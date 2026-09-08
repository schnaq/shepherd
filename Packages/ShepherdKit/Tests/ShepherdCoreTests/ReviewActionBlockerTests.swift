import Foundation
import XCTest

@testable import ShepherdCore

/// The three refusals GitHub answers a review write with, decided in one place.
///
/// These predicates are the reason the app can grey a button out *before* the write instead of
/// letting the outbox carry a row GitHub will reject — a failed "Pull Request is still a draft"
/// merge sitting in the queue is the bug they were extracted for. ``BulkTriagePlan`` partitions
/// on the same two properties, so a rule that drifted here would let bulk triage and the single
/// write disagree about the same pull request.
final class ReviewActionBlockerTests: XCTestCase {
    // MARK: - Merging

    func testDraftBlocksTheMergeButNotAVerdict() {
        let pullRequest = Fixtures.summary(id: "PR_draft", isDraft: true)

        XCTAssertEqual(pullRequest.mergeBlocker, .draft)
        XCTAssertNil(pullRequest.verdictBlocker)
    }

    func testConflictingNonDraftBlocksTheMerge() {
        let pullRequest = Fixtures.summary(id: "PR_conflict", mergeable: .conflicting)

        XCTAssertEqual(pullRequest.mergeBlocker, .conflicting)
        XCTAssertNil(pullRequest.verdictBlocker)
    }

    func testDraftWinsOverConflicts() {
        let pullRequest = Fixtures.summary(
            id: "PR_draft_conflict",
            isDraft: true,
            mergeable: .conflicting
        )

        // A fixed order, so the sentence the user reads never depends on evaluation order —
        // the same guarantee ``BulkTriagePlan/skipReason(for:action:steps:)`` makes.
        XCTAssertEqual(pullRequest.mergeBlocker, .draft)
    }

    func testMergeableNonDraftFromSomebodyElseBlocksNothing() {
        let pullRequest = Fixtures.summary(id: "PR_green", relations: [.reviewRequested])

        XCTAssertNil(pullRequest.mergeBlocker)
        XCTAssertNil(pullRequest.verdictBlocker)
    }

    func testUnknownMergeabilityIsNotABlocker() {
        // GitHub has simply not computed it yet; the merge sheet warns, but the button stays
        // live because refusing here would block every freshly pushed pull request.
        let pullRequest = Fixtures.summary(id: "PR_unknown", mergeable: .unknown)

        XCTAssertNil(pullRequest.mergeBlocker)
    }

    // MARK: - Verdicts

    func testOwnPullRequestBlocksTheVerdictButNotTheMerge() {
        let pullRequest = Fixtures.summary(id: "PR_mine", relations: [.author])

        XCTAssertEqual(pullRequest.verdictBlocker, .ownPullRequest)
        // Merging your own pull request is ordinary; only approving it is a 422.
        XCTAssertNil(pullRequest.mergeBlocker)
    }

    func testAuthorshipAlongsideAnotherRelationStillBlocksTheVerdict() {
        let pullRequest = Fixtures.summary(id: "PR_mine_2", relations: [.author, .assigned])

        XCTAssertEqual(pullRequest.verdictBlocker, .ownPullRequest)
    }

    func testAnOwnDraftBlocksBothIndependently() {
        let pullRequest = Fixtures.summary(id: "PR_mine_draft", isDraft: true, relations: [.author])

        XCTAssertEqual(pullRequest.mergeBlocker, .draft)
        XCTAssertEqual(pullRequest.verdictBlocker, .ownPullRequest)
    }
}
