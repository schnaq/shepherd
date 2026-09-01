import Foundation
import ShepherdCore
import XCTest

@testable import ShepherdPersistence

/// Bulk triage lands in the outbox and nowhere else (ADR 0015).
///
/// The app's write surface enqueues exactly the writes ``BulkTriagePlan/writes(mergeMethod:existingDrafts:now:)``
/// produces, so asserting them against a real (in-memory) database is what proves that a bulk
/// run is n ordinary outbox rows — with the retry, offline and staleness behaviour that comes
/// with them — rather than a second write path.
final class BulkTriageOutboxTests: XCTestCase {
    private func greenRow(
        id: String,
        number: Int,
        headRefOid: String = "abc123",
        reviewDecision: ReviewDecision? = nil
    ) -> PullRequestSummary {
        var row = PersistenceFixtures.summary(
            id: id,
            number: number,
            headRefOid: headRefOid,
            checkRollup: CheckRollup(state: .success, total: 2, successCount: 2)
        )
        row.reviewDecision = reviewDecision
        return row
    }

    /// Enqueues a plan the way `PullRequestActions` does: one batched transaction for every
    /// draft and every outbox row.
    private func queue(
        _ plan: BulkTriagePlan,
        mergeMethod: String,
        into database: DatabaseManager,
        drafts: [String: ReviewDraft] = [:]
    ) async throws -> Int {
        let writes = plan.writes(mergeMethod: mergeMethod, existingDrafts: drafts)
        try await database.saveBulkTriage(writes: writes)
        return writes.count
    }

    func testApprovingThreePullRequestsEnqueuesThreeReviewsAndThreeDrafts() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = (1...3).map { greenRow(id: "PR_\($0)", number: $0, headRefOid: "head\($0)") }
        let plan = BulkTriagePlan.make(action: .approve, pullRequests: rows)

        let written = try await queue(plan, mergeMethod: "squash", into: database)

        XCTAssertEqual(written, 3)
        let items = try await database.allOutboxItems()
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.prID), ["PR_1", "PR_2", "PR_3"])
        XCTAssertEqual(items.map(\.number), [1, 2, 3])
        XCTAssertEqual(items.map(\.action.kind), ["submitReview", "submitReview", "submitReview"])
        XCTAssertTrue(items.allSatisfy { $0.state == .pending })
        XCTAssertTrue(items.allSatisfy { $0.repo == PersistenceFixtures.repo })
        let pendingCount = try await database.pendingOutboxCount()
        XCTAssertEqual(pendingCount, 3)

        // Each row's payload is anchored to the head the user saw, and the draft is on disk so
        // the approval survives a crash between enqueue and drain.
        for (index, item) in items.enumerated() {
            guard case .submitReview(let draft) = item.action else {
                XCTFail("expected a review submission")
                return
            }
            XCTAssertEqual(draft.verdict, .approve)
            XCTAssertEqual(draft.summaryBody, "")
            XCTAssertEqual(draft.basedOnHeadOid, "head\(index + 1)")
            let stored = try await database.fetchDraft(prID: item.prID)
            XCTAssertEqual(stored?.verdict, .approve)
            XCTAssertEqual(stored?.basedOnHeadOid, "head\(index + 1)")
        }
        let idsWithDrafts = try await database.pullRequestIDsWithDrafts()
        XCTAssertEqual(idsWithDrafts.sorted(), ["PR_1", "PR_2", "PR_3"])
    }

    func testApproveAndMergeEnqueuesTwoRowsPerPullRequestInSendOrder() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = [
            greenRow(id: "PR_1", number: 1, headRefOid: "head1"),
            greenRow(id: "PR_2", number: 2, headRefOid: "head2", reviewDecision: .approved),
        ]
        let plan = BulkTriagePlan.make(action: .approveAndMerge, pullRequests: rows)

        _ = try await queue(plan, mergeMethod: "rebase", into: database)

        // `PR_2` is already approved, so it contributes the merge alone.
        let items = try await database.allOutboxItems()
        XCTAssertEqual(
            items.map { "\($0.prID):\($0.action.kind)" },
            ["PR_1:submitReview", "PR_1:merge", "PR_2:merge"]
        )
        guard case .merge(let method, let expectedHeadOid) = items[1].action else {
            XCTFail("expected a merge action")
            return
        }
        XCTAssertEqual(method, "rebase")
        XCTAssertEqual(expectedHeadOid, "head1")

        // The drain claims rows oldest first, so the approval is sent before its merge.
        let claimed = try await database.claimReadyOutboxItems()
        XCTAssertEqual(
            claimed.map { "\($0.prID):\($0.action.kind)" },
            ["PR_1:submitReview", "PR_1:merge", "PR_2:merge"]
        )
    }

    func testSkippedPullRequestsNeverReachTheOutbox() async throws {
        let database = try DatabaseManager.inMemory()
        var red = greenRow(id: "PR_red", number: 2)
        red.checkRollup = CheckRollup(state: .failure, total: 2, successCount: 1, failureCount: 1)
        var draftPR = greenRow(id: "PR_draft", number: 3)
        draftPR.isDraft = true
        let plan = BulkTriagePlan.make(
            action: .approveAndMerge,
            pullRequests: [greenRow(id: "PR_ok", number: 1), red, draftPR]
        )

        _ = try await queue(plan, mergeMethod: "squash", into: database)

        let items = try await database.allOutboxItems()
        XCTAssertEqual(Set(items.map(\.prID)), ["PR_ok"])
        XCTAssertEqual(items.count, 2)
        let redDraft = try await database.fetchDraft(prID: "PR_red")
        XCTAssertNil(redDraft)
        let draftDraft = try await database.fetchDraft(prID: "PR_draft")
        XCTAssertNil(draftDraft)
    }

    func testAnExistingDraftKeepsItsCommentsWhenBulkApproved() async throws {
        let database = try DatabaseManager.inMemory()
        let row = greenRow(id: "PR_1", number: 1)
        let existing = PersistenceFixtures.draft(prID: row.id, headRefOid: row.headRefOid)
        try await database.saveDraft(existing)

        let plan = BulkTriagePlan.make(action: .approve, pullRequests: [row])
        _ = try await queue(plan, mergeMethod: "squash", into: database, drafts: [row.id: existing])

        let stored = try await database.fetchDraft(prID: row.id)
        XCTAssertEqual(stored?.verdict, .approve)
        XCTAssertEqual(stored?.comments.count, existing.comments.count)
        XCTAssertEqual(stored?.summaryBody, existing.summaryBody)
    }

    /// The batch is one transaction, so an empty plan writes nothing and is not an error.
    func testQueueingAnEmptyPlanIsANoOp() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveBulkTriage(writes: [])
        let outboxCount = try await database.allOutboxItems().count
        XCTAssertEqual(outboxCount, 0)
        let draftIDs = try await database.pullRequestIDsWithDrafts()
        XCTAssertEqual(draftIDs, [])
    }

    /// What the app reads before it builds its writes: every existing draft in one pass, with the
    /// inline comments still attached to the right pull request and still in their own order.
    func testFetchingDraftsInBulkReturnsOnlyTheOnesThatExistWithTheirComments() async throws {
        let database = try DatabaseManager.inMemory()
        let first = PersistenceFixtures.draft(prID: "PR_1", headRefOid: "head1")
        let second = PersistenceFixtures.draft(prID: "PR_2", headRefOid: "head2")
        try await database.saveDraft(first)
        try await database.saveDraft(second)

        let drafts = try await database.fetchDrafts(
            // A duplicate and an id with no draft are both harmless.
            prIDs: ["PR_1", "PR_2", "PR_2", "PR_missing"]
        )

        XCTAssertEqual(drafts.keys.sorted(), ["PR_1", "PR_2"])
        XCTAssertEqual(drafts["PR_1"], first)
        XCTAssertEqual(drafts["PR_2"], second)
        // Same answer as reading them one at a time, which is what this replaced.
        for prID in ["PR_1", "PR_2"] {
            let single = try await database.fetchDraft(prID: prID)
            XCTAssertEqual(drafts[prID], single)
        }
        XCTAssertNil(drafts["PR_missing"])
        let emptyFetch = try await database.fetchDrafts(prIDs: [])
        XCTAssertTrue(emptyFetch.isEmpty)
    }
}
