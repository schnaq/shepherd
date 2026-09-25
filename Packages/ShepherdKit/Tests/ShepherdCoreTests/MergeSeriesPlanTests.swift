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

    // MARK: - Stacks (ADR 0042)

    private func stacked(
        _ id: String,
        stack: Int = 7,
        position: Int,
        size: Int = 3,
        additions: Int,
        isDraft: Bool = false
    ) -> PullRequestSummary {
        var summary = row(id, isDraft: isDraft, additions: additions)
        summary.stack = PullRequestStack(number: stack, size: size, position: position, baseRefName: "main")
        return summary
    }

    func testMembersOfOneStackMergeBottomFirstEvenWhenTheBottomIsTheBiggest() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            stacked("pos2", position: 2, additions: 1),
            stacked("pos1", position: 1, additions: 100),
            row("other", additions: 50),
        ])
        // Size order alone is pos2, other, pos1; the stack's two slots are refilled bottom first,
        // and the unrelated pull request keeps its place between them.
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["pos1", "other", "pos2"])
    }

    func testAWholeStackTickedInAnyOrderComesOutBottomToTop() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            stacked("top", position: 3, additions: 1),
            stacked("bottom", position: 1, additions: 3),
            stacked("middle", position: 2, additions: 2),
        ])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["bottom", "middle", "top"])
    }

    func testTwoStacksOfOneRepositoryAreOrderedEachOnItsOwn() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            stacked("a2", stack: 1, position: 2, additions: 1),
            stacked("b2", stack: 2, position: 2, additions: 2),
            stacked("a1", stack: 1, position: 1, additions: 3),
            stacked("b1", stack: 2, position: 1, additions: 4),
        ])
        // Size order: a2, b2, a1, b1. Stack 1 holds slots 0 and 2, stack 2 slots 1 and 3.
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["a1", "b1", "a2", "b2"])
    }

    func testPullRequestsOutsideAnyStackKeepTheSizeOrder() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            row("big", additions: 300),
            stacked("only", position: 2, additions: 100),
            row("small", additions: 1),
        ])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["small", "only", "big"])
    }

    func testAnExcludedStackMemberExcludesEveryMemberAboveItBecauseMergingOneWouldMergeIt() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            stacked("pos3", position: 3, additions: 2),
            stacked("pos1", position: 1, additions: 1, isDraft: true),
            stacked("pos2", position: 2, additions: 5),
            stacked("other", stack: 8, position: 2, additions: 1),
            row("loose", additions: 1),
        ])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["other", "loose"])
        // In tick order, each with its own reason.
        XCTAssertEqual(plan.groups[0].excluded.map(\.id), ["pos3", "pos1", "pos2"])
        XCTAssertEqual(
            plan.groups[0].excluded.map(\.reason),
            [.belowInStackExcluded, .draft, .belowInStackExcluded]
        )
    }

    func testAnExcludedUpperStackMemberLeavesTheOnesBelowItInTheSeries() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            stacked("pos3", position: 3, additions: 2, isDraft: true),
            stacked("pos1", position: 1, additions: 1),
            stacked("pos2", position: 2, additions: 5),
        ])
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), ["pos1", "pos2"])
        XCTAssertEqual(plan.groups[0].excluded.map(\.reason), [.draft])
    }

    func testAStackMemberAboveAnExcludedOneKeepsItsOwnReason() {
        let plan = MergeSeriesPlan.make(pullRequests: [
            stacked("pos1", position: 1, additions: 1, isDraft: true),
            stacked("pos2", position: 2, additions: 5, isDraft: true),
        ])
        XCTAssertEqual(plan.groups[0].excluded.map(\.reason), [.draft, .draft])
    }

    func testReorderingKeepsEachStackBottomFirstWithinTheSlotsItOccupies() {
        // The order a user dragged: the top of the stack first, an unrelated pull request between.
        let reordered = MergeSeriesPlan.stacksBottomFirst([
            stacked("top", position: 2, additions: 1),
            row("loose", additions: 1),
            stacked("bottom", position: 1, additions: 1),
        ])
        XCTAssertEqual(reordered.map(\.id), ["bottom", "loose", "top"])
    }

    func testNoTicksMakeAnEmptyPlan() {
        XCTAssertEqual(MergeSeriesPlan.make(pullRequests: []).groups, [])
    }
}
