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
    /// The signed-in user's login, when the engine is allowed to recognise their own reviews.
    ///
    /// Read by exactly one thing: the retroactive interdiff baseline (ADR 0028). A review
    /// submitted on github.com carries the head it was made against, and a detail fetch that
    /// sees one by *this* user while the pull request is still on that commit may write the
    /// snapshot the outbox drain never got to write. `nil` switches that off, which is what
    /// every test that does not care about it gets.
    public var viewerLogin: String?

    /// Creates a configuration.
    public init(
        queries: [InboxQuery] = InboxQuery.defaultSweep,
        sweepInterval: TimeInterval = 120,
        notificationsFallbackInterval: TimeInterval = 60,
        minimumNotificationsInterval: TimeInterval = 30,
        failureBackoff: TimeInterval = 30,
        maxConcurrentDetailFetches: Int = 5,
        outboxBatchSize: Int = 20,
        viewerLogin: String? = nil
    ) {
        self.queries = queries
        self.sweepInterval = sweepInterval
        self.notificationsFallbackInterval = notificationsFallbackInterval
        self.minimumNotificationsInterval = minimumNotificationsInterval
        self.failureBackoff = failureBackoff
        self.maxConcurrentDetailFetches = max(1, maxConcurrentDetailFetches)
        self.outboxBatchSize = max(1, outboxBatchSize)
        self.viewerLogin = viewerLogin
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
    /// Where a submitted review's baseline goes, when the app wired one up (ADR 0028).
    private let snapshots: (any ReviewSnapshotWriting)?
    /// Where a disappeared pull request's outcome goes, when the app wired one up (ADR 0027).
    private let outcomes: OutcomeCapture?
    /// Where the issues sweep reads and writes, when the app wired it up (ADR 0032).
    private let issues: IssueCapture?
    /// Where the drain executes an issue triage write, when the app wired one up (ADR 0032's
    /// Sprint 4a amendment).
    ///
    /// Separate from ``issues`` rather than a third field on ``IssueCapture``, because that
    /// value's own argument — "neither half is any use without the other" — is not true here: a
    /// drain that sends a queued comment needs no sweep, and a sweep needs no writer. `nil` means
    /// an issue row in the outbox is parked as failed with one sentence rather than sent blind.
    private let issueWrites: (any IssueWriting)?
    /// Where the drain deletes a merged pull request's head branch, when the app wired one up
    /// (ADR 0005's 2026-09-05 amendment).
    ///
    /// Optional for ``snapshots``'s reason rather than ``issueWrites``'s: a merge row whose
    /// deletion cannot be carried out is still a merge, so `nil` costs the user nothing but the
    /// tidying-up — where a `nil` issue writer would mean sending an issue write blind.
    private let branchDeletion: (any BranchDeleting)?
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

    /// What the most recent issues sweep learned, or `nil` when none has run (ADR 0032).
    ///
    /// The engine's own bookkeeping, kept because the issues sweep emits no event of its own —
    /// see ``IssueSweepDelta``.
    private(set) var lastIssueSweep: IssueSweepDelta?

    /// Creates an engine.
    /// - Parameters:
    ///   - github: The GitHub façade.
    ///   - store: The local database.
    ///   - snapshots: Where the interdiff's baseline is written when a review is sent
    ///     (ADR 0028). `nil` — the default — means no baseline is kept, which is how every
    ///     caller that does not care about the review screen builds an engine.
    ///   - outcomes: Where the outcome of a pull request that left the inbox is read and written
    ///     (ADR 0027). `nil` — the default — means no track record is kept, and the sweep then
    ///     behaves exactly as it did before: no extra request, no extra query.
    ///   - issues: Where the issues sweep reads and writes (ADR 0032). `nil` — the default —
    ///     means the cycle runs the pull-request sweep alone, which is how every caller that
    ///     predates the issues inbox builds an engine.
    ///   - issueWrites: Where a queued issue triage write is probed and executed (ADR 0032's
    ///     Sprint 4a amendment). `nil` — the default — means the drain refuses an issue row
    ///     instead of sending it, which is how every caller that predates the issue writes
    ///     builds an engine.
    ///   - branchDeletion: Where a merged pull request's head branch is read and deleted
    ///     (ADR 0005's 2026-09-05 amendment). `nil` — the default — means a merge row that asks
    ///     for the deletion is merged and nothing more, which is how every caller that predates
    ///     branch deletion builds an engine.
    ///   - configuration: Tunables.
    ///   - sleeper: The delay abstraction; tests inject one that does not wait.
    ///   - now: Clock injection point for tests.
    public init(
        github: any PullRequestFetching,
        store: any SyncStoring,
        snapshots: (any ReviewSnapshotWriting)? = nil,
        outcomes: OutcomeCapture? = nil,
        issues: IssueCapture? = nil,
        issueWrites: (any IssueWriting)? = nil,
        branchDeletion: (any BranchDeleting)? = nil,
        configuration: SyncConfiguration = SyncConfiguration(),
        sleeper: any Sleeping = SystemSleeper(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.github = github
        self.store = store
        self.snapshots = snapshots
        self.outcomes = outcomes
        self.issues = issues
        self.issueWrites = issueWrites
        self.branchDeletion = branchDeletion
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
        // Here rather than at the end of `runSweep()`, so the coalescing above stays invisible to
        // consumers: a burst that turned into two passes is still one sweep as far as anybody
        // outside this actor is concerned, and the caller that was folded into a running sweep and
        // returned early above does not announce a completion of its own either. A throw skips
        // this line entirely, which is what makes the event mean "the inbox is now as current as
        // GitHub" rather than the much weaker "the loop came round again".
        emit(.sweepCompleted(SweepCompletion(finishedAt: now())))
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

            // Both of these are *edges*, not states: the guard compares against what the
            // previous sweep saw, and the event carries that comparison along so a consumer can
            // tell a watched change from a first sighting (ADR 0016).
            if AutoDelegationPolicy.isOwn(summary), summary.checkRollup?.state == .failure,
               old?.checkRollup?.state != .failure {
                emit(
                    .checksFailedOnOwnPR(
                        ChecksFailure(
                            summary: summary,
                            previousState: old?.checkRollup?.state,
                            wasTracked: old != nil
                        )
                    )
                )
            }

            if AutoDelegationPolicy.isOwn(summary), summary.reviewDecision == .changesRequested,
               old?.reviewDecision != .changesRequested {
                emit(
                    .changesRequestedOnOwnPR(
                        ChangesRequested(
                            summary: summary,
                            previousDecision: old?.reviewDecision,
                            wasTracked: old != nil
                        )
                    )
                )
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
        var departed: [PullRequestSummary] = []
        for old in previous where !currentIDs.contains(old.id) && !remaining.contains(old.id) {
            departed.append(old)
            emit(.prMerged(old))
        }

        // The same list, for the track record: a pull request that has left the inbox is the one
        // moment its final state can be read, and it is read once (ADR 0027). Deliberately
        // *after* the event above and before the detail fetches, so a capture that hangs on a
        // slow request delays the diffs rather than the notification.
        await captureOutcomes(for: departed)

        // The second sweep of the same cycle (ADR 0032): no second timer and no second cadence
        // setting, because the two sections are read together and a user who refreshes expects
        // both to move. Before the detail fetches, so a busy diff round does not hold the issues
        // section back — it is inbox data, and nobody is waiting on a diff the same way.
        await runIssueSweep()

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
        let snapshots = self.snapshots
        let viewerLogin = configuration.viewerLogin
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
                            // A review of *this* head by the viewer that Shepherd never sent
                            // itself can still be a baseline, but only while the head has not
                            // moved and only when there is no baseline for it yet (ADR 0028).
                            if let snapshots, let viewerLogin,
                               let baseline = SyncEngine.retroactiveBaseline(
                                   detail: detail,
                                   viewerLogin: viewerLogin
                               ),
                               (try? await snapshots.hasReviewSnapshot(
                                   prID: detail.id,
                                   reviewedHeadOid: baseline.headRefOid
                               )) == false {
                                _ = try? await snapshots.captureReviewSnapshot(
                                    prID: detail.id,
                                    reviewedHeadOid: baseline.headRefOid,
                                    reviewedAt: baseline.reviewedAt
                                )
                            }
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

    // MARK: - Track record (ADR 0027)

    /// Reads and stores the final state of the pull requests that just left the inbox.
    ///
    /// Four properties, and each one is a decision:
    ///
    /// - **Once per pull request.** The store is asked first, and a pull request that already has
    ///   a row — from the backfill, or from an earlier sweep that saw the same disappearance —
    ///   costs one local `SELECT` and no request.
    /// - **One request each, sequentially.** A disappearance is rare (a merge, a close, a facet
    ///   that stopped matching) and nobody is waiting on the answer, so there is no task group
    ///   here: a Monday-morning sweep that sees eight merges spends eight requests over a second
    ///   rather than eight at once against the secondary rate limit.
    /// - **A failure is never the sync's failure.** Every error is swallowed — not even a
    ///   ``SyncEvent/syncFailed(_:)`` — because the user did not ask for this and a badge that is
    ///   one pull request behind is worth nothing next to a sweep that reported itself broken.
    ///   The row is simply written on some later sweep, or by the backfill.
    /// - **Reverts are linked immediately.** A revert is a pull request like any other and closes
    ///   like any other, so the moment its own outcome is stored is the moment it can be matched
    ///   against the merged pull requests already on disk.
    /// - Parameter departed: The rows the prune actually removed.
    private func captureOutcomes(for departed: [PullRequestSummary]) async {
        guard let outcomes, !departed.isEmpty else { return }
        for summary in departed {
            if Task.isCancelled { return }
            do {
                if try await outcomes.store.hasPullRequestOutcome(prID: summary.id) { continue }
                guard let closed = try await outcomes.reader.closedPullRequest(
                    repo: summary.repo,
                    number: summary.number
                ) else { continue }
                _ = try await outcomes.store.savePullRequestOutcomes([closed])
                let since = TrackRecord.windowStart(from: closed.outcome.closedAt)
                let known = try await outcomes.store.mergedClosedPullRequests(
                    repo: closed.outcome.repo,
                    since: since
                )
                let links = RevertDetector.links(candidates: [closed], known: known)
                _ = try await outcomes.store.applyRevertLinks(links)
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
    }

    // MARK: - Issues sweep (ADR 0032)

    /// What the last issues sweep learned, for the sweep's own tests.
    ///
    /// Deliberately **not** a ``SyncEvent``. The roadmap's digest line reads stored rows the way
    /// `DigestReport.make`'s review-request section already does — off `updatedAt` against a
    /// window start — so nothing needs an event to work, and no notification bullet asks for one.
    /// A "new issue assignment" notification would be a new event *then*, added with the feature
    /// that wants it rather than in advance.
    ///
    /// Internal, so it is the engine's own bookkeeping and not API: what the app renders is the
    /// database.
    struct IssueSweepDelta: Sendable, Hashable {
        /// The issues this sweep saw for the first time.
        var newIssueIDs: [String] = []
        /// The issues the prune actually removed.
        var departedIssueIDs: [String] = []
    }

    /// Runs the issues sweep, when the engine was built with the ports for it.
    ///
    /// ``runSweep()``'s delta logic, on the other kind of row: the cached rows are the "before",
    /// the three facet searches are the "after", first sightings and departures are the
    /// difference, and the prune is the store's — guarded by
    /// ``ShepherdPersistence/DatabaseManager/issuePruneGuardSQL``, so an issue the user has a
    /// queued mutation for stays.
    ///
    /// Three things differ from the pull-request sweep, and each one is a decision:
    ///
    /// - **No detail fetches.** An issue's body is fetched when somebody opens it; there is no
    ///   diff to stagger and nothing on the row that a detail read would keep fresh, so the
    ///   sweep is one round of searches and one write.
    /// - **It cannot fail the cycle.** This method does not `throw`: a failure becomes a
    ///   ``SyncEvent/syncFailed(_:)`` on the sweep stage — the same way the pull-request sweep's
    ///   own errors surface — and the caller carries on. The alternative would let a GitHub
    ///   account without issues enabled, or one search that timed out, take the review inbox
    ///   down with it, and the review inbox is what Shepherd is for. It is *reported* rather than
    ///   swallowed, unlike the track record's capture, because the user asked for this section
    ///   and an inbox that is quietly two days stale is worse than a line saying so.
    /// - **"Departed" is what the prune removed**, not what the search stopped returning: an
    ///   issue held open by the guard is deliberately kept, and it is not gone.
    ///
    /// The previous and remaining reads both ask for closed issues too. The sweep only searches
    /// open ones, so a stored closed row exists exactly when it was captured or the guard kept it,
    /// and a delta blind to those rows would announce the same issue as a first sighting on every
    /// pass.
    ///
    /// An issue the search stopped returning is **not** simply pruned any more: it goes through
    /// ``captureIssueOutcomes(for:)`` first, which is what makes the digest's
    /// "an agent's pull request closed one of these" line able to fire at all.
    @discardableResult
    func runIssueSweep() async -> IssueSweepDelta {
        guard let issues else { return IssueSweepDelta() }
        let everything = IssueFilter(includeClosed: true)
        do {
            let previous = try await issues.store.fetchIssues(filter: everything)
            let previousIDs = Set(previous.map(\.id))

            let current = try await issues.fetcher.searchOpenIssues(queries: issues.queries)
            let currentIDs = Set(current.map(\.id))
            let firstSightings = current.map(\.id).filter { !previousIDs.contains($0) }

            // What the search no longer returns: closed, retained from an earlier close, or
            // merely out of the user's facets. One read each decides which, and the rows that
            // come back are written *beside* the search's own — the write is also the prune, so
            // a row that is not in this array is a row that goes.
            let retained = await captureIssueOutcomes(
                for: previous.filter { !currentIDs.contains($0.id) }
            )

            // Every write is preceded by a cancellation check, as in the pull-request sweep: a
            // sweep stopped because the user signed out must not repopulate tables the erase has
            // already emptied.
            try Task.checkCancellation()
            try await issues.store.saveIssueSummaries(current + retained, pruneMissing: true)

            let remaining = Set(
                try await issues.store.fetchIssues(filter: everything).map(\.id)
            )
            let departed = previous
                .map(\.id)
                .filter { !currentIDs.contains($0) && !remaining.contains($0) }

            let delta = IssueSweepDelta(
                newIssueIDs: firstSightings,
                departedIssueIDs: departed
            )
            lastIssueSweep = delta
            return delta
        } catch is CancellationError {
            return IssueSweepDelta()
        } catch {
            emit(
                .syncFailed(
                    SyncFailure(stage: .sweep, message: "issue sweep: \(describe(error))")
                )
            )
            return IssueSweepDelta()
        }
    }

    /// How long a closed issue stays on disk after it was closed.
    ///
    /// Fourteen days, and the number is a compromise between the two things the row is kept for:
    /// the morning digest's "an agent's pull request closed one of these as completed" line, which
    /// is a *state* and must survive more than one night (ADR 0032's Sprint 4a amendment), and
    /// ⌘K's second corpus, which should still answer for something closed last week rather than
    /// saying "no results". It is also what stops `issues` growing without bound: the sweep
    /// searches `is:open`, so nothing else would ever take a closed row away.
    ///
    /// Measured from ``ShepherdCore/IssueRowSummary/closedAt``, falling back to `updatedAt` for a
    /// row GitHub reported closed without one — a missing timestamp must not mean "keep forever".
    static let closedIssueRetention: TimeInterval = 14 * 24 * 60 * 60

    /// How many disappeared issues one sweep is allowed to read.
    ///
    /// The pull-request outcome capture's "one request each, sequentially" with a hard stop on
    /// top, because the two disappearances are not equally rare: a pull request leaves the inbox
    /// when it is merged or closed, while an issue also leaves it when the user is unassigned from
    /// twenty of them at once. Rows over the cap are **kept**, not pruned, so the next sweep reads
    /// the next few — the queue drains at this rate instead of the whole batch hitting GitHub's
    /// secondary rate limit in one pass.
    static let maxIssueOutcomeReadsPerSweep = 10

    /// Reads the final state of the issues the search stopped returning, and decides which rows
    /// survive the prune (ADR 0032's 2026-09-03 amendment).
    ///
    /// ADR 0027's outcome capture, on the other kind of row and with one difference that matters:
    /// a pull request's outcome goes into a table of its own that outlives the pull request, while
    /// an issue has no such table — so the outcome is written **onto the row**, and the row is
    /// what has to stay. Everything this returns is handed to
    /// ``ShepherdPersistence/DatabaseManager/saveIssueSummaries(_:pruneMissing:)`` beside the
    /// search's own results, where being in the array is exactly what keeps a row from being
    /// pruned.
    ///
    /// Four answers, and each one is a decision:
    ///
    /// - **Closed on GitHub** → the row is updated in place with `state`, `stateReason`,
    ///   `closedAt`, `updatedAt` and the links the by-number query already selects, and kept until
    ///   ``closedIssueRetention`` runs out. Its relations are the stored ones: the by-number read
    ///   claims none, deliberately (`GitHubClient.issueRow`), and the store's own rule keeps what
    ///   the sweep saw.
    /// - **Still open on GitHub** → it merely left the user's facets (unassigned, mention
    ///   removed), so it is pruned exactly as it was before this existed. So is an issue GitHub no
    ///   longer answers for at all.
    /// - **The read failed** → the row is kept *unchanged* and read again on the next sweep. A
    ///   tunnel says nothing about the issue, and pruning on it would throw away the one moment
    ///   the outcome could have been learned.
    /// - **Already stored closed** → no read at all. The outcome was captured on the sweep that
    ///   saw it go; this pass only asks whether the window has run out.
    ///
    /// Like the track record's capture the reads are sequential and their failures are swallowed
    /// rather than reported: nobody is waiting on the answer, and a sweep that announced itself
    /// broken because one extra read timed out would be worse than a row updated one pass later.
    /// - Parameter missing: The stored rows this sweep's search did not return.
    /// - Returns: The rows to write back, and therefore to keep.
    private func captureIssueOutcomes(for missing: [IssueRowSummary]) async -> [IssueRowSummary] {
        guard let issues, !missing.isEmpty else { return [] }
        let moment = now()
        var retained: [IssueRowSummary] = []
        var reads = 0
        for row in missing {
            if Task.isCancelled { return retained }
            guard row.state != .closed else {
                // Captured already: the only question left is how old it is.
                if SyncEngine.isWithinClosedIssueRetention(row, now: moment) {
                    retained.append(row)
                }
                continue
            }
            guard reads < SyncEngine.maxIssueOutcomeReadsPerSweep else {
                retained.append(row)
                continue
            }
            reads += 1
            do {
                guard let fresh = try await issues.fetcher.issueRow(
                    repo: row.repo,
                    number: row.number
                ) else { continue }
                guard fresh.state == .closed else { continue }
                let captured = SyncEngine.captured(row, from: fresh)
                if SyncEngine.isWithinClosedIssueRetention(captured, now: moment) {
                    retained.append(captured)
                }
            } catch is CancellationError {
                return retained
            } catch {
                retained.append(row)
            }
        }
        return retained
    }

    /// The stored row with the five fields the outcome read is allowed to change.
    ///
    /// Deliberately not the fetched row itself: that one carries no relations (a by-number read
    /// cannot know them) and was never told how the user relates to the issue, while the stored row
    /// is the one the facets, the search index and the digest have been reading all along.
    /// - Parameters:
    ///   - stored: The row on disk.
    ///   - fresh: What the by-number read answered.
    /// - Returns: The row to write back.
    static func captured(
        _ stored: IssueRowSummary,
        from fresh: IssueRowSummary
    ) -> IssueRowSummary {
        var row = stored
        row.state = fresh.state
        row.stateReason = fresh.stateReason
        row.closedAt = fresh.closedAt
        row.updatedAt = fresh.updatedAt
        row.linkedPullRequests = fresh.linkedPullRequests
        return row
    }

    /// Whether a closed row is still inside ``closedIssueRetention``.
    /// - Parameters:
    ///   - row: The closed row.
    ///   - now: The moment to measure against.
    /// - Returns: `true` while the row is worth keeping.
    static func isWithinClosedIssueRetention(_ row: IssueRowSummary, now: Date) -> Bool {
        let closedAt = row.closedAt ?? row.updatedAt
        return now.timeIntervalSince(closedAt) < closedIssueRetention
    }

    // MARK: - Outbox

    /// The result of attempting one outbox row.
    private enum OutboxOutcome {
        /// The mutation reached GitHub.
        case sent
        /// The mutation was not sent because the pull request moved on.
        case conflict(DraftConflict)
        /// The mutation was not sent because the **issue** moved on (ADR 0032's Sprint 4a
        /// amendment).
        ///
        /// Its own case rather than a ``DraftConflict`` with timestamps in the two SHA fields,
        /// because ``SyncEvent/draftConflict(_:)`` promises something an issue write cannot
        /// offer: a review draft that is still on disk and can be re-applied against the new
        /// head. A parked issue row is parked, counted by
        /// ``ShepherdPersistence/DatabaseManager/conflictedOutboxCount()`` beside every other
        /// parked row, and left for the user — which is the whole of what ADR 0006 asks for.
        case staleIssue(reason: String)
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
                    await followUp(for: item)
                case .conflict(let conflict):
                    try await store.markOutboxItemConflicted(
                        id: item.id,
                        reason: "Head moved from \(conflict.expectedHeadOid) to \(conflict.actualHeadOid)"
                    )
                    emit(.draftConflict(conflict))
                case .staleIssue(let reason):
                    // Parked, and nothing is emitted: there is no draft to re-apply and no
                    // alert that could offer one. The standing conflicted count is the surface.
                    try await store.markOutboxItemConflicted(id: item.id, reason: reason)
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

    /// The best-effort tidying-up a sent row leaves behind, run **after** the row is gone.
    ///
    /// Keyed on the action here rather than done inside ``execute(_:)``, and the position is the
    /// whole point of it. Everything between a write reaching GitHub and
    /// ``ShepherdPersistence/DatabaseManager/markOutboxItemSucceeded(id:)`` is a window in which
    /// a crash costs the *write*: the row is left in `sending`, the next launch resets it to
    /// `pending`, and the mutation is sent a second time. Branch deletion is two network
    /// round-trips, so doing it before the mark made that window two round-trips wide for the one
    /// action that cannot be sent twice — a second merge is a `405`, which is not retryable.
    /// After the mark there is no window left: a crash here costs a branch that stays behind and
    /// nothing else, and the next launch finds a row that is already gone.
    /// - Parameter item: The row that has just been marked succeeded.
    private func followUp(for item: OutboxItem) async {
        switch item.action {
        case .merge(_, _, let deletesHeadBranch) where deletesHeadBranch:
            await deleteHeadBranch(of: item)
        default:
            return
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
                // The same comparison the bulk-triage dialog warns with, so what the user was
                // told before the confirm is what actually happens here (ADR 0015).
                if draft.isStale(against: head) {
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
            await captureBaseline(for: item, draft: draft)
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

        case .merge(let method, let expectedHeadOid, _):
            do {
                _ = try await github.mergePullRequest(
                    repo: item.repo,
                    number: item.number,
                    method: MergeMethod(rawValue: method) ?? .merge,
                    expectedHeadOid: expectedHeadOid,
                    commitTitle: nil
                )
            } catch GitHubError.notMergeable(let message) {
                // GitHub answers a merge on a pull request that is *already merged* with the same
                // `405` it answers one that cannot be merged at all with, and `405` is not
                // retryable — so without this the row would be parked as failed with "cannot be
                // merged" for a merge that landed. That is not a hypothetical: a row is only
                // marked succeeded after `execute` returns, so a crash in between leaves a
                // `sending` row that the next launch resets to `pending` and sends again.
                // One read tells the two apart, and it is only made on the refusal.
                guard try await github.isPullRequestMerged(
                    repo: item.repo,
                    number: item.number
                ) else {
                    throw GitHubError.notMergeable(message: message)
                }
            }
            // The head branch is deliberately *not* deleted here: it is the drain's follow-up,
            // run only once the row is gone — see `followUp(for:)`.
            return .sent

        case .markReadyForReview:
            try await github.markReadyForReview(pullRequestID: item.prID)
            return .sent

        // The five issue actions (ADR 0032's Sprint 4a amendment). Every one of them goes
        // through `issueTarget(for:)` first, so the precondition cannot be forgotten for one of
        // them, and `item.prID`/`repo`/`number` are read here as *the issue's* node id,
        // repository and number — see ``ShepherdCore/OutboxItem``'s own note.
        case .addIssueComment(let body, let basedOnUpdatedAt):
            let target = try await issueTarget(for: item, basedOnUpdatedAt: basedOnUpdatedAt)
            switch target {
            case .stale(let outcome):
                return outcome
            case .fresh(let writes):
                try await writes.addIssueComment(repo: item.repo, number: item.number, body: body)
                return .sent
            }

        case .addIssueLabel(let name, let basedOnUpdatedAt):
            let target = try await issueTarget(for: item, basedOnUpdatedAt: basedOnUpdatedAt)
            switch target {
            case .stale(let outcome):
                return outcome
            case .fresh(let writes):
                try await writes.addIssueLabels(
                    repo: item.repo,
                    number: item.number,
                    labels: [name]
                )
                return .sent
            }

        case .addIssueAssignee(let login, let basedOnUpdatedAt):
            let target = try await issueTarget(for: item, basedOnUpdatedAt: basedOnUpdatedAt)
            switch target {
            case .stale(let outcome):
                return outcome
            case .fresh(let writes):
                try await writes.addIssueAssignees(
                    repo: item.repo,
                    number: item.number,
                    logins: [login]
                )
                return .sent
            }

        case .closeIssue(let reason, let basedOnUpdatedAt):
            let target = try await issueTarget(for: item, basedOnUpdatedAt: basedOnUpdatedAt)
            switch target {
            case .stale(let outcome):
                return outcome
            case .fresh(let writes):
                try await writes.setIssueState(
                    repo: item.repo,
                    number: item.number,
                    state: reason.apiState,
                    stateReason: reason.rawValue
                )
                return .sent
            }

        case .reopenIssue(let basedOnUpdatedAt):
            let target = try await issueTarget(for: item, basedOnUpdatedAt: basedOnUpdatedAt)
            switch target {
            case .stale(let outcome):
                return outcome
            case .fresh(let writes):
                // No `state_reason`: "reopened" is what GitHub records by itself, and sending a
                // reason Shepherd invented would be a second opinion about why.
                try await writes.setIssueState(
                    repo: item.repo,
                    number: item.number,
                    state: "open",
                    stateReason: nil
                )
                return .sent
            }
        }
    }

    /// Deletes the merged pull request's head branch, when the row asked for it and both guards
    /// pass (ADR 0005's 2026-09-05 amendment).
    ///
    /// Nothing in here can fail the merge, and that is the whole shape of it. By the time this
    /// runs the pull request is merged *on GitHub* and the row has already left the queue: a row
    /// that reported failure for a thing that had succeeded would be retried, and the retry would
    /// be a merge GitHub refuses — or a merge the user re-queues by hand, having been told theirs
    /// did not land. So every way out of this function is silent.
    ///
    /// The guards are read here rather than only in the merge sheet because the sheet is not the
    /// only thing that queues a merge, and because they are facts about GitHub rather than about
    /// the click: a pull request can be re-targeted, and a fork can be deleted, between the tick
    /// and the drain. What a refusal or a failure leaves behind is the request-log entry GitHubKit
    /// writes for every request — including the `422 Reference does not exist` that a repository
    /// with "automatically delete head branches" switched on produces, which is that repository
    /// having already done this for us rather than anything worth a warning.
    /// - Parameter item: The merge row that has just been sent and marked succeeded.
    private func deleteHeadBranch(of item: OutboxItem) async {
        // An engine built without the port deletes nothing, exactly as one built without a
        // snapshot writer keeps no baseline (ADR 0028).
        guard let branchDeletion else { return }
        // An unanswerable guard is a refusal: a probe that failed says nothing about the branch,
        // and "we could not check whether this is a fork" is not permission to delete it.
        guard let context = try? await branchDeletion.headBranchContext(
            repo: item.repo,
            number: item.number
        ) else { return }
        guard let branch = context.deletableBranch(in: item.repo) else { return }
        try? await branchDeletion.deleteBranch(repo: item.repo, name: branch)
    }

    /// What the staleness probe found: either a writer to go ahead with, or the outcome to park
    /// the row with.
    private enum IssueTarget {
        /// The issue is where it was when the row was queued.
        case fresh(any IssueWriting)
        /// The issue moved on; nothing may be sent.
        case stale(OutboxOutcome)
    }

    /// Probes the issue and decides whether the queued write may go out (ADR 0006, ADR 0032).
    ///
    /// This is `ReviewDraft.basedOnHeadOid`'s rule on the other kind of node: the field a review
    /// is pinned to is the head commit, and the field an issue write is pinned to is `updatedAt`,
    /// because that is what GitHub moves for every edit, label, assignment, comment and state
    /// change. A mismatch parks the row; it does **not** send and then apologise.
    ///
    /// A probe that *fails* is a plain failure and therefore a backoff — the row stays queued and
    /// is tried again — rather than a conflict. The two are genuinely different: a conflict is a
    /// fact about the issue that will not change by waiting, while a probe that could not be made
    /// says nothing about the issue at all, and parking on it would turn every tunnel into a pile
    /// of rows the user has to clear by hand.
    /// - Parameters:
    ///   - item: The outbox row, whose target fields name the issue.
    ///   - basedOnUpdatedAt: The `updatedAt` the action was composed against.
    /// - Returns: The writer to proceed with, or the outcome to park with.
    /// - Throws: Whatever the probe or the missing port failed with.
    private func issueTarget(
        for item: OutboxItem,
        basedOnUpdatedAt: Date
    ) async throws -> IssueTarget {
        guard let issueWrites else {
            // Not retryable: an engine built without the port will never grow one at runtime, so
            // a backoff would only mean the same sentence every fifteen minutes.
            throw GitHubError.validationFailed(
                message: "This build of the sync engine cannot send issue writes."
            )
        }
        let state = try await issueWrites.issueState(repo: item.repo, number: item.number)
        guard state.isStale(against: basedOnUpdatedAt) else { return .fresh(issueWrites) }
        return .stale(
            .staleIssue(
                reason: "The issue moved on before the write could run: it was last updated "
                    + GitHubTimestamp.string(from: basedOnUpdatedAt)
                    + " when this was queued, and GitHub now says "
                    + GitHubTimestamp.string(from: state.updatedAt)
                    + "."
            )
        )
    }

    // MARK: - Helpers

    /// Stores the diff the review that was just sent was written against (ADR 0028).
    ///
    /// The head is the draft's own ``ShepherdCore/ReviewDraft/basedOnHeadOid`` — the commit the
    /// staleness check above just re-validated, so it is the head the reviewer really saw. A
    /// draft that carries none (a summary-only review queued before any detail fetch) falls
    /// back to the head at drain time; that leaves a small window in which a push between the
    /// review being written and the drain running would label the *new* head as reviewed, which
    /// is why the fallback is second and not first.
    ///
    /// Failures are swallowed on purpose: the mutation has already reached GitHub, and a
    /// baseline that could not be written must not turn a sent review into a retried one. The
    /// cost of losing it is that the review screen offers no "Since your review" tab.
    /// - Parameters:
    ///   - item: The outbox row that was just sent.
    ///   - draft: The submitted review.
    private func captureBaseline(for item: OutboxItem, draft: ReviewDraft) async {
        guard let snapshots else { return }
        var head = draft.basedOnHeadOid
        if head.isEmpty {
            head = (try? await github.headRefOid(repo: item.repo, number: item.number)) ?? ""
        }
        guard !head.isEmpty else { return }
        _ = try? await snapshots.captureReviewSnapshot(
            prID: item.prID,
            reviewedHeadOid: head,
            reviewedAt: now()
        )
    }

    /// The head a review by the viewer was submitted against, when the pull request is *still*
    /// on that commit.
    ///
    /// The retroactive baseline (ADR 0028): a review submitted on github.com, or by a Shepherd
    /// on another Mac, leaves a timeline event carrying its commit. While the pull request has
    /// not moved on, the diff Shepherd holds now *is* the diff that was reviewed, so a snapshot
    /// written from it is exact rather than a guess. The moment the head moves the chance is
    /// gone and nothing is written — the plan's "unavailable" case, in which the review screen
    /// shows no tab at all.
    ///
    /// Pure and `static` so the rule is unit-tested without an engine.
    /// - Parameters:
    ///   - detail: The freshly fetched detail.
    ///   - viewerLogin: The signed-in user's login.
    /// - Returns: The commit and the review's timestamp, or `nil` when there is no such review.
    static func retroactiveBaseline(
        detail: PullRequestDetail,
        viewerLogin: String
    ) -> (headRefOid: String, reviewedAt: Date)? {
        let head = detail.summary.headRefOid
        guard !head.isEmpty, !viewerLogin.isEmpty, !detail.files.isEmpty else { return nil }
        let reviews = detail.timeline.filter { event in
            switch event.kind {
            case .reviewApproved, .reviewChangesRequested, .reviewCommented:
                return event.commitOid == head
                    && event.author.login.caseInsensitiveCompare(viewerLogin) == .orderedSame
            default:
                return false
            }
        }
        guard let newest = reviews.map(\.createdAt).max() else { return nil }
        return (head, newest)
    }

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
        case .merge(let method, _, _): return .merged(method: method)
        case .markReadyForReview: return .markedReadyForReview
        case .addIssueComment: return .issueCommentAdded
        case .addIssueLabel(let name, _): return .issueLabelAdded(name: name)
        case .addIssueAssignee(let login, _): return .issueAssigneeAdded(login: login)
        case .closeIssue(let reason, _): return .issueClosed(reason: reason.rawValue)
        case .reopenIssue: return .issueReopened
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
