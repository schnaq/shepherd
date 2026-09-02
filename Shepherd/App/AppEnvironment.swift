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
    /// Remembers — and shows — every merge a rule queued, across launches (ADR 0018).
    let autoMergeStore: AutoMergeStore
    /// Decides whether the rows a sweep wrote contain anything to merge on its own (ADR 0018).
    let autoMerge: AutoMergeCoordinator
    /// Keeps the on-device ⌘K search index current and answers the palette's queries (ADR 0019).
    ///
    /// Created inert: it holds no corpus and loads no model until the first inbox observation
    /// hands it rows, and with the setting off it never reads a diff or spends an embedding.
    let search: SearchIndexCoordinator
    /// Keeps the pull requests in the inbox visible to macOS Spotlight (ADR 0021).
    ///
    /// Created inert, like the search index beside it: it writes nothing until the first inbox
    /// observation hands it rows, and with the setting off it never makes a framework call.
    let spotlight: SpotlightIndexer
    /// Delivers the opt-in morning digest: a notification when it is due, a card in the inbox
    /// while the day lasts. Created inert — it does nothing until ``bootstrap()`` starts its check,
    /// and that check does nothing until the user switches the digest on.
    let digest: DigestCoordinator

    /// Reopens the main window when AppKit has nothing left to bring forward.
    ///
    /// Set by ``RootView`` from SwiftUI's `openWindow`, which is the only thing that can create a
    /// window and is not reachable from here — the same problem, and the same solution, as the
    /// menu-bar quick inbox's `revealMainWindow()`. Not observed by anything (it is called
    /// imperatively, from a notification click), so it stays out of the observation graph.
    @ObservationIgnored var reopenMainWindow: (@MainActor () -> Void)?

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
        let autoMergeStore = AutoMergeStore()
        self.autoMergeStore = autoMergeStore
        self.autoMerge = AutoMergeCoordinator(
            settings: settings,
            store: autoMergeStore,
            notify: { payload in
                // Detached like the auto-delegation notice, and for the same reason: asking for
                // notification authorisation must not sit inside the inbox observation's loop.
                Task { [notifications] in
                    await notifications.present(payload)
                }
            }
        )
        self.search = SearchIndexCoordinator(settings: settings)
        self.spotlight = SpotlightIndexer(settings: settings)
        self.digest = DigestCoordinator(
            settings: settings,
            notify: { payload in
                // Detached for the same reason the auto-delegation notice is: asking for
                // notification authorisation must not sit inside a once-a-minute timer tick.
                Task { [notifications] in
                    await notifications.present(payload)
                }
            }
        )
        refreshIntelligence()
        // Registered here rather than in `bootstrap()`: a click on a digest notification that
        // happened while Shepherd was not running is delivered to the delegate shortly after
        // launch, and a delegate installed a moment later would miss it.
        notifications.routeClicks { [weak self] in
            self?.openInboxFromNotification()
        }
        // App Intents are created by the *system*, so they have no initialiser to be handed a
        // dependency through; registering the container here is how an intent finds the running
        // app (ADR 0021, `Intents/IntentBridge.swift`). The reference there is weak.
        IntentBridge.register(self)
    }

    // MARK: - Lifecycle

    /// Restores the signed-in account, if the Keychain still has its token.
    func bootstrap() async {
        applyAppearance()
        // Before anything else that could go wrong: MetricKit delivers the previous run's
        // diagnostics shortly after launch, and a subscriber registered after that moment would
        // miss the batch that describes the crash the user is here about (ADR 0017).
        applyDiagnosticsSetting()
        // Cheap and self-healing: with the export switched off this deletes the `pullRequests`
        // domain, which repairs the one state nothing else can — the app was killed between the
        // toggle going off and the deletion landing (ADR 0021). With it on there is no session
        // yet, so it does nothing and the first inbox observation is what exports.
        applySpotlightSetting()
        startDigestChecks()
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
        // Dropped before the route changes and without the closing toast: the queue named pull
        // requests of the account that is leaving, and there is nothing to report about a
        // session the user did not end.
        reviewSession = nil
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
        // The same argument, and one more: the auto-merge ledger is also the audit log, and a log
        // naming the previous account's pull requests has no business being on screen after a
        // sign-out (ADR 0018).
        autoMerge.reset()
        // Same argument for the digest's device state: the card names the leaving account's pull
        // requests, and "already delivered today" belongs to that account's morning.
        digest.reset()
        // And the search corpus, which is the leaving account's titles and diffs held in memory.
        // Its table went with `eraseAllData()` above — the index is local cache in exactly the
        // sense ADR 0006 means.
        search.reset()
        // And the Spotlight domain, which is the one piece of this account's data that lives
        // *outside* the database `eraseAllData()` just emptied: the system index is not Shepherd's
        // to leave behind (ADR 0021).
        spotlight.reset()
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
            notifications: notifications,
            onEvent: { [weak self] event in
                self?.handle(event)
            },
            onInboxRows: { [weak self] rows in
                guard let self else { return }
                self.considerAutoMerge(rows: rows)
                // The same rows, the same moment, for the same reason: the inbox observation is
                // the one place that reports a change to what is *in* the inbox — including the
                // one nothing else announces, a detail fetch storing a diff (ADR 0019). The
                // database comes from `self.session` rather than from the local above: the
                // session holds this closure, so capturing it here would be a retain cycle.
                // The third consumer of the same rows (ADR 0021), and it goes first because it
                // is the one that needs no database: a Spotlight item is built out of the row
                // itself. A sweep that changed nothing a result shows costs one dictionary
                // comparison and no framework call.
                self.spotlight.considerExporting(rows: rows)
                guard let database = self.session?.database else { return }
                self.search.considerIndexing(rows: rows, database: database)
            }
        )
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

    // MARK: - Automatic merging (ADR 0018)

    /// Considers the rows a sweep just wrote for automatic merging.
    ///
    /// Opt-in and off by default; with no rule armed this is one `Bool` read before anything
    /// asynchronous is started, which matters because the inbox observation speaks on every inbox
    /// write. Everything that decides anything is the pure
    /// ``ShepherdCore/AutoMergePolicy``; the write goes through the *same*
    /// ``PullRequestActions/merge(_:method:)`` the merge sheet's button calls, so the outbox, the
    /// retry, the head-commit preflight and the `pr.merged` webhook all behave exactly as they do
    /// for a merge the user asked for (ADR 0006, ADR 0015's "n ordinary outbox writes").
    /// - Parameter rows: Every inbox row the local database now holds.
    private func considerAutoMerge(rows: [PullRequestSummary]) {
        guard settings.autoMerge.isEnabled, let session else { return }
        Task { [weak self] in
            // Read before the pass rather than per row: one query for the whole batch, and the
            // coordinator adds its own queued ids as it goes.
            let queuedWrites = await session.pullRequestIDsWithQueuedWrites()
            guard let self else { return }
            // `announcesSuccess: false` — the pass announces itself once, as a notification, and
            // records every merge in the audit log; a toast per row would be a dozen banners for
            // something nobody was watching. A *failure* still toasts.
            let actions = PullRequestActions(
                session: session,
                toasts: self.toasts,
                announcesSuccess: false
            )
            let queued = await self.autoMerge.run(
                rows: rows,
                existingOutbox: queuedWrites,
                write: { summary, method in
                    await actions.merge(summary, method: method)
                }
            )
            for write in queued {
                self.webhookCoordinator.handle(write, database: session.database)
            }
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

    /// Builds or drops the semantic search index to match the setting (ADR 0019).
    ///
    /// Called at launch and whenever ``AppSettings/semanticSearchEnabled`` changes — from the
    /// toggle in Settings, or because a downloaded settings document carried the flag from another
    /// Mac (ADR 0014). One route for both, exactly as ``applyDiagnosticsSetting()`` is.
    ///
    /// Switching it off empties the table rather than keeping it warm: a switch named after an
    /// index that left a megabyte of vectors on disk would be lying about the one thing it is
    /// named after. Re-enabling costs one local indexing pass.
    func applySemanticSearchSetting() {
        guard let session else {
            search.reset()
            return
        }
        if settings.semanticSearchEnabled {
            search.considerIndexing(rows: session.inboxRows, database: session.database)
            return
        }
        // The clear is a write, so it is awaited in a task of its own; only the database — which
        // is `Sendable` — crosses into it.
        let database = session.database
        Task { [weak self] in
            guard let self else { return }
            await self.search.disable(database: database)
        }
    }

    /// Re-indexes one pull request because the review screen just stored its diff (ADR 0019).
    ///
    /// Promptness only: the stored `detailFetchedAt` moves, so the next ordinary pass would pick
    /// the pull request up regardless. The screen announcing it just means the diff is searchable
    /// before the next sweep rather than after it.
    /// - Parameter prID: The pull request whose detail arrived.
    func searchIndexDidLoadDetail(prID: String) {
        guard let session else { return }
        search.indexAfterDetailLoad(prID: prID, database: session.database)
    }

    /// Throws the search index away and builds it again — the *Rebuild index* button.
    func rebuildSearchIndex() {
        guard let session else { return }
        let database = session.database
        Task { [weak self] in
            guard let self else { return }
            await self.search.rebuild(database: database)
        }
    }

    /// Registers or removes the MetricKit subscriber to match the opt-in setting (ADR 0017).
    ///
    /// Called at launch and whenever ``AppSettings/diagnosticsEnabled`` changes — from the toggle
    /// in Settings, or because a downloaded settings document carried the flag from another Mac.
    /// Idempotent, so it does not matter how many of those happen.
    func applyDiagnosticsSetting() {
        diagnostics.setSubscribed(settings.diagnosticsEnabled)
    }

    // MARK: - Morning digest

    /// Starts the once-a-minute digest due check.
    ///
    /// Started at launch rather than at sign-in, and never stopped: the check's source answers `nil`
    /// while there is no session, so signing in and out does not have to remember to restart a
    /// timer. The source is `nil` until the inbox observation has spoken once
    /// (``SignedInSession/hasLoadedInbox``) — without that, a digest delivered in the second
    /// between launch and the first `SELECT` would report an empty inbox and then mark itself done
    /// for the day.
    private func startDigestChecks() {
        digest.start { [weak self] in
            guard let session = self?.session, session.hasLoadedInbox else { return nil }
            return DigestInputs(
                pullRequests: session.inboxRows,
                parkedReviewCount: session.conflictedOutboxCount
            )
        }
    }

    /// Brings the inbox forward because the user clicked a Shepherd notification.
    ///
    /// The digest is the one notification that routes anywhere (see ``NotificationRouter``), and
    /// "needs my review" is where it points: it is the section the digest leads with and the one
    /// the user is being reminded about. The route is set through the same
    /// ``AppEnvironment/pendingInboxFilter`` slot a `shepherd://inbox?filter=needs-my-review` link
    /// uses, so there is one implementation of "filter the inbox" (ADR 0013).
    func openInboxFromNotification() {
        route = .inbox
        pendingInboxFilter = Pending(.needsMyReview)
        guard !activateMainWindow() else { return }
        // Every window is closed; only SwiftUI can make a new one.
        reopenMainWindow?()
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
        // Opening a pull request that is *not* the one under a running session's cursor means the
        // user left the queue — a parked-review alert's "Re-review", a menu-bar row, a
        // `shepherd://` link. The session ends instead of leaving a bar on screen that names a
        // different pull request than the screen below it. The session's own advance sets its
        // cursor first, so it never trips this.
        if let running = reviewSession, running.current?.id != prID {
            endReviewSession()
        }
        pendingReviewVerdict = verdict
        route = .review(prID: prID)
    }

    /// Reads and clears the verdict the review screen should open its composer on.
    func consumePendingReviewVerdict() -> ReviewVerdict? {
        defer { pendingReviewVerdict = nil }
        return pendingReviewVerdict
    }

    /// Returns to the inbox.
    ///
    /// A running focus session ends here too. The session *is* "work through these, one after
    /// another", so leaving the review screen by any route — the back chevron, Escape, the
    /// palette's "Back to the inbox" — ends it rather than leaving an invisible queue behind
    /// that the next `openReview` would silently rejoin.
    func closeReview() {
        if reviewSession != nil {
            endReviewSession()
            return
        }
        route = .inbox
    }

    // MARK: - Focus review session

    /// The guided pass over the pending reviews, when one is running.
    ///
    /// One optional, held here rather than on a screen for the same reason the delegation sheets
    /// are: the session outlives every individual review screen it walks through, because
    /// changing ``route`` is exactly how it moves on.
    ///
    /// Deliberately transient — see ``ReviewSession`` — and therefore not in ``AppSettings`` and
    /// not in the encrypted settings document (ADR 0014).
    private(set) var reviewSession: ReviewSession?

    /// Starts a session over the pull requests currently waiting for the user's review.
    ///
    /// The queue is frozen from ``SignedInSession/inboxRows`` — the session-level observation the
    /// menu-bar badge already reads — so it does not matter which screen asked, and a session
    /// started from ⌘K on the review screen sees the same list as one started from the inbox
    /// header.
    /// - Returns: Whether a session began. Every surface with a screen ignores this — the toast
    ///   says it — and `StartFocusSessionIntent` speaks it, because Siri has no toast.
    @discardableResult
    func startReviewSession() -> Bool {
        guard let session else { return false }
        guard var started = ReviewSession.make(from: session.inboxRows) else {
            toasts.info(String(localized: "Nothing needs your review right now."))
            return false
        }
        // Settled before anyone sees it, so the first entry is governed by exactly the rule every
        // later one is: the frozen queue and the "still in the inbox" set are two separate reads.
        let advance = started.settle(present: presentPullRequestIDs)
        guard advance.next != nil else {
            // Everything in the queue had already left the inbox. No session and no closing
            // toast — there is nothing to report about a sitting that never started.
            toasts.info(String(localized: "Nothing needs your review right now."))
            return false
        }
        apply(started, advance: advance)
        return true
    }

    /// Advances the session past the pull request the user just acted on.
    ///
    /// Wired to ``PullRequestActions/onDidQueueVerdict`` by the review screen, so `r a`, `r x`,
    /// `r c` and `m` all move the queue without a second "next" keystroke.
    /// - Parameter prID: The pull request whose verdict or merge was queued.
    func reviewSessionDidQueueVerdict(on prID: String) {
        guard let running = reviewSession, running.current?.id == prID else { return }
        // The sheet that submitted is still on screen and dismisses itself as soon as this
        // returns, so the route underneath it is changed one main-actor turn later: the next
        // pull request must never be pushed in under a sheet that is still closing.
        Task { [weak self] in
            self?.completeCurrentReviewSessionItem()
        }
    }

    /// Counts the current pull request as reviewed and moves on ("Done & next", `d`).
    func completeCurrentReviewSessionItem() {
        guard var running = reviewSession else { return }
        let advance = running.completeCurrent(present: presentPullRequestIDs)
        apply(running, advance: advance)
    }

    /// Leaves the current pull request for later and moves on ("Next", `n`).
    func skipCurrentReviewSessionItem() {
        guard var running = reviewSession else { return }
        let advance = running.skipCurrent(present: presentPullRequestIDs)
        apply(running, advance: advance)
    }

    /// Ends the session, says what it did, and returns to the inbox.
    ///
    /// The one exit: the queue running out, "End session", a confirmed Escape and
    /// ``closeReview()`` all come through here, so there is one place that can leave
    /// ``reviewSession`` set.
    func endReviewSession() {
        guard let running = reviewSession else { return }
        // Cleared first: `route = .inbox` below goes through nothing that could re-enter, but
        // `closeReview()` calls this method, and a session still set would recurse.
        reviewSession = nil
        route = .inbox
        toasts.show(
            Toast(message: running.summary().message, kind: .success, duration: 7)
        )
    }

    /// The pull requests the local inbox still holds — what "has not vanished" means.
    ///
    /// Every cached row rather than the "Needs my review" subset: a pull request someone else
    /// approved is still a pull request the user can look at, while one the sweep pruned is
    /// merged, closed, or past the search's page cap and there is nothing left to review.
    private var presentPullRequestIDs: Set<String> {
        Set((session?.inboxRows ?? []).map(\.id))
    }

    private func apply(_ running: ReviewSession, advance: ReviewSession.Advance) {
        reviewSession = running
        if let message = advance.vanishedMessage {
            toasts.info(message)
        }
        guard let next = advance.next else {
            endReviewSession()
            return
        }
        openReview(prID: next.id)
    }

    // MARK: - Menu bar (Features/MenuBar)

    /// SwiftUI's own identifier for the window the `Settings` scene puts on screen.
    ///
    /// Used only to *exclude* that window in ``activateMainWindow()``, so if Apple ever renames
    /// it the effect is "Settings may come forward instead", never a crash.
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"

    /// Brings the app's own window to the front, from a surface that is not inside it.
    ///
    /// The menu-bar quick inbox is its own scene, so it cannot rely on the window being active —
    /// or even present — when a row is clicked. Existing windows are AppKit's business rather
    /// than `openWindow`'s: asking a window *group* to open means asking for a second window, so
    /// `openWindow(id:)` is the caller's fallback for the one case this cannot handle.
    /// - Returns: Whether there was a window to bring forward. `false` means the user closed it
    ///   and the caller should ask SwiftUI for a new one.
    @discardableResult
    func activateMainWindow() -> Bool {
        // `activate()` rather than the deprecated `activate(ignoringOtherApps:)`: the click on the
        // menu-bar item is the user's own activation request, which is exactly the case macOS 14's
        // cooperative activation is for.
        NSApplication.shared.activate()
        // The menu-bar extra's own window is an `NSPanel`, which never becomes main, and the
        // Settings window is excluded by identifier; what is left is the WindowGroup's window.
        let window = NSApplication.shared.windows.first { window in
            window.canBecomeMain
                && window.identifier?.rawValue != Self.settingsWindowIdentifier
        }
        guard let window else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}
