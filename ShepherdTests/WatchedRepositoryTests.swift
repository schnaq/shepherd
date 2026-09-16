import Foundation
import GitHubKit
import ShepherdCore
import XCTest

@testable import Shepherd

/// Which rail a row from a watched repository lands in (ADR 0005's 2026-09-16 amendment).
///
/// The five default facets are all `@me` searches, so before this every row in the inbox was one
/// the user had *some* relation to and "Involved" could afford to be a plain `return true`. A
/// watched repository breaks that: its pull requests arrive with no relation to the user at all,
/// and the question of where they go is the whole feature. Getting it wrong in either direction
/// is silent — a strangers' pull request filed under "Involved" is noise of exactly the kind the
/// ignore list was built to remove, and a colleague's pull request filed under "Watched" because
/// it happens to be in a watched repository takes it out of the list the user actually reads.
///
/// So the rule is asserted on the relation set rather than on a repository lookup: the facet
/// query is what knows why a row is here (``ShepherdCore/Relation``), and the rail reads that.
@MainActor
final class WatchedRepositoryTests: XCTestCase {
    private func row(_ relations: Set<Relation>) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "unlock"),
            number: 831,
            title: "Rework the billing screen",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 0),
            additions: 12,
            deletions: 3,
            changedFiles: 1,
            headRefName: "billing",
            headRefOid: "0123456789abcdef0123",
            baseRefName: "main",
            myRelation: relations
        )
    }

    func testAStrangersPullRequestInAWatchedRepositoryIsWatchedAndNotInvolved() {
        let watched = row([.watched])
        XCTAssertTrue(SmartView.watched.matches(watched))
        XCTAssertFalse(SmartView.involved.matches(watched))
    }

    func testAPullRequestTheUserCommentedOnStaysInvolvedEvenInAWatchedRepository() {
        // Both facets returned it, so it carries both relations. Watching a repository says where
        // a row may come from; it never takes one out of the list the user actually reads.
        let both = row([.involved, .watched])
        XCTAssertTrue(SmartView.involved.matches(both))
        XCTAssertFalse(SmartView.watched.matches(both))
    }

    func testARowFromABuildWithoutTheInvolvedRelationStaysInvolved() {
        // Rows swept by an older build carry no relation at all until the next sweep rewrites
        // them. Two minutes of a pull request quietly missing from "Involved" would look like a
        // bug in the upgrade, so the rule is "not purely watched" rather than "carries involved".
        let legacy = row([])
        XCTAssertTrue(SmartView.involved.matches(legacy))
        XCTAssertFalse(SmartView.watched.matches(legacy))
    }

    func testAReviewRequestInAWatchedRepositoryStillNeedsMyReview() {
        let requested = row([.reviewRequested, .watched])
        XCTAssertTrue(SmartView.needsMyReview.matches(requested))
        XCTAssertFalse(SmartView.watched.matches(requested))
    }

    func testAWatchedRowNeverCountsAsTheUsersOwnWork() {
        // ADR 0018's gate: being able to see a pull request must never be enough to start an
        // agent on it or merge it unattended.
        XCTAssertFalse(AutoDelegationPolicy.isOwn(row([.watched])))
    }

    func testTheRailAndTheDeepLinkGrammarAgree() {
        XCTAssertEqual(InboxRailSelection(.watched).smartView, .watched)
        XCTAssertEqual(InboxDeepLinkFilter(token: "watched"), .watched)
        XCTAssertEqual(InboxDeepLinkFilter.watched.token, "watched")
    }
}
