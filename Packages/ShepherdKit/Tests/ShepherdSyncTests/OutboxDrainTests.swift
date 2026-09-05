import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence
import XCTest
@testable import ShepherdSync

final class OutboxDrainTests: XCTestCase {
    private let repo = SyncFixtures.repo
    private let now = Date(timeIntervalSince1970: 1_788_162_000)

    private func makeEngine(
        github: MockGitHub,
        store: DatabaseManager,
        issueWrites: (any IssueWriting)? = nil,
        branchDeletion: (any BranchDeleting)? = nil
    ) -> SyncEngine {
        SyncEngine(
            github: github,
            store: store,
            issueWrites: issueWrites,
            branchDeletion: branchDeletion,
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

    // MARK: - Deleting the merged head branch (ADR 0005's 2026-09-05 amendment)

    func testAMergeThatAsksForItDeletesTheHeadBranchAfterTheMerge() async throws {
        let github = MockGitHub()
        await github.setBranchContext(
            HeadBranchContext(
                headRefName: "agent/token-store",
                headRepositoryFullName: repo.fullName,
                defaultBranchName: "main"
            ),
            repo: repo,
            number: 1
        )
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(
            .merge(method: "squash", expectedHeadOid: "head-1", deletesHeadBranch: true),
            in: store
        )
        let engine = makeEngine(github: github, store: store, branchDeletion: github)

        await engine.drainOutbox()

        // The order is the assertion: a branch is only a leftover once the merge has landed.
        let log = await github.writeLog
        XCTAssertEqual(log, ["merge #1", "delete agent/token-store"])
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testABranchDeletionThatFailsStillLeavesTheMergeSucceeded() async throws {
        // The whole reason the deletion is swallowed: the merge already happened on GitHub, and
        // a row that reported failure would be retried into a merge GitHub refuses.
        let github = MockGitHub()
        await github.setDeleteBranchError(.server(status: 500, message: "boom"))
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(
            .merge(method: "squash", expectedHeadOid: "head-1", deletesHeadBranch: true),
            in: store
        )
        let engine = makeEngine(github: github, store: store, branchDeletion: github)

        await engine.drainOutbox()

        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty, "the merge row left the queue")
        let merges = await github.merges
        XCTAssertEqual(merges.count, 1, "and the merge was not sent a second time")

        // A second drain has nothing left to send, which is the same statement from the other
        // side: nothing was queued for a retry.
        await engine.drainOutbox()
        let mergesAfterSecondDrain = await github.merges
        XCTAssertEqual(mergesAfterSecondDrain.count, 1)
    }

    func testAProbeThatFailsDeletesNothingAndStillSucceeds() async throws {
        let github = MockGitHub()
        await github.setBranchContextError(.server(status: 502, message: "bad gateway"))
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(
            .merge(method: "squash", expectedHeadOid: "head-1", deletesHeadBranch: true),
            in: store
        )
        let engine = makeEngine(github: github, store: store, branchDeletion: github)

        await engine.drainOutbox()

        let deleted = await github.deletedBranches
        XCTAssertTrue(deleted.isEmpty, "a guard that could not be evaluated is a refusal")
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAMergeThatDoesNotAskForItNeverEvenProbes() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(.merge(method: "squash", expectedHeadOid: "head-1"), in: store)
        let engine = makeEngine(github: github, store: store, branchDeletion: github)

        await engine.drainOutbox()

        let probes = await github.branchContextRequests
        XCTAssertTrue(probes.isEmpty, "the request is only made when the row asked for a deletion")
        let deleted = await github.deletedBranches
        XCTAssertTrue(deleted.isEmpty)
    }

    func testAForksHeadBranchIsNeverDeleted() async throws {
        let github = MockGitHub()
        await github.setBranchContext(
            HeadBranchContext(
                headRefName: "patch-1",
                headRepositoryFullName: "someone-else/review",
                defaultBranchName: "main"
            ),
            repo: repo,
            number: 1
        )
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(
            .merge(method: "merge", expectedHeadOid: "head-1", deletesHeadBranch: true),
            in: store
        )
        let engine = makeEngine(github: github, store: store, branchDeletion: github)

        await engine.drainOutbox()

        let deleted = await github.deletedBranches
        XCTAssertTrue(deleted.isEmpty, "the branch of a cross-repository pull request is not ours")
        let log = await github.writeLog
        XCTAssertEqual(log, ["merge #1"])
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTheRepositorysDefaultBranchIsNeverDeleted() async throws {
        // A pull request from `main` into a release branch is an ordinary thing to open.
        let github = MockGitHub()
        await github.setBranchContext(
            HeadBranchContext(
                headRefName: "main",
                headRepositoryFullName: repo.fullName,
                defaultBranchName: "main"
            ),
            repo: repo,
            number: 1
        )
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(
            .merge(method: "merge", expectedHeadOid: "head-1", deletesHeadBranch: true),
            in: store
        )
        let engine = makeEngine(github: github, store: store, branchDeletion: github)

        await engine.drainOutbox()

        let deleted = await github.deletedBranches
        XCTAssertTrue(deleted.isEmpty)
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAnEngineWithoutTheBranchPortMergesAndDeletesNothing() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(
            .merge(method: "squash", expectedHeadOid: "head-1", deletesHeadBranch: true),
            in: store
        )
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let log = await github.writeLog
        XCTAssertEqual(log, ["merge #1"])
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty, "the merge is a merge either way")
    }

    // MARK: - Announcing what actually reached GitHub (ADR 0012)

    func testEverySentMutationMapsToAKind() {
        XCTAssertEqual(
            SyncEngine.sentKind(for: .submitReview(draft(headOid: "head-1"))),
            .reviewSubmitted(verdict: .approve, inlineCommentCount: 1)
        )
        XCTAssertEqual(
            SyncEngine.sentKind(
                for: .submitReview(ReviewDraft(prID: "PR_1", basedOnHeadOid: ""))
            ),
            .reviewSubmitted(verdict: nil, inlineCommentCount: 0),
            "a draft parked as pending still reports what it carried"
        )
        XCTAssertEqual(
            SyncEngine.sentKind(for: .replyToComment(commentDatabaseID: 1, body: "hi")),
            .replyPosted
        )
        XCTAssertEqual(SyncEngine.sentKind(for: .resolveThread(threadID: "T")), .threadResolved)
        XCTAssertEqual(
            SyncEngine.sentKind(for: .unresolveThread(threadID: "T")),
            .threadUnresolved
        )
        XCTAssertEqual(
            SyncEngine.sentKind(for: .merge(method: "rebase", expectedHeadOid: nil)),
            .merged(method: "rebase")
        )
        XCTAssertEqual(SyncEngine.sentKind(for: .markReadyForReview), .markedReadyForReview)
    }

    func testASubmittedReviewIsAnnouncedWithItsVerdictAndCommentCount() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let pending = draft(headOid: "head-1")
        try await store.saveDraft(pending)
        _ = try await enqueue(.submitReview(pending), in: store)
        let engine = makeEngine(github: github, store: store)

        let sent = sentMutations(in: await drainCollectingEvents(engine))

        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.prID, "PR_1")
        XCTAssertEqual(sent.first?.repo, repo)
        XCTAssertEqual(sent.first?.number, 1)
        XCTAssertEqual(
            sent.first?.kind,
            .reviewSubmitted(verdict: .approve, inlineCommentCount: 1)
        )
        XCTAssertEqual(sent.first?.sentAt, now)
    }

    func testAMergeIsAnnouncedWithTheMethodItUsed() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        _ = try await enqueue(.merge(method: "squash", expectedHeadOid: "head-1"), in: store)
        let engine = makeEngine(github: github, store: store)

        let sent = sentMutations(in: await drainCollectingEvents(engine))

        XCTAssertEqual(sent.map(\.kind), [.merged(method: "squash")])
    }

    func testNothingIsAnnouncedWhenTheMutationDidNotReachGitHub() async throws {
        // A moved head: the row is parked, so the review never happened and nothing may claim
        // it did. This is the whole reason the announcement lives in the drain and not at the
        // point the user pressed the key.
        let conflicting = MockGitHub()
        await conflicting.setHeadOid("head-2", repo: repo, number: 1)
        let conflictStore = try DatabaseManager.inMemory()
        let pending = draft(headOid: "head-1")
        try await conflictStore.saveDraft(pending)
        _ = try await enqueue(.submitReview(pending), in: conflictStore)
        let conflictEngine = makeEngine(github: conflicting, store: conflictStore)

        let afterConflict = sentMutations(in: await drainCollectingEvents(conflictEngine))
        XCTAssertTrue(afterConflict.isEmpty)

        // A retryable server error: the row is still queued, so still nothing happened.
        let failing = MockGitHub()
        await failing.setHeadOid("head-1", repo: repo, number: 1)
        await failing.setSubmitError(.server(status: 502, message: "bad gateway"))
        let failStore = try DatabaseManager.inMemory()
        _ = try await enqueue(.submitReview(draft(headOid: "head-1")), in: failStore)
        let failEngine = makeEngine(github: failing, store: failStore)

        let afterFailure = sentMutations(in: await drainCollectingEvents(failEngine))
        XCTAssertTrue(afterFailure.isEmpty)
    }

    private func sentMutations(in events: [SyncEvent]) -> [SentMutation] {
        events.compactMap { event in
            if case .mutationSent(let mutation) = event { return mutation }
            return nil
        }
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

    // MARK: - Concurrent drains

    /// Waits until `count` scripted calls are parked on the mock's gate.
    private func waitForGate(_ github: MockGitHub, count: Int) async throws {
        for _ in 0..<10_000 {
            if await github.gateWaiterCount >= count { return }
            await Task.yield()
        }
        XCTFail("the scripted call never reached the gate")
    }

    func testASecondDrainDuringAnInFlightSubmitDoesNotResubmit() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let pending = draft(headOid: "head-1")
        try await store.saveDraft(pending)
        _ = try await enqueue(.submitReview(pending), in: store)
        let engine = makeEngine(github: github, store: store)

        // Drain #1 parks inside `submitReview`, exactly where the network would.
        await github.closeGate()
        let first = Task { await engine.drainOutbox() }
        try await waitForGate(github, count: 1)

        // This is the real scenario: the user hits `r a` on a second pull request, which
        // enqueues and drains again while the first submission is still in flight.
        await engine.drainOutbox()

        await github.openGate()
        await first.value

        let submitted = await github.submittedDrafts
        XCTAssertEqual(submitted.count, 1, "the same review must never be POSTed twice")
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testWorkEnqueuedDuringADrainIsPickedUpByTheSameDrain() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let pending = draft(headOid: "head-1")
        try await store.saveDraft(pending)
        _ = try await enqueue(.submitReview(pending), in: store)
        let engine = makeEngine(github: github, store: store)

        await github.closeGate()
        let first = Task { await engine.drainOutbox() }
        try await waitForGate(github, count: 1)

        // A second mutation lands while the first drain is suspended. The coalesced re-drain
        // has to pick it up, or it would sit in the queue until the next sweep.
        _ = try await enqueue(.resolveThread(threadID: "PRRT_LATE"), in: store)
        await engine.drainOutbox()

        await github.openGate()
        await first.value

        let resolved = await github.resolvedThreads
        XCTAssertEqual(resolved, ["PRRT_LATE"])
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testFourConcurrentDrainsSendEachMutationOnce() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        for index in 0..<6 {
            _ = try await enqueue(.resolveThread(threadID: "PRRT_\(index)"), in: store)
        }
        let engine = makeEngine(github: github, store: store)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await engine.drainOutbox() }
            }
        }

        let resolved = await github.resolvedThreads
        XCTAssertEqual(resolved.count, 6)
        XCTAssertEqual(Set(resolved).count, 6, "no thread is resolved twice")
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
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

    // MARK: - Issue writes and their staleness precondition (ADR 0032's Sprint 4a amendment)

    /// Queues one issue action against an issue last updated at ``now``.
    ///
    /// The row's `prID`, `repo` and `number` are the *issue's*: `OutboxItem` reuses its three
    /// target fields for whichever kind of node the action names.
    private func enqueueIssue(
        _ action: OutboxAction,
        in store: DatabaseManager,
        queuedAfter offset: TimeInterval = 0
    ) async throws {
        try await store.enqueue(
            OutboxItem(
                prID: "I_1",
                repo: repo,
                number: 128,
                action: action,
                // Distinct, because the drain claims in `createdAt` order and a test that
                // asserts on the order of two state changes must not depend on a tie-break.
                createdAt: now.addingTimeInterval(offset),
                nextAttemptAt: Date(timeIntervalSince1970: 0)
            )
        )
    }

    func testAMatchingTimestampLetsEveryIssueWriteThrough() async throws {
        let github = MockGitHub()
        let writer = MockIssueWriter()
        await writer.setState(updatedAt: now)
        let store = try DatabaseManager.inMemory()
        try await enqueueIssue(
            .addIssueComment(body: "Picking this up.", basedOnUpdatedAt: now),
            in: store,
            queuedAfter: 1
        )
        try await enqueueIssue(
            .addIssueLabel(name: "needs-triage", basedOnUpdatedAt: now),
            in: store,
            queuedAfter: 2
        )
        try await enqueueIssue(
            .addIssueAssignee(login: "octocat", basedOnUpdatedAt: now),
            in: store,
            queuedAfter: 3
        )
        try await enqueueIssue(
            .closeIssue(reason: .notPlanned, basedOnUpdatedAt: now),
            in: store,
            queuedAfter: 4
        )
        try await enqueueIssue(.reopenIssue(basedOnUpdatedAt: now), in: store, queuedAfter: 5)
        let engine = makeEngine(github: github, store: store, issueWrites: writer)

        await engine.drainOutbox()

        let comments = await writer.comments
        XCTAssertEqual(
            comments,
            [MockIssueWriter.Comment(repo: repo, number: 128, body: "Picking this up.")]
        )
        let labels = await writer.labels
        XCTAssertEqual(labels, [["needs-triage"]])
        let assignees = await writer.assignees
        XCTAssertEqual(assignees, [["octocat"]])
        let changes = await writer.stateChanges
        XCTAssertEqual(
            changes,
            [
                MockIssueWriter.StateChange(
                    repo: repo,
                    number: 128,
                    state: "closed",
                    stateReason: "not_planned"
                ),
                MockIssueWriter.StateChange(
                    repo: repo,
                    number: 128,
                    state: "open",
                    stateReason: nil
                ),
            ]
        )
        // Every one of the five was probed first, and the row is gone once it landed.
        let probes = await writer.probes
        XCTAssertEqual(probes, Array(repeating: "schnaq/review#128", count: 5))
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAChangedUpdatedAtParksTheRowAndSendsNothing() async throws {
        let github = MockGitHub()
        let writer = MockIssueWriter()
        // Somebody relabelled the issue between the click and the drain.
        await writer.setState(updatedAt: now.addingTimeInterval(90))
        let store = try DatabaseManager.inMemory()
        try await enqueueIssue(.closeIssue(reason: .completed, basedOnUpdatedAt: now), in: store)
        let engine = makeEngine(github: github, store: store, issueWrites: writer)

        let emitted = await drainCollectingEvents(engine)

        let sent = await writer.sentAnything
        XCTAssertFalse(sent, "nothing may be sent against an issue that moved on")
        let stored = try await store.allOutboxItems()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.state, .conflicted, "the row is parked, not retried")
        XCTAssertEqual(
            stored.first?.lastError?.contains("moved on before the write could run"),
            true
        )
        // No `draftConflict`: there is no review draft to re-apply, so the alert that offers one
        // would be a promise this row cannot keep. The standing conflicted count is the surface.
        XCTAssertFalse(
            emitted.contains { event in
                if case .draftConflict = event { return true }
                return false
            }
        )
        XCTAssertTrue(sentMutations(in: emitted).isEmpty)
    }

    func testAProbeThatCouldNotBeMadeIsABackoffAndNotAConflict() async throws {
        let github = MockGitHub()
        let writer = MockIssueWriter()
        await writer.setState(updatedAt: now)
        await writer.setProbeError(.transport(message: "offline"))
        let store = try DatabaseManager.inMemory()
        try await enqueueIssue(
            .addIssueComment(body: "On it.", basedOnUpdatedAt: now),
            in: store
        )
        let engine = makeEngine(github: github, store: store, issueWrites: writer)

        await engine.drainOutbox()

        let sent = await writer.sentAnything
        XCTAssertFalse(sent)
        let stored = try await store.allOutboxItems()
        // Still queued and backed off — a tunnel says nothing about the issue, so parking on it
        // would leave the user a pile of rows to clear by hand.
        XCTAssertEqual(stored.first?.state, .pending)
        XCTAssertEqual(stored.first?.attemptCount, 1)
        XCTAssertEqual(
            stored.first?.nextAttemptAt.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(5).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testAnEngineWithNoIssueWriterRefusesTheRowRatherThanSendingItBlind() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        try await enqueueIssue(.reopenIssue(basedOnUpdatedAt: now), in: store)
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let stored = try await store.allOutboxItems()
        XCTAssertEqual(stored.first?.state, .failed, "not retryable: the port cannot appear later")
    }

    func testAClosedIssueIsAnnouncedWithGitHubsOwnReasonWord() async throws {
        let github = MockGitHub()
        let writer = MockIssueWriter()
        await writer.setState(updatedAt: now)
        let store = try DatabaseManager.inMemory()
        try await enqueueIssue(.closeIssue(reason: .notPlanned, basedOnUpdatedAt: now), in: store)
        let engine = makeEngine(github: github, store: store, issueWrites: writer)

        let sent = sentMutations(in: await drainCollectingEvents(engine))

        XCTAssertEqual(sent.map(\.kind), [.issueClosed(reason: "not_planned")])
        XCTAssertEqual(sent.first?.prID, "I_1")
        XCTAssertEqual(sent.first?.number, 128)
    }

    func testEveryIssueActionMapsToASentKind() {
        let queuedAt = Date(timeIntervalSince1970: 1_788_162_000)
        XCTAssertEqual(
            SyncEngine.sentKind(for: .addIssueComment(body: "x", basedOnUpdatedAt: queuedAt)),
            .issueCommentAdded
        )
        XCTAssertEqual(
            SyncEngine.sentKind(for: .addIssueLabel(name: "bug", basedOnUpdatedAt: queuedAt)),
            .issueLabelAdded(name: "bug")
        )
        XCTAssertEqual(
            SyncEngine.sentKind(for: .addIssueAssignee(login: "octocat", basedOnUpdatedAt: queuedAt)),
            .issueAssigneeAdded(login: "octocat")
        )
        XCTAssertEqual(
            SyncEngine.sentKind(for: .closeIssue(reason: .completed, basedOnUpdatedAt: queuedAt)),
            .issueClosed(reason: "completed")
        )
        XCTAssertEqual(
            SyncEngine.sentKind(for: .reopenIssue(basedOnUpdatedAt: queuedAt)),
            .issueReopened
        )
    }

    // MARK: - Reading the outcome back off the queue

    /// The mechanism the write-path toasts are worded from: after a drain, the row a caller
    /// enqueued says what became of it, without the drain returning anything.
    func testASentRowReadsBackAsSent() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        let id = try await enqueue(.resolveThread(threadID: "PRRT_1"), in: store)
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let row = try await store.outboxItem(id: id)
        XCTAssertNil(row, "a sent row is deleted, which is the only way one leaves the queue")
        XCTAssertEqual(OutboxWriteOutcome(row: row), .sent)
    }

    func testAParkedRowReadsBackAsParkedWithItsReason() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-2", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let pending = draft(headOid: "head-1")
        try await store.saveDraft(pending)
        let id = try await enqueue(.submitReview(pending), in: store)
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let row = try await store.outboxItem(id: id)
        XCTAssertEqual(row?.state, .conflicted)
        guard case .parked(let reason) = OutboxWriteOutcome(row: row) else {
            return XCTFail("a review the head moved under is parked, not sent")
        }
        XCTAssertEqual(reason?.contains("head-2"), true)
    }

    func testARefusedRowReadsBackAsFailedWithWhatGitHubSaid() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        await github.setSubmitError(.validationFailed(message: "line not in diff"))
        let store = try DatabaseManager.inMemory()
        let id = try await enqueue(.submitReview(draft(headOid: "head-1")), in: store)
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let row = try await store.outboxItem(id: id)
        XCTAssertEqual(row?.state, .failed)
        guard case .failed(let reason) = OutboxWriteOutcome(row: row) else {
            return XCTFail("a 4xx is given up on rather than parked")
        }
        XCTAssertEqual(reason?.contains("line not in diff"), true)
    }

    func testARetryableFailureReadsBackAsStillQueued() async throws {
        // The outcome that is not news: the row is on disk, the engine will try again, and the
        // toast may still promise what the outbox promises (ADR 0006).
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        await github.setSubmitError(.server(status: 502, message: "bad gateway"))
        let store = try DatabaseManager.inMemory()
        let id = try await enqueue(.submitReview(draft(headOid: "head-1")), in: store)
        let engine = makeEngine(github: github, store: store)

        await engine.drainOutbox()

        let row = try await store.outboxItem(id: id)
        XCTAssertEqual(row?.state, .pending)
        XCTAssertEqual(OutboxWriteOutcome(row: row), .queued)
    }
}
