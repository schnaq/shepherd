import Foundation
import ShepherdCore
import XCTest
@testable import ShepherdPersistence

/// What the user can do with a parked row, and what replaces or drops one by itself
/// (ADR 0006's 2026-10-29 amendment).
final class ParkedOutboxTests: XCTestCase {
    private func row(
        _ action: OutboxAction,
        prID: String = "PR_1",
        createdAt: TimeInterval = 1_788_161_000
    ) -> OutboxItem {
        OutboxItem(
            prID: prID,
            repo: PersistenceFixtures.repo,
            number: 128,
            action: action,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    /// Enqueues `item` and parks it, the way the drain does.
    private func park(_ item: OutboxItem, in database: DatabaseManager) async throws {
        try await database.enqueue(item)
        try await database.markOutboxItemConflicted(id: item.id, reason: "Head moved")
    }

    private func merge(head: String = "abc123") -> OutboxAction {
        .merge(method: "squash", expectedHeadOid: head)
    }

    // MARK: - Discard

    func testDiscardingAParkedReviewDeletesTheRowAndItsDraft() async throws {
        let database = try DatabaseManager.inMemory()
        let draft = PersistenceFixtures.draft()
        try await database.saveDraft(draft)
        let parked = row(.submitReview(draft))
        try await park(parked, in: database)

        try await database.discardConflictedOutboxItem(id: parked.id)

        let rows = try await database.allOutboxItems()
        XCTAssertTrue(rows.isEmpty)
        let stored = try await database.fetchDraft(prID: draft.prID)
        XCTAssertNil(stored, "a draft left behind would keep the pull request pinned in the inbox")
    }

    func testDiscardingAParkedMergeLeavesTheDraftAlone() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveDraft(PersistenceFixtures.draft())
        let parked = row(merge())
        try await park(parked, in: database)

        try await database.discardConflictedOutboxItem(id: parked.id)

        let rows = try await database.allOutboxItems()
        XCTAssertTrue(rows.isEmpty)
        let stored = try await database.fetchDraft(prID: "PR_1")
        XCTAssertNotNil(stored)
    }

    func testDiscardingLeavesARowThatIsNotParked() async throws {
        let database = try DatabaseManager.inMemory()
        let draft = PersistenceFixtures.draft()
        try await database.saveDraft(draft)
        let pending = row(.submitReview(draft))
        try await database.enqueue(pending)

        try await database.discardConflictedOutboxItem(id: pending.id)

        let stored = try await database.outboxItem(id: pending.id)
        XCTAssertEqual(stored?.state, .pending)
        let storedDraft = try await database.fetchDraft(prID: draft.prID)
        XCTAssertNotNil(storedDraft)
    }

    func testConflictedOutboxItemsListsOnlyParkedRows() async throws {
        let database = try DatabaseManager.inMemory()
        let parked = row(merge())
        try await park(parked, in: database)
        try await database.enqueue(row(.resolveThread(threadID: "PRRT_1")))

        let listed = try await database.conflictedOutboxItems()
        XCTAssertEqual(listed.map(\.id), [parked.id])
        XCTAssertEqual(listed.first?.lastError, "Head moved")
    }

    // MARK: - Supersede

    func testANewReviewReplacesTheParkedOneAndKeepsTheDraft() async throws {
        let database = try DatabaseManager.inMemory()
        let draft = PersistenceFixtures.draft()
        try await database.saveDraft(draft)
        let parked = row(.submitReview(draft))
        try await park(parked, in: database)
        let otherPullRequest = row(.submitReview(draft), prID: "PR_2")
        try await park(otherPullRequest, in: database)
        let parkedMerge = row(merge())
        try await park(parkedMerge, in: database)

        let resubmitted = row(.submitReview(draft), createdAt: 1_788_162_000)
        try await database.enqueue(resubmitted)

        let ids = Set(try await database.allOutboxItems().map(\.id))
        XCTAssertEqual(
            ids,
            [otherPullRequest.id, parkedMerge.id, resubmitted.id],
            "only this pull request's parked review is replaced"
        )
        let stored = try await database.fetchDraft(prID: draft.prID)
        XCTAssertNotNil(stored, "the new row was built from this draft")
    }

    func testABulkTriageMergeReplacesAParkedMerge() async throws {
        let database = try DatabaseManager.inMemory()
        let parked = row(merge(head: "old"))
        try await park(parked, in: database)

        let queued = row(merge(head: "new"), createdAt: 1_788_162_000)
        try await database.saveBulkTriage(writes: [BulkTriageWrite(item: queued)])

        let ids = try await database.allOutboxItems().map(\.id)
        XCTAssertEqual(ids, [queued.id])
    }

    func testAParkedRowOfAnotherKindIsNotReplaced() async throws {
        let database = try DatabaseManager.inMemory()
        let parked = row(.addPullRequestComment(body: "Hi"))
        try await park(parked, in: database)

        try await database.enqueue(row(.addPullRequestComment(body: "Hi again")))

        let stored = try await database.outboxItem(id: parked.id)
        XCTAssertEqual(stored?.state, .conflicted, "only a review, a merge and a branch update are replaced")
    }

    // MARK: - Send anyway

    func testSendingAParkedReviewAnywayRequeuesItWithTheFlag() async throws {
        let database = try DatabaseManager.inMemory()
        let parked = row(.submitReview(PersistenceFixtures.draft()))
        try await park(parked, in: database)

        try await database.sendConflictedReviewAnyway(id: parked.id)

        let stored = try await database.outboxItem(id: parked.id)
        XCTAssertEqual(stored?.state, .pending)
        XCTAssertNil(stored?.lastError)
        XCTAssertEqual(stored?.attemptCount, 0)
        guard case .submitReview(let draft) = stored?.action else {
            return XCTFail("still a review")
        }
        XCTAssertEqual(draft.sendsAgainstReviewedCommit, true)
        XCTAssertEqual(draft.basedOnHeadOid, "abc123", "still pinned to the reviewed commit")
    }

    func testSendAnywayLeavesAParkedMergeParked() async throws {
        let database = try DatabaseManager.inMemory()
        let parked = row(merge())
        try await park(parked, in: database)

        try await database.sendConflictedReviewAnyway(id: parked.id)

        let stored = try await database.outboxItem(id: parked.id)
        XCTAssertEqual(stored?.state, .conflicted)
    }

    // MARK: - Dropped with the pull request

    func testASweepThatNoLongerSeesAPullRequestDropsItsParkedMergeButNotItsReview() async throws {
        let database = try DatabaseManager.inMemory()
        let gone = PersistenceFixtures.summary(id: "PR_1")
        let open = PersistenceFixtures.summary(id: "PR_2", number: 129)
        try await database.savePullRequestSummaries([gone, open])
        let goneMerge = row(merge())
        try await park(goneMerge, in: database)
        let goneUpdate = row(.updateBranch(expectedHeadOid: "abc123"))
        try await park(goneUpdate, in: database)
        let openMerge = row(merge(), prID: "PR_2")
        try await park(openMerge, in: database)
        let goneReview = row(.submitReview(PersistenceFixtures.draft(prID: "PR_3")), prID: "PR_3")
        try await park(goneReview, in: database)

        try await database.savePullRequestSummaries([open], pruneMissing: true)

        let ids = Set(try await database.allOutboxItems().map(\.id))
        XCTAssertEqual(ids, [openMerge.id, goneReview.id])
        let remaining = try await database.pullRequestIDs()
        XCTAssertEqual(remaining, ["PR_2"], "nothing pins the merged pull request any more")
    }
}
