import Foundation

/// The signal that made ``AgentDetector`` classify an author as a coding agent.
///
/// Kept in the model so the UI can explain *why* a pull request is labelled the way it is —
/// misdetection must always be inspectable (ADR 0008).
public enum AgentMatchSignal: String, Sendable, Codable, Hashable, CaseIterable {
    /// The author login matched a registry login pattern.
    case login
    /// The head branch name started with a registry branch prefix.
    case branchPrefix
    /// A commit message trailer matched a registry trailer.
    case commitTrailer
}

/// A coding agent identified by ``AgentDetector``.
public struct AgentIdentity: Sendable, Codable, Hashable, Identifiable {
    /// Stable registry identifier, e.g. `"claude-code"`.
    public let id: String
    /// Human-readable name for badges and grouping headers, e.g. `"Claude Code"`.
    public let displayName: String
    /// Which detection signal matched.
    public let matchedBy: AgentMatchSignal

    /// Creates an agent identity.
    /// - Parameters:
    ///   - id: Stable registry identifier.
    ///   - displayName: Human-readable name.
    ///   - matchedBy: The signal that produced the match.
    public init(id: String, displayName: String, matchedBy: AgentMatchSignal) {
        self.id = id
        self.displayName = displayName
        self.matchedBy = matchedBy
    }
}

/// What kind of entity authored a pull request or comment.
///
/// `type == "Bot"` from the GitHub API is authoritative for ``bot``; a match in the agent
/// registry promotes an author to ``agent(_:)`` (ADR 0008).
public enum ActorKind: Sendable, Codable, Hashable {
    /// A human GitHub user.
    case human
    /// A bot account that is not a recognised coding agent.
    case bot
    /// A recognised coding agent.
    case agent(AgentIdentity)

    /// `true` for both ``bot`` and ``agent(_:)``.
    public var isMachine: Bool {
        switch self {
        case .human: return false
        case .bot, .agent: return true
        }
    }

    /// The matched agent identity, if any.
    public var agentIdentity: AgentIdentity? {
        if case .agent(let identity) = self { return identity }
        return nil
    }

    /// A short, stable English label, for tests, logs and model prompts.
    ///
    /// Not what the app shows: it cannot be localised here, so the app renders provenance itself
    /// (`ActorKind.localizedProvenanceLabel`, ADR 0022's 2026-09-22 amendment).
    public var provenanceLabel: String {
        switch self {
        case .human: return "People"
        case .bot: return "Bots"
        case .agent(let identity): return identity.displayName
        }
    }

    /// A stable key used to order and group provenance sections deterministically.
    ///
    /// Agents sort first (alphabetically by display name), then generic bots, then humans.
    public var provenanceSortKey: String {
        switch self {
        case .agent(let identity): return "0-\(identity.displayName.lowercased())"
        case .bot: return "1-bots"
        case .human: return "2-people"
        }
    }
}

/// A GitHub author: the person, bot or agent behind a pull request, commit or comment.
///
/// - Note: This type intentionally shadows the standard library's `Actor` protocol inside
///   ShepherdKit. The name is normative (see `docs/ARCHITECTURE.md`); ShepherdKit never uses
///   the standard library protocol by name, so the shadowing is unambiguous.
public struct Actor: Sendable, Codable, Hashable, Identifiable {
    /// The GitHub login, e.g. `"claude[bot]"`.
    public let login: String
    /// The account's display name, when GitHub exposes one.
    public let displayName: String?
    /// The account's avatar.
    public let avatarURL: URL?
    /// The detected provenance of this author.
    public let kind: ActorKind

    /// Creates an actor.
    /// - Parameters:
    ///   - login: The GitHub login.
    ///   - displayName: The account's display name, if known.
    ///   - avatarURL: The account's avatar, if known.
    ///   - kind: The detected provenance.
    public init(login: String, displayName: String? = nil, avatarURL: URL? = nil, kind: ActorKind) {
        self.login = login
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.kind = kind
    }

    /// `Actor` is identified by its ``login``.
    public var id: String { login }

    /// The best human-readable name for this actor: the display name if present, else the login.
    public var bestName: String { displayName ?? login }
}
