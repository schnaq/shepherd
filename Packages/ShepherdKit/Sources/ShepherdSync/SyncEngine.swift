import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence

/// Tunables for ``SyncEngine``.
public struct SyncConfiguration: Sendable {
    /// The facet queries the sweep runs.
    public var queries: [InboxQuery]
    /// How long to wait between sweeps. ADR 0005's default is two minutes.
    public var sweepInterval: TimeInterval
    /// How long to wait between notification polls when the server does not say.
    public var notificationsFallbackInterval: TimeInterval
    /// A floor under the server-supplied poll interval, so a bad header cannot make Shepherd
    /// hammer the API.
    public var minimumNotificationsInterval: TimeInterval
    /// How long to wait after a failed loop iteration before trying again.
    public var failureBackoff: TimeInterval
    /// How many detail fetches run at once (ADR 0005: about five).
    public var maxConcurrentDetailFetches: Int
    /// How many outbox rows one drain attempts.
    public var outboxBatchSize: Int

    /// Creates a configuration.
    public init(
        queries: [InboxQuery] = InboxQuery.defaultSweep,
        sweepInterval: TimeInterval = 120,
        notificationsFallbackInterval: TimeInterval = 60,
        minimumNotificationsInterval: TimeInterval = 30,
        failureBackoff: TimeInterval = 30,
        maxConcurrentDetailFetches: Int = 5,
        outboxBatchSize: Int = 20
    ) {
        self.queries = queries
        self.sweepInterval = sweepInterval
        self.notificationsFallbackInterval = notificationsFallbackInterval
        self.minimumNotificationsInterval = minimumNotificationsInterval
        self.failureBackoff = failureBackoff
        self.maxConcurrentDetailFetches = max(1, maxConcurrentDetailFetches)
        self.outboxBatchSize = max(1, outboxBatchSize)
    }
}

/// Keeps the local database in step with GitHub (ADR 0005).
///
/// Two independent loops run while the engine is started:
///
/// 1. **Notifications** — polls `GET /notifications` at the interval the *server* asks for.
///    It is a wake-up signal, not a source of truth: when something interesting arrives it
///    triggers a sweep.
/// 2. **Sweep** — one GraphQL search per facet every ``SyncConfiguration/sweepInterval``,
///    which *is* the source of truth for the inbox. A pull request is fetched in detail only
///    when its `updatedAt` or `headRefOid` changed, and those fetches are chunked so a busy
///    cycle cannot trip GitHub's secondary rate limit.
///
/// Every wait goes through an injected ``ShepherdCore/Sleeping``, so the whole engine can be
/// driven at full speed in tests.
public actor SyncEngine {
    /// Keys used in the `sync_state` table.
    enum StateKey {
        static let notificationsLastModified = "notifications.lastModified"
        static let notificationsSince = "notifications.since"
        static let lastSweepAt = "sweep.lastCompletedAt"
    }

    /// The stream of things worth telling the user about.
    ///
    /// Buffered and non-blocking: a UI that stops listening can never stall the sync.
    public nonisolated let events: AsyncStream<SyncEvent>
    private nonisolated let continuation: AsyncStream<SyncEvent>.Continuation

    private let github: any PullRequestFetching
    private let store: any SyncStoring
    private let configuration: SyncConfiguration
    private let sleeper: any Sleeping
    private let now: @Sendable () -> Date

    private var sweepTask: Task<Void, Never>?
    private var notificationsTask: Task<Void, Never>?

    /// Whether a sweep is in flight. The engine is an actor but ``performSweep()`` awaits, so
    /// it is fully re-entrant without this.
    private var isSweeping = false
    /// Set when a sweep was asked for while one was already running; the running sweep picks
    /// it up when it finishes, so a burst of requests costs at most one extra pass.
    private var sweepRequested = false
    /// The same guard for the outbox drain, which has three callers that routinely overlap.
    private var isDraining = false
    private var drainRequested = false

    /// Whether the loops are running.
    public private(set) var isRunning = false

    /// Creates an engine.
    /// - Parameters:
    ///   - github: The GitHub façade.
    ///   - store: The local database.
    ///   - configuration: Tunables.
    ///   - sleeper: The delay abstraction; tests inject one that does not wait.
    ///   - now: Clock injection point for tests.
    public init(
        github: any PullRequestFetching,
        store: any SyncStoring,
        configuration: SyncConfiguration = SyncConfiguration(),
        sleeper: any Sleeping = SystemSleeper(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.github = github
        self.store = store
        self.configuration = configuration
        self.sleeper = sleeper
        self.now = now
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - Lifecycle

    /// Starts both loops. Calling it twice is a no-op.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        sweepTask = Task { [weak self] in
            await self?.runSweepLoop()
        }
        notificationsTask = Task { [weak self] in
            await self?.runNotificationsLoop()
        }
    }

    /// Stops both loops and **waits for them to finish**. The event stream stays open so the
    /// engine can be started again.
    ///
    /// Awaiting matters: "Sign out & erase" stops the engine and then empties the tables, and
    /// a loop that was merely asked to cancel would still be mid-sweep and would write the
    /// pull requests — and their patches — straight back onto disk after the erase.
    public func stop() async {
        let sweep = sweepTask
        let notifications = notificationsTask
        sweepTask = nil
        notificationsTask = nil
        isRunning = false
        sweep?.cancel()
        notifications?.cancel()
        if let sweep { await sweep.value }
        if let notifications { await notifications.value }
    }

    /// Stops the loops and closes the event stream for good.
    public func shutdown() async {
        await stop()
        continuation.finish()
    }

    /// Runs one sweep and one outbox drain immediately, outside the loop schedule.
    ///
    /// Used by "Refresh now", by the app coming back to the foreground, and by tests.
    public func syncNow() async throws {
        try await performSweep()
        await drainOutbox()
    }

    // MARK: - Loops

    private func runSweepLoop() async {
        while !Task.isCancelled {
            var interval = configuration.sweepInterval
            do {
                try await performSweep()
            } catch is CancellationError {
                return
            } catch {
                emit(.syncFailed(SyncFailure(stage: .sweep, message: describe(error))))
                interval = max(interval, configuration.failureBackoff)
            }
            await drainOutbox()
            do {
                try await sleeper.sleep(for: .seconds(interval))
            } catch {
                return
            }
        }
    }

    private func runNotificationsLoop() async {
        var lastModified: String? = (try? await store.syncState(
            forKey: StateKey.notificationsLastModified
        )) ?? nil
        let storedSince: String? = (try? await store.syncState(
            forKey: StateKey.notificationsSince
        )) ?? nil
        var since: Date? = storedSince
            .flatMap { Double($0) }
            .map { Date(timeIntervalSince1970: $0) }

        while !Task.isCancelled {
            var interval = configuration.notificationsFallbackInterval
            do {
                let page = try await github.notifications(
                    since: since,
                    lastModified: lastModified,
                    participating: true
                )
                if let serverInterval = page.pollInterval {
                    interval = max(configuration.minimumNotificationsInterval, serverInterval)
                }
                if let newLastModified = page.lastModified, newLastModified != lastModified {
                    lastModified = newLastModified
                    try? await store.setSyncState(
                        newLastModified,
                        forKey: StateKey.notificationsLastModified
                    )
                }
                // A `304` means "nothing changed". The transport may still hand back the
                // previous page's body from the conditional-request cache, and treating those
                // stale items as new would force a full sweep on every single poll.
                if !page.notModified {
                    if Self.warrantsSweep(page.items) {
                        try await performSweep()
                    }
                    // `since` comes from the newest thread GitHub actually returned, not from
                    // the local clock: a clock running fast would silently skip notifications.
                    let newest = page.items.map(\.updatedAt).max()
                    if let newest, newest > (since ?? .distantPast) {
                        since = newest
                        try? await store.setSyncState(
                            String(newest.timeIntervalSince1970),
                            forKey: StateKey.notificationsSince
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                emit(.syncFailed(SyncFailure(stage: .notifications, message: describe(error))))
                interval = max(interval, configuration.failureBackoff)
            }
            do {
                try await sleeper.sleep(for: .seconds(interval))
            } catch {
                return
            }
        }
    }

    /// Whether a notifications page contains anything that should pull a sweep forward.
    ///
    /// Deliberately narrow: a `subscribed` notification about a repository the user watches
    /// is not a reason to spend a search call.
    static func warrantsSweep(_ items: [NotificationItem]) -> Bool {
        items.contains { item in
            guard item.isPullRequest else { return false }
            switch item.reason {
            case .reviewRequested, .mention, .assign, .ciActivity, .stateChange, .comment:
                return true
            case .author, .subscribed, .other:
                return false
            }
        }
    }

    // MARK: - Sweep

    /// Runs a sweep, unless one is already running.
    ///
    /// There are three callers — the sweep loop, `syncNow()`, and the notifications loop when
    /// something interesting arrives — and every launch used to fire at least two of them at
    /// once: twice the search calls, twice the detail fetches, and two concurrent
    /// `savePullRequestSummaries(pruneMissing: true)` racing each other. Overlapping requests
    /// are coalesced into a single follow-up pass instead.
    private func performSweep() async throws {
        if isSweeping {
            sweepRequested = true
            return
        }
        isSweeping = true
        defer { isSweeping = false }
        repeat {
            sweepRequested = false
            try await runSweep()
        } while sweepRequested && !Task.isCancelled
    }

    private func runSweep() async throws {
        let previous = try await store.fetchInbox(filter: InboxFilter())
        var previousByID: [String: PullRequestSummary] = [:]
        previousByID.reserveCapacity(previous.count)
        for summary in previous {
            previousByID[summary.id] = summary
        }

        let current = try await github.searchOpenPullRequests(queries: configuration.queries)

        var currentIDs = Set<String>()
        currentIDs.reserveCapacity(current.count)
        var needsDetail: [PullRequestSummary] = []

        for summary in current {
            currentIDs.insert(summary.id)
            let old = previousByID[summary.id]

            if old == nil {
                needsDetail.append(summary)
                if summary.myRelation.contains(.reviewRequested) {
                    emit(.newReviewRequest(summary))
                }
            } else if let old,
                      old.updatedAt != summary.updatedAt || old.headRefOid != summary.headRefOid {
                needsDetail.append(summary)
                emit(.prUpdated(summary))
            }

            if summary.myRelation.contains(.author),
               summary.checkRollup?.state == .failure,
               old?.checkRollup?.state != .failure {
                emit(.checksFailedOnOwnPR(summary))
            }
        }

        // Every write is preceded by a cancellation check: a sweep that was stopped because the
        // user signed out must not repopulate tables the erase has already emptied.
        try Task.checkCancellation()
        try await store.savePullRequestSummaries(current, pruneMissing: true)

        // "Left the inbox" is decided by what the prune actually removed, not by what the
        // search returned: a pull request the user still has a draft or a queued mutation for
        // is deliberately kept, and re-announcing it as merged on every sweep would be a
        // notification every two minutes for as long as the draft lives.
        let remaining = Set(try await store.fetchInbox(filter: InboxFilter()).map(\.id))
        for old in previous where !currentIDs.contains(old.id) && !remaining.contains(old.id) {
            emit(.prMerged(old))
        }

        try await fetchDetails(for: needsDetail)
        try Task.checkCancellation()
        try? await store.setSyncState(
            String(now().timeIntervalSince1970),
            forKey: StateKey.lastSweepAt
        )
    }

    /// Fetches details for the changed pull requests in chunks.
    ///
    /// Chunking rather than one big task group is the staggering ADR 0005 asks for: at most
    /// ``SyncConfiguration/maxConcurrentDetailFetches`` requests are ever in flight, and a
    /// slow pull request delays only its own chunk.
    private func fetchDetails(for summaries: [PullRequestSummary]) async throws {
        guard !summaries.isEmpty else { return }
        let github = self.github
        let store = self.store
        let chunkSize = configuration.maxConcurrentDetailFetches

        var index = 0
        while index < summaries.count {
            try Task.checkCancellation()
            let upperBound = min(index + chunkSize, summaries.count)
            let chunk = Array(summaries[index..<upperBound])
            index = upperBound

            let failures = await withTaskGroup(
                of: SyncFailure?.self,
                returning: [SyncFailure].self
            ) { group in
                for summary in chunk {
                    group.addTask {
                        do {
                            let detail = try await github.pullRequestDetail(
                                repo: summary.repo,
                                number: summary.number
                            )
                            // The fetch may have been in flight across a sign-out; do not
                            // write its patches back into a database that was just erased.
                            try Task.checkCancellation()
                            try await store.savePullRequestDetail(detail)
                            return nil
                        } catch is CancellationError {
                            return nil
                        } catch {
                            return SyncFailure(
                                stage: .detail,
                                message: "\(summary.slug): \(String(describing: error))"
                            )
                        }
                    }
                }
                var collected: [SyncFailure] = []
                for await failure in group {
                    if let failure { collected.append(failure) }
                }
                return collected
            }

            for failure in failures {
                emit(.syncFailed(failure))
            }
        }
    }

    // MARK: - Outbox

    /// The result of attempting one outbox row.
    private enum OutboxOutcome {
        /// The mutation reached GitHub.
        case sent
        /// The mutation was not sent because the pull request moved on.
        case conflict(DraftConflict)
    }

    /// Sends everything in the outbox that is due.
    ///
    /// Before submitting a review the current head commit is re-read and compared against the
    /// draft's ``ShepherdCore/ReviewDraft/basedOnHeadOid``. If they differ, nothing is sent:
    /// the row is parked as conflicted and a ``SyncEvent/draftConflict(_:)`` is emitted
    /// (ADR 0006).
    public func drainOutbox() async {
        if isDraining {
            // Somebody enqueued while a drain was in flight. Do not start a second one — let
            // the running drain take another lap when it is done.
            drainRequested = true
            return
        }
        isDraining = true
        defer { isDraining = false }
        repeat {
            drainRequested = false
            await performDrain()
        } while drainRequested && !Task.isCancelled
    }

    private func performDrain() async {
        let items: [OutboxItem]
        do {
            items = try await store.claimReadyOutboxItems(
                now: now(),
                limit: configuration.outboxBatchSize
            )
        } catch {
            emit(.syncFailed(SyncFailure(stage: .outbox, message: describe(error))))
            return
        }

        var index = 0
        while index < items.count {
            if Task.isCancelled { break }
            let item = items[index]
            index += 1
            do {
                switch try await execute(item) {
                case .sent:
                    try await store.markOutboxItemSucceeded(id: item.id)
                    // Announced only here, after the row is gone: this is the single moment at
                    // which the mutation is known to have reached GitHub rather than merely
                    // been queued.
                    emit(
                        .mutationSent(
                            SentMutation(
                                prID: item.prID,
                                repo: item.repo,
                                number: item.number,
                                kind: Self.sentKind(for: item.action),
                                sentAt: now()
                            )
                        )
                    )
                case .conflict(let conflict):
                    try await store.markOutboxItemConflicted(
                        id: item.id,
                        reason: "Head moved from \(conflict.expectedHeadOid) to \(conflict.actualHeadOid)"
                    )
                    emit(.draftConflict(conflict))
                }
            } catch let error as GitHubError {
                await handleOutboxFailure(item, error: error)
            } catch {
                try? await store.markOutboxItemFailed(
                    id: item.id,
                    error: describe(error),
                    now: now(),
                    retriable: true
                )
                emit(.syncFailed(SyncFailure(stage: .outbox, message: describe(error))))
            }
        }

        // Rows claimed but never attempted — the app is quitting, or the loop was cancelled —
        // go straight back into the queue rather than sitting in `sending` until relaunch.
        if index < items.count {
            try? await store.releaseOutboxItems(ids: items[index...].map(\.id))
        }
    }

    private func handleOutboxFailure(_ item: OutboxItem, error: GitHubError) async {
        if case .staleHead(let expected, let actual) = error {
            let conflict = DraftConflict(
                prID: item.prID,
                repo: item.repo,
                number: item.number,
                expectedHeadOid: expected,
                actualHeadOid: actual ?? ""
            )
            try? await store.markOutboxItemConflicted(
                id: item.id,
                reason: "The pull request moved on before the merge could run"
            )
            emit(.draftConflict(conflict))
            return
        }
        try? await store.markOutboxItemFailed(
            id: item.id,
            error: describe(error),
            now: now(),
            retriable: error.isRetryable
        )
        emit(.syncFailed(SyncFailure(stage: .outbox, message: describe(error))))
    }

    private func execute(_ item: OutboxItem) async throws -> OutboxOutcome {
        switch item.action {
        case .submitReview(let draft):
            if !draft.basedOnHeadOid.isEmpty {
                let head = try await github.headRefOid(repo: item.repo, number: item.number)
                if head != draft.basedOnHeadOid {
                    return .conflict(
                        DraftConflict(
                            prID: item.prID,
                            repo: item.repo,
                            number: item.number,
                            expectedHeadOid: draft.basedOnHeadOid,
                            actualHeadOid: head
                        )
                    )
                }
            }
            _ = try await github.submitReview(draft, repo: item.repo, number: item.number)
            try await store.deleteDraft(prID: item.prID)
            return .sent

        case .replyToComment(let commentDatabaseID, let body):
            try await github.replyToComment(
                repo: item.repo,
                number: item.number,
                commentID: commentDatabaseID,
                body: body
            )
            return .sent

        case .resolveThread(let threadID):
            try await github.resolveThread(id: threadID)
            return .sent

        case .unresolveThread(let threadID):
            try await github.unresolveThread(id: threadID)
            return .sent

        case .merge(let method, let expectedHeadOid):
            _ = try await github.mergePullRequest(
                repo: item.repo,
                number: item.number,
                method: MergeMethod(rawValue: method) ?? .merge,
                expectedHeadOid: expectedHeadOid,
                commitTitle: nil
            )
            return .sent

        case .markReadyForReview:
            try await github.markReadyForReview(pullRequestID: item.prID)
            return .sent
        }
    }

    // MARK: - Helpers

    /// The ``SentMutation/Kind`` an outbox action amounts to once it has been sent.
    ///
    /// Pure and `static` so the mapping is covered by the drain tests without an engine.
    static func sentKind(for action: OutboxAction) -> SentMutation.Kind {
        switch action {
        case .submitReview(let draft):
            return .reviewSubmitted(
                verdict: draft.verdict,
                inlineCommentCount: draft.comments.count
            )
        case .replyToComment: return .replyPosted
        case .resolveThread: return .threadResolved
        case .unresolveThread: return .threadUnresolved
        case .merge(let method, _): return .merged(method: method)
        case .markReadyForReview: return .markedReadyForReview
        }
    }

    private func emit(_ event: SyncEvent) {
        continuation.yield(event)
    }

    private func describe(_ error: any Error) -> String {
        if let githubError = error as? GitHubError {
            return githubError.errorDescription ?? String(describing: githubError)
        }
        return String(describing: error)
    }
}
