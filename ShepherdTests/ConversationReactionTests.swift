import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// Reacting in the conversation tab (ADR 0043, B): what the bar shows once the reviewer has
/// clicked, when a click stops being the screen's and becomes GitHub's, what a click writes to the
/// outbox, and what is said about it. English, because the app tests run with
/// `-testLanguage en`. The mutation and the drain are ShepherdKit's (`OutboxDrainTests`).
@MainActor
final class ConversationReactionTests: XCTestCase {
    private typealias Key = ConversationOverlay.ReactionKey

    /// What the bar draws for these clicks (``ConversationOverlay/reactions(_:on:)``).
    private func displayed(_ groups: [ReactionGroup], subjectID: String, overlay: [Key: Bool]) -> [ReactionGroup] {
        ConversationOverlay(reactions: overlay).reactions(groups, on: subjectID)
    }

    /// The clicks a detail leaves (``ConversationOverlay/settled(against:)``).
    private func unconfirmedClicks(_ overlay: [Key: Bool], against detail: PullRequestDetail) -> [Key: Bool] {
        ConversationOverlay(reactions: overlay).settled(against: detail).reactions
    }

    // MARK: - What the bar shows

    func testAClickAddsToAGroupThatIsAlreadyThere() {
        let shown = displayed(
            [ReactionGroup(content: .thumbsUp, count: 2)],
            subjectID: "IC_1",
            overlay: [Key(subjectID: "IC_1", content: .thumbsUp): true]
        )
        XCTAssertEqual(shown, [ReactionGroup(content: .thumbsUp, count: 3, viewerHasReacted: true)])
    }

    func testANewGroupTakesItsPlaceInGitHubsOrder() {
        let shown = displayed(
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
        let shown = displayed(
            [ReactionGroup(content: .hooray, count: 1, viewerHasReacted: true)],
            subjectID: "IC_1",
            overlay: [Key(subjectID: "IC_1", content: .hooray): false]
        )
        XCTAssertEqual(shown, [])
        XCTAssertEqual(
            displayed(
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
            displayed(stored, subjectID: "IC_1", overlay: [Key(subjectID: "IC_1", content: .thumbsUp): true]),
            stored
        )
        XCTAssertEqual(
            displayed(stored, subjectID: "IC_1", overlay: [Key(subjectID: "IC_2", content: .thumbsUp): false]),
            stored,
            "a click on another post"
        )
        XCTAssertEqual(
            displayed([], subjectID: "IC_1", overlay: [Key(subjectID: "IC_1", content: .laugh): false]),
            [],
            "taking back what is not there"
        )
    }

    // MARK: - When a click stops being the screen's

    private static let author = ShepherdCore.Actor(login: "octocat", kind: .human)
    private static let moment = Date(timeIntervalSince1970: 1_000)
    private var summary: PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            title: "Retry the flaky upload",
            author: Self.author,
            updatedAt: Self.moment,
            createdAt: Self.moment,
            additions: 1,
            deletions: 0,
            changedFiles: 1,
            headRefName: "feature",
            headRefOid: "abc123",
            baseRefName: "main"
        )
    }

    private func detail(
        description: [ReactionGroup] = [],
        comment: [ReactionGroup] = [],
        review: [ReactionGroup] = [],
        threadComment: [ReactionGroup] = [],
        hasConversation: Bool = true
    ) -> PullRequestDetail {
        let author = Self.author
        let moment = Self.moment
        return PullRequestDetail(
            summary: summary,
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
        let kept = unconfirmedClicks(overlay, against: detail(
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
        let kept = unconfirmedClicks(overlay, against: detail(
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
            unconfirmedClicks(overlay, against: detail(hasConversation: false)),
            overlay,
            "a conversation not read yet is not one without reactions"
        )
        XCTAssertEqual(
            unconfirmedClicks(overlay, against: detail()),
            [Key(subjectID: "IC_gone", content: .heart): false]
        )
    }

    // MARK: - What a click does to the row it undoes

    private func row(
        _ action: OutboxAction,
        prID: String = "PR_1",
        state: OutboxState = .pending
    ) -> OutboxItem {
        OutboxItem(
            prID: prID,
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            action: action,
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

    // MARK: - What a click writes

    // Against a real outbox: the cancel is the store's own state-guarded delete, which a list of
    // rows in memory could only pretend to be.

    /// One click on the heart under `IC_1`, written the way the bar writes it.
    private func click(adding: Bool, in database: DatabaseManager) async throws -> OutboxItem {
        try await PullRequestActions.writeReaction(
            subjectID: "IC_1",
            content: .heart,
            adding: adding,
            on: summary,
            in: database
        )
    }

    func testWithNothingToUndoTheClickQueuesItsOwnRow() async throws {
        let database = try DatabaseManager.inMemory()
        let add = try await click(adding: true, in: database)
        let rows = try await database.allOutboxItems()
        XCTAssertEqual(rows.map(\.id), [add.id])
        XCTAssertEqual(rows.first?.action, .react(subjectID: "IC_1", content: .heart, adding: true))
        XCTAssertEqual(rows.first?.state, .pending)
    }

    /// A row the drain holds is in flight and is not touched: it stays the drain's, and the click's
    /// own row waits behind it.
    func testARowTheDrainHoldsIsLeftAloneAndTheClickQueuesBehindIt() async throws {
        let database = try DatabaseManager.inMemory()
        let add = try await click(adding: true, in: database)
        _ = try await database.claimReadyOutboxItems()
        let remove = try await click(adding: false, in: database)
        let rows = try await database.allOutboxItems()
        XCTAssertEqual(Set(rows.map(\.id)), [add.id, remove.id])
        XCTAssertEqual(rows.first { $0.id == add.id }?.state, .sending)
        XCTAssertEqual(rows.first { $0.id == remove.id }?.state, .pending)
    }

    func testAClickCancelsARowThatNeverLeftAndStillQueuesItsOwn() async throws {
        let database = try DatabaseManager.inMemory()
        _ = try await click(adding: true, in: database)
        let remove = try await click(adding: false, in: database)
        let rows = try await database.allOutboxItems()
        XCTAssertEqual(rows.map(\.id), [remove.id], "the add can no longer land after the removal")
    }

    /// A tried row may have landed with its answer lost; the click's own row makes sure either way.
    func testAClickCancelsATriedRowInBackoffAndStillQueuesItsOwn() async throws {
        let database = try DatabaseManager.inMemory()
        let add = try await click(adding: true, in: database)
        _ = try await database.claimReadyOutboxItems()
        try await database.markOutboxItemFailed(id: add.id, error: "502 Bad Gateway", retriable: true)
        let remove = try await click(adding: false, in: database)
        let rows = try await database.allOutboxItems()
        XCTAssertEqual(rows.map(\.id), [remove.id])
    }

    /// An add in flight, then remove, add and remove before it lands. Each click cancels the
    /// still-waiting row of the click before it and queues its own, so what waits behind the add in
    /// flight is the last click — and the removal the reviewer ended on is what reaches GitHub
    /// last.
    func testTheLastClickIsWhatWaitsBehindARowInFlight() async throws {
        let database = try DatabaseManager.inMemory()
        let inFlight = try await click(adding: true, in: database)
        _ = try await database.claimReadyOutboxItems()
        _ = try await click(adding: false, in: database)
        _ = try await click(adding: true, in: database)
        let last = try await click(adding: false, in: database)
        let rows = try await database.allOutboxItems()
        XCTAssertEqual(Set(rows.map(\.id)), [inFlight.id, last.id])
        let waiting = rows.filter { $0.state == .pending }
        XCTAssertEqual(waiting.map(\.id), [last.id])
        XCTAssertEqual(
            waiting.first?.action,
            .react(subjectID: "IC_1", content: .heart, adding: false),
            "the last click was a removal"
        )
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
