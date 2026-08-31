import Foundation
import ShepherdCore

/// The device-code grant GitHub hands out at the start of the device flow.
///
/// The user is shown ``userCode`` and sent to ``verificationURI``; Shepherd polls in the
/// background until they approve or the code expires (ADR 0004).
public struct DeviceCodeGrant: Sendable, Hashable {
    /// The opaque device code Shepherd polls with. Never shown to the user.
    public var deviceCode: String
    /// The short code the user types into GitHub, e.g. `"WDJB-MJHT"`.
    public var userCode: String
    /// Where the user should enter ``userCode``.
    public var verificationURI: URL
    /// How long the grant is valid for, in seconds.
    public var expiresIn: TimeInterval
    /// The minimum number of seconds between two polls, as requested by GitHub.
    public var interval: TimeInterval
    /// When the grant was issued, used to compute the deadline.
    public var issuedAt: Date

    /// Creates a grant.
    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        expiresIn: TimeInterval,
        interval: TimeInterval,
        issuedAt: Date = Date()
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresIn = expiresIn
        self.interval = interval
        self.issuedAt = issuedAt
    }

    /// The moment after which the grant can no longer be redeemed.
    public var expiresAt: Date { issuedAt.addingTimeInterval(expiresIn) }
}

// MARK: - Wire shapes

/// The `POST /login/device/code` response.
struct DeviceCodeResponseDTO: Decodable {
    var deviceCode: String?
    var userCode: String?
    var verificationUri: String?
    var expiresIn: Double?
    var interval: Double?
    var error: String?
    var errorDescription: String?
}

/// The `POST /login/oauth/access_token` response, for both the device-flow and the
/// refresh-token grant.
struct AccessTokenResponseDTO: Decodable {
    var accessToken: String?
    var tokenType: String?
    var scope: String?
    var expiresIn: Double?
    var refreshToken: String?
    var refreshTokenExpiresIn: Double?
    var interval: Double?
    var error: String?
    var errorDescription: String?
}

/// Runs GitHub's OAuth **device flow** — the sign-in path that needs no client secret and so
/// is the only honest option for an open-source desktop app (ADR 0004).
///
/// Usage:
/// ```swift
/// let grant = try await authenticator.requestDeviceCode()
/// show(grant.userCode, grant.verificationURI)      // native UI
/// let tokens = try await authenticator.pollForToken(grant)
/// ```
/// or ``authenticate(scopes:presentation:)`` to do both in one call.
public struct DeviceFlowAuthenticator: Sendable {
    private let clientID: String
    private let transport: any HTTPTransport
    private let sleeper: any Sleeping
    private let webBaseURL: URL
    private let now: @Sendable () -> Date
    private let userAgent: String

    /// Creates an authenticator.
    /// - Parameters:
    ///   - clientID: The GitHub App's public client ID.
    ///   - transport: The HTTP transport to use.
    ///   - sleeper: The delay abstraction; tests inject one that does not wait.
    ///   - webBaseURL: The `github.com` base URL (overridable for GitHub Enterprise Server).
    ///   - userAgent: The `User-Agent` header value.
    ///   - now: Clock injection point for tests.
    public init(
        clientID: String,
        transport: any HTTPTransport,
        sleeper: any Sleeping = SystemSleeper(),
        webBaseURL: URL = GitHubDefaultURL.web,
        userAgent: String = GitHubDefaultURL.userAgent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientID = clientID
        self.transport = transport
        self.sleeper = sleeper
        self.webBaseURL = webBaseURL
        self.userAgent = userAgent
        self.now = now
    }

    /// Requests a device code.
    /// - Parameter scopes: OAuth scopes to request. GitHub Apps derive permissions from the
    ///   installation and ignore this, so it defaults to empty.
    /// - Returns: The grant to show to the user and poll with.
    /// - Throws: ``GitHubError`` when GitHub rejects the request.
    public func requestDeviceCode(scopes: [String] = []) async throws -> DeviceCodeGrant {
        var fields = [("client_id", clientID)]
        if !scopes.isEmpty {
            fields.append(("scope", scopes.joined(separator: " ")))
        }
        let response = try await post(path: "/login/device/code", fields: fields)
        let payload: DeviceCodeResponseDTO = try AuthJSON.decode(response.body)

        if let error = payload.error {
            throw Self.mapDeviceFlowError(code: error, description: payload.errorDescription)
        }
        guard let deviceCode = payload.deviceCode,
              let userCode = payload.userCode,
              let verificationString = payload.verificationUri,
              let verificationURI = URL(string: verificationString)
        else {
            throw GitHubError.decoding(message: "Device code response was missing required fields")
        }
        return DeviceCodeGrant(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            expiresIn: payload.expiresIn ?? 900,
            interval: payload.interval ?? 5,
            issuedAt: now()
        )
    }

    /// Polls until the user approves the grant, GitHub refuses, or the grant expires.
    ///
    /// Honours GitHub's `interval`, backs off by five seconds on every `slow_down`, and stops
    /// at ``DeviceCodeGrant/expiresAt``.
    /// - Parameter grant: The grant returned by ``requestDeviceCode(scopes:)``.
    /// - Returns: The issued credential.
    /// - Throws: ``GitHubError/deviceFlowExpired`` when the code times out,
    ///   ``GitHubError/deviceFlowDenied`` when the user says no.
    public func pollForToken(_ grant: DeviceCodeGrant) async throws -> TokenSet {
        var interval = max(1, grant.interval)
        let deadline = grant.expiresAt

        while true {
            if now() >= deadline {
                throw GitHubError.deviceFlowExpired
            }
            try await sleeper.sleep(for: .seconds(interval))
            if now() >= deadline {
                throw GitHubError.deviceFlowExpired
            }

            let response = try await post(
                path: "/login/oauth/access_token",
                fields: [
                    ("client_id", clientID),
                    ("device_code", grant.deviceCode),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ]
            )
            let payload: AccessTokenResponseDTO = try AuthJSON.decode(response.body)

            if let error = payload.error {
                switch error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    // GitHub's documented behaviour: add five seconds to the poll interval.
                    if let suggested = payload.interval {
                        interval = max(interval + 5, suggested)
                    } else {
                        interval += 5
                    }
                    continue
                default:
                    throw Self.mapDeviceFlowError(code: error, description: payload.errorDescription)
                }
            }
            return try Self.tokenSet(from: payload, now: now())
        }
    }

    /// Runs the whole flow: request a code, hand it to the UI, poll until it is approved.
    /// - Parameters:
    ///   - scopes: OAuth scopes to request.
    ///   - presentation: Called once with the grant so the app can show the user code, before
    ///     polling starts.
    /// - Returns: The issued credential.
    public func authenticate(
        scopes: [String] = [],
        presentation: @Sendable (DeviceCodeGrant) -> Void
    ) async throws -> TokenSet {
        let grant = try await requestDeviceCode(scopes: scopes)
        presentation(grant)
        return try await pollForToken(grant)
    }

    // MARK: - Shared helpers

    private func post(path: String, fields: [(String, String)]) async throws -> HTTPResponse {
        guard let url = URL(string: path, relativeTo: webBaseURL)?.absoluteURL else {
            throw GitHubError.invalidURL(webBaseURL.absoluteString + path)
        }
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "User-Agent": userAgent,
            ],
            body: Data(FormEncoding.encode(fields).utf8)
        )
        let response = try await transport.data(for: request)
        guard response.isSuccess else {
            throw GitHubError.server(
                status: response.statusCode,
                message: String(decoding: response.body, as: UTF8.self)
            )
        }
        return response
    }

    static func mapDeviceFlowError(code: String, description: String?) -> GitHubError {
        switch code {
        case "expired_token": return .deviceFlowExpired
        case "access_denied": return .deviceFlowDenied
        default: return .deviceFlowError(code: code, description: description)
        }
    }

    static func tokenSet(from payload: AccessTokenResponseDTO, now: Date) throws -> TokenSet {
        guard let accessToken = payload.accessToken, !accessToken.isEmpty else {
            throw GitHubError.decoding(message: "Token response was missing access_token")
        }
        let scopes = payload.scope?
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init) ?? []
        return TokenSet(
            accessToken: accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: payload.expiresIn.map { now.addingTimeInterval($0) },
            refreshTokenExpiresAt: payload.refreshTokenExpiresIn.map { now.addingTimeInterval($0) },
            scopes: scopes
        )
    }
}

/// Exchanges a GitHub App refresh token for a fresh ``TokenSet`` (ADR 0004).
///
/// Personal access tokens are not refreshable and never reach this type.
public struct TokenRefresher: Sendable {
    private let clientID: String
    private let transport: any HTTPTransport
    private let webBaseURL: URL
    private let userAgent: String
    private let now: @Sendable () -> Date

    /// Creates a refresher.
    /// - Parameters:
    ///   - clientID: The GitHub App's public client ID.
    ///   - transport: The HTTP transport to use.
    ///   - webBaseURL: The `github.com` base URL.
    ///   - userAgent: The `User-Agent` header value.
    ///   - now: Clock injection point for tests.
    public init(
        clientID: String,
        transport: any HTTPTransport,
        webBaseURL: URL = GitHubDefaultURL.web,
        userAgent: String = GitHubDefaultURL.userAgent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientID = clientID
        self.transport = transport
        self.webBaseURL = webBaseURL
        self.userAgent = userAgent
        self.now = now
    }

    /// Exchanges a refresh token for a new credential.
    /// - Parameter refreshToken: The refresh token from the previous ``TokenSet``.
    /// - Returns: The renewed credential, including a new refresh token.
    /// - Throws: ``GitHubError/tokenRefreshFailed(message:)`` when GitHub refuses; the user
    ///   then has to sign in again.
    public func refresh(refreshToken: String) async throws -> TokenSet {
        guard let url = URL(string: "/login/oauth/access_token", relativeTo: webBaseURL)?
            .absoluteURL
        else {
            throw GitHubError.invalidURL(webBaseURL.absoluteString + "/login/oauth/access_token")
        }
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "User-Agent": userAgent,
            ],
            body: Data(
                FormEncoding.encode([
                    ("client_id", clientID),
                    ("grant_type", "refresh_token"),
                    ("refresh_token", refreshToken),
                ]).utf8
            )
        )
        let response = try await transport.data(for: request)
        guard response.isSuccess else {
            throw GitHubError.tokenRefreshFailed(
                message: String(decoding: response.body, as: UTF8.self)
            )
        }
        let payload: AccessTokenResponseDTO
        do {
            payload = try AuthJSON.decode(response.body)
        } catch {
            throw GitHubError.tokenRefreshFailed(message: String(describing: error))
        }
        if let error = payload.error {
            throw GitHubError.tokenRefreshFailed(message: payload.errorDescription ?? error)
        }
        do {
            return try DeviceFlowAuthenticator.tokenSet(from: payload, now: now())
        } catch {
            throw GitHubError.tokenRefreshFailed(message: String(describing: error))
        }
    }
}

/// JSON decoding for the two auth endpoints, which speak `snake_case`.
enum AuthJSON {
    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError.decoding(message: String(describing: error))
        }
    }
}

/// `application/x-www-form-urlencoded` encoding for the auth endpoints.
enum FormEncoding {
    /// Encodes ordered key/value pairs. Order is preserved so tests can assert on the body.
    static func encode(_ fields: [(String, String)]) -> String {
        fields
            .map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
    }

    /// The unreserved set from RFC 3986. Built per call rather than stored in a `static let`:
    /// `CharacterSet`'s `Sendable`-ness differs between Foundation implementations and this
    /// package must compile identically on macOS and Linux.
    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
