import CommonCrypto
import CryptoKit
import Foundation

/// The whole cryptographic surface of settings sync (ADR 0014), and nothing else.
///
/// Two Apple primitives, no invention:
///
/// - **PBKDF2-HMAC-SHA256** via `CCKeyDerivationPBKDF` turns the passphrase into a 256-bit key.
///   CommonCrypto rather than CryptoKit because CryptoKit still has no password-based KDF; the
///   cost (``productionIterations``) and a fresh 32-byte salt per upload are what make a stolen
///   object expensive rather than free to attack.
/// - **AES-256-GCM** via CryptoKit seals the document. AES over ChaCha20-Poly1305 for two
///   reasons: Apple Silicon has AES instructions, so the cost is invisible at this size, and
///   AES-GCM is the AEAD every other language's standard library speaks — the user's own
///   ten-line Python script must be able to open their own backup, which is a real requirement
///   for a local-first product that promises no lock-in.
///
/// The nonce is fresh per upload (``nonceByteCount`` random bytes), never reused, and never
/// derived from anything. The envelope's metadata is authenticated as AAD, so the parameters
/// cannot be edited in the bucket to weaken a later download.
enum SettingsSyncCrypto {
    // MARK: - Parameters

    /// The KDF name written into the envelope.
    static let kdfAlgorithm = "PBKDF2-HMAC-SHA256"
    /// The AEAD name written into the envelope.
    static let cipherAlgorithm = "AES-256-GCM"

    /// The iteration count every upload from this build uses.
    ///
    /// Above OWASP's 2023 floor for PBKDF2-HMAC-SHA256 (600 000) and paid exactly twice per
    /// user action — once on upload, once on download — so there is no reason to shave it.
    static let productionIterations = 600_000

    /// The salt length in bytes.
    static let saltByteCount = 32
    /// The shortest salt a *stored* envelope may carry, so tests can seal cheaply while a real
    /// upload always gets ``saltByteCount``.
    static let minimumSaltByteCount = 16
    /// The AES-GCM nonce length in bytes (96 bits, the value GCM is specified for).
    static let nonceByteCount = 12
    /// The derived key length in bytes.
    static let keyByteCount = 32
    /// The GCM authentication tag length in bytes.
    static let tagByteCount = 16

    /// The shortest passphrase an upload will accept.
    ///
    /// A guard rather than a policy engine: the passphrase is the only thing between the bucket
    /// and the user's GitHub token, and an offline attacker gets unlimited attempts. Both
    /// ``seal(document:passphrase:deviceName:createdAt:iterations:salt:nonce:)`` and
    /// ``open(_:passphrase:)`` trim surrounding whitespace before using the passphrase, so a
    /// stray space picked up from a paste cannot make a round trip fail asymmetrically.
    static let minimumPassphraseLength = 12

    /// The iteration counts a *downloaded* envelope may declare.
    ///
    /// The upper bound is the interesting half: an envelope is untrusted input, and without a
    /// cap a bucket that answers with `"iterations": 2000000000` would freeze the app for hours
    /// on a button press. The lower bound stays at 1 so the test suite can seal in milliseconds.
    static let acceptedIterations = 1...5_000_000

    /// The longest device name that goes into an envelope.
    static let deviceNameLimit = 64

    // MARK: - Key derivation

    /// Derives the content-encryption key from a passphrase.
    ///
    /// - Parameters:
    ///   - passphrase: The user's passphrase, used as UTF-8 bytes.
    ///   - salt: The envelope's salt.
    ///   - iterations: The envelope's iteration count.
    /// - Returns: A 256-bit symmetric key.
    /// - Throws: ``SettingsSyncError/passphraseMissing``,
    ///   ``SettingsSyncError/iterationsOutOfRange(_:)`` or
    ///   ``SettingsSyncError/keyDerivationFailed(_:)``.
    static func derivedKey(
        passphrase: String,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        guard !passphrase.isEmpty else { throw SettingsSyncError.passphraseMissing }
        guard acceptedIterations.contains(iterations) else {
            throw SettingsSyncError.iterationsOutOfRange(iterations)
        }
        guard !salt.isEmpty else { throw SettingsSyncError.malformedEnvelope }

        var derived = [UInt8](repeating: 0, count: keyByteCount)
        // `withCString` hands CommonCrypto exactly the `const char *` it wants, NUL-terminated,
        // and `strlen` is the byte length of the UTF-8 passphrase. A passphrase typed into a
        // text field cannot contain a NUL, so nothing is silently truncated.
        let status: Int32 = passphrase.withCString { password in
            salt.withUnsafeBytes { saltBuffer in
                derived.withUnsafeMutableBytes { keyBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password,
                        strlen(password),
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        keyBuffer.bindMemory(to: UInt8.self).baseAddress,
                        keyBuffer.count
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw SettingsSyncError.keyDerivationFailed(status)
        }
        let key = SymmetricKey(data: Data(derived))
        // The array is the only copy of the key material outside CryptoKit's own storage.
        for index in derived.indices { derived[index] = 0 }
        return key
    }

    // MARK: - Sealing

    /// Seals a settings document into an envelope.
    ///
    /// - Parameters:
    ///   - document: The document to protect.
    ///   - passphrase: The user's passphrase.
    ///   - deviceName: Which Mac is uploading; sanitised and authenticated.
    ///   - createdAt: The envelope timestamp.
    ///   - iterations: The KDF cost. Defaults to ``productionIterations``; the tests lower it.
    ///   - salt: The salt. Defaults to fresh randomness.
    ///   - nonce: The nonce. Defaults to fresh randomness — **never** pass a reused one.
    /// - Returns: The envelope to upload.
    /// - Throws: ``SettingsSyncError`` when the passphrase is unusable or sealing fails.
    static func seal(
        document: SyncedSettingsDocument,
        passphrase: String,
        deviceName: String,
        createdAt: Date,
        iterations: Int = SettingsSyncCrypto.productionIterations,
        salt: Data = SettingsSyncCrypto.randomBytes(SettingsSyncCrypto.saltByteCount),
        nonce: Data = SettingsSyncCrypto.randomBytes(SettingsSyncCrypto.nonceByteCount)
    ) throws -> SettingsEnvelope {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsSyncError.passphraseMissing }
        guard trimmed.count >= minimumPassphraseLength else {
            throw SettingsSyncError.passphraseTooShort(minimum: minimumPassphraseLength)
        }

        let plaintext: Data
        do {
            plaintext = try document.canonicalJSON()
        } catch {
            throw SettingsSyncError.malformedDocument
        }

        // Built first, sealed second: the envelope *is* the AAD, so the metadata that will be
        // uploaded and the metadata that was authenticated are the same object by construction.
        var envelope = SettingsEnvelope(
            kdf: SettingsEnvelope.KDF(
                algorithm: kdfAlgorithm,
                salt: salt,
                iterations: iterations
            ),
            cipher: SettingsEnvelope.Cipher(algorithm: cipherAlgorithm, nonce: nonce),
            createdAt: createdAt,
            deviceName: sanitisedDeviceName(deviceName),
            payload: Data()
        )

        let key = try derivedKey(passphrase: trimmed, salt: salt, iterations: iterations)
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce) else {
            throw SettingsSyncError.malformedEnvelope
        }
        guard let sealed = try? AES.GCM.seal(
            plaintext,
            using: key,
            nonce: gcmNonce,
            authenticating: envelope.authenticatedData
        ) else {
            throw SettingsSyncError.malformedEnvelope
        }
        envelope.payload = sealed.ciphertext + sealed.tag
        return envelope
    }

    /// Opens an envelope.
    ///
    /// Every authentication failure — a wrong passphrase, an edited salt, a lowered iteration
    /// count, one flipped bit — arrives here as the same thrown error, and no plaintext is
    /// produced in any of those cases. GCM verifies the tag before returning anything, so there
    /// is no such thing as a half-decrypted document to leak.
    /// - Parameters:
    ///   - envelope: The envelope from the bucket.
    ///   - passphrase: The user's passphrase.
    /// - Returns: The settings document.
    /// - Throws: ``SettingsSyncError/wrongPassphraseOrCorruptedData`` for any tag failure, or a
    ///   document error when the plaintext is not a document this build understands.
    static func open(
        _ envelope: SettingsEnvelope,
        passphrase: String
    ) throws -> SyncedSettingsDocument {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SettingsSyncError.passphraseMissing }
        guard envelope.payload.count > tagByteCount else {
            throw SettingsSyncError.malformedEnvelope
        }

        let key = try derivedKey(
            passphrase: trimmed,
            salt: envelope.kdf.salt,
            iterations: envelope.kdf.iterations
        )
        let boundary = envelope.payload.count - tagByteCount
        let ciphertext = envelope.payload.prefix(boundary)
        let tag = envelope.payload.suffix(tagByteCount)

        guard let nonce = try? AES.GCM.Nonce(data: envelope.cipher.nonce),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plaintext = try? AES.GCM.open(
                  box,
                  using: key,
                  authenticating: envelope.authenticatedData
              )
        else { throw SettingsSyncError.wrongPassphraseOrCorruptedData }

        return try SyncedSettingsDocument.decode(from: plaintext)
    }

    // MARK: - Helpers

    /// Cryptographically secure random bytes.
    /// - Parameter count: How many.
    /// - Returns: The bytes.
    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8.random(in: 0...255, using: &generator))
        }
        return Data(bytes)
    }

    /// The device name as it may appear in an envelope.
    ///
    /// Control characters are removed and the length is capped, because this string is the last
    /// line of the authenticated byte list: a newline inside it would make the AAD ambiguous,
    /// and an unbounded one would let a hostile hostname bloat every upload.
    /// - Parameter name: The raw name.
    /// - Returns: A single-line, bounded name; `"Mac"` when nothing usable is left.
    static func sanitisedDeviceName(_ name: String) -> String {
        let cleaned = name.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map { Character($0) }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Mac" }
        return String(trimmed.prefix(deviceNameLimit))
    }

    /// This Mac's name, for the envelope's `deviceName`.
    ///
    /// `ProcessInfo.hostName` rather than `Host.current().localizedName`: it needs no framework
    /// beyond Foundation, carries no deprecation risk, and the Bonjour `.local` suffix it adds is
    /// noise in a status line, so it is trimmed.
    static var currentDeviceName: String {
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") {
            name = String(name.dropLast(".local".count))
        }
        return sanitisedDeviceName(name)
    }
}
