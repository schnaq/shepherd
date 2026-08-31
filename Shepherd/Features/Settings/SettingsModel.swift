import Foundation
import Observation
import ShepherdCore

/// Backs the Settings window's stateful tabs (agents registry, AI keys, connection tests).
@MainActor
@Observable
final class SettingsModel {
    /// The result of the last "Test connection" run.
    enum TestState: Equatable {
        /// Not run yet.
        case idle
        /// Running.
        case running
        /// The endpoint answered.
        case success(String)
        /// The endpoint refused or could not be reached.
        case failure(String)
    }

    /// The bundled, read-only agent registry (ADR 0008).
    private(set) var bundledAgents: [AgentRegistryEntry] = []
    /// The user's registry extensions, stored in `agent_registry_overrides`.
    private(set) var overrides: [AgentRegistryEntry] = []
    /// The last registry error, if loading failed.
    private(set) var registryError: String?

    /// The API key currently in the editor. Loaded from and written to the Keychain only.
    var apiKeyField = ""
    /// Whether the key field holds a value that came from the Keychain.
    private(set) var hasStoredKey = false
    /// The connection-test state.
    private(set) var testState: TestState = .idle

    /// Draft fields for a new agent-registry entry.
    var newAgentID = ""
    /// The new entry's display name.
    var newAgentName = ""
    /// Comma-separated login patterns.
    var newAgentLogins = ""
    /// Comma-separated branch prefixes.
    var newAgentBranches = ""
    /// Comma-separated commit trailers.
    var newAgentTrailers = ""

    /// Creates the model.
    init() {}

    // MARK: - Agent registry

    /// Loads the bundled registry and the user's overrides.
    /// - Parameter session: The signed-in session, when there is one (overrides live in its
    ///   database).
    func loadRegistry(session: SignedInSession?) async {
        do {
            bundledAgents = try AgentRegistry.bundled().agents
        } catch {
            registryError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        guard let session else { return }
        overrides = (try? await session.database.agentRegistryOverrides()) ?? []
    }

    /// Adds the entry currently in the draft fields.
    /// - Parameter session: The signed-in session.
    /// - Returns: An error message when the entry is not valid.
    @discardableResult
    func addOverride(session: SignedInSession?) async -> String? {
        guard let session else { return String(localized: "Sign in first.") }
        let id = newAgentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return String(localized: "An id is required.") }
        let name = newAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = AgentRegistryEntry(
            id: id,
            displayName: name.isEmpty ? id : name,
            loginPatterns: SettingsModel.split(newAgentLogins),
            branchPrefixes: SettingsModel.split(newAgentBranches),
            commitTrailers: SettingsModel.split(newAgentTrailers)
        )
        do {
            try await session.database.saveAgentRegistryOverride(entry)
            overrides = (try? await session.database.agentRegistryOverrides()) ?? overrides
            newAgentID = ""
            newAgentName = ""
            newAgentLogins = ""
            newAgentBranches = ""
            newAgentTrailers = ""
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Removes one override.
    /// - Parameters:
    ///   - id: The entry's id.
    ///   - session: The signed-in session.
    func removeOverride(id: String, session: SignedInSession?) async {
        guard let session else { return }
        try? await session.database.deleteAgentRegistryOverride(id: id)
        overrides = (try? await session.database.agentRegistryOverrides()) ?? overrides
    }

    private static func split(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - API keys

    /// Loads the stored key for the selected provider into the editor.
    /// - Parameters:
    ///   - kind: Which provider's key to load.
    ///   - store: The Keychain secret store.
    func loadKey(kind: CloudProviderKind, store: KeychainSecretStore) {
        let key = SettingsModel.keychainKey(for: kind)
        let stored = (try? store.secret(for: key)) ?? nil
        hasStoredKey = !(stored ?? "").isEmpty
        apiKeyField = stored ?? ""
        testState = .idle
    }

    /// Writes the editor's key to the Keychain (or removes it when empty).
    /// - Parameters:
    ///   - kind: Which provider's key to write.
    ///   - store: The Keychain secret store.
    /// - Returns: An error message on failure.
    @discardableResult
    func saveKey(kind: CloudProviderKind, store: KeychainSecretStore) -> String? {
        do {
            try store.setSecret(apiKeyField, for: SettingsModel.keychainKey(for: kind))
            hasStoredKey = !apiKeyField.isEmpty
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The Keychain account name for a provider kind.
    static func keychainKey(for kind: CloudProviderKind) -> String {
        switch kind {
        case .anthropic: return KeychainSecretStore.Key.anthropicAPIKey
        case .openAICompatible: return KeychainSecretStore.Key.openAICompatibleAPIKey
        }
    }

    // MARK: - Connection test

    /// Sends a one-token request to the configured endpoint and reports what came back.
    /// - Parameter settings: The current preferences.
    func testConnection(settings: AppSettings) async {
        testState = .running
        let probeSystem = "You are a connection test. Answer with the single word: ok."
        let probeUser = "Reply with: ok"
        do {
            switch settings.cloudProviderKind {
            case .anthropic:
                let provider = AnthropicProvider(
                    apiKey: apiKeyField,
                    model: settings.anthropicModel
                )
                let answer = try await provider.complete(system: probeSystem, user: probeUser)
                testState = .success(String(localized: "Answered: \(String(answer.prefix(60)))"))
            case .openAICompatible:
                let provider = OpenAICompatibleProvider(
                    baseURL: settings.openAICompatibleBaseURL,
                    model: settings.openAICompatibleModel,
                    apiKey: apiKeyField
                )
                let answer = try await provider.complete(system: probeSystem, user: probeUser)
                testState = .success(String(localized: "Answered: \(String(answer.prefix(60)))"))
            }
        } catch {
            testState = .failure(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}
