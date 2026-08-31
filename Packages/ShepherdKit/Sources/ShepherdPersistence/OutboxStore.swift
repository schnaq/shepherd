import Foundation
import GRDB
import ShepherdCore

extension DatabaseManager {
    /// Adds a mutation to the outbox.
    ///
    /// The UI calls this and returns immediately; the sync engine drains the queue. That is
    /// what makes "approve" work offline (ADR 0006).
    /// - Parameter item: The mutation to enqueue.
    public func enqueue(_ item: OutboxItem) async throws {
        let record = try OutboxRecord(item: item)
        try await writer.write { db in
            try record.save(db)
        }
    }

    /// Reads the mutations that are due to be attempted.
    /// - Parameters:
    ///   - now: The current time; rows whose backoff has not elapsed are skipped.
    ///   - limit: Maximum number of rows to return.
    /// - Returns: Due rows, oldest first.
    public func dequeueReadyOutboxItems(
        now: Date = Date(),
        limit: Int = 20
    ) async throws -> [OutboxItem] {
        let cutoff = now.timeIntervalSince1970
        let records = try await writer.read { db in
            try OutboxRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM outbox
                    WHERE state = 'pending' AND nextAttemptAt <= ?
                    ORDER BY createdAt ASC
                    LIMIT ?
                    """,
                arguments: [cutoff, limit]
            )
        }
        // A row whose payload no longer decodes (schema drift, corrupt file) is skipped
        // rather than allowed to poison the queue forever.
        return records.compactMap { try? $0.outboxItem() }
    }

    /// Marks a mutation as sent and removes it from the queue.
    /// - Parameter id: The row's identity.
    public func markOutboxItemSucceeded(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Records a failed attempt and schedules the next one.
    /// - Parameters:
    ///   - id: The row's identity.
    ///   - error: A human-readable description of what went wrong.
    ///   - now: The current time.
    ///   - retriable: When `false` the row moves to ``OutboxState/failed`` and is never
    ///     retried automatically.
    public func markOutboxItemFailed(
        id: UUID,
        error: String,
        now: Date = Date(),
        retriable: Bool = true
    ) async throws {
        try await writer.write { db in
            let attempts = try Int.fetchOne(
                db,
                sql: "SELECT attemptCount FROM outbox WHERE id = ?",
                arguments: [id.uuidString]
            ) ?? 0
            let nextAttempt = attempts + 1
            let delay = OutboxBackoff.delay(forAttempt: nextAttempt)
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET attemptCount = ?, lastError = ?, nextAttemptAt = ?, state = ?
                    WHERE id = ?
                    """,
                arguments: [
                    nextAttempt,
                    error,
                    now.addingTimeInterval(delay).timeIntervalSince1970,
                    retriable ? OutboxState.pending.rawValue : OutboxState.failed.rawValue,
                    id.uuidString,
                ]
            )
        }
    }

    /// Parks a mutation because the pull request moved on underneath it.
    ///
    /// The row is kept so the UI can show the conflict and let the user re-apply or discard;
    /// it is never retried on its own (ADR 0006: surface conflicts, never blind-submit).
    /// - Parameters:
    ///   - id: The row's identity.
    ///   - reason: What the conflict was.
    public func markOutboxItemConflicted(id: UUID, reason: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE outbox SET state = ?, lastError = ? WHERE id = ?",
                arguments: [OutboxState.conflicted.rawValue, reason, id.uuidString]
            )
        }
    }

    /// Every row currently in the outbox, newest last. Used by the Settings screen and tests.
    public func allOutboxItems() async throws -> [OutboxItem] {
        let records = try await writer.read { db in
            try OutboxRecord.fetchAll(db, sql: "SELECT * FROM outbox ORDER BY createdAt ASC")
        }
        return records.compactMap { try? $0.outboxItem() }
    }

    /// How many mutations are waiting to be sent.
    public func pendingOutboxCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox WHERE state = 'pending'"
            ) ?? 0
        }
    }

    /// Deletes a row outright — the user discarding a conflicted mutation.
    /// - Parameter id: The row's identity.
    public func deleteOutboxItem(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id.uuidString])
        }
    }
}
