import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// Editing and deleting the viewer's own posts in the conversation tab (ADR 0043, C): what the tab
/// draws once the reviewer has edited or deleted, when that stops being the screen's and becomes
/// GitHub's, which posts offer it, what a delete or an edit does to the edits still waiting in the
/// outbox, and what is said about it. English, because the app tests run with `-testLanguage en`.
/// The REST calls and the drain are ShepherdKit's (`WriteRequestTests`, `OutboxDrainTests`).
@MainActor
final class ConversationEditTests: XCTestCase {
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

    private func threadComment(_ id: String, _ body: String) -> ReviewComment {
        ReviewComment(id: id, author: Self.author, bodyMarkdown: body, createdAt: Self.moment, reviewID: "PRR_1")
    }

    /// A description, two comments, a review with words, and two threads under the review — one
    /// with two comments, one with one.
    private func detail(
        description: String = "The fix.",
        comment: String = "Looks good.",
        review: String = "Two nits.",
        reply: String = "Because.",
        comments: [String] = ["IC_1", "IC_2"],
        hasConversation: Bool = true
    ) -> PullRequestDetail {
        let author = Self.author
        let moment = Self.moment
        let bodies = ["IC_1": comment, "IC_2": "Ship it."]
        return PullRequestDetail(
            summary: summary,
            bodyMarkdown: description,
            threads: [
                ReviewThread(id: "RT_1", comments: [threadComment("RC_1", "Why twice?"), threadComment("RC_2", reply)]),
                ReviewThread(id: "RT_2", comments: [threadComment("RC_3", "Typo.")]),
            ],
            conversation: hasConversation
                ? PullRequestConversation(
                    items: comments.map { id in
                        .comment(ConversationComment(
                            id: id,
                            author: author,
                            bodyMarkdown: bodies[id] ?? "",
                            createdAt: moment
                        ))
                    } + [
                        .review(ConversationReview(
                            id: "PRR_1",
                            author: author,
                            state: .commented,
                            bodyMarkdown: review,
                            createdAt: moment
                        )),
                    ]
                )
                : nil
        )
    }

    private func body(of id: String, in detail: PullRequestDetail) -> String? {
        for item in detail.conversation?.items ?? [] {
            switch item {
            case .comment(let comment) where comment.id == id: return comment.bodyMarkdown
            case .review(let review) where review.id == id: return review.bodyMarkdown
            default: continue
            }
        }
        return detail.threads.flatMap(\.comments).first { $0.id == id }?.bodyMarkdown
    }

    // MARK: - What the tab draws

    func testAnEditedPostShowsItsNewTextWhereverItIs() {
        let overlay = ConversationOverlay(editedBodies: [
            "PR_1": "The real fix.",
            "IC_1": "Looks good, once CI is green.",
            "PRR_1": "One nit.",
            "RC_2": "Because the first one times out.",
        ])
        let shown = overlay.applied(to: detail())
        XCTAssertEqual(shown.bodyMarkdown, "The real fix.", "the description")
        XCTAssertEqual(body(of: "IC_1", in: shown), "Looks good, once CI is green.")
        XCTAssertEqual(body(of: "PRR_1", in: shown), "One nit.")
        XCTAssertEqual(body(of: "RC_2", in: shown), "Because the first one times out.")
        XCTAssertEqual(body(of: "IC_2", in: shown), "Ship it.", "a post nobody edited")
        XCTAssertEqual(body(of: "RC_1", in: shown), "Why twice?")
    }

    func testADeletedCommentIsGoneFromTheConversationAndFromItsThread() {
        let shown = ConversationOverlay(deletedPosts: ["IC_1", "RC_1"]).applied(to: detail())
        XCTAssertEqual(shown.conversation?.items.map(\.id), ["IC_2", "PRR_1"])
        XCTAssertEqual(shown.threads.first?.comments.map(\.id), ["RC_2"], "the reply stays")
    }

    func testAThreadWhoseCommentsAreAllDeletedIsNotDrawn() {
        let shown = ConversationOverlay(deletedPosts: ["RC_3"]).applied(to: detail())
        let entries = ConversationTimeline.entries(
            conversation: shown.conversation,
            commits: shown.commits,
            threads: shown.threads
        )
        let threads = entries.flatMap { entry -> [ReviewThread] in
            if case .review(_, let threads) = entry { return threads }
            if case .thread(let thread) = entry { return [thread] }
            return []
        }
        XCTAssertEqual(threads.map(\.id), ["RT_1"])
    }

    func testADeleteWinsOverAnEditOfTheSamePost() {
        let shown = ConversationOverlay(editedBodies: ["IC_1": "Never mind."], deletedPosts: ["IC_1"])
            .applied(to: detail())
        XCTAssertNil(body(of: "IC_1", in: shown))
    }

    func testNothingOverlaidLeavesTheDetailAsStored() {
        XCTAssertEqual(ConversationOverlay().applied(to: detail()), detail())
    }

    // MARK: - When an edit or a delete stops being the screen's

    func testADetailThatAgreesTakesTheEditAndTheDeleteOver() {
        let overlay = ConversationOverlay(
            editedBodies: ["PR_1": "The real fix.", "IC_1": "Looks better.", "RC_2": "Timeouts."],
            deletedPosts: ["IC_2", "RC_3"]
        )
        let settled = overlay.settled(against: detail(
            description: "The real fix.",
            comment: "Looks better.",
            reply: "Timeouts.",
            comments: ["IC_1"]
        ).removingThread("RT_2"))
        XCTAssertEqual(settled, ConversationOverlay())
    }

    /// The re-read after another write can still carry the text from before the edit and the
    /// comment before the delete: both stay, so the post does not flicker back.
    func testADetailThatDoesNotAgreeYetKeepsTheEditAndTheDelete() {
        let overlay = ConversationOverlay(
            editedBodies: ["PR_1": "The real fix.", "IC_1": "Looks better.", "RC_2": "Timeouts."],
            deletedPosts: ["IC_2", "RC_3"]
        )
        XCTAssertEqual(overlay.settled(against: detail()), overlay)
    }

    /// A tolerated failure of the conversation read leaves it `nil`: that is "not read", and a
    /// deleted comment must not come back on it. The threads and the description are read all the
    /// same, so what they carry still settles.
    func testAConversationNotReadYetKeepsWhatOnlyItCouldSettle() {
        let overlay = ConversationOverlay(
            editedBodies: ["IC_1": "Looks better.", "PR_1": "The fix.", "RC_2": "Because."],
            deletedPosts: ["IC_2"]
        )
        let settled = overlay.settled(against: detail(hasConversation: false))
        XCTAssertEqual(settled, ConversationOverlay(editedBodies: ["IC_1": "Looks better."], deletedPosts: ["IC_2"]))
    }

    /// An edit of a comment somebody deleted on GitHub meanwhile: nothing left to draw it on.
    func testAnEditOfAPostThatIsGoneGoesWithIt() {
        let overlay = ConversationOverlay(editedBodies: ["IC_2": "Ship it now."])
        XCTAssertEqual(overlay.settled(against: detail(comments: ["IC_1"])), ConversationOverlay())
    }

    // MARK: - What a refusal takes back

    func testARefusedEditTakesBackOnlyItsOwnText() {
        var overlay = ConversationOverlay(editedBodies: ["IC_1": "Second try."])
        overlay.drop(editOf: "IC_1", ifStill: "First try.")
        XCTAssertEqual(overlay.editedBodies, ["IC_1": "Second try."], "a later edit replaced it")
        overlay.drop(editOf: "IC_1", ifStill: "Second try.")
        XCTAssertEqual(overlay, ConversationOverlay())
    }

    func testARefusedEditGoesBackIntoItsEditorUnlessSomethingNewerIsThere() {
        let shown = ConversationOverlay(editedBodies: ["IC_1": "First try."])
        XCTAssertTrue(ReviewModel.reopensEditor(of: "IC_1", with: "First try.", overlay: shown, editing: ["IC_2"]))
        XCTAssertFalse(
            ReviewModel.reopensEditor(of: "IC_1", with: "First try.", overlay: shown, editing: ["IC_1"]),
            "the editor was opened again, and what is typed there is newer"
        )
        XCTAssertFalse(
            ReviewModel.reopensEditor(
                of: "IC_1",
                with: "First try.",
                overlay: ConversationOverlay(editedBodies: ["IC_1": "Second try."]),
                editing: []
            ),
            "a later edit replaced it"
        )
        XCTAssertFalse(
            ReviewModel.reopensEditor(
                of: "IC_1",
                with: "First try.",
                overlay: ConversationOverlay(deletedPosts: ["IC_1"]),
                editing: []
            ),
            "the comment was deleted since"
        )
    }

    func testARefusedDeleteBringsTheCommentBack() {
        var overlay = ConversationOverlay(deletedPosts: ["IC_1", "IC_2"])
        overlay.drop(deletionOf: "IC_1")
        XCTAssertEqual(overlay.deletedPosts, ["IC_2"])
    }

    func testARefusedClickTakesBackOnlyItsOwnDirection() {
        let key = ConversationOverlay.ReactionKey(subjectID: "IC_1", content: .heart)
        var overlay = ConversationOverlay(reactions: [key: false])
        overlay.drop(key, ifStill: true)
        XCTAssertEqual(overlay.reactions, [key: false], "a later click moved it")
        overlay.drop(key, ifStill: false)
        XCTAssertEqual(overlay, ConversationOverlay())
    }

    // MARK: - Which posts offer it

    func testACommentOffersWhatGitHubAllowsAndOnlyWithItsRESTID() {
        func comment(databaseID: Int?, update: Bool, delete: Bool) -> ConversationComment {
            ConversationComment(
                id: "IC_1",
                databaseID: databaseID,
                author: Self.author,
                bodyMarkdown: "Looks good.",
                createdAt: Self.moment,
                viewerCanUpdate: update,
                viewerCanDelete: delete
            )
        }
        XCTAssertEqual(
            PostEditing.comment(comment(databaseID: 11, update: true, delete: true)),
            PostEditing(postID: "IC_1", target: .issueComment(databaseID: 11), canEdit: true, canDelete: true)
        )
        XCTAssertEqual(
            PostEditing.comment(comment(databaseID: 11, update: true, delete: false)),
            PostEditing(postID: "IC_1", target: .issueComment(databaseID: 11), canEdit: true, canDelete: false)
        )
        XCTAssertNil(PostEditing.comment(comment(databaseID: 11, update: false, delete: false)), "somebody else's")
        XCTAssertNil(PostEditing.comment(comment(databaseID: nil, update: true, delete: true)), "nothing to address")
    }

    func testAThreadCommentOffersWhatGitHubAllowsAndOnlyWithItsRESTID() {
        var comment = threadComment("RC_1", "Why twice?")
        comment.viewerCanDelete = true
        XCTAssertNil(PostEditing.threadComment(comment), "no database id")
        comment.databaseID = 31
        XCTAssertEqual(
            PostEditing.threadComment(comment),
            PostEditing(postID: "RC_1", target: .reviewComment(databaseID: 31), canEdit: false, canDelete: true)
        )
    }

    func testASubmittedReviewWithWordsIsEditableAndNeverDeletable() {
        func review(state: ConversationReview.State, body: String, databaseID: Int? = 21) -> ConversationReview {
            ConversationReview(
                id: "PRR_1",
                databaseID: databaseID,
                author: Self.author,
                state: state,
                bodyMarkdown: body,
                createdAt: Self.moment,
                viewerCanUpdate: true
            )
        }
        XCTAssertEqual(
            PostEditing.review(review(state: .approved, body: "Two nits.")),
            PostEditing(postID: "PRR_1", target: .review(databaseID: 21), canEdit: true, canDelete: false)
        )
        XCTAssertNil(PostEditing.review(review(state: .approved, body: " \n")), "a verdict without words")
        XCTAssertNil(PostEditing.review(review(state: .pending, body: "Draft.")), "not submitted")
        XCTAssertNil(PostEditing.review(review(state: .approved, body: "Two nits.", databaseID: nil)))
    }

    func testTheDescriptionIsEditableWhereGitHubSaysAndNeverDeletable() {
        XCTAssertEqual(
            PostEditing.description(of: "PR_1", conversation: PullRequestConversation(viewerCanUpdateDescription: true)),
            PostEditing(postID: "PR_1", target: .description, canEdit: true, canDelete: false)
        )
        XCTAssertNil(PostEditing.description(of: "PR_1", conversation: PullRequestConversation()))
        XCTAssertNil(PostEditing.description(of: "PR_1", conversation: nil), "not read yet")
    }

    // MARK: - What a delete or an edit does to the edits still waiting

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

    func testTheWaitingEditsOfAPostAreEveryPendingEditOfTheSameTarget() {
        let target = ConversationTarget.issueComment(databaseID: 11)
        let first = row(.editComment(target, body: "One."))
        let second = row(.editComment(target, body: "Two."))
        let items = [
            first,
            row(.editComment(.issueComment(databaseID: 12), body: "Another post.")),
            row(.editComment(.reviewComment(databaseID: 11), body: "Same number, other kind.")),
            row(.editComment(target, body: "Other pull request."), prID: "PR_2"),
            row(.editComment(target, body: "In flight."), state: .sending),
            row(.editComment(target, body: "Refused."), state: .failed),
            row(.deleteComment(target)),
            row(.addPullRequestComment(body: "one thought")),
            second,
        ]
        XCTAssertEqual(
            PullRequestActions.pendingEdits(of: target, prID: "PR_1", in: items).map(\.id),
            [first.id, second.id]
        )
    }

    // Against a real outbox: the cancel is the store's own state-guarded delete.

    private let target = ConversationTarget.issueComment(databaseID: 11)

    private func edit(_ body: String, in database: DatabaseManager) async throws -> OutboxItem {
        try await PullRequestActions.write(
            .editComment(target, body: body),
            replacingEditsOf: target,
            on: summary,
            in: database
        )
    }

    private func delete(in database: DatabaseManager) async throws -> OutboxItem {
        try await PullRequestActions.write(.deleteComment(target), replacingEditsOf: target, on: summary, in: database)
    }

    func testADeleteBehindAWaitingEditIsAllThatIsSent() async throws {
        let database = try DatabaseManager.inMemory()
        _ = try await edit("Never mind.", in: database)
        let deletion = try await delete(in: database)
        let rows = try await database.allOutboxItems()
        XCTAssertEqual(rows.map(\.id), [deletion.id])
        XCTAssertEqual(rows.first?.action, .deleteComment(target))
    }

    /// An edit the drain holds may already be on GitHub; it is left alone and the delete lands
    /// after it.
    func testADeleteBehindAnEditInFlightWaitsBehindIt() async throws {
        let database = try DatabaseManager.inMemory()
        let inFlight = try await edit("Never mind.", in: database)
        _ = try await database.claimReadyOutboxItems()
        let deletion = try await delete(in: database)
        let rows = try await database.allOutboxItems()
        XCTAssertEqual(Set(rows.map(\.id)), [inFlight.id, deletion.id])
        XCTAssertEqual(rows.first { $0.id == inFlight.id }?.state, .sending)
        XCTAssertEqual(rows.first { $0.id == deletion.id }?.state, .pending)
    }

    /// An older edit in a retry's backoff would be sent after the newer one and put the replaced
    /// text back.
    func testANewerEditTakesOutAnOlderOneInBackoff() async throws {
        let database = try DatabaseManager.inMemory()
        let older = try await edit("First try.", in: database)
        _ = try await database.claimReadyOutboxItems()
        try await database.markOutboxItemFailed(id: older.id, error: "502 Bad Gateway", retriable: true)
        let newer = try await edit("Second try.", in: database)
        let rows = try await database.allOutboxItems()
        XCTAssertEqual(rows.map(\.id), [newer.id])
        XCTAssertEqual(rows.first?.action, .editComment(target, body: "Second try."))
    }

    // MARK: - What is said about it

    func testAnEditAndADeleteAreSilentUnlessTheyFail() {
        let slug = "schnaq/review#182"
        for write in [PullRequestActions.WriteKind.edit, .delete] {
            XCTAssertNil(PullRequestActions.announcement(for: .sent, of: write, slug: slug), "\(write)")
            XCTAssertNil(PullRequestActions.announcement(for: .queued, of: write, slug: slug), "\(write)")
        }
        XCTAssertEqual(
            PullRequestActions.announcement(for: .failed(reason: "Not Found"), of: .edit, slug: slug)?.message,
            "Could not edit your post on schnaq/review#182: Not Found"
        )
        XCTAssertEqual(
            PullRequestActions.announcement(
                for: .failed(reason: "Resource not accessible by integration"),
                of: .delete,
                slug: slug
            )?.message,
            "Could not delete your comment on schnaq/review#182 — it is back: Resource not accessible by integration"
        )
    }

    func testADeleteAsksNamingWhoseCommentAndFromWhen() {
        let now = Self.moment.addingTimeInterval(2 * 3_600)
        XCTAssertEqual(
            PostMenu.deleteQuestion(author: Self.author, date: Self.moment, now: now),
            "octocat wrote this comment 2 hours ago. It is deleted on GitHub, and that cannot be undone."
        )
    }
}

private extension PullRequestDetail {
    /// The detail with one thread gone, the way a re-read after its only comment was deleted reads.
    func removingThread(_ id: String) -> PullRequestDetail {
        var copy = self
        copy.threads.removeAll { $0.id == id }
        return copy
    }
}
