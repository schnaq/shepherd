import Foundation

/// How a signed-in account authenticates against GitHub (see ADR 0004).
public enum AuthKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// GitHub App user-to-server token obtained through the OAuth device flow.
    case deviceFlow
    /// A fine-grained personal access token pasted by the user.
    case pat
}

/// A GitHub account Shepherd is signed in as.
///
/// Tokens are deliberately *not* part of this model: they live in the Keychain only
/// (ADR 0004), keyed by ``login``.
public struct Account: Sendable, Codable, Hashable, Identifiable {
    /// The GitHub login of the signed-in user, e.g. `"octocat"`.
    public let login: String
    /// The account's avatar, if GitHub reported one.
    public let avatarURL: URL?
    /// How this account authenticates.
    public let authKind: AuthKind

    /// Creates an account.
    /// - Parameters:
    ///   - login: The GitHub login.
    ///   - avatarURL: The avatar URL reported by GitHub, if any.
    ///   - authKind: How the account authenticates.
    public init(login: String, avatarURL: URL? = nil, authKind: AuthKind) {
        self.login = login
        self.avatarURL = avatarURL
        self.authKind = authKind
    }

    /// `Account` is identified by its ``login``.
    public var id: String { login }
}
