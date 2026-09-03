import Foundation
import GRDB
import ShepherdCore
import XCTest

@testable import ShepherdPersistence

/// The track-record table (ADR 0027): round trips, upserts, and the reads the badge makes.
final class PullRequestOutcomeStoreTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager.inMemory()
    }

    private var window: Date { PersistenceFixtures.date(-100_000) }

    // MARK: - Round trip

    func testAnOutcomeRoundTripsThroughEveryColumn() async throws {
        let database = try makeDatabase()
        let closed = OutcomeFixtures.closed(
            prID: "PR_1",
            number: 128,
            agentName: "Claude Code",
            login: "claude[bot]",
            title: #"Revert "feat: parser""#,
            merged: true,
            mergeCommitOid: "abc1234",
            revertedBy: "PR_9",
            firstPushGreen: false,
            reviewRounds: 3,
            changedLines: 240,
            closedAt: -60,
            source: .sync
        )
        try await database.savePullRequestOutcomes([closed])

        let stored = try await database.pullRequestOutcomes(since: window)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first, closed.outcome)
    }

    func testAnUnknownSourceDegradesToSyncRatherThanFailingTheFetch() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: true)
        ])
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE pull_request_outcomes SET source = 'from-the-future'"
            )
        }
        let stored = try await database.pullRequestOutcomes(since: window)
        XCTAssertEqual(stored.first?.source, .sync)
    }

    func testAnUnknownFirstPushStaysUnknownRatherThanBecomingRed() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: true, firstPushGreen: nil)
        ])
        let awaited1 = try await database.pullRequestOutcomes(since: window).first?.firstPushCIGreen
        XCTAssertNil(awaited1)
    }

    // MARK: - Upserting

    func testWritingTheSamePullRequestTwiceKeepsOneRow() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: false, reviewRounds: 0)
        ])
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: true, reviewRounds: 2)
        ])

        let stored = try await database.pullRequestOutcomes(since: window)
        XCTAssertEqual(stored.count, 1, "running the backfill twice upserts")
        XCTAssertTrue(stored.first?.merged ?? false)
        XCTAssertEqual(stored.first?.reviewRounds, 2)
    }

    func testASecondWriteDoesNotUnRevertARowThatWasLinked() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: true)
        ])
        _ = try await database.applyRevertLinks(["PR_1": "PR_2"])

        // A second backfill re-imports it, carrying no link of its own.
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: true)
        ])

        let stored = try await database.pullRequestOutcomes(since: window)
        XCTAssertEqual(
            stored.first?.revertedByPRID,
            "PR_2",
            "the link is discovered separately and must survive a re-import"
        )
    }

    // MARK: - Revert links

    func testARevertLinkIsWrittenOnlyForAMergedRow() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: true),
            OutcomeFixtures.closed(prID: "PR_2", number: 2, merged: false),
        ])
        let updated = try await database.applyRevertLinks([
            "PR_1": "PR_9",
            "PR_2": "PR_9",
            "PR_missing": "PR_9",
        ])
        XCTAssertEqual(updated, 1)

        let stored = try await database.pullRequestOutcomes(since: window)
        XCTAssertEqual(stored.first { $0.prID == "PR_1" }?.revertedByPRID, "PR_9")
        XCTAssertNil(stored.first { $0.prID == "PR_2" }?.revertedByPRID)
    }

    func testAnEmptyLinkSetIsANoOp() async throws {
        let database = try makeDatabase()
        let awaited2 = try await database.applyRevertLinks([:])
        XCTAssertEqual(awaited2, 0)
    }

    // MARK: - Reading

    func testTheWindowIsInclusiveAndOlderRowsAreLeftOut() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_new", number: 1, merged: true, closedAt: 0),
            OutcomeFixtures.closed(prID: "PR_edge", number: 2, merged: true, closedAt: -1_000),
            OutcomeFixtures.closed(prID: "PR_old", number: 3, merged: true, closedAt: -5_000),
        ])
        let stored = try await database.pullRequestOutcomes(
            since: PersistenceFixtures.date(-1_000)
        )
        XCTAssertEqual(stored.map(\.prID), ["PR_new", "PR_edge"], "newest first, cutoff included")
    }

    func testTheScopedReadFiltersByRepositoryAndAgent() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: true),
            OutcomeFixtures.closed(
                prID: "PR_2",
                number: 2,
                repo: PersistenceFixtures.otherRepo,
                merged: true
            ),
            OutcomeFixtures.closed(prID: "PR_3", number: 3, agentName: nil, merged: true),
        ])

        let agentRows = try await database.pullRequestOutcomes(
            repo: PersistenceFixtures.repo,
            agentName: "Claude Code",
            since: window
        )
        XCTAssertEqual(agentRows.map(\.prID), ["PR_1"])

        let humanRows = try await database.pullRequestOutcomes(
            repo: PersistenceFixtures.repo,
            agentName: nil,
            since: window
        )
        XCTAssertEqual(humanRows.map(\.prID), ["PR_3"], "`nil` means the rows with no agent")
    }

    func testTheRepositoryAndAgentComparisonsIgnoreCase() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(
                prID: "PR_1",
                number: 1,
                repo: RepoRef(owner: "Schnaq", name: "Review"),
                agentName: "claude code",
                merged: true
            )
        ])
        let rows = try await database.pullRequestOutcomes(
            repo: PersistenceFixtures.repo,
            agentName: "Claude Code",
            since: window
        )
        XCTAssertEqual(rows.map(\.prID), ["PR_1"])
    }

    func testTheRevertMatchingReadCarriesOnlyMergedRowsAndTheirText() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(
                prID: "PR_1",
                number: 10,
                title: "feat: parser",
                merged: true,
                mergeCommitOid: "abc1234",
                closedAt: -100
            ),
            OutcomeFixtures.closed(prID: "PR_2", number: 11, merged: false, closedAt: 0),
        ])
        let candidates = try await database.mergedClosedPullRequests(
            repo: PersistenceFixtures.repo,
            since: window
        )
        XCTAssertEqual(candidates.map(\.id), ["PR_1"])
        XCTAssertEqual(candidates.first?.title, "feat: parser")
        XCTAssertEqual(candidates.first?.number, 10)
        XCTAssertEqual(candidates.first?.mergeCommitOid, "abc1234")
        XCTAssertEqual(
            candidates.first?.bodyMarkdown,
            "",
            "bodies are not stored: only the reverting pull request needs one, and it is in hand"
        )
    }

    func testTheCountAndTheExistenceProbe() async throws {
        let database = try makeDatabase()
        let awaited3 = try await database.pullRequestOutcomeCount()
        XCTAssertEqual(awaited3, 0)
        let awaited4 = try await database.hasPullRequestOutcome(prID: "PR_1")
        XCTAssertFalse(awaited4)

        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: true)
        ])
        let awaited5 = try await database.pullRequestOutcomeCount()
        XCTAssertEqual(awaited5, 1)
        let awaited6 = try await database.hasPullRequestOutcome(prID: "PR_1")
        XCTAssertTrue(awaited6)
    }

    // MARK: - Deleting

    func testDeletingOneRepositoryLeavesTheOthers() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: true),
            OutcomeFixtures.closed(
                prID: "PR_2",
                number: 2,
                repo: PersistenceFixtures.otherRepo,
                merged: true
            ),
        ])
        try await database.deletePullRequestOutcomes(repo: PersistenceFixtures.repo)
        let remaining = try await database.pullRequestOutcomes(since: window).map(\.prID)
        XCTAssertEqual(remaining, ["PR_2"])
    }

    func testClearHistoryEmptiesTheTable() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: "PR_1", number: 1, merged: true),
            OutcomeFixtures.closed(prID: "PR_2", number: 2, merged: true),
        ])
        try await database.deleteAllPullRequestOutcomes()
        let awaited7 = try await database.pullRequestOutcomeCount()
        XCTAssertEqual(awaited7, 0)
    }

    // MARK: - The lane's diff input

    func testChangedFilePathsCarryPathsAndStatusesButNoPatches() async throws {
        let database = try makeDatabase()
        let detail = PersistenceFixtures.detail()
        try await database.savePullRequestSummaries([detail.summary])
        try await database.savePullRequestDetail(detail)

        let files = try await database.changedFilePaths(prIDs: [detail.id, "PR_unknown"])
        XCTAssertEqual(files.count, 1, "a pull request with no cached diff is absent, not empty")
        XCTAssertEqual(
            files[detail.id]?.map(\.path),
            ["Sources/Auth/TokenStore.swift", "Sources/Auth/KeychainTokenStore.swift"]
        )
        XCTAssertEqual(files[detail.id]?.first?.status, .modified)
        XCTAssertEqual(files[detail.id]?.last?.previousPath, "Sources/Auth/Keychain.swift")
        XCTAssertTrue(
            files[detail.id]?.allSatisfy { !$0.hasPatch } ?? false,
            "the lane reads paths, so the patches stay in SQLite"
        )
        let awaited8 = try await database.changedFilePaths(prIDs: []).isEmpty
        XCTAssertTrue(awaited8)
    }
}
