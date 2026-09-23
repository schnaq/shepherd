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
        /// The fleet: every agent Shepherd has counted, or one of them.
        ///
        /// A route rather than a third `ContentKind` beside the pull requests and the issues
        /// (ADR 0032): that picker exists because both of its sections own a *pull-request-shaped
        /// selection* the toolbar, `j`/`k`, ⌘K and the focus session all address, and the fleet
        /// owns none — it selects an agent, and nothing outside the screen has an opinion about
        /// which one.
        ///
        /// The agent travels as its **registry id** and never as a display name, which is the
        /// third of the three structural layers that keep this screen about agents rather than
        /// about people: an id is something the registry has and a login is not, so a link cannot
        /// be made to name a person by naming them. `nil` is the whole fleet with nothing
        /// selected; an id no agent carries is shown as such rather than silently ignored.
        case fleet(agentID: String?)
    }

    /// The current phase.
    private(set) var phase: Phase = .launching
    /// The current route within the signed-in window.
    var route: Route = .inbox
    /// Whether the ⌘K palette is up.
    var isCommandPaletteVisible = false
    /// Whether the "watch a repository" dialog is up.
    ///
    /// Here rather than in the inbox's own state because three things raise it: the `+` beside
    /// the sidebar's REPOSITORIES heading, ⇧⌘A from the menu, and the ⌘K palette.
    var isAddingWatchedRepository = false
    /// The folder "Add a local repository…" is confirming, while its sheet is up in the main
    /// window (ADR 0011's 2026-09-23 amendment).
    ///
    /// Here for ``isAddingWatchedRepository``'s reason: the rail's `+` menu, the menu bar and ⌘K
    /// all raise it. Settings → Delegation raises its own, in its own window.
    var localRepositoryDraft: LocalRepositoryDraft?
    /// The tab the Settings window shows.
    ///
    /// It lives here rather than inside ``SettingsView`` because every surface that wants a
    /// *particular* tab is outside that window — the rail's gear, `shepherd://settings/<tab>`
    /// (ADR 0013), the fleet's empty state — and a window that is already open cannot be
    /// re-created with a different initial tab. ``SettingsView`` binds to it, so writing it
    /// switches the tab of an open window and chooses the tab of one about to open.
    var settingsTab: SettingsDeepLinkTab = .account
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
    /// An issue a link or a ⌘K row asked for, waiting for the inbox to reveal it (ADR 0032).
    ///
    /// The same mechanism as ``pendingInboxFilter`` above, and it is a *pending request* rather
    /// than a call into a model for that field's reason: which section is showing and which row
    /// is selected are state ``InboxScreen`` owns, and this container reaches into no model a
    /// screen owns.
    var pendingIssueSelection: Pending<String>?

    /// User preferences.
    let settings: AppSettings
    /// GitHub credentials (Keychain only, ADR 0004).
    let tokenStore: KeychainTokenStore
    /// AI keys (Keychain only, ADR 0007).
    let secretStore: KeychainSecretStore
    /// The window's toast queue; errors are surfaced here, never printed.
    let toasts = ToastCenter()
    /// Which writes are in flight, so every write button can go quiet while its own write runs
    /// and refuse a second click.
    ///
    /// Beside ``toasts`` and for the same reason: both are one user action's feedback, both are
    /// read by every screen that can start a write, and neither belongs to a session — a write
    /// started just before a sign-out still has to release its key.
    let activity = ActionActivity()
    /// Maps sync events to macOS notifications.
    let notifications: NotificationManager
    /// The delegation sheets: one per pull request, at most one on screen (ADR 0011).
    let delegation: DelegationCenter
    /// Posts events to the user's own webhook URL, when they configured one (ADR 0012).
    let webhooks: WebhookDispatcher
    /// Maps Shepherd's events onto webhook deliveries.
    let webhookCoordinator: WebhookCoordinator
    /// Sparkle 2, or an inert stand-in when the build has no update feed and key (ADR 0010).
    let updates: UpdateController
    /// MetricKit crash and hang reports, kept on this Mac only and only when asked for
    /// (ADR 0017). Created inert: it subscribes to nothing until ``applyDiagnosticsSetting()``
    /// sees the opt-in.
    let diagnostics = DiagnosticsReporter()

    /// Usage telemetry (ADR 0036), or `nil` when this build has no key, the level is `off`, or the
    /// first-run notice has not been answered. `nil` is the normal state of a development build.
    private(set) var telemetry: UsageTelemetry?
    /// Remembers what automatic delegation already did, across launches (ADR 0016).
    let autoDelegationStore: AutoDelegationStore
    /// Decides whether a sweep event starts a delegation on its own (ADR 0016).
    let autoDelegation: AutoDelegationCoordinator
    /// Remembers — and shows — every merge a rule queued, across launches (ADR 0018).
    let autoMergeStore: AutoMergeStore
    /// Decides whether the rows a sweep wrote contain anything to merge on its own (ADR 0018).
    let autoMerge: AutoMergeCoordinator
    /// Remembers the merges the user armed while their checks were running (ADR 0037).
    let mergeWhenGreenStore: MergeWhenGreenStore
    /// Fires an armed merge on the sweep that sees its checks go green (ADR 0037).
    let mergeWhenGreen: MergeWhenGreenCoordinator
    /// Owns the track-record backfill and the stored history (ADR 0027).
    ///
    /// Created inert, like the two coordinators below it: it reads nothing and asks GitHub
    /// nothing until somebody presses *Load track record* in Settings → Automation. Owned here
    /// rather than by a screen because a backfill outlives the Settings sheet that started it,
    /// and because the inbox reads its ``TrackRecordCoordinator/historyVersion`` to know when to
    /// recount the badges.
    let trackRecord = TrackRecordCoordinator()
    /// Keeps the on-device ⌘K search index current and answers the palette's queries (ADR 0019).
    ///
    /// Created inert: it holds no corpus and loads no model until the first inbox observation
    /// hands it rows, and with the setting off it never reads a diff or spends an embedding.
    let search: SearchIndexCoordinator
    /// Gives every pull request in the inbox an on-device triage verdict (ADR 0023).
    ///
    /// Created inert, like the search index beside it: it loads no model and classifies nothing
    /// until the first inbox observation hands it rows, and with the switch off — or with the
    /// tiers off — a pass is one `Bool` read.
    let triage: TriageCoordinator
    /// Ranks the saved replies against the thread a reviewer is answering, so the two that fit
    /// are at the top of the insert menu (ADR 0019's embedder, reused).
    ///
    /// Created inert, and it stays inert for a reviewer who never reaches for a saved reply: it
    /// loads no model and holds no vector until a menu is about to open on a thread. Owned here
    /// rather than by a screen because the cache is one vector per saved-reply *body* — the
    /// replies are the same in every composer in every window, and a per-screen cache would
    /// re-embed them each time a popover opened.
    let savedReplySuggestions = SavedReplySuggestionCoordinator()
    /// Summarises a long review thread on-device when a reviewer asks it to (ADR 0007's
    /// on-device-only amendment).
    ///
    /// Created inert, like the coordinator above it: no model is loaded and no session exists
    /// until somebody presses *Summarise* on a thread with at least six comments. Owned here
    /// rather than by the popover because the popover's `@State` survives a click on a different
    /// comment card and is discarded on a trip to the Files tab — the opposite of what a cache of
    /// digests wants, which is to be keyed by the thread and to outlive the panel. Nothing it
    /// holds is persisted or synced: these are colleagues' comments (ADR 0020's argument).
    let threadDigests = ThreadDigestCoordinator()
    /// Notices that the reviewer has written the same finding three times on one repository
    /// (ADR 0029, ADR 0019's embedder reused once more).
    ///
    /// Created inert, like the two coordinators above it: it reads no comment, loads no model and
    /// holds no vector until a sweep has landed rows. Owned here rather than by the review screen
    /// because the pass is per *account* — it reads the last thirty days of the reviewer's own
    /// review comments across every repository at once — and because the vector cache and the
    /// dismissals must outlive a trip to the inbox and back.
    let recurringFindings: RecurringFindingCoordinator
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

    /// Brings the Settings window up.
    ///
    /// Set by ``RootView`` from SwiftUI's `openSettings`, for ``reopenMainWindow``'s reason and
    /// in the same breath: opening a scene is something only a view can do. Not observed by
    /// anything — it is called imperatively, from ``showSettings(_:)`` — so it stays out of the
    /// observation graph.
    @ObservationIgnored var openSettingsWindow: (@MainActor () -> Void)?

    /// The provider router, rebuilt whenever the intelligence settings change.
    private(set) var intelligence: IntelligenceRouter = .disabled

    /// The optional tier-2 reader behind the claims card, or `nil` when the tiers are off
    /// (ADR 0026's amendment).
    ///
    /// Rebuilt beside ``intelligence`` rather than stored once, because "the tiers are off" is a
    /// setting the user can change while a review screen is open, and a seam captured at launch
    /// would keep reading descriptions after they switched the model off. There is no router, no
    /// base URL and no key in it: the description is somebody else's text, so the *only*
    /// implementation of ``ClaimExtracting`` is the on-device one and there may not be another
    /// (ADR 0026, ADR 0007's on-device-only amendment).
    ///
    /// It is on for both model-bearing modes rather than only for `.onDevice`: the mode chooses
    /// whether a *cloud* rung exists, and this feature has none, so `.onDeviceAndCloud` means
    /// the same thing here as `.onDevice`.
    private(set) var claimExtractor: (any ClaimExtracting)?

    /// How a claims line is looked at more closely, or `nil` with the tiers off.
    ///
    /// On-device only for ``claimExtractor``'s reason, and inert until a reviewer clicks
    /// *Look closer* (ADR 0026's 2026-09-22 amendment).
    private(set) var claimChecker: (any ClaimChecking)?

    /// How a description's screenshots are read, or `nil` with the tiers off.
    ///
    /// On-device only for ``claimExtractor``'s reason, `nil` unless
    /// ``AppSettings/screenshotReadingEnabled`` is on as well, and inert until a reviewer clicks
    /// *Read screenshots* on the summary card (ADR 0038 item 4).
    private(set) var screenshotReader: (any DescriptionScreenshotReading)?

    /// The signed-in session, when there is one.
    var session: SignedInSession? {
        if case .signedIn(let session) = phase { return session }
        return nil
    }

    /// How the claims card reads the issue a `fixes #N` claim points at (ADR 0026's amendment).
    ///
    /// The signed-in session's client, or `nil` when there is no session — which is a state and
    /// not a failure: without it the card's issue line says the acceptance criteria were not
    /// checked, which is what it said before there was an issue read at all. Read at click time
    /// rather than captured when a screen is built, like the router the CI diagnosis asks with,
    /// so a card can never hold a client from a session the user has signed out of.
    var issueFetcher: (any IssueFetching)? { session?.github }

    /// Where a description's screenshots are fetched from — the signed-in client, or `nil`.
    var descriptionImageFetcher: (any DescriptionImageFetching)? { session?.github }

    /// How a signed-in session's GitHub client reaches the network, or `nil` for the one real
    /// transport. Only the Debug demo mode passes one.
    @ObservationIgnored private let gitHubTransport: (any HTTPTransport)?
    /// Whether a signed-in session starts the background sweep loop. Only the Debug demo mode
    /// switches it off, because its inbox is a seed that no GitHub answer may prune.
    @ObservationIgnored private let runsSyncLoop: Bool

    /// Creates the container.
    ///
    /// Every parameter past the first three is a seam for the Debug demo mode
    /// (`Shepherd/Debug/DemoMode.swift`), which has to run without touching the installed app's
    /// state; the defaults are what every other build and every test gets.
    /// - Parameters:
    ///   - settings: The preference store.
    ///   - tokenStore: The GitHub credential store.
    ///   - secretStore: The AI-key store.
    ///   - defaults: Where the device-local automation ledgers and dismissals are kept.
    ///   - updates: The updater.
    ///   - spotlightIndex: The system Spotlight index the export writes to (ADR 0021).
    ///   - gitHubTransport: The session's transport, `nil` for `URLSessionTransport`.
    ///   - runsSyncLoop: Whether a session starts its sweep loop.
    init(
        settings: AppSettings = AppSettings(),
        tokenStore: KeychainTokenStore = KeychainTokenStore(),
        secretStore: KeychainSecretStore = KeychainSecretStore(),
        defaults: UserDefaults = .standard,
        updates: UpdateController = UpdateController(),
        spotlightIndex: any SpotlightIndexing = CoreSpotlightIndex(),
        gitHubTransport: (any HTTPTransport)? = nil,
        runsSyncLoop: Bool = true
    ) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.secretStore = secretStore
        self.updates = updates
        self.gitHubTransport = gitHubTransport
        self.runsSyncLoop = runsSyncLoop
        self.recurringFindings = RecurringFindingCoordinator(defaults: defaults)
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
        let autoDelegationStore = AutoDelegationStore(defaults: defaults)
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
        let autoMergeStore = AutoMergeStore(defaults: defaults)
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
        let mergeWhenGreenStore = MergeWhenGreenStore(defaults: defaults)
        self.mergeWhenGreenStore = mergeWhenGreenStore
        self.mergeWhenGreen = MergeWhenGreenCoordinator(
            settings: settings,
            store: mergeWhenGreenStore,
            notify: { payload in
                // Detached, for the same reason as the two notices above it.
                Task { [notifications] in
                    await notifications.present(payload)
                }
            }
        )
        self.search = SearchIndexCoordinator(settings: settings)
        self.triage = TriageCoordinator(settings: settings)
        self.spotlight = SpotlightIndexer(settings: settings, index: spotlightIndex)
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
        // Beside the MetricKit line and for the same reason: one route from the stored level to
        // whether the mechanism exists at all (ADR 0036). The heartbeat follows it, and defers
        // itself when a session's inbox has not spoken yet.
        applyTelemetryLevel()
        recordLaunchHeartbeat()
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
        // Dropped before the route changes and without the closing summary: the queue named pull
        // requests of the account that is leaving, and there is nothing to report about a
        // session the user did not end. A summary still on screen from an earlier session names
        // that account's work too, so it goes with it.
        reviewSession = nil
        reviewSessionSummary = nil
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
        // And the merges armed while their checks ran: each names a pull request of the leaving
        // account, and a decision made about one account's commit must not fire on another's
        // (ADR 0037).
        mergeWhenGreen.reset()
        // Same argument for the digest's device state: the card names the leaving account's pull
        // requests, and "already delivered today" belongs to that account's morning.
        digest.reset()
        // And the search corpus, which is the leaving account's titles and diffs held in memory.
        // Its table went with `eraseAllData()` above — the index is local cache in exactly the
        // sense ADR 0006 means.
        search.reset()
        // And the verdicts, for the same two reasons: they are the leaving account's pull
        // requests described in the model's own words, and the table went with `eraseAllData()`
        // above (ADR 0023).
        triage.reset()
        // And the Spotlight domain, which is the one piece of this account's data that lives
        // *outside* the database `eraseAllData()` just emptied: the system index is not Shepherd's
        // to leave behind (ADR 0021).
        spotlight.reset()
        // And the recurring findings, dismissals included: they name findings the leaving account
        // wrote, and the comments they were computed from went with `eraseAllData()` above. The
        // dismissal set is the same kind of device-local automation state the auto-delegation
        // ledger is, and it is cleared here for the same reason (ADR 0029).
        recurringFindings.reset()
        // And the track record's run state. The rows went with `eraseAllData()` above — they are
        // the leaving account's closed pull requests — and this drops the progress line and the
        // last run's summary, which name that account's repositories (ADR 0027).
        trackRecord.reset()
    }

    private func startSession(for account: Account) async throws {
        let session = try await SignedInSession.make(
            account: account,
            tokenStore: tokenStore,
            sweepInterval: settings.sweepIntervalMinutes * 60,
            transport: gitHubTransport ?? URLSessionTransport()
        )
        phase = .signedIn(session)
        // The watched repositories are the engine's, not the configuration's: they change while
        // the app runs, and signing out to follow a repository would be absurd. Set before
        // `start` so the first sweep usually carries them already; the assignment is a hop
        // through the actor and the loop does not wait for it, so losing that race costs one
        // cycle and nothing else.
        applyWatchedRepositoriesSetting(sweepNow: false)
        // `start` spawns the sweep loop, whose first iteration sweeps immediately — an extra
        // `syncNow()` here only bought a second concurrent sweep on every launch.
        session.start(
            settings: settings,
            notifications: notifications,
            runsSyncLoop: runsSyncLoop,
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
                // The day-event, which needs the rows only for their count: this is the first
                // moment `inbox_size` is knowable, and `recordHeartbeatIfDue` drops every call
                // after the first one of the UTC day (ADR 0036, § 1.1).
                self.recordLaunchHeartbeat()
                guard let database = self.session?.database else { return }
                self.search.considerIndexing(rows: rows, database: database)
                // The fourth consumer of the same rows (ADR 0023), and deliberately a *peer* of
                // the search index rather than something hanging off the end of its pass: the two
                // features share a data source and nothing else, and a triage pass that only ran
                // after an indexing pass would depend on the semantic-search toggle for its
                // quality (`TriageCoordinator` argues it).
                self.triage.considerClassifying(rows: rows, database: database)
                // The fifth consumer of the same rows (ADR 0029), and a peer of the two above for
                // the same reason. It is the one that reads none of them: it needs the *moment* a
                // sweep landed, and then reads the reviewer's own review comments instead. The
                // login comes from the local session rather than from a row, because "the
                // reviewer's own words" is the whole licence this unattended pass runs under. Read
                // through `self.session` for the same reason the database is: capturing the local
                // session here would be a retain cycle.
                if let login = self.session?.account.login {
                    self.recurringFindings.considerScanning(
                        rows: rows,
                        database: database,
                        viewerLogin: login
                    )
                }
            },
            onIssueRows: { [weak self] rows in
                // The issues sweep's only announcement (ADR 0032): it emits no `SyncEvent`, and
                // the rows it wrote are what the second ⌘K pass is about. One consumer, because
                // one feature indexes issues — the digest, the webhooks and automatic merging are
                // all about pull requests and none of them may grow an issue input here.
                guard let self, let database = self.session?.database else { return }
                self.search.considerIndexingIssues(rows: rows, database: database)
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
        confirmMerge(event)
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

    /// Says so when a merge actually lands.
    ///
    /// The merge is the one write whose *landing* nothing else reported. At the button the most
    /// that can honestly be said is "Merge queued for …", because the drain re-checks the head
    /// commit and can park the row instead (ADR 0006) — so ``PullRequestActions`` says nothing
    /// there once the row is really gone, and ``NotificationManager/payload(for:settings:)``
    /// deliberately posts nothing for ``ShepherdSync/SyncEvent/mutationSent(_:)``. Without this
    /// the loop never closed.
    ///
    /// Merges only. An approval already says "Approved …" the moment the drain sent it, so a
    /// second toast per action would be noise rather than news, and the queued half of every
    /// other write is confirmed by the row leaving the queue.
    ///
    /// It also covers the merge this window never queued: a row drained later, by the sweep loop
    /// or after the network came back, arrives here exactly the same way — and so does an
    /// automatic one (ADR 0018). That is deliberate rather than an oversight of
    /// ``PullRequestActions/announcesSuccess``: that flag silences the *queueing* toast for rows
    /// nobody asked for one by one, while a branch that really got merged while nobody was
    /// watching is the one thing about the pass worth saying out loud, once per merge.
    /// - Parameter event: The event the sync engine emitted.
    private func confirmMerge(_ event: SyncEvent) {
        guard case .mutationSent(let sent) = event, case .merged = sent.kind else { return }
        // Built here rather than carried on the event: ``ShepherdSync/SentMutation`` holds the
        // repository and the number and spends no fetch on describing itself, which is the same
        // two fields the draft-conflict notification spells a slug out of.
        let slug = "\(sent.repo.fullName)#\(sent.number)"
        toasts.success(String(localized: "Merged \(slug)."))
        session?.noteMerged(sent.prID)
        scheduleSyncAfterMerge()
    }

    /// The sweep a confirmed merge asks for, coalesced.
    @ObservationIgnored private var syncAfterMergeTask: Task<Void, Never>?

    /// Syncs a few seconds after a merge landed, so the merged pull request leaves the inbox now
    /// rather than at the next scheduled sweep. Coalesced: automatic merging can confirm several
    /// in one drain, and they share one sweep. The delay is for GitHub's search index, which the
    /// inbox query reads and which lags a merge by a moment.
    private func scheduleSyncAfterMerge() {
        guard syncAfterMergeTask == nil else { return }
        syncAfterMergeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppEnvironment.syncAfterMergeDelay))
            guard let self else { return }
            // Cleared on every exit, a cancelled one included, or the coalescing guard above
            // would believe a sweep is still pending and schedule none again.
            self.syncAfterMergeTask = nil
            guard !Task.isCancelled else { return }
            try? await self.session?.syncNow()
        }
    }

    /// How long a confirmed merge waits before its sweep.
    static let syncAfterMergeDelay: Double = 3

    // MARK: - Automatic merging (ADR 0018) and merge when checks pass (ADR 0037)

    /// Considers the rows a sweep just wrote for the two kinds of merge Shepherd queues without a
    /// click at that moment: the opt-in rules (ADR 0018) and the merges the user armed while their
    /// checks were running (ADR 0037).
    ///
    /// With neither armed this is two cheap reads before anything asynchronous is started, which
    /// matters because the inbox observation speaks on every inbox write. Everything that decides
    /// anything is a pure policy in `ShepherdCore`; both writes go through the *same*
    /// ``PullRequestActions/merge(_:method:deletesHeadBranch:)`` the merge sheet's button calls,
    /// so the outbox, the retry, the head-commit preflight and the `pr.merged` webhook all behave
    /// exactly as they do for a merge the user asked for (ADR 0006, ADR 0015's "n ordinary outbox
    /// writes").
    ///
    /// One `Task` for both, in this order, on purpose: a pull request can satisfy the rules *and*
    /// carry an arm — an agent's, approved, and the reviewer pressed *Merge when checks pass* on
    /// top — and two passes that each read the outbox before the other wrote would queue two
    /// merges for it. The second pass therefore sees what the first one queued as writes already
    /// in flight, and waits.
    /// - Parameter rows: Every inbox row the local database now holds.
    private func considerAutoMerge(rows: [PullRequestSummary]) {
        let rulesArmed = settings.autoMerge.isEnabled
        let decisionsArmed = mergeWhenGreen.armedCount > 0
        guard rulesArmed || decisionsArmed, let session else { return }
        Task { [weak self] in
            // Read before either pass rather than per row: one query for the whole batch, and
            // each coordinator adds its own queued ids as it goes.
            var inFlight = await session.pullRequestIDsWithQueuedWrites()
            guard let self else { return }

            if rulesArmed {
                // `announcesSuccess: false` — the pass announces itself once, as a notification,
                // and records every merge in the audit log; a toast per row would be a dozen
                // banners for something nobody was watching. A *failure* still toasts.
                let actions = PullRequestActions(
                    session: session,
                    toasts: self.toasts,
                    activity: self.activity,
                    announcesSuccess: false,
                    telemetry: self.telemetry,
                    // The one helper in the app whose merges nobody pressed: they are counted as
                    // the rule's, not the detail screen's (ADR 0036).
                    mergeSource: .autoRule
                )
                let queued = await self.autoMerge.run(
                    rows: rows,
                    existingOutbox: inFlight,
                    write: { summary, method in
                        // No branch deletion: `deletesHeadBranch` keeps its default. A rule may
                        // only record a decision a human already made (ADR 0018), and nobody
                        // ticked a box about a branch — widening what an unattended rule does
                        // needs a new ADR.
                        await actions.merge(summary, method: method)
                    }
                )
                for write in queued {
                    self.webhookCoordinator.handle(write, database: session.database)
                    // One per merge the rule actually queued (ADR 0036). Skips are not recorded:
                    // the policy reaches a decision for every inbox row on every sweep, so
                    // counting them would be tens of thousands of events a month and would drown
                    // this one.
                    self.telemetry?.record(.autoMergeRuleFired(outcome: .merged))
                }
                inFlight.formUnion(queued.map(\.pullRequest.id))
            }

            if decisionsArmed {
                // `announcesSuccess: false` here too: the pass posts its own notification, and
                // the user is not necessarily looking at the window a toast would land in.
                let actions = PullRequestActions(
                    session: session,
                    toasts: self.toasts,
                    activity: self.activity,
                    announcesSuccess: false,
                    telemetry: self.telemetry,
                    mergeSource: .whenChecksPass
                )
                await self.mergeWhenGreen.run(
                    rows: rows,
                    existingOutbox: inFlight,
                    write: { summary, method, deletesHeadBranch in
                        await actions.merge(
                            summary,
                            method: method,
                            deletesHeadBranch: deletesHeadBranch
                        )
                    }
                )
            }
        }
    }

    // MARK: - The track record (ADR 0027)

    /// The repositories a backfill would read: the ones the inbox knows, in a stable order.
    ///
    /// The inbox's own rows rather than a listing call, which is the whole reason this feature
    /// adds no endpoint beyond the search: Shepherd already knows which repositories the user
    /// reviews in, because it is syncing pull requests from them.
    var trackRecordBackfillRepositories: [RepoRef] {
        guard let session else { return [] }
        var seen = Set<String>()
        var result: [RepoRef] = []
        for row in session.inboxRows where seen.insert(row.repo.fullName.lowercased()).inserted {
            result.append(row.repo)
        }
        return result.sorted()
    }

    /// Starts the one-time backfill, from whichever surface offered it.
    ///
    /// Here rather than on the Settings tab that used to own it, because there are two surfaces
    /// offering the same run since ADR 0027's 2026-09-05 amendment — the tab and the inbox's
    /// notice — and a second copy of "which repositories, read by what, stored where" could only
    /// ever drift from this one. The *progress* is shared without arranging anything: both
    /// surfaces read ``trackRecord``, which is the coordinator that owns the run, so they show
    /// the same line at the same moment.
    func startTrackRecordBackfill() {
        guard let session else { return }
        trackRecord.start(
            repos: trackRecordBackfillRepositories,
            reader: session.github,
            store: session.database
        )
    }

    /// Re-reads how many outcomes are on disk, for the two surfaces that show a count.
    ///
    /// One indexed `SELECT COUNT(*)`. It is asked for rather than observed because only two
    /// things change it — a finished run and *Clear history* — and both bump
    /// ``TrackRecordCoordinator/historyVersion``, which is what the callers watch.
    func refreshTrackRecordCount() async {
        guard let session else { return }
        await trackRecord.refreshStoredCount(database: session.database)
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
        // A repository task has its own entry point (no webhook, no re-sync); routing it there
        // from here means the sheet's "Choose folder…" rebuild, which calls this with whatever
        // context it had, cannot accidentally give one the pull-request treatment. The context
        // travels as it is, so the rebuild replaces that task's sheet rather than adding a second
        // task beside it.
        if context.isRepositoryTask {
            guard !automatic else { return }
            openRepositoryTask(context, task: task)
            return
        }
        let onDidPush: @MainActor () async -> Void = { [weak self] in
            // The agent's commits are on the pull request now; refresh so the review screen
            // shows the new head instead of the one the user delegated from.
            await self?.syncNow()
        }
        let onDidFinish: @MainActor (DelegationOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.webhookCoordinator.handle(outcome, database: self.session?.database)
            // Beside the webhook and for the same reason: this closure is where a run ends,
            // whichever surface started it (ADR 0036).
            self.telemetry?.record(.delegationFinished(outcome: Self.telemetryOutcome(outcome.status)))
        }
        // The run, not the sheet: every surface below *opens* a sheet, and a sheet nobody presses
        // Start in has delegated nothing. ADR 0016 arms exactly one rule that may start a run
        // unattended — red CI — and ADR 0029 is explicit that a recurring finding stays a
        // suggestion to a person, so every other origin is `.manual` (ADR 0036).
        let onDidBegin: @MainActor () -> Void = { [weak self] in
            self?.telemetry?.record(.delegationStarted(trigger: .manual))
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
            onDidFinish: onDidFinish,
            onDidBegin: onDidBegin,
            // Only the attended path gets one (plan §3.E): the sheet's ✨ button drafts the task
            // text, and the reviewer still presses Run.
            brief: agentBriefDrafter()
        )
        if let task, !model.isBusy {
            model.task = task
        }
    }

    /// Opens the delegation sheet for a **new** free-text task on a repository (ADR 0011's
    /// 2026-09-23 amendment).
    ///
    /// Always a new task, whatever else is running or finished in the repository: each task has
    /// its own identity, branch and worktree, so a second one never waits for, reveals or replaces
    /// the first. Going back to an existing task is ``reopenRepositoryTask(_:)``.
    ///
    /// The same ``DelegationCenter`` every other delegation goes through, so the guardrails
    /// (turn cap or *No limit*, spend cap, permission mode, allowed tools), the worktree
    /// isolation, the transcript and "Shepherd itself pushes nothing" are the same code. Three
    /// things are left out, each because there is nothing for it to talk about:
    ///
    /// - **No `delegation.finished` webhook.** Its payload is a pull request's identity
    ///   (ADR 0012's envelope: node id, repository, number), and a task has no number; sending
    ///   `0` would be a payload that lies. Telemetry's enum-only count still records the run.
    /// - **No re-sync after a push.** The branch is new and no pull request carries it, so a sweep
    ///   would find nothing that changed.
    /// - **No brief drafter**, for the issue path's reason: the ✨ brief is built from a pull
    ///   request's detail, and a repository task has none.
    ///
    /// Never automatic: ``DelegationCenter/startAutomatically(context:task:settings:toasts:onDidPush:onDidFinish:onDidBegin:)``
    /// refuses the origin outright (ADR 0016).
    /// - Parameters:
    ///   - repo: The repository. Without a linked checkout the sheet opens on its "Choose
    ///     folder…" state.
    ///   - task: A prefilled task text, when the caller has one.
    /// - Returns: The delegation now on screen.
    @discardableResult
    func startRepositoryDelegation(_ repo: RepoRef, task: String? = nil) -> DelegationModel {
        openRepositoryTask(.repository(repo), task: task)
    }

    /// Puts one of a repository's tasks back on screen as it is — running, finished or failed —
    /// from the rail's *Agent tasks* submenu or ⌘K.
    /// - Parameter model: A task from ``DelegationCenter/repositoryTasks(for:)``.
    func reopenRepositoryTask(_ model: DelegationModel) {
        delegation.present(model)
    }

    /// Opens a repository task's sheet under a given identity: a fresh one for a new task, the
    /// sheet's own for the "Choose folder…" rebuild.
    @discardableResult
    private func openRepositoryTask(_ context: DelegationContext, task: String?) -> DelegationModel {
        let onDidFinish: @MainActor (DelegationOutcome) -> Void = { [weak self] outcome in
            self?.telemetry?.record(.delegationFinished(outcome: Self.telemetryOutcome(outcome.status)))
        }
        let onDidBegin: @MainActor () -> Void = { [weak self] in
            self?.telemetry?.record(.delegationStarted(trigger: .manual))
        }
        let model = delegation.open(
            context: context,
            settings: settings,
            toasts: toasts,
            onDidFinish: onDidFinish,
            onDidBegin: onDidBegin,
            brief: nil
        )
        if let task, !model.isBusy {
            model.task = task
        }
        return model
    }

    /// "Add a local repository…" from the main window: pick a clone, read its `origin`, and put
    /// the confirmation sheet up (``AddLocalRepositorySheet``).
    ///
    /// The panel runs first and the sheet only appears once git has answered, so a cancelled
    /// panel leaves nothing behind.
    func addLocalRepository() {
        Task { @MainActor [weak self] in
            guard let draft = await LocalRepositoryDraft.choose() else { return }
            self?.localRepositoryDraft = draft
        }
    }

    /// Asks for a folder and links it as a repository's local checkout (ADR 0039's map).
    ///
    /// The rail's "Link a local checkout…" on a watched repository that has none, and the step
    /// "Start an agent…" offers first in that case. Only the checkout is written; the repository
    /// is already watched, or the row would not be there.
    /// - Parameter repo: The repository.
    /// - Returns: Whether a folder was linked.
    @discardableResult
    func chooseLocalCheckout(for repo: RepoRef) -> Bool {
        guard let url = FolderPicker.choose(
            title: String(localized: "Choose the local clone of \(repo.fullName)")
        ) else { return false }
        settings.setLocalCheckout(url, forRepoNamed: repo.fullName)
        return true
    }

    /// Hands an issue to the configured assistant (ADR 0032's 2026-09-04 amendment).
    ///
    /// The same ``DelegationCenter`` a pull-request delegation goes through, so the worktree
    /// isolation, the one-run-per-target rule, the transcript and "Shepherd itself publishes
    /// nothing" are the same code. What differs is what the run is allowed to do with the result,
    /// and that is said by the preamble the origin selects — see ``DelegationPrompt``.
    ///
    /// The task text is rendered here and handed in, exactly as an automatic delegation hands in
    /// its rendered rule template (ADR 0016): the body is a fetched detail the *section* has and
    /// a context does not, and a brief that quoted no description would be a worse brief.
    /// - Parameters:
    ///   - row: The issue.
    ///   - body: The issue body as Markdown source, when the panel has read it.
    ///   - onDidStart: Called once the run is actually running, so the caller can record the
    ///     handover on GitHub. Called *there* rather than on the click on purpose: a handover
    ///     comment posted before the worktree exists would describe work nobody is doing.
    /// - Returns: The delegation now on screen.
    @discardableResult
    func startIssueDelegation(
        _ row: IssueRowSummary,
        body: String = "",
        onDidStart: (@MainActor (DelegationStart) -> Void)? = nil
    ) -> DelegationModel {
        let context = DelegationContext.issue(row)
        let onDidPush: @MainActor () async -> Void = { [weak self] in
            // The branch is on GitHub now, so the next sweep is what turns it into a row.
            await self?.syncNow()
        }
        let onDidFinish: @MainActor (DelegationOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.webhookCoordinator.handle(outcome, database: self.session?.database)
            // Beside the webhook and for the same reason: this closure is where a run ends,
            // whichever surface started it (ADR 0036).
            self.telemetry?.record(.delegationFinished(outcome: Self.telemetryOutcome(outcome.status)))
        }
        // The run, not the sheet: every surface below *opens* a sheet, and a sheet nobody presses
        // Start in has delegated nothing. ADR 0016 arms exactly one rule that may start a run
        // unattended — red CI — and ADR 0029 is explicit that a recurring finding stays a
        // suggestion to a person, so every other origin is `.manual` (ADR 0036).
        let onDidBegin: @MainActor () -> Void = { [weak self] in
            self?.telemetry?.record(.delegationStarted(trigger: .manual))
        }
        let announce: @MainActor (DelegationStart) -> Void = { [weak self] start in
            guard let self else { return }
            self.webhookCoordinator.handle(start, database: self.session?.database)
            onDidStart?(start)
        }
        let model = delegation.open(
            context: context,
            settings: settings,
            toasts: toasts,
            onDidPush: onDidPush,
            onDidFinish: onDidFinish,
            onDidBegin: onDidBegin,
            onDidStart: announce,
            // No drafter, and this is a missing argument rather than a check. The ✨ button's
            // brief is built from a *pull request* — `AgentBriefDrafter.live` reads a
            // `PullRequestDetail` by node id and `AgentBriefRequest` is shaped around a head
            // commit and a review finding — and an issue has neither. A button that could only
            // ever fail is worse than no button, and drafting an issue brief properly is its own
            // piece of work (recorded in ADR 0032's 2026-09-04 amendment).
            brief: nil
        )
        if !model.isBusy {
            model.task = IssueDelegationPrompt.render(
                template: context.taskTemplate ?? IssueDelegationPrompt.defaultTemplate,
                issue: row,
                body: body
            )
        }
        return model
    }

    /// Sends one confirmed message to the session that wrote the code (ADR 0030).
    ///
    /// The same ``DelegationCenter`` a button press goes through, so the one-run-per-pull-request
    /// rule, the worktree isolation, the transcript and "Shepherd never pushes" are the same code
    /// — and the run is *not* automatic: the reviewer pressed Send in a sheet that showed the
    /// message verbatim, which is the press ADR 0011 asks for. Nothing else happens: no thread is
    /// resolved, no review is submitted, no automatic-delegation rule is consulted or recorded.
    ///
    /// No brief drafter is passed, and the omission is the point: the text is the reviewer's own
    /// words, already confirmed, and there is nothing here for a model to write.
    /// - Parameters:
    ///   - context: The finding, with its return address in ``DelegationContext/session``.
    ///   - message: The message, exactly as the confirmation sheet showed it.
    /// - Returns: The delegation now on screen, or `nil` when one was already running for this
    ///   pull request and was revealed instead.
    @discardableResult
    func sendToSession(_ context: DelegationContext, message: String) -> DelegationModel? {
        let onDidPush: @MainActor () async -> Void = { [weak self] in
            await self?.syncNow()
        }
        let onDidFinish: @MainActor (DelegationOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.webhookCoordinator.handle(outcome, database: self.session?.database)
            // Beside the webhook and for the same reason: this closure is where a run ends,
            // whichever surface started it (ADR 0036).
            self.telemetry?.record(.delegationFinished(outcome: Self.telemetryOutcome(outcome.status)))
        }
        // The run, not the sheet: every surface below *opens* a sheet, and a sheet nobody presses
        // Start in has delegated nothing. ADR 0016 arms exactly one rule that may start a run
        // unattended — red CI — and ADR 0029 is explicit that a recurring finding stays a
        // suggestion to a person, so every other origin is `.manual` (ADR 0036).
        let onDidBegin: @MainActor () -> Void = { [weak self] in
            self?.telemetry?.record(.delegationStarted(trigger: .manual))
        }
        let model = delegation.open(
            context: context,
            settings: settings,
            toasts: toasts,
            onDidPush: onDidPush,
            onDidFinish: onDidFinish,
            onDidBegin: onDidBegin,
            // See above: a confirmed message is not a field to draft into.
            brief: nil
        )
        // A run already in flight for this pull request owns its prompt and its transcript; the
        // centre revealed it rather than replacing it, and this message is not sent twice.
        guard !model.isBusy else { return nil }
        model.task = message
        model.start()
        return model
    }

    /// Opens the delegation sheet with a **rule** for the repository's agent instructions
    /// (ADR 0029).
    ///
    /// Everything ADR 0011 guarantees is the code above, reused: the same centre, the same
    /// worktree isolation and caps, the same "Shepherd never pushes", the same one-run-per-pull-request
    /// rule. Two things differ, and both are about the *text*:
    ///
    /// - the task is prefilled with ``RecurringFindingRule/template(for:)`` — the three quotes and
    ///   a sentence, which is the whole feature with no model configured at all;
    /// - the ✨ button is wired to ``RuleBriefDrafter`` rather than ``AgentBriefDrafter/live(router:viewerLogin:detail:)``,
    ///   so the drafted text asks for a rule instead of a fix.
    ///
    /// There is no `automatic` parameter, and that omission is the ADR 0016 rule expressed as
    /// missing code: a recurring finding is a suggestion to a person, so nothing can turn it into
    /// an unattended run.
    /// - Parameters:
    ///   - finding: The recurring finding the rule is drafted from.
    ///   - pullRequest: The pull request the reviewer is on — the worktree the agent gets.
    func startRuleDelegation(finding: RecurringFinding, pullRequest: PullRequestSummary) {
        let context = RecurringFindingRule.context(
            finding: finding,
            pullRequest: pullRequest,
            viewerLogin: session?.account.login
        )
        let onDidPush: @MainActor () async -> Void = { [weak self] in
            await self?.syncNow()
        }
        let onDidFinish: @MainActor (DelegationOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.webhookCoordinator.handle(outcome, database: self.session?.database)
            // Beside the webhook and for the same reason: this closure is where a run ends,
            // whichever surface started it (ADR 0036).
            self.telemetry?.record(.delegationFinished(outcome: Self.telemetryOutcome(outcome.status)))
        }
        // The run, not the sheet: every surface below *opens* a sheet, and a sheet nobody presses
        // Start in has delegated nothing. ADR 0016 arms exactly one rule that may start a run
        // unattended — red CI — and ADR 0029 is explicit that a recurring finding stays a
        // suggestion to a person, so every other origin is `.manual` (ADR 0036).
        let onDidBegin: @MainActor () -> Void = { [weak self] in
            self?.telemetry?.record(.delegationStarted(trigger: .manual))
        }
        let model = delegation.open(
            context: context,
            settings: settings,
            toasts: toasts,
            onDidPush: onDidPush,
            onDidFinish: onDidFinish,
            onDidBegin: onDidBegin,
            brief: ruleBriefDrafter()
        )
        // Never over a run in flight: that sheet's task belongs to the prompt the agent is
        // already working from (``DelegationCenter/open(context:settings:toasts:onDidPush:onDidFinish:brief:)``
        // reveals the running model unchanged).
        if !model.isBusy {
            model.task = RecurringFindingRule.template(for: finding)
        }
    }

    /// Builds the rule drafter for the ✨ button of a rule delegation (ADR 0029).
    ///
    /// The same three pieces ``agentBriefDrafter()`` reads, read the same way and for the same
    /// reason: on the main actor, captured as values, so the drafter's closure never reaches back
    /// into this class from a background task.
    /// - Returns: The drafter, or `nil` when no account is signed in.
    private func ruleBriefDrafter() -> AgentBriefDrafter? {
        guard let session else { return nil }
        let database = session.database
        return RuleBriefDrafter.live(
            router: intelligence,
            viewerLogin: session.account.login,
            detail: { prID in
                guard let detail = try? await database.fetchPullRequestDetail(id: prID) else {
                    return nil
                }
                return detail
            }
        )
    }

    /// Builds the delegation sheet's brief drafter from the current tiers and session (plan §3.E).
    ///
    /// The three pieces are read *here*, on the main actor, and captured as values — the router
    /// is a `Sendable` snapshot, the database is a `Sendable` class, the login is a string — so
    /// the drafter's closure never reaches back into this class from a background task.
    /// - Returns: The drafter, or `nil` when no account is signed in (there is no database to
    ///   read the pull request from, so there would be nothing to draft from either).
    private func agentBriefDrafter() -> AgentBriefDrafter? {
        guard let session else { return nil }
        let database = session.database
        return AgentBriefDrafter.live(
            router: intelligence,
            viewerLogin: session.account.login,
            detail: { prID in
                // The cached row, never a fetch: the brief is drafted from what the reviewer
                // already has on screen, and a sheet must not wait on the network to offer it.
                guard let detail = try? await database.fetchPullRequestDetail(id: prID) else {
                    return nil
                }
                return detail
            }
        )
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
            // Both corpora, because it is one switch (ADR 0032).
            search.considerIndexingIssues(rows: session.issueRows, database: session.database)
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

    /// Starts or stops structured triage to match the setting (ADR 0023).
    ///
    /// Called whenever ``AppSettings/structuredTriageEnabled`` changes — from the toggle in
    /// Settings, or because a downloaded settings document carried the flag from another Mac
    /// (ADR 0014). One route for both, exactly as ``applySemanticSearchSetting()`` is.
    ///
    /// Switching it off empties the table rather than keeping the verdicts warm, for the search
    /// index's reason: a switch that left a verdict per pull request on disk would be lying about
    /// what it is named after. Re-enabling costs one local pass.
    /// Tells the running sweep which repositories to watch (ADR 0005's 2026-09-16 amendment).
    ///
    /// Called at sign-in and whenever ``AppSettings/watchedRepositories`` changes — one route for
    /// both, exactly as ``applySemanticSearchSetting()`` is. The engine takes the new facets for
    /// its next cycle, and a sweep is asked for straight away so that adding a repository fills
    /// the list now rather than in up to ten minutes.
    ///
    /// Removing one needs nothing extra: the sweep stops returning those rows, and the ordinary
    /// prune takes them out of the inbox.
    /// - Parameter sweepNow: Whether to ask for a sweep immediately. False at sign-in, where the
    ///   loop's own first iteration is about to sweep anyway.
    func applyWatchedRepositoriesSetting(sweepNow: Bool = true) {
        guard let session else { return }
        let queries = InboxQuery.watching(settings.watchedRepositories)
        let engine = session.syncEngine
        Task {
            await engine.setAdditionalQueries(queries)
            guard sweepNow else { return }
            try? await engine.syncNow()
        }
    }

    func applyStructuredTriageSetting() {
        guard let session else {
            triage.reset()
            return
        }
        if settings.structuredTriageEnabled {
            triage.considerClassifying(rows: session.inboxRows, database: session.database)
            return
        }
        // The delete is a write, so it is awaited in a task of its own; only the database — which
        // is `Sendable` — crosses into it.
        let database = session.database
        Task { [weak self] in
            guard let self else { return }
            await self.triage.disable(database: database)
        }
    }

    /// Re-indexes and re-classifies one pull request because the review screen just stored its
    /// diff (ADR 0019, ADR 0023).
    ///
    /// Promptness only, for both: the stored `detailFetchedAt` moves, so the next ordinary pass
    /// would pick the pull request up regardless. The screen announcing it just means the diff is
    /// searchable — and the verdict is made from the change rather than from the title — before
    /// the next sweep rather than after it.
    /// - Parameter prID: The pull request whose detail arrived.
    func searchIndexDidLoadDetail(prID: String) {
        guard let session else { return }
        search.indexAfterDetailLoad(prID: prID, database: session.database)
        triage.classifyAfterDetailLoad(prID: prID, database: session.database)
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

    /// Builds or tears down usage telemetry to match the level (ADR 0036).
    ///
    /// Called at launch, from the picker in Settings, and when an applied settings document
    /// carried a level from another Mac — the same three callers ``applyDiagnosticsSetting()`` has,
    /// and idempotent for the same reason.
    func applyTelemetryLevel() {
        if let telemetry {
            telemetry.apply(level: settings.telemetryLevel)
            if !settings.telemetryLevel.sendsEvents {
                self.telemetry = nil
            }
            return
        }
        telemetry = UsageTelemetry.make(settings: settings)
        telemetry?.startFlushing()
    }

    /// Records `app_active_day` when this UTC day has not been counted yet (ADR 0036, § 1.1).
    ///
    /// Every value it sends is a bucket or a flag read from settings — never a repository name, a
    /// count, or anything the allow-list does not already contain.
    ///
    /// Called at launch *and* from the inbox observation, because of the guard below: a session
    /// whose first `SELECT` has not come back yet would report `inbox_size: 0` and then mark the
    /// day as sent, so the number would be wrong for every installation on every day. This is the
    /// same hazard ``startDigestChecks()`` avoids with the same flag. With no session at all there
    /// is nothing to wait for — a signed-out Mac is still an active installation and must be
    /// counted — so only a *loading* session defers. ``UsageTelemetry/recordHeartbeatIfDue(_:)``
    /// is idempotent per UTC day, which is what makes calling it on every inbox update free.
    func recordLaunchHeartbeat() {
        if let session, !session.hasLoadedInbox { return }
        telemetry?.recordHeartbeatIfDue { [settings, session] in
            .appActiveDay(
                repoCount: CountBucket(count: settings.watchedRepositories.count),
                inboxSize: CountBucket(count: session?.inboxRows.count ?? 0),
                diffRenderer: settings.diffRenderer == .native ? .native : .monaco,
                intelligence: Self.intelligenceChoice(for: settings),
                webhooks: settings.webhooksEnabled,
                settingsSync: settings.settingsSyncEnabled,
                autoMerge: settings.autoMerge.isEnabled,
                autoDelegation: settings.autoDelegation.isEnabled,
                digest: settings.digest.isEnabled,
                menuBar: settings.showsMenuBarExtra,
                diagnostics: settings.diagnosticsEnabled
            )
        }
    }

    /// Reduces the intelligence settings to the values the allow-list knows.
    ///
    /// `.cloud` has no source here: Shepherd's cloud rung is never on *without* the on-device one,
    /// so the mode maps to three of the four cases and the fourth stays unused rather than being
    /// faked.
    /// - Parameter settings: The settings to read.
    /// - Returns: The reported choice.
    /// Reduces a finished run to the value the allow-list knows.
    /// - Parameter status: How the run ended.
    /// - Returns: The reported outcome.
    private static func telemetryOutcome(_ status: DelegationOutcome.Status) -> DelegationOutcomeChoice {
        switch status {
        case .finished: return .finished
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    private static func intelligenceChoice(for settings: AppSettings) -> IntelligenceChoice {
        switch settings.intelligenceMode {
        case .off: return .none
        case .onDevice: return .onDevice
        case .onDeviceAndCloud: return .both
        }
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
                // The wide observation, closed rows included: the digest's second issue line is
                // about an issue an agent's pull request just closed (ADR 0032).
                issues: session.issueRows,
                parkedReviewCount: session.conflictedOutboxCount,
                failedWriteCount: session.failedOutboxCount
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
        // The digest is the only notification that routes here, so a click on one is a digest
        // that was opened (ADR 0036).
        telemetry?.record(.digestOpened(source: .notification))
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
            openAIModel: settings.openAICompatibleModel,
            // Empty and `false` on a fresh install, and not sent at all in that state — see
            // `AppSettings.openAICompatibleSovereigntyCountries` (plan §3.K).
            openAISovereigntyCountries: settings.openAICompatibleSovereigntyCountries,
            openAIZeroRetention: settings.openAICompatibleZeroRetention
        )
        let key = settings.cloudProviderKind == .anthropic
            ? KeychainSecretStore.Key.anthropicAPIKey
            : KeychainSecretStore.Key.openAICompatibleAPIKey
        configuration.cloudAPIKey = ((try? secretStore.secret(for: key)) ?? nil) ?? ""
        intelligence = IntelligenceRouter(configuration: configuration)
        // Created here rather than held from launch, and created *inert*: nothing is loaded and
        // no session exists until a reviewer expands a claims card (ADR 0026's amendment).
        claimExtractor = settings.intelligenceMode == .off ? nil : OnDeviceClaimExtractor()
        claimChecker = settings.intelligenceMode == .off ? nil : OnDeviceClaimChecker()
        // Two switches: the tiers, and the screenshot switch that stands for its download host
        // (off by default, ADR 0038 item 4). With either off there is no reader, so no button.
        screenshotReader = settings.intelligenceMode == .off || !settings.screenshotReadingEnabled
            ? nil : OnDeviceScreenshotReader()
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

    /// The pull request the visible screen's cursor is on, published for the command palette.
    ///
    /// The palette is presented from ``SignedInRootView`` rather than from a screen, so it cannot
    /// see the inbox's cursor or the review screen's subject — and a palette that offers
    /// "Approve pull request" with nothing selected raises a ``PendingAction`` the screen quietly
    /// drops. Both screens write it (``InboxScreen`` from its selected row, ``ReviewScreen`` from
    /// the pull request it is showing) so the palette can leave a command out instead, and it is
    /// exactly the row those commands' ``request(_:)`` would act on.
    ///
    /// Never cleared on disappear: the route switch tears one screen down and builds the other,
    /// in an order nothing here guarantees, and a clear that lost that race would blank the
    /// palette for the screen that just arrived. The screen that arrives overwrites it instead.
    var selectedPullRequest: PullRequestSummary?

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
            endReviewSession(announcing: false)
        }
        pendingReviewVerdict = verdict
        route = .review(prID: prID)
    }

    /// Reads and clears the verdict the review screen should open its composer on.
    func consumePendingReviewVerdict() -> ReviewVerdict? {
        defer { pendingReviewVerdict = nil }
        return pendingReviewVerdict
    }

    /// Opens one issue in the inbox's issues section (ADR 0032).
    ///
    /// ``openReview(prID:composing:)``'s sibling, and the one entry point every surface that
    /// names an issue goes through — a `shepherd://issue/…` link, a ⌘K result, a linked-issue row
    /// a later sprint adds — so "reveal this issue" has one implementation for the same reason
    /// opening a review does.
    ///
    /// A running focus session ends first, exactly as it does when a pull request that is not
    /// under its cursor is opened: the user has left the queue, and a session bar naming a pull
    /// request while the screen below it shows an issue would be worse than no bar.
    /// - Parameter issueID: The issue's GraphQL node id.
    func openIssue(issueID: String) {
        if reviewSession != nil { endReviewSession(announcing: false) }
        route = .inbox
        pendingIssueSelection = Pending(issueID)
    }

    /// Clears the issue request after the inbox has revealed it.
    func clearPendingIssueSelection() {
        pendingIssueSelection = nil
    }

    /// Opens the fleet, on one agent or on the whole list.
    ///
    /// ``openIssue(issueID:)``'s sibling, and the one entry point every surface that names an
    /// agent goes through — a `shepherd://fleet/…` link, a ⌘K row, the rail, the track-record
    /// popover's footer — so "show me this agent" has one implementation for the same reason
    /// opening a review or an issue does.
    ///
    /// A running focus session ends first and **without announcing**, exactly as opening an issue
    /// does and for that method's reason: the user has left the queue, so the session ends rather
    /// than leaving a bar on screen naming a pull request the screen below it is not about — and
    /// the completion view is raised *after* the route changes, so a summary announced here would
    /// never be shown and would instead sit in this container until the next time the user
    /// happened to reach the inbox. That is the toast it replaced: a report about something the
    /// reader has since stopped doing.
    ///
    /// There is no `pending…` request beside this one, unlike the issue above: the fleet's
    /// selection is *in* the route, so there is no screen-owned state for the container to reach
    /// into and nothing to clear afterwards.
    /// - Parameter agentID: The registry id of the agent to select, or `nil` for the whole fleet.
    func openFleet(agentID: String? = nil) {
        if reviewSession != nil { endReviewSession(announcing: false) }
        // The fleet screen has no pull-request cursor and handles no review command, so the row
        // the inbox left behind would only put dead entries in the palette.
        selectedPullRequest = nil
        route = .fleet(agentID: agentID)
    }

    /// Shows the Settings window on `tab`.
    ///
    /// The one way in, for the rail's gear, `shepherd://settings/<tab>` (ADR 0013), the fleet's
    /// empty state and the delegation sheet alike. There used to be two presentations — the
    /// `Settings` scene behind ⌘, and a sheet on the inbox screen — which is how a window with no
    /// close button came to exist, and how sixteen links came to open sixteen windows.
    ///
    /// No `endReviewSession` beside it, unlike ``openReview(prID:composing:)`` and its siblings:
    /// Settings is a *second window*, not a route, so a running focus session keeps its queue and
    /// the user comes back to it.
    /// - Parameter tab: The tab to show.
    func showSettings(_ tab: SettingsDeepLinkTab) {
        settingsTab = tab
        openSettingsWindow?()
        // …and in front of the main window, which `openSettings()` arranges only when it *creates*
        // the window. An already-open Settings window stays where it is: the 2026-09-09 live test
        // watched `shepherd://settings/<tab>` change the tab behind the main window, where nobody
        // could see it — the link looked like it had done nothing, and the ⌘W after it closed the
        // wrong window. One runloop hop, because on the very first open the window does not exist
        // yet when this line runs; that is also the case that needs no help.
        Task { @MainActor in activateSettingsWindow() }
    }

    /// Brings the Settings window forward, if there is one.
    ///
    /// Deliberately silent when no window carries ``settingsWindowIdentifier``: the alternative —
    /// raising whichever window is first — would raise the *main* window over the settings the
    /// caller just asked for, which is the bug this exists to fix.
    private func activateSettingsWindow() {
        // `activate()` for ``activateMainWindow()``'s reason: a `shepherd://` link or a click on a
        // gear is the user's own activation request, which is what macOS 14's cooperative
        // activation is for.
        NSApplication.shared.activate()
        NSApplication.shared.windows
            .first { $0.identifier?.rawValue == Self.settingsWindowIdentifier }?
            .makeKeyAndOrderFront(nil)
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
    /// What the last session did, for as long as its completion view is on screen.
    ///
    /// The end of a focus session used to be a seven-second toast — the same banner a failed
    /// clipboard copy gets — for the one moment in this app where somebody has finished
    /// something. It is a small view on the inbox now, and the summary is held here rather than
    /// by that screen because ``endReviewSession(announcing:)`` is also what routes back to it:
    /// the screen that shows this is built *after* the route changes, so the numbers have to be
    /// waiting for it rather than handed to it.
    ///
    /// Transient for ``reviewSession``'s reason, and one degree more so: it describes a sitting
    /// that has already ended, so nothing about it belongs in ``AppSettings`` or in the encrypted
    /// settings document (ADR 0014).
    var reviewSessionSummary: ReviewSession.Summary?

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
    /// - Parameter announcing: Whether the completion view comes up. `false` for the two exits
    ///   that are somebody *navigating away* rather than finishing — opening a pull request that
    ///   is not the one under the cursor, and opening an issue — because both of those set
    ///   ``route`` again immediately afterwards, so a summary raised here would not be shown and
    ///   would instead sit in this container until the next time the user happened to reach the
    ///   inbox. That is exactly the toast this replaced: a report about something the reader has
    ///   since stopped doing.
    func endReviewSession(announcing: Bool = true) {
        guard let running = reviewSession else { return }
        // Cleared first: `route = .inbox` below goes through nothing that could re-enter, but
        // `closeReview()` calls this method, and a session still set would recurse.
        reviewSession = nil
        // Before the `announcing` guard, because every exit is a finished sitting — including the
        // two that navigate away without raising the completion view (ADR 0036).
        let summary = running.summary()
        telemetry?.record(
            .focusSessionCompleted(
                queueSize: CountBucket(count: summary.total),
                completed: summary.remaining == 0
            )
        )
        route = .inbox
        guard announcing else { return }
        // Set after the route rather than before it, so the inbox is what the completion view
        // comes up over. There is no toast beside it: one completion surface, or the two would
        // say the same thing twice and the quieter one would win by staying.
        reviewSessionSummary = summary
    }

    /// Closes the completion view.
    func clearReviewSessionSummary() {
        reviewSessionSummary = nil
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
    /// Used to *exclude* that window in ``activateMainWindow()`` and to *find* it in
    /// ``activateSettingsWindow()``, so if Apple ever renames it the effect is "the wrong window
    /// comes forward, or none does", never a crash.
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

    /// Closes whichever window has the keyboard — the ⌘W the menu bar otherwise does not have.
    ///
    /// AppKit's own `performClose(_:)` rather than a SwiftUI dismissal, because the item behind
    /// this has to close *whatever* is key: the Settings scene, which no view of ours owns, as
    /// readily as the main window. It also inherits the behaviour the red button has — a window
    /// with a sheet up refuses and says so — instead of inventing a second answer to "can this
    /// close?". Nothing happens when no window is key, which is the menu-bar-only state.
    func closeKeyWindow() {
        NSApplication.shared.keyWindow?.performClose(nil)
    }
}
