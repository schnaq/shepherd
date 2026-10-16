import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// Every event of the conversation tab reads as GitHub's sentence (ADR 0043).
///
/// ShepherdKit carries an event as values and no words, so the sentence is the app's own, and one
/// assertion per row of the table in the plan is what keeps it GitHub's. English, because the app
/// tests run with `-testLanguage en`; the German rows are `Scripts/check-localization.py`'s.
@MainActor
final class ConversationEventTextTests: XCTestCase {
    private static let sophie = ShepherdCore.Actor(
        login: "sophie-mueller",
        displayName: "Sophie Müller",
        kind: .human
    )

    private func sentence(
        _ event: ConversationEvent,
        by actor: ShepherdCore.Actor? = ConversationEventTextTests.sophie
    ) -> String {
        ConversationEventText.sentence(
            for: ConversationEventItem(id: "E_1", createdAt: Date(), actor: actor, event: event)
        )
    }

    func testLabels() {
        XCTAssertEqual(
            sentence(.labeled(name: "outbox", color: "1d76db")),
            "Sophie Müller added the label outbox"
        )
        XCTAssertEqual(
            sentence(.unlabeled(name: "outbox", color: nil)),
            "Sophie Müller removed the label outbox"
        )
    }

    func testAssignments() {
        XCTAssertEqual(sentence(.assigned(login: "tkrause")), "Sophie Müller assigned tkrause")
        XCTAssertEqual(sentence(.assigned(login: "sophie-mueller")), "Sophie Müller self-assigned this")
        XCTAssertEqual(sentence(.unassigned(login: "tkrause")), "Sophie Müller unassigned tkrause")
    }

    func testReviewRequests() {
        XCTAssertEqual(
            sentence(.reviewRequested(reviewer: "jonas-weber")),
            "Sophie Müller requested a review from jonas-weber"
        )
        XCTAssertEqual(
            sentence(.reviewRequestRemoved(reviewer: "jonas-weber")),
            "Sophie Müller removed the review request for jonas-weber"
        )
    }

    func testTitleAndDraftState() {
        XCTAssertEqual(
            sentence(.renamed(from: "Retry", to: "Retry failed writes")),
            "Sophie Müller changed the title from \"Retry\" to \"Retry failed writes\""
        )
        XCTAssertEqual(
            sentence(.readyForReview),
            "Sophie Müller marked this pull request as ready for review"
        )
        XCTAssertEqual(
            sentence(.convertedToDraft),
            "Sophie Müller converted this pull request to a draft"
        )
    }

    func testMergeCloseReopen() {
        XCTAssertEqual(
            sentence(.merged(commitOid: "9c41e07b2d5f3a86e1c0", into: "main")),
            "Sophie Müller merged commit 9c41e07 into main"
        )
        XCTAssertEqual(
            sentence(.merged(commitOid: "9c41e07b2d5f3a86e1c0", into: nil)),
            "Sophie Müller merged this pull request"
        )
        XCTAssertEqual(sentence(.closed), "Sophie Müller closed this pull request")
        XCTAssertEqual(sentence(.reopened), "Sophie Müller reopened this pull request")
    }

    func testBranches() {
        XCTAssertEqual(
            sentence(.headRefDeleted(branch: "claude/outbox-retry")),
            "Sophie Müller deleted the branch claude/outbox-retry"
        )
        XCTAssertEqual(sentence(.headRefDeleted(branch: nil)), "Sophie Müller deleted the head branch")
        XCTAssertEqual(sentence(.headRefRestored), "Sophie Müller restored the head branch")
        XCTAssertEqual(
            sentence(.baseRefChanged(from: "main", to: "release")),
            "Sophie Müller changed the base branch from main to release"
        )
        XCTAssertEqual(
            sentence(.baseRefChanged(from: nil, to: "release")),
            "Sophie Müller changed the base branch"
        )
        XCTAssertEqual(
            sentence(.forcePushed(fromOid: "1a2b3c4d5e6f", toOid: "9c41e07b2d5f")),
            "Sophie Müller force-pushed from 1a2b3c4 to 9c41e07"
        )
        XCTAssertEqual(
            sentence(.forcePushed(fromOid: nil, toOid: "9c41e07b2d5f")),
            "Sophie Müller force-pushed the branch"
        )
    }

    func testCrossReferenceNamesTheOtherPullRequestWithoutGrouping() {
        let reference = ConversationReference(
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 1024,
            title: "Use the new retry",
            isPullRequest: true
        )
        XCTAssertEqual(
            sentence(.crossReferenced(reference, willClose: false)),
            "Sophie Müller mentioned this in schnaq/review#1024 Use the new retry"
        )
    }

    func testDismissedReviewAndAutoMerge() {
        XCTAssertEqual(
            sentence(.reviewDismissed(message: "Outdated after the rebase")),
            "Sophie Müller dismissed a review: Outdated after the rebase"
        )
        XCTAssertEqual(sentence(.reviewDismissed(message: nil)), "Sophie Müller dismissed a review")
        XCTAssertEqual(sentence(.autoMergeEnabled), "Sophie Müller enabled auto-merge")
        XCTAssertEqual(sentence(.autoMergeDisabled), "Sophie Müller disabled auto-merge")
    }

    func testAnEventWhoseActorIsGoneIsSomeones() {
        XCTAssertEqual(sentence(.closed, by: nil), "Someone closed this pull request")
    }
}
