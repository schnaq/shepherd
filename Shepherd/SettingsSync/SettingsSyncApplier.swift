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
        // The schedule only. `settings.digestLastDeliveredAt` is deliberately absent: it is this
        // Mac's own record of what it has already announced, and a shared one would let the first
        // Mac awake silence the others.
        document.digest = SyncedSettingsDocument.DigestGroup(schedule: settings.digest)
        document.agents = SyncedSettingsDocument.AgentsGroup(registryOverrides: overrides)
        document.intelligence = SyncedSettingsDocument.IntelligenceGroup(
            mode: settings.intelligenceMode,
            cloudProviderKind: settings.cloudProviderKind,
            anthropicModel: settings.anthropicModel,
            openAICompatibleBaseURL: settings.openAICompatibleBaseURL,
            openAICompatibleModel: settings.openAICompatibleModel,
            // The sovereignty policy travels with the endpoint it belongs to: it is part of what
            // the request *is*, so two Macs must not disagree about it (plan §3.K).
            openAICompatibleSovereigntyCountries: settings.openAICompatibleSovereigntyCountries,
            openAICompatibleZeroRetention: settings.openAICompatibleZeroRetention,
            // The switch, never the verdicts: a classification is derived from local rows and is
            // re-derived when the pull request changes, so it is device state like the search
            // vectors (plan §3.A, ADR 0019's argument).
            structuredTriageEnabled: settings.structuredTriageEnabled
        )
        document.delegation = SyncedSettingsDocument.DelegationGroup(
            agentCLI: settings.agentCLI,
            localCheckouts: settings.localCheckouts,
            autoDelegation: settings.autoDelegation
        )
        document.automation = SyncedSettingsDocument.AutomationGroup(
            webhooksEnabled: settings.webhooksEnabled,
            webhookURL: settings.webhookURL,
            webhookEvents: settings.webhookEvents.map(\.rawValue).sorted()
        )
        // The rules only. The ledger — which is also the audit log — is device state for the same
        // reason `AutoDelegationLedger` is: it records what *this* Mac already queued (ADR 0018).
        document.autoMerge = SyncedSettingsDocument.AutoMergeGroup(rules: settings.autoMerge)
        // The thresholds only. The ninety days of closed pull requests behind the badges are
        // device state for the search index's reason: rebuildable from a read any Mac can make,
        // and far too large to put in a settings object (ADR 0027).
        document.trust = SyncedSettingsDocument.TrustGroup(
            laneConfiguration: settings.trustLaneConfiguration
        )
        // The switch, never the index: the vectors are device state that a local pass rebuilds
        // from local rows (ADR 0019).
        document.search = SyncedSettingsDocument.SearchGroup(
            isSemanticIndexEnabled: settings.semanticSearchEnabled,
            // The switch, never the items: Spotlight's index belongs to the Mac it is on, and this
            // Mac rebuilds its own from local rows (ADR 0021).
            isSpotlightExportEnabled: settings.spotlightExportEnabled
        )
        document.appearance = SyncedSettingsDocument.AppearanceGroup(
            appearance: settings.appearance,
            inboxGroupBy: settings.groupBy,
            inboxSortOrder: settings.sortOrder,
            diffFontSize: settings.diffFontSize,
            diffWrapsLines: settings.diffWrapsLines,
            diffUsesInlineMode: settings.diffUsesInlineMode,
            diffRenderer: settings.diffRenderer,
            showsMenuBarExtra: settings.showsMenuBarExtra,
            opensAgentPullRequestsOnConversation: settings.opensAgentPullRequestsOnConversation
        )
        document.triage = SyncedSettingsDocument.TriageGroup(
            defaultMergeMethod: settings.defaultMergeMethod,
            deletesBranchAfterMerge: settings.deletesBranchAfterMerge
        )
        document.composer = SyncedSettingsDocument.ComposerGroup(
            savedReplies: settings.savedReplies,
            reviewTemplates: settings.reviewTemplates
        )
        document.diagnostics = SyncedSettingsDocument.DiagnosticsGroup(
            isEnabled: settings.diagnosticsEnabled
        )
        document.telemetry = SyncedSettingsDocument.TelemetryGroup(
            level: settings.telemetryLevel,
            noticeAcknowledged: settings.telemetryNoticeAcknowledged
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

        // Only the schedule is applied; `digestLastDeliveredAt` stays this Mac's. Nothing else has
        // to happen — the once-a-minute due check in `DigestCoordinator` reads the schedule on
        // every tick, so a document that switches the digest on takes effect within the minute,
        // whether it arrived here or through the toggle in Settings.
        settings.digest = document.digest.schedule

        settings.intelligenceMode = document.intelligence.mode
        settings.cloudProviderKind = document.intelligence.cloudProviderKind
        settings.anthropicModel = document.intelligence.anthropicModel
        // Writing the base URL is what selects the endpoint preset — it is derived from the URL,
        // so there is nothing further to apply here.
        settings.openAICompatibleBaseURL = document.intelligence.openAICompatibleBaseURL
        settings.openAICompatibleModel = document.intelligence.openAICompatibleModel
        // The mirror of the capture above. Nothing further has to happen either: the router is
        // rebuilt from the settings after a document is applied, exactly as it is after the
        // endpoint fields change in Settings (plan §3.K).
        settings.openAICompatibleSovereigntyCountries = document.intelligence
            .openAICompatibleSovereigntyCountries
        settings.openAICompatibleZeroRetention = document.intelligence.openAICompatibleZeroRetention
        // Only the flag is applied, and nothing else has to happen: nothing reads it yet, and
        // when the classifier exists it will re-consider the inbox on the next indexing pass —
        // the same one route the search index takes (ADR 0019).
        settings.structuredTriageEnabled = document.intelligence.structuredTriageEnabled

        settings.agentCLI = document.delegation.agentCLI
        settings.localCheckouts = document.delegation.localCheckouts
        settings.autoDelegation = document.delegation.autoDelegation

        settings.webhooksEnabled = document.automation.webhooksEnabled
        settings.webhookURL = document.automation.webhookURL
        settings.webhookEvents = document.automation.knownEvents

        // Only the rules are applied. Nothing else has to happen: the next inbox observation
        // re-considers every row against whatever the rules now say, so a document that switches
        // automatic merging on takes effect on the next sweep — and one that switches it off
        // stops the very next pass (ADR 0018).
        settings.autoMerge = document.autoMerge.rules

        // The mirror of the capture. Nothing further has to happen: the inbox recomputes the
        // lanes whenever the thresholds change, so a document that widens "small" moves rows
        // between the two headers as soon as it is applied (ADR 0027). The two stored properties
        // are written rather than the value, because the value is the clamped view of them.
        settings.trustLaneMaxFiles = document.trust.laneConfiguration.maxFiles
        settings.trustLaneMaxChangedLines = document.trust.laneConfiguration.maxChangedLines

        // Only the flag is applied. Building or dropping the index is the window's job, driven by
        // `onChange(of: settings.semanticSearchEnabled)` in `ShepherdApp` — the same one route the
        // diagnostics opt-in takes (ADR 0017), so a flipped toggle and an applied document reach
        // the coordinator through one path rather than two.
        settings.semanticSearchEnabled = document.search.isSemanticIndexEnabled

        // And the same again for the Spotlight export (ADR 0021): only the flag is applied, and
        // `onChange(of: settings.spotlightExportEnabled)` in `ShepherdApp` is what turns it into
        // items in the system index or a deleted domain.
        settings.spotlightExportEnabled = document.search.isSpotlightExportEnabled

        settings.appearance = document.appearance.appearance
        settings.groupBy = document.appearance.inboxGroupBy
        settings.sortOrder = document.appearance.inboxSortOrder
        settings.diffFontSize = document.appearance.diffFontSize
        settings.diffWrapsLines = document.appearance.diffWrapsLines
        settings.diffUsesInlineMode = document.appearance.diffUsesInlineMode
        settings.diffRenderer = document.appearance.diffRenderer
        // Nothing to apply beyond the flag: `MenuBarExtra(isInserted:)` reads this setting
        // directly, so the item appears or disappears as soon as the value changes — whether it
        // changed in Settings or arrived in a document.
        settings.showsMenuBarExtra = document.appearance.showsMenuBarExtra
        // A preference rather than per-Mac UI state, so it travels: a reviewer who wants the diff
        // first wants it on both Macs. Nothing to apply beyond the value — the next review to open
        // reads it, and a review already on screen has spent its one choice (ADR 0026's amendment).
        settings.opensAgentPullRequestsOnConversation =
            document.appearance.opensAgentPullRequestsOnConversation

        settings.defaultMergeMethod = document.triage.defaultMergeMethod
        settings.deletesBranchAfterMerge = document.triage.deletesBranchAfterMerge

        // Replaced wholesale rather than merged, like every other setting: two lists of authored
        // text have no conflict resolution a machine could guess, and the confirmation dialog in
        // Settings is what makes that honest. Nothing else has to be applied — the insert menu and
        // the template lookup read these arrays on every use.
        settings.savedReplies = document.composer.savedReplies
        settings.reviewTemplates = document.composer.reviewTemplates

        // Only the flag is applied. Registering or removing the MetricKit subscriber is the
        // window's job, driven by `onChange(of: settings.diagnosticsEnabled)` in `ShepherdApp` —
        // the same route the appearance change takes, so an applied document and a flipped toggle
        // reach the subscriber through one path rather than two (ADR 0017).
        settings.diagnosticsEnabled = document.diagnostics.isEnabled

        // Absent means "leave it alone", not "apply the default": a document written before
        // ADR 0036 has no telemetry group, and applying a default would decide the question for
        // somebody who has not been asked. Only the flags are applied here — building or tearing
        // down the mechanism is the window's job, driven by `onChange(of: settings.telemetryLevel)`
        // in `ShepherdApp`, exactly like the MetricKit subscriber.
        if let telemetry = document.telemetry {
            settings.telemetryLevel = telemetry.level
            // Both flags travel as they are. Since the 2026-09-22 amendment an unasked Mac and a
            // Mac that said no both read `off`; only this flag tells them apart, so an applied
            // `off` may not be taken as an answer — the second Mac asks its own question, and a
            // document that carries a `yes` or a `no` is applied as that answer.
            settings.telemetryNoticeAcknowledged = telemetry.noticeAcknowledged
        }

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
