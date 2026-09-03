import Foundation
import GRDB
import ShepherdCore

extension DatabaseManager {
    // MARK: - Writing

    /// Writes a snapshot, replacing the one for the same head if it exists.
    ///
    /// A snapshot whose pull request has meanwhile left the inbox is **skipped rather than
    /// failing the write**: the foreign key would refuse it, and the honest reading of that
    /// refusal is "the sweep pruned this pull request while the review was in the outbox",
    /// which is not an error.
    /// - Parameter snapshot: The snapshot to store.
    /// - Returns: `true` when a row was written.
    /// - Throws: A `DatabaseError` when the write fails.
    @discardableResult
    public func saveReviewSnapshot(_ snapshot: ReviewSnapshot) async throws -> Bool {
        guard !snapshot.reviewedHeadOid.isEmpty else { return false }
        let record = ReviewSnapshotRecord(snapshot: snapshot)
        return try await writer.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM pull_requests WHERE id = ?)",
                arguments: [record.prID]
            ) ?? false
            guard exists else { return false }
            try record.save(db)
            return true
        }
    }

    /// Snapshots the pull request's current `changed_files` rows as the head that was reviewed.
    ///
    /// This is the outbox drain's hook (ADR 0028): the moment a `submitReview` mutation is
    /// acknowledged is the one moment Shepherd knows which head a review was written against,
    /// and the patches of that head are what the interdiff needs later — GitHub cannot be asked
    /// for them again once the branch has been force-pushed.
    ///
    /// Read and write happen in **one** transaction so a detail fetch landing at the same
    /// moment cannot contribute half of one round and half of the next.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - reviewedHeadOid: The head commit the review was made against.
    ///   - reviewedAt: When the review was submitted.
    /// - Returns: `true` when a row was written; `false` when the pull request is gone or has
    ///   no cached files to snapshot.
    /// - Throws: A `DatabaseError` when the transaction cannot be committed.
    @discardableResult
    public func captureReviewSnapshot(
        prID: String,
        reviewedHeadOid: String,
        reviewedAt: Date
    ) async throws -> Bool {
        guard !reviewedHeadOid.isEmpty else { return false }
        return try await writer.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM pull_requests WHERE id = ?)",
                arguments: [prID]
            ) ?? false
            guard exists else { return false }
            let files = try ChangedFileRecord
                .fetchAll(
                    db,
                    sql: "SELECT * FROM changed_files WHERE prID = ? ORDER BY sortIndex ASC",
                    arguments: [prID]
                )
                .map(\.changedFile)
            // Nothing to compare against later, so nothing is claimed: a review submitted
            // before any detail fetch has stored a diff leaves no baseline behind, and the
            // review screen shows no tab rather than an empty one.
            guard !files.isEmpty else { return false }
            let snapshot = ReviewSnapshot(
                prID: prID,
                reviewedHeadOid: reviewedHeadOid,
                reviewedAt: reviewedAt,
                files: files
            )
            try ReviewSnapshotRecord(snapshot: snapshot).save(db)
            return true
        }
    }

    // MARK: - Reading

    /// The newest snapshot of a pull request, if there is one.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: The snapshot of the most recently reviewed head, or `nil`.
    /// - Throws: A `DatabaseError` when the read fails.
    public func latestReviewSnapshot(prID: String) async throws -> ReviewSnapshot? {
        try await writer.read { db in
            try ReviewSnapshotRecord
                .fetchOne(
                    db,
                    sql: """
                        SELECT * FROM review_snapshots
                        WHERE prID = ?
                        ORDER BY reviewedAt DESC
                        LIMIT 1
                        """,
                    arguments: [prID]
                )?
                .snapshot
        }
    }

    /// Whether a snapshot for one reviewed head exists.
    ///
    /// The retroactive path's gate: a review Shepherd did not send itself may only become a
    /// baseline when there is no baseline for that head yet.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - reviewedHeadOid: The head commit.
    /// - Returns: `true` when the row is there.
    /// - Throws: A `DatabaseError` when the read fails.
    public func hasReviewSnapshot(prID: String, reviewedHeadOid: String) async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM review_snapshots WHERE prID = ? AND reviewedHeadOid = ?
                    )
                    """,
                arguments: [prID, reviewedHeadOid]
            ) ?? false
        }
    }

    /// How many rounds of this pull request have been reviewed on this Mac.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: The number of stored snapshots.
    /// - Throws: A `DatabaseError` when the read fails.
    public func reviewSnapshotCount(prID: String) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_snapshots WHERE prID = ?",
                arguments: [prID]
            ) ?? 0
        }
    }

    /// The round counts of several pull requests, in one query.
    ///
    /// What the inbox reads: one grouped `SELECT` for the whole list rather than one query per
    /// row, and pull requests with no snapshot are simply absent from the result.
    /// - Parameter prIDs: The pull requests to count.
    /// - Returns: The counts, keyed by node id.
    /// - Throws: A `DatabaseError` when the read fails.
    public func reviewSnapshotCounts(prIDs: [String]) async throws -> [String: Int] {
        let ids = Array(Set(prIDs))
        guard !ids.isEmpty else { return [:] }
        return try await writer.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT prID, COUNT(*) AS roundCount FROM review_snapshots
                    WHERE prID IN (\(placeholders))
                    GROUP BY prID
                    """,
                arguments: StatementArguments(ids)
            )
            var result: [String: Int] = [:]
            for row in rows {
                let id: String = row["prID"]
                let count: Int = row["roundCount"]
                result[id] = count
            }
            return result
        }
    }

    // MARK: - Deleting

    /// Deletes every snapshot of a pull request.
    ///
    /// Not the ordinary pruning path — that is the `ON DELETE CASCADE` in the v5 migration,
    /// which happens inside the sweep's own transaction. This is for the case the cascade cannot
    /// cover: a reviewer who wants the baseline forgotten while the pull request stays open.
    /// - Parameter prID: The pull request whose snapshots go.
    /// - Throws: A `DatabaseError` when the write fails.
    public func deleteReviewSnapshots(prID: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM review_snapshots WHERE prID = ?",
                arguments: [prID]
            )
        }
    }
}
