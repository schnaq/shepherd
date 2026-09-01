import Foundation
import GRDB
import ShepherdCore
import XCTest
@testable import ShepherdPersistence

final class DraftStoreTests: XCTestCase {
    func testDraftSurvivesAReopenOfTheDatabase() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shepherd-draft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")

        let draft = PersistenceFixtures.draft()
        do {
            let database = try DatabaseManager(url: url)
            try await database.saveDraft(draft)
        }

        // A fresh manager over the same file is what an app relaunch looks like.
        let reopened = try DatabaseManager(url: url)
        let loaded = try await reopened.fetchDraft(prID: draft.prID)
        XCTAssertEqual(loaded, draft)
    }

    func testDraftRoundTripKeepsCommentOrderAndRanges() async throws {
        let database = try DatabaseManager.inMemory()
        let draft = PersistenceFixtures.draft()
        try await database.saveDraft(draft)

        let loaded = try await database.fetchDraft(prID: draft.prID)
        XCTAssertEqual(loaded?.verdict, .requestChanges)
        XCTAssertEqual(loaded?.summaryBody, "Please fix the token handling.")
        XCTAssertEqual(loaded?.basedOnHeadOid, "abc123")
        XCTAssertEqual(loaded?.comments.map(\.path), draft.comments.map(\.path))
        XCTAssertEqual(loaded?.comments[1].startLine, 15)
        XCTAssertEqual(loaded?.comments[1].side, .left)
        XCTAssertEqual(loaded?.comments[0].localID, draft.comments[0].localID)
    }

    func testSavingADraftReplacesItsComments() async throws {
        let database = try DatabaseManager.inMemory()
        var draft = PersistenceFixtures.draft()
        try await database.saveDraft(draft)

        draft.comments = [draft.comments[0]]
        try await database.saveDraft(draft)

        let loaded = try await database.fetchDraft(prID: draft.prID)
        XCTAssertEqual(loaded?.comments.count, 1)
    }

    func testDeletingADraftRemovesItsComments() async throws {
        let database = try DatabaseManager.inMemory()
        let draft = PersistenceFixtures.draft()
        try await database.saveDraft(draft)
        try await database.deleteDraft(prID: draft.prID)

        let loaded = try await database.fetchDraft(prID: draft.prID)
        XCTAssertNil(loaded)

        let orphanCount = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM draft_comments") ?? 0
        }
        XCTAssertEqual(orphanCount, 0)
    }

    func testUpsertingACommentCreatesTheDraftWhenNeeded() async throws {
        let database = try DatabaseManager.inMemory()
        let comment = DraftComment(
            path: "Sources/App/View.swift",
            line: 7,
            side: .right,
            body: "Typo."
        )
        try await database.upsertDraftComment(comment, prID: "PR_9", headRefOid: "head9")

        let loaded = try await database.fetchDraft(prID: "PR_9")
        XCTAssertEqual(loaded?.basedOnHeadOid, "head9")
        XCTAssertEqual(loaded?.comments.count, 1)
        XCTAssertEqual(loaded?.comments.first?.body, "Typo.")
        XCTAssertNil(loaded?.verdict)
    }

    func testDeletingASingleComment() async throws {
        let database = try DatabaseManager.inMemory()
        let draft = PersistenceFixtures.draft()
        try await database.saveDraft(draft)

        try await database.deleteDraftComment(localID: draft.comments[0].localID)
        let loaded = try await database.fetchDraft(prID: draft.prID)
        XCTAssertEqual(loaded?.comments.count, 1)
        XCTAssertEqual(loaded?.comments.first?.localID, draft.comments[1].localID)
    }

    func testPullRequestsWithDraftsAreListed() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveDraft(PersistenceFixtures.draft(prID: "PR_1"))
        try await database.saveDraft(PersistenceFixtures.draft(prID: "PR_2"))

        let ids = try await database.pullRequestIDsWithDrafts()
        XCTAssertEqual(Set(ids), ["PR_1", "PR_2"])
    }
}

final class OutboxStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_162_000)

    private func item(
        id: UUID = UUID(),
        action: OutboxAction = .resolveThread(threadID: "PRRT_1"),
        nextAttemptAt: Date = Date(timeIntervalSince1970: 0)
    ) -> OutboxItem {
        OutboxItem(
            id: id,
            prID: "PR_1",
            repo: PersistenceFixtures.repo,
            number: 128,
            action: action,
            createdAt: Date(timeIntervalSince1970: 1_788_161_000),
            attemptCount: 0,
            nextAttemptAt: nextAttemptAt,
            lastError: nil,
            state: .pending
        )
    }

    func testEnqueueAndDequeueRoundTripEveryActionKind() async throws {
        let database = try DatabaseManager.inMemory()
        let actions: [OutboxAction] = [
            .submitReview(PersistenceFixtures.draft()),
            .replyToComment(commentDatabaseID: 987_654_321, body: "Thanks!"),
            .resolveThread(threadID: "PRRT_1"),
            .unresolveThread(threadID: "PRRT_2"),
            .merge(method: "squash", expectedHeadOid: "abc123"),
            .markReadyForReview,
        ]
        for (index, action) in actions.enumerated() {
            var queued = item(action: action)
            // Distinct creation times so the "oldest first" ordering is deterministic.
            queued.createdAt = Date(timeIntervalSince1970: 1_788_161_000 + Double(index))
            try await database.enqueue(queued)
        }

        let ready = try await database.claimReadyOutboxItems(now: now, limit: 50)
        XCTAssertEqual(ready.count, actions.count)
        XCTAssertEqual(ready.map(\.action), actions, "actions must round-trip exactly")
        XCTAssertTrue(ready.allSatisfy { $0.repo == PersistenceFixtures.repo })
        XCTAssertTrue(ready.allSatisfy { $0.number == 128 })
    }

    func testItemsWaitingOutTheirBackoffAreNotDequeued() async throws {
        let database = try DatabaseManager.inMemory()
        let due = item(nextAttemptAt: now.addingTimeInterval(-1))
        let notDue = item(nextAttemptAt: now.addingTimeInterval(60))
        try await database.enqueue(due)
        try await database.enqueue(notDue)

        let ready = try await database.claimReadyOutboxItems(now: now, limit: 50)
        XCTAssertEqual(ready.map(\.id), [due.id])
    }

    func testSucceedingRemovesTheRow() async throws {
        let database = try DatabaseManager.inMemory()
        let queued = item()
        try await database.enqueue(queued)
        try await database.markOutboxItemSucceeded(id: queued.id)

        let remaining = try await database.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
        let pending = try await database.pendingOutboxCount()
        XCTAssertEqual(pending, 0)
    }

    func testFailingSchedulesAnExponentialRetry() async throws {
        let database = try DatabaseManager.inMemory()
        let queued = item()
        try await database.enqueue(queued)

        try await database.markOutboxItemFailed(id: queued.id, error: "offline", now: now)
        var stored = try await database.allOutboxItems()
        XCTAssertEqual(stored.first?.attemptCount, 1)
        XCTAssertEqual(stored.first?.lastError, "offline")
        XCTAssertEqual(stored.first?.state, .pending)
        XCTAssertEqual(
            stored.first?.nextAttemptAt.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(5).timeIntervalSince1970,
            accuracy: 0.001
        )

        try await database.markOutboxItemFailed(id: queued.id, error: "offline", now: now)
        stored = try await database.allOutboxItems()
        XCTAssertEqual(stored.first?.attemptCount, 2)
        XCTAssertEqual(
            stored.first?.nextAttemptAt.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(10).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testNonRetryableFailuresStopBeingDequeued() async throws {
        let database = try DatabaseManager.inMemory()
        let queued = item()
        try await database.enqueue(queued)
        try await database.markOutboxItemFailed(
            id: queued.id,
            error: "422 Validation Failed",
            now: now,
            retriable: false
        )

        let stored = try await database.allOutboxItems()
        XCTAssertEqual(stored.first?.state, .failed)

        let ready = try await database.claimReadyOutboxItems(
            now: now.addingTimeInterval(86_400),
            limit: 50
        )
        XCTAssertTrue(ready.isEmpty)
    }

    func testConflictedItemsAreParkedNotRetried() async throws {
        let database = try DatabaseManager.inMemory()
        let queued = item(action: .submitReview(PersistenceFixtures.draft()))
        try await database.enqueue(queued)
        try await database.markOutboxItemConflicted(id: queued.id, reason: "head moved")

        let stored = try await database.allOutboxItems()
        XCTAssertEqual(stored.first?.state, .conflicted)
        XCTAssertEqual(stored.first?.lastError, "head moved")

        let ready = try await database.claimReadyOutboxItems(
            now: now.addingTimeInterval(86_400),
            limit: 50
        )
        XCTAssertTrue(ready.isEmpty, "a conflict needs a human, not a retry")
    }

    func testConflictedRowsAreCountedSeparatelyFromPendingOnes() async throws {
        // The two counts answer different questions: pending drains by itself, conflicted needs
        // the user — which is why the UI shows the second one permanently (ADR 0006, ADR 0015).
        let database = try DatabaseManager.inMemory()
        let parked = item(action: .submitReview(PersistenceFixtures.draft()))
        var waiting = item()
        waiting.createdAt = now.addingTimeInterval(1)
        try await database.enqueue(parked)
        try await database.enqueue(waiting)
        let beforeConflict = try await database.conflictedOutboxCount()
        XCTAssertEqual(beforeConflict, 0)

        try await database.markOutboxItemConflicted(id: parked.id, reason: "head moved")

        let conflicted = try await database.conflictedOutboxCount()
        let pending = try await database.pendingOutboxCount()
        XCTAssertEqual(conflicted, 1)
        XCTAssertEqual(pending, 1, "a parked row is not waiting to be sent any more")

        try await database.deleteOutboxItem(id: parked.id)
        let afterDiscard = try await database.conflictedOutboxCount()
        XCTAssertEqual(afterDiscard, 0)
    }

    func testDiscardingAConflictDeletesIt() async throws {
        let database = try DatabaseManager.inMemory()
        let queued = item()
        try await database.enqueue(queued)
        try await database.deleteOutboxItem(id: queued.id)

        let stored = try await database.allOutboxItems()
        XCTAssertTrue(stored.isEmpty)
    }

    func testDequeueRespectsTheLimitAndOrdersOldestFirst() async throws {
        let database = try DatabaseManager.inMemory()
        for index in 0..<5 {
            var queued = item()
            queued.createdAt = Date(timeIntervalSince1970: 1_788_160_000 + Double(index))
            try await database.enqueue(queued)
        }
        let ready = try await database.claimReadyOutboxItems(now: now, limit: 3)
        XCTAssertEqual(ready.count, 3)
        XCTAssertEqual(ready.map(\.createdAt), ready.map(\.createdAt).sorted())
    }

    // MARK: - Claiming

    func testClaimingMovesRowsOutOfPendingSoASecondClaimSeesNothing() async throws {
        let database = try DatabaseManager.inMemory()
        let queued = item()
        try await database.enqueue(queued)

        let first = try await database.claimReadyOutboxItems(now: now, limit: 50)
        let second = try await database.claimReadyOutboxItems(now: now, limit: 50)

        XCTAssertEqual(first.map(\.id), [queued.id])
        XCTAssertTrue(second.isEmpty, "a claimed row must never be handed out twice")
        XCTAssertEqual(first.first?.state, .sending)
        XCTAssertEqual(first.first?.attemptCount, 1, "the claim counts the attempt")

        let stored = try await database.allOutboxItems()
        XCTAssertEqual(stored.first?.state, .sending)
    }

    func testConcurrentClaimsSplitTheQueueWithoutOverlap() async throws {
        let database = try DatabaseManager.inMemory()
        var expected: Set<UUID> = []
        for index in 0..<10 {
            var queued = item()
            queued.createdAt = Date(timeIntervalSince1970: 1_788_160_000 + Double(index))
            expected.insert(queued.id)
            try await database.enqueue(queued)
        }

        let claimTime = now
        let claimed = try await withThrowingTaskGroup(of: [OutboxItem].self) { group in
            for _ in 0..<4 {
                group.addTask { try await database.claimReadyOutboxItems(now: claimTime, limit: 10) }
            }
            var all: [OutboxItem] = []
            for try await batch in group { all.append(contentsOf: batch) }
            return all
        }

        XCTAssertEqual(claimed.count, 10, "every row is claimed exactly once")
        XCTAssertEqual(Set(claimed.map(\.id)), expected)
    }

    func testInFlightRowsAreResetWhenTheDatabaseIsReopened() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-outbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }

        let queued = item()
        do {
            let database = try DatabaseManager(url: path)
            try await database.enqueue(queued)
            let claimed = try await database.claimReadyOutboxItems(now: now, limit: 50)
            XCTAssertEqual(claimed.first?.state, .sending)
        }

        // A crash between the claim and the response looks exactly like this.
        let reopened = try DatabaseManager(url: path)
        let stored = try await reopened.allOutboxItems()
        XCTAssertEqual(stored.first?.state, .pending, "a stranded row is retried, not lost")
        let ready = try await reopened.claimReadyOutboxItems(now: now, limit: 50)
        XCTAssertEqual(ready.map(\.id), [queued.id])
    }

    func testReleasingHandsAClaimedRowBack() async throws {
        let database = try DatabaseManager.inMemory()
        let queued = item()
        try await database.enqueue(queued)
        _ = try await database.claimReadyOutboxItems(now: now, limit: 50)

        try await database.releaseOutboxItems(ids: [queued.id])

        let stored = try await database.allOutboxItems()
        XCTAssertEqual(stored.first?.state, .pending)
        XCTAssertEqual(stored.first?.attemptCount, 0, "an unattempted claim does not count")
    }

    func testFailingAClaimedRowDoesNotDoubleCountTheAttempt() async throws {
        let database = try DatabaseManager.inMemory()
        let queued = item()
        try await database.enqueue(queued)
        _ = try await database.claimReadyOutboxItems(now: now, limit: 50)

        try await database.markOutboxItemFailed(id: queued.id, error: "offline", now: now)

        let stored = try await database.allOutboxItems()
        XCTAssertEqual(stored.first?.attemptCount, 1)
        XCTAssertEqual(stored.first?.state, .pending)
        XCTAssertEqual(
            stored.first?.nextAttemptAt.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(5).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testInFlightRowsStillCountAsPendingForTheBadge() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.enqueue(item())
        _ = try await database.claimReadyOutboxItems(now: now, limit: 50)

        let pending = try await database.pendingOutboxCount()
        XCTAssertEqual(pending, 1, "a mutation in flight has not landed yet")
    }
}

final class ConditionalCacheStoreTests: XCTestCase {
    func testETagsRoundTripThroughSQLite() async throws {
        let database = try DatabaseManager.inMemory()
        let cache = DatabaseConditionalCache(database: database)
        let entry = ConditionalCacheEntry(
            etag: "W/\"abc123\"",
            lastModified: "Mon, 31 Aug 2026 07:41:12 GMT",
            payload: Data("[]".utf8),
            storedAt: Date(timeIntervalSince1970: 1_788_162_000)
        )
        await cache.store(entry, for: "https://api.github.com/notifications")

        let loaded = await cache.entry(for: "https://api.github.com/notifications")
        XCTAssertEqual(loaded, entry)
    }

    func testStoringTwiceReplacesTheEntry() async throws {
        let database = try DatabaseManager.inMemory()
        let cache = DatabaseConditionalCache(database: database)
        await cache.store(ConditionalCacheEntry(etag: "one"), for: "key")
        await cache.store(ConditionalCacheEntry(etag: "two"), for: "key")

        let loaded = await cache.entry(for: "key")
        XCTAssertEqual(loaded?.etag, "two")

        let rowCount = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM etags") ?? 0
        }
        XCTAssertEqual(rowCount, 1)
    }

    func testRemovalAndClear() async throws {
        let database = try DatabaseManager.inMemory()
        let cache = DatabaseConditionalCache(database: database)
        await cache.store(ConditionalCacheEntry(etag: "one"), for: "a")
        await cache.store(ConditionalCacheEntry(etag: "two"), for: "b")

        await cache.remove(for: "a")
        let removed = await cache.entry(for: "a")
        XCTAssertNil(removed)

        await cache.removeAll()
        let cleared = await cache.entry(for: "b")
        XCTAssertNil(cleared)
    }

    func testMissingKeysReturnNil() async throws {
        let database = try DatabaseManager.inMemory()
        let cache = DatabaseConditionalCache(database: database)
        let loaded = await cache.entry(for: "never-stored")
        XCTAssertNil(loaded)
    }

    func testTrimmingDropsStaleEntries() async throws {
        let database = try DatabaseManager.inMemory()
        let cache = DatabaseConditionalCache(database: database)
        let now = Date(timeIntervalSince1970: 1_788_162_000)
        await cache.store(
            ConditionalCacheEntry(etag: "old", storedAt: now.addingTimeInterval(-8 * 86_400)),
            for: "stale"
        )
        await cache.store(ConditionalCacheEntry(etag: "new", storedAt: now), for: "fresh")

        try await database.writer.write { db in
            try DatabaseManager.trimConditionalCache(
                db,
                olderThan: now.addingTimeInterval(-7 * 86_400),
                maximumRows: 100
            )
        }

        let staleEntry = await cache.entry(for: "stale")
        let freshEntry = await cache.entry(for: "fresh")
        XCTAssertNil(staleEntry)
        XCTAssertNotNil(freshEntry)
    }

    func testTrimmingEnforcesARowCapOldestFirst() async throws {
        let database = try DatabaseManager.inMemory()
        let cache = DatabaseConditionalCache(database: database)
        let now = Date(timeIntervalSince1970: 1_788_162_000)
        for index in 0..<5 {
            await cache.store(
                ConditionalCacheEntry(
                    etag: "e\(index)",
                    storedAt: now.addingTimeInterval(Double(index))
                ),
                for: "key-\(index)"
            )
        }

        try await database.writer.write { db in
            try DatabaseManager.trimConditionalCache(
                db,
                olderThan: now.addingTimeInterval(-86_400),
                maximumRows: 2
            )
        }

        let remaining = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM etags ORDER BY key")
        }
        XCTAssertEqual(remaining, ["key-3", "key-4"], "the newest entries survive the cap")
    }
}

final class ObservationTests: XCTestCase {
    func testObserveInboxEmitsTheCurrentValue() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])

        var iterator = database.observeInbox().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(first?.first?.id, "PR_1")
    }

    func testObserveDraftEmitsNilWhenThereIsNoDraft() async throws {
        let database = try DatabaseManager.inMemory()
        var iterator = database.observeDraft(prID: "PR_missing").makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertNil(first ?? nil)
    }

    func testObserveDraftEmitsTheStoredDraft() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveDraft(PersistenceFixtures.draft())

        var iterator = database.observeDraft(prID: "PR_1").makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first??.prID, "PR_1")
        XCTAssertEqual(first??.comments.count, 2)
    }

    func testObservePendingOutboxCount() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.enqueue(
            OutboxItem(
                prID: "PR_1",
                repo: PersistenceFixtures.repo,
                number: 128,
                action: .resolveThread(threadID: "PRRT_1")
            )
        )
        var iterator = database.observePendingOutboxCount().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, 1)
    }

    func testObserveConflictedOutboxCount() async throws {
        let database = try DatabaseManager.inMemory()
        let parked = OutboxItem(
            prID: "PR_1",
            repo: PersistenceFixtures.repo,
            number: 128,
            action: .resolveThread(threadID: "PRRT_1")
        )
        try await database.enqueue(parked)
        try await database.markOutboxItemConflicted(id: parked.id, reason: "head moved")

        var iterator = database.observeConflictedOutboxCount().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, 1)
        // Pending and conflicted are disjoint: a parked row is no longer waiting to be sent.
        var pending = database.observePendingOutboxCount().makeAsyncIterator()
        let stillPending = await pending.next()
        XCTAssertEqual(stillPending, 0)
    }
}
