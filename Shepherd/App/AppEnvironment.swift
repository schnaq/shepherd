import AppKit
import Foundation
import GitHubKit
import Observation
import ShepherdCore
import ShepherdPersistence
import ShepherdSync
import SwiftUI

/// The dependency container and top-level state machine.
///
/// The app has exactly two states: signed out (onboarding) and signed in (inbox). Everything
/// that needs a token, a database or the network lives in ``SignedInSession`` and therefore
/// cannot exist in the signed-out state.
@MainActor
@Observable
final class AppEnvironment {
    /// Which top-level screen is showing.
    enum Phase {
        /// Reading the Keychain to find out whether an account is signed in.
        case launching
        /// No account: onboarding.
        case signedOut
        /// An account is signed in: the inbox.
        case signedIn(SignedInSession)
    }

    /// Which screen the signed-in window is showing.
    enum Route: Hashable {
        /// The three-pane inbox.
        case inbox
        /// The full-window review screen for one pull request.
        case review(prID: String)
    }

    /// The current phase.
    private(set) var phase: Phase = .launching
    /// The current route within the signed-in window.
    var route: Route = .inbox
    /// Whether the ⌘K palette is up.
    var isCommandPaletteVisible = false
    /// The drafts that could not be submitted because the pull request moved on (ADR 0006).
    ///
    /// A queue rather than a single slot: one bulk-triage drain can park several reviews, and
    /// the user has to see each of them (ADR 0015).
    let draftConflicts = DraftConflictQueue()

    /// A `shepherd://` link that arrived before there was a session to run it (ADR 0013).
    ///
    /// One slot, last link wins: a deep link is a *navigation*, and replaying a queue of them
    /// after sign-in would leave the user on whichever one happened to be last anyway. No view
    /// observes it — it is read once, imperatively, by ``runPendingDeepLink()`` — so like
    /// `pendingReviewVerdict` it stays out of the observation graph.
    @ObservationIgnored var pendingDeepLink: DeepLink?
    /// An inbox rail filter raised by a deep link, waiting for the inbox to apply it.
    ///
    /// Same mechanism as ``PendingAction``: the container raises it, the screen that owns the
    /// state consumes it, so there is one implementation of "filter the inbox" (ADR 0013).
    var pendingInboxFilter: Pending<InboxDeepLinkFilter>?
    /// A Settings tab a deep link asked for, waiting for the inbox to present it.
    var pendingSettingsTab: Pending<SettingsDeepLinkTab>?

    /// User preferences.
    let settings: AppSettings
    /// GitHub credentials (Keychain only, ADR 0004).
    let tokenStore: KeychainTokenStore
    /// AI keys (Keychain only, ADR 0007).
    let secretStore: KeychainSecretStore
    /// The window's toast queue; errors are surfaced here, never printed.
    let toasts = ToastCenter()
    /// Maps sync events to macOS notifications.
    let notifications: NotificationManager
    /// The delegation sheets: one per pull request, at most one on screen (ADR 0011).
    let delegation: DelegationCenter
    /// Posts events to the user's own webhook URL, when they configured one (ADR 0012).
    let webhooks: WebhookDispatcher
    /// Maps Shepherd's events onto webhook deliveries.
    let webhookCoordinator: WebhookCoordinator
    /// Sparkle 2, or an inert stand-in when the build has no update feed and key (ADR 0010).
    let updates = UpdateController()
    /// MetricKit crash and hang reports, kept on this Mac only and only when asked for
    /// (ADR 0017). Created inert: it subscribes to nothing until ``applyDiagnosticsSetting()``
    /// sees the opt-in.
    let diagnostics = DiagnosticsReporter()
    /// Remembers what automatic delegation already did, across launches (ADR 0016).
    let autoDelegationStore: AutoDelegationStore
    /// Decides whether a sweep event starts a delegation on its own (ADR 0016).
    let autoDelegation: AutoDelegationCoordinator

    /// The provider router, rebuilt whenever the intelligence settings change.
    private(set) var intelligence: IntelligenceRouter = .disabled

    /// The signed-in session, when there is one.
    var session: SignedInSession? {
        if case .signedIn(let session) = phase { return session }
        return nil
    }

    /// Creates the container.
    /// - Parameters:
    ///   - settings: The preference store.
    ///   - tokenStore: The GitHub credential store.
    ///   - secretStore: The AI-key store.
    init(
        settings: AppSettings = AppSettings(),
        tokenStore: KeychainTokenStore = KeychainTokenStore(),
        secretStore: KeychainSecretStore = KeychainSecretStore()
    ) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.secretStore = secretStore
        // Assigned from locals rather than from property defaults, because the coordinators
        // built further down need them *during* initialisation.
        let notifications = NotificationManager()
        self.notifications = notifications
        let delegation = DelegationCenter()
        self.delegation = delegation
        let webhooks = WebhookDispatcher()
        self.webhooks = webhooks
        self.webhookCoordinator = WebhookCoordinator(
            dispatcher: webhooks,
            settings: settings,
            secretStore: secretStore
        )
        let autoDelegationStore = AutoDelegationStore()
        self.autoDelegationStore = autoDelegationStore
        self.autoDelegation = AutoDelegationCoordinator(
            settings: settings,
            delegation: delegation,
            store: autoDelegationStore,
            notify: { payload in
                // Detached like the webhook dispatch: asking for notification authorisation
                // must not sit in the middle of the sync's event loop.
                Task { [notifications] in
                    await notifications.present(payload)
                }
            }
        )
        refreshIntelligence()
    }

    // MARK: - Lifecycle

    /// Restores the signed-in account, if the Keychain still has its token.
    func bootstrap() async {
        applyAppearance()
        // Before anything else that could go wrong: MetricKit delivers the previous run's
        // diagnostics shortly after launch, and a subscriber registered after that moment would
        // miss the batch that describes the crash the user is here about (ADR 0017).
        applyDiagnosticsSetting()
        guard let account = settings.account else {
            phase = .signedOut
            announceDeepLinkNeedsSignIn()
            return
        }
        do {
            guard try await tokenStore.token(for: account.login) != nil else {
                settings.clearAccount()
                phase = .signedOut
                announceDeepLinkNeedsSignIn()
                return
            }
            try await startSession(for: account)
        } catch {
            toasts.failure(error, context: String(localized: "Could not open the local database"))
            phase = .signedOut
        }
    }

    /// Completes a sign-in: stores the credential, remembers the account, starts syncing.
    /// - Parameters:
    ///   - account: The account that authenticated.
    ///   - token: The credential to store in the Keychain.
    func signIn(account: Account, token: TokenSet) async {
        do {
            try await tokenStore.setToken(token, for: account.login)
            settings.store(account: account)
            try await startSession(for: account)
        } catch {
            toasts.failure(error, context: String(localized: "Sign-in failed"))
        }
    }

    /// Signs out and deletes both the credential and the local cache (ADR 0006).
    func signOutAndErase() async {
        let current = session
        route = .inbox
        phase = .signedOut
        // A queued deep link belongs to the account that was signed in.
        clearPendingDeepLink()
        // So do parked conflicts: they name pull requests of the account that is leaving.
        draftConflicts.removeAll()
        if let current {
            await current.shutdown()
            do {
                try await current.database.eraseAllData()
            } catch {
                toasts.failure(error, context: String(localized: "Could not erase local data"))
            }
            do {
                try await tokenStore.deleteToken(for: current.account.login)
            } catch {
                toasts.failure(error, context: String(localized: "Could not remove the Keychain item"))
            }
        }
        settings.clearAccount()
        // The ledger names pull requests of the account that just signed out, and keeping it
        // would let a rule refuse to fire for a pull request the next account re-imports.
        autoDelegation.reset()
    }

    private func startSession(for account: Account) async throws {
        let session = try await SignedInSession.make(
            account: account,
            tokenStore: tokenStore,
            sweepInterval: settings.sweepIntervalMinutes * 60
        )
        phase = .signedIn(session)
        // `start` spawns the sweep loop, whose first iteration sweeps immediately — an extra
        // `syncNow()` here only bought a second concurrent sweep on every launch.
        session.start(
            settings: settings,
            notifications: notifications
        ) { [weak self] event in
            self?.handle(event)
        }
        // A `shepherd://` link may have arrived while the app was still launching or signed
        // out; this is the first moment it can do anything (ADR 0013).
        runPendingDeepLink()
    }

    private func handle(_ event: SyncEvent) {
        if case .draftConflict(let conflict) = event {
            draftConflicts.raise(conflict)
        }
        // Fire-and-forget by construction: the coordinator spawns its own task and swallows
        // every failure, so a broken webhook cannot slow down or break the sync (ADR 0012).
        webhookCoordinator.handle(event, database: session?.database)
        // Opt-in and off by default; with no rule armed this is one Bool read (ADR 0016). The
        // coordinator decides and reserves the slot, the start goes through the same
        // `startDelegation` a button press uses.
        if let plan = autoDelegation.plan(for: event) {
            startDelegation(
                .pullRequest(plan.pullRequest),
                task: plan.task,
                automatic: true
            )
        }
    }

    // MARK: - Actions

    /// Runs a sweep now (⌘R).
    func syncNow() async {
        guard let session else { return }
        do {
            try await session.syncNow()
        } catch {
            toasts.failure(error, context: String(localized: "Sync failed"))
        }
    }

    /// Opens the delegation sheet for a pull request or a review finding (ADR 0011).
    ///
    /// A delegation already running for the same pull request is revealed rather than
    /// replaced — one worktree per pull request, one run at a time.
    ///
    /// An automatic start (ADR 0016) takes the same path with `automatic: true`: it runs without
    /// a sheet, is marked as automatic wherever it shows up, and is otherwise identical — same
    /// worktree isolation, same guardrails, same "Shepherd never pushes".
    /// - Parameters:
    ///   - context: What the delegation is about.
    ///   - task: A prefilled task text, replacing the default. Used by automatic starts.
    ///   - automatic: Whether a rule asked for this rather than the user.
    func startDelegation(
        _ context: DelegationContext,
        task: String? = nil,
        automatic: Bool = false
    ) {
        let onDidPush: @MainActor () async -> Void = { [weak self] in
            // The agent's commits are on the pull request now; refresh so the review screen
            // shows the new head instead of the one the user delegated from.
            await self?.syncNow()
        }
        let onDidFinish: @MainActor (DelegationOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.webhookCoordinator.handle(outcome, database: self.session?.database)
        }

        if automatic {
            delegation.startAutomatically(
                context: context,
                task: task ?? DelegationPrompt.defaultTask(for: context),
                settings: settings,
                toasts: toasts,
                onDidPush: onDidPush,
                onDidFinish: onDidFinish
            )
            return
        }

        let model = delegation.open(
            context: context,
            settings: settings,
            toasts: toasts,
            onDidPush: onDidPush,
            onDidFinish: onDidFinish
        )
        if let task, !model.isBusy {
            model.task = task
        }
    }

    /// Applies the stored appearance preference to the whole app.
    func applyAppearance() {
        NSApplication.shared.appearance = settings.appearance.nsAppearance
    }

    /// Registers or removes the MetricKit subscriber to match the opt-in setting (ADR 0017).
    ///
    /// Called at launch and whenever ``AppSettings/diagnosticsEnabled`` changes — from the toggle
    /// in Settings, or because a downloaded settings document carried the flag from another Mac.
    /// Idempotent, so it does not matter how many of those happen.
    func applyDiagnosticsSetting() {
        diagnostics.setSubscribed(settings.diagnosticsEnabled)
    }

    /// Rebuilds the intelligence router from the current settings and Keychain.
    ///
    /// Called at launch and whenever the Intelligence settings tab changes something.
    func refreshIntelligence() {
        var configuration = IntelligenceConfiguration(
            mode: settings.intelligenceMode,
            cloudKind: settings.cloudProviderKind,
            anthropicModel: settings.anthropicModel,
            openAIBaseURL: settings.openAICompatibleBaseURL,
            openAIModel: settings.openAICompatibleModel
        )
        let key = settings.cloudProviderKind == .anthropic
            ? KeychainSecretStore.Key.anthropicAPIKey
            : KeychainSecretStore.Key.openAICompatibleAPIKey
        configuration.cloudAPIKey = ((try? secretStore.secret(for: key)) ?? nil) ?? ""
        intelligence = IntelligenceRouter(configuration: configuration)
    }

    /// Assembles the surfaces encrypted settings sync needs (ADR 0014).
    ///
    /// Built fresh per action rather than held: the agent-registry half only exists while an
    /// account is signed in, and a context captured at launch would still be pointing at a
    /// database that has since been erased.
    /// - Returns: The context to hand ``SettingsSyncModel``.
    func settingsSyncContext() -> SettingsSyncContext {
        var reader: (@Sendable () async -> [AgentRegistryEntry])?
        var writer: (@Sendable ([AgentRegistryEntry]) async -> Void)?
        if let database = session?.database {
            reader = { (try? await database.agentRegistryOverrides()) ?? [] }
            writer = { entries in
                // A download *replaces* the registry extensions rather than merging into them,
                // matching what the confirmation dialog promises about the rest of the document:
                // ids the incoming document does not mention are removed.
                let existing = (try? await database.agentRegistryOverrides()) ?? []
                let incoming = Set(entries.map(\.id))
                for entry in existing where !incoming.contains(entry.id) {
                    try? await database.deleteAgentRegistryOverride(id: entry.id)
                }
                for entry in entries {
                    try? await database.saveAgentRegistryOverride(entry)
                }
            }
        }
        return SettingsSyncContext(
            settings: settings,
            secrets: secretStore,
            tokens: tokenStore,
            signedInLogin: session?.account.login,
            readAgentOverrides: reader,
            writeAgentOverrides: writer
        )
    }

    // MARK: - Menu / palette commands

    /// A command raised by the menu bar or the command palette, waiting for the screen that
    /// owns the selection to run it.
    struct PendingAction: Equatable, Identifiable {
        /// Makes two otherwise identical requests distinguishable.
        let id = UUID()
        /// What was asked for.
        let action: ShortcutAction
    }

    /// The command waiting to be executed, if any.
    private(set) var pendingAction: PendingAction?

    /// Raises a command. The visible screen picks it up and clears it.
    /// - Parameter action: The command.
    func request(_ action: ShortcutAction) {
        pendingAction = PendingAction(action: action)
    }

    /// Clears the pending command after a screen has handled it.
    func clearPendingAction() {
        pendingAction = nil
    }

    /// A verdict the review screen should open its composer on, set by an inbox shortcut.
    ///
    /// Transient routing state that is read once, imperatively, when the review screen
    /// appears — no view observes it, so it stays out of the observation graph.
    @ObservationIgnored private var pendingReviewVerdict: ReviewVerdict?

    /// Opens the full-window review screen.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - verdict: When given, the review screen opens its submit composer on this verdict
    ///     instead of the caller queueing a review blind. `r x` and `r c` need a summary body,
    ///     which only the composer can collect.
    func openReview(prID: String, composing verdict: ReviewVerdict? = nil) {
        pendingReviewVerdict = verdict
        route = .review(prID: prID)
    }

    /// Reads and clears the verdict the review screen should open its composer on.
    func consumePendingReviewVerdict() -> ReviewVerdict? {
        defer { pendingReviewVerdict = nil }
        return pendingReviewVerdict
    }

    /// Returns to the inbox.
    func closeReview() {
        route = .inbox
    }
}
