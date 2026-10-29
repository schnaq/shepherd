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
            try DatabaseManager.supersedeParked(by: record, db)
            try record.save(db)
        }
    }

    /// The kinds a newer row of the same kind replaces while parked: a review, a merge and a
    /// branch update are each one decision per pull request, so the parked one is the decision
    /// the user has just made again (ADR 0006's 2026-10-29 amendment).
    static let supersededParkedKinds = ["submitReview", "merge", "updateBranch"]

    /// Deletes the target's parked rows of `record`'s kind, when `record` is a new pending one of
    /// a kind in ``supersededParkedKinds``. The outbox row only — the review draft is the text the
    /// new row was just built from, so it stays.
    ///
    /// Called inside the transaction that writes `record`, from ``enqueue(_:)`` and
    /// ``saveBulkTriage(writes:)``, so every way a review or a merge is queued replaces the parked
    /// one. Without it, re-reviewing after the conflict alert left the old row parked for ever.
    static func supersedeParked(by record: OutboxRecord, _ db: Database) throws {
        guard record.state == OutboxState.pending.rawValue,
              supersededParkedKinds.contains(record.kind)
        else { return }
        try db.execute(
            sql: "DELETE FROM outbox WHERE prID = ? AND kind = ? AND state = ?",
            arguments: [record.prID, record.kind, OutboxState.conflicted.rawValue]
        )
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
            let placeholders = sqlPlaceholders(ids.count)
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
            let placeholders = sqlPlaceholders(strings.count)
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
    /// ``ShepherdCore/OutboxState/sending`` forever. And by every drain that starts while none is
    /// running, for the rows a *cancelled* drain left behind: its writes throw once its task is
    /// cancelled, so it cannot settle or release them itself (ADR 0044). The attempt count is
    /// kept, so the replay check still runs on the next claim.
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
    ///   - error: A human-readable description of what went wrong, in English — for logs, and
    ///     the display's fallback.
    ///   - errorCode: A machine-readable encoding of the same error, when there is one (the
    ///     sync engine writes `GitHubError.storageCode`). Opaque here; the app decodes it to say
    ///     the error in the user's language (ADR 0022, 2026-09-22 amendment).
    ///   - now: The current time.
    ///   - retriable: When `false` the row moves to ``OutboxState/failed`` and is never
    ///     retried automatically.
    public func markOutboxItemFailed(
        id: UUID,
        error: String,
        errorCode: String? = nil,
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
                    SET attemptCount = ?, lastError = ?, lastErrorCode = ?, nextAttemptAt = ?,
                        state = ?
                    WHERE id = ?
                    """,
                arguments: [
                    nextAttempt,
                    error,
                    errorCode,
                    now.addingTimeInterval(delay).timeIntervalSince1970,
                    retriable ? OutboxState.pending.rawValue : OutboxState.failed.rawValue,
                    id.uuidString,
                ]
            )
        }
    }

    /// Parks a mutation because the pull request moved on underneath it.
    ///
    /// The row is kept so the UI can show the conflict and let the user decide — *Discard*
    /// (``discardConflictedOutboxItem(id:)``), *Send anyway* for a review
    /// (``sendConflictedReviewAnyway(id:)``), or a new review or merge that replaces it
    /// (``enqueue(_:)``); it is never retried on its own (ADR 0006: surface conflicts, never
    /// blind-submit).
    /// - Parameters:
    ///   - id: The row's identity.
    ///   - reason: What the conflict was.
    public func markOutboxItemConflicted(id: UUID, reason: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE outbox SET state = ?, lastError = ?, lastErrorCode = NULL WHERE id = ?",
                arguments: [OutboxState.conflicted.rawValue, reason, id.uuidString]
            )
        }
    }

    /// One row by its identity, or `nil` when the outbox no longer holds it.
    ///
    /// The read behind ``ShepherdCore/OutboxWriteOutcome/init(row:)``: a caller that has just
    /// enqueued a write and drained asks what became of *its* row, and the answer is already in
    /// the queue — gone means sent, ``ShepherdCore/OutboxState/conflicted`` means parked,
    /// ``ShepherdCore/OutboxState/failed`` means given up on. One indexed lookup by primary key,
    /// rather than ``allOutboxItems()`` and a `first(where:)` over a table the caller does not
    /// care about.
    ///
    /// A row whose payload no longer decodes throws rather than being skipped, unlike the list
    /// reads above: those describe a queue and must not hide the rest of it, while this one
    /// answers a question about a single row, and "no such row" would be a wrong answer.
    /// - Parameter id: The row's identity.
    /// - Returns: The row, or `nil` when it is not in the outbox any more.
    public func outboxItem(id: UUID) async throws -> OutboxItem? {
        let record = try await writer.read { db in
            try OutboxRecord.fetchOne(
                db,
                sql: "SELECT * FROM outbox WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        return try record?.outboxItem()
    }

    /// Every row currently in the outbox, newest last. Used by the Settings screen and tests.
    public func allOutboxItems() async throws -> [OutboxItem] {
        try await writer.read { db in
            try DatabaseManager.loadOutboxItems(db)
        }
    }

    /// Every row queued against one pull request, in any state, oldest first — the claim's order,
    /// so "older" and "newer" mean here what they mean to the drain.
    ///
    /// What the drain reads before it sends an edit or a delete of a post, and the app before it
    /// queues one, to find the other rows about the same post (ADR 0043, C). A row whose payload no longer decodes is skipped, as in
    /// the other list reads.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: Its rows.
    public func outboxItems(prID: String) async throws -> [OutboxItem] {
        let records = try await writer.read { db in
            try OutboxRecord.fetchAll(
                db,
                sql: "SELECT * FROM outbox WHERE prID = ? ORDER BY createdAt ASC",
                arguments: [prID]
            )
        }
        return records.compactMap { try? $0.outboxItem() }
    }

    /// The whole-outbox query, shared by ``allOutboxItems()`` and ``observeOutboxItems()``.
    ///
    /// One definition rather than the same `SELECT` written twice: the ordering is part of what
    /// callers see — a panel lists a pull request's writes in the order they were queued — and
    /// two copies of a query are two chances for that to stop being true. A row whose payload
    /// cannot be decoded is dropped rather than thrown: the outbox is append-only history, and one
    /// unreadable row must not hide the rest of the queue from the surfaces that describe it.
    static func loadOutboxItems(_ db: Database) throws -> [OutboxItem] {
        let records = try OutboxRecord.fetchAll(
            db,
            sql: "SELECT * FROM outbox ORDER BY createdAt ASC"
        )
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

    /// The rows parked because their target moved on, oldest first — ``failedOutboxItems()``'s
    /// sibling, for the lists that name each parked write beside the failed ones.
    public func conflictedOutboxItems() async throws -> [OutboxItem] {
        let records = try await writer.read { db in
            try OutboxRecord.fetchAll(
                db,
                sql: "SELECT * FROM outbox WHERE state = ? ORDER BY createdAt ASC",
                arguments: [OutboxState.conflicted.rawValue]
            )
        }
        return records.compactMap { try? $0.outboxItem() }
    }

    /// Throws a parked row away — the user deciding the write is not going out.
    ///
    /// A parked **review** takes its draft with it, in the same transaction: the draft is what the
    /// row was built from, and a draft left behind keeps the pull request pinned in the inbox
    /// (`pruneGuardSQL`) after it was merged or closed — the stuck row this exists to clear. That
    /// deletes text the user wrote, which is why every caller confirms first.
    ///
    /// Guarded on `state = 'conflicted'`, so a screen that is a moment behind cannot throw away a
    /// row that has meanwhile been re-queued or sent.
    /// - Parameter id: The row's identity.
    public func discardConflictedOutboxItem(id: UUID) async throws {
        try await writer.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT prID, kind FROM outbox WHERE id = ? AND state = ?",
                arguments: [id.uuidString, OutboxState.conflicted.rawValue]
            ) else { return }
            try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id.uuidString])
            let kind: String = row["kind"]
            guard kind == "submitReview" else { return }
            let prID: String = row["prID"]
            try db.execute(sql: "DELETE FROM review_drafts WHERE prID = ?", arguments: [prID])
            try db.execute(sql: "DELETE FROM draft_comments WHERE prID = ?", arguments: [prID])
        }
    }

    /// Re-queues a parked review to be sent against the commit it was written on — the user's
    /// *Send anyway*.
    ///
    /// The row's draft gets ``ShepherdCore/ReviewDraft/sendsAgainstReviewedCommit`` set, which is
    /// what makes the drain skip its staleness check for this one send; GitHub anchors the
    /// comments on `commit_id`, the reviewed commit. A commit a force-push made unreachable is
    /// refused by GitHub, and the row ends up failed, where Retry and Discard are.
    ///
    /// The attempt count goes to zero: a review is parked before it is submitted, so there is no
    /// earlier attempt the replay check could find. Only a parked `submitReview` row is touched.
    /// - Parameter id: The row's identity.
    public func sendConflictedReviewAnyway(id: UUID) async throws {
        try await writer.write { db in
            guard let record = try OutboxRecord.fetchOne(
                db,
                sql: "SELECT * FROM outbox WHERE id = ? AND state = ? AND kind = 'submitReview'",
                arguments: [id.uuidString, OutboxState.conflicted.rawValue]
            ), case .submitReview(var draft) = try record.outboxItem().action
            else { return }
            draft.sendsAgainstReviewedCommit = true
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = ?, payload = ?, attemptCount = 0, nextAttemptAt = 0,
                        lastError = NULL, lastErrorCode = NULL
                    WHERE id = ?
                    """,
                arguments: [
                    OutboxState.pending.rawValue,
                    try JSONEncoder().encode(OutboxAction.submitReview(draft)),
                    id.uuidString,
                ]
            )
        }
    }

    /// Puts a row the drain gave up on back into the queue, with its backoff reset.
    ///
    /// The counterpart of ``deleteOutboxItem(id:)`` for a failed row: retry or discard, and
    /// nothing in between. ``ShepherdCore/OutboxState/failed`` means "retrying cannot fix this",
    /// so the next attempt only makes sense once a *person* has changed something the queue cannot
    /// see — a token that was missing, a permission that was denied, a branch that was protected.
    /// That is why this is an explicit user action rather than another rung of
    /// ``ShepherdCore/OutboxBackoff``, and why the attempt count goes back down: the row starts
    /// its life again rather than resuming a schedule that had already run out.
    ///
    /// Down to zero for a row only ever attempted once, which cannot have landed unseen; down to
    /// one for a row attempted more than once, so the next claim makes it two and the replay check
    /// (`SyncEngine.previousAttemptLanded`) still asks GitHub first. A row the check gave up on
    /// because it could not decide is exactly a row whose earlier attempt may have landed, and
    /// zeroing it would send it blind — the duplicate the check exists to prevent (ADR 0044).
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
                    SET state = ?, attemptCount = CASE WHEN attemptCount > 1 THEN 1 ELSE 0 END,
                        nextAttemptAt = 0, lastError = NULL,
                        lastErrorCode = NULL
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
    /// A failed row ends here when the user says so (Settings → Sync, the unsent-writes list). A
    /// parked one goes through ``discardConflictedOutboxItem(id:)``, which also clears its draft.
    /// - Parameter id: The row's identity.
    public func deleteOutboxItem(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Cancels a row the drain has not claimed — the user taking a write back before it left
    /// (ADR 0043, B).
    ///
    /// A read of the row followed by ``deleteOutboxItem(id:)`` would not do: the drain can claim
    /// the row between the two, and a row in ``ShepherdCore/OutboxState/sending`` is in flight —
    /// GitHub may already have it — so deleting it would take back nothing and hide a write that
    /// landed. The `state = 'pending'` guard makes the check and the delete one statement, as
    /// ``retryOutboxItem(id:)``'s guard does for its own: a row is cancelled only while it is
    /// pending, one waiting out a backoff included, and any other row is left as it is — a claimed
    /// one to the drain, a failed or parked one to its own owners (Settings → Sync, the conflict
    /// alert).
    ///
    /// A primitive, with no policy in it. The ones built on it are its callers': a reaction click
    /// cancels the row it undoes and queues its own all the same (`PullRequestActions.writeReaction`),
    /// and an edit or a delete of a post takes out the older edits of it still waiting — the app's
    /// when it is queued, the drain's when it is sent (ADR 0043, C).
    /// - Parameter id: The row's identity.
    public func cancelPendingOutboxItem(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM outbox WHERE id = ? AND state = ?",
                arguments: [id.uuidString, OutboxState.pending.rawValue]
            )
        }
    }
}
