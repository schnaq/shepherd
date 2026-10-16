import Foundation
import GRDB
import ShepherdCore
import XCTest
@testable import ShepherdPersistence

/// The store side of ADR 0043: the conversation document in `pull_request_conversations` and the
/// review comment's extra columns, written by `savePullRequestDetail` and read back by both detail
/// reads.
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

    /// Most comments carry no reaction, and `[]` written out for each of them is a column of
    /// noise; `NULL` reads back as the same empty list.
    func testACommentWithoutReactionsStoresNull() async throws {
        let database = try DatabaseManager.inMemory()
        var detail = Self.detail()
        detail.threads[0].comments[0].reactions = []
        try await database.savePullRequestDetail(detail)

        let nullRows = try await database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_comments WHERE id = 'PRRC_1' AND reactionsJSON IS NULL"
            )
        }
        XCTAssertEqual(nullRows, 1, "NULL, not \"[]\"")
        let fetched = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(fetched?.threads.first?.comments.first?.reactions, [])
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

    func testTheObservationFiresWhenOnlyTheConversationRowChanges() async throws {
        let database = try DatabaseManager.inMemory()
        let detail = Self.detail()
        try await database.savePullRequestDetail(detail)

        var iterator = database.observePullRequestDetail(prID: detail.id).makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first??.conversation, Self.conversation())

        // Straight into the table rather than through `savePullRequestDetail`, which would
        // rewrite the `pull_requests` row too and fire the observation for that reason alone.
        var changed = Self.conversation()
        changed.viewerCanReact = false
        let json = ColumnCoding.encodeJSON(changed)
        let prID = detail.id
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE pull_request_conversations SET json = ? WHERE prID = ?",
                arguments: [json, prID]
            )
        }

        let second = await iterator.next()
        XCTAssertEqual(second??.conversation, changed)
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

        // The sweep rewrites the `pull_requests` row from a search result. The conversation sits
        // in a table of its own, so there is nothing to carry forward: the upsert has to neither
        // touch it nor cascade it away.
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

    func testADocumentThisBuildCannotDecodeReadsAsUnknownAndDoesNotFailTheFetch() async throws {
        let database = try DatabaseManager.inMemory()
        let detail = Self.detail()
        try await database.savePullRequestDetail(detail)

        // A document from a build whose model differed, or a damaged one.
        let id = detail.id
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE pull_request_conversations SET json = ? WHERE prID = ?",
                arguments: [#"{"items": 7}"#, id]
            )
        }

        let fetched = try await database.fetchPullRequestDetail(id: id)
        XCTAssertNil(fetched?.conversation, "unknown, which is not an empty conversation")
        XCTAssertEqual(fetched?.threads, detail.threads, "and the rest of the detail still loads")
    }

    // MARK: - The cascade

    func testTheConversationLeavesWithItsPullRequest() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestDetail(Self.detail())
        let before = try await conversationRowCount(database)
        XCTAssertEqual(before, 1)

        // The pull request was merged, so the next sweep prunes it, and the row goes with it.
        try await database.savePullRequestSummaries([])

        let after = try await conversationRowCount(database)
        XCTAssertEqual(after, 0)
    }

    func testErasingEverythingEmptiesTheConversationTable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestDetail(Self.detail())

        try await database.eraseAllData()

        let remaining = try await conversationRowCount(database)
        XCTAssertEqual(remaining, 0)
    }

    private func conversationRowCount(_ database: DatabaseManager) async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pull_request_conversations") ?? -1
        }
    }

    // MARK: - The upgrade

    func testV11AddsTheTableAndTheCommentColumnsAndOldRowsReadBackWithoutThem() async throws {
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

        // The document is a table of its own, not a column of `pull_requests`: the inbox reads
        // every row of that table whole, on every observation.
        try await database.writer.read { db in
            let pullRequestColumns = try db.columns(in: "pull_requests").map(\.name)
            XCTAssertFalse(pullRequestColumns.contains("conversationJSON"))

            let columns = try db.columns(in: "pull_request_conversations")
            XCTAssertEqual(columns.map(\.name), ["prID", "json"])
            XCTAssertEqual(columns.last?.type, "TEXT")
            XCTAssertEqual(columns.last?.isNotNull, true)
            XCTAssertEqual(try db.primaryKey("pull_request_conversations").columns, ["prID"])

            let parents = try String.fetchAll(
                db,
                sql: """
                    SELECT "table" FROM pragma_foreign_key_list('pull_request_conversations')
                    """
            )
            XCTAssertEqual(parents, ["pull_requests"])
            let onDelete = try String.fetchAll(
                db,
                sql: "SELECT on_delete FROM pragma_foreign_key_list('pull_request_conversations')"
            )
            XCTAssertEqual(onDelete, ["CASCADE"], "pruned with its pull request")
        }

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
