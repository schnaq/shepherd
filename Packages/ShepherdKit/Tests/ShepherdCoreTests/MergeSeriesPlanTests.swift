import Foundation
import XCTest

@testable import ShepherdCore

/// Which ticked pull requests go into which series, in which order (ADR 0041).
final class MergeSeriesPlanTests: XCTestCase {
    private let other = RepoRef(owner: "schnaq", name: "shepherd")

    private func row(
        _ id: String,
        number: Int = 1,
        repo: RepoRef = Fixtures.repo,
        createdAt: TimeInterval = 0,
        isDraft: Bool = false,
        additions: Int = 10,
        deletions: Int = 0,
        reviewDecision: ReviewDecision? = nil,
        checkRollup: CheckRollup? = CheckRollup(state: .success, total: 1, successCount: 1),
        relations: Set<Relation> = [],
        mergeable: Mergeable? = .mergeable
    ) -> PullRequestSummary {
        Fixtures.summary(
            id: id,
            number: number,
            repo: repo,
            createdAt: createdAt,
            isDraft: isDraft,
            additions: additions,
            deletions: deletions,
            reviewDecision: reviewDecision,
            checkRollup: checkRollup,
            relations: relations,
            mergeable: mergeable
        )
    }

    func testTickedPullRequestsAreGroupedByRepositoryInOrderOfFirstAppearance() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            row("A", repo: other),
            row("B"),
            row("C", repo: other),
        ])
        XCTAssertEqual(plan.groups.map(\.repository), [other, Fixtures.repo])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id).sorted(), ["A", "C"])
        XCTAssertEqual(plan.groups[1].candidates.map(\.id), ["B"])
        XCTAssertTrue(plan.isActionable)
    }

    func testTheDefaultOrderIsFewestChangedLinesFirst() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            row("big", additions: 300, deletions: 20),
            row("small", additions: 1, deletions: 1),
            row("mid", additions: 20, deletions: 30),
        ])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["small", "mid", "big"])
    }

    func testDeletionsCountAsChangedLines() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            row("deletes", additions: 0, deletions: 50),
            row("adds", additions: 10, deletions: 0),
        ])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["adds", "deletes"])
    }

    func testEqualSizeFallsBackToTheOldestThenTheLowestNumber() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            row("newer", number: 1, createdAt: 100),
            row("older-high", number: 9, createdAt: 0),
            row("older-low", number: 3, createdAt: 0),
        ])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["older-low", "older-high", "newer"])
    }

    func testRunningChecksAreNotAReasonToLeaveAPullRequestOut() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            row("A", checkRollup: CheckRollup(state: .pending, total: 2, pendingCount: 2)),
        ])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["A"])
        XCTAssertEqual(plan.groups[0].excluded, [])
    }

    func testUnknownMergeabilityIsNotAReasonToLeaveAPullRequestOut() {
        let plan = MergeSeriesPlan.make(pullRequests: [row("A", mergeable: .unknown)])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["A"])
    }

    func testEachReasonThatCanNeverMergeIsNamed() {
        let plan = MergeSeriesPlan.make(
            pullRequests: [
                row("draft", isDraft: true),
                row("conflict", mergeable: .conflicting),
                row("failing", checkRollup: CheckRollup(state: .failure, total: 1, failureCount: 1)),
                row("changes", reviewDecision: .changesRequested),
                row("mine", relations: [.author]),
                row("queued"),
                row("fine"),
            ],
            mergesOnTheirWay: ["queued"]
        )
        let group = plan.groups[0]
        XCTAssertEqual(group.candidates.map(\.id), ["fine"])
        XCTAssertEqual(group.excluded.map(\.id), ["draft", "conflict", "failing", "changes", "mine", "queued"])
        XCTAssertEqual(
            group.excluded.map(\.reason),
            [.draft, .conflicting, .checksFailing, .changesRequested, .ownPullRequest, .mergeOnItsWay]
        )
    }

    func testAMergeOnItsWayIsTheReasonGivenBeforeAnyOther() {
        let plan = MergeSeriesPlan.make(
            pullRequests: [row("A", isDraft: true, mergeable: .conflicting)],
            mergesOnTheirWay: ["A"]
        )
        XCTAssertEqual(plan.groups[0].excluded.map(\.reason), [.mergeOnItsWay])
    }

    func testReasonsFollowBulkTriagesFixedOrder() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            row("A", isDraft: true, mergeable: .conflicting),
            row("B", reviewDecision: .changesRequested, checkRollup: CheckRollup(state: .failure, total: 1)),
            row("C", reviewDecision: .changesRequested, relations: [.author]),
        ])
        XCTAssertEqual(plan.groups[0].excluded.map(\.reason), [.draft, .checksFailing, .changesRequested])
    }

    func testReasonsSharedWithBulkTriageUseTheSameRawValues() {
        let shared: [MergeSeriesExclusionReason] = [.draft, .conflicting, .checksFailing, .changesRequested, .ownPullRequest]
        for reason in shared {
            XCTAssertNotNil(BulkTriageSkipReason(rawValue: reason.rawValue), reason.rawValue)
        }
    }

    func testARepositoryWithOnlyExcludedPullRequestsIsNotActionable() {
        let plan = MergeSeriesPlan.make(pullRequests: [row("A", isDraft: true)])
        XCTAssertFalse(plan.groups[0].isActionable)
        XCTAssertFalse(plan.isActionable)
    }

    func testAPullRequestTickedTwiceAppearsOnce() {
        let plan = MergeSeriesPlan.make(pullRequests: [row("A"), row("A")])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["A"])
    }

    func testNoTicksMakeAnEmptyPlan() {
        XCTAssertEqual(MergeSeriesPlan.make(pullRequests: []).groups, [])
    }
}
