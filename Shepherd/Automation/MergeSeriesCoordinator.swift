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

    /// Whether the outbox holds no unsent merge or branch update for this pull request — a
    /// `merging` or `updatingBranch` entry that has none has nothing left to wait for in the
    /// outbox.
    func hasNoUnsentRow(for prID: String) -> Bool {
        !queuedIDs.contains(prID)
    }

    /// Pull requests with a merge or branch update still waiting to be sent or being sent.
    ///
    /// Deliberately **not** every row: a failed or parked row stays in the outbox until somebody
    /// discards it, and counting it as "a write still in flight" would make an entry wait for ever
    /// behind an old refusal it has nothing to do with.
    var queuedIDs: Set<String> {
        Set(items.filter { Self.isSeriesWrite($0) && ($0.state == .pending || $0.state == .sending) }.map(\.prID))
    }

    /// Whether a failed or parked merge or branch update for this pull request was created at or
    /// after `since`.
    ///
    /// Only rows from the entry's own turn count. A 405 parked by an earlier bulk merge — before
    /// the series started, or before this entry became active — is not something this entry did,
    /// and skipping it for that would skip exactly the pull request the series exists to merge.
    func hasFailedWrite(for prID: String, since: Date) -> Bool {
        items.contains { item in
            item.prID == prID
                && Self.isSeriesWrite(item)
                && (item.state == .failed || item.state == .conflicted)
                && item.createdAt >= since
        }
    }

    /// Whether a row is one of the two writes a series makes. Only those say anything about an
    /// entry: a comment or a review for the same pull request that is still queued, or failed,
    /// neither holds the merge back nor refuses it.
    private static func isSeriesWrite(_ item: OutboxItem) -> Bool {
        switch item.action {
        case .merge, .updateBranch: return true
        case .submitReview, .replyToComment, .resolveThread, .unresolveThread, .markReadyForReview,
             .addPullRequestComment, .closePullRequest, .addIssueComment, .addIssueLabel,
             .addIssueAssignee, .closeIssue, .reopenIssue:
            return false
        }
    }
}

/// How the outbox is read for a pass. A closure, so the read happens *after* the pass has claimed
/// its turn (``MergeSeriesCoordinator/run(rows:alsoQueued:readOutbox:isMerged:confirmedMerges:write:)``)
/// and the tests need no database.
///
/// `nil` when the outbox could not be read, and the pass is then skipped whole: an unreadable
/// outbox is not an empty one, and reading it as empty would take every queued merge for landed
/// and every queued update for accepted.
typealias MergeSeriesOutboxReading = @MainActor () async -> MergeSeriesOutboxSnapshot?

/// Asks GitHub whether a pull request is merged (``GitHubKit/GitHubClient/isPullRequestMerged(repo:number:)``).
/// `nil` when it could not be asked — offline, rate-limited — which must never read as "no".
typealias MergeSeriesMergeChecking = @MainActor (_ repository: RepoRef, _ number: Int) async -> Bool?

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
///   itself: an update whose row is gone without a failure was accepted. A merge whose row is
///   gone without a failure and whose pull request left the inbox is asked about once, on
///   GitHub: a row can also leave because somebody discarded it, and a pull request can leave
///   the inbox closed rather than merged.
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
    /// Not while its merge or branch update is in the outbox: the row cannot be taken back, so
    /// the drain's outcome decides — and for an update the entry is also what keeps a parked
    /// row's "review not sent" alert down (``handlesConflict(_:)``). An entry whose row is gone
    /// without an outcome, though, is waiting for nothing, and may go.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - hasUnsentWrite: Whether the outbox holds a pending or sending row for it.
    func canRemove(_ prID: String, hasUnsentWrite: Bool) -> Bool {
        guard let entry = store.series(containing: prID)?.entry(for: prID) else { return false }
        return entry.state.isRemovable(hasNoUnsentWrite: !hasUnsentWrite)
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
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - outbox: The outbox as it stands, so a `merging` or `updatingBranch` entry whose row is
    ///     gone can be removed too. `nil` leaves every such entry to the drain's outcome.
    func remove(_ prID: String, outbox: MergeSeriesOutboxSnapshot? = nil) {
        guard let series = store.series(containing: prID) else { return }
        let hasNoUnsentWrite = outbox?.hasNoUnsentRow(for: prID) ?? false
        store.update(series.id) { $0.remove(prID, hasNoUnsentWrite: hasNoUnsentWrite) }
        finishIfDone(series.id)
    }

    /// **Cancel** in Settings: every entry that has not been queued yet is removed. A merge that
    /// is still in the outbox still lands, and the series finishes when it does; a branch update
    /// still in the outbox still goes out, and its entry is removed once it is settled
    /// (``ShepherdCore/MergeSeriesEntry/removalRequested``).
    /// - Parameters:
    ///   - id: The series id.
    ///   - outbox: The outbox as it stands; see ``remove(_:outbox:)``.
    func cancel(seriesID id: String, outbox: MergeSeriesOutboxSnapshot? = nil) {
        // `queuedIDs` is read once for the whole series rather than through `hasNoUnsentRow` per
        // entry, which would recompute it from the outbox's items every time.
        let queued = outbox?.queuedIDs ?? []
        store.update(id) { series in
            let removable = Set(series.entries.map(\.prID)).subtracting(queued)
            return series.cancel(withoutUnsentWrites: removable)
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

    /// The drain confirmed a branch update (`mutationSent(.branchUpdated)`). For an entry Cancel
    /// asked to take out, that is also the moment it goes, which can finish the series.
    /// - Parameter prID: The pull request's node id.
    func noteBranchUpdated(_ prID: String) {
        guard let series = store.series(containing: prID) else { return }
        store.update(series.id) { $0.markBranchUpdated(prID) }
        finishIfDone(series.id)
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
    ///   - readOutbox: Reads the outbox and the confirmed merges; `nil` skips the pass.
    ///   - isMerged: Asks GitHub whether a `merging` entry that left both the outbox and the
    ///     inbox was merged.
    ///   - confirmedMerges: The merges GitHub confirmed in this session, as they stand *now* —
    ///     read again after a write, which can take long enough for a confirmation to arrive.
    ///   - write: How a write reaches the outbox.
    /// - Returns: What was written and which series finished.
    @discardableResult
    func run(
        rows: [PullRequestSummary],
        alsoQueued: Set<String> = [],
        readOutbox: @escaping MergeSeriesOutboxReading,
        isMerged: @escaping MergeSeriesMergeChecking,
        confirmedMerges: @escaping @MainActor () -> Set<String>,
        write: @escaping MergeSeriesWriting
    ) async -> MergeSeriesPassResult {
        guard !store.series.isEmpty else { return MergeSeriesPassResult() }
        guard !isRunning else {
            pendingPass = { [weak self] in
                await self?.run(
                    rows: rows,
                    alsoQueued: alsoQueued,
                    readOutbox: readOutbox,
                    isMerged: isMerged,
                    confirmedMerges: confirmedMerges,
                    write: write
                )
            }
            return MergeSeriesPassResult()
        }
        isRunning = true
        var result = await pass(
            rows: rows,
            alsoQueued: alsoQueued,
            readOutbox: readOutbox,
            isMerged: isMerged,
            confirmedMerges: confirmedMerges,
            write: write
        )
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
        isMerged: MergeSeriesMergeChecking,
        confirmedMerges: @MainActor () -> Set<String>,
        write: MergeSeriesWriting
    ) async -> MergeSeriesPassResult {
        var result = MergeSeriesPassResult()
        guard let snapshot = await readOutbox() else { return result }
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let moment = now()
        var queued = snapshot.queuedIDs.union(alsoQueued)
        // Asked before any series is copied out of the store: an event that lands while GitHub
        // answers then changes the stored series, which the loop below reads afresh, instead of a
        // copy that the save after the step would write back over it.
        let mergedOnGitHub = await probeVanishedMerges(rows: rowsByID, queued: queued, snapshot: snapshot, isMerged: isMerged)

        for id in store.series.map(\.id) {
            guard let stored = store.series.first(where: { $0.id == id }), !stored.isFinished else {
                continue
            }
            var series = stored
            reconcile(
                &series,
                rows: rowsByID,
                queued: queued,
                snapshot: snapshot,
                mergedOnGitHub: mergedOnGitHub,
                now: moment
            )

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
            // `.none` is already ruled out: the guard above requires `step.action.entry`, which
            // only `.updateBranch` and `.merge` carry.
            let request: MergeSeriesWrite
            if case .merge = step.action {
                let method = MergeMethod(rawValue: step.series.mergeMethod) ?? settings.defaultMergeMethod
                request = .merge(row, method: method, deletesHeadBranch: step.series.deletesHeadBranch)
            } else {
                request = .updateBranch(row)
            }
            queued.insert(entry.prID)
            result.writes.append(request)
            let written = await write(request)
            if !written {
                // Read now, not from the pass's start: the write can take long enough for the
                // confirmation of this very merge to arrive in between.
                refuseUnwritten(request, seriesID: id, mergedIDs: confirmedMerges())
            }
            if let finished = finishIfDone(id) { result.finished.append(finished) }
        }
        return result
    }

    /// Whether a `merging` entry has nothing left to wait for locally: no unsent row, no failed
    /// one, no confirmation, and its pull request is gone from the inbox. Only GitHub can say
    /// what happened to such a merge.
    private func hasVanished(
        _ entry: MergeSeriesEntry,
        rows: [String: PullRequestSummary],
        queued: Set<String>,
        snapshot: MergeSeriesOutboxSnapshot,
        now moment: Date
    ) -> Bool {
        entry.state == .merging
            && !queued.contains(entry.prID)
            && !snapshot.hasFailedWrite(for: entry.prID, since: entry.activeSince ?? moment)
            && !snapshot.mergedIDs.contains(entry.prID)
            && rows[entry.prID] == nil
    }

    /// Asks GitHub, once per pass, about every merge that vanished (``hasVanished(_:rows:queued:snapshot:now:)``).
    /// - Returns: GitHub's answer per pull request; absent where it could not be asked.
    private func probeVanishedMerges(
        rows: [String: PullRequestSummary],
        queued: Set<String>,
        snapshot: MergeSeriesOutboxSnapshot,
        isMerged: MergeSeriesMergeChecking
    ) async -> [String: Bool] {
        let moment = now()
        var candidates: [(prID: String, repository: RepoRef, number: Int)] = []
        for series in store.series where !series.isFinished {
            for entry in series.entries
            where hasVanished(entry, rows: rows, queued: queued, snapshot: snapshot, now: moment) {
                candidates.append((entry.prID, series.repository, entry.number))
            }
        }
        var answers: [String: Bool] = [:]
        for candidate in candidates {
            if let merged = await isMerged(candidate.repository, candidate.number) {
                answers[candidate.prID] = merged
            }
        }
        return answers
    }

    /// Reads what the events may have missed off the outbox (see the type's documentation).
    /// - Parameter mergedOnGitHub: GitHub's answers for the merges that vanished.
    private func reconcile(
        _ series: inout MergeSeries,
        rows: [String: PullRequestSummary],
        queued: Set<String>,
        snapshot: MergeSeriesOutboxSnapshot,
        mergedOnGitHub: [String: Bool],
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
            case .merging where hasVanished(entry, rows: rows, queued: queued, snapshot: snapshot, now: moment):
                // The row left the outbox without a failure and the pull request left the inbox.
                // Likely merged — but the row may have been discarded and the pull request closed
                // or filtered out, so GitHub decides. No answer (offline): ask again next pass.
                switch mergedOnGitHub[entry.prID] {
                case true?:
                    // The rows are already from after the merge; no gate needed.
                    series.markMerged(entry.prID)
                case false?:
                    series.markGoneUnmerged(entry.prID)
                case nil:
                    break
                }
            case .merging where !isQueued && !hasFailed:
                // No row, no failure, no confirmation, and the pull request is still open: the
                // merge was never written (a crash between save and enqueue) or its row was
                // discarded by hand. Waiting for a confirmation that cannot come would hold every
                // entry behind it, so after the grace period the entry is let go.
                let since = entry.mergeQueuedAt ?? entry.activeSince ?? moment
                if moment >= since.addingTimeInterval(Self.missingRowGracePeriod),
                   let index = series.entries.firstIndex(where: { $0.prID == entry.prID }) {
                    series.entries[index].state = .skipped(.mergeRefused)
                }
            case .updatingBranch where !isQueued && !hasFailed:
                series.markBranchUpdated(entry.prID)
            default:
                break
            }
        }
    }

    /// Settles an entry whose write the funnel refused before writing a row.
    ///
    /// Against the store as it is *after* the write: an event handled while the write was
    /// awaited may already have settled the entry (a confirmed merge above all), and that
    /// outcome must not be overwritten with a refusal.
    /// - Parameter mergedIDs: The confirmed merges, read after the write.
    private func refuseUnwritten(_ request: MergeSeriesWrite, seriesID: String, mergedIDs: Set<String>) {
        let prID = request.pullRequest.id
        store.update(seriesID) { series in
            guard let index = series.entries.firstIndex(where: { $0.prID == prID }) else { return false }
            switch request {
            case .merge:
                // The one refusal that is good news: the merge was already confirmed.
                if mergedIDs.contains(prID) { return series.markMerged(prID) }
                guard series.entries[index].state == .merging else { return false }
                series.entries[index].state = .skipped(.mergeRefused)
            case .updateBranch:
                guard case .updatingBranch = series.entries[index].state else { return false }
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
