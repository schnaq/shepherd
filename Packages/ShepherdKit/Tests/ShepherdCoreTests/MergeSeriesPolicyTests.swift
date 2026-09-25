import Foundation
import XCTest

@testable import ShepherdCore

/// The merge-series step, rule by rule (ADR 0041).
///
/// Exhaustive for the same reason `MergeWhenGreenPolicyTests` is: a step that fires wrongly
/// writes to somebody's default branch. Every rule has a test that reaches it on its own, with
/// everything else satisfied, and the ordering between rules is pinned where it matters.
final class MergeSeriesPolicyTests: XCTestCase {
    private let clock = Fixtures.date(0)
    private let grace: TimeInterval = 7 * 24 * 3_600

    // MARK: - Helpers

    private func entry(
        _ prID: String,
        head: String? = nil,
        state: MergeSeriesEntryState = .pending,
        activeSince: Date? = nil,
        updateQueuedAt: Date? = nil
    ) -> MergeSeriesEntry {
        MergeSeriesEntry(
            prID: prID,
            slug: "schnaq/review#\(prID)",
            number: 1,
            title: "Title \(prID)",
            pinnedHeadOid: head ?? "head-\(prID)",
            state: state,
            activeSince: activeSince,
            updateQueuedAt: updateQueuedAt
        )
    }

    private func series(_ entries: [MergeSeriesEntry]) -> MergeSeries {
        MergeSeries(
            id: "S1",
            repository: Fixtures.repo,
            mergeMethod: "squash",
            deletesHeadBranch: true,
            createdAt: clock,
            entries: entries
        )
    }

    /// A row that is green, mergeable and on the entry's default pin.
    private func green(
        _ prID: String,
        head: String? = nil,
        isDraft: Bool = false,
        reviewDecision: ReviewDecision? = nil,
        checkRollup: CheckRollup? = CheckRollup(state: .success, total: 3, successCount: 3),
        mergeable: Mergeable? = .mergeable,
        mergeStateStatus: MergeStateStatus? = .clean
    ) -> PullRequestSummary {
        var row = Fixtures.summary(
            id: prID,
            isDraft: isDraft,
            headRefOid: head ?? "head-\(prID)",
            reviewDecision: reviewDecision,
            checkRollup: checkRollup,
            mergeable: mergeable
        )
        row.mergeStateStatus = mergeStateStatus
        return row
    }

    private func step(
        _ series: MergeSeries,
        rows: [PullRequestSummary],
        existingOutbox: Set<String> = [],
        failedWrites: Set<String> = [],
        at now: Date? = nil
    ) -> MergeSeriesStep {
        MergeSeriesPolicy.step(
            series: series,
            rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }),
            existingOutbox: existingOutbox,
            failedWrites: failedWrites,
            now: now ?? clock,
            gracePeriod: grace
        )
    }

    private func state(_ step: MergeSeriesStep, _ prID: String) -> MergeSeriesEntryState? {
        step.series.entry(for: prID)?.state
    }

    // MARK: - The merge

    func testAGreenMergeableEntryOnItsPinQueuesTheMerge() {
        let result = step(series([entry("A")]), rows: [green("A")])
        XCTAssertEqual(result.action.expectedHeadOid, "head-A")
        guard case .merge(let entry, "head-A") = result.action else {
            return XCTFail("expected a merge, got \(result.action)")
        }
        XCTAssertEqual(entry.prID, "A")
        XCTAssertEqual(entry.state, .merging)
        XCTAssertEqual(state(result, "A"), .merging)
    }

    func testOnlyTheFirstUnfinishedEntryIsActedOn() {
        let result = step(series([entry("A"), entry("B")]), rows: [green("A"), green("B")])
        XCTAssertEqual(result.action.entry?.prID, "A")
        XCTAssertEqual(state(result, "B"), .pending)
    }

    func testTheNextEntryIsActedOnOnceTheOneBeforeIsMerged() {
        let result = step(
            series([entry("A", state: .merged), entry("B")]),
            rows: [green("B")]
        )
        XCTAssertEqual(result.action.entry?.prID, "B")
    }

    func testAMergingEntryWaitsForTheConfirmation() {
        let result = step(series([entry("A", state: .merging), entry("B")]), rows: [green("A"), green("B")])
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(state(result, "A"), .merging)
        XCTAssertEqual(state(result, "B"), .pending, "strict order: B waits for A's confirmation")
    }

    // MARK: - Waiting

    func testRunningChecksWait() {
        let row = green("A", checkRollup: CheckRollup(state: .pending, total: 3, successCount: 1, pendingCount: 2))
        let result = step(series([entry("A")]), rows: [row])
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(state(result, "A"), .pending)
    }

    func testUnknownMergeabilityWaits() {
        XCTAssertEqual(step(series([entry("A")]), rows: [green("A", mergeable: .unknown)]).action, .none)
        XCTAssertEqual(step(series([entry("A")]), rows: [green("A", mergeable: nil)]).action, .none)
    }

    func testAWriteStillInTheOutboxWaits() {
        let result = step(series([entry("A")]), rows: [green("A")], existingOutbox: ["A"])
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(state(result, "A"), .pending)
    }

    func testAWriteForAnotherPullRequestDoesNotBlock() {
        let result = step(series([entry("A")]), rows: [green("A")], existingOutbox: ["B"])
        XCTAssertEqual(result.action.entry?.prID, "A")
    }

    func testAWaitingEntryDoesNotLetTheNextOneAct() {
        let pending = green("A", checkRollup: CheckRollup(state: .pending, total: 1, pendingCount: 1))
        let result = step(series([entry("A"), entry("B")]), rows: [pending, green("B")])
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(state(result, "B"), .pending)
    }

    // MARK: - Behind its base

    func testABehindEntryWithGreenChecksQueuesABranchUpdatePinnedToItsHead() {
        let result = step(series([entry("A")]), rows: [green("A", mergeStateStatus: .behind)])
        guard case .updateBranch(let entry, "head-A") = result.action else {
            return XCTFail("expected an update, got \(result.action)")
        }
        XCTAssertEqual(entry.state, .updatingBranch(from: "head-A"))
        XCTAssertEqual(state(result, "A"), .updatingBranch(from: "head-A"))
        XCTAssertEqual(result.series.entry(for: "A")?.updateQueuedAt, clock)
    }

    func testABehindEntryWithRunningChecksIsUpdatedWithoutWaitingForThem() {
        // The update restarts the checks on a new head anyway; waiting for the old head's run
        // first would run CI twice for every entry that fell behind.
        let row = green(
            "A",
            checkRollup: CheckRollup(state: .pending, total: 1, pendingCount: 1),
            mergeStateStatus: .behind
        )
        let result = step(series([entry("A")]), rows: [row])
        guard case .updateBranch(_, "head-A") = result.action else {
            return XCTFail("expected an update, got \(result.action)")
        }
        XCTAssertEqual(state(result, "A"), .updatingBranch(from: "head-A"))
    }

    func testARunningEntryThatIsNotBehindStillWaitsForItsChecks() {
        let row = green(
            "A",
            checkRollup: CheckRollup(state: .pending, total: 1, pendingCount: 1),
            mergeStateStatus: .blocked
        )
        XCTAssertEqual(step(series([entry("A")]), rows: [row]).action, .none)
    }

    func testABehindEntryWithFailingChecksIsSkippedRatherThanUpdated() {
        let row = green(
            "A",
            checkRollup: CheckRollup(state: .failure, total: 1, failureCount: 1),
            mergeStateStatus: .behind
        )
        let result = step(series([entry("A")]), rows: [row])
        XCTAssertEqual(state(result, "A"), .skipped(.checksFailed))
        XCTAssertEqual(result.action, .none)
    }

    func testABehindEntryIsUpdatedEvenWhileMergeabilityIsUnknown() {
        let row = green("A", mergeable: .unknown, mergeStateStatus: .behind)
        XCTAssertEqual(step(series([entry("A")]), rows: [row]).action.entry?.prID, "A")
    }

    func testAnEntryUpdatingItsBranchWaitsEvenWhileTheRowStillSaysBehind() {
        let result = step(
            series([entry("A", state: .updatingBranch(from: "head-A"))]),
            rows: [green("A", mergeStateStatus: .behind)]
        )
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(state(result, "A"), .updatingBranch(from: "head-A"))
    }

    func testAnEntryUpdatingItsBranchWaitsWhenTheNewHeadArrivesBeforeTheConfirmation() {
        let result = step(
            series([entry("A", state: .updatingBranch(from: "head-A"))]),
            rows: [green("A", head: "new")]
        )
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(state(result, "A"), .updatingBranch(from: "head-A"))
    }

    func testAnEntryWithoutMergeStateStatusIsNeverUpdated() {
        let result = step(series([entry("A")]), rows: [green("A", mergeStateStatus: nil)])
        guard case .merge = result.action else { return XCTFail("expected a merge") }
    }

    // MARK: - Re-pinning

    func testAConfirmedUpdateRePinsToTheNewHeadAndMergesInTheSameStep() {
        let result = step(
            series([entry("A", state: .branchUpdated(from: "head-A"))]),
            rows: [green("A", head: "new")]
        )
        XCTAssertEqual(result.series.entry(for: "A")?.pinnedHeadOid, "new")
        guard case .merge(_, "new") = result.action else {
            return XCTFail("expected a merge on the new pin, got \(result.action)")
        }
    }

    func testARePinnedEntryWaitsForTheChecksOnItsNewHead() {
        let row = green("A", head: "new", checkRollup: CheckRollup(state: .pending, total: 1, pendingCount: 1))
        let result = step(series([entry("A", state: .branchUpdated(from: "head-A"))]), rows: [row])
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(state(result, "A"), .pending)
        XCTAssertEqual(result.series.entry(for: "A")?.pinnedHeadOid, "new")
    }

    func testRePinningHappensOnlyOnceSoASecondHeadChangeSkips() {
        let pending = green("A", head: "new", checkRollup: CheckRollup(state: .pending, total: 1, pendingCount: 1))
        let first = step(series([entry("A", state: .branchUpdated(from: "head-A"))]), rows: [pending])
        let second = step(first.series, rows: [green("A", head: "pushed-by-agent")])
        XCTAssertEqual(state(second, "A"), .skipped(.headMoved))
        XCTAssertEqual(second.action, .none)
    }

    func testAConfirmedUpdateWhoseHeadHasNotMovedYetWaitsWithoutASecondUpdate() {
        // GitHub answers the update with 202 and makes the commit asynchronously: the next sweep
        // may still show the old head, and still BEHIND.
        let result = step(
            series([entry("A", state: .branchUpdated(from: "head-A"), updateQueuedAt: clock)]),
            rows: [green("A", mergeStateStatus: .behind)],
            at: clock.addingTimeInterval(60)
        )
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(state(result, "A"), .branchUpdated(from: "head-A"))
        XCTAssertEqual(result.series.entry(for: "A")?.pinnedHeadOid, "head-A")
    }

    func testAConfirmedUpdateThatNeverProducesAHeadIsRefusedAfterTheGracePeriod() {
        let base = series([entry(
            "A",
            state: .branchUpdated(from: "head-A"),
            activeSince: clock.addingTimeInterval(-10 * grace),
            updateQueuedAt: clock
        )])
        let before = step(base, rows: [green("A")], at: clock.addingTimeInterval(grace - 1))
        XCTAssertEqual(state(before, "A"), .branchUpdated(from: "head-A"), "counted from the update, not activeSince")
        let after = step(base, rows: [green("A")], at: clock.addingTimeInterval(grace))
        XCTAssertEqual(state(after, "A"), .skipped(.updateRefused))
    }

    func testAConfirmedUpdateWithoutATimestampStartsItsGracePeriodNow() {
        let result = step(
            series([entry("A", state: .branchUpdated(from: "head-A"), activeSince: clock.addingTimeInterval(-10 * grace))]),
            rows: [green("A")]
        )
        XCTAssertEqual(state(result, "A"), .branchUpdated(from: "head-A"))
        XCTAssertEqual(result.series.entry(for: "A")?.updateQueuedAt, clock)
    }

    func testARePinnedEntryThatFallsBehindAgainGetsAFreshUpdate() {
        let result = step(
            series([entry("A", state: .branchUpdated(from: "head-A"))]),
            rows: [green("A", head: "new", mergeStateStatus: .behind)]
        )
        guard case .updateBranch(_, "new") = result.action else {
            return XCTFail("expected an update pinned to the new head, got \(result.action)")
        }
        XCTAssertEqual(state(result, "A"), .updatingBranch(from: "new"))
    }

    func testTheFullUpdateCycleEndsInAMergeOnTheUpdatedHead() {
        var current = series([entry("A")])
        // Sweep 1: behind → update.
        var result = step(current, rows: [green("A", mergeStateStatus: .behind)])
        guard case .updateBranch = result.action else { return XCTFail("expected an update") }
        current = result.series
        // The drain confirms.
        XCTAssertTrue(current.markBranchUpdated("A"))
        // Sweep 2: GitHub has not made the commit yet.
        result = step(current, rows: [green("A", mergeStateStatus: .behind)])
        XCTAssertEqual(result.action, .none)
        current = result.series
        // Sweep 3: new head, checks running.
        let running = green("A", head: "new", checkRollup: CheckRollup(state: .pending, total: 1, pendingCount: 1))
        result = step(current, rows: [running])
        XCTAssertEqual(result.action, .none)
        current = result.series
        // Sweep 4: green.
        result = step(current, rows: [green("A", head: "new")])
        guard case .merge(_, "new") = result.action else { return XCTFail("expected a merge") }
        current = result.series
        XCTAssertTrue(current.markMerged("A"))
        XCTAssertTrue(current.isFinished)
    }

    // MARK: - Skipping

    func testAHeadThatMovedWithoutAnUpdateSkips() {
        let result = step(series([entry("A")]), rows: [green("A", head: "pushed")])
        XCTAssertEqual(state(result, "A"), .skipped(.headMoved))
    }

    func testAMovedHeadWinsOverChangesRequested() {
        let result = step(
            series([entry("A")]),
            rows: [green("A", head: "pushed", reviewDecision: .changesRequested)]
        )
        XCTAssertEqual(state(result, "A"), .skipped(.headMoved))
    }

    func testADraftSkips() {
        XCTAssertEqual(state(step(series([entry("A")]), rows: [green("A", isDraft: true)]), "A"), .skipped(.draft))
    }

    func testConflictsSkip() {
        let result = step(series([entry("A")]), rows: [green("A", mergeable: .conflicting)])
        XCTAssertEqual(state(result, "A"), .skipped(.conflicting))
    }

    func testChangesRequestedSkips() {
        let result = step(series([entry("A")]), rows: [green("A", reviewDecision: .changesRequested)])
        XCTAssertEqual(state(result, "A"), .skipped(.changesRequested))
    }

    func testConflictsWinOverChangesRequestedAndChangesRequestedWinsOverFailingChecks() {
        let both = green("A", reviewDecision: .changesRequested, mergeable: .conflicting)
        XCTAssertEqual(state(step(series([entry("A")]), rows: [both]), "A"), .skipped(.conflicting))
        let failing = green(
            "A",
            reviewDecision: .changesRequested,
            checkRollup: CheckRollup(state: .failure, total: 1, failureCount: 1)
        )
        XCTAssertEqual(state(step(series([entry("A")]), rows: [failing]), "A"), .skipped(.changesRequested))
    }

    func testChangesRequestedSkipsEvenWhileChecksAreRunning() {
        let row = green(
            "A",
            reviewDecision: .changesRequested,
            checkRollup: CheckRollup(state: .pending, total: 1, pendingCount: 1)
        )
        XCTAssertEqual(state(step(series([entry("A")]), rows: [row]), "A"), .skipped(.changesRequested))
    }

    func testFailingChecksSkip() {
        let row = green("A", checkRollup: CheckRollup(state: .failure, total: 3, successCount: 2, failureCount: 1))
        XCTAssertEqual(state(step(series([entry("A")]), rows: [row]), "A"), .skipped(.checksFailed))
    }

    func testAHeadWithoutChecksSkips() {
        for rollup in [nil, CheckRollup(state: .none), CheckRollup(state: .success, total: 0)] {
            let result = step(series([entry("A")]), rows: [green("A", checkRollup: rollup)])
            XCTAssertEqual(state(result, "A"), .skipped(.noChecks), "rollup \(String(describing: rollup))")
        }
    }

    func testAFailedWriteForAPendingEntrySkipsIt() {
        let result = step(series([entry("A")]), rows: [green("A")], failedWrites: ["A"])
        XCTAssertEqual(state(result, "A"), .skipped(.writeFailed))
        XCTAssertEqual(result.action, .none)
    }

    func testAFailedWriteForAMergingEntryIsARefusedMerge() {
        let result = step(series([entry("A", state: .merging)]), rows: [green("A")], failedWrites: ["A"])
        XCTAssertEqual(state(result, "A"), .skipped(.mergeRefused))
    }

    func testAFailedWriteForAnEntryUpdatingItsBranchIsARefusedUpdate() {
        let result = step(
            series([entry("A", state: .updatingBranch(from: "head-A"))]),
            rows: [green("A")],
            failedWrites: ["A"]
        )
        XCTAssertEqual(state(result, "A"), .skipped(.updateRefused))
    }

    func testAFailedWriteWinsOverEveryRowReason() {
        let row = green("A", head: "pushed", isDraft: true, mergeable: .conflicting)
        let result = step(series([entry("A")]), rows: [row], failedWrites: ["A"])
        XCTAssertEqual(state(result, "A"), .skipped(.writeFailed))
    }

    func testAFailedWriteForAnotherPullRequestDoesNotSkip() {
        let result = step(series([entry("A")]), rows: [green("A")], failedWrites: ["B"])
        XCTAssertEqual(result.action.entry?.prID, "A")
    }

    // MARK: - Skip, then act on the next

    func testSkippedEntriesAreSkippedInOneStepAndTheNextOneActs() {
        let result = step(
            series([entry("A"), entry("B"), entry("C"), entry("D")]),
            rows: [green("A", isDraft: true), green("B", mergeable: .conflicting), green("C"), green("D")]
        )
        XCTAssertEqual(state(result, "A"), .skipped(.draft))
        XCTAssertEqual(state(result, "B"), .skipped(.conflicting))
        XCTAssertEqual(state(result, "C"), .merging)
        XCTAssertEqual(state(result, "D"), .pending, "at most one write per step")
        XCTAssertEqual(result.action.entry?.prID, "C")
        XCTAssertEqual(result.newlySkipped.map(\.prID), ["A", "B"])
        XCTAssertEqual(result.newlySkipped.map(\.state), [.skipped(.draft), .skipped(.conflicting)])
    }

    func testEveryEntryANewStepReachesGetsItsActiveSince() {
        let result = step(
            series([entry("A"), entry("B"), entry("C")]),
            rows: [green("A", isDraft: true), green("B"), green("C")],
            at: clock.addingTimeInterval(5)
        )
        XCTAssertEqual(result.series.entry(for: "A")?.activeSince, clock.addingTimeInterval(5))
        XCTAssertEqual(result.series.entry(for: "B")?.activeSince, clock.addingTimeInterval(5))
        XCTAssertNil(result.series.entry(for: "C")?.activeSince, "C has not been reached")
    }

    func testAnExistingActiveSinceIsKept() {
        let result = step(
            series([entry("A", activeSince: clock)]),
            rows: [green("A", checkRollup: CheckRollup(state: .pending, total: 1, pendingCount: 1))],
            at: clock.addingTimeInterval(100)
        )
        XCTAssertEqual(result.series.entry(for: "A")?.activeSince, clock)
    }

    func testASeriesWhoseEntriesAllSkipFinishesWithoutAWrite() {
        let result = step(
            series([entry("A"), entry("B")]),
            rows: [green("A", isDraft: true), green("B", head: "pushed")]
        )
        XCTAssertEqual(result.action, .none)
        XCTAssertTrue(result.series.isFinished)
        XCTAssertEqual(result.series.skippedCount, 2)
    }

    func testAStepOnAFinishedSeriesChangesNothing() {
        let finished = series([entry("A", state: .merged), entry("B", state: .skipped(.draft))])
        let result = step(finished, rows: [green("A"), green("B")])
        XCTAssertEqual(result.series, finished)
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.newlySkipped, [])
    }

    // MARK: - Missing rows

    func testAMissingRowWaitsWithinTheGracePeriod() {
        let result = step(
            series([entry("A", activeSince: clock)]),
            rows: [],
            at: clock.addingTimeInterval(grace - 1)
        )
        XCTAssertEqual(state(result, "A"), .pending)
        XCTAssertEqual(result.action, .none)
    }

    func testAMissingRowIsSkippedAsDisappearedAfterTheGracePeriodAndTheNextActs() {
        let result = step(
            series([entry("A", activeSince: clock), entry("B")]),
            rows: [green("B")],
            at: clock.addingTimeInterval(grace)
        )
        XCTAssertEqual(state(result, "A"), .skipped(.disappeared))
        XCTAssertEqual(result.action.entry?.prID, "B")
    }

    func testAMissingRowStartsItsGracePeriodWhenTheEntryBecomesActive() {
        let first = step(series([entry("A")]), rows: [])
        XCTAssertEqual(first.series.entry(for: "A")?.activeSince, clock)
        XCTAssertEqual(state(first, "A"), .pending)
    }

    func testAMissingRowOfAnEntryUpdatingItsBranchAlsoDisappearsAfterTheGracePeriod() {
        let result = step(
            series([entry("A", state: .updatingBranch(from: "head-A"), activeSince: clock)]),
            rows: [],
            at: clock.addingTimeInterval(grace)
        )
        XCTAssertEqual(state(result, "A"), .skipped(.disappeared))
    }

    func testAMergingEntryWhoseRowVanishedKeepsWaitingForTheConfirmation() {
        let result = step(
            series([entry("A", state: .merging, activeSince: clock), entry("B")]),
            rows: [green("B")],
            at: clock.addingTimeInterval(10 * grace)
        )
        XCTAssertEqual(state(result, "A"), .merging)
        XCTAssertEqual(result.action, .none)
    }

    func testAMergingEntryWhoseRowVanishedIsSkippedWhenItsMergeWasRefused() {
        let result = step(
            series([entry("A", state: .merging), entry("B")]),
            rows: [green("B")],
            failedWrites: ["A"]
        )
        XCTAssertEqual(state(result, "A"), .skipped(.mergeRefused))
        XCTAssertEqual(result.action.entry?.prID, "B")
    }

    // MARK: - Events

    func testMarkMergedFinishesTheEntryAndMovesTheSeriesOn() {
        var current = series([entry("A", state: .merging), entry("B")])
        XCTAssertTrue(current.markMerged("A"))
        XCTAssertEqual(current.activeEntry?.prID, "B")
        XCTAssertFalse(current.markMerged("A"), "a second confirmation changes nothing")
        XCTAssertFalse(current.markMerged("unknown"))
    }

    func testMarkMergedWinsOverASkip() {
        var current = series([entry("A", state: .skipped(.headMoved))])
        XCTAssertTrue(current.markMerged("A"))
        XCTAssertEqual(current.entry(for: "A")?.state, .merged)
    }

    func testMarkBranchUpdatedOnlyMovesAnEntryWaitingForItsUpdate() {
        var current = series([entry("A", state: .updatingBranch(from: "h")), entry("B")])
        XCTAssertTrue(current.markBranchUpdated("A"))
        XCTAssertEqual(current.entry(for: "A")?.state, .branchUpdated(from: "h"))
        XCTAssertFalse(current.markBranchUpdated("A"), "already confirmed")
        XCTAssertFalse(current.markBranchUpdated("B"), "never updated")
        XCTAssertEqual(current.entry(for: "B")?.state, .pending)
    }

    func testRemoveSkipsAPendingEntryAsRemovedByUser() {
        var current = series([entry("A"), entry("B")])
        XCTAssertTrue(current.remove("B"))
        XCTAssertEqual(current.entry(for: "B")?.state, .skipped(.removedByUser))
    }

    func testRemoveLeavesAMergingEntryBecauseAQueuedMergeCannotBeTakenBack() {
        var current = series([entry("A", state: .merging)])
        XCTAssertFalse(current.remove("A"))
        XCTAssertEqual(current.entry(for: "A")?.state, .merging)
    }

    func testRemoveLeavesFinishedEntriesAlone() {
        var current = series([entry("A", state: .merged), entry("B", state: .skipped(.draft))])
        XCTAssertFalse(current.remove("A"))
        XCTAssertFalse(current.remove("B"))
        XCTAssertEqual(current.entry(for: "B")?.state, .skipped(.draft))
    }

    func testRemovingTheActiveEntryLetsTheNextOneAct() {
        var current = series([entry("A"), entry("B")])
        current.remove("A")
        XCTAssertEqual(step(current, rows: [green("A"), green("B")]).action.entry?.prID, "B")
    }

    func testCancelRemovesEveryUnfinishedEntryExceptAQueuedMerge() {
        var current = series([
            entry("A", state: .merged),
            entry("B", state: .merging),
            entry("C", state: .updatingBranch(from: "h")),
            entry("D", state: .branchUpdated(from: "h")),
            entry("E"),
            entry("F", state: .skipped(.draft)),
        ])
        current.cancel()
        XCTAssertEqual(current.entries.map(\.state), [
            .merged,
            .merging,
            .skipped(.removedByUser),
            .skipped(.removedByUser),
            .skipped(.removedByUser),
            .skipped(.draft),
        ])
        XCTAssertEqual(current.activeEntry?.prID, "B")
    }
}
