import Foundation
import Observation
import ShepherdCore

/// Backs the Settings window's stateful tabs (agents registry, AI keys, connection tests).
@MainActor
@Observable
final class SettingsModel {
    /// The result of the last "Load models" run against an OpenAI-compatible endpoint.
    enum ModelListState: Equatable {
        /// Not asked yet, or invalidated because the endpoint changed.
        case idle
        /// Fetching.
        case loading
        /// The endpoint listed these model ids.
        case loaded([String])
        /// The list could not be fetched; the free-text model field stays in charge.
        case failed(String)
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
    private(set) var testState: AsyncActionState = .idle
    /// The model-discovery state.
    private(set) var modelListState: ModelListState = .idle

    /// The webhook signing secret currently in the editor (ADR 0012).
    ///
    /// Like ``apiKeyField``, it exists only here and in the Keychain — never in `UserDefaults`.
    var webhookSecretField = ""
    /// Whether the Keychain holds a webhook secret.
    private(set) var hasStoredWebhookSecret = false
    /// The result of the last "Send test event" run.
    private(set) var webhookTestState: AsyncActionState = .idle

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
        modelListState = .idle
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

    // MARK: - Webhook secret and test delivery (ADR 0012)

    /// Loads the stored webhook secret into the editor.
    /// - Parameter store: The Keychain secret store.
    func loadWebhookSecret(store: KeychainSecretStore) {
        let stored = (try? store.secret(for: KeychainSecretStore.Key.webhookSecret)) ?? nil
        hasStoredWebhookSecret = !(stored ?? "").isEmpty
        webhookSecretField = stored ?? ""
        webhookTestState = .idle
    }

    /// Writes the editor's webhook secret to the Keychain (or removes it when empty).
    /// - Parameter store: The Keychain secret store.
    /// - Returns: An error message on failure.
    @discardableResult
    func saveWebhookSecret(store: KeychainSecretStore) -> String? {
        do {
            try store.setSecret(webhookSecretField, for: KeychainSecretStore.Key.webhookSecret)
            hasStoredWebhookSecret = !webhookSecretField.isEmpty
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Posts one test event to the configured URL and reports what came back.
    ///
    /// The secret in the editor is used rather than the stored one, so a freshly pasted secret
    /// can be verified before it is saved — the same courtesy the model picker extends to keys.
    /// - Parameter coordinator: The webhook coordinator.
    func sendTestWebhook(coordinator: WebhookCoordinator) async {
        webhookTestState = .running
        do {
            try await coordinator.sendTestEvent(secret: webhookSecretField)
            webhookTestState = .success(String(localized: "The webhook accepted the test event."))
        } catch {
            webhookTestState = .failure(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
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

    // MARK: - Model discovery

    /// Whether `GET {base}/models` can be attempted with what is in the fields right now.
    /// - Parameter settings: The current preferences.
    /// - Returns: `true` when the endpoint is OpenAI-compatible, its base URL is usable, and a
    ///   key is either present or not expected by the selected preset.
    func canLoadModels(settings: AppSettings) -> Bool {
        guard settings.cloudProviderKind == .openAICompatible,
              OpenAICompatibleProvider.modelsURL(base: settings.openAICompatibleBaseURL) != nil
        else { return false }
        return !apiKeyField.isEmpty || settings.openAICompatiblePreset.allowsKeylessDiscovery
    }

    /// Fetches the endpoint's model list so the model field can become a picker.
    ///
    /// The key in the editor is used rather than the stored one, so a freshly pasted key works
    /// before it is saved. A failure is not fatal anywhere: the free-text model field remains.
    /// - Parameter settings: The current preferences.
    func loadModels(settings: AppSettings) async {
        await loadModels(
            settings: settings,
            from: OpenAICompatibleProvider(
                baseURL: settings.openAICompatibleBaseURL,
                model: settings.openAICompatibleModel,
                apiKey: apiKeyField
            )
        )
    }

    /// The half of discovery that does not care where the list came from.
    /// - Parameters:
    ///   - settings: The current preferences.
    ///   - lister: The endpoint to ask; the tests pass a stub instead of a network call.
    func loadModels(settings: AppSettings, from lister: any ModelListing) async {
        guard settings.cloudProviderKind == .openAICompatible else { return }
        modelListState = .loading
        do {
            let models = try await lister.availableModels()
            modelListState = .loaded(models)
            // Only ever *offer* a model; an existing choice is never overwritten.
            let configured = settings.openAICompatibleModel
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if configured.isEmpty, let first = models.first {
                settings.openAICompatibleModel = first
            }
        } catch {
            modelListState = .failed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    /// Loads the model list on its own for a configuration that is already complete.
    ///
    /// Deliberately narrow: it only fires when a key came out of the Keychain (or the preset
    /// needs none), so opening Settings never sends a request for a half-typed endpoint.
    /// - Parameter settings: The current preferences.
    func loadModelsIfConfigured(settings: AppSettings) async {
        guard settings.intelligenceMode == .onDeviceAndCloud,
              modelListState == .idle,
              canLoadModels(settings: settings),
              hasStoredKey || settings.openAICompatiblePreset.allowsKeylessDiscovery
        else { return }
        await loadModels(settings: settings)
    }

    /// Drops a loaded list, returning the model field to free text.
    ///
    /// Called when the endpoint changes — a list from the previous endpoint would offer models
    /// the new one does not have.
    func forgetLoadedModels() {
        modelListState = .idle
    }

    /// The model ids to offer in the picker.
    /// - Parameter selected: The model currently configured.
    /// - Returns: The loaded ids, with `selected` prepended when the endpoint did not list it;
    ///   an empty array when the free-text field should be shown instead.
    func modelOptions(selected: String) -> [String] {
        guard case .loaded(let models) = modelListState, !models.isEmpty else { return [] }
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !models.contains(trimmed) else { return models }
        return [trimmed] + models
    }
}
