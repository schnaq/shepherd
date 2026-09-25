import Foundation
import GitHubKit
import Observation
import ShepherdCore
import ShepherdSync

/// One write a merge series asks the outbox for.
enum MergeSeriesWrite: Sendable, Equatable {
    /// Merge this pull request, pinned to the summary's head.
    case merge(PullRequestSummary, method: MergeMethod, deletesHeadBranch: Bool)
    /// Bring this pull request's branch up to date, pinned to the summary's head.
    case updateBranch(PullRequestSummary)

    /// The pull request the write targets.
    var pullRequest: PullRequestSummary {
        switch self {
        case .merge(let summary, _, _), .updateBranch(let summary): return summary
        }
    }
}

/// How a series write reaches the outbox.
///
/// In the app it is ``PullRequestActions/merge(_:method:deletesHeadBranch:)`` or
/// ``PullRequestActions/updateBranch(_:)`` — the same funnel a click goes through — and in the
/// tests a closure that records what it was asked. The answer is whether a row was **written**:
/// the funnel can refuse before it writes anything (a merge already on its way, a blocker, a
/// second press still running, a local write error), and an entry that waits for a row that was
/// never written would wait for ever.
typealias MergeSeriesWriting = @MainActor (MergeSeriesWrite) async -> Bool

/// What the outbox holds and what the drain confirmed, read once per pass.
struct MergeSeriesOutboxSnapshot: Sendable, Equatable {
    /// Every outbox row.
    var items: [OutboxItem]
    /// Pull requests whose merge GitHub confirmed in this session
    /// (``SignedInSession/mergedPullRequestIDs``).
    var mergedIDs: Set<String>

    /// Creates a snapshot.
    init(items: [OutboxItem] = [], mergedIDs: Set<String> = []) {
        self.items = items
        self.mergedIDs = mergedIDs
    }

    /// Pull requests with a row still waiting to be sent or being sent.
    ///
    /// Deliberately **not** every row: a failed or parked row stays in the outbox until somebody
    /// discards it, and counting it as "a write still in flight" would make an entry wait for ever
    /// behind an old refusal it has nothing to do with.
    var queuedIDs: Set<String> {
        Set(items.filter { $0.state == .pending || $0.state == .sending }.map(\.prID))
    }

    /// Whether a failed or parked row for this pull request was created at or after `since`.
    ///
    /// Only rows from the entry's own turn count. A 405 parked by an earlier bulk merge — before
    /// the series started, or before this entry became active — is not something this entry did,
    /// and skipping it for that would skip exactly the pull request the series exists to merge.
    func hasFailedWrite(for prID: String, since: Date) -> Bool {
        items.contains { item in
            item.prID == prID
                && (item.state == .failed || item.state == .conflicted)
                && item.createdAt >= since
        }
    }
}

/// How the outbox is read for a pass. A closure, so the read happens *after* the pass has claimed
/// its turn (``MergeSeriesCoordinator/run(rows:alsoQueued:readOutbox:write:)``) and the tests need
/// no database.
typealias MergeSeriesOutboxReading = @MainActor () async -> MergeSeriesOutboxSnapshot

/// What one pass did.
struct MergeSeriesPassResult: Sendable, Equatable {
    /// The writes asked for, in order. A write the funnel refused is included; its entry was
    /// skipped.
    var writes: [MergeSeriesWrite] = []
    /// The series that finished in this pass and were announced and pruned.
    var finished: [MergeSeries] = []
}

/// Merges several pull requests of a repository one after another (ADR 0041).
///
/// The division of labour is ``MergeWhenGreenCoordinator``'s: the decision per sweep is the pure
/// ``ShepherdCore/MergeSeriesPolicy``, and this type supplies its inputs, stores what it returns,
/// performs the one write through the seam above and tells the user once a series is done.
///
/// Three things here are not in the policy and are the reason this type is more than a loop:
///
/// - **Save before write.** The stepped series is stored *before* the write is awaited. The
///   funnel drains the outbox inside that await, so the confirmation of a fast merge can arrive
///   before the write returns — and a confirmation for an entry the store still has as `pending`
///   would be ignored by ``ShepherdCore/MergeSeries/markBranchUpdated(_:)`` and lost.
/// - **Reconcile from the outbox.** The drain's events are the fast path, not the only one: an
///   event can be missed (the app quit between the send and the event, the event arrived for a
///   series this build could not read). Every pass therefore reads the outcome off the outbox
///   itself: a merge whose row is gone without a failure landed; an update whose row is gone
///   without a failure was accepted.
/// - **Fresh rows after a merge.** After GitHub confirms entry *n*'s merge, the rows the inbox
///   holds still show entry *n + 1* as it was *before* its base moved — typically `CLEAN`. Acting
///   on them would queue a merge GitHub refuses with `405`, which is the failure this whole
///   feature exists to avoid. So the next entry is not stepped until a sweep has shown the merged
///   pull request gone (``sweepAfterMergeTimeout`` bounds the wait).
@MainActor
@Observable
final class MergeSeriesCoordinator {
    /// How long an active entry whose row left the inbox is waited for, and how long a branch
    /// update GitHub accepted may take to produce its commit, before the entry is skipped.
    ///
    /// An hour rather than merge-when-green's seven days: a series is something the user is
    /// actively waiting on, and one stuck entry blocks every entry behind it. An hour is still
    /// far longer than a search hiccup or GitHub's update-branch job.
    static let missingRowGracePeriod: TimeInterval = 60 * 60

    /// How long the next entry waits for a sweep that shows the merged one gone, before it is
    /// stepped on the rows there are. A pull request that stays in the search after its merge
    /// (a watched repository's closed-but-cached row, a search index that is very behind) must
    /// not stop the series for good.
    static let sweepAfterMergeTimeout: TimeInterval = 10 * 60

    private let settings: AppSettings
    private let store: MergeSeriesStore
    private let now: @MainActor () -> Date
    private let notify: @MainActor (NotificationPayload) -> Void

    /// Whether a pass is between its outbox read and its last write. Passes do not overlap: a
    /// second one would read the outbox while the first is between saving an entry as
    /// `updatingBranch` and writing its row, and reconcile it as already updated.
    @ObservationIgnored private var isRunning = false
    /// The pass asked for while one was running; run as soon as it finishes, so a Start pressed
    /// during a sweep's pass is not left for the next sweep.
    @ObservationIgnored private var pendingPass: (@MainActor () async -> Void)?
    /// Series whose last merge GitHub confirmed while its row was still in the inbox: the merged
    /// pull request and when. Cleared by the first pass whose rows no longer contain it.
    /// In memory only: after a relaunch the first sweep runs at once anyway.
    @ObservationIgnored private var awaitingFreshRows: [String: (prID: String, since: Date)] = [:]

    /// Creates a coordinator.
    /// - Parameters:
    ///   - settings: The fallback merge method for a series whose own method cannot be read.
    ///   - store: The persistent series.
    ///   - now: The clock. Injectable for tests.
    ///   - notify: Where the summary notice goes.
    init(
        settings: AppSettings,
        store: MergeSeriesStore,
        now: @escaping @MainActor () -> Date = { Date() },
        notify: @escaping @MainActor (NotificationPayload) -> Void = { _ in }
    ) {
        self.settings = settings
        self.store = store
        self.now = now
        self.notify = notify
    }

    // MARK: - Reading

    /// Whether any series is running — the one cheap read the inbox observation makes.
    var hasRunningSeries: Bool { store.hasRunningSeries }

    /// The running series, oldest first, for Settings → Sync.
    var runningSeries: [MergeSeries] { store.series.filter { !$0.isFinished } }

    /// The running series a pull request belongs to, if any.
    /// - Parameter prID: The pull request's node id.
    func series(containing prID: String) -> MergeSeries? {
        store.series(containing: prID)
    }

    /// Every pull request that is part of a running series, finished entries included — what the
    /// sheet leaves out as *merge already on its way*, so no pull request is in two series.
    var pullRequestIDsInSeries: Set<String> {
        Set(runningSeries.flatMap { $0.entries.map(\.prID) })
    }

    /// The chip state for a pull request, or `nil` when it is in no running series.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - row: The pull request as the caller shows it, for the checks it is waiting on.
    func chip(for prID: String, row: PullRequestSummary?) -> MergeSeriesChip? {
        guard let series = store.series(containing: prID) else { return nil }
        return MergeSeriesChip.make(series: series, prID: prID, row: row)
    }

    /// Whether **Remove from series** can still take this pull request out.
    ///
    /// Not once its merge is queued: the outbox row cannot be taken back, so the confirmation
    /// decides (``ShepherdCore/MergeSeries/remove(_:)``).
    /// - Parameter prID: The pull request's node id.
    func canRemove(_ prID: String) -> Bool {
        guard let entry = store.series(containing: prID)?.entry(for: prID) else { return false }
        switch entry.state {
        case .pending, .updatingBranch, .branchUpdated: return true
        case .merging, .merged, .skipped: return false
        }
    }

    // MARK: - Starting and stopping

    /// Records the user's Start: one series per repository, each entry pinned to the head the
    /// sheet showed.
    /// - Parameters:
    ///   - groups: Each repository with its pull requests, in the order the sheet showed.
    ///   - method: The merge method on the sheet.
    ///   - deletesHeadBranch: The branch box on the sheet.
    /// - Returns: The series stored.
    @discardableResult
    func start(
        _ groups: [(repository: RepoRef, pullRequests: [PullRequestSummary])],
        method: MergeMethod,
        deletesHeadBranch: Bool
    ) -> [MergeSeries] {
        let moment = now()
        // Never two running series over one pull request: the sheet already leaves those out,
        // and this is the backstop for a sheet that was open while another Start ran.
        let taken = pullRequestIDsInSeries
        let series = groups.compactMap { group -> MergeSeries? in
            let pullRequests = group.pullRequests.filter { !taken.contains($0.id) }
            guard !pullRequests.isEmpty else { return nil }
            return MergeSeries(
                repository: group.repository,
                pullRequests: pullRequests,
                mergeMethod: method.rawValue,
                deletesHeadBranch: deletesHeadBranch,
                now: moment
            )
        }
        store.add(series)
        return series
    }

    /// **Remove from series**: the entry is skipped as *removed by user*, and the series goes on.
    /// - Parameter prID: The pull request's node id.
    func remove(_ prID: String) {
        guard let series = store.series(containing: prID) else { return }
        store.update(series.id) { $0.remove(prID) }
        finishIfDone(series.id)
    }

    /// **Cancel** in Settings: every entry that has not been queued yet is removed. A merge that
    /// is already in the outbox still lands, and the series finishes when it does.
    /// - Parameter id: The series id.
    func cancel(seriesID id: String) {
        store.update(id) { series in
            let before = series
            series.cancel()
            return series != before
        }
        finishIfDone(id)
    }

    /// Forgets every series. Called from "Sign out & erase local data".
    func reset() {
        store.reset()
        awaitingFreshRows = [:]
    }

    // MARK: - Events (the fast path)

    /// GitHub confirmed a merge (`mutationSent(.merged)`). The confirmation wins over any state,
    /// a skip included, so a pull request merged by hand mid-series counts as merged.
    /// - Parameter prID: The pull request's node id.
    func noteMerged(_ prID: String) {
        for series in store.series where series.entry(for: prID) != nil && !series.isFinished {
            let changed = store.update(series.id) { $0.markMerged(prID) }
            if changed?.entry(for: prID)?.state == .merged {
                // The rows in the inbox are from before this merge until the next sweep.
                awaitingFreshRows[series.id] = (prID, now())
            }
            finishIfDone(series.id)
        }
    }

    /// The drain confirmed a branch update (`mutationSent(.branchUpdated)`).
    /// - Parameter prID: The pull request's node id.
    func noteBranchUpdated(_ prID: String) {
        guard let series = store.series(containing: prID) else { return }
        store.update(series.id) { $0.markBranchUpdated(prID) }
    }

    /// Whether a parked write's alert should stay down because the series already handles it.
    ///
    /// The drain raises ``ShepherdSync/SyncEvent/draftConflict(_:)`` for a branch update whose
    /// pin went stale, and the alert it pops talks about a review draft to re-apply — which a
    /// series' update does not have. The series skips such an entry (*update refused*) and says
    /// so in its chip and its summary, so the alert would be a second, wrong explanation.
    /// `DraftConflict` carries no action kind; the entry's state and the pin it was updating
    /// from identify the update exactly, without a database read.
    /// - Parameter conflict: The parked write.
    func handlesConflict(_ conflict: DraftConflict) -> Bool {
        guard let entry = store.series(containing: conflict.prID)?.entry(for: conflict.prID) else {
            return false
        }
        switch entry.state {
        case .updatingBranch(let from), .branchUpdated(let from):
            return from == conflict.expectedHeadOid
        case .pending, .merging, .merged, .skipped:
            return false
        }
    }

    // MARK: - The pass

    /// Advances every running series by one sweep.
    ///
    /// - Parameters:
    ///   - rows: Every inbox row the local database holds.
    ///   - alsoQueued: Pull requests the passes before this one queued a merge for in the same
    ///     sweep (auto-merge, merge when checks pass), which the outbox read may predate.
    ///   - readOutbox: Reads the outbox and the confirmed merges.
    ///   - write: How a write reaches the outbox.
    /// - Returns: What was written and which series finished.
    @discardableResult
    func run(
        rows: [PullRequestSummary],
        alsoQueued: Set<String> = [],
        readOutbox: @escaping MergeSeriesOutboxReading,
        write: @escaping MergeSeriesWriting
    ) async -> MergeSeriesPassResult {
        guard !store.series.isEmpty else { return MergeSeriesPassResult() }
        guard !isRunning else {
            pendingPass = { [weak self] in
                await self?.run(rows: rows, alsoQueued: alsoQueued, readOutbox: readOutbox, write: write)
            }
            return MergeSeriesPassResult()
        }
        isRunning = true
        var result = await pass(rows: rows, alsoQueued: alsoQueued, readOutbox: readOutbox, write: write)
        isRunning = false
        if let next = pendingPass {
            pendingPass = nil
            await next()
        }
        // Finishing is also checked here for a series whose last entry was settled by an event
        // during the pass; `finishIfDone` is idempotent.
        for series in store.series where series.isFinished {
            if let finished = finishIfDone(series.id) { result.finished.append(finished) }
        }
        return result
    }

    private func pass(
        rows: [PullRequestSummary],
        alsoQueued: Set<String>,
        readOutbox: MergeSeriesOutboxReading,
        write: MergeSeriesWriting
    ) async -> MergeSeriesPassResult {
        var result = MergeSeriesPassResult()
        let snapshot = await readOutbox()
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let moment = now()
        var queued = snapshot.queuedIDs.union(alsoQueued)

        for id in store.series.map(\.id) {
            guard let stored = store.series.first(where: { $0.id == id }), !stored.isFinished else {
                continue
            }
            var series = stored
            reconcile(&series, rows: rowsByID, queued: queued, snapshot: snapshot, now: moment)

            if let gate = awaitingFreshRows[id] {
                let fresh = rowsByID[gate.prID] == nil
                let timedOut = moment >= gate.since.addingTimeInterval(Self.sweepAfterMergeTimeout)
                if fresh || timedOut {
                    awaitingFreshRows[id] = nil
                } else {
                    if series != stored { store.save(series) }
                    continue
                }
            }

            let failed = Set(series.entries.compactMap { entry -> String? in
                snapshot.hasFailedWrite(for: entry.prID, since: entry.activeSince ?? moment)
                    ? entry.prID : nil
            })
            let step = MergeSeriesPolicy.step(
                series: series,
                rows: rowsByID,
                existingOutbox: queued,
                failedWrites: failed,
                now: moment,
                gracePeriod: Self.missingRowGracePeriod
            )
            // Stored before the write is awaited — see the type's documentation.
            store.save(step.series)

            guard let entry = step.action.entry,
                  let oid = step.action.expectedHeadOid,
                  var row = rowsByID[entry.prID]
            else { continue }
            // The pin, not whatever the row says, is what the write is pinned to. They are equal
            // whenever the policy acts; this keeps it so if that ever changes.
            row.headRefOid = oid
            let request: MergeSeriesWrite
            switch step.action {
            case .none:
                continue
            case .updateBranch:
                request = .updateBranch(row)
            case .merge:
                let method = MergeMethod(rawValue: step.series.mergeMethod) ?? settings.defaultMergeMethod
                request = .merge(row, method: method, deletesHeadBranch: step.series.deletesHeadBranch)
            }
            queued.insert(entry.prID)
            result.writes.append(request)
            let written = await write(request)
            if !written {
                refuseUnwritten(request, seriesID: id, mergedIDs: snapshot.mergedIDs)
            }
            if let finished = finishIfDone(id) { result.finished.append(finished) }
        }
        return result
    }

    /// Reads what the events may have missed off the outbox (see the type's documentation).
    private func reconcile(
        _ series: inout MergeSeries,
        rows: [String: PullRequestSummary],
        queued: Set<String>,
        snapshot: MergeSeriesOutboxSnapshot,
        now moment: Date
    ) {
        for entry in series.entries where !entry.state.isFinished {
            let isQueued = queued.contains(entry.prID)
            let hasFailed = snapshot.hasFailedWrite(for: entry.prID, since: entry.activeSince ?? moment)
            if snapshot.mergedIDs.contains(entry.prID) {
                series.markMerged(entry.prID)
                if rows[entry.prID] != nil { awaitingFreshRows[series.id] = (entry.prID, moment) }
                continue
            }
            switch entry.state {
            case .merging where !isQueued && !hasFailed && rows[entry.prID] == nil:
                // The row left the outbox without a failure — it was sent — and the pull request
                // left the inbox: merged, and the rows are already from after the merge.
                series.markMerged(entry.prID)
            case .updatingBranch where !isQueued && !hasFailed:
                series.markBranchUpdated(entry.prID)
            default:
                break
            }
        }
    }

    /// Settles an entry whose write the funnel refused before writing a row.
    private func refuseUnwritten(_ request: MergeSeriesWrite, seriesID: String, mergedIDs: Set<String>) {
        let prID = request.pullRequest.id
        store.update(seriesID) { series in
            guard let index = series.entries.firstIndex(where: { $0.prID == prID }) else { return false }
            switch request {
            case .merge:
                // The one refusal that is good news: the merge was already confirmed.
                if mergedIDs.contains(prID) { return series.markMerged(prID) }
                series.entries[index].state = .skipped(.mergeRefused)
            case .updateBranch:
                series.entries[index].state = .skipped(.updateRefused)
            }
            return true
        }
    }

    /// Announces and prunes a series once every entry is merged or skipped. In one main-actor
    /// turn, with no `await` in between, so two paths finishing the same series cannot post two
    /// notices: the second finds it gone.
    /// - Returns: The finished series, when this call announced it.
    @discardableResult
    private func finishIfDone(_ id: String) -> MergeSeries? {
        guard let series = store.series.first(where: { $0.id == id }), series.isFinished else {
            return nil
        }
        store.remove(id)
        awaitingFreshRows[id] = nil
        if let payload = NotificationManager.payload(forFinishedMergeSeries: series) {
            notify(payload)
        }
        return series
    }
}
