import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// Reacting in the conversation tab (ADR 0043, B): what the bar shows once the reviewer has
/// clicked, when a click stops being the screen's and becomes GitHub's, what a click does to the
/// row it undoes, and what is said about it. English, because the app tests run with
/// `-testLanguage en`. The row, the mutation and the drain are ShepherdKit's (`OutboxDrainTests`).
@MainActor
final class ConversationReactionTests: XCTestCase {
    private typealias Key = ReviewModel.ReactionKey

    // MARK: - What the bar shows

    func testAClickAddsToAGroupThatIsAlreadyThere() {
        let shown = ReviewModel.displayed(
            [ReactionGroup(content: .thumbsUp, count: 2)],
            subjectID: "IC_1",
            overlay: [Key(subjectID: "IC_1", content: .thumbsUp): true]
        )
        XCTAssertEqual(shown, [ReactionGroup(content: .thumbsUp, count: 3, viewerHasReacted: true)])
    }

    func testANewGroupTakesItsPlaceInGitHubsOrder() {
        let shown = ReviewModel.displayed(
            [ReactionGroup(content: .thumbsUp, count: 1), ReactionGroup(content: .rocket, count: 4)],
            subjectID: "IC_1",
            overlay: [Key(subjectID: "IC_1", content: .heart): true]
        )
        XCTAssertEqual(shown, [
            ReactionGroup(content: .thumbsUp, count: 1),
            ReactionGroup(content: .heart, count: 1, viewerHasReacted: true),
            ReactionGroup(content: .rocket, count: 4),
        ])
    }

    func testTakingBackTheOnlyReactionTakesTheGroupAway() {
        let shown = ReviewModel.displayed(
            [ReactionGroup(content: .hooray, count: 1, viewerHasReacted: true)],
            subjectID: "IC_1",
            overlay: [Key(subjectID: "IC_1", content: .hooray): false]
        )
        XCTAssertEqual(shown, [])
        XCTAssertEqual(
            ReviewModel.displayed(
                [ReactionGroup(content: .eyes, count: 3, viewerHasReacted: true)],
                subjectID: "IC_1",
                overlay: [Key(subjectID: "IC_1", content: .eyes): false]
            ),
            [ReactionGroup(content: .eyes, count: 2)],
            "other people's stay"
        )
    }

    func testAClickTheStoredStateAlreadyAgreesWithChangesNothing() {
        let stored = [ReactionGroup(content: .thumbsUp, count: 2, viewerHasReacted: true)]
        XCTAssertEqual(
            ReviewModel.displayed(stored, subjectID: "IC_1", overlay: [Key(subjectID: "IC_1", content: .thumbsUp): true]),
            stored
        )
        XCTAssertEqual(
            ReviewModel.displayed(stored, subjectID: "IC_1", overlay: [Key(subjectID: "IC_2", content: .thumbsUp): false]),
            stored,
            "a click on another post"
        )
        XCTAssertEqual(
            ReviewModel.displayed([], subjectID: "IC_1", overlay: [Key(subjectID: "IC_1", content: .laugh): false]),
            [],
            "taking back what is not there"
        )
    }

    // MARK: - When a click stops being the screen's

    private func detail(
        description: [ReactionGroup] = [],
        comment: [ReactionGroup] = [],
        review: [ReactionGroup] = [],
        threadComment: [ReactionGroup] = [],
        hasConversation: Bool = true
    ) -> PullRequestDetail {
        let author = ShepherdCore.Actor(login: "octocat", kind: .human)
        let moment = Date(timeIntervalSince1970: 1_000)
        return PullRequestDetail(
            summary: PullRequestSummary(
                id: "PR_1",
                repo: RepoRef(owner: "schnaq", name: "review"),
                number: 42,
                title: "Retry the flaky upload",
                author: author,
                updatedAt: moment,
                createdAt: moment,
                additions: 1,
                deletions: 0,
                changedFiles: 1,
                headRefName: "feature",
                headRefOid: "abc123",
                baseRefName: "main"
            ),
            threads: [
                ReviewThread(
                    id: "RT_1",
                    comments: [
                        ReviewComment(
                            id: "RC_1",
                            author: author,
                            bodyMarkdown: "Why twice?",
                            createdAt: moment,
                            reactions: threadComment
                        ),
                    ]
                ),
            ],
            conversation: hasConversation
                ? PullRequestConversation(
                    descriptionReactions: description,
                    viewerCanReact: true,
                    items: [
                        .comment(ConversationComment(
                            id: "IC_1",
                            author: author,
                            bodyMarkdown: "Looks good.",
                            createdAt: moment,
                            reactions: comment
                        )),
                        .review(ConversationReview(
                            id: "PRR_1",
                            author: author,
                            state: .approved,
                            createdAt: moment,
                            reactions: review
                        )),
                    ]
                )
                : nil
        )
    }

    func testADetailThatAgreesTakesTheClickOver() {
        let overlay: [Key: Bool] = [
            Key(subjectID: "PR_1", content: .heart): true,
            Key(subjectID: "IC_1", content: .thumbsUp): false,
            Key(subjectID: "PRR_1", content: .rocket): true,
            Key(subjectID: "RC_1", content: .eyes): true,
        ]
        let kept = ReviewModel.reactionOverlay(overlay, against: detail(
            description: [ReactionGroup(content: .heart, count: 1, viewerHasReacted: true)],
            comment: [ReactionGroup(content: .thumbsUp, count: 2)],
            review: [ReactionGroup(content: .rocket, count: 1, viewerHasReacted: true)],
            threadComment: [ReactionGroup(content: .eyes, count: 2, viewerHasReacted: true)]
        ))
        XCTAssertEqual(kept, [:])
    }

    /// The re-read after a send can still carry the state from before it: the click stays, so the
    /// reaction does not flicker off and on again.
    func testADetailThatDoesNotAgreeYetKeepsTheClick() {
        let overlay: [Key: Bool] = [
            Key(subjectID: "IC_1", content: .thumbsUp): true,
            Key(subjectID: "RC_1", content: .eyes): false,
        ]
        let kept = ReviewModel.reactionOverlay(overlay, against: detail(
            comment: [ReactionGroup(content: .thumbsUp, count: 2)],
            threadComment: [ReactionGroup(content: .eyes, count: 1, viewerHasReacted: true)]
        ))
        XCTAssertEqual(kept, overlay)
    }

    func testAPostTheDetailDoesNotCarryKeepsItsClick() {
        let overlay: [Key: Bool] = [
            Key(subjectID: "IC_1", content: .thumbsUp): false,
            Key(subjectID: "IC_gone", content: .heart): false,
        ]
        XCTAssertEqual(
            ReviewModel.reactionOverlay(overlay, against: detail(hasConversation: false)),
            overlay,
            "a conversation not read yet is not one without reactions"
        )
        XCTAssertEqual(
            ReviewModel.reactionOverlay(overlay, against: detail()),
            [Key(subjectID: "IC_gone", content: .heart): false]
        )
    }

    // MARK: - What a click does to the row it undoes

    private func row(
        _ action: OutboxAction,
        prID: String = "PR_1",
        state: OutboxState = .pending,
        attemptCount: Int = 0
    ) -> OutboxItem {
        OutboxItem(
            prID: prID,
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            action: action,
            attemptCount: attemptCount,
            state: state
        )
    }

    private func undone(byAdding adding: Bool, in items: [OutboxItem]) -> OutboxItem? {
        PullRequestActions.queuedReaction(
            undoneBy: adding,
            subjectID: "IC_1",
            content: .heart,
            prID: "PR_1",
            in: items
        )
    }

    func testAClickUndoesTheWaitingRowOfTheSameReactionGoingTheOtherWay() {
        let add = row(.react(subjectID: "IC_1", content: .heart, adding: true))
        let newerAdd = row(.react(subjectID: "IC_1", content: .heart, adding: true))
        let items = [
            add,
            row(.react(subjectID: "IC_1", content: .heart, adding: false)),
            row(.react(subjectID: "IC_1", content: .rocket, adding: true)),
            row(.react(subjectID: "IC_2", content: .heart, adding: true)),
            row(.react(subjectID: "IC_1", content: .heart, adding: true), prID: "PR_2"),
            row(.react(subjectID: "IC_1", content: .heart, adding: true), state: .sending),
            row(.react(subjectID: "IC_1", content: .heart, adding: true), state: .failed),
            row(.addPullRequestComment(body: "one thought")),
            newerAdd,
        ]
        XCTAssertEqual(undone(byAdding: false, in: items)?.id, newerAdd.id, "the newest of two")
        XCTAssertEqual(undone(byAdding: false, in: [add])?.id, add.id)
        XCTAssertNil(undone(byAdding: true, in: [add]), "a row going the same way is not undone")
        XCTAssertNil(
            undone(byAdding: false, in: Array(items.dropFirst().dropLast())),
            "only a pending row of the same post, emoji and pull request"
        )
    }

    func testWithNothingToUndoTheClickQueuesItsOwnRow() {
        XCTAssertTrue(PullRequestActions.needsReactionRow(undoing: nil, cancelled: false))
    }

    func testARowCancelledBeforeItWasTriedNeedsNoOpposite() {
        let waiting = row(.react(subjectID: "IC_1", content: .heart, adding: true))
        XCTAssertFalse(PullRequestActions.needsReactionRow(undoing: waiting, cancelled: true))
    }

    /// A row tried before may have reached GitHub with its answer lost on the way back.
    func testARowCancelledAfterAnAttemptStillGetsItsOpposite() {
        let retried = row(.react(subjectID: "IC_1", content: .heart, adding: true), attemptCount: 1)
        XCTAssertTrue(PullRequestActions.needsReactionRow(undoing: retried, cancelled: true))
    }

    /// The drain claimed the row between the read and the cancel: it may be on GitHub by now.
    func testARowTheDrainClaimedFirstGetsItsOpposite() {
        let claimed = row(.react(subjectID: "IC_1", content: .heart, adding: true))
        XCTAssertTrue(PullRequestActions.needsReactionRow(undoing: claimed, cancelled: false))
    }

    // MARK: - What is said about it

    func testAReactionIsSilentUnlessItFails() {
        let slug = "schnaq/review#182"
        XCTAssertNil(PullRequestActions.announcement(for: .sent, of: .reaction, slug: slug))
        XCTAssertNil(PullRequestActions.announcement(for: .queued, of: .reaction, slug: slug))
        let failed = PullRequestActions.announcement(
            for: .failed(reason: "Resource not accessible by integration"),
            of: .reaction,
            slug: slug
        )
        XCTAssertEqual(
            failed?.message,
            "Could not change your reaction on schnaq/review#182 — it is back as it was: Resource not accessible by integration"
        )
        XCTAssertEqual(failed?.kind, .failure)
        let parked = PullRequestActions.announcement(for: .parked(reason: nil), of: .reaction, slug: slug)
        XCTAssertNotNil(parked)
        XCTAssertNotEqual(parked?.kind, .success)
    }

    func testACapsuleSaysItsEmojiItsCountWhetherYoursIsInItAndWhatPressingDoes() {
        let mine = ReactionGroup(content: .thumbsUp, count: 2, viewerHasReacted: true)
        XCTAssertEqual(ReactionBar.spokenLabel(for: mine), "Thumbs up. 2 reactions. including yours.")
        XCTAssertEqual(ReactionBar.action(for: mine), "Remove your reaction")
        let theirs = ReactionGroup(content: .heart, count: 1)
        XCTAssertEqual(ReactionBar.spokenLabel(for: theirs), "Heart. 1 reaction.")
        XCTAssertEqual(ReactionBar.action(for: theirs), "Add your reaction")
    }

    func testEveryEmojiHasAName() {
        let names = ReactionContent.allCases.map(ReactionBar.name(of:))
        XCTAssertEqual(Set(names).count, ReactionContent.allCases.count)
        XCTAssertFalse(names.contains { $0.isEmpty })
    }
}
