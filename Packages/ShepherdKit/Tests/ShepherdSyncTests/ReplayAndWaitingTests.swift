import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence
import XCTest
@testable import ShepherdSync

final class ReplayAndWaitingTests: XCTestCase {
    private let repo = SyncFixtures.repo
    private let now = Date(timeIntervalSince1970: 1_788_162_000)
    private let me = ShepherdCore.Actor(login: "n2o", kind: .human)
    private let someoneElse = ShepherdCore.Actor(login: "alex", kind: .human)

    private func makeEngine(
        github: MockGitHub,
        store: any SyncStoring,
        viewer: String? = "n2o",
        issueWrites: (any IssueWriting)? = nil
    ) -> SyncEngine {
        SyncEngine(
            github: github,
            store: store,
            issueWrites: issueWrites,
            configuration: SyncConfiguration(viewerLogin: viewer),
            sleeper: RecordingSleeper(),
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )
    }

    /// `attemptCount: 1` is a row an earlier attempt claimed: the claim makes it 2.
    @discardableResult
    private func enqueue(_ action: OutboxAction, in store: DatabaseManager, attempts: Int) async throws -> UUID {
        let id = UUID()
        try await store.enqueue(OutboxItem(
            id: id, prID: "PR_1", repo: repo, number: 1, action: action,
            createdAt: now, attemptCount: attempts
        ))
        return id
    }

    private func detail(threads: [ReviewThread] = [], items: [ConversationItem]? = []) -> PullRequestDetail {
        PullRequestDetail(
            summary: SyncFixtures.summary(id: "PR_1", number: 1),
            threads: threads,
            conversation: items.map { PullRequestConversation(items: $0) }
        )
    }

    private func thread(replyBy author: ShepherdCore.Actor, body: String, at offset: TimeInterval) -> ReviewThread {
        ReviewThread(id: "PRRT_1", path: "A.swift", line: 3, comments: [
            ReviewComment(id: "C1", databaseID: 42, author: someoneElse, bodyMarkdown: "Why?", createdAt: now.addingTimeInterval(-600)),
            ReviewComment(id: "C2", databaseID: 43, author: author, bodyMarkdown: body, createdAt: now.addingTimeInterval(offset)),
        ])
    }

    // MARK: - Replay

    func testAFirstAttemptNeverReadsThePullRequest() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        try await enqueue(.replyToComment(commentDatabaseID: 42, body: "Thanks!"), in: store, attempts: 0)
        await makeEngine(github: github, store: store).drainOutbox()
        let requests = await github.detailRequests
        let replies = await github.replies
        XCTAssertEqual(requests, [])
        XCTAssertEqual(replies.count, 1)
    }

    func testARetriedReplyThatAlreadyLandedIsNotPostedAgain() async throws {
        let github = MockGitHub()
        await github.setDetail(detail(threads: [thread(replyBy: me, body: "Thanks!\r\n", at: 2)]), repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        try await enqueue(.replyToComment(commentDatabaseID: 42, body: "Thanks!"), in: store, attempts: 1)
        await makeEngine(github: github, store: store).drainOutbox()
        let replies = await github.replies
        XCTAssertEqual(replies.count, 0, "the reply is already on GitHub")
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testARetriedReplyIsPostedWhenOnlySomeoneElseSaidTheSame() async throws {
        let github = MockGitHub()
        await github.setDetail(detail(threads: [thread(replyBy: someoneElse, body: "Thanks!", at: 2)]), repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        try await enqueue(.replyToComment(commentDatabaseID: 42, body: "Thanks!"), in: store, attempts: 1)
        await makeEngine(github: github, store: store).drainOutbox()
        let replies = await github.replies
        XCTAssertEqual(replies.count, 1)
    }

    func testARetryWhoseReadFailsSendsNothingAndStaysQueued() async throws {
        let github = MockGitHub()
        await github.setDetailError(.transport(message: "offline"))
        let store = try DatabaseManager.inMemory()
        try await enqueue(.replyToComment(commentDatabaseID: 42, body: "Thanks!"), in: store, attempts: 1)
        await makeEngine(github: github, store: store).drainOutbox()
        let replies = await github.replies
        XCTAssertEqual(replies.count, 0)
        let remaining = try await store.allOutboxItems()
        XCTAssertEqual(remaining.first?.state, .pending)
        XCTAssertEqual(remaining.first?.attemptCount, 2, "the row stays in doubt")
    }

    func testARetriedReviewThatLandedClearsTheDraftAndIsNotResubmitted() async throws {
        let github = MockGitHub()
        let review = ConversationReview(id: "PRR_9", author: me, state: .approved, bodyMarkdown: "Ship it.", createdAt: now.addingTimeInterval(1), commitOid: "head-1")
        await github.setDetail(detail(items: [.review(review)]), repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let draft = ReviewDraft(prID: "PR_1", verdict: .approve, summaryBody: "Ship it.", basedOnHeadOid: "head-1", updatedAt: now)
        try await store.saveDraft(draft)
        try await enqueue(.submitReview(draft), in: store, attempts: 1)
        let engine = makeEngine(github: github, store: store)
        let stream = engine.events
        let collected = Task { () -> [SyncEvent] in
            var events: [SyncEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        await engine.drainOutbox()
        await engine.shutdown()
        let events = await collected.value
        let submitted = await github.submittedDrafts
        XCTAssertEqual(submitted.count, 0)
        let remainingDraft = try await store.fetchDraft(prID: "PR_1")
        XCTAssertNil(remainingDraft)
        XCTAssertTrue(events.contains { if case .mutationSent = $0 { return true } else { return false } })
    }

    func testAReviewWhoseAnswerWasUnreadableIsSentNotFailed() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        await github.setSubmitError(.decoding(message: "Review response was missing an id"))
        let store = try DatabaseManager.inMemory()
        let draft = ReviewDraft(prID: "PR_1", verdict: .approve, summaryBody: "Ship it.", basedOnHeadOid: "head-1", updatedAt: now)
        try await store.saveDraft(draft)
        try await enqueue(.submitReview(draft), in: store, attempts: 0)
        await makeEngine(github: github, store: store).drainOutbox()
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty, "a failed row would be one Retry away from a second review")
        let remainingDraft = try await store.fetchDraft(prID: "PR_1")
        XCTAssertNil(remainingDraft)
    }

    func testARetriedReviewOnAnotherCommitIsSubmitted() async throws {
        let github = MockGitHub()
        let earlier = ConversationReview(id: "PRR_8", author: me, state: .approved, bodyMarkdown: "Ship it.", createdAt: now.addingTimeInterval(1), commitOid: "head-0")
        await github.setDetail(detail(items: [.review(earlier)]), repo: repo, number: 1)
        await github.setHeadOid("head-1", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let draft = ReviewDraft(prID: "PR_1", verdict: .approve, summaryBody: "Ship it.", basedOnHeadOid: "head-1", updatedAt: now)
        try await enqueue(.submitReview(draft), in: store, attempts: 1)
        await makeEngine(github: github, store: store).drainOutbox()
        let submitted = await github.submittedDrafts
        XCTAssertEqual(submitted.count, 1, "an approval of an older commit is not this one")
    }

    func testARetriedReviewCommentThatLandedIsNotPostedAgain() async throws {
        let github = MockGitHub()
        let landed = ReviewThread(id: "PRRT_2", path: "a.swift", line: nil, comments: [
            ReviewComment(id: "C9", databaseID: 99, author: me, bodyMarkdown: "Nit", createdAt: now.addingTimeInterval(2)),
        ])
        await github.setDetail(detail(threads: [landed]), repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let comment = DraftComment(path: "a.swift", line: 4, body: "Nit")
        try await enqueue(.addReviewComment(comment, commitOid: "head-1"), in: store, attempts: 1)
        await makeEngine(github: github, store: store).drainOutbox()
        let posted = await github.reviewComments
        XCTAssertEqual(posted.count, 0, "the comment is on GitHub, outdated thread and all")
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testARetriedReviewCommentOnAnotherFileIsPosted() async throws {
        let github = MockGitHub()
        let elsewhere = ReviewThread(id: "PRRT_2", path: "b.swift", line: 4, comments: [
            ReviewComment(id: "C9", databaseID: 99, author: me, bodyMarkdown: "Nit", createdAt: now.addingTimeInterval(2)),
        ])
        await github.setDetail(detail(threads: [elsewhere]), repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        try await enqueue(.addReviewComment(DraftComment(path: "a.swift", line: 4, body: "Nit"), commitOid: "head-1"), in: store, attempts: 1)
        await makeEngine(github: github, store: store).drainOutbox()
        let posted = await github.reviewComments
        XCTAssertEqual(posted.count, 1)
    }

    func testARetriedConversationCommentThatLandedIsNotPostedAgain() async throws {
        let github = MockGitHub()
        let posted = ConversationComment(id: "IC_1", author: me, bodyMarkdown: "Two thoughts.", createdAt: now.addingTimeInterval(3))
        await github.setDetail(detail(items: [.comment(posted)]), repo: repo, number: 1)
        let writer = MockIssueWriter()
        let store = try DatabaseManager.inMemory()
        try await enqueue(.addPullRequestComment(body: "Two thoughts."), in: store, attempts: 1)
        await makeEngine(github: github, store: store, issueWrites: writer).drainOutbox()
        let comments = await writer.comments
        XCTAssertEqual(comments, [])
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testARetriedCloseClosesAgainButDoesNotRepostItsComment() async throws {
        let github = MockGitHub()
        let posted = ConversationComment(id: "IC_1", author: me, bodyMarkdown: "Superseded by #191.", createdAt: now.addingTimeInterval(3))
        await github.setDetail(detail(items: [.comment(posted)]), repo: repo, number: 1)
        let writer = MockIssueWriter()
        let store = try DatabaseManager.inMemory()
        try await enqueue(.closePullRequest(comment: "Superseded by #191."), in: store, attempts: 1)
        await makeEngine(github: github, store: store, issueWrites: writer).drainOutbox()
        let order = await writer.writeLog
        XCTAssertEqual(order, ["state:closed"], "closing twice is harmless, commenting twice is not")
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testARetryWithoutASignedInLoginSendsNothing() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        try await enqueue(.replyToComment(commentDatabaseID: 42, body: "Thanks!"), in: store, attempts: 1)
        await makeEngine(github: github, store: store, viewer: nil).drainOutbox()
        let replies = await github.replies
        XCTAssertEqual(replies.count, 0)
        let remaining = try await store.allOutboxItems()
        XCTAssertEqual(remaining.first?.state, .pending, "retried later, never sent blind")
    }

    /// Edits, (un)resolves, reactions and ready-for-review repeat harmlessly; a delete that finds
    /// nothing and a merge that finds it merged are decided by answers of their own, whatever the
    /// attempt count (`OutboxDrainTests.testADeleteOfACommentThatIsAlreadyGoneIsSent`,
    /// `testAMergeGitHubHasAlreadyLandedIsSentRatherThanFailed`).
    func testTheWritesThatRepeatHarmlesslyAreRetriedWithoutAProbe() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        try await enqueue(.resolveThread(threadID: "PRRT_1"), in: store, attempts: 1)
        try await enqueue(.editComment(.issueComment(databaseID: 7), body: "Fixed typo"), in: store, attempts: 1)
        try await enqueue(.react(subjectID: "IC_1", content: .thumbsUp, adding: true), in: store, attempts: 1)
        try await enqueue(.unresolveThread(threadID: "PRRT_2"), in: store, attempts: 1)
        try await enqueue(.markReadyForReview, in: store, attempts: 1)
        await makeEngine(github: github, store: store).drainOutbox()
        let probes = await github.detailRequests
        XCTAssertEqual(probes, [])
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testARetriedConversationCommentIsUndecidedWhenTheConversationWasNotRead() {
        let landed = SyncEngine.landed(.addPullRequestComment(body: "LGTM"), in: detail(items: nil), viewer: "n2o", since: now)
        XCTAssertNil(landed)
    }

    func testAPostFromBeforeTheRowWasQueuedDoesNotCount() {
        let old = ConversationComment(id: "IC_1", author: me, bodyMarkdown: "LGTM", createdAt: now.addingTimeInterval(-3_600))
        let landed = SyncEngine.landed(
            .addPullRequestComment(body: "LGTM"), in: detail(items: [.comment(old)]), viewer: "N2O",
            since: now.addingTimeInterval(-SyncEngine.replayClockSkew)
        )
        XCTAssertEqual(landed, false)
    }

    // MARK: - Waiting

    /// Polls on the clock rather than counting yields, which run out on a loaded CI machine.
    private func eventually(_ what: String, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(what)
    }

    private func waitForGate(_ github: MockGitHub) async throws {
        await eventually("never reached the gate") { await github.gateWaiterCount >= 1 }
    }

    private func waitForParkedDrain(_ engine: SyncEngine) async {
        await eventually("the waiter never parked") { await engine.drainWaiters.count == 1 }
    }

    private func drainParkedInSubmit() async throws -> (MockGitHub, DatabaseManager, SyncEngine, Task<Void, Never>) {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let draft = ReviewDraft(prID: "PR_1", verdict: .approve, summaryBody: "Ship it.", basedOnHeadOid: "head-1", updatedAt: now)
        try await enqueue(.submitReview(draft), in: store, attempts: 0)
        let engine = makeEngine(github: github, store: store)
        await github.closeGate()
        let first = Task { await engine.drainOutbox() }
        try await waitForGate(github)
        return (github, store, engine, first)
    }

    func testADefaultDrainStillReturnsWhileAnotherIsInFlight() async throws {
        let (github, _, engine, first) = try await drainParkedInSubmit()
        await engine.drainOutbox()
        let submitted = await github.submittedDrafts
        XCTAssertEqual(submitted.count, 0, "returned before the in-flight submit finished")
        await github.openGate()
        await first.value
    }

    func testAnAwaitingDrainReturnsOnlyOnceTheInFlightDrainIsDone() async throws {
        let (github, store, engine, first) = try await drainParkedInSubmit()
        let finished = Flag()
        let waiter = Task {
            await engine.drainOutbox(awaitingInFlight: true)
            await finished.set()
        }
        await waitForParkedDrain(engine)
        let early = await finished.value
        XCTAssertFalse(early, "the waiter returned while the submit was still in flight")
        await github.openGate()
        await waiter.value
        let submitted = await github.submittedDrafts
        XCTAssertEqual(submitted.count, 1)
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty)
        await first.value
    }

    func testAnAwaitingSyncReturnsOnlyOnceTheInFlightSweepIsDone() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)
        await github.closeGate()
        let first = Task { try await engine.syncNow() }
        try await waitForGate(github)
        let finished = Flag()
        let waiter = Task {
            try await engine.syncNow(awaitingInFlight: true)
            await finished.set()
        }
        await eventually("the waiter never parked") { await engine.sweepWaiters.count == 1 }
        let early = await finished.value
        XCTAssertFalse(early, "the waiter returned while the sweep was still reading")
        await github.openGate()
        try await waiter.value
        try await first.value
        let searches = await github.searchCallCount
        XCTAssertEqual(searches, 2, "the waiter's request is the running sweep's extra lap")
    }

    func testAWaiterOnAFailedSweepGetsItsError() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)
        await github.closeGate()
        let first = Task { try await engine.syncNow() }
        try await waitForGate(github)
        let waiter = Task { try await engine.syncNow(awaitingInFlight: true) }
        await eventually("the waiter never parked") { await engine.sweepWaiters.count == 1 }
        await github.setSearchError(.rateLimited(retryAfter: 30, resetAt: nil))
        await github.openGate()
        do {
            try await waiter.value
            XCTFail("a waiter must not report a sweep that failed as done")
        } catch {}
        _ = try? await first.value
    }

    func testACancelledWaiterStopsWaitingWhileTheDrainCarriesOn() async throws {
        let (github, store, engine, first) = try await drainParkedInSubmit()
        let waiter = Task { await engine.drainOutbox(awaitingInFlight: true) }
        await waitForParkedDrain(engine)
        waiter.cancel()
        await waiter.value
        let before = await github.submittedDrafts
        XCTAssertEqual(before.count, 0)
        await github.openGate()
        await first.value
        let remaining = try await store.allOutboxItems()
        XCTAssertTrue(remaining.isEmpty, "the drain the waiter joined still finished")
    }

    /// `stop()` cancels the loop's inline drain; a waiter must not run the skipped lap itself
    /// afterwards, or it would write behind "Sign out & erase".
    func testAWaiterOnACancelledDrainDoesNotRunTheSkippedLap() async throws {
        let (github, store, engine, first) = try await drainParkedInSubmit()
        try await enqueue(.resolveThread(threadID: "PRRT_LATE"), in: store, attempts: 0)
        let waiter = Task { await engine.drainOutbox(awaitingInFlight: true) }
        await waitForParkedDrain(engine)
        first.cancel()
        await github.openGate()
        await first.value
        await waiter.value
        let resolved = await github.resolvedThreads
        XCTAssertEqual(resolved, [], "the lap the cancelled drain skipped stays skipped")
    }
}

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}
