import Foundation
import GRDB
import ShepherdCore

extension DatabaseManager {
    /// Writes a whole bulk-triage plan — every draft and every outbox row — in one transaction.
    ///
    /// A bulk run is still *n* ordinary outbox rows, with the retry, offline and staleness
    /// behaviour a single approval has (ADR 0006, ADR 0015); only the number of transactions
    /// changes. Writing them one at a time meant two `fsync`-bearing commits per write, so
    /// approving twenty pull requests cost forty — for rows that are only ever drained together.
    ///
    /// The batch is also the stronger guarantee. Each draft is still written before the row that
    /// carries it, so the per-write ordering is unchanged; but a failure part way through now
    /// rolls the whole batch back instead of leaving an approval queued without the merge that
    /// was meant to follow it. The caller reports the batch as unqueued and the user retries it.
    ///
    /// Send order is untouched: the rows keep the `createdAt` stamps
    /// ``ShepherdCore/BulkTriagePlan/writes(mergeMethod:existingDrafts:now:)`` gave them — one
    /// millisecond apart — and the drain claims by `createdAt`, so an approval still reaches
    /// GitHub before the merge queued behind it.
    /// - Parameter writes: The writes, in send order.
    /// - Throws: A `DatabaseError` when the transaction cannot be committed. Nothing is written
    ///   in that case.
    public func saveBulkTriage(writes: [BulkTriageWrite]) async throws {
        guard !writes.isEmpty else { return }
        // Encoded before the transaction opens: a payload that will not encode should fail
        // without having held a write lock, and `OutboxRecord.init` is the only throwing step
        // that has nothing to do with the database.
        var prepared: [(draft: ReviewDraft?, record: OutboxRecord)] = []
        prepared.reserveCapacity(writes.count)
        for write in writes {
            prepared.append((write.draft, try OutboxRecord(item: write.item)))
        }
        try await writer.write { db in
            for entry in prepared {
                if let draft = entry.draft {
                    try DatabaseManager.storeDraft(db, draft)
                }
                try entry.record.save(db)
            }
        }
    }
}
