import Foundation
import GRDB
import ShepherdCore

extension DatabaseManager {
    // MARK: - Issue index rows (ADR 0032)

    /// Reads the whole issue search index.
    ///
    /// The whole of it, on purpose, for ``searchIndexEntries()``'s reason: it is one small row
    /// per issue in the local inbox — hundreds at most — and the coordinator needs every hash to
    /// work out what has to be redone. A query that returned "just the stale ones" would have to
    /// know what stale means, which is the pure ``ShepherdCore/IssueSearchDocument``'s job.
    /// - Returns: The entries, newest first.
    public func issueSearchIndexEntries() async throws -> [IssueSearchIndexEntry] {
        try await writer.read { db in
            try IssueSearchIndexRecord
                .fetchAll(db, sql: "SELECT * FROM issue_search_index ORDER BY indexedAt DESC")
                .map(\.entry)
        }
    }

    /// Writes issue index rows, replacing any that exist.
    ///
    /// One transaction for the batch, and a row whose issue has meanwhile left the inbox is
    /// **skipped rather than failing the batch** — both for the reasons
    /// ``saveSearchIndexEntries(_:)`` gives: indexing walks the inbox in batches of tiny writes,
    /// and the honest reading of the foreign key's refusal is "the sweep pruned this issue while
    /// we were embedding it", which is not an error.
    /// - Parameter entries: The rows to write.
    /// - Throws: A `DatabaseError` when the transaction cannot be committed.
    public func saveIssueSearchIndexEntries(_ entries: [IssueSearchIndexEntry]) async throws {
        guard !entries.isEmpty else { return }
        let records = entries.map { IssueSearchIndexRecord(entry: $0) }
        try await writer.write { db in
            for record in records {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM issues WHERE id = ?)",
                    arguments: [record.issueID]
                ) ?? false
                guard exists else { continue }
                try record.save(db)
            }
        }
    }

    /// Deletes issue index rows by issue id.
    ///
    /// Not the ordinary pruning path — that is the `ON DELETE CASCADE` in the v7 migration, which
    /// happens in the sweep's own transaction. This is for the two cases the cascade cannot
    /// cover: *Rebuild index* in Settings, and an entry whose model identifier no longer matches.
    /// - Parameter issueIDs: The issues whose rows go.
    public func deleteIssueSearchIndexEntries(issueIDs: [String]) async throws {
        guard !issueIDs.isEmpty else { return }
        try await writer.write { db in
            let placeholders = Array(repeating: "?", count: issueIDs.count).joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM issue_search_index WHERE issueID IN (\(placeholders))",
                arguments: StatementArguments(issueIDs)
            )
        }
    }

    /// Empties the issue search index. The issues half of *Rebuild index*.
    public func clearIssueSearchIndex() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM issue_search_index")
        }
    }

    /// Measures the issue index.
    ///
    /// Reported through ``SearchIndexStatistics``, the same value the pull-request index uses:
    /// the question Settings asks is "how much of my disk is this", and two identical types would
    /// only make the one line that adds them up harder to write.
    /// - Returns: Row and byte counts plus the newest write, or zeroes for an empty index.
    public func issueSearchIndexStatistics() async throws -> SearchIndexStatistics {
        try await writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        COUNT(*) AS entryCount,
                        COALESCE(SUM(CASE WHEN vector IS NULL THEN 0 ELSE 1 END), 0) AS vectorCount,
                        COALESCE(SUM(LENGTH(vector)), 0) AS byteCount,
                        MAX(indexedAt) AS lastIndexedAt
                    FROM issue_search_index
                    """
            ) else { return SearchIndexStatistics() }
            // Each column bound with an explicit type, for ``searchIndexStatistics()``'s reason:
            // `Row`'s subscript is generic over every `DatabaseValueConvertible`, and letting
            // inference run through defaulted optionals inside an initialiser call is the
            // expression shape that makes the type-checker slow.
            let entryCount: Int = row["entryCount"] ?? 0
            let vectorCount: Int = row["vectorCount"] ?? 0
            let byteCount: Int = row["byteCount"] ?? 0
            let last: Double? = row["lastIndexedAt"]
            return SearchIndexStatistics(
                entryCount: entryCount,
                vectorCount: vectorCount,
                vectorByteCount: byteCount,
                lastIndexedAt: last.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    // MARK: - Sources

    /// Reads the raw material for the search documents of some issues.
    ///
    /// By id and in batches, like ``searchIndexSources(prIDs:)`` — although the reason is weaker
    /// here, because an issue body is capped by what a human typed rather than by a generated
    /// diff. The shape is kept identical anyway so the coordinator runs both passes off one loop.
    /// - Parameter issueIDs: The issues to read. Unknown ids are absent from the result.
    /// - Returns: One source per issue that exists, in the order the ids were given.
    public func issueSearchIndexSources(
        issueIDs: [String]
    ) async throws -> [IssueSearchIndexSource] {
        let ids = Array(Set(issueIDs))
        guard !ids.isEmpty else { return [] }
        let sources = try await writer.read { db -> [String: IssueSearchIndexSource] in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let records = try IssueRecord.fetchAll(
                db,
                sql: "SELECT * FROM issues WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            var result: [String: IssueSearchIndexSource] = [:]
            for record in records {
                // The links are deliberately not read: no field of the document is built from
                // them, and a search that ranked an issue on its linked pull requests' titles
                // would answer a query about one row with another row's words.
                result[record.id] = IssueSearchIndexSource(
                    summary: record.summary(),
                    bodyMarkdown: record.bodyMarkdown ?? "",
                    detailFetchedAt: record.detailFetchedAt
                        .map { Date(timeIntervalSince1970: $0) }
                )
            }
            return result
        }
        return issueIDs.compactMap { sources[$0] }
    }

    /// When each cached issue's detail was last fetched.
    ///
    /// The cheap half of ``ShepherdCore/IssueSearchDocument/fingerprint(for:)``: everything else
    /// in the fingerprint is already in the rows the app holds in memory, and this one column is
    /// what turns "somebody opened this issue, so there is a body now" into a re-read without any
    /// code path having to announce it.
    /// - Returns: The timestamps, keyed by node id. Issues with no detail fetch are absent.
    public func issueDetailFetchTimestamps() async throws -> [String: Date] {
        try await writer.read { db in
            var result: [String: Date] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, detailFetchedAt FROM issues WHERE detailFetchedAt IS NOT NULL"
            )
            for row in rows {
                guard let id: String = row["id"], let stamp: Double = row["detailFetchedAt"] else {
                    continue
                }
                result[id] = Date(timeIntervalSince1970: stamp)
            }
            return result
        }
    }
}
