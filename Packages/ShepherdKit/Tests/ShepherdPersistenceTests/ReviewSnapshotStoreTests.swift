import Foundation
import GRDB
import ShepherdCore
import XCTest

@testable import ShepherdPersistence

/// The interdiff's baseline: the v5 table, its round trip and its pruning (ADR 0028).
final class ReviewSnapshotStoreTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager.inMemory()
    }

    private func snapshot(
        prID: String = "PR_1",
        head: String = "abc123",
        at offset: TimeInterval = 0
    ) -> ReviewSnapshot {
        ReviewSnapshot(
            prID: prID,
            reviewedHeadOid: head,
            reviewedAt: PersistenceFixtures.date(offset),
            files: PersistenceFixtures.detail().files
        )
    }

    func testSnapshotRoundTripKeepsEveryFieldIncludingPatches() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestDetail(PersistenceFixtures.detail())
        let written = snapshot()
        let didWrite = try await database.saveReviewSnapshot(written)
        XCTAssertTrue(didWrite)

        let loaded = try await database.latestReviewSnapshot(prID: "PR_1")
        XCTAssertEqual(loaded, written)
        XCTAssertEqual(loaded?.files.count, 2)
        XCTAssertEqual(loaded?.files.first?.patch, "@@ -1,3 +1,4 @@\n+protocol TokenStore {}")
        XCTAssertEqual(loaded?.files.last?.previousPath, "Sources/Auth/Keychain.swift")
    }

    func testCapturingReadsTheStoredChangedFiles() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestDetail(PersistenceFixtures.detail())

        let didWrite = try await database.captureReviewSnapshot(
            prID: "PR_1",
            reviewedHeadOid: "abc123",
            reviewedAt: PersistenceFixtures.date(0)
        )
        XCTAssertTrue(didWrite)

        let loaded = try await database.latestReviewSnapshot(prID: "PR_1")
        XCTAssertEqual(loaded?.reviewedHeadOid, "abc123")
        XCTAssertEqual(loaded?.files.map(\.path), PersistenceFixtures.detail().files.map(\.path))
        let rounds = try await database.reviewSnapshotCount(prID: "PR_1")
        XCTAssertEqual(rounds, 1)
    }

    func testCapturingWithoutAPullRequestOrFilesWritesNothing() async throws {
        let database = try makeDatabase()
        // No row at all.
        let withoutRow = try await database.captureReviewSnapshot(
            prID: "PR_ghost",
            reviewedHeadOid: "abc123",
            reviewedAt: PersistenceFixtures.date(0)
        )
        XCTAssertFalse(withoutRow)
        // A row, but no diff has been fetched yet: nothing to compare against later, so no
        // baseline is claimed.
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        let withoutFiles = try await database.captureReviewSnapshot(
            prID: "PR_1",
            reviewedHeadOid: "abc123",
            reviewedAt: PersistenceFixtures.date(0)
        )
        XCTAssertFalse(withoutFiles)
        // And an empty head is never a baseline.
        try await database.savePullRequestDetail(PersistenceFixtures.detail())
        let withoutHead = try await database.captureReviewSnapshot(
            prID: "PR_1",
            reviewedHeadOid: "",
            reviewedAt: PersistenceFixtures.date(0)
        )
        XCTAssertFalse(withoutHead)
    }

    func testOneRowPerReviewedHead() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestDetail(PersistenceFixtures.detail())

        try await database.saveReviewSnapshot(snapshot(head: "abc123", at: 0))
        // The same head twice is the same round: an upsert, not a second row.
        try await database.saveReviewSnapshot(snapshot(head: "abc123", at: 10))
        let afterUpsert = try await database.reviewSnapshotCount(prID: "PR_1")
        XCTAssertEqual(afterUpsert, 1)

        try await database.saveReviewSnapshot(snapshot(head: "def456", at: 20))
        let afterSecondRound = try await database.reviewSnapshotCount(prID: "PR_1")
        XCTAssertEqual(afterSecondRound, 2)
        let latest = try await database.latestReviewSnapshot(prID: "PR_1")
        XCTAssertEqual(latest?.reviewedHeadOid, "def456")
        let hasFirst = try await database.hasReviewSnapshot(
            prID: "PR_1",
            reviewedHeadOid: "abc123"
        )
        XCTAssertTrue(hasFirst)
        let hasUnknown = try await database.hasReviewSnapshot(
            prID: "PR_1",
            reviewedHeadOid: "999999"
        )
        XCTAssertFalse(hasUnknown)
    }

    func testCountsForSeveralPullRequestsComeBackInOneQuery() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestDetail(PersistenceFixtures.detail())
        let other = PersistenceFixtures.summary(id: "PR_2", number: 129)
        try await database.savePullRequestDetail(PersistenceFixtures.detail(summary: other))

        try await database.saveReviewSnapshot(snapshot(prID: "PR_1", head: "abc123", at: 0))
        try await database.saveReviewSnapshot(snapshot(prID: "PR_1", head: "def456", at: 10))
        try await database.saveReviewSnapshot(snapshot(prID: "PR_2", head: "abc123", at: 20))

        let counts = try await database.reviewSnapshotCounts(prIDs: ["PR_1", "PR_2", "PR_3"])
        XCTAssertEqual(counts, ["PR_1": 2, "PR_2": 1])
        let empty = try await database.reviewSnapshotCounts(prIDs: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testSnapshotsOfAnUnknownPullRequestAreRefused() async throws {
        let database = try makeDatabase()
        let didWrite = try await database.saveReviewSnapshot(snapshot(prID: "PR_ghost"))
        XCTAssertFalse(didWrite)
        let loaded = try await database.latestReviewSnapshot(prID: "PR_ghost")
        XCTAssertNil(loaded)
    }

    func testSnapshotsCascadeAwayWithTheirPullRequest() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestDetail(PersistenceFixtures.detail())
        try await database.saveReviewSnapshot(snapshot())

        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM pull_requests WHERE id = ?", arguments: ["PR_1"])
        }
        let rounds = try await database.reviewSnapshotCount(prID: "PR_1")
        XCTAssertEqual(rounds, 0)
    }

    func testDeletingSnapshotsLeavesThePullRequestAlone() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestDetail(PersistenceFixtures.detail())
        try await database.saveReviewSnapshot(snapshot())

        try await database.deleteReviewSnapshots(prID: "PR_1")
        let rounds = try await database.reviewSnapshotCount(prID: "PR_1")
        XCTAssertEqual(rounds, 0)
        let row = try await database.fetchPullRequestSummary(id: "PR_1")
        XCTAssertNotNil(row)
    }

    func testAnUnreadableBlobDegradesToASnapshotWithNoFiles() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestDetail(PersistenceFixtures.detail())
        try await database.saveReviewSnapshot(snapshot())
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE review_snapshots SET filesJSON = ? WHERE prID = ?",
                arguments: [Data("not json".utf8), "PR_1"]
            )
        }
        // The row still reads — the interdiff over an empty baseline simply produces nothing,
        // which is the plan's "unavailable" case rather than a failed fetch.
        let loaded = try await database.latestReviewSnapshot(prID: "PR_1")
        XCTAssertEqual(loaded?.reviewedHeadOid, "abc123")
        XCTAssertTrue(loaded?.files.isEmpty ?? false)
    }
}
