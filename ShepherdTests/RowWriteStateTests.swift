import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The one chip a row and the review header show for what the outbox is doing (``RowWriteState``).
final class RowWriteStateTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    private func item(
        _ action: OutboxAction,
        state: OutboxState = .pending,
        prID: String = "PR_1"
    ) -> OutboxItem {
        var item = OutboxItem(prID: prID, repo: repo, number: 1, action: action)
        item.state = state
        return item
    }

    private let merge = OutboxAction.merge(method: "squash", expectedHeadOid: "abc")
    private let comment = OutboxAction.addPullRequestComment(body: "Looks good")

    private func state(
        _ items: [OutboxItem],
        isMerging: Bool = false,
        wasMerged: Bool = false,
        series: MergeSeriesChip? = nil
    ) -> RowWriteState? {
        RowWriteState.make(
            items: items,
            for: "PR_1",
            isMerging: isMerging,
            wasMerged: wasMerged,
            series: series
        )
    }

    // MARK: - Merge series (ADR 0041)

    private let seriesChip = MergeSeriesChip(position: 2, total: 5, phase: .merging)

    func testAFailedOrParkedWriteOutranksTheSeriesChip() {
        XCTAssertEqual(state([item(merge, state: .failed)], series: seriesChip), .failed(1))
        XCTAssertEqual(state([item(merge, state: .conflicted)], series: seriesChip), .parked(1))
    }

    func testTheSeriesChipOutranksAQueuedMergeAndAMergeInFlight() {
        XCTAssertEqual(state([item(merge)], series: seriesChip), .series(seriesChip))
        XCTAssertEqual(state([], isMerging: true, series: seriesChip), .series(seriesChip))
    }

    func testAMergeOnItsWayForAWaitingEntryStillBlocksASecondMerge() {
        // Merged by hand while the series had not got to it yet.
        let waiting = MergeSeriesChip(position: 3, total: 5, phase: .waiting)
        let queued = state([item(merge)], series: waiting)
        XCTAssertEqual(queued, .series(MergeSeriesChip(position: 3, total: 5, phase: .merging)))
        XCTAssertEqual(queued?.isMergeOnItsWay, true)
        XCTAssertEqual(state([], isMerging: true, series: waiting)?.isMergeOnItsWay, true)
        XCTAssertEqual(state([item(comment)], series: waiting), .series(waiting))
    }

    func testAConfirmedMergeFallsThroughToMerged() {
        XCTAssertEqual(state([], wasMerged: true, series: seriesChip), .merged)
    }

    func testOnlyASeriesMergeCountsAsAMergeOnItsWay() {
        XCTAssertTrue(RowWriteState.series(seriesChip).isMergeOnItsWay)
        let waiting = MergeSeriesChip(position: 2, total: 5, phase: .waiting)
        XCTAssertFalse(RowWriteState.series(waiting).isMergeOnItsWay)
    }

    func testTheSeriesChipNamesItsPlaceAndPhase() {
        XCTAssertEqual(seriesChip.text, String(localized: "Series 2/5 · merging"))
        let skipped = MergeSeriesChip(position: 3, total: 5, phase: .skipped(.checksFailed))
        XCTAssertEqual(
            skipped.text,
            String(localized: "Series 3/5 · skipped: \(MergeSeriesSkipReason.checksFailed.title)")
        )
    }

    func testTheChipReadsThePhaseOffTheEntryAndTheRow() {
        let row = PullRequestSummary(
            id: "A",
            repo: repo,
            number: 1,
            title: "A",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            isDraft: false,
            headRefName: "a",
            headRefOid: "head-A",
            baseRefName: "main",
            checkRollup: CheckRollup(state: .pending, total: 1, pendingCount: 1),
            myRelation: [.reviewRequested]
        )
        func entry(_ id: String, _ state: MergeSeriesEntryState) -> MergeSeriesEntry {
            MergeSeriesEntry(prID: id, slug: "schnaq/review#1", number: 1, title: id, pinnedHeadOid: "head-\(id)", state: state)
        }
        var series = MergeSeries(
            repository: repo,
            mergeMethod: "squash",
            deletesHeadBranch: false,
            createdAt: Date(timeIntervalSince1970: 0),
            entries: [entry("A", .pending), entry("B", .pending)]
        )
        XCTAssertEqual(MergeSeriesChip.make(series: series, prID: "A", row: row)?.phase, .waitingForChecks)
        XCTAssertEqual(MergeSeriesChip.make(series: series, prID: "B", row: nil)?.phase, .waiting)
        XCTAssertEqual(MergeSeriesChip.make(series: series, prID: "B", row: nil)?.position, 2)

        series.entries[0].state = .branchUpdated(from: "head-A")
        XCTAssertEqual(
            MergeSeriesChip.make(series: series, prID: "A", row: row)?.phase,
            .updatingBranch,
            "GitHub has not made the new commit yet"
        )
        series.entries[0].state = .merged
        XCTAssertNil(MergeSeriesChip.make(series: series, prID: "A", row: row))
    }

    func testNothingOnItsWayShowsNothing() {
        XCTAssertNil(state([]))
        XCTAssertNil(state([item(comment, prID: "PR_2")]), "another pull request's write is not this row's")
    }

    func testAMergeClickInFlightSaysMerging() {
        XCTAssertEqual(state([], isMerging: true), .merging)
    }

    func testAQueuedMergeSaysSoRatherThanSending() {
        XCTAssertEqual(state([item(merge), item(comment)]), .mergeQueued)
        XCTAssertEqual(state([item(merge, state: .sending)]), .mergeQueued)
    }

    func testOtherWritesAreCounted() {
        XCTAssertEqual(state([item(comment), item(comment, state: .sending)]), .queued(2))
    }

    func testMergedIsShownOnlyOnceTheDrainConfirmedIt() {
        XCTAssertEqual(state([item(merge)]), .mergeQueued, "a queued merge is not a merged one")
        XCTAssertEqual(state([], wasMerged: true), .merged)
    }

    func testAFailureOutranksEverything() {
        let items = [item(comment, state: .failed), item(merge, state: .conflicted), item(merge)]
        XCTAssertEqual(state(items, isMerging: true, wasMerged: true), .failed(1))
    }

    func testAParkedWriteOutranksAMergeInFlight() {
        XCTAssertEqual(state([item(merge, state: .conflicted)], isMerging: true), .parked(1))
    }

    func testTheChipSaysHowManyWhenThereIsMoreThanOne() {
        XCTAssertEqual(RowWriteState.failed(1).text, "Not sent")
        XCTAssertEqual(RowWriteState.failed(3).text, "3 not sent")
        XCTAssertEqual(RowWriteState.queued(2).text, "2 sending")
    }

    func testOnlyAMergeInFlightQueuedOrLandedBlocksAnotherMerge() {
        XCTAssertTrue(RowWriteState.merging.isMergeOnItsWay)
        XCTAssertTrue(RowWriteState.mergeQueued.isMergeOnItsWay)
        XCTAssertTrue(RowWriteState.merged.isMergeOnItsWay)
        XCTAssertFalse(RowWriteState.failed(1).isMergeOnItsWay, "a failed merge may be merged again")
        XCTAssertFalse(RowWriteState.parked(1).isMergeOnItsWay)
        XCTAssertFalse(RowWriteState.queued(2).isMergeOnItsWay)
    }
}
