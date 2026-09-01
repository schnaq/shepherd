import Foundation
import GitHubKit
import ShepherdCore

/// Turns this Mac's state into a document, and a document back into this Mac's state (ADR 0014).
///
/// The two directions are deliberately in one type and read as mirror images, because the failure
/// mode of a sync feature is a field that is captured but never applied (or the reverse). A
/// reviewer should be able to diff the two functions by eye.
///
/// Applying is *not* a merge. v1 is explicit about it: a download replaces the local settings
/// with the document's, because a field-by-field merge of two settings snapshots has no
/// meaningful conflict resolution — "which sweep interval did I mean?" has no answer a machine
/// can guess. The confirmation dialog in Settings is what makes that honest, and the one place
/// the rule is bent is secrets: an *absent* secret leaves this Mac's alone rather than deleting
/// it, so uploading from a Mac that never configured a webhook does not silently disarm the Mac
/// that did.
enum SettingsSyncApplier {
    /// What applying a document actually did, so Settings can say something true afterwards.
    struct Outcome: Sendable, Equatable {
        /// How many secrets were written to the Keychain.
        var secretsWritten: Int
        /// Whether the GitHub credential changed for an account other than the signed-in one —
        /// or arrived while signed out. Either way the session must be restarted before it is
        /// used, and Settings says so instead of pretending the swap was live.
        var needsSignInRestart: Bool
        /// Whether agent-registry extensions were carried but could not be applied because no
        /// database was available.
        var skippedAgentRegistry: Bool
        /// How many agent-registry extensions were applied.
        var agentOverridesApplied: Int

        /// Creates an outcome.
        init(
            secretsWritten: Int = 0,
            needsSignInRestart: Bool = false,
            skippedAgentRegistry: Bool = false,
            agentOverridesApplied: Int = 0
        ) {
            self.secretsWritten = secretsWritten
            self.needsSignInRestart = needsSignInRestart
            self.skippedAgentRegistry = skippedAgentRegistry
            self.agentOverridesApplied = agentOverridesApplied
        }
    }

    // MARK: - Capture

    /// Reads every setting and secret this Mac has into a document.
    /// - Parameter context: Where to read from.
    /// - Returns: The document to seal.
    @MainActor
    static func capture(context: SettingsSyncContext) async -> SyncedSettingsDocument {
        let settings = context.settings
        var overrides: [AgentRegistryEntry] = []
        if let reader = context.readAgentOverrides {
            overrides = await reader()
        }

        var document = SyncedSettingsDocument()
        document.sync = SyncedSettingsDocument.SyncGroup(
            sweepIntervalMinutes: settings.sweepIntervalMinutes
        )
        document.notifications = SyncedSettingsDocument.NotificationGroup(
            onReviewRequest: settings.notifyOnReviewRequest,
            onChecksFailed: settings.notifyOnChecksFailed,
            onDraftConflict: settings.notifyOnDraftConflict
        )
        document.agents = SyncedSettingsDocument.AgentsGroup(registryOverrides: overrides)
        document.intelligence = SyncedSettingsDocument.IntelligenceGroup(
            mode: settings.intelligenceMode,
            cloudProviderKind: settings.cloudProviderKind,
            anthropicModel: settings.anthropicModel,
            openAICompatiblePreset: settings.openAICompatiblePreset,
            openAICompatibleBaseURL: settings.openAICompatibleBaseURL,
            openAICompatibleModel: settings.openAICompatibleModel
        )
        document.delegation = SyncedSettingsDocument.DelegationGroup(
            agentCLI: settings.agentCLI,
            localCheckouts: settings.localCheckouts
        )
        document.automation = SyncedSettingsDocument.AutomationGroup(
            webhooksEnabled: settings.webhooksEnabled,
            webhookURL: settings.webhookURL,
            webhookEvents: settings.webhookEvents.map(\.rawValue).sorted()
        )
        document.appearance = SyncedSettingsDocument.AppearanceGroup(
            appearance: settings.appearance,
            inboxGroupBy: settings.groupBy,
            inboxSortOrder: settings.sortOrder,
            diffFontSize: settings.diffFontSize,
            diffWrapsLines: settings.diffWrapsLines,
            diffUsesInlineMode: settings.diffUsesInlineMode
        )
        document.triage = SyncedSettingsDocument.TriageGroup(
            defaultMergeMethod: settings.defaultMergeMethod
        )
        document.account = SyncedSettingsDocument.AccountGroup(
            login: settings.accountLogin,
            authKind: settings.accountLogin == nil ? nil : settings.accountAuthKind
        )
        document.secrets = await captureSecrets(context: context)
        return document
    }

    /// Reads the four secrets. Empty ones stay `nil` so they are absent from the document rather
    /// than present-and-blank, which is what makes "absent means leave it alone" work.
    @MainActor
    private static func captureSecrets(
        context: SettingsSyncContext
    ) async -> SyncedSettingsDocument.Secrets {
        var secrets = SyncedSettingsDocument.Secrets()
        secrets.anthropicKey = nonEmpty(
            context.storedSecret(KeychainSecretStore.Key.anthropicAPIKey)
        )
        secrets.openAICompatibleKey = nonEmpty(
            context.storedSecret(KeychainSecretStore.Key.openAICompatibleAPIKey)
        )
        secrets.webhookSecret = nonEmpty(
            context.storedSecret(KeychainSecretStore.Key.webhookSecret)
        )
        if let login = context.settings.accountLogin,
           let stored = try? await context.tokens.token(for: login) {
            // Only the access token travels. A device-flow *refresh* token is single-use and
            // rotates on every use (see `RefreshingTokenProvider`), so shipping a copy to a
            // second Mac would guarantee that one of the two Macs loses the race and has to
            // sign in again — worse than simply signing in once on the new Mac.
            secrets.githubToken = nonEmpty(stored.accessToken)
        }
        return secrets
    }

    // MARK: - Apply

    /// Writes a document's contents into this Mac.
    ///
    /// Order matters exactly once: the non-secret settings are written first and the secrets
    /// second, so a Keychain prompt that the user cancels leaves the *visible* settings already
    /// consistent with what the status line will claim.
    /// - Parameters:
    ///   - document: The decrypted document.
    ///   - context: Where to write to.
    /// - Returns: What was done, for the status line.
    @MainActor
    static func apply(
        _ document: SyncedSettingsDocument,
        context: SettingsSyncContext
    ) async -> Outcome {
        let settings = context.settings
        var outcome = Outcome()

        settings.sweepIntervalMinutes = document.sync.sweepIntervalMinutes
        settings.notifyOnReviewRequest = document.notifications.onReviewRequest
        settings.notifyOnChecksFailed = document.notifications.onChecksFailed
        settings.notifyOnDraftConflict = document.notifications.onDraftConflict

        settings.intelligenceMode = document.intelligence.mode
        settings.cloudProviderKind = document.intelligence.cloudProviderKind
        settings.anthropicModel = document.intelligence.anthropicModel
        settings.openAICompatibleBaseURL = document.intelligence.openAICompatibleBaseURL
        settings.openAICompatibleModel = document.intelligence.openAICompatibleModel
        settings.openAICompatiblePreset = document.intelligence.openAICompatiblePreset

        settings.agentCLI = document.delegation.agentCLI
        settings.localCheckouts = document.delegation.localCheckouts

        settings.webhooksEnabled = document.automation.webhooksEnabled
        settings.webhookURL = document.automation.webhookURL
        settings.webhookEvents = document.automation.knownEvents

        settings.appearance = document.appearance.appearance
        settings.groupBy = document.appearance.inboxGroupBy
        settings.sortOrder = document.appearance.inboxSortOrder
        settings.diffFontSize = document.appearance.diffFontSize
        settings.diffWrapsLines = document.appearance.diffWrapsLines
        settings.diffUsesInlineMode = document.appearance.diffUsesInlineMode

        settings.defaultMergeMethod = document.triage.defaultMergeMethod

        // The registry lives in the database, not here, so it is applied only when there is one.
        let overrides = document.agents.registryOverrides
        if let writer = context.writeAgentOverrides {
            await writer(overrides)
            outcome.agentOverridesApplied = overrides.count
        } else if !overrides.isEmpty {
            outcome.skippedAgentRegistry = true
        }

        outcome.secretsWritten = applySecrets(document.secrets, context: context)

        if let token = nonEmpty(document.secrets.githubToken),
           let login = nonEmpty(document.account.login) {
            let stored = await storeGitHubToken(token, login: login, context: context)
            if stored {
                outcome.secretsWritten += 1
                // A live session is wired to one login and reads the Keychain on every request,
                // so replacing the token *of that login* takes effect without a restart. Any
                // other case — a different login, or no session at all — needs the sign-in flow
                // to run, and saying so is more useful than a silent half-swap.
                outcome.needsSignInRestart = context.signedInLogin != login
                if context.signedInLogin == nil {
                    settings.accountLogin = login
                    settings.accountAuthKind = document.account.authKind ?? .pat
                }
            }
        }

        return outcome
    }

    /// Writes the three string secrets, skipping absent ones.
    @MainActor
    private static func applySecrets(
        _ secrets: SyncedSettingsDocument.Secrets,
        context: SettingsSyncContext
    ) -> Int {
        let pairs: [(String?, String)] = [
            (secrets.anthropicKey, KeychainSecretStore.Key.anthropicAPIKey),
            (secrets.openAICompatibleKey, KeychainSecretStore.Key.openAICompatibleAPIKey),
            (secrets.webhookSecret, KeychainSecretStore.Key.webhookSecret),
        ]
        var written = 0
        for (value, key) in pairs {
            guard let value = nonEmpty(value) else { continue }
            do {
                try context.secrets.setSecret(value, for: key)
                written += 1
            } catch {
                // A Keychain refusal for one item must not stop the other two: a partial apply
                // that the status line under-reports is better than an aborted one.
                continue
            }
        }
        return written
    }

    /// Stores the GitHub credential under the document's login.
    ///
    /// A `TokenSet` is rebuilt rather than copied wholesale: the document carries the access
    /// token only, and inventing expiry metadata for it would make a personal access token look
    /// like a device-flow one.
    @MainActor
    private static func storeGitHubToken(
        _ token: String,
        login: String,
        context: SettingsSyncContext
    ) async -> Bool {
        do {
            try await context.tokens.setToken(TokenSet(accessToken: token), for: login)
            return true
        } catch {
            return false
        }
    }

    /// `nil` for a missing or blank string, the trimmed value otherwise.
    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
