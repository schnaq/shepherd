import Foundation
import GitHubKit

/// The versioned, self-describing container that is actually uploaded (ADR 0014).
///
/// Everything a reader needs in order to attempt decryption is in the clear — the KDF, its cost,
/// its salt, the cipher and the nonce — because none of it is secret and hiding it would only
/// make the format unopenable by anything but this exact build. What is *not* in the clear is
/// the payload, and what is not present at all is the passphrase.
///
/// The metadata is not merely descriptive: it is fed to the AEAD as additional authenticated
/// data (``authenticatedData``), so an attacker who owns the bucket cannot lower `iterations`,
/// swap the salt, or relabel `deviceName` without the tag failing. The envelope is therefore
/// tamper-evident as a whole, not just in its ciphertext.
struct SettingsEnvelope: Sendable, Equatable {
    /// The envelope version. Bumped only for a change a reader cannot ignore.
    static let schemaVersion = 1

    /// The key-derivation parameters.
    struct KDF: Sendable, Equatable {
        /// The algorithm name, always ``SettingsSyncCrypto/kdfAlgorithm`` for version 1.
        var algorithm: String
        /// The random per-upload salt.
        var salt: Data
        /// The iteration count.
        var iterations: Int
    }

    /// The AEAD parameters.
    struct Cipher: Sendable, Equatable {
        /// The algorithm name, always ``SettingsSyncCrypto/cipherAlgorithm`` for version 1.
        var algorithm: String
        /// The fresh per-upload nonce.
        var nonce: Data
    }

    /// The envelope version.
    var v: Int
    /// How the passphrase becomes a key.
    var kdf: KDF
    /// How the plaintext becomes the payload.
    var cipher: Cipher
    /// When this envelope was sealed.
    var createdAt: Date
    /// Which Mac sealed it, so the user can tell "did my laptop or my desk Mac write this?".
    var deviceName: String
    /// The ciphertext **with the 16-byte authentication tag appended**.
    ///
    /// Concatenated rather than split into two fields on purpose: that is the layout every
    /// non-Apple AEAD implementation expects, so a user can decrypt their own backup with ten
    /// lines of Python if Shepherd ever stops existing.
    var payload: Data

    /// Creates an envelope.
    init(
        v: Int = SettingsEnvelope.schemaVersion,
        kdf: KDF,
        cipher: Cipher,
        createdAt: Date,
        deviceName: String,
        payload: Data
    ) {
        self.v = v
        self.kdf = kdf
        self.cipher = cipher
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.payload = payload
    }

    // MARK: - Additional authenticated data

    /// The prefix that makes the authenticated bytes unambiguous about what they belong to.
    static let authenticatedDataPrefix = "shepherd.settings-sync/1"

    /// The bytes the AEAD authenticates alongside the payload.
    ///
    /// Deliberately **not** produced by `JSONEncoder`: this byte string has to be reproducible
    /// years and OS versions later (and by a third-party script), so it is a fixed, hand-written
    /// `key=value` list joined by newlines rather than something whose escaping rules belong to
    /// Foundation. Every value except ``deviceName`` is ASCII by construction; `deviceName` is
    /// sanitised when it is captured (``SettingsSyncCrypto/sanitisedDeviceName(_:)``) and is
    /// written last, so a stray separator cannot shift the meaning of another field.
    ///
    /// The nonce is *not* in here. It needs no additional protection: it is already an input to
    /// the AEAD, so changing it invalidates the tag by itself.
    var authenticatedData: Data {
        let lines = [
            SettingsEnvelope.authenticatedDataPrefix,
            "v=\(v)",
            "kdf=\(kdf.algorithm)",
            "iterations=\(kdf.iterations)",
            "salt=\(kdf.salt.base64EncodedString())",
            "cipher=\(cipher.algorithm)",
            "createdAt=\(GitHubTimestamp.string(from: createdAt))",
            "deviceName=\(deviceName)",
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: - Wire format

    /// Encodes the envelope as the JSON that goes into the bucket.
    ///
    /// `JSONSerialization` rather than `Codable`: the shape is a contract with every other Mac
    /// *and* with the AAD above, and writing it as one literal keeps the two impossible to drift
    /// apart. Sorted keys make the bytes deterministic; pretty-printing costs a few dozen bytes
    /// and buys a user browsing their bucket a readable object.
    /// - Returns: The object body.
    /// - Throws: Whatever `JSONSerialization` throws, which for this fixed shape is nothing.
    func json() throws -> Data {
        let object: [String: Any] = [
            "v": v,
            "kdf": [
                "algo": kdf.algorithm,
                "salt": kdf.salt.base64EncodedString(),
                "iterations": kdf.iterations,
            ] as [String: Any],
            "cipher": [
                "algo": cipher.algorithm,
                "nonce": cipher.nonce.base64EncodedString(),
            ] as [String: Any],
            "createdAt": GitHubTimestamp.string(from: createdAt),
            "deviceName": deviceName,
            "payload": payload.base64EncodedString(),
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .prettyPrinted]
        )
    }

    /// Parses an envelope out of an object body.
    ///
    /// Strict, because this is untrusted input from a server: the version is checked before
    /// anything else, every field must be present and of the right type, and the base64 fields
    /// must decode to the exact lengths the algorithms require.
    /// - Parameter data: The object body.
    /// - Returns: The parsed envelope.
    /// - Throws: ``SettingsSyncError/malformedEnvelope``,
    ///   ``SettingsSyncError/unsupportedEnvelopeVersion(_:)``,
    ///   ``SettingsSyncError/unsupportedAlgorithm(_:)`` or
    ///   ``SettingsSyncError/iterationsOutOfRange(_:)``.
    static func parse(_ data: Data) throws -> SettingsEnvelope {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsSyncError.malformedEnvelope
        }
        guard let version = root["v"] as? Int else { throw SettingsSyncError.malformedEnvelope }
        guard version == schemaVersion else {
            throw SettingsSyncError.unsupportedEnvelopeVersion(version)
        }
        guard let kdfObject = root["kdf"] as? [String: Any],
              let cipherObject = root["cipher"] as? [String: Any],
              let kdfAlgorithm = kdfObject["algo"] as? String,
              let cipherAlgorithm = cipherObject["algo"] as? String,
              let iterations = kdfObject["iterations"] as? Int,
              let saltText = kdfObject["salt"] as? String,
              let nonceText = cipherObject["nonce"] as? String,
              let payloadText = root["payload"] as? String,
              let createdAtText = root["createdAt"] as? String,
              let deviceName = root["deviceName"] as? String,
              let salt = Data(base64Encoded: saltText),
              let nonce = Data(base64Encoded: nonceText),
              let payload = Data(base64Encoded: payloadText),
              let createdAt = GitHubTimestamp.parse(createdAtText)
        else { throw SettingsSyncError.malformedEnvelope }

        guard kdfAlgorithm == SettingsSyncCrypto.kdfAlgorithm else {
            throw SettingsSyncError.unsupportedAlgorithm(kdfAlgorithm)
        }
        guard cipherAlgorithm == SettingsSyncCrypto.cipherAlgorithm else {
            throw SettingsSyncError.unsupportedAlgorithm(cipherAlgorithm)
        }
        guard SettingsSyncCrypto.acceptedIterations.contains(iterations) else {
            throw SettingsSyncError.iterationsOutOfRange(iterations)
        }
        // A payload shorter than the tag cannot even be a tag, let alone a document; catching it
        // here means the AEAD is never handed nonsense.
        guard salt.count >= SettingsSyncCrypto.minimumSaltByteCount,
              nonce.count == SettingsSyncCrypto.nonceByteCount,
              payload.count > SettingsSyncCrypto.tagByteCount
        else { throw SettingsSyncError.malformedEnvelope }

        return SettingsEnvelope(
            v: version,
            kdf: KDF(algorithm: kdfAlgorithm, salt: salt, iterations: iterations),
            cipher: Cipher(algorithm: cipherAlgorithm, nonce: nonce),
            createdAt: createdAt,
            deviceName: deviceName,
            payload: payload
        )
    }
}
