import Foundation

/// The one write a step of a merge series asks the app to queue.
public enum MergeSeriesAction: Sendable, Hashable {
    /// Nothing to write this sweep.
    case none
    /// Queue GitHub's *Update branch* for this entry, with the pinned head as the precondition.
    case updateBranch(entry: MergeSeriesEntry, expectedHeadOid: String)
    /// Queue the merge for this entry, pinned to this head.
    case merge(entry: MergeSeriesEntry, expectedHeadOid: String)

    /// The entry the write is for, if there is one.
    public var entry: MergeSeriesEntry? {
        switch self {
        case .none: return nil
        case .updateBranch(let entry, _), .merge(let entry, _): return entry
        }
    }

    /// The head commit the write is pinned to, if there is one.
    public var expectedHeadOid: String? {
        switch self {
        case .none: return nil
        case .updateBranch(_, let oid), .merge(_, let oid): return oid
        }
    }
}

/// What one sweep did to one series.
public struct MergeSeriesStep: Sendable, Hashable {
    /// The series with every state change of this sweep applied — the value to store.
    public var series: MergeSeries
    /// The write to queue, at most one.
    public var action: MergeSeriesAction
    /// The entries this sweep skipped, in order, as they stand after the skip — so the app can
    /// log or announce them without diffing.
    public var newlySkipped: [MergeSeriesEntry]

    /// Creates a step.
    public init(series: MergeSeries, action: MergeSeriesAction, newlySkipped: [MergeSeriesEntry] = []) {
        self.series = series
        self.action = action
        self.newlySkipped = newlySkipped
    }
}

/// Drives a merge series one sweep at a time (ADR 0041).
///
/// A pure function over values, split the way ``MergeWhenGreenPolicy`` is: the app supplies the
/// rows the last sweep wrote and what the outbox holds, stores the returned series and queues
/// the returned write through the ordinary outbox. The green-or-not question is answered by
/// ``MergeWhenGreenPolicy/decide(request:pullRequest:existingOutbox:)`` itself, pinned to the
/// entry's head, so a series and a single "merge when checks pass" can never disagree about
/// what green means. What a series adds on top is the order, the branch update for a pull
/// request that fell behind, and the one re-pin that update needs.
///
/// Like merge-when-green, nothing here checks approval, authorship or the repository: the user
/// decided *whether* when they pressed Start. The policy decides only *when*.
public enum MergeSeriesPolicy {
    /// Advances one series by one sweep.
    ///
    /// Only the active entry (the first that is neither merged nor skipped) is evaluated. When
    /// it is skipped, the same step goes on to the next entry, so one sweep can skip several and
    /// act on the one after them; but it emits **at most one** write, and it stops at the first
    /// entry that waits or acts. An entry gets ``MergeSeriesEntry/activeSince`` the first time a
    /// step finds it active.
    ///
    /// The rules for the active entry, in this fixed order, so the reason a chip gives never
    /// depends on evaluation order:
    ///
    /// 1. **Row missing.** A `merging` entry keeps waiting, because the confirmed-merge event
    ///    decides and a merged pull request leaves the inbox; only a failed or parked write for
    ///    it ends the wait (*merge refused*). Any other entry waits until `activeSince +
    ///    gracePeriod`, then is skipped as *disappeared*.
    /// 2. **A failed or parked write** for the pull request: skipped — *merge refused* while
    ///    merging, *update refused* while updating the branch, *write failed* otherwise.
    /// 3. **Branch updated.** A head that differs from the one the update started from becomes
    ///    the new pin, once, and evaluation continues in the same step. The same head as before
    ///    means GitHub has not created the merge commit yet (it answers the update with `202`):
    ///    wait, never queue a second update, and after `updateQueuedAt + gracePeriod` skip as
    ///    *update refused*.
    ///    **After a lower stack member merged** (an entry of the same stack, below this one when
    ///    the series started, is merged; or the row's stack position is lower than when the series
    ///    started, or the row left its stack — ADR 0042): a head that differs from the pin becomes the
    ///    new pin, once, because GitHub re-targets and rebases the pull requests above a merged
    ///    one itself. Not waited for: the head may also stay as it was.
    /// 4. **Updating branch or merging:** wait for the drain's confirmation.
    /// 5. **Head moved** off the pin: skipped.
    /// 6. **Draft**, then **conflicting**, then **changes requested**: skipped.
    /// 7. **Checks failed** or none at all: skipped. "None at all" on a head Shepherd's own
    ///    update produced waits instead, up to `updateQueuedAt + gracePeriod`: GitHub has often
    ///    not registered any check suite on a commit that is seconds old.
    /// 8. **A merge or branch update for it is still in the outbox:** wait. Never a second write
    ///    on top of one in flight, a branch update included.
    /// 9. **Behind its base** (`mergeStateStatus == .behind`): queue the branch update — even
    ///    while checks are still running. The update gives the pull request a new head whose
    ///    checks run anyway, so waiting for the old head's checks first would run CI twice.
    ///    **Never above the bottom of a stack** (the row's `stack.position > 1`, ADR 0042): GitHub
    ///    brings those up to date itself, so the entry waits instead, and after `gracePeriod` of
    ///    being behind is skipped as *update refused*.
    /// 10. **Checks running** or **mergeability unknown:** wait.
    /// 11. Otherwise: queue the merge.
    ///
    /// - Parameters:
    ///   - series: The series as stored.
    ///   - rows: The inbox rows the last sweep wrote, keyed by node id.
    ///   - existingOutbox: Node ids of pull requests the outbox still holds an unsent merge or
    ///     branch update for.
    ///   - failedWrites: Node ids of pull requests with a failed or parked merge or branch update.
    ///   - now: The sweep's time.
    ///   - gracePeriod: How long a missing row or an unanswered branch update is waited for.
    /// - Returns: The updated series and the one write to queue, if any.
    public static func step(
        series: MergeSeries,
        rows: [String: PullRequestSummary],
        existingOutbox: Set<String>,
        failedWrites: Set<String>,
        now: Date,
        gracePeriod: TimeInterval
    ) -> MergeSeriesStep {
        var series = series
        var skipped: [MergeSeriesEntry] = []
        while let index = series.activeIndex {
            var entry = series.entries[index]
            if entry.activeSince == nil { entry.activeSince = now }
            let verdict = evaluate(
                &entry,
                row: rows[entry.prID],
                lowerStackMemberMerged: hasMergedLowerStackMember(of: entry, in: series)
                    || wasRestacked(entry, row: rows[entry.prID]),
                existingOutbox: existingOutbox,
                failedWrites: failedWrites,
                now: now,
                gracePeriod: gracePeriod
            )
            switch verdict {
            case .skip(let reason):
                entry.state = .skipped(reason)
                series.entries[index] = entry
                skipped.append(entry)
                continue
            case .wait:
                series.entries[index] = entry
                return MergeSeriesStep(series: series, action: .none, newlySkipped: skipped)
            case .updateBranch:
                let pin = entry.pinnedHeadOid
                entry.state = .updatingBranch(from: pin)
                entry.updateQueuedAt = now
                series.entries[index] = entry
                return MergeSeriesStep(
                    series: series,
                    action: .updateBranch(entry: entry, expectedHeadOid: pin),
                    newlySkipped: skipped
                )
            case .merge:
                entry.state = .merging
                entry.mergeQueuedAt = now
                series.entries[index] = entry
                return MergeSeriesStep(
                    series: series,
                    action: .merge(entry: entry, expectedHeadOid: entry.pinnedHeadOid),
                    newlySkipped: skipped
                )
            }
        }
        return MergeSeriesStep(series: series, action: .none, newlySkipped: skipped)
    }

    // MARK: - One entry

    /// Whether an entry of the same stack, below this one when the series started, is merged
    /// (ADR 0042). That merge is what makes GitHub re-target and rebase this entry's branch, so it
    /// is the one head change the series expects without having caused it.
    private static func hasMergedLowerStackMember(of entry: MergeSeriesEntry, in series: MergeSeries) -> Bool {
        guard let number = entry.stackNumber, let position = entry.stackPosition else { return false }
        return series.entries.contains { other in
            other.prID != entry.prID
                && other.stackNumber == number
                && (other.stackPosition ?? .max) < position
                && other.state == .merged
        }
    }

    /// Whether the row shows that something below the entry in its stack merged since the series
    /// started, although no entry of the series did (ADR 0042): merged by hand on github.com, or
    /// by another series. The row's stack sits lower than the place recorded at Start, or the row
    /// is in no stack any more while the entry was in one — GitHub re-numbers or dissolves a
    /// stack once its lower pull requests merge. The stack *number* is not compared, because
    /// that re-numbering is exactly what happens.
    ///
    /// Never for an entry that was the bottom: nothing below it can have merged, and a bottom
    /// that left its stack (unstacked, or the ones above it closed) and was then pushed to is a
    /// push, which rule 5 skips.
    private static func wasRestacked(_ entry: MergeSeriesEntry, row: PullRequestSummary?) -> Bool {
        guard let row, let recorded = entry.stackPosition, recorded > 1 else { return false }
        guard let current = row.stack else { return true }
        return current.position < recorded
    }

    private enum Verdict {
        case skip(MergeSeriesSkipReason)
        case wait
        case updateBranch
        case merge
    }

    /// Waits from `anchor` — recording `now` there the first time it is asked — then skips once
    /// `gracePeriod` has elapsed since. Shared by every grace-period timer in `evaluate` whose
    /// anchor defaults to *now* when it is missing; the one timer that instead skips at once on a
    /// missing anchor (rule 7's "no checks yet") is not this shape and keeps its own logic.
    private static func waitThenSkip(
        anchor: inout Date?,
        now: Date,
        gracePeriod: TimeInterval,
        ifExpired reason: MergeSeriesSkipReason
    ) -> Verdict {
        let since = anchor ?? now
        anchor = since
        return now >= since.addingTimeInterval(gracePeriod) ? .skip(reason) : .wait
    }

    /// The rules of ``step(series:rows:existingOutbox:failedWrites:now:gracePeriod:)`` for the
    /// active entry. May change the entry in place (the re-pin, a missing timestamp); the state
    /// change a verdict implies is applied by the caller.
    private static func evaluate(
        _ entry: inout MergeSeriesEntry,
        row: PullRequestSummary?,
        lowerStackMemberMerged: Bool,
        existingOutbox: Set<String>,
        failedWrites: Set<String>,
        now: Date,
        gracePeriod: TimeInterval
    ) -> Verdict {
        let hasFailedWrite = failedWrites.contains(entry.prID)

        // 1. Row missing.
        guard let row else {
            if entry.state == .merging {
                // Not skipped: a merged pull request leaves the inbox, and the confirmation is
                // what decides. A refused merge, though, would otherwise wait forever.
                return hasFailedWrite ? .skip(.mergeRefused) : .wait
            }
            return waitThenSkip(
                anchor: &entry.activeSince,
                now: now,
                gracePeriod: gracePeriod,
                ifExpired: .disappeared
            )
        }

        // 2. A failed or parked write.
        if hasFailedWrite {
            switch entry.state {
            case .merging: return .skip(.mergeRefused)
            case .updatingBranch: return .skip(.updateRefused)
            case .pending, .branchUpdated, .merged, .skipped: return .skip(.writeFailed)
            }
        }

        // 3. Re-pin after Shepherd's own update, once.
        if case .branchUpdated(let from) = entry.state {
            guard row.headRefOid != from else {
                // GitHub creates the update's merge commit asynchronously; the row may still show
                // the old head (and still BEHIND) for a sweep or two. Never a second update.
                return waitThenSkip(
                    anchor: &entry.updateQueuedAt,
                    now: now,
                    gracePeriod: gracePeriod,
                    ifExpired: .updateRefused
                )
            }
            entry.pinnedHeadOid = row.headRefOid
            entry.state = .pending
        }

        // 3b. Re-pin after a lower member of the stack merged, once (ADR 0042). GitHub re-targets
        // and rebases the pull requests above a merged one itself, so a new head here is expected
        // — and it has to be taken without waiting for it: with a merge commit a re-target can
        // also leave the head as it was, and then there is nothing to wait for. Any head change
        // after this one is somebody's push, and rule 5 skips it.
        if entry.state == .pending, lowerStackMemberMerged, !entry.repinnedAfterStackMerge,
           row.headRefOid != entry.pinnedHeadOid {
            entry.pinnedHeadOid = row.headRefOid
            entry.repinnedAfterStackMerge = true
            // A head GitHub made seconds ago often has no check suites yet; the grace period that
            // rule 7 gives a head from Shepherd's own update applies to this one as well.
            entry.updateQueuedAt = now
        }

        // 4. Waiting for the drain.
        switch entry.state {
        case .updatingBranch, .merging: return .wait
        case .pending, .branchUpdated, .merged, .skipped: break
        }

        // 5–11, with merge-when-green's own decision pinned to the entry's head. Its order is
        // head → draft → conflicting → checks → mergeability → outbox; a series slots *changes
        // requested* in after conflicting and *behind* in once the checks are known not to have
        // failed — before "checks running", because an update restarts them anyway.
        let decision = MergeWhenGreenPolicy.decide(
            request: MergeWhenGreenRequest(
                prID: entry.prID,
                slug: entry.slug,
                title: entry.title,
                headRefOid: entry.pinnedHeadOid,
                mergeMethod: "",
                deletesHeadBranch: false,
                armedAt: now
            ),
            pullRequest: row,
            existingOutbox: existingOutbox
        )
        //
        // One switch, in that order. The three facts that outrank *changes requested* come first
        // and unguarded; the guarded arm then catches changes requested on whatever is left, and
        // the compiler still checks that every decision has an arm of its own.
        let behind = row.mergeStateStatus == .behind
        // A merge or update of this pull request already in the outbox: never a second write on
        // top of it. Checked here and not only through `.writeInFlight`, because merge-when-green
        // looks at the outbox last and answers `.checksPending` first.
        let inFlight = existingOutbox.contains(entry.prID)
        // Above the bottom of a stack, *Update branch* is never the series' write (ADR 0042): the
        // base is the branch of the pull request below, and GitHub brings the stack up to date
        // itself once that one merges. What would have been the update is a wait instead, bounded
        // by the grace period so a lone upper pull request cannot hold the series for ever. The
        // row's *current* position decides: once the ones below have merged it is the bottom,
        // its base is the trunk, and updating it is the series' job again.
        let mayUpdate = (row.stack?.position ?? 1) <= 1
        if !behind { entry.restackWaitSince = nil }
        func update() -> Verdict {
            if mayUpdate { return .updateBranch }
            return waitThenSkip(
                anchor: &entry.restackWaitSince,
                now: now,
                gracePeriod: gracePeriod,
                ifExpired: .updateRefused
            )
        }
        switch decision {
        case .abandon(.headMoved): return .skip(.headMoved)
        case .abandon(.draft): return .skip(.draft)
        case .abandon(.conflicting): return .skip(.conflicting)
        case _ where row.reviewDecision == .changesRequested: return .skip(.changesRequested)
        case .abandon(.checksFailed): return .skip(.checksFailed)
        case .abandon(.noChecks):
            // A head Shepherd's own update produced is seconds old when the sweep first sees it,
            // and GitHub often reports no check suites on it yet. That is "not started", not "no
            // checks": wait, up to the grace period after the update, before believing it.
            if let queuedAt = entry.updateQueuedAt, now < queuedAt.addingTimeInterval(gracePeriod) {
                return .wait
            }
            return .skip(.noChecks)
        case .wait(.writeInFlight):
            return .wait
        case .wait(.checksPending):
            // Behind and still building: update now. The old head's checks are about a commit
            // that will never be merged, and waiting for them only to start a second run on the
            // updated head would double the wait for every pull request in the series.
            return behind && !inFlight ? update() : .wait
        case .wait(.mergeabilityUnknown):
            // Green checks on the pinned head; GitHub has not worked out the merge yet.
            return behind && !inFlight ? update() : .wait
        case .merge:
            // Green checks, mergeability known, nothing of this pull request in the outbox.
            return behind ? update() : .merge
        }
    }
}
