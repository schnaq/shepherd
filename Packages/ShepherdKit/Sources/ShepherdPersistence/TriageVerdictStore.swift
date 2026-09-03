import Foundation
import GRDB
import ShepherdCore

extension DatabaseManager {
    /// Reads every stored triage verdict (ADR 0023).
    ///
    /// The whole table, on purpose, and for ``searchIndexEntries()``'s reason: it is one small
    /// row per pull request in the local inbox — hundreds at most — and the coordinator needs
    /// every document hash to work out which pull requests have to be classified again. A query
    /// that returned "just the stale ones" would have to know what stale means, which is the pure
    /// ``ShepherdCore/TriageVerdictEntry/isUsable(for:modelIdentifier:)``'s job.
    ///
    /// Rows this version cannot read — a `kind` or `risk` outside the vocabulary — are **skipped
    /// rather than failing the fetch**: the table is a cache of locally computed opinions, and the
    /// honest response is to classify that pull request again.
    /// - Returns: The entries, newest first.
    /// - Throws: A `DatabaseError` when the read fails.
    public func triageVerdicts() async throws -> [TriageVerdictEntry] {
        try await writer.read { db in
            try TriageVerdictRecord
                .fetchAll(db, sql: "SELECT * FROM triage_verdicts ORDER BY classifiedAt DESC")
                .compactMap { $0.entry }
        }
    }

    /// Reads the stored verdicts of some pull requests.
    ///
    /// Keyed by node id, because every caller is asking "what do we have for this row" rather
    /// than iterating: the inbox row, the chip and the ⌘K filter all look one pull request up.
    /// - Parameter prIDs: The pull requests to read. Unknown ids are absent from the result.
    /// - Returns: The entries, keyed by node id.
    /// - Throws: A `DatabaseError` when the read fails.
    public func triageVerdicts(prIDs: [String]) async throws -> [String: TriageVerdictEntry] {
        let ids = Array(Set(prIDs))
        guard !ids.isEmpty else { return [:] }
        return try await writer.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let records = try TriageVerdictRecord.fetchAll(
                db,
                sql: "SELECT * FROM triage_verdicts WHERE prID IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            var result: [String: TriageVerdictEntry] = [:]
            for record in records {
                guard let entry = record.entry else { continue }
                result[entry.prID] = entry
            }
            return result
        }
    }

    /// Writes verdicts, replacing any that exist.
    ///
    /// One transaction for the batch, for ``saveSearchIndexEntries(_:)``'s reason: a pass walks
    /// the inbox row by row and each write is tiny, so a transaction per verdict would mean one
    /// `fsync` per pull request for work nobody is waiting on.
    ///
    /// A verdict whose pull request has meanwhile left the inbox is **skipped rather than failing
    /// the batch**: the foreign key would refuse it, and the honest reading of that refusal is
    /// "the sweep pruned this pull request while the model was thinking about it", which is not
    /// an error.
    /// - Parameter entries: The rows to write.
    /// - Throws: A `DatabaseError` when the transaction cannot be committed.
    public func saveTriageVerdicts(_ entries: [TriageVerdictEntry]) async throws {
        guard !entries.isEmpty else { return }
        let records = entries.map { TriageVerdictRecord(entry: $0) }
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

    /// Deletes verdicts by pull-request id.
    ///
    /// Not the ordinary pruning path — that is the `ON DELETE CASCADE` in the v4 migration, which
    /// happens inside the sweep's own transaction. This is for the cases the cascade cannot
    /// cover: the structured-triage switch going off, which empties the table because a switch
    /// that left its rows on disk would be lying about what it is named after.
    /// - Parameter prIDs: The pull requests whose verdicts go.
    /// - Throws: A `DatabaseError` when the write fails.
    public func deleteTriageVerdicts(prIDs: [String]) async throws {
        guard !prIDs.isEmpty else { return }
        try await writer.write { db in
            let placeholders = Array(repeating: "?", count: prIDs.count).joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM triage_verdicts WHERE prID IN (\(placeholders))",
                arguments: StatementArguments(prIDs)
            )
        }
    }
}
