import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The rule the single write funnel turns on, and the sentence it says when it turns.
///
/// Live testing found the outbox holding a failed write reading "Merge — Pull Request is still a
/// draft" and an approve GitHub answered 422 to, so ``PullRequestActions`` now refuses both
/// before it writes anything. That refusal happens *before* ``ShepherdCore/ReviewDraft`` is
/// saved, which makes its answer load-bearing well beyond the toast: it is the only thing telling
/// ``ReviewModel/submit(verdict:actions:)`` that the summary the reviewer typed is still nowhere
/// on disk and must stay in the field.
///
/// Asserted through ``PullRequestActions/refusal(of:on:)`` and
/// ``PullRequestActions/blockerMessage(_:slug:)`` rather than by calling `submitReview` itself:
/// that needs a ``SignedInSession``, which wants the Keychain and the real database file, and the
/// decision and the wording are the whole of what this path contributes. Expectations go through
/// `String(localized:)` for the reason ``WriteOutcomeToastTests`` states — a German runner picks a
/// different lookup table, and a test spelled in English would fail there for no reason.
@MainActor
final class ReviewRefusalTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    private func summary(relations: Set<Relation>) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: repo,
            number: 87,
            title: "Fix the off-by-one",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 1_756_600_000),
            createdAt: Date(timeIntervalSince1970: 1_756_600_000),
            headRefName: "feature",
            headRefOid: "head-1",
            baseRefName: "main",
            myRelation: relations,
            mergeable: .mergeable
        )
    }

    // MARK: - What the funnel refuses

    func testAnApproveOnYourOwnPullRequestIsRefused() {
        let mine = summary(relations: [.author])

        XCTAssertEqual(PullRequestActions.refusal(of: .approve, on: mine), .ownPullRequest)
        XCTAssertEqual(PullRequestActions.refusal(of: .requestChanges, on: mine), .ownPullRequest)
    }

    func testACommentOnYourOwnPullRequestIsNotRefused() {
        // The exemption the funnel exists to keep: GitHub accepts a `COMMENT` review from the
        // author, so the composer degrades to one instead of going dark.
        let mine = summary(relations: [.author])

        XCTAssertNil(PullRequestActions.refusal(of: .comment, on: mine))
    }

    func testNoVerdictIsRefusedOnSomebodyElsesPullRequest() {
        let theirs = summary(relations: [.reviewRequested])

        for verdict in [ReviewVerdict.approve, .requestChanges, .comment] {
            XCTAssertNil(
                PullRequestActions.refusal(of: verdict, on: theirs),
                "\(verdict) is refused on a pull request that is not yours"
            )
        }
    }

    // MARK: - What it says

    func testEachBlockerNamesThePullRequestAndADifferentWayOut() {
        let slug = "schnaq/review#87"
        let messages = [
            PullRequestActions.blockerMessage(.draft, slug: slug),
            PullRequestActions.blockerMessage(.conflicting, slug: slug),
            PullRequestActions.blockerMessage(.ownPullRequest, slug: slug),
        ]

        for message in messages {
            XCTAssertTrue(message.contains(slug), "a refusal that does not name the pull request")
        }
        XCTAssertEqual(Set(messages).count, 3, "two blockers must never read the same")
        XCTAssertEqual(
            messages[0],
            String(
                localized: "\(slug) is still a draft — GitHub refuses the merge until it is marked ready for review."
            )
        )
    }
}
