import CryptoKit
import Foundation
import GitHubKit

/// AWS Signature Version 4, by hand, for exactly three operations (ADR 0014).
///
/// Shepherd needs `GET`, `PUT` and `HEAD` on **one** object. An AWS SDK would be several hundred
/// thousand lines and a new dependency for that; SigV4 itself is four hashes and a string
/// concatenation, and the only part that is easy to get wrong — canonicalisation — is precisely
/// the part that can be pinned to the official test vectors. So this type is a pure value: it
/// takes a description of a request and returns strings. It opens no connection, reads no
/// Keychain, and knows nothing about S3 beyond the service name.
///
/// The canonicalisation rules implemented here, in the order the specification applies them:
///
/// 1. `CanonicalRequest = METHOD ⏎ CanonicalURI ⏎ CanonicalQuery ⏎ CanonicalHeaders ⏎⏎
///    SignedHeaders ⏎ HexSHA256(payload)` — note the blank line after the headers block, which
///    is why ``canonicalHeaders(_:)`` ends every header with a newline of its own.
/// 2. Query parameters are sorted by name, then by value, and both halves are URI-encoded with
///    the unreserved set only (space becomes `%20`, never `+`).
/// 3. Header names are lower-cased, values trimmed, and the list sorted by name. `host` and
///    `x-amz-date` are mandatory; for S3, so is `x-amz-content-sha256`.
/// 4. The signing key is a four-step HMAC chain over date, region, service and the literal
///    `aws4_request`, keyed initially by `"AWS4" + secret`.
///
/// Path canonicalisation is **single**-encoded, which is S3's rule and differs from every other
/// AWS service. Shepherd only ever signs `/<bucket>/<prefix>/settings.enc.json`, but the prefix
/// comes from a text field, so the encoding is applied rather than assumed.
struct SigV4Signer: Sendable, Equatable {
    /// The algorithm identifier that appears in the string-to-sign and the header.
    static let algorithm = "AWS4-HMAC-SHA256"
    /// The terminator of the credential scope.
    static let requestType = "aws4_request"
    /// The header S3 requires the payload hash in.
    static let contentSHA256Header = "x-amz-content-sha256"
    /// The header the request timestamp goes in.
    static let dateHeader = "x-amz-date"

    /// An access key pair. Lives in the Keychain; this type only ever holds it in memory.
    struct Credentials: Sendable, Equatable {
        /// The access key id, which appears in the `Authorization` header in the clear.
        var accessKeyID: String
        /// The secret access key, which never appears anywhere but inside an HMAC.
        var secretAccessKey: String

        /// Creates a pair.
        /// - Parameters:
        ///   - accessKeyID: The access key id.
        ///   - secretAccessKey: The secret access key.
        init(accessKeyID: String, secretAccessKey: String) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
        }

        /// Whether both halves are present.
        var isComplete: Bool {
            !accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// One query parameter, before canonicalisation.
    struct QueryItem: Sendable, Equatable {
        /// The parameter name, not yet encoded.
        var name: String
        /// The parameter value, not yet encoded.
        var value: String

        /// Creates a parameter.
        /// - Parameters:
        ///   - name: The name.
        ///   - value: The value.
        init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Everything the signature is computed over.
    struct Request: Sendable, Equatable {
        /// The HTTP method, upper case.
        var method: String
        /// The absolute path, **not** yet URI-encoded, starting with `/`.
        var path: String
        /// The query parameters, in any order.
        var query: [QueryItem]
        /// The headers to sign, in any case and any order. Every one of them is signed.
        var headers: [String: String]
        /// The lowercase hex SHA-256 of the request body.
        var payloadHash: String

        /// Creates a request description.
        init(
            method: String,
            path: String,
            query: [QueryItem] = [],
            headers: [String: String],
            payloadHash: String
        ) {
            self.method = method
            self.path = path
            self.query = query
            self.headers = headers
            self.payloadHash = payloadHash
        }
    }

    /// The access key pair to sign with.
    var credentials: Credentials
    /// The region, e.g. `eu01` for STACKIT or `us-east-1` for AWS.
    var region: String
    /// The service name, `s3` for object storage.
    var service: String

    /// Creates a signer.
    /// - Parameters:
    ///   - credentials: The access key pair.
    ///   - region: The region.
    ///   - service: The service name.
    init(credentials: Credentials, region: String, service: String = "s3") {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    // MARK: - Canonicalisation

    /// URI-encodes a string the way SigV4 requires.
    ///
    /// Only `A-Z a-z 0-9 - _ . ~` survive unescaped; everything else becomes uppercase
    /// percent-escapes of its UTF-8 bytes. `/` is exempt when encoding a path, because the path
    /// separator is structural.
    /// - Parameters:
    ///   - text: The string to encode.
    ///   - encodeSlash: Whether `/` is escaped too. `false` for paths, `true` for query halves.
    /// - Returns: The encoded string.
    static func uriEncode(_ text: String, encodeSlash: Bool) -> String {
        var encoded = ""
        encoded.reserveCapacity(text.utf8.count)
        // Byte by byte rather than character by character, because that is what the
        // specification says: a multi-byte scalar becomes one escape per UTF-8 byte.
        for byte in text.utf8 {
            if unreservedBytes.contains(byte) || (byte == slashByte && !encodeSlash) {
                encoded.append(Character(Unicode.Scalar(byte)))
            } else {
                // Written out rather than via `String(format:)`: the escapes must be uppercase
                // hex of the *byte*, and a format string would put a C variadic promotion
                // between this loop and that requirement.
                encoded.append(Character("%"))
                encoded.append(upperHexDigits[Int(byte >> 4)])
                encoded.append(upperHexDigits[Int(byte & 0x0F)])
            }
        }
        return encoded
    }

    /// The bytes SigV4 leaves unescaped: `A-Z a-z 0-9 - _ . ~` and nothing else.
    private static let unreservedBytes: Set<UInt8> = {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            + "abcdefghijklmnopqrstuvwxyz0123456789-_.~"
        return Set(unreserved.utf8)
    }()

    /// The path separator, which is structural rather than data in a canonical URI.
    private static let slashByte = UInt8(ascii: "/")

    /// The canonical URI: the encoded path, or `/` when there is none.
    /// - Parameter path: The raw path.
    /// - Returns: The canonical URI.
    static func canonicalURI(path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let absolute = path.hasPrefix("/") ? path : "/" + path
        return uriEncode(absolute, encodeSlash: false)
    }

    /// The canonical query string: every half encoded, sorted by name and then by value.
    ///
    /// Sorting on the *encoded* forms is what the specification says, and it matters: `%2F`
    /// sorts before `a`, while `/` does not.
    /// - Parameter items: The parameters.
    /// - Returns: The canonical query string, empty when there are no parameters.
    static func canonicalQuery(_ items: [QueryItem]) -> String {
        items
            .map { (uriEncode($0.name, encodeSlash: true), uriEncode($0.value, encodeSlash: true)) }
            .sorted { left, right in
                left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
            }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// The canonical headers block: `name:value⏎` per header, lower-cased and sorted.
    ///
    /// Values are trimmed of surrounding whitespace. Internal runs of spaces are left alone;
    /// every header Shepherd signs is a hostname, a hex digest, a timestamp or a media type, so
    /// there are none, and collapsing them blindly would corrupt a value that legitimately had
    /// them.
    /// - Parameter headers: The headers to sign.
    /// - Returns: The canonical block, already newline-terminated.
    static func canonicalHeaders(_ headers: [String: String]) -> String {
        headers
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()
    }

    /// The semicolon-separated list of signed header names, lower-cased and sorted.
    /// - Parameter headers: The headers to sign.
    /// - Returns: The `SignedHeaders` value.
    static func signedHeaders(_ headers: [String: String]) -> String {
        headers.keys.map { $0.lowercased() }.sorted().joined(separator: ";")
    }

    /// The canonical request, exactly as it is hashed.
    /// - Parameter request: The request description.
    /// - Returns: The canonical request string.
    static func canonicalRequest(_ request: Request) -> String {
        [
            request.method.uppercased(),
            canonicalURI(path: request.path),
            canonicalQuery(request.query),
            canonicalHeaders(request.headers),
            signedHeaders(request.headers),
            request.payloadHash,
        ].joined(separator: "\n")
    }

    // MARK: - Signing

    /// The credential scope: `<date>/<region>/<service>/aws4_request`.
    /// - Parameter date: The request timestamp.
    /// - Returns: The scope.
    func credentialScope(at date: Date) -> String {
        [SigV4Signer.dateStamp(date), region, service, SigV4Signer.requestType]
            .joined(separator: "/")
    }

    /// The string that is actually HMAC'd with the signing key.
    /// - Parameters:
    ///   - request: The request description.
    ///   - date: The request timestamp.
    /// - Returns: The string-to-sign.
    func stringToSign(_ request: Request, at date: Date) -> String {
        [
            SigV4Signer.algorithm,
            SigV4Signer.amzDate(date),
            credentialScope(at: date),
            SigV4Signer.hexSHA256(Data(SigV4Signer.canonicalRequest(request).utf8)),
        ].joined(separator: "\n")
    }

    /// Derives the date/region/service-scoped signing key.
    ///
    /// Four chained HMACs, each keyed by the previous result — which is what makes a leaked
    /// signing key useless outside its day, region and service.
    /// - Parameters:
    ///   - secretAccessKey: The secret access key.
    ///   - dateStamp: The `yyyyMMdd` date stamp.
    ///   - region: The region.
    ///   - service: The service name.
    /// - Returns: The 32-byte signing key.
    static func signingKey(
        secretAccessKey: String,
        dateStamp: String,
        region: String,
        service: String
    ) -> SymmetricKey {
        var key = SymmetricKey(data: Data(("AWS4" + secretAccessKey).utf8))
        for element in [dateStamp, region, service, requestType] {
            let code = HMAC<SHA256>.authenticationCode(for: Data(element.utf8), using: key)
            key = SymmetricKey(data: Data(code))
        }
        return key
    }

    /// The signature: lowercase hex of HMAC-SHA256(signing key, string-to-sign).
    /// - Parameters:
    ///   - request: The request description.
    ///   - date: The request timestamp.
    /// - Returns: 64 lowercase hex characters.
    func signature(_ request: Request, at date: Date) -> String {
        let key = SigV4Signer.signingKey(
            secretAccessKey: credentials.secretAccessKey,
            dateStamp: SigV4Signer.dateStamp(date),
            region: region,
            service: service
        )
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign(request, at: date).utf8),
            using: key
        )
        return SigV4Signer.hex(code)
    }

    /// The complete `Authorization` header value.
    /// - Parameters:
    ///   - request: The request description.
    ///   - date: The request timestamp.
    /// - Returns: The header value.
    func authorizationHeader(_ request: Request, at date: Date) -> String {
        let scope = credentialScope(at: date)
        let signed = SigV4Signer.signedHeaders(request.headers)
        return "\(SigV4Signer.algorithm) "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signed), "
            + "Signature=\(signature(request, at: date))"
    }

    // MARK: - Primitives

    /// `yyyyMMdd'T'HHmmss'Z'` in UTC.
    ///
    /// Derived from ``GitHubKit/GitHubTimestamp/string(from:)`` by dropping its separators rather
    /// than from a `DateFormatter`: that function is already the app's locale-independent,
    /// calendar-independent UTC formatter and is unit-tested as such, and a `DateFormatter` here
    /// would be one `Locale` away from emitting Buddhist-calendar years.
    /// - Parameter date: The moment to format.
    /// - Returns: The `X-Amz-Date` value.
    static func amzDate(_ date: Date) -> String {
        String(GitHubTimestamp.string(from: date).filter { $0 != "-" && $0 != ":" })
    }

    /// `yyyyMMdd` in UTC.
    /// - Parameter date: The moment to format.
    /// - Returns: The date stamp used in the credential scope.
    static func dateStamp(_ date: Date) -> String {
        String(amzDate(date).prefix(8))
    }

    /// Lowercase hex SHA-256 of some bytes.
    /// - Parameter data: The bytes.
    /// - Returns: 64 lowercase hex characters.
    static func hexSHA256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// The hash of an empty body, which every GET and HEAD carries.
    static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// The digits percent-escapes are written with. Uppercase, as the specification requires.
    private static let upperHexDigits: [Character] = Array("0123456789ABCDEF")

    /// Lowercase hex, the only encoding SigV4 uses.
    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        for byte in bytes {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }
}
