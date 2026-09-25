import Foundation
import GitHubKit
import Observation
import ShepherdCore
import ShepherdPersistence
import ShepherdSync

/// Everything that only exists while an account is signed in.
///
/// Wiring order follows `Packages/ShepherdKit/README.md`: database → client (Keychain token
/// provider, SQLite conditional cache, agent detector seeded with the user's registry
/// overrides) → sync engine.
@MainActor
@Observable
final class SignedInSession {
    /// The signed-in account.
    let account: Account
    /// The local source of truth (ADR 0006).
    let database: DatabaseManager
    /// The GitHub façade.
    let github: GitHubClient
    /// The provenance rules this session's rows were labelled with (ADR 0008).
    ///
    /// The same value ``github`` was built with, kept rather than let go of. It is held here for
    /// one reason: it is the only thing in the app that can turn an **agent-registry id** back
    /// into a display name, and `shepherd://fleet/<agent-id>` addresses the fleet by id
    /// (ADR 0035) while a stored outcome remembers only the name
    /// (``ShepherdCore/PullRequestOutcome/agentName``). Without it a link would have nothing to
    /// resolve against and would have to fall back to the list.
    ///
    /// A value type, seeded once from the user's registry overrides at sign-in, so this is a
    /// second reference and not a second detector: editing the registry in Settings restarts the
    /// session, which is what makes one snapshot per session correct rather than stale.
    let agentDetector: AgentDetector
    /// The background sync loops.
    let syncEngine: SyncEngine

    /// When the last successful sweep finished, for the title-bar indicator.
    var lastSyncedAt: Date?
    /// Whether a sweep has run all the way to the end since this session started.
    ///
    /// Three near-neighbours that mean different things, and the inbox needs this one:
    /// ``lastSyncedAt`` is a *timestamp* and is also moved by a queued write reaching GitHub;
    /// ``hasLoadedInbox`` says the local `SELECT` came back, which on a fresh database is true
    /// within a second of signing in while the sweep's search queries are still in flight. This is
    /// the only one that answers "may a surface claim there is nothing waiting for you" — until it
    /// is `true`, an empty list means "not asked yet" rather than "nobody is waiting", and those
    /// are opposite claims drawn with the same pixels.
    private(set) var hasCompletedFirstSweep = false
    /// Whether a manual sync is in flight.
    var isSyncing = false
    /// The most recent sync failure, shown as a dot in the title bar, in the user's language.
    ///
    /// Rendered from the failure's typed error when it arrives (`SyncFailure.localizedMessage`),
    /// not copied from its English `message` (ADR 0022, 2026-09-22 amendment).
    var lastSyncError: String?
    /// How many mutations are waiting in the outbox.
    var pendingOutboxCount = 0
    /// How many mutations are parked as conflicted and need the user (ADR 0006).
    ///
    /// Kept beside the pending count because it behaves in the opposite way: pending drains by
    /// itself, conflicted does not, so it stays visible until someone acts on it.
    var conflictedOutboxCount = 0
    /// How many mutations the drain gave up on (ADR 0006).
    ///
    /// The third of the three, and it behaves like the conflicted one rather than the pending one:
    /// ``ShepherdCore/OutboxState/failed`` means retrying cannot help, so the number never falls
    /// by itself — only a Retry or a Discard in Settings → Sync moves it. It is published here for
    /// the same reason the other two are: a write that is never going to arrive has to be sayable
    /// from a surface the user is already looking at, not only from the panel it was queued in.
    var failedOutboxCount = 0
    /// Every inbox row the local database holds, for the surfaces that outlive a screen.
    ///
    /// This is the menu-bar quick inbox's source (`Features/MenuBar/`), and it is here rather
    /// than in the inbox for one reason: `InboxModel` is owned by `InboxScreen` and stops
    /// observing when that screen goes away — the review screen replaces it — while the menu-bar
    /// item has to keep its badge current whether or not the inbox, or any window, is on screen.
    /// So the observation belongs to the session, exactly like the three outbox counts above.
    ///
    /// It is the *same* source, not a second one: `observeInbox()` re-reads what the sync engine
    /// wrote, the menu bar has no fetch of its own and no sync of its own, and the counting and
    /// ordering are the inbox's (`SmartView.needsMyReview`, `InboxModel.prioritySorted`). The
    /// price is a second `ValueObservation` on one table — one local `SELECT` per write while
    /// the inbox is also on screen — which is cheaper than any arrangement that lets a screen's
    /// lifetime decide whether the menu bar is telling the truth.
    var inboxRows: [PullRequestSummary] = []
    /// Whether ``inboxRows`` has been filled in at least once.
    ///
    /// An empty array means two very different things a fraction of a second apart — "this account
    /// has nothing open" and "the first `SELECT` has not come back yet" — and the morning digest is
    /// the one reader that has to tell them apart: a digest built from the second one would report
    /// a quiet night and then mark itself delivered for the day.
    private(set) var hasLoadedInbox = false
    /// Every issue row the local database holds, for the surfaces that outlive a screen
    /// (ADR 0032).
    ///
    /// Here rather than on ``IssueInboxModel`` for ``inboxRows``' reason, and it is the same
    /// reason twice over: the issues model is owned by `InboxScreen` and stops observing when the
    /// review screen replaces it, while ⌘K has to be able to answer with an issue from the review
    /// screen as well. So the observation belongs to the session, and the model observes again for
    /// its own filtered view — one more local `SELECT` per write, which is cheaper than letting a
    /// screen's lifetime decide whether the palette can find an issue.
    var issueRows: [IssueRowSummary] = []

    private var eventTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?
    private var conflictTask: Task<Void, Never>?
    private var failedTask: Task<Void, Never>?
    private var inboxTask: Task<Void, Never>?
    private var issuesTask: Task<Void, Never>?

    private init(
        account: Account,
        database: DatabaseManager,
        github: GitHubClient,
        agentDetector: AgentDetector,
        syncEngine: SyncEngine
    ) {
        self.account = account
        self.database = database
        self.github = github
        self.agentDetector = agentDetector
        self.syncEngine = syncEngine
    }

    /// Builds a session for an account whose token is already in the Keychain.
    /// - Parameters:
    ///   - account: The account to sign in as.
    ///   - tokenStore: The Keychain-backed token store.
    ///   - sweepInterval: How often the inbox sweep runs, in seconds.
    ///   - transport: How the client reaches GitHub. `URLSessionTransport` everywhere except the
    ///     Debug demo mode, whose transport refuses every request.
    /// - Returns: A fully wired session; the caller starts the loops.
    static func make(
        account: Account,
        tokenStore: KeychainTokenStore,
        sweepInterval: TimeInterval,
        transport: any HTTPTransport = URLSessionTransport()
    ) async throws -> SignedInSession {
        let database = try DatabaseManager(url: AppConfig.databaseURL)
        let overrides = (try? await database.agentRegistryOverrides()) ?? []
        let detector = try AgentDetector(extensions: overrides)

        let refresher: TokenRefresher? = account.authKind == .deviceFlow
            && AppConfig.isDeviceFlowConfigured
            ? TokenRefresher(clientID: AppConfig.githubAppClientID, transport: transport)
            : nil

        let github = GitHubClient(
            transport: transport,
            tokenProvider: RefreshingTokenProvider(
                login: account.login,
                store: tokenStore,
                refresher: refresher
            ),
            agentDetector: detector,
            cache: DatabaseConditionalCache(database: database)
        )

        let engine = SyncEngine(
            github: github,
            store: database,
            // The same database, through the narrow port the drain writes the interdiff's
            // baseline with (ADR 0028), and the login that lets a detail fetch recognise a
            // review the user submitted elsewhere.
            snapshots: database,
            // The same two things again, through the pair of ports the sweep captures a closed
            // pull request's outcome with (ADR 0027): the client reads it once, the database
            // stores it, and a failure on either side is swallowed rather than failing a sweep.
            outcomes: OutcomeCapture(reader: github, store: database),
            // And the pair of ports the second sweep of the same cycle runs through (ADR 0032).
            // This one line is the whole switch: with it the cycle also searches
            // `is:issue is:open archived:false` for the three relations and writes the rows the
            // issues section renders from, without it the engine sweeps exactly as it did
            // before — no extra request, no extra query. It cannot fail the cycle
            // (`runIssueSweep()` does not throw), which is what makes turning it on safe for the
            // review inbox Shepherd is actually for.
            issues: IssueCapture(fetcher: github, store: database),
            // And the port the drain executes a queued issue triage write through (ADR 0032's
            // Sprint 4a amendment). Separate from the pair above because the drain is a
            // different moment: it probes the issue's `updatedAt` before every write and parks
            // the row when it has moved, which is `ReviewDraft.basedOnHeadOid`'s rule on the
            // other kind of node.
            issueWrites: github,
            // And the port the drain deletes a merged head branch through (ADR 0005's
            // 2026-09-05 amendment). The same client once more, and it is only ever asked
            // anything when a merge row carries `deletesHeadBranch` — the box the merge sheet
            // remembers, which nothing automatic ever ticks.
            branchDeletion: github,
            // And where the drain reads whether a merge row's pull request is in a GitHub stack,
            // which decides between the synchronous and the asynchronous merge (ADR 0042). The
            // sweep keeps the stored membership current; a failed read is a retry, not a guess.
            isStacked: { [database] prID in try await database.isInStack(prID: prID) },
            configuration: SyncConfiguration(
                sweepInterval: sweepInterval,
                viewerLogin: account.login,
                // `GET /notifications` is classic-personal-access-token territory: a GitHub App
                // user token is refused by design and there is no App permission that would
                // change that (ADR 0004). A device-flow account therefore never starts the loop.
                // A pasted token still does, because nothing here can tell a classic token from
                // a fine-grained one — and the loop ends itself on the first refusal.
                pollsNotifications: account.authKind == .pat
            )
        )

        return SignedInSession(
            account: account,
            database: database,
            github: github,
            agentDetector: detector,
            syncEngine: engine
        )
    }

    /// Starts the sync loops and the event/outbox observers.
    /// - Parameters:
    ///   - settings: Used to decide which events become notifications.
    ///   - notifications: The notification manager.
    ///   - runsSyncLoop: Whether to start the engine's sweep loop. `false` only in the Debug demo
    ///     mode: its inbox is a seed, and the first sweep would either fail loudly or prune it.
    ///     The observers start either way, because they are what puts the seed on screen.
    ///   - onEvent: Called on the main actor for every sync event, after notification mapping.
    ///   - onInboxRows: Called on the main actor every time the inbox observation speaks, with the
    ///     rows it just wrote to ``inboxRows``. This is the trigger automatic merging runs on
    ///     (ADR 0018): the one transition that feature cares about — the last check turning
    ///     green — does not change a pull request's `updatedAt`, so no ``ShepherdSync/SyncEvent``
    ///     reports it and the rows the sweep persisted are the honest source. It fires for every
    ///     inbox write, and the consumer is required to be idempotent.
    ///   - onIssueRows: Called on the main actor every time the issues observation speaks, with
    ///     the rows it just wrote to ``issueRows`` (ADR 0032). The issues sweep emits no
    ///     ``ShepherdSync/SyncEvent`` of its own, deliberately, so the rows are the only
    ///     announcement there is — and they are the honest one: ⌘K's second index pass is about
    ///     the *content* of the issues section, which is exactly what a write to it changes. It
    ///     fires for every issue write, and the consumer is required to be idempotent.
    func start(
        settings: AppSettings,
        notifications: NotificationManager,
        runsSyncLoop: Bool = true,
        onEvent: @escaping @MainActor (SyncEvent) -> Void,
        onInboxRows: @escaping @MainActor ([PullRequestSummary]) -> Void = { _ in },
        onIssueRows: @escaping @MainActor ([IssueRowSummary]) -> Void = { _ in }
    ) {
        guard eventTask == nil else { return }

        let events = syncEngine.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await notifications.present(event, settings: settings)
                self.note(event)
                onEvent(event)
            }
        }

        let stream = database.observePendingOutboxCount()
        outboxTask = Task { [weak self] in
            for await count in stream {
                self?.pendingOutboxCount = count
            }
        }

        let conflicts = database.observeConflictedOutboxCount()
        conflictTask = Task { [weak self] in
            for await count in conflicts {
                self?.conflictedOutboxCount = count
            }
        }

        let failures = database.observeFailedOutboxCount()
        failedTask = Task { [weak self] in
            for await count in failures {
                self?.failedOutboxCount = count
            }
        }

        let inbox = database.observeInbox()
        inboxTask = Task { [weak self] in
            for await rows in inbox {
                guard let self else { return }
                self.inboxRows = rows
                self.hasLoadedInbox = true
                onInboxRows(rows)
            }
        }

        // `includeClosed: true`, because "an agent pull request closed one of your issues" is a
        // statement about a closed row. The sweep searches `is:open`, so such a row exists here
        // only because the sweep captured the close onto it and kept it for its retention window
        // (ADR 0032's 2026-09-03 amendment) — before that it vanished two minutes after closing
        // and this line could never fire. The issues section reads just as widely since that
        // ADR's 2026-09-04 amendment and narrows it in Swift with its STATE facet, so the two
        // observations no longer disagree about which rows this Mac holds; this one stays because
        // it is a different question — everything on disk, for the digest and for ⌘K, with no
        // facet in front of it.
        let issues = database.observeIssues(filter: IssueFilter(includeClosed: true))
        issuesTask = Task { [weak self] in
            for await rows in issues {
                guard let self else { return }
                self.issueRows = rows
                onIssueRows(rows)
            }
        }

        guard runsSyncLoop else { return }
        Task { [syncEngine] in
            await syncEngine.start()
        }
    }

    /// Runs one sweep and outbox drain now (⌘R).
    func syncNow() async throws {
        isSyncing = true
        defer { isSyncing = false }
        try await syncEngine.syncNow()
        // Set here as well as from the event below, and not because the event is unreliable: it
        // arrives on the event task a hop later, and ⌘R is the one path where somebody is looking
        // at the indicator at the moment it should change.
        lastSyncedAt = Date()
        hasCompletedFirstSweep = true
        lastSyncError = nil
    }

    /// Pushes the outbox without running a full sweep.
    func drainOutbox() async {
        await syncEngine.drainOutbox()
    }

    /// Pull requests whose merge GitHub confirmed during this session.
    ///
    /// What the *Merged* chip reads (``RowWriteState/merged``) and what stops a second merge from
    /// being queued behind a landed one. Set only by ``noteMerged(_:)``, i.e. after the drain heard
    /// back, never on the click; it belongs to the account, so it ends with the session.
    private(set) var mergedPullRequestIDs: Set<String> = []

    /// Records that the drain reported a merge as sent.
    func noteMerged(_ id: String) {
        mergedPullRequestIDs.insert(id)
    }

    /// Whether a merge for this pull request is queued, being sent, or already confirmed — in
    /// which case another one would only fail on GitHub and sit in the outbox as *Not sent*.
    func hasMergeOnItsWay(for id: String) async -> Bool {
        if mergedPullRequestIDs.contains(id) { return true }
        let items = (try? await database.allOutboxItems()) ?? []
        return items.contains { item in
            guard item.prID == id, item.state == .pending || item.state == .sending else { return false }
            if case .merge = item.action { return true }
            return false
        }
    }

    /// Sends the failed writes of one pull request or issue again, from wherever the reviewer is
    /// looking at it — the same reset-and-drain Settings → Sync's *Retry* does per row.
    /// - Parameter targetID: The pull request's or issue's node id.
    func retryFailedWrites(for targetID: String) async {
        let failed = (try? await database.failedOutboxItems()) ?? []
        for item in failed where item.prID == targetID {
            try? await database.retryOutboxItem(id: item.id)
        }
        await drainOutbox()
    }

    /// The pull requests the outbox still holds a write for — pending, in flight or parked.
    ///
    /// Read as a set of node ids rather than as rows because that is all the one caller needs:
    /// automatic merging refuses a pull request that already has an unsent write (ADR 0018), so
    /// it can neither queue a second merge behind a parked one nor race its own previous pass.
    /// A read failure answers "nothing is queued", which is the same answer an empty outbox
    /// gives — and the policy's other guard, the ledger, is the one that must not be lost.
    func pullRequestIDsWithQueuedWrites() async -> Set<String> {
        let items = (try? await database.allOutboxItems()) ?? []
        return Set(items.map(\.prID))
    }

    /// Stops the loops and observers. Called on sign-out and on quit.
    func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        outboxTask?.cancel()
        outboxTask = nil
        conflictTask?.cancel()
        conflictTask = nil
        failedTask?.cancel()
        failedTask = nil
        inboxTask?.cancel()
        inboxTask = nil
        issuesTask?.cancel()
        issuesTask = nil
        await syncEngine.shutdown()
    }

    private func note(_ event: SyncEvent) {
        switch event {
        case .syncFailed(let failure):
            lastSyncError = failure.localizedMessage()
        case .sweepCompleted(let completion):
            // The event that fixes the quiet account. Every case below reports something the
            // sweep *found*, so an account with nothing open reached none of them, `lastSyncedAt`
            // stayed `nil` and the title bar said "Not synced yet" indefinitely while the engine
            // swept every two minutes. The engine's own clock rather than `Date()`, so
            // "Synced · 32 s ago" counts from when the sweep came back rather than from when this
            // actor got round to the event.
            lastSyncedAt = completion.finishedAt
            hasCompletedFirstSweep = true
            lastSyncError = nil
        case .newReviewRequest, .checksFailedOnOwnPR, .changesRequestedOnOwnPR, .prMerged,
             .prUpdated, .mutationSent:
            // Kept beside the case above rather than folded into it: these are emitted *during* a
            // sweep, so they move the indicator as soon as there is evidence GitHub answered,
            // without waiting for the detail fetches the same cycle still has to make. They
            // deliberately do not set `hasCompletedFirstSweep` — the sweep has not finished.
            lastSyncedAt = Date()
            lastSyncError = nil
        case .draftConflict:
            break
        }
    }
}
