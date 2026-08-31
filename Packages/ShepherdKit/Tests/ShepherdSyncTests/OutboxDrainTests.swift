import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence
import XCTest
@testable import ShepherdSync

final class OutboxDrainTests: XCTestCase {
    private let repo = SyncFixtures.repo
    private let now = Date(timeIntervalSince1970: 1_788_162_000)

    private func makeEngine(github: MockGitHub, store: DatabaseManager) -> SyncEngine {
        SyncEngine(
            github: github,
            store: store,
            configuration: SyncConfiguration(),
            sleeper: RecordingSleeper(),
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )
    }

    private func drainCollectingEvents(
        _ engine: SyncEngine
    ) async -> [SyncEvent] {
        let collector = EventCollector()
        let stream = engine.events
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
        }
        await engine.drainOutbox()
        await engine.shutdown()
        _ = await task.value
        return await collector.events
    }

    private func draft(headOid: String) -> ReviewDraft {
        ReviewDraft(
            prID: "PR_1",
            verdict: .approve,
            summaryBody: "Ship it.",
            comments: [
                DraftComment(path: "Sources/A.swift", line: 3, side: .right, body: "Nice.")
            ],
            basedOnHeadOid: headOid,
            updatedAt: now
        )
    }

    private func enqueue(
        _ action: OutboxAction,
        in store: DatabaseManager,
        id: UUID = UUID()
    ) async throws -> UUID {
        try await store.enqueue(
            OutboxItem(
                id: id,
                prID: "PR_1",
                repo: repo,
                number: 1,
                action: action,
                createdAt: now,
                attemptCount: 0,
                nextAttemptAt: Date(timeIntervalSince1970: 0),
                lastError: nil,
                state: .pending
            )
        )
        return id
    }

    // MARK: - Happy paths

    func testResolveThreadIsSentAndTheRowIsRemoved() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(.resolveThread(threadID: "PRRT_1"), in: store)
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let resolved = await github.resolvedThreads
        XCTAssertEqual(resolved, ["PRRT_1"])
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testReplyMergeAndReadyForReviewAreDispatched() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(
            .replyToComment(commentDatabaseID: 42, body: "Thanks!"),
            in: store
        )
        _ = try await enqueue(.merge(method: "squash", expectedHeadOid: "head-1"), in: store)
        _ = try await enqueue(.markReadyForReview, in: store)
        _ = try await enqueue(.unresolveThread(threadID: "PRRT_9"), in: store)
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let replies = await github.replies
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.commentID, 42)

        let merges = await github.merges
        XCTAssertEqual(merges.first?.method, .squash)
        XCTAssertEqual(merges.first?.sha, "head-1")

        let ready = await github.readyForReview
        XCTAssertEqual(ready, ["PR_1"])

        let unresolved = await github.unresolvedThreads
        XCTAssertEqual(unresolved, ["PRRT_9"])

        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSubmittingAReviewRevalidatesTheHeadAndClearsTheDraft() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let pending = draft(headOid: "head-1")
        try await store.saveDraft(pending)
        _ = try await enqueue(.submitReview(pending), in: store)
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let submitted = await github.submittedDrafts
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted.first?.verdict, .approve)

        let storedDraft = try await store.fetchDraft(prID: "PR_1")
        XCTAssertNil(storedDraft, "a submitted draft is cleared")

        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)

        let headChecks = await github.headOidRequests
        XCTAssertEqual(headChecks, ["schnaq/review#1"])
    }

    // MARK: - Conflict path

    func testAMovedHeadBlocksTheSubmitAndSurfacesAConflict() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-2", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let pending = draft(headOid: "head-1")
        try await store.saveDraft(pending)
        _ = try await enqueue(.submitReview(pending), in: store)
        let engine = makeEngine(github: github, store: store)

        let emitted = await drainCollectingEvents(engine)

        let submitted = await github.submittedDrafts
        XCTAssertTrue(submitted.isEmpty, "nothing may be submitted against a moved head")

        let conflicts = emitted.compactMap { event -> DraftConflict? in
            if case .draftConflict(let conflict) = event { return conflict }
            return nil
        }
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.expectedHeadOid, "head-1")
        XCTAssertEqual(conflicts.first?.actualHeadOid, "head-2")
        XCTAssertEqual(conflicts.first?.prID, "PR_1")

        let stored = try await store.allOutboxItems()
        XCTAssertEqual(stored.first?.state, .conflicted, "the row is parked, not retried")

        let draftAfter = try await store.fetchDraft(prID: "PR_1")
        XCTAssertNotNil(draftAfter, "the draft is kept so the user can re-apply it")
    }

    func testAStaleHeadOnMergeIsAlsoAConflict() async throws {
        let github = MockGitHub()
        await github.setMergeError(.staleHead(expected: "head-1", actual: "head-2"))
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(.merge(method: "merge", expectedHeadOid: "head-1"), in: store)
        let engine = makeEngine(github: github, store: store)

        let emitted = await drainCollectingEvents(engine)

        XCTAssertTrue(
            emitted.contains { event in
                if case .draftConflict = event { return true }
                return false
            }
        )
        let stored = try await store.allOutboxItems()
        XCTAssertEqual(stored.first?.state, .conflicted)
    }

    // MARK: - Failure and backoff

    func testARetryableFailureSchedulesABackoff() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        await github.setSubmitError(.server(status: 502, message: "bad gateway"))
        let store = try DatabaseManager.inMemory()
        let pending = draft(headOid: "head-1")
        _ = try await enqueue(.submitReview(pending), in: store)
        let engine = makeEngine(github: github, store: store)

        let emitted = await drainCollectingEvents(engine)

        let stored = try await store.allOutboxItems()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.state, .pending)
        XCTAssertEqual(stored.first?.attemptCount, 1)
        XCTAssertEqual(
            stored.first?.nextAttemptAt.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(5).timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertTrue(
            emitted.contains { event in
                if case .syncFailed(let failure) = event { return failure.stage == .outbox }
                return false
            }
        )
    }

    func testANonRetryableFailureIsParked() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        await github.setSubmitError(.validationFailed(message: "line not in diff"))
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(.submitReview(draft(headOid: "head-1")), in: store)
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let stored = try await store.allOutboxItems()
        XCTAssertEqual(stored.first?.state, .failed)
        XCTAssertEqual(stored.first?.lastError?.contains("line not in diff"), true)
    }

    func testItemsWaitingOnBackoffAreSkipped() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        try await store.enqueue(
            OutboxItem(
                prID: "PR_1",
                repo: repo,
                number: 1,
                action: .resolveThread(threadID: "PRRT_1"),
                createdAt: now,
                attemptCount: 1,
                nextAttemptAt: now.addingTimeInterval(300),
                lastError: "offline",
                state: .pending
            )
        )
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let resolved = await github.resolvedThreads
        XCTAssertTrue(resolved.isEmpty)
        let stored = try await store.allOutboxItems()
        XCTAssertEqual(stored.count, 1)
    }

    func testADraftWithoutABaseCommitSkipsTheStalenessProbe() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        let pending = ReviewDraft(prID: "PR_1", verdict: .comment, basedOnHeadOid: "")
        _ = try await enqueue(.submitReview(pending), in: store)
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let headChecks = await github.headOidRequests
        XCTAssertTrue(headChecks.isEmpty)
        let submitted = await github.submittedDrafts
        XCTAssertEqual(submitted.count, 1)
    }
}
