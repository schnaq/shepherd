import Foundation
import XCTest

@testable import ShepherdCore

/// Which inbox rows make up a pull request's stack, and what is missing (ADR 0042).
final class PullRequestStackOverviewTests: XCTestCase {
    private let other = RepoRef(owner: "schnaq", name: "shepherd")

    private func member(
        _ id: String,
        number: Int,
        stack: Int = 7,
        position: Int,
        size: Int = 3,
        repo: RepoRef = Fixtures.repo
    ) -> PullRequestSummary {
        var row = Fixtures.summary(id: id, number: number, repo: repo)
        row.stack = PullRequestStack(number: stack, size: size, position: position, baseRefName: "main")
        return row
    }

    func testAPullRequestInNoStackHasNoOverview() {
        XCTAssertNil(PullRequestStackOverview.make(for: Fixtures.summary(id: "A"), in: []))
    }

    func testTheMembersAreTheSameRepositoryAndStackInPositionOrder() {
        let current = member("B", number: 11, position: 2)
        let rows = [
            member("C", number: 12, position: 3),
            current,
            member("A", number: 10, position: 1),
            member("elsewhere", number: 10, position: 1, repo: other),
            member("otherStack", number: 20, stack: 8, position: 1),
            Fixtures.summary(id: "loose", number: 30),
        ]
        let overview = PullRequestStackOverview.make(for: current, in: rows)
        XCTAssertEqual(overview?.members.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(overview?.currentID, "B")
        XCTAssertEqual(overview?.missingCount, 0)
        XCTAssertEqual(overview?.below.map(\.id), ["A"])
        XCTAssertEqual(overview?.knowsEveryPullRequestBelow, true)
    }

    func testTheShownPullRequestIsAMemberEvenWhenTheRowsDoNotHoldIt() {
        let current = member("B", number: 11, position: 2)
        let overview = PullRequestStackOverview.make(for: current, in: [member("A", number: 10, position: 1)])
        XCTAssertEqual(overview?.members.map(\.id), ["A", "B"])
        XCTAssertEqual(overview?.missingCount, 1)
    }

    func testPositionsTheInboxDoesNotHoldAreCountedAsMissing() {
        let current = member("C", number: 12, position: 3, size: 4)
        let overview = PullRequestStackOverview.make(for: current, in: [current, member("A", number: 10, position: 1, size: 4)])
        XCTAssertEqual(overview?.members.map(\.id), ["A", "C"])
        XCTAssertEqual(overview?.missingCount, 2)
        XCTAssertEqual(overview?.below.map(\.id), ["A"])
        XCTAssertEqual(overview?.belowCount, 2)
        XCTAssertEqual(overview?.knowsEveryPullRequestBelow, false)
    }

    func testTwoRowsClaimingOnePositionCountOnce() {
        let current = member("A", number: 10, position: 1)
        let overview = PullRequestStackOverview.make(for: current, in: [
            current,
            member("B", number: 11, position: 2),
            member("B2", number: 13, position: 2),
        ])
        XCTAssertEqual(overview?.members.map(\.id), ["A", "B"])
        XCTAssertEqual(overview?.missingCount, 1)
    }

    func testTheBottomOfAStackHasNothingBelowIt() {
        let current = member("A", number: 10, position: 1)
        let overview = PullRequestStackOverview.make(for: current, in: [current])
        XCTAssertEqual(overview?.below, [])
        XCTAssertEqual(overview?.belowCount, 0)
        XCTAssertEqual(overview?.knowsEveryPullRequestBelow, true)
    }

    func testTheMissingCountIsNeverNegative() {
        let current = member("A", number: 10, position: 1, size: 1)
        let overview = PullRequestStackOverview.make(for: current, in: [current, member("B", number: 11, position: 2)])
        XCTAssertEqual(overview?.missingCount, 0)
    }
}
