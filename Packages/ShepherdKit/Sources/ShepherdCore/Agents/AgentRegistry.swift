import Foundation

/// One entry of the agent registry: the signals that identify a single coding agent.
///
/// Entries come either from the bundled `agent-registry.json` or from user-supplied
/// extensions stored in the database (`agent_registry_overrides`).
public struct AgentRegistryEntry: Sendable, Codable, Hashable, Identifiable {
    /// Stable identifier, e.g. `"claude-code"`. Also the key user overrides replace.
    public let id: String
    /// Human-readable name shown on badges and section headers.
    public var displayName: String
    /// Login glob patterns (`*` and `?` wildcards, matched case-insensitively).
    public var loginPatterns: [String]
    /// Head-branch prefixes, matched case-insensitively, e.g. `"claude/"`.
    public var branchPrefixes: [String]
    /// Commit message trailers, matched case-insensitively as a prefix of the trailer line.
    public var commitTrailers: [String]

    /// Creates a registry entry.
    /// - Parameters:
    ///   - id: Stable identifier.
    ///   - displayName: Human-readable name.
    ///   - loginPatterns: Login glob patterns.
    ///   - branchPrefixes: Head-branch prefixes.
    ///   - commitTrailers: Commit message trailers.
    public init(
        id: String,
        displayName: String,
        loginPatterns: [String] = [],
        branchPrefixes: [String] = [],
        commitTrailers: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.loginPatterns = loginPatterns
        self.branchPrefixes = branchPrefixes
        self.commitTrailers = commitTrailers
    }
}

/// Something went wrong loading the agent registry.
public enum AgentRegistryError: Error, Sendable, Equatable {
    /// The bundled `agent-registry.json` resource could not be found in the module bundle.
    case bundledResourceMissing
    /// The registry JSON could not be decoded.
    case malformedRegistry(String)
}

/// The set of known coding agents, ordered by precedence.
///
/// Detection walks the entries in order, so earlier entries win ties. User extensions are
/// appended after the bundled defaults but *replace* a bundled entry with the same ``id``,
/// which is how a user can correct a wrong default without forking the file.
public struct AgentRegistry: Sendable, Codable, Hashable {
    /// The registry schema version of the bundled file.
    public var version: Int
    /// The entries, in precedence order.
    public var agents: [AgentRegistryEntry]

    /// Creates a registry.
    /// - Parameters:
    ///   - version: The registry schema version.
    ///   - agents: The entries, in precedence order.
    public init(version: Int = 1, agents: [AgentRegistryEntry]) {
        self.version = version
        self.agents = agents
    }

    /// An empty registry: every author is either a human or a plain bot.
    public static let empty = AgentRegistry(agents: [])

    /// Decodes a registry from JSON.
    /// - Parameter data: The JSON payload.
    /// - Throws: ``AgentRegistryError/malformedRegistry(_:)`` when decoding fails.
    public static func decode(from data: Data) throws -> AgentRegistry {
        do {
            return try JSONDecoder().decode(AgentRegistry.self, from: data)
        } catch {
            throw AgentRegistryError.malformedRegistry(String(describing: error))
        }
    }

    /// Loads the registry bundled with `ShepherdCore`.
    /// - Throws: ``AgentRegistryError`` when the resource is missing or malformed.
    public static func bundled() throws -> AgentRegistry {
        guard let url = Bundle.module.url(forResource: "agent-registry", withExtension: "json")
        else {
            throw AgentRegistryError.bundledResourceMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AgentRegistryError.malformedRegistry(String(describing: error))
        }
        return try decode(from: data)
    }

    /// Returns a copy of this registry with user extensions merged in.
    ///
    /// An extension with the same ``AgentRegistryEntry/id`` as a bundled entry replaces it in
    /// place, preserving precedence order; new ids are appended.
    /// - Parameter extensions: The user-supplied entries.
    public func merging(extensions: [AgentRegistryEntry]) -> AgentRegistry {
        guard !extensions.isEmpty else { return self }
        var merged = agents
        for entry in extensions {
            if let index = merged.firstIndex(where: { $0.id == entry.id }) {
                merged[index] = entry
            } else {
                merged.append(entry)
            }
        }
        return AgentRegistry(version: version, agents: merged)
    }
}
