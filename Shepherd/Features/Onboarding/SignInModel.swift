import AppKit
import Foundation
import GitHubKit
import Observation
import ShepherdCore

/// Drives the sign-in screen: device flow (ADR 0004's primary path) and the PAT fallback.
@MainActor
@Observable
final class SignInModel {
    /// Which path the user is on.
    enum Step: Equatable {
        /// Nothing started yet.
        case idle
        /// A device code has been issued and is being polled.
        case awaitingDeviceApproval
        /// A credential is being verified against `GET /user`.
        case verifying
    }

    /// The current step.
    private(set) var step: Step = .idle
    /// The issued device grant, shown to the user.
    private(set) var grant: DeviceCodeGrant?
    /// The last failure, shown inline under the buttons.
    var errorMessage: String?
    /// The personal access token being typed.
    var patText = ""
    /// Whether the user code was just copied (drives the button's checkmark).
    private(set) var didCopyCode = false

    private var flowTask: Task<Void, Never>?
    private let transport: any HTTPTransport

    /// Creates the model.
    /// - Parameter transport: The HTTP transport. Injectable for tests.
    init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Whether the device-flow button can be offered at all.
    var isDeviceFlowConfigured: Bool { AppConfig.isDeviceFlowConfigured }

    /// Whether any network work is in flight.
    var isBusy: Bool { step != .idle }

    // MARK: - Device flow

    /// Requests a device code and polls until the user approves it.
    /// - Parameter environment: The app container, which stores the resulting credential.
    func startDeviceFlow(environment: AppEnvironment) {
        guard isDeviceFlowConfigured else {
            errorMessage = String(
                localized: "This build has no GitHub App client ID. Use a personal access token."
            )
            return
        }
        guard flowTask == nil else { return }
        errorMessage = nil
        step = .awaitingDeviceApproval

        let authenticator = DeviceFlowAuthenticator(
            clientID: AppConfig.githubAppClientID,
            transport: transport
        )
        flowTask = Task { [weak self] in
            guard let self else { return }
            do {
                let grant = try await authenticator.requestDeviceCode()
                self.grant = grant
                let token = try await authenticator.pollForToken(grant)
                self.step = .verifying
                let identity = try await Self.fetchViewer(
                    accessToken: token.accessToken,
                    transport: self.transport
                )
                await environment.signIn(
                    account: Account(
                        login: identity.login,
                        avatarURL: identity.avatarURL,
                        authKind: .deviceFlow
                    ),
                    token: token
                )
                self.reset()
            } catch {
                self.fail(with: error)
            }
        }
    }

    /// Cancels an in-flight device flow.
    func cancelDeviceFlow() {
        flowTask?.cancel()
        flowTask = nil
        grant = nil
        step = .idle
    }

    /// Copies the user code to the pasteboard.
    func copyUserCode() {
        guard let code = grant?.userCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopyCode = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.didCopyCode = false
        }
    }

    /// Opens `github.com/login/device` in the default browser.
    func openVerificationPage() {
        guard let url = grant?.verificationURI else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Personal access token

    /// Validates a pasted token against `GET /user` and signs in on success.
    /// - Parameter environment: The app container.
    func submitPersonalAccessToken(environment: AppEnvironment) {
        let token = patText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = String(localized: "Paste a token first.")
            return
        }
        guard flowTask == nil else { return }
        errorMessage = nil
        step = .verifying

        flowTask = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try await Self.fetchViewer(
                    accessToken: token,
                    transport: self.transport
                )
                await environment.signIn(
                    account: Account(
                        login: identity.login,
                        avatarURL: identity.avatarURL,
                        authKind: .pat
                    ),
                    token: TokenSet(accessToken: token)
                )
                self.patText = ""
                self.reset()
            } catch {
                self.fail(with: error)
            }
        }
    }

    // MARK: - Shared

    /// The signed-in user's identity, as `GET /user` reports it.
    struct ViewerIdentity: Sendable, Hashable {
        /// The GitHub login.
        var login: String
        /// The avatar, if any.
        var avatarURL: URL?
    }

    /// Reads `GET /user` with a bearer token.
    ///
    /// `GitHubClient` deliberately has no "who am I" call — the sweep uses `@me` in search
    /// queries — so sign-in asks for it directly through the same transport abstraction.
    /// - Parameters:
    ///   - accessToken: The credential to test.
    ///   - transport: The HTTP transport.
    /// - Returns: The identity behind the token.
    static func fetchViewer(
        accessToken: String,
        transport: any HTTPTransport
    ) async throws -> ViewerIdentity {
        guard let url = URL(string: "https://api.github.com/user") else {
            throw GitHubError.invalidURL("https://api.github.com/user")
        }
        let response = try await transport.data(
            for: HTTPRequest(
                method: "GET",
                url: url,
                headers: [
                    "Accept": "application/vnd.github+json",
                    "Authorization": "Bearer \(accessToken)",
                    "User-Agent": GitHubDefaultURL.userAgent,
                    "X-GitHub-Api-Version": "2022-11-28",
                ]
            )
        )
        guard response.isSuccess else {
            if response.statusCode == 401 { throw GitHubError.unauthorized }
            throw GitHubError.server(
                status: response.statusCode,
                message: String(decoding: response.body, as: UTF8.self).prefix(200).description
            )
        }
        struct Payload: Decodable {
            var login: String
            var avatarURL: URL?

            enum CodingKeys: String, CodingKey {
                case login
                case avatarURL = "avatar_url"
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: response.body) else {
            throw GitHubError.decoding(message: "GET /user did not return a login")
        }
        return ViewerIdentity(login: payload.login, avatarURL: payload.avatarURL)
    }

    private func fail(with error: any Error) {
        flowTask = nil
        grant = nil
        step = .idle
        if error is CancellationError { return }
        errorMessage = error.userFacingDescription
    }

    private func reset() {
        flowTask = nil
        grant = nil
        step = .idle
    }
}
