import Foundation

/// How the bucket is addressed in the URL.
///
/// Path-style is the default and it is a deliberate choice, not a legacy one: AWS is deprecating
/// path-style, but the S3-*compatible* providers this feature exists for — STACKIT, MinIO, Ceph,
/// Garage — either require it or serve it more reliably, and virtual-hosted style additionally
/// needs a wildcard TLS certificate on the provider's side. The user can switch when their
/// provider prefers it.
enum S3AddressingStyle: String, CaseIterable, Sendable, Codable, Identifiable {
    /// `https://endpoint/bucket/key` — the robust default for S3-compatible providers.
    case path
    /// `https://bucket.endpoint/key` — what AWS itself prefers.
    case virtualHosted

    var id: String { rawValue }

    /// The label shown in the picker.
    var title: String {
        switch self {
        case .path: return String(localized: "Path style")
        case .virtualHosted: return String(localized: "Virtual-hosted style")
        }
    }
}

/// Where the one settings object lives, resolved from the user's fields.
///
/// A value, and a validated one: constructing it is the only way the rest of the feature learns
/// a host or a path, so a mistyped endpoint fails in Settings rather than halfway through an
/// upload.
struct S3ObjectLocation: Sendable, Equatable {
    /// The default object key relative to the prefix.
    static let objectName = "settings.enc.json"
    /// The prefix a fresh install uses.
    static let defaultPrefix = "shepherd"

    /// The service endpoint, e.g. `https://object.storage.eu01.onstackit.cloud`.
    var endpoint: URL
    /// The bucket name.
    var bucket: String
    /// The object key, prefix included.
    var key: String
    /// The signing region, e.g. `eu01`.
    var region: String
    /// How the bucket appears in the URL.
    var addressing: S3AddressingStyle

    /// The `Host` header — and therefore the host that gets signed.
    var host: String {
        let base = endpoint.host(percentEncoded: false) ?? ""
        let withPort = endpoint.port.map { "\(base):\($0)" } ?? base
        switch addressing {
        case .path:
            return withPort
        case .virtualHosted:
            return bucket.isEmpty ? withPort : "\(bucket).\(withPort)"
        }
    }

    /// The raw (unencoded) path that gets canonicalised and signed.
    var path: String {
        switch addressing {
        case .path:
            return "/\(bucket)/\(key)"
        case .virtualHosted:
            return "/\(key)"
        }
    }

    /// The URL to actually open.
    ///
    /// Built from the signed pieces — the canonical URI, not the raw path — so the bytes on the
    /// wire and the bytes in the signature cannot disagree. `URLComponents` is avoided for the
    /// same reason: it would be free to re-normalise the path after signing.
    var url: URL? {
        let scheme = endpoint.scheme ?? "https"
        let canonical = SigV4Signer.canonicalURI(path: path)
        return URL(string: "\(scheme)://\(host)\(canonical)")
    }

    /// Validates the user's fields into a location.
    ///
    /// - Parameters:
    ///   - endpointText: The endpoint as typed.
    ///   - bucket: The bucket name as typed.
    ///   - region: The region as typed.
    ///   - prefix: The key prefix as typed; empty means the object sits at the bucket root.
    ///   - addressing: The addressing style.
    /// - Returns: The validated location.
    /// - Throws: ``SettingsSyncError/notConfigured``, ``SettingsSyncError/invalidEndpoint`` or
    ///   ``SettingsSyncError/invalidBucket``.
    static func resolve(
        endpointText: String,
        bucket: String,
        region: String,
        prefix: String,
        addressing: S3AddressingStyle
    ) throws -> S3ObjectLocation {
        let endpointTrimmed = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bucketTrimmed = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let regionTrimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointTrimmed.isEmpty, !bucketTrimmed.isEmpty, !regionTrimmed.isEmpty else {
            throw SettingsSyncError.notConfigured
        }
        guard !bucketTrimmed.contains("/") else { throw SettingsSyncError.invalidBucket }
        // https only, and no exception for localhost: a MinIO on this machine is a plausible
        // setup, but the object carries the user's GitHub token, so "it is only on my LAN" is
        // not a good enough reason to put it on the wire in the clear.
        guard let endpoint = URL(string: endpointTrimmed),
              endpoint.scheme?.lowercased() == "https",
              let host = endpoint.host(percentEncoded: false), !host.isEmpty
        else { throw SettingsSyncError.invalidEndpoint }

        return S3ObjectLocation(
            endpoint: endpoint,
            bucket: bucketTrimmed,
            key: objectKey(prefix: prefix),
            region: regionTrimmed,
            addressing: addressing
        )
    }

    /// Joins a user-typed prefix with the fixed object name.
    ///
    /// Leading and trailing slashes are absorbed so `shepherd`, `/shepherd` and `shepherd/` all
    /// mean the same thing — the field is a folder, and a user should not be able to create
    /// `//settings.enc.json` by ending it the way a path usually ends.
    /// - Parameter prefix: The prefix as typed.
    /// - Returns: The object key.
    static func objectKey(prefix: String) -> String {
        let cleaned = prefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        return (cleaned + [objectName]).joined(separator: "/")
    }
}

/// One prepared, already-signed HTTP request.
struct S3ObjectRequest: Sendable, Equatable {
    /// The HTTP method.
    var method: String
    /// Where to send it.
    var url: URL
    /// Every header, `Authorization` included.
    var headers: [String: String]
    /// The body, for `PUT`.
    var body: Data?
    /// How long one attempt may take.
    var timeout: TimeInterval
}

/// What the storage service answered.
struct S3ObjectResponse: Sendable, Equatable {
    /// The HTTP status.
    var status: Int
    /// The response headers, keys lower-cased by the transport.
    var headers: [String: String]
    /// The body, empty for `HEAD`.
    var body: Data

    /// Whether the request succeeded.
    var isSuccess: Bool { (200..<300).contains(status) }

    /// `Last-Modified`, parsed.
    ///
    /// An RFC 7231 IMF-fixdate is the only shape S3 implementations emit here, and it is parsed
    /// with a POSIX-locale formatter so a user in a non-Gregorian region still gets a date.
    var lastModified: Date? {
        guard let text = headers["last-modified"] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    /// The object size the service reported.
    var contentLength: Int? {
        headers["content-length"].flatMap(Int.init)
    }

    /// The first line of an S3 error body, which is XML.
    ///
    /// Only the `<Message>` element is extracted, and only up to a sane length: the goal is a
    /// status line a user can act on ("SignatureDoesNotMatch"), not an XML parser.
    var errorMessage: String {
        guard let text = String(data: body, encoding: .utf8) else { return "" }
        guard let start = text.range(of: "<Message>"),
              let end = text.range(of: "</Message>", range: start.upperBound..<text.endIndex)
        else { return "" }
        return String(text[start.upperBound..<end.lowerBound].prefix(200))
    }
}

/// The seam the settings-sync tests drive instead of a network, in the same spirit as
/// ``WebhookPosting``, ``ModelListing`` and ``AgentRunning``.
protocol S3Transporting: Sendable {
    /// Performs one prepared request.
    /// - Parameter request: What to send.
    /// - Returns: What came back.
    /// - Throws: ``SettingsSyncError/transport(_:)`` when there was no answer.
    func perform(_ request: S3ObjectRequest) async throws -> S3ObjectResponse
}

/// The production transport.
///
/// A plain `URLSession` call to the endpoint the user typed, and nothing else. Like the webhook
/// poster, this is one of the very few places in Shepherd that opens a connection to a host the
/// user named themselves.
struct URLSessionS3Transport: S3Transporting {
    /// A shared instance; the type is stateless.
    static let shared = URLSessionS3Transport()

    /// Creates a transport.
    init() {}

    func perform(_ request: S3ObjectRequest) async throws -> S3ObjectResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers {
            // `Host` is reserved: URLSession sets it from the URL and silently drops an attempt
            // to override it. It is signed all the same, which is correct — the value URLSession
            // will send is the one the URL's host produced, and that is what was signed.
            guard name.lowercased() != "host" else { continue }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body

        do {
            let (data, response) = try await CredentialSafeSession.shared.data(for: urlRequest)
            var headers: [String: String] = [:]
            if let http = response as? HTTPURLResponse {
                for (key, value) in http.allHeaderFields {
                    guard let name = key as? String, let text = value as? String else { continue }
                    headers[name.lowercased()] = text
                }
                return S3ObjectResponse(status: http.statusCode, headers: headers, body: data)
            }
            return S3ObjectResponse(status: 0, headers: headers, body: data)
        } catch {
            throw SettingsSyncError.transport(error.localizedDescription)
        }
    }
}

/// GET, PUT and HEAD on one object, signed by hand (ADR 0014).
///
/// The client is intentionally not a general S3 client: there is no list, no delete, no
/// multipart, no bucket creation. The whole surface is "read the settings object, write the
/// settings object, ask when it last changed", which is also the whole set of permissions a
/// user needs to hand out to make this work.
struct S3ObjectClient: Sendable {
    /// How long one request may take.
    static let timeout: TimeInterval = 30

    /// Where the object lives.
    let location: S3ObjectLocation
    /// The access key pair.
    let credentials: SigV4Signer.Credentials
    /// The transport; tests pass a recorder.
    let transport: any S3Transporting
    /// Clock injection point, so the tests can pin `X-Amz-Date`.
    let now: @Sendable () -> Date

    /// Creates a client.
    /// - Parameters:
    ///   - location: Where the object lives.
    ///   - credentials: The access key pair.
    ///   - transport: The transport.
    ///   - now: The clock.
    init(
        location: S3ObjectLocation,
        credentials: SigV4Signer.Credentials,
        transport: any S3Transporting = URLSessionS3Transport.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.location = location
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    /// What `HEAD` reports about the stored object.
    struct RemoteState: Sendable, Equatable {
        /// When the service says it last changed.
        var lastModified: Date?
        /// How large it is, when the service says.
        var byteCount: Int?
    }

    /// Builds and signs one request.
    ///
    /// Separated from performing it because this is the interesting half and the half worth
    /// asserting on: the tests build the exact three requests Shepherd makes and compare their
    /// `Authorization` headers against signatures computed independently.
    /// - Parameters:
    ///   - method: `GET`, `PUT` or `HEAD`.
    ///   - body: The body, for `PUT`.
    ///   - date: The request timestamp.
    /// - Returns: The signed request.
    /// - Throws: ``SettingsSyncError/invalidEndpoint`` when the location cannot produce a URL, or
    ///   ``SettingsSyncError/credentialsMissing`` when a key half is empty.
    func signedRequest(method: String, body: Data?, date: Date) throws -> S3ObjectRequest {
        guard credentials.isComplete else { throw SettingsSyncError.credentialsMissing }
        guard let url = location.url else { throw SettingsSyncError.invalidEndpoint }

        let payload = body ?? Data()
        let payloadHash = body == nil
            ? SigV4Signer.emptyPayloadHash
            : SigV4Signer.hexSHA256(payload)

        var headers: [String: String] = [
            "host": location.host,
            SigV4Signer.dateHeader: SigV4Signer.amzDate(date),
            SigV4Signer.contentSHA256Header: payloadHash,
        ]
        if body != nil {
            headers["content-type"] = "application/json"
        }

        let signer = SigV4Signer(credentials: credentials, region: location.region)
        let description = SigV4Signer.Request(
            method: method,
            path: location.path,
            headers: headers,
            payloadHash: payloadHash
        )
        headers["authorization"] = signer.authorizationHeader(description, at: date)

        return S3ObjectRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: S3ObjectClient.timeout
        )
    }

    /// Downloads the object.
    /// - Returns: The body and when the service says it changed.
    /// - Throws: ``SettingsSyncError/noRemoteDocument`` on 404, or
    ///   ``SettingsSyncError/remoteRejected(status:message:)``.
    func get() async throws -> (body: Data, lastModified: Date?) {
        let request = try signedRequest(method: "GET", body: nil, date: now())
        let response = try await transport.perform(request)
        guard response.isSuccess else { throw S3ObjectClient.failure(response) }
        return (response.body, response.lastModified)
    }

    /// Uploads the object, replacing whatever was there.
    /// - Parameter body: The envelope JSON.
    /// - Throws: ``SettingsSyncError/remoteRejected(status:message:)``.
    func put(_ body: Data) async throws {
        let request = try signedRequest(method: "PUT", body: body, date: now())
        let response = try await transport.perform(request)
        guard response.isSuccess else { throw S3ObjectClient.failure(response) }
    }

    /// Asks whether the object exists and when it last changed.
    /// - Returns: The remote state, or `nil` when nothing has been uploaded yet.
    /// - Throws: ``SettingsSyncError/remoteRejected(status:message:)`` for anything other than a
    ///   404.
    func head() async throws -> RemoteState? {
        let request = try signedRequest(method: "HEAD", body: nil, date: now())
        let response = try await transport.perform(request)
        if response.status == 404 { return nil }
        guard response.isSuccess else { throw S3ObjectClient.failure(response) }
        return RemoteState(
            lastModified: response.lastModified,
            byteCount: response.contentLength
        )
    }

    /// Maps a non-2xx answer onto an error a user can act on.
    ///
    /// 403 is special-cased because it is the one a misconfiguration actually produces, and
    /// because S3's own message for it ("SignatureDoesNotMatch", "AccessDenied") is genuinely
    /// the most useful thing to show.
    private static func failure(_ response: S3ObjectResponse) -> SettingsSyncError {
        if response.status == 404 { return .noRemoteDocument }
        return .remoteRejected(status: response.status, message: response.errorMessage)
    }
}
