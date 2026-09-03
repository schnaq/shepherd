import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import ShepherdSync

/// The interdiff's baseline: written by the drain when a review is sent, and retroactively by a
/// detail fetch that recognises a review of the current head (ADR 0028).
final class ReviewBaselineTests: XCTestCase {
    private let repo = SyncFixtures.repo
    private let clock = Date(timeIntervalSince1970: 1_788_162_000)

    private func makeEngine(
        github: MockGitHub,
        store: DatabaseManager,
        snapshots: (any ReviewSnapshotWriting)?,
        viewerLogin: String? = nil
    ) -> SyncEngine {
        SyncEngine(
            github: github,
            store: store,
            snapshots: snapshots,
            configuration: SyncConfiguration(viewerLogin: viewerLogin),
            sleeper: RecordingSleeper(),
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )
    }

    private func draft(headOid: String) -> ReviewDraft {
        ReviewDraft(
            prID: "PR_1",
            verdict: .requestChanges,
            summaryBody: "Two things.",
            comments: [
                DraftComment(path: "Sources/A.swift", line: 3, side: .right, body: "Nit.")
            ],
            basedOnHeadOid: headOid,
            updatedAt: clock
        )
    }

    private func enqueueSubmit(_ draft: ReviewDraft, in store: DatabaseManager) async throws {
        try await store.enqueue(
            OutboxItem(
                id: UUID(),
                prID: "PR_1",
                repo: repo,
                number: 1,
                action: .submitReview(draft),
                createdAt: clock,
                attemptCount: 0,
                nextAttemptAt: Date(timeIntervalSince1970: 0),
                lastError: nil,
                state: .pending
            )
        )
    }

    // MARK: - The drain hook

    func testASentReviewWritesTheHeadItWasWrittenAgainst() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let snapshots = FakeReviewSnapshotWriter()
        try await enqueueSubmit(draft(headOid: "head-1"), in: store)
        let engine = makeEngine(github: github, store: store, snapshots: snapshots)

        await engine.drainOutbox()
        await engine.shutdown()

        let captures = await snapshots.captures
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.prID, "PR_1")
        XCTAssertEqual(captures.first?.head, "head-1")
        XCTAssertEqual(captures.first?.reviewedAt, clock)
    }

    func testADraftWithoutAHeadFallsBackToTheHeadAtDrainTime() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-9", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let snapshots = FakeReviewSnapshotWriter()
        try await enqueueSubmit(draft(headOid: ""), in: store)
        let engine = makeEngine(github: github, store: store, snapshots: snapshots)

        await engine.drainOutbox()
        await engine.shutdown()

        let heads = await snapshots.captures.map { $0.head }
        XCTAssertEqual(heads, ["head-9"])
    }

    func testAParkedReviewWritesNoBaseline() async throws {
        let github = MockGitHub()
        // The pull request moved on, so the drain parks the row instead of submitting it.
        await github.setHeadOid("head-2", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let snapshots = FakeReviewSnapshotWriter()
        try await enqueueSubmit(draft(headOid: "head-1"), in: store)
        let engine = makeEngine(github: github, store: store, snapshots: snapshots)

        await engine.drainOutbox()
        await engine.shutdown()

        let captures = await snapshots.captures
        XCTAssertTrue(captures.isEmpty)
        let submitted = await github.submittedDrafts
        XCTAssertTrue(submitted.isEmpty)
    }

    func testAFailedBaselineDoesNotFailTheSentReview() async throws {
        let github = MockGitHub()
        await github.setHeadOid("head-1", repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let snapshots = FakeReviewSnapshotWriter(result: false)
        try await enqueueSubmit(draft(headOid: "head-1"), in: store)
        let engine = makeEngine(github: github, store: store, snapshots: snapshots)

        await engine.drainOutbox()
        await engine.shutdown()

        // The mutation reached GitHub and the row is gone; only the tab is lost.
        let submitted = await github.submittedDrafts
        XCTAssertEqual(submitted.count, 1)
        let pending = try await store.pendingOutboxCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - The retroactive baseline

    private func detail(
        headRefOid: String = "head-1",
        reviewer: String = "octocat",
        reviewCommit: String? = "head-1",
        files: [ChangedFile] = [
            ChangedFile(path: "a.swift", status: .modified, patch: "@@ -1,1 +1,1 @@\n+one")
        ]
    ) -> PullRequestDetail {
        PullRequestDetail(
            summary: SyncFixtures.summary(id: "PR_1", number: 1, headRefOid: headRefOid),
            files: files,
            timeline: [
                TimelineEvent(
                    id: "commit:1",
                    kind: .commit,
                    author: SyncFixtures.agent(),
                    createdAt: SyncFixtures.date(-3_600),
                    summary: "fix: the thing",
                    commitOid: headRefOid
                ),
                TimelineEvent(
                    id: "review:1",
                    kind: .reviewChangesRequested,
                    author: ShepherdCore.Actor(login: reviewer, kind: .human),
                    createdAt: SyncFixtures.date(-600),
                    summary: "Requested changes",
                    commitOid: reviewCommit
                ),
            ]
        )
    }

    func testAReviewOfTheCurrentHeadByTheViewerIsABaseline() throws {
        let baseline = SyncEngine.retroactiveBaseline(
            detail: detail(),
            viewerLogin: "OCTOCAT"
        )
        XCTAssertEqual(baseline?.headRefOid, "head-1")
        XCTAssertEqual(baseline?.reviewedAt, SyncFixtures.date(-600))
    }

    func testAReviewOfAnOlderHeadIsNotABaseline() {
        XCTAssertNil(
            SyncEngine.retroactiveBaseline(
                detail: detail(headRefOid: "head-2", reviewCommit: "head-1"),
                viewerLogin: "octocat"
            )
        )
        XCTAssertNil(
            SyncEngine.retroactiveBaseline(
                detail: detail(reviewCommit: nil),
                viewerLogin: "octocat"
            )
        )
    }

    func testSomebodyElsesReviewIsNotABaseline() {
        XCTAssertNil(
            SyncEngine.retroactiveBaseline(
                detail: detail(reviewer: "hubot"),
                viewerLogin: "octocat"
            )
        )
    }

    func testAPullRequestWithNoStoredDiffIsNotABaseline() {
        XCTAssertNil(
            SyncEngine.retroactiveBaseline(detail: detail(files: []), viewerLogin: "octocat")
        )
    }

    func testASweepWritesTheRetroactiveBaselineOnlyOnce() async throws {
        let github = MockGitHub()
        let summary = SyncFixtures.summary(id: "PR_1", number: 1)
        await github.setSearchResults([[summary]])
        await github.setDetail(detail(), repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let snapshots = FakeReviewSnapshotWriter()
        let engine = makeEngine(
            github: github,
            store: store,
            snapshots: snapshots,
            viewerLogin: "octocat"
        )

        try await engine.syncNow()
        // A second sweep re-fetches nothing, but even a detail fetch that happened again must
        // not write a second baseline for a head that already has one.
        try await engine.syncNow()
        await engine.shutdown()

        let captures = await snapshots.captures
        let heads = captures.map { $0.head }
        XCTAssertEqual(heads, ["head-1"])
        XCTAssertEqual(captures.first?.reviewedAt, SyncFixtures.date(-600))
    }

    func testASweepWithoutAViewerLoginWritesNothing() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)]])
        await github.setDetail(detail(), repo: repo, number: 1)
        let store = try DatabaseManager.inMemory()
        let snapshots = FakeReviewSnapshotWriter()
        let engine = makeEngine(github: github, store: store, snapshots: snapshots)

        try await engine.syncNow()
        await engine.shutdown()

        let captures = await snapshots.captures
        XCTAssertTrue(captures.isEmpty)
    }
}
