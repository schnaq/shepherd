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
        wasMerged: Bool = false
    ) -> RowWriteState? {
        RowWriteState.make(items: items, for: "PR_1", isMerging: isMerging, wasMerged: wasMerged)
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
}
