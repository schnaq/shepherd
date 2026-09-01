import Foundation
import GRDB
import ShepherdCore

extension DatabaseManager {
    /// Stores a review draft, replacing its inline comments.
    ///
    /// Drafts are written on every keystroke-batch by the composer, which is what makes them
    /// survive a crash or a quit (ADR 0006).
    /// - Parameter draft: The draft to store.
    public func saveDraft(_ draft: ReviewDraft) async throws {
        try await writer.write { db in
            try DatabaseManager.storeDraft(db, draft)
        }
    }

    /// Reads a review draft.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: The draft, or `nil` when none is stored.
    public func fetchDraft(prID: String) async throws -> ReviewDraft? {
        try await writer.read { db in
            try DatabaseManager.loadDraft(db, prID: prID)
        }
    }

    /// Reads several review drafts at once.
    ///
    /// Two queries for the whole set rather than two per pull request. Bulk triage has to know
    /// every existing draft before it can build its writes — a queued approval must not throw
    /// away inline comments the user wrote earlier (ADR 0015) — and a selection of thirty pull
    /// requests would otherwise be sixty trips through the pool for what is one `IN` clause.
    /// - Parameter prIDs: The pull requests to read. Duplicates and unknown ids are harmless.
    /// - Returns: The drafts that exist, keyed by pull-request node id. An id with no draft is
    ///   absent from the result rather than present and empty.
    public func fetchDrafts(prIDs: [String]) async throws -> [String: ReviewDraft] {
        let ids = Array(Set(prIDs))
        guard !ids.isEmpty else { return [:] }
        return try await writer.read { db -> [String: ReviewDraft] in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let records = try ReviewDraftRecord.fetchAll(
                db,
                sql: "SELECT * FROM review_drafts WHERE prID IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            guard !records.isEmpty else { return [:] }
            // One comment query for all of them, ordered so that grouping preserves the
            // per-draft `sortIndex` order ``loadDraft(_:prID:)`` relies on.
            let comments = try DraftCommentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM draft_comments
                    WHERE prID IN (\(placeholders))
                    ORDER BY prID ASC, sortIndex ASC
                    """,
                arguments: StatementArguments(ids)
            )
            var grouped: [String: [DraftComment]] = [:]
            for record in comments {
                grouped[record.prID, default: []].append(record.draftComment)
            }
            var drafts: [String: ReviewDraft] = [:]
            for record in records {
                drafts[record.prID] = record.reviewDraft(comments: grouped[record.prID] ?? [])
            }
            return drafts
        }
    }

    /// Deletes a review draft and its comments.
    /// - Parameter prID: The pull request's node id.
    public func deleteDraft(prID: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM review_drafts WHERE prID = ?", arguments: [prID])
            try db.execute(sql: "DELETE FROM draft_comments WHERE prID = ?", arguments: [prID])
        }
    }

    /// Adds or replaces a single inline comment inside a draft, creating the draft if needed.
    /// - Parameters:
    ///   - comment: The comment to store.
    ///   - prID: The pull request's node id.
    ///   - headRefOid: The head commit the draft is based on; used only when the draft has to
    ///     be created.
    public func upsertDraftComment(
        _ comment: DraftComment,
        prID: String,
        headRefOid: String
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            let existing = try ReviewDraftRecord.fetchOne(
                db,
                sql: "SELECT * FROM review_drafts WHERE prID = ?",
                arguments: [prID]
            )
            if existing == nil {
                try ReviewDraftRecord(
                    draft: ReviewDraft(
                        prID: prID,
                        basedOnHeadOid: headRefOid,
                        updatedAt: Date(timeIntervalSince1970: now)
                    )
                ).save(db)
            }
            let nextIndex = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM draft_comments WHERE prID = ?",
                arguments: [prID]
            ) ?? 0
            try DraftCommentRecord(
                prID: prID,
                comment: comment,
                sortIndex: nextIndex
            ).save(db)
            try db.execute(
                sql: "UPDATE review_drafts SET updatedAt = ? WHERE prID = ?",
                arguments: [now, prID]
            )
        }
    }

    /// Removes a single inline comment from a draft.
    /// - Parameter localID: The comment's local identity.
    public func deleteDraftComment(localID: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM draft_comments WHERE localID = ?",
                arguments: [localID.uuidString]
            )
        }
    }

    /// Every pull request that currently has a draft. Drives the "pending review" badge.
    public func pullRequestIDsWithDrafts() async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(db, sql: "SELECT prID FROM review_drafts ORDER BY updatedAt DESC")
        }
    }

    /// The synchronous body of ``saveDraft(_:)``.
    ///
    /// Separate so a batched write can reuse it *inside* one transaction
    /// (``saveBulkTriage(writes:)``) instead of opening its own per draft.
    /// - Parameters:
    ///   - db: The open database.
    ///   - draft: The draft to store.
    static func storeDraft(_ db: Database, _ draft: ReviewDraft) throws {
        try ReviewDraftRecord(draft: draft).save(db)
        try db.execute(
            sql: "DELETE FROM draft_comments WHERE prID = ?",
            arguments: [draft.prID]
        )
        for (index, comment) in draft.comments.enumerated() {
            try DraftCommentRecord(
                prID: draft.prID,
                comment: comment,
                sortIndex: index
            ).save(db)
        }
    }

    /// The draft query, shared by ``fetchDraft(prID:)`` and ``observeDraft(prID:)``.
    static func loadDraft(_ db: Database, prID: String) throws -> ReviewDraft? {
        guard let record = try ReviewDraftRecord.fetchOne(
            db,
            sql: "SELECT * FROM review_drafts WHERE prID = ?",
            arguments: [prID]
        ) else { return nil }
        let comments = try DraftCommentRecord.fetchAll(
            db,
            sql: "SELECT * FROM draft_comments WHERE prID = ? ORDER BY sortIndex ASC",
            arguments: [prID]
        )
        return record.reviewDraft(comments: comments.map(\.draftComment))
    }
}
