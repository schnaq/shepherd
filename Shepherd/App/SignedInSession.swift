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
    /// The background sync loops.
    let syncEngine: SyncEngine

    /// When the last successful sweep finished, for the title-bar indicator.
    var lastSyncedAt: Date?
    /// Whether a manual sync is in flight.
    var isSyncing = false
    /// The most recent sync failure, shown as a dot in the title bar.
    var lastSyncError: String?
    /// How many mutations are waiting in the outbox.
    var pendingOutboxCount = 0
    /// How many mutations are parked as conflicted and need the user (ADR 0006).
    ///
    /// Kept beside the pending count because it behaves in the opposite way: pending drains by
    /// itself, conflicted does not, so it stays visible until someone acts on it.
    var conflictedOutboxCount = 0
    /// Every inbox row the local database holds, for the surfaces that outlive a screen.
    ///
    /// This is the menu-bar quick inbox's source (`Features/MenuBar/`), and it is here rather
    /// than in the inbox for one reason: `InboxModel` is owned by `InboxScreen` and stops
    /// observing when that screen goes away — the review screen replaces it — while the menu-bar
    /// item has to keep its badge current whether or not the inbox, or any window, is on screen.
    /// So the observation belongs to the session, exactly like the two outbox counts above.
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

    private var eventTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?
    private var conflictTask: Task<Void, Never>?
    private var inboxTask: Task<Void, Never>?

    private init(
        account: Account,
        database: DatabaseManager,
        github: GitHubClient,
        syncEngine: SyncEngine
    ) {
        self.account = account
        self.database = database
        self.github = github
        self.syncEngine = syncEngine
    }

    /// Builds a session for an account whose token is already in the Keychain.
    /// - Parameters:
    ///   - account: The account to sign in as.
    ///   - tokenStore: The Keychain-backed token store.
    ///   - sweepInterval: How often the inbox sweep runs, in seconds.
    /// - Returns: A fully wired session; the caller starts the loops.
    static func make(
        account: Account,
        tokenStore: KeychainTokenStore,
        sweepInterval: TimeInterval
    ) async throws -> SignedInSession {
        let database = try DatabaseManager(url: AppConfig.databaseURL)
        let overrides = (try? await database.agentRegistryOverrides()) ?? []
        let detector = try AgentDetector(extensions: overrides)

        let transport = URLSessionTransport()
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
            configuration: SyncConfiguration(
                sweepInterval: sweepInterval,
                viewerLogin: account.login
            )
        )

        return SignedInSession(
            account: account,
            database: database,
            github: github,
            syncEngine: engine
        )
    }

    /// Starts the sync loops and the event/outbox observers.
    /// - Parameters:
    ///   - settings: Used to decide which events become notifications.
    ///   - notifications: The notification manager.
    ///   - onEvent: Called on the main actor for every sync event, after notification mapping.
    ///   - onInboxRows: Called on the main actor every time the inbox observation speaks, with the
    ///     rows it just wrote to ``inboxRows``. This is the trigger automatic merging runs on
    ///     (ADR 0018): the one transition that feature cares about — the last check turning
    ///     green — does not change a pull request's `updatedAt`, so no ``ShepherdSync/SyncEvent``
    ///     reports it and the rows the sweep persisted are the honest source. It fires for every
    ///     inbox write, and the consumer is required to be idempotent.
    func start(
        settings: AppSettings,
        notifications: NotificationManager,
        onEvent: @escaping @MainActor (SyncEvent) -> Void,
        onInboxRows: @escaping @MainActor ([PullRequestSummary]) -> Void = { _ in }
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

        let inbox = database.observeInbox()
        inboxTask = Task { [weak self] in
            for await rows in inbox {
                guard let self else { return }
                self.inboxRows = rows
                self.hasLoadedInbox = true
                onInboxRows(rows)
            }
        }

        Task { [syncEngine] in
            await syncEngine.start()
        }
    }

    /// Runs one sweep and outbox drain now (⌘R).
    func syncNow() async throws {
        isSyncing = true
        defer { isSyncing = false }
        try await syncEngine.syncNow()
        lastSyncedAt = Date()
        lastSyncError = nil
    }

    /// Pushes the outbox without running a full sweep.
    func drainOutbox() async {
        await syncEngine.drainOutbox()
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
        inboxTask?.cancel()
        inboxTask = nil
        await syncEngine.shutdown()
    }

    private func note(_ event: SyncEvent) {
        switch event {
        case .syncFailed(let failure):
            lastSyncError = failure.message
        case .newReviewRequest, .checksFailedOnOwnPR, .changesRequestedOnOwnPR, .prMerged,
             .prUpdated, .mutationSent:
            lastSyncedAt = Date()
            lastSyncError = nil
        case .draftConflict:
            break
        }
    }
}
