import Foundation
import XCTest

@testable import ShepherdCore

/// The "merge when checks pass" decision, branch by branch (ADR 0037).
///
/// Exhaustive for the same reason `AutoMergePolicyTests` is: a decision that fires wrongly writes
/// to somebody's default branch. Every way out of the policy that is not a merge has a test that
/// reaches it *on its own*, with everything else satisfied.
final class MergeWhenGreenPolicyTests: XCTestCase {
    private let clock = Fixtures.date(0)

    // MARK: - Helpers

    private func request(
        prID: String = "PR_1",
        headRefOid: String = "abc123abc123def",
        mergeMethod: String = "squash",
        deletesHeadBranch: Bool = true
    ) -> MergeWhenGreenRequest {
        MergeWhenGreenRequest(
            prID: prID,
            slug: "schnaq/review#42",
            title: "Fix the thing",
            headRefOid: headRefOid,
            mergeMethod: mergeMethod,
            deletesHeadBranch: deletesHeadBranch,
            armedAt: clock
        )
    }

    /// The row the sweep writes once the checks have turned green on the armed head.
    private func green(
        id: String = "PR_1",
        headRefOid: String = "abc123abc123def",
        isDraft: Bool = false,
        checkRollup: CheckRollup? = CheckRollup(state: .success, total: 7, successCount: 7),
        mergeable: Mergeable? = .mergeable
    ) -> PullRequestSummary {
        Fixtures.summary(
            id: id,
            number: 42,
            isDraft: isDraft,
            headRefOid: headRefOid,
            checkRollup: checkRollup,
            mergeable: mergeable
        )
    }

    private func decide(
        _ pullRequest: PullRequestSummary,
        request armed: MergeWhenGreenRequest? = nil,
        existingOutbox: Set<String> = []
    ) -> MergeWhenGreenDecision {
        MergeWhenGreenPolicy.decide(
            request: armed ?? request(),
            pullRequest: pullRequest,
            existingOutbox: existingOutbox
        )
    }

    // MARK: - The merge

    func testGreenChecksOnTheArmedHeadMerge() {
        XCTAssertEqual(decide(green()), .merge(expectedHeadOid: "abc123abc123def"))
    }

    func testTheMergeIsPinnedToTheHeadTheUserSaw() {
        let decision = decide(green(headRefOid: "abc123abc123def"))
        XCTAssertEqual(decision.expectedHeadOid, "abc123abc123def")
    }

    // MARK: - Waiting

    func testRunningChecksWait() {
        let row = green(checkRollup: CheckRollup(state: .pending, total: 7, successCount: 3, pendingCount: 4))
        XCTAssertEqual(decide(row), .wait(.checksPending))
    }

    func testRunningChecksWaitEvenWhenOnlyTheStateIsKnown() {
        // `total` is 0 when the sweep knows the rollup's state but not its count. A running suite
        // with an unknown count is still running — not "no checks".
        let row = green(checkRollup: CheckRollup(state: .pending, total: 0))
        XCTAssertEqual(decide(row), .wait(.checksPending))
    }

    func testFailingChecksAbandonEvenWhenOnlyTheStateIsKnown() {
        let row = green(checkRollup: CheckRollup(state: .failure, total: 0))
        XCTAssertEqual(decide(row), .abandon(.checksFailed))
    }

    func testUnknownMergeabilityWaitsRatherThanAbandons() {
        XCTAssertEqual(decide(green(mergeable: .unknown)), .wait(.mergeabilityUnknown))
        XCTAssertEqual(decide(green(mergeable: nil)), .wait(.mergeabilityUnknown))
    }

    func testAWriteStillInTheOutboxWaits() {
        XCTAssertEqual(decide(green(), existingOutbox: ["PR_1"]), .wait(.writeInFlight))
    }

    func testAWriteForAnotherPullRequestDoesNotBlock() {
        XCTAssertEqual(decide(green(), existingOutbox: ["PR_2"]), .merge(expectedHeadOid: "abc123abc123def"))
    }

    // MARK: - Abandoning

    func testANewPushAbandonsTheArm() {
        XCTAssertEqual(decide(green(headRefOid: "fedcba")), .abandon(.headMoved))
    }

    func testANewPushWinsOverEveryOtherReason() {
        // The head is what the user looked at; once it moved nothing else about the row is
        // about the commit they decided on.
        let row = green(
            headRefOid: "fedcba",
            isDraft: true,
            checkRollup: CheckRollup(state: .failure, total: 7, failureCount: 1),
            mergeable: .conflicting
        )
        XCTAssertEqual(decide(row), .abandon(.headMoved))
    }

    func testFailingChecksAbandon() {
        let row = green(checkRollup: CheckRollup(state: .failure, total: 7, successCount: 6, failureCount: 1))
        XCTAssertEqual(decide(row), .abandon(.checksFailed))
    }

    func testAHeadWithNoChecksAbandonsBecauseThereIsNothingToWaitFor() {
        XCTAssertEqual(decide(green(checkRollup: nil)), .abandon(.noChecks))
        XCTAssertEqual(decide(green(checkRollup: CheckRollup(state: .none))), .abandon(.noChecks))
        XCTAssertEqual(
            decide(green(checkRollup: CheckRollup(state: .success, total: 0))),
            .abandon(.noChecks)
        )
    }

    func testADraftAbandons() {
        XCTAssertEqual(decide(green(isDraft: true)), .abandon(.draft))
    }

    func testConflictsAbandon() {
        XCTAssertEqual(decide(green(mergeable: .conflicting)), .abandon(.conflicting))
    }

    // MARK: - The list

    func testArmingReplacesAnEarlierArmForTheSamePullRequest() {
        let list = MergeWhenGreenList()
            .arming(request(headRefOid: "old"))
            .arming(request(headRefOid: "new"))
        XCTAssertEqual(list.entries.count, 1)
        XCTAssertEqual(list.request(forPullRequestID: "PR_1")?.headRefOid, "new")
    }

    func testDisarmingRemovesOnlyThatPullRequest() {
        let list = MergeWhenGreenList()
            .arming(request(prID: "PR_1"))
            .arming(request(prID: "PR_2"))
            .disarming(pullRequestID: "PR_1")
        XCTAssertNil(list.request(forPullRequestID: "PR_1"))
        XCTAssertNotNil(list.request(forPullRequestID: "PR_2"))
    }

    func testIsArmedIsAboutTheHeadNotJustThePullRequest() {
        let list = MergeWhenGreenList().arming(request(headRefOid: "abc"))
        XCTAssertTrue(list.isArmed(pullRequestID: "PR_1", headRefOid: "abc"))
        XCTAssertFalse(list.isArmed(pullRequestID: "PR_1", headRefOid: "def"))
        XCTAssertFalse(list.isArmed(pullRequestID: "PR_2", headRefOid: "abc"))
    }

    // MARK: - Persistence

    func testARequestRoundTripsThroughJSON() throws {
        let original = request()
        let data = try JSONEncoder().encode(MergeWhenGreenList().arming(original))
        let decoded = try JSONDecoder().decode(MergeWhenGreenList.self, from: data)
        XCTAssertEqual(decoded.entries, [original])
    }

    func testAnEntryFromAnotherBuildDecodesTolerantly() throws {
        // A key this build does not know is ignored; a key it expects but is missing costs that
        // key, not the list — and never the whole list.
        let json = """
        {"entries":[{"prID":"PR_9","headRefOid":"h","mergeMethod":"rebase","laterField":true}]}
        """
        let decoded = try JSONDecoder().decode(MergeWhenGreenList.self, from: Data(json.utf8))
        let entry = try XCTUnwrap(decoded.entries.first)
        XCTAssertEqual(entry.prID, "PR_9")
        XCTAssertEqual(entry.headRefOid, "h")
        XCTAssertEqual(entry.mergeMethod, "rebase")
        XCTAssertFalse(entry.deletesHeadBranch, "an unknown branch answer is the cautious one")
        XCTAssertEqual(entry.slug, "")
    }

    func testAnUnreadableListIsEmptyRatherThanFatal() throws {
        let decoded = try JSONDecoder().decode(
            MergeWhenGreenList.self,
            from: Data(#"{"entries":"nonsense"}"#.utf8)
        )
        XCTAssertEqual(decoded.entries, [])
    }
}
