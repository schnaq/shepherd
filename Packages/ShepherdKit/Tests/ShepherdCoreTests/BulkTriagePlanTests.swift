import Foundation
import XCTest

@testable import ShepherdCore

/// The partition rules of bulk triage (ADR 0015).
///
/// Every case a user can select is here, because the plan is the only thing standing between a
/// selection and a write: a rule that lived in a view would be untestable, and a rule that
/// silently dropped a row would be invisible.
final class BulkTriagePlanTests: XCTestCase {
    // MARK: - Fixtures

    /// A green pull request: checks passed, mergeable, nobody blocking it.
    private func green(
        id: String = "PR_green",
        number: Int = 1,
        author: ShepherdCore.Actor = BulkTriagePlanTests.agentAuthor,
        reviewDecision: ReviewDecision? = nil,
        relations: Set<Relation> = [.reviewRequested]
    ) -> PullRequestSummary {
        Fixtures.summary(
            id: id,
            number: number,
            author: author,
            reviewDecision: reviewDecision,
            checkRollup: CheckRollup(state: .success, total: 3, successCount: 3),
            relations: relations
        )
    }

    private static let agentAuthor = Fixtures.makeActor(
        "claude[bot]",
        kind: Fixtures.agent("claude-code", "Claude Code")
    )

    private func entry(_ plan: BulkTriagePlan, _ id: String) throws -> BulkTriagePlan.Entry {
        try XCTUnwrap(plan.entries.first { $0.id == id })
    }

    // MARK: - Approve

    func testAGreenAgentPullRequestIsApproved() throws {
        let plan = BulkTriagePlan.make(action: .approve, pullRequests: [green()])
        let entry = try entry(plan, "PR_green")
        XCTAssertEqual(entry.steps, [.approve])
        XCTAssertNil(entry.skipReason)
        XCTAssertTrue(entry.caveats.isEmpty)
        XCTAssertEqual(plan.eligible.count, 1)
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertTrue(plan.isActionable)
    }

    func testFailingChecksConflictsDraftsAndChangeRequestsAreSkippedWithTheirReason() {
        var failing = green(id: "PR_red", number: 2)
        failing.checkRollup = CheckRollup(
            state: .failure,
            total: 3,
            successCount: 2,
            failureCount: 1
        )
        var running = green(id: "PR_running", number: 3)
        running.checkRollup = CheckRollup(state: .pending, total: 3, successCount: 1, pendingCount: 2)
        var conflicting = green(id: "PR_conflict", number: 4)
        conflicting.mergeable = .conflicting
        var draft = green(id: "PR_draft", number: 5)
        draft.isDraft = true
        let changesRequested = green(id: "PR_changes", number: 6, reviewDecision: .changesRequested)

        let plan = BulkTriagePlan.make(
            action: .approve,
            pullRequests: [green(), failing, running, conflicting, draft, changesRequested]
        )

        XCTAssertEqual(plan.eligible.map(\.id), ["PR_green"])
        XCTAssertEqual(
            plan.skipped.map(\.skipReason),
            [.checksFailing, .checksRunning, .conflicting, .draft, .changesRequested]
        )
        // A skipped entry carries no steps, so it cannot contribute a write by accident.
        XCTAssertTrue(plan.skipped.allSatisfy { $0.steps.isEmpty })
        XCTAssertEqual(plan.writes(mergeMethod: "squash").count, 1)
    }

    func testAPullRequestYouOpenedYourselfIsNotApproved() throws {
        let mine = green(id: "PR_mine", relations: [.author])
        let plan = BulkTriagePlan.make(action: .approve, pullRequests: [mine])
        XCTAssertEqual(try entry(plan, "PR_mine").skipReason, .ownPullRequest)
        XCTAssertFalse(plan.isActionable)
    }

    func testAnAlreadyApprovedPullRequestIsSkippedByApproveOnly() throws {
        let approved = green(id: "PR_approved", reviewDecision: .approved)
        let plan = BulkTriagePlan.make(action: .approve, pullRequests: [approved])
        XCTAssertEqual(try entry(plan, "PR_approved").skipReason, .alreadyApproved)
    }

    // MARK: - Approve & merge

    func testApproveAndMergeQueuesTheApprovalBeforeTheMerge() throws {
        let plan = BulkTriagePlan.make(action: .approveAndMerge, pullRequests: [green()])
        XCTAssertEqual(try entry(plan, "PR_green").steps, [.approve, .merge])

        let writes = plan.writes(mergeMethod: "squash", now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].item.action.kind, "submitReview")
        XCTAssertEqual(writes[1].item.action.kind, "merge")
        // The drain sends rows in `createdAt` order, so the approval must sort first.
        XCTAssertLessThan(writes[0].item.createdAt, writes[1].item.createdAt)
    }

    func testApproveAndMergeOnAnAlreadyApprovedPullRequestOnlyMerges() throws {
        let approved = green(id: "PR_approved", reviewDecision: .approved)
        let plan = BulkTriagePlan.make(action: .approveAndMerge, pullRequests: [approved])
        XCTAssertEqual(try entry(plan, "PR_approved").steps, [.merge])
    }

    func testYourOwnAlreadyApprovedPullRequestCanStillBeMerged() throws {
        let mine = green(id: "PR_mine", reviewDecision: .approved, relations: [.author])
        let plan = BulkTriagePlan.make(action: .approveAndMerge, pullRequests: [mine])
        let entry = try entry(plan, "PR_mine")
        XCTAssertNil(entry.skipReason)
        XCTAssertEqual(entry.steps, [.merge])
    }

    // MARK: - Merge only

    func testMergeOnlyRefusesWhatIsNotApprovedYet() throws {
        let plan = BulkTriagePlan.make(
            action: .merge,
            pullRequests: [green(), green(id: "PR_approved", number: 7, reviewDecision: .approved)]
        )
        XCTAssertEqual(try entry(plan, "PR_green").skipReason, .notApproved)
        XCTAssertEqual(try entry(plan, "PR_approved").steps, [.merge])
    }

    // MARK: - Caveats

    func testAPullRequestWithoutChecksGoesAheadWithANote() throws {
        var noChecks = green(id: "PR_nochecks")
        noChecks.checkRollup = nil
        var emptyRollup = green(id: "PR_emptyrollup", number: 8)
        emptyRollup.checkRollup = CheckRollup(state: .none)

        let plan = BulkTriagePlan.make(action: .approve, pullRequests: [noChecks, emptyRollup])

        XCTAssertEqual(try entry(plan, "PR_nochecks").caveats, [.noChecksConfigured])
        XCTAssertEqual(try entry(plan, "PR_emptyrollup").caveats, [.noChecksConfigured])
        XCTAssertEqual(plan.eligible.count, 2)
    }

    func testUnknownMergeabilityIsANoteOnTheMergeStepOnly() throws {
        var unknown = green(id: "PR_unknown")
        unknown.mergeable = .unknown

        let approveOnly = BulkTriagePlan.make(action: .approve, pullRequests: [unknown])
        XCTAssertTrue(try entry(approveOnly, "PR_unknown").caveats.isEmpty)

        let withMerge = BulkTriagePlan.make(action: .approveAndMerge, pullRequests: [unknown])
        XCTAssertEqual(try entry(withMerge, "PR_unknown").caveats, [.mergeabilityUnknown])
    }

    // MARK: - Writes

    func testAWriteCarriesTheHeadTheUserSawAndTheChosenMethod() throws {
        let writes = BulkTriagePlan
            .make(
                action: .merge,
                pullRequests: [green(id: "PR_approved", reviewDecision: .approved)]
            )
            .writes(mergeMethod: "rebase")
        let write = try XCTUnwrap(writes.first)
        XCTAssertNil(write.draft)
        XCTAssertEqual(write.item.prID, "PR_approved")
        XCTAssertEqual(write.item.repo, Fixtures.repo)
        XCTAssertEqual(write.item.state, .pending)
        guard case .merge(let method, let expectedHeadOid) = write.item.action else {
            XCTFail("expected a merge action")
            return
        }
        XCTAssertEqual(method, "rebase")
        XCTAssertEqual(expectedHeadOid, "abc123")
    }

    func testAnApprovalReusesTheLocalDraftInsteadOfDiscardingItsComments() throws {
        let row = green()
        let existing = ReviewDraft(
            prID: row.id,
            verdict: nil,
            summaryBody: "Two nits.",
            comments: [DraftComment(path: "App.swift", line: 12, body: "Rename this.")],
            basedOnHeadOid: row.headRefOid
        )
        let writes = BulkTriagePlan
            .make(action: .approve, pullRequests: [row])
            .writes(mergeMethod: "squash", existingDrafts: [row.id: existing])

        let write = try XCTUnwrap(writes.first)
        let draft = try XCTUnwrap(write.draft)
        XCTAssertEqual(draft.verdict, .approve)
        XCTAssertEqual(draft.summaryBody, "Two nits.")
        XCTAssertEqual(draft.comments.count, 1)
        XCTAssertEqual(draft.basedOnHeadOid, "abc123")
        guard case .submitReview(let enqueued) = write.item.action else {
            XCTFail("expected a review submission")
            return
        }
        // The row carries the same draft that gets persisted; the drain needs no second read.
        XCTAssertEqual(enqueued, draft)
    }

    func testACommentFreeDraftIsReanchoredToTheHeadTheUserActedOn() throws {
        // The scenario that used to lose the approval: a bare verdict was drafted on an older
        // commit, the pull request was pushed to, and it is green again. The draft hangs off no
        // particular line, so the queued approval is anchored to the head in the dialog —
        // otherwise the drain would park it as a conflict and nothing would ever be sent.
        let row = green()
        let existing = ReviewDraft(
            prID: row.id,
            verdict: nil,
            summaryBody: "Looks fine.",
            comments: [],
            basedOnHeadOid: "old000"
        )
        let plan = BulkTriagePlan.make(
            action: .approve,
            pullRequests: [row],
            existingDrafts: [row.id: existing]
        )
        XCTAssertTrue(try entry(plan, row.id).caveats.isEmpty)

        let writes = plan.writes(mergeMethod: "squash", existingDrafts: [row.id: existing])
        let draft = try XCTUnwrap(writes.first?.draft)
        XCTAssertEqual(draft.basedOnHeadOid, row.headRefOid)
        XCTAssertEqual(draft.summaryBody, "Looks fine.")
        XCTAssertEqual(draft.verdict, .approve)
        XCTAssertFalse(draft.isStale(against: row.headRefOid))
    }

    func testADraftWithCommentsKeepsItsAnchorAndSaysSoBeforeTheConfirm() throws {
        // The mirror image: inline comments reference lines of the commit they were written on,
        // so the anchor stays and the drain's staleness check keeps them off the wrong lines.
        // What changes is that the dialog says it will happen instead of letting the user find
        // out from an alert afterwards.
        let row = green()
        let existing = ReviewDraft(
            prID: row.id,
            verdict: nil,
            summaryBody: "Two nits.",
            comments: [DraftComment(path: "App.swift", line: 12, body: "Rename this.")],
            basedOnHeadOid: "old000"
        )
        let plan = BulkTriagePlan.make(
            action: .approve,
            pullRequests: [row],
            existingDrafts: [row.id: existing]
        )
        let entry = try entry(plan, row.id)
        XCTAssertEqual(entry.caveats, [.staleDraftComments])
        // A caveat is a note, not a refusal: the entry still goes ahead.
        XCTAssertTrue(entry.isEligible)

        let writes = plan.writes(mergeMethod: "squash", existingDrafts: [row.id: existing])
        let draft = try XCTUnwrap(writes.first?.draft)
        XCTAssertEqual(draft.basedOnHeadOid, "old000")
        XCTAssertEqual(draft.comments.count, 1)
        XCTAssertTrue(draft.isStale(against: row.headRefOid))
    }

    func testADraftOnTheCurrentHeadIsNotFlaggedAsStale() throws {
        let row = green()
        let existing = ReviewDraft(
            prID: row.id,
            verdict: nil,
            comments: [DraftComment(path: "App.swift", line: 12, body: "Rename this.")],
            basedOnHeadOid: row.headRefOid
        )
        let plan = BulkTriagePlan.make(
            action: .approve,
            pullRequests: [row],
            existingDrafts: [row.id: existing]
        )
        XCTAssertTrue(try entry(plan, row.id).caveats.isEmpty)
        // A merge-only run writes no review, so a stale draft is not its problem.
        let mergeOnly = BulkTriagePlan.make(
            action: .merge,
            pullRequests: [green(id: "PR_approved", reviewDecision: .approved)],
            existingDrafts: [
                "PR_approved": ReviewDraft(
                    prID: "PR_approved",
                    comments: [DraftComment(path: "App.swift", line: 3, body: "…")],
                    basedOnHeadOid: "old000"
                ),
            ]
        )
        XCTAssertTrue(try entry(mergeOnly, "PR_approved").caveats.isEmpty)
    }

    func testWritesOfSeveralPullRequestsStayInSelectionOrder() {
        let rows = (1...3).map { green(id: "PR_\($0)", number: $0) }
        let writes = BulkTriagePlan
            .make(action: .approveAndMerge, pullRequests: rows)
            .writes(mergeMethod: "merge", now: Date(timeIntervalSince1970: 5_000))

        XCTAssertEqual(writes.map(\.item.prID), ["PR_1", "PR_1", "PR_2", "PR_2", "PR_3", "PR_3"])
        XCTAssertEqual(writes.map(\.item.createdAt), writes.map(\.item.createdAt).sorted())
        XCTAssertEqual(Set(writes.map(\.item.createdAt)).count, writes.count)
    }

    func testAPlanWithNothingEligibleProducesNoWrites() {
        var draft = green(id: "PR_draft")
        draft.isDraft = true
        let plan = BulkTriagePlan.make(action: .approveAndMerge, pullRequests: [draft])
        XCTAssertFalse(plan.isActionable)
        XCTAssertTrue(plan.writes(mergeMethod: "squash").isEmpty)
    }

    // MARK: - Preselection

    func testTheGreenAgentPreselectTakesAgentsOnlyAndSkipsAnythingUnproven() {
        let agent = green(id: "PR_agent")
        let human = green(id: "PR_human", number: 9, author: Fixtures.makeActor("octocat"))
        let bot = green(
            id: "PR_bot",
            number: 10,
            author: Fixtures.makeActor("some-bot[bot]", kind: .bot)
        )
        var noChecks = green(id: "PR_nochecks", number: 11)
        noChecks.checkRollup = nil
        var pending = green(id: "PR_pending", number: 12)
        pending.checkRollup = CheckRollup(state: .pending, total: 1, pendingCount: 1)

        let selection = BulkTriagePlan.greenAgentPullRequests(
            in: [agent, human, bot, noChecks, pending]
        )

        // Agents only — a generic bot account is not what bulk triage is for — and only where
        // "green" is actually proven.
        XCTAssertEqual(selection.map(\.id), ["PR_agent"])
        XCTAssertTrue(BulkTriagePlan.isGreen(human))
        XCTAssertFalse(BulkTriagePlan.isGreen(noChecks))
        XCTAssertFalse(BulkTriagePlan.isGreen(pending))
    }

    func testGreennessRefusesDraftsConflictsAndChangeRequests() {
        var draft = green()
        draft.isDraft = true
        var conflicting = green()
        conflicting.mergeable = .conflicting
        XCTAssertFalse(BulkTriagePlan.isGreen(draft))
        XCTAssertFalse(BulkTriagePlan.isGreen(conflicting))
        XCTAssertFalse(BulkTriagePlan.isGreen(green(reviewDecision: .changesRequested)))
        XCTAssertTrue(BulkTriagePlan.isGreen(green(reviewDecision: .approved)))
    }
}
