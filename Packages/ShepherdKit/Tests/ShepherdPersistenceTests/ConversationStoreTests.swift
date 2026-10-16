import Foundation
import GRDB
import ShepherdCore
import XCTest
@testable import ShepherdPersistence

/// The store side of ADR 0043: the conversation document on `pull_requests` and the review
/// comment's extra columns, written by `savePullRequestDetail` and read back by both detail reads.
final class ConversationStoreTests: XCTestCase {
    // MARK: - Fixtures

    /// One of every kind of item, so a round trip that drops a kind shows.
    private static func conversation() -> PullRequestConversation {
        PullRequestConversation(
            descriptionReactions: [ReactionGroup(content: .heart, count: 2, viewerHasReacted: true)],
            isDescriptionEdited: true,
            viewerCanUpdateDescription: true,
            viewerCanReact: true,
            items: [
                .event(
                    ConversationEventItem(
                        id: "LE_1",
                        createdAt: PersistenceFixtures.date(-1_000),
                        actor: PersistenceFixtures.humanActor(),
                        event: .labeled(name: "agent", color: "0e8a16")
                    )
                ),
                .review(
                    ConversationReview(
                        id: "PRR_1",
                        databaseID: 5_001,
                        author: PersistenceFixtures.agentActor(),
                        state: .changesRequested,
                        bodyMarkdown: "Please fix the token handling.",
                        createdAt: PersistenceFixtures.date(-900),
                        isEdited: true,
                        url: URL(string: "https://github.com/schnaq/review/pull/128#pullrequestreview-5001"),
                        reactions: [ReactionGroup(content: .eyes, count: 1)],
                        viewerCanUpdate: true,
                        commitOid: "abc123"
                    )
                ),
                .comment(
                    ConversationComment(
                        id: "IC_1",
                        databaseID: 4_001,
                        author: PersistenceFixtures.humanActor("hubot"),
                        bodyMarkdown: "Looks good to me.",
                        createdAt: PersistenceFixtures.date(-800),
                        isEdited: true,
                        url: URL(string: "https://github.com/schnaq/review/pull/128#issuecomment-4001"),
                        reactions: [ReactionGroup(content: .thumbsUp, count: 1)],
                        viewerCanUpdate: true,
                        viewerCanDelete: true,
                        isMinimized: true,
                        minimizedReason: "off-topic"
                    )
                ),
            ],
            hasEarlierItems: true
        )
    }

    /// A review comment with every ADR 0043 extra set to something other than its default.
    private static func richComment() -> ReviewComment {
        ReviewComment(
            id: "PRRC_1",
            databaseID: 987_654_321,
            author: PersistenceFixtures.humanActor(),
            bodyMarkdown: "This should not force-unwrap.",
            createdAt: PersistenceFixtures.date(-900),
            reviewID: "PRR_1",
            reactions: [
                ReactionGroup(content: .thumbsUp, count: 3, viewerHasReacted: true),
                ReactionGroup(content: .eyes, count: 1),
            ],
            viewerCanUpdate: true,
            viewerCanDelete: true,
            isEdited: true,
            url: URL(string: "https://github.com/schnaq/review/pull/128#discussion_r987654321")
        )
    }

    /// The shared fixture detail, carrying the conversation and the rich comment.
    private static func detail() -> PullRequestDetail {
        var detail = PersistenceFixtures.detail()
        detail.conversation = conversation()
        detail.threads[0].comments[0] = richComment()
        return detail
    }

    // MARK: - Round trip

    func testADetailRoundTripsItsConversationAndTheCommentExtras() async throws {
        let database = try DatabaseManager.inMemory()
        let saved = Self.detail()
        try await database.savePullRequestDetail(saved)

        let fetched = try await database.fetchPullRequestDetail(id: saved.id)
        XCTAssertEqual(fetched?.conversation, saved.conversation)
        XCTAssertEqual(fetched?.threads.first?.comments.first, Self.richComment())
        XCTAssertEqual(fetched, saved, "and nothing else moved")
    }

    func testTheObservationCarriesTheConversationAndTheCommentExtrasToo() async throws {
        let database = try DatabaseManager.inMemory()
        let saved = Self.detail()
        try await database.savePullRequestDetail(saved)

        var iterator = database.observePullRequestDetail(prID: saved.id).makeAsyncIterator()
        let observed = await iterator.next()
        XCTAssertEqual(observed??.conversation, saved.conversation)
        XCTAssertEqual(observed??.threads.first?.comments.first, Self.richComment())
    }

    // MARK: - Unknown is not empty

    func testADetailWithoutAConversationKeepsTheStoredOne() async throws {
        let database = try DatabaseManager.inMemory()
        var detail = Self.detail()
        try await database.savePullRequestDetail(detail)

        // A read that failed or was not made: `nil` is "unknown", and unknown never overwrites.
        detail.conversation = nil
        try await database.savePullRequestDetail(detail)

        let fetched = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(fetched?.conversation, Self.conversation())
    }

    func testASweepUpsertKeepsTheConversation() async throws {
        let database = try DatabaseManager.inMemory()
        let detail = Self.detail()
        try await database.savePullRequestDetail(detail)

        // The sweep rewrites the row from a search result, which carries no detail columns.
        var swept = detail.summary
        swept.title = "Refactor the token store, again"
        try await database.savePullRequestSummaries([swept])

        let fetched = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(fetched?.summary.title, swept.title, "the row really was rewritten")
        XCTAssertEqual(fetched?.conversation, Self.conversation())
    }

    func testAnEmptyConversationIsStoredAsEmptyNotAsUnknown() async throws {
        let database = try DatabaseManager.inMemory()
        var detail = Self.detail()
        try await database.savePullRequestDetail(detail)

        // GitHub answered, and the answer is "nothing": that replaces what was stored.
        detail.conversation = PullRequestConversation()
        try await database.savePullRequestDetail(detail)

        let fetched = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(fetched?.conversation, PullRequestConversation())
    }

    // MARK: - The upgrade

    func testV11AddsTheColumnsAndRowsStoredBeforeItReadBackWithoutThem() async throws {
        // A database migrated only as far as v10, holding a pull request, a thread and a comment
        // an older build stored.
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v10")
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO repos (fullName, owner, name) VALUES ('schnaq/review', 'schnaq', 'review')")
            try db.execute(
                sql: """
                    INSERT INTO pull_requests (id, repoFullName, number, title, authorLogin,
                        authorKind, createdAt, updatedAt, isDraft, additions, deletions,
                        changedFiles, headRefName, headRefOid, baseRefName, checkTotal,
                        checkSuccess, checkFailure, checkPending, relations, labels, mergeable)
                    VALUES ('PR_old', 'schnaq/review', 7, 'Old row', 'octocat', 'human', 0, 0, 0,
                        1, 1, 1, 'fix', 'abc', 'main', 0, 0, 0, 0, '[]', '[]', 'mergeable')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO review_threads (id, prID, path, line, side, isResolved, isOutdated,
                        sortIndex)
                    VALUES ('PRRT_old', 'PR_old', 'a.swift', 3, 'RIGHT', 0, 0, 0)
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO review_comments (id, threadID, authorLogin, authorKind,
                        bodyMarkdown, createdAt, sortIndex)
                    VALUES ('PRRC_old', 'PRRT_old', 'octocat', 'human', 'An old comment', 0, 0)
                    """
            )
        }

        let database = try DatabaseManager(writer: queue)

        let pullRequestColumns = try await database.writer.read { db in
            try db.columns(in: "pull_requests")
        }
        let document = try XCTUnwrap(pullRequestColumns.first { $0.name == "conversationJSON" })
        XCTAssertEqual(document.type, "TEXT")
        XCTAssertFalse(document.isNotNull, "additive: no existing row has a conversation")

        let commentColumns = try await database.writer.read { db in
            try db.columns(in: "review_comments")
        }
        let expected = [
            "reviewID": "TEXT", "reactionsJSON": "TEXT", "url": "TEXT",
            "viewerCanUpdate": "INTEGER", "viewerCanDelete": "INTEGER", "isEdited": "INTEGER",
        ]
        for (name, type) in expected {
            let column = try XCTUnwrap(commentColumns.first { $0.name == name }, name)
            XCTAssertEqual(column.type, type, name)
        }
        for name in ["viewerCanUpdate", "viewerCanDelete", "isEdited"] {
            let column = try XCTUnwrap(commentColumns.first { $0.name == name }, name)
            XCTAssertTrue(column.isNotNull, name)
            XCTAssertEqual(column.defaultValueSQL, "0", "an old comment is not editable (\(name))")
        }

        let fetched = try await database.fetchPullRequestDetail(id: "PR_old")
        XCTAssertNil(fetched?.conversation, "never read is unknown, not empty")
        let comment = try XCTUnwrap(fetched?.threads.first?.comments.first)
        XCTAssertEqual(comment.bodyMarkdown, "An old comment")
        XCTAssertNil(comment.reviewID)
        XCTAssertEqual(comment.reactions, [])
        XCTAssertFalse(comment.viewerCanUpdate)
        XCTAssertFalse(comment.viewerCanDelete)
        XCTAssertFalse(comment.isEdited)
        XCTAssertNil(comment.url)
    }
}
