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

    /// Claims the mutations that are due to be attempted, moving them out of the queue.
    ///
    /// Selecting and claiming happen in **one** write transaction: the rows come back already
    /// in ``ShepherdCore/OutboxState/sending``, so a second drain running concurrently — and
    /// there are three callers that can overlap: the sweep loop, `syncNow()`, and the enqueue
    /// path in the UI — cannot pick the same row up and submit it a second time. A plain
    /// `SELECT … WHERE state = 'pending'` would hand the same review to both.
    ///
    /// The attempt is counted here rather than on failure so that a mutation which kills the
    /// process mid-flight still walks its backoff instead of retrying forever.
    /// - Parameters:
    ///   - now: The current time; rows whose backoff has not elapsed are skipped.
    ///   - limit: Maximum number of rows to claim.
    /// - Returns: The claimed rows, oldest first.
    public func claimReadyOutboxItems(
        now: Date = Date(),
        limit: Int = 20
    ) async throws -> [OutboxItem] {
        let cutoff = now.timeIntervalSince1970
        let records = try await writer.write { db -> [OutboxRecord] in
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM outbox
                    WHERE state = 'pending' AND nextAttemptAt <= ?
                    ORDER BY createdAt ASC
                    LIMIT ?
                    """,
                arguments: [cutoff, limit]
            )
            guard !ids.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = ?, attemptCount = attemptCount + 1
                    WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments([OutboxState.sending.rawValue] + ids)
            )
            return try OutboxRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM outbox
                    WHERE id IN (\(placeholders))
                    ORDER BY createdAt ASC
                    """,
                arguments: StatementArguments(ids)
            )
        }
        // A row whose payload no longer decodes (schema drift, corrupt file) is skipped
        // rather than allowed to poison the queue forever.
        return records.compactMap { try? $0.outboxItem() }
    }

    /// Hands claimed rows back to the queue without counting a failure.
    ///
    /// Used when a drain stops early — the app is quitting, or the sweep task was cancelled —
    /// so that rows claimed but never attempted are not stranded in
    /// ``ShepherdCore/OutboxState/sending`` until the next launch.
    /// - Parameter ids: The rows to release. Rows that already moved on are left alone.
    public func releaseOutboxItems(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let strings = ids.map(\.uuidString)
        try await writer.write { db in
            let placeholders = Array(repeating: "?", count: strings.count).joined(separator: ",")
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = ?, attemptCount = MAX(0, attemptCount - 1)
                    WHERE state = ? AND id IN (\(placeholders))
                    """,
                arguments: StatementArguments(
                    [OutboxState.pending.rawValue, OutboxState.sending.rawValue] + strings
                )
            )
        }
    }

    /// Resets rows a previous run left in flight.
    ///
    /// Called when the database is opened: a process that died between the claim and the
    /// response would otherwise leave its mutations stuck in
    /// ``ShepherdCore/OutboxState/sending`` forever.
    public func resetInFlightOutboxItems() async throws {
        try await writer.write { db in
            try DatabaseManager.resetInFlightOutboxItems(db)
        }
    }

    /// The synchronous body of ``resetInFlightOutboxItems()``, so `init` can run it too.
    static func resetInFlightOutboxItems(_ db: Database) throws {
        try db.execute(
            sql: "UPDATE outbox SET state = ? WHERE state = ?",
            arguments: [OutboxState.pending.rawValue, OutboxState.sending.rawValue]
        )
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
            let state = try String.fetchOne(
                db,
                sql: "SELECT state FROM outbox WHERE id = ?",
                arguments: [id.uuidString]
            )
            // ``claimReadyOutboxItems(now:limit:)`` already counted this attempt when it moved
            // the row to `sending`; a caller that never claimed the row counts it here.
            let nextAttempt = state == OutboxState.sending.rawValue
                ? max(1, attempts)
                : attempts + 1
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
    ///
    /// A row that is currently in flight still counts: from the user's point of view it has
    /// not landed yet.
    public func pendingOutboxCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox WHERE state IN ('pending', 'sending')"
            ) ?? 0
        }
    }

    /// How many mutations are parked because the pull request moved on underneath them.
    ///
    /// These are *not* retried on their own (ADR 0006), so unlike the pending count this number
    /// does not go down by itself: it needs the user. That is what makes it worth showing
    /// permanently rather than only in the alert the conflict raised once (ADR 0015).
    public func conflictedOutboxCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox WHERE state = ?",
                arguments: [OutboxState.conflicted.rawValue]
            ) ?? 0
        }
    }

    /// How many mutations were given up on because retrying them cannot help.
    ///
    /// The third standing count, beside ``pendingOutboxCount()`` and
    /// ``conflictedOutboxCount()``, and it is the one that was missing: a write can also end in
    /// ``ShepherdCore/OutboxState/failed`` — a 4xx from GitHub, or a port the app never wired
    /// up — and such a row is neither waiting nor parked, so neither of the other two counts it.
    /// Like a
    /// parked row it never goes away by itself, which is what makes it worth showing rather than
    /// leaving in a table nobody reads.
    public func failedOutboxCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox WHERE state = ?",
                arguments: [OutboxState.failed.rawValue]
            ) ?? 0
        }
    }

    /// The rows the drain gave up on, oldest first.
    ///
    /// The list behind ``failedOutboxCount()``: Settings → Sync needs to *name* each one — what it
    /// would have done, and why it was refused — because "1 failed" is not something a user can act
    /// on, and a row that is never retried automatically is one only they can decide about.
    /// A row whose payload no longer decodes is skipped, exactly as
    /// ``claimReadyOutboxItems(now:limit:)`` skips it.
    public func failedOutboxItems() async throws -> [OutboxItem] {
        let records = try await writer.read { db in
            try OutboxRecord.fetchAll(
                db,
                sql: "SELECT * FROM outbox WHERE state = ? ORDER BY createdAt ASC",
                arguments: [OutboxState.failed.rawValue]
            )
        }
        return records.compactMap { try? $0.outboxItem() }
    }

    /// Puts a row the drain gave up on back into the queue, with its backoff reset.
    ///
    /// The counterpart of ``deleteOutboxItem(id:)`` for a failed row: retry or discard, and
    /// nothing in between. ``ShepherdCore/OutboxState/failed`` means "retrying cannot fix this",
    /// so the next attempt only makes sense once a *person* has changed something the queue cannot
    /// see — a token that was missing, a permission that was denied, a branch that was protected.
    /// That is why this is an explicit user action rather than another rung of
    /// ``ShepherdCore/OutboxBackoff``, and why the attempt count goes back to zero: the row starts
    /// its life again rather than resuming a schedule that had already run out.
    ///
    /// The `state = 'failed'` guard is what makes it safe to call from a screen: a row a drain is
    /// currently sending cannot be yanked back into ``ShepherdCore/OutboxState/pending`` underneath
    /// it and sent twice.
    /// - Parameter id: The row's identity.
    public func retryOutboxItem(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = ?, attemptCount = 0, nextAttemptAt = 0, lastError = NULL
                    WHERE id = ? AND state = ?
                    """,
                arguments: [
                    OutboxState.pending.rawValue,
                    id.uuidString,
                    OutboxState.failed.rawValue,
                ]
            )
        }
    }

    /// Deletes a row outright — the user discarding a mutation that is never going to be sent.
    ///
    /// Both parked states end here when the user says so: a conflicted row from the draft-conflict
    /// alert, and a failed one from Settings → Sync's Discard.
    /// - Parameter id: The row's identity.
    public func deleteOutboxItem(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id.uuidString])
        }
    }
}
