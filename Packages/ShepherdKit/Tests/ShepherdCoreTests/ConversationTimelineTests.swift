import Foundation
import XCTest
@testable import ShepherdCore

final class ConversationTimelineTests: XCTestCase {
    private let alice = Fixtures.makeActor("alice")
    private let bob = Fixtures.makeActor("bob")

    private func comment(_ id: String, at offset: TimeInterval) -> ConversationItem {
        .comment(ConversationComment(id: id, author: alice, bodyMarkdown: id, createdAt: Fixtures.date(offset)))
    }

    private func review(
        _ id: String,
        at offset: TimeInterval,
        state: ConversationReview.State = .commented,
        body: String = "Looks fine."
    ) -> ConversationItem {
        .review(ConversationReview(id: id, author: bob, state: state, bodyMarkdown: body, createdAt: Fixtures.date(offset)))
    }

    private func thread(_ id: String, review reviewID: String?, at offset: TimeInterval) -> ReviewThread {
        ReviewThread(
            id: id,
            path: "Sources/App.swift",
            line: 12,
            comments: [
                ReviewComment(
                    id: "\(id)-c1",
                    author: bob,
                    bodyMarkdown: "Why?",
                    createdAt: Fixtures.date(offset),
                    reviewID: reviewID
                ),
            ]
        )
    }

    private func commit(_ oid: String, at offset: TimeInterval) -> CommitInfo {
        CommitInfo(oid: oid, messageHeadline: oid, author: alice, committedDate: Fixtures.date(offset))
    }

    private func ids(_ entries: [ConversationEntry]) -> [String] {
        entries.map(\.id)
    }

    func testThreadsHangUnderTheReviewThatStartedThem() {
        let conversation = PullRequestConversation(items: [review("R1", at: 10), comment("C1", at: 20)])
        let entries = ConversationTimeline.entries(
            conversation: conversation,
            commits: [],
            threads: [thread("T1", review: "R1", at: 9), thread("T2", review: "R1", at: 9)]
        )

        XCTAssertEqual(ids(entries), ["review:R1", "comment:C1"])
        guard case .review(_, let threads) = entries.first else { return XCTFail("expected the review first") }
        XCTAssertEqual(threads.map(\.id), ["T1", "T2"], "in the order GitHub listed the threads")
    }

    func testAThreadWhoseReviewIsNotInTheTimelineStandsAloneAtItsFirstComment() {
        let conversation = PullRequestConversation(items: [comment("C1", at: 10), comment("C2", at: 30)])
        let entries = ConversationTimeline.entries(
            conversation: conversation,
            commits: [],
            threads: [thread("T1", review: "R-missing", at: 20), thread("T2", review: nil, at: 40)]
        )

        XCTAssertEqual(ids(entries), ["comment:C1", "thread:T1", "comment:C2", "thread:T2"])
    }

    func testConsecutiveCommitsAreOneGroupAndInterleaveByDate() {
        let conversation = PullRequestConversation(items: [comment("C1", at: 30)])
        let entries = ConversationTimeline.entries(
            conversation: conversation,
            commits: [commit("a1", at: 10), commit("a2", at: 20), commit("a3", at: 40)],
            threads: []
        )

        XCTAssertEqual(entries.count, 3)
        guard case .commits(let first) = entries[0], case .commits(let last) = entries[2] else {
            return XCTFail("expected commit groups around the comment, got \(ids(entries))")
        }
        XCTAssertEqual(first.map(\.oid), ["a1", "a2"])
        XCTAssertEqual(entries[1].id, "comment:C1")
        XCTAssertEqual(last.map(\.oid), ["a3"])
    }

    func testAWordlessCommentReviewWithoutThreadsIsLeftOutButAVerdictIsKept() {
        let conversation = PullRequestConversation(items: [
            review("R1", at: 10, state: .commented, body: ""),
            review("R2", at: 20, state: .approved, body: ""),
            review("R3", at: 30, state: .commented, body: "  \n"),
        ])
        let entries = ConversationTimeline.entries(
            conversation: conversation,
            commits: [],
            threads: [thread("T1", review: "R3", at: 29)]
        )

        XCTAssertEqual(ids(entries), ["review:R2", "review:R3"], "R3 is kept for the thread it started")
    }

    func testWithoutAConversationTheCommitsAndEveryThreadAreStillShown() {
        let entries = ConversationTimeline.entries(
            conversation: nil,
            commits: [commit("a1", at: 10)],
            threads: [thread("T1", review: "R1", at: 20)]
        )

        XCTAssertEqual(ids(entries), ["commits:a1", "thread:T1"])
    }

    func testACutConversationDropsWhatIsOlderThanItsFirstItem() {
        let conversation = PullRequestConversation(items: [comment("C1", at: 50)], hasEarlierItems: true)
        let entries = ConversationTimeline.entries(
            conversation: conversation,
            commits: [commit("old", at: 10), commit("new", at: 60)],
            threads: [thread("T-old", review: nil, at: 20)]
        )

        XCTAssertEqual(ids(entries), ["comment:C1", "commits:new"])
    }

    func testGitHubsOrderOfItemsIsKeptWhenTheirDatesDisagree() {
        // A review is dated by its submission, and GitHub may list it before a comment written in
        // between: the timeline's own order wins, and nothing is re-sorted inside it.
        let conversation = PullRequestConversation(items: [review("R1", at: 30), comment("C1", at: 20)])
        let entries = ConversationTimeline.entries(conversation: conversation, commits: [], threads: [])

        XCTAssertEqual(ids(entries), ["review:R1", "comment:C1"])
    }

    func testAThreadWithoutCommentsIsNotDrawn() {
        let empty = ReviewThread(id: "T0", path: "a.swift", line: 1, comments: [])
        let entries = ConversationTimeline.entries(conversation: nil, commits: [], threads: [empty])

        XCTAssertTrue(entries.isEmpty)
    }
}
