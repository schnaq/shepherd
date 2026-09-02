import Foundation
import GRDB
import ShepherdCore

/// What the semantic search index currently holds, for the one line Settings shows (ADR 0019).
///
/// Computed by SQL rather than by counting an in-memory corpus, because the question the user is
/// asking is "how much of my disk is this", and the answer to that is what is on disk.
public struct SearchIndexStatistics: Sendable, Hashable {
    /// How many pull requests have an index row.
    public var entryCount: Int
    /// How many of those rows carry an embedding.
    ///
    /// Reported apart from ``entryCount`` because the difference between them is exactly the
    /// state Settings has to be able to explain: rows without a vector are pull requests that
    /// were indexed while the on-device model was unavailable.
    public var vectorCount: Int
    /// How many bytes of vector are stored.
    public var vectorByteCount: Int
    /// When the most recent row was written.
    public var lastIndexedAt: Date?

    /// Creates a statistics value.
    /// - Parameters:
    ///   - entryCount: Row count.
    ///   - vectorCount: How many rows carry a vector.
    ///   - vectorByteCount: Total vector bytes.
    ///   - lastIndexedAt: The newest `indexedAt`.
    public init(
        entryCount: Int = 0,
        vectorCount: Int = 0,
        vectorByteCount: Int = 0,
        lastIndexedAt: Date? = nil
    ) {
        self.entryCount = entryCount
        self.vectorCount = vectorCount
        self.vectorByteCount = vectorByteCount
        self.lastIndexedAt = lastIndexedAt
    }
}

extension DatabaseManager {
    // MARK: - Index rows

    /// Reads the whole search index.
    ///
    /// The whole of it, on purpose: it is one small row per pull request in the local inbox —
    /// hundreds at most (ADR 0019) — and the coordinator needs every hash to work out what has to
    /// be redone. A query that returned "just the stale ones" would have to know what stale means,
    /// which is the pure ``ShepherdCore/SearchDocument``'s job.
    /// - Returns: The entries, newest first.
    public func searchIndexEntries() async throws -> [SearchIndexEntry] {
        try await writer.read { db in
            try SearchIndexRecord
                .fetchAll(db, sql: "SELECT * FROM search_index ORDER BY indexedAt DESC")
                .map(\.entry)
        }
    }

    /// Writes index rows, replacing any that exist.
    ///
    /// One transaction for the batch, for ``saveBulkTriage(writes:)``'s reason: indexing walks the
    /// inbox in batches and each row is a tiny write, so a transaction per row would mean one
    /// `fsync` per pull request for work nobody is waiting on.
    ///
    /// A row whose pull request has meanwhile left the inbox is **skipped rather than failing the
    /// batch**: the foreign key would refuse it, and the honest reading of that refusal is "the
    /// sweep pruned this pull request while we were embedding it", which is not an error.
    /// - Parameter entries: The rows to write.
    /// - Throws: A `DatabaseError` when the transaction cannot be committed.
    public func saveSearchIndexEntries(_ entries: [SearchIndexEntry]) async throws {
        guard !entries.isEmpty else { return }
        let records = entries.map { SearchIndexRecord(entry: $0) }
        try await writer.write { db in
            for record in records {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM pull_requests WHERE id = ?)",
                    arguments: [record.prID]
                ) ?? false
                guard exists else { continue }
                try record.save(db)
            }
        }
    }

    /// Deletes index rows by pull-request id.
    ///
    /// Not the ordinary pruning path — that is the `ON DELETE CASCADE` in the v3 migration, which
    /// happens in the sweep's own transaction. This is for the two cases the cascade cannot cover:
    /// *Rebuild index* in Settings, and an entry whose model identifier no longer matches.
    /// - Parameter prIDs: The pull requests whose rows go.
    public func deleteSearchIndexEntries(prIDs: [String]) async throws {
        guard !prIDs.isEmpty else { return }
        try await writer.write { db in
            let placeholders = Array(repeating: "?", count: prIDs.count).joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM search_index WHERE prID IN (\(placeholders))",
                arguments: StatementArguments(prIDs)
            )
        }
    }

    /// Empties the search index. Backs *Rebuild index*.
    public func clearSearchIndex() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM search_index")
        }
    }

    /// Measures the index.
    /// - Returns: Row and byte counts plus the newest write, or zeroes for an empty index.
    public func searchIndexStatistics() async throws -> SearchIndexStatistics {
        try await writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        COUNT(*) AS entryCount,
                        COALESCE(SUM(CASE WHEN vector IS NULL THEN 0 ELSE 1 END), 0) AS vectorCount,
                        COALESCE(SUM(LENGTH(vector)), 0) AS byteCount,
                        MAX(indexedAt) AS lastIndexedAt
                    FROM search_index
                    """
            ) else { return SearchIndexStatistics() }
            // Each column bound with an explicit type: `Row`'s subscript is generic over every
            // `DatabaseValueConvertible`, and letting the inference run through three defaulted
            // optionals inside an initialiser call is exactly the expression shape that makes the
            // type-checker slow (and, on a bad day, ambiguous).
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

    /// Reads the raw material for the search documents of some pull requests.
    ///
    /// Deliberately **by id and in batches**, which is the one performance decision in this file.
    /// The material includes the stored unified diffs, and those have no size ceiling — a single
    /// generated client can be a megabyte — so a `fetchSearchIndexSources()` with no argument
    /// would peak at "every diff in the database" in memory just to compute a set of hashes. The
    /// coordinator therefore asks for twenty pull requests at a time, and only for the ones whose
    /// cheap fingerprint says something changed.
    ///
    /// Two queries per batch rather than a join: a join would repeat every pull-request row once
    /// per changed file, including its `bodyMarkdown`.
    /// - Parameter prIDs: The pull requests to read. Unknown ids are absent from the result.
    /// - Returns: One source per pull request that exists, in the order the ids were given.
    public func searchIndexSources(prIDs: [String]) async throws -> [SearchIndexSource] {
        let ids = Array(Set(prIDs))
        guard !ids.isEmpty else { return [] }
        let sources = try await writer.read { db -> [String: SearchIndexSource] in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let records = try PullRequestRecord.fetchAll(
                db,
                sql: "SELECT * FROM pull_requests WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            guard !records.isEmpty else { return [:] }
            let files = try ChangedFileRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM changed_files
                    WHERE prID IN (\(placeholders))
                    ORDER BY prID ASC, sortIndex ASC
                    """,
                arguments: StatementArguments(ids)
            )
            var grouped: [String: [ChangedFile]] = [:]
            for record in files {
                grouped[record.prID, default: []].append(record.changedFile)
            }
            var result: [String: SearchIndexSource] = [:]
            for record in records {
                result[record.id] = SearchIndexSource(
                    summary: record.summary,
                    bodyMarkdown: record.bodyMarkdown ?? "",
                    files: grouped[record.id] ?? [],
                    detailFetchedAt: record.detailFetchedAt
                        .map { Date(timeIntervalSince1970: $0) }
                )
            }
            return result
        }
        return prIDs.compactMap { sources[$0] }
    }

    /// When each cached pull request's detail was last fetched.
    ///
    /// The cheap half of ``ShepherdCore/SearchDocument/fingerprint(for:)``: everything else in the
    /// fingerprint is already in the inbox rows the app holds in memory, and this one column is
    /// what turns "somebody opened this pull request, so there is a diff now" into a re-read
    /// without any code path having to announce it.
    /// - Returns: The timestamps, keyed by node id. Pull requests with no detail fetch are absent.
    public func detailFetchTimestamps() async throws -> [String: Date] {
        try await writer.read { db in
            var result: [String: Date] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, detailFetchedAt FROM pull_requests WHERE detailFetchedAt IS NOT NULL"
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
