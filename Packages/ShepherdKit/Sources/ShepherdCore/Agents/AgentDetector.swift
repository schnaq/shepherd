import Foundation

/// The raw author information Shepherd gets from the GitHub API, before provenance is decided.
public struct AuthorSignal: Sendable, Codable, Hashable {
    /// The author login, e.g. `"claude[bot]"`.
    public var login: String
    /// Whether the API reported this account as a bot (`user.type == "Bot"` in REST,
    /// `author.__typename == "Bot"` in GraphQL). Authoritative for ``ActorKind/bot``.
    public var isBotAccount: Bool
    /// The account display name, when GitHub exposes one.
    public var displayName: String?
    /// The account avatar.
    public var avatarURL: URL?

    /// Creates an author signal.
    /// - Parameters:
    ///   - login: The author login.
    ///   - isBotAccount: Whether the API reported the account as a bot.
    ///   - displayName: The account display name, if known.
    ///   - avatarURL: The account avatar, if known.
    public init(
        login: String,
        isBotAccount: Bool = false,
        displayName: String? = nil,
        avatarURL: URL? = nil
    ) {
        self.login = login
        self.isBotAccount = isBotAccount
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

/// Decides whether a pull request was authored by a human, a plain bot, or a known coding
/// agent (ADR 0008).
///
/// The rules, in order:
///
/// 1. A registry match on the author **login** wins and produces ``ActorKind/agent(_:)``.
/// 2. Otherwise a registry match on the **head branch prefix** produces an agent — this is
///    how agent runs made with a human's token (`claude/fix-login`) are still labelled.
/// 3. Otherwise a registry match on a **commit trailer** produces an agent.
/// 4. Otherwise, if the API said the account is a bot, the author is a ``ActorKind/bot``.
/// 5. Otherwise the author is a ``ActorKind/human``.
///
/// Detection is pure and deterministic: the same inputs always give the same answer, and
/// misdetection is cosmetic — provenance never drives an automated review action.
public struct AgentDetector: Sendable {
    /// The registry this detector matches against.
    public let registry: AgentRegistry
    private let compiledEntries: [CompiledEntry]

    private struct CompiledEntry: Sendable {
        let id: String
        let displayName: String
        let loginPatterns: [GlobPattern]
        let branchPrefixes: [String]
        let commitTrailers: [String]
    }

    /// Creates a detector for an explicit registry.
    /// - Parameter registry: The registry to match against.
    public init(registry: AgentRegistry) {
        self.registry = registry
        self.compiledEntries = registry.agents.map { entry in
            CompiledEntry(
                id: entry.id,
                displayName: entry.displayName,
                loginPatterns: entry.loginPatterns.map(GlobPattern.init),
                branchPrefixes: entry.branchPrefixes.map { $0.lowercased() },
                commitTrailers: entry.commitTrailers.map { $0.lowercased() }
            )
        }
    }

    /// Creates a detector from the bundled registry plus user extensions.
    /// - Parameter extensions: User-supplied registry entries; entries with a bundled id
    ///   replace the bundled entry.
    /// - Throws: ``AgentRegistryError`` when the bundled registry cannot be loaded.
    public init(extensions: [AgentRegistryEntry] = []) throws {
        let bundled = try AgentRegistry.bundled()
        self.init(registry: bundled.merging(extensions: extensions))
    }

    /// Classifies an author.
    /// - Parameters:
    ///   - author: The raw author information from the API.
    ///   - branchName: The pull request's head branch name, when known.
    ///   - commitTrailers: Trailer lines collected from the pull request's commits.
    /// - Returns: The detected provenance.
    public func detect(
        author: AuthorSignal,
        branchName: String? = nil,
        commitTrailers: [String] = []
    ) -> ActorKind {
        let login = author.login.lowercased()
        for entry in compiledEntries {
            for pattern in entry.loginPatterns where pattern.matches(login) {
                return .agent(
                    AgentIdentity(id: entry.id, displayName: entry.displayName, matchedBy: .login)
                )
            }
        }

        if let branchName, !branchName.isEmpty {
            let branch = branchName.lowercased()
            for entry in compiledEntries {
                for prefix in entry.branchPrefixes where !prefix.isEmpty && branch.hasPrefix(prefix) {
                    return .agent(
                        AgentIdentity(
                            id: entry.id,
                            displayName: entry.displayName,
                            matchedBy: .branchPrefix
                        )
                    )
                }
            }
        }

        if !commitTrailers.isEmpty {
            let trailers = commitTrailers.map { $0.lowercased() }
            for entry in compiledEntries {
                for trailer in entry.commitTrailers where !trailer.isEmpty {
                    if trailers.contains(where: { $0.hasPrefix(trailer) }) {
                        return .agent(
                            AgentIdentity(
                                id: entry.id,
                                displayName: entry.displayName,
                                matchedBy: .commitTrailer
                            )
                        )
                    }
                }
            }
        }

        return author.isBotAccount ? .bot : .human
    }

    /// Classifies an author and wraps the result in an ``Actor``.
    /// - Parameters:
    ///   - author: The raw author information from the API.
    ///   - branchName: The pull request's head branch name, when known.
    ///   - commitTrailers: Trailer lines collected from the pull request's commits.
    /// - Returns: A fully populated actor.
    public func resolveActor(
        author: AuthorSignal,
        branchName: String? = nil,
        commitTrailers: [String] = []
    ) -> Actor {
        Actor(
            login: author.login,
            displayName: author.displayName,
            avatarURL: author.avatarURL,
            kind: detect(author: author, branchName: branchName, commitTrailers: commitTrailers)
        )
    }
}
