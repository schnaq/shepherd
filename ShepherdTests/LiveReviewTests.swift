import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// What an open review screen does with the pull request the database keeps handing it: the
/// silent path, the banner, the ending, and the number the banner is allowed to say.
///
/// Asserted through `ReviewModel`'s pure `static` forms rather than through an instance, for the
/// reason `SinceReviewTests` and `PullRequestQueueStatusTests` both give: `ReviewModel` is built
/// from a `SignedInSession`, which wants the Keychain and the real database file, so standing one
/// up here would test the wiring of a test rather than the decision. The decisions are exactly
/// these three functions; the model's own methods are their application to whatever the two
/// observations last handed over, and `ObservationTests` on the Linux runner drives the
/// observation itself.
///
/// `@MainActor` because `ReviewModel` is: a `static` member of a main-actor class is main-actor
/// isolated too, and reaching it from a nonisolated test is not allowed under Swift 6.
@MainActor
final class LiveReviewTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let moment = Date(timeIntervalSince1970: 1_788_162_000)

    private func summary(
        headRefOid: String,
        checkRollup: CheckRollup? = nil,
        mergeable: Mergeable? = .mergeable,
        reviewDecision: ReviewDecision? = nil
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: repo,
            number: 182,
            title: "Fix the parser",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: moment,
            createdAt: moment.addingTimeInterval(-3_600),
            headRefName: "fix-the-parser",
            headRefOid: headRefOid,
            baseRefName: "main",
            reviewDecision: reviewDecision,
            checkRollup: checkRollup,
            mergeable: mergeable
        )
    }

    private func commit(_ oid: String, at offset: TimeInterval) -> CommitInfo {
        CommitInfo(
            oid: oid,
            messageHeadline: "Work on \(oid)",
            committedDate: moment.addingTimeInterval(offset)
        )
    }

    private func detail(
        headRefOid: String,
        commits: [CommitInfo],
        checkRollup: CheckRollup? = nil,
        mergeable: Mergeable? = .mergeable,
        reviewDecision: ReviewDecision? = nil,
        checks: [CheckRun] = []
    ) -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(
                headRefOid: headRefOid,
                checkRollup: checkRollup,
                mergeable: mergeable,
                reviewDecision: reviewDecision
            ),
            commits: commits,
            files: [
                ChangedFile(
                    path: "a.swift",
                    status: .modified,
                    additions: 1,
                    deletions: 1,
                    patch: "@@ -1,2 +1,2 @@\n-let a = 1\n+let a = 2\n"
                )
            ],
            checks: checks
        )
    }

    private func outcome(merged: Bool) -> PullRequestOutcome {
        PullRequestOutcome(
            prID: "PR_1",
            repo: repo,
            authorLogin: "octocat",
            openedAt: moment.addingTimeInterval(-3_600),
            closedAt: moment,
            merged: merged,
            reviewRounds: 1,
            changedLines: 2,
            source: .sync
        )
    }

    // MARK: - The same head is applied silently

    func testANewCheckStateOnTheSameHeadIsRefreshedInPlace() {
        let shown = detail(
            headRefOid: "head-1",
            commits: [commit("c1", at: 0)],
            checkRollup: CheckRollup(state: .pending, total: 3, pendingCount: 3),
            mergeable: .unknown
        )
        let fresh = detail(
            headRefOid: "head-1",
            commits: [commit("c1", at: 0)],
            checkRollup: CheckRollup(state: .success, total: 3, successCount: 3),
            mergeable: .mergeable,
            reviewDecision: .approved
        )
        // `.refresh` is the answer that leaves the reviewer's cursor alone: the selected file, the
        // selected diff row, the tab, the round view and the composer's text are none of them
        // derived from anything that moved here, and `ReviewModel.refresh(_:)` touches none of
        // them. Only `.newCommits` replaces the document under a cursor, and only after a click.
        XCTAssertEqual(ReviewModel.change(shown: shown, fresh: fresh), .refresh)
    }

    func testADetailIdenticalToTheOneOnScreenIsNotAnUpdate() {
        // The reviewer's own submitted review makes the sweep write a fresh detail on the same
        // head, and a screen that treated every write as news would announce the user's own work
        // back at them.
        let shown = detail(headRefOid: "head-1", commits: [commit("c1", at: 0)])
        XCTAssertEqual(ReviewModel.change(shown: shown, fresh: shown), .unchanged)
    }

    // MARK: - The cached read never overtakes the observation

    func testTheCachedDetailIsAppliedOnlyToAnEmptyScreen() {
        // `load()` starts the observation first and then reads the cache, so a sweep that wrote
        // between the two has already delivered the newer row. The cached read is then the older
        // copy, and applying it would put the earlier checks and threads back on screen and clear
        // the banner with them.
        XCTAssertTrue(ReviewModel.shouldApplyCached(shown: nil))
        XCTAssertFalse(
            ReviewModel.shouldApplyCached(
                shown: detail(headRefOid: "head-1", commits: [commit("c1", at: 0)])
            ),
            "the observation got there first, and it is the fresher of the two"
        )
    }

    // MARK: - A moved head is held back

    func testAPushIsHeldBackWithTheNumberOfNewCommits() {
        let shown = detail(headRefOid: "head-1", commits: [commit("c1", at: 0)])
        let pushed = detail(
            headRefOid: "head-3",
            commits: [commit("c1", at: 0), commit("c2", at: 60), commit("c3", at: 120)]
        )
        XCTAssertEqual(
            ReviewModel.change(shown: shown, fresh: pushed),
            .newCommits(count: 2),
            "the diff must not be swapped under a review anchored on the old head"
        )
    }

    func testAPushWhoseCommitsAreUnknownIsHeldBackWithoutANumber() {
        // A detail fetch that learned nothing about the commits would make every commit on the
        // branch look new, so the banner says "new commits" and no number at all.
        let shown = detail(headRefOid: "head-1", commits: [commit("c1", at: 0)])
        let pushed = detail(headRefOid: "head-2", commits: [])
        XCTAssertEqual(ReviewModel.change(shown: shown, fresh: pushed), .newCommits(count: nil))
    }

    func testAForcePushCountsTheWholeBranchAsNew() {
        // A rebase replaces every commit, so every one of them is a commit this reviewer has not
        // seen. Saying "2 new commits" is the honest reading of that, not an over-count.
        let shown = detail(
            headRefOid: "head-1",
            commits: [commit("c1", at: 0), commit("c2", at: 60)]
        )
        let rebased = detail(
            headRefOid: "head-2",
            commits: [commit("d1", at: 0), commit("d2", at: 60)]
        )
        XCTAssertEqual(ReviewModel.change(shown: shown, fresh: rebased), .newCommits(count: 2))
    }

    func testACommitCountNeedsBothListsAndAtLeastOneNewCommit() {
        let old = [commit("c1", at: 0)]
        let new = [commit("c1", at: 0), commit("c2", at: 60)]
        XCTAssertEqual(ReviewModel.newCommitCount(shown: old, fresh: new), 1)
        XCTAssertNil(ReviewModel.newCommitCount(shown: [], fresh: new))
        XCTAssertNil(ReviewModel.newCommitCount(shown: old, fresh: []))
        XCTAssertNil(
            ReviewModel.newCommitCount(shown: new, fresh: old),
            "a head that only dropped commits has no new one to count"
        )
    }

    // MARK: - Merged and closed

    func testAMergedPullRequestThatLeftTheInboxSaysSo() {
        let notice = ReviewModel.endNotice(hasLeftTheInbox: true, outcome: outcome(merged: true))
        XCTAssertEqual(notice, .merged)
        XCTAssertTrue(notice?.endsTheReview == true, "no verdict can land on it any more")
        XCTAssertFalse(notice?.offersReload == true, "there is nothing left to reload into")
    }

    func testAClosedPullRequestThatLeftTheInboxSaysSo() {
        let notice = ReviewModel.endNotice(hasLeftTheInbox: true, outcome: outcome(merged: false))
        XCTAssertEqual(notice, .closed)
        XCTAssertTrue(notice?.endsTheReview == true)
    }

    func testAStoredOutcomeAloneIsNotAnEnding() {
        // An outcome row is never deleted, so a pull request that closed and was reopened still
        // has one; it describes the previous ending, not this one.
        XCTAssertNil(ReviewModel.endNotice(hasLeftTheInbox: false, outcome: outcome(merged: true)))
    }

    func testAVanishedRowAloneIsNotAnEndingEither() {
        // A pull request also leaves the inbox when the user's search facets stop matching it,
        // and that one is still open and still reviewable.
        XCTAssertNil(ReviewModel.endNotice(hasLeftTheInbox: true, outcome: nil))
    }

    func testOnlyAPushOffersAReload() {
        XCTAssertTrue(ReviewModel.Notice.newCommits(count: 2).offersReload)
        XCTAssertFalse(ReviewModel.Notice.newCommits(count: nil).endsTheReview)
        XCTAssertFalse(ReviewModel.Notice.merged.offersReload)
        XCTAssertFalse(ReviewModel.Notice.closed.offersReload)
    }
}
