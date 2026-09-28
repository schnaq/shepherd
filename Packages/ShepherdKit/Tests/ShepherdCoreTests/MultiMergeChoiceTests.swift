import Foundation
import XCTest

@testable import ShepherdCore

/// What the inbox's *Merge* button does with the ticked rows.
///
/// Each case is here because the choice decides which merges get queued: a stack read too
/// generously would merge a pull request nobody ticked, and one read too strictly only costs the
/// user the series sheet instead of the one-click stack merge.
final class MultiMergeChoiceTests: XCTestCase {
    private let other = RepoRef(owner: "schnaq", name: "shepherd")

    private func member(
        _ id: String,
        stack: Int = 7,
        position: Int,
        size: Int = 3,
        repo: RepoRef = Fixtures.repo
    ) -> PullRequestSummary {
        var row = Fixtures.summary(id: id, number: 10 + position, repo: repo)
        row.stack = PullRequestStack(number: stack, size: size, position: position, baseRefName: "main")
        return row
    }

    func testNothingTickedIsTheSelectedRowsMerge() {
        XCTAssertEqual(MultiMergeChoice.make(marked: []), .single)
    }

    func testOneTickedRowIsStillASingleMerge() {
        XCTAssertEqual(MultiMergeChoice.make(marked: [member("A", position: 2)]), .single)
    }

    func testTheBottomOfAStackTickedUpwardsIsAStackMergeOfItsTop() {
        let top = member("B", position: 2)
        let choice = MultiMergeChoice.make(marked: [top, member("A", position: 1)])
        XCTAssertEqual(choice, .stack(top: top, count: 2))
    }

    func testAWholeStackTickedInAnyOrderIsAStackMerge() {
        let top = member("C", position: 3)
        let choice = MultiMergeChoice.make(marked: [member("B", position: 2), top, member("A", position: 1)])
        XCTAssertEqual(choice, .stack(top: top, count: 3))
    }

    func testAGapInThePositionsIsSeveralMerges() {
        // Merging position 3 would take position 2 along, which nobody ticked.
        let choice = MultiMergeChoice.make(marked: [member("A", position: 1), member("C", position: 3)])
        XCTAssertEqual(choice, .several(count: 2))
    }

    func testAStackSliceThatDoesNotStartAtTheBottomIsSeveralMerges() {
        // Merging position 3 would take position 1 along, which nobody ticked.
        let choice = MultiMergeChoice.make(marked: [member("B", position: 2), member("C", position: 3)])
        XCTAssertEqual(choice, .several(count: 2))
    }

    func testTwoRowsClaimingTheSamePositionAreSeveralMerges() {
        let choice = MultiMergeChoice.make(marked: [member("A", position: 1), member("A2", position: 1)])
        XCTAssertEqual(choice, .several(count: 2))
    }

    func testTheSameStackNumberInAnotherRepositoryIsNotTheSameStack() {
        let choice = MultiMergeChoice.make(marked: [member("A", position: 1), member("B", position: 2, repo: other)])
        XCTAssertEqual(choice, .several(count: 2))
    }

    func testTwoStacksOfOneRepositoryAreSeveralMerges() {
        let choice = MultiMergeChoice.make(marked: [member("A", position: 1), member("B", stack: 8, position: 2)])
        XCTAssertEqual(choice, .several(count: 2))
    }

    func testAStackMixedWithALoosePullRequestIsSeveralMerges() {
        let choice = MultiMergeChoice.make(marked: [
            member("A", position: 1),
            member("B", position: 2),
            Fixtures.summary(id: "loose", number: 30),
        ])
        XCTAssertEqual(choice, .several(count: 3))
    }

    func testPullRequestsInNoStackAreSeveralMerges() {
        let choice = MultiMergeChoice.make(marked: [
            Fixtures.summary(id: "one", number: 1),
            Fixtures.summary(id: "two", number: 2),
        ])
        XCTAssertEqual(choice, .several(count: 2))
    }

    func testOnlyTheMultiChoicesTakeTheTickedRows() {
        XCTAssertFalse(MultiMergeChoice.single.isMulti)
        XCTAssertTrue(MultiMergeChoice.several(count: 2).isMulti)
        XCTAssertTrue(MultiMergeChoice.stack(top: member("B", position: 2), count: 2).isMulti)
    }
}
