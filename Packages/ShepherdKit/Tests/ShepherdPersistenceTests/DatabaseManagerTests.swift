import Foundation
import GRDB
import ShepherdCore
import XCTest
@testable import ShepherdPersistence

final class MigrationTests: XCTestCase {
    func testMigratorCreatesTheV1Schema() async throws {
        let database = try DatabaseManager.inMemory()
        let tables = try await database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
        for expected in DatabaseSchema.allTables {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
    }

    func testMigrationIsIdempotent() async throws {
        let queue = try DatabaseQueue()
        _ = try DatabaseManager(writer: queue)
        // Re-running the migrator over the same connection must be a no-op, not an error.
        _ = try DatabaseManager(writer: queue)
        let count = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testDatabaseCanBeOpenedFromAURL() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shepherd-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("nested").appendingPathComponent("db.sqlite")
        let database = try DatabaseManager(url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let tables = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        XCTAssertTrue(tables.contains("pull_requests"))
    }

    func testEraseRemovesEveryRow() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        var inbox = try await database.fetchInbox()
        XCTAssertEqual(inbox.count, 1)

        try await database.eraseAllData()
        inbox = try await database.fetchInbox()
        XCTAssertTrue(inbox.isEmpty)
    }
}

final class InboxStoreTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager.inMemory()
    }

    func testSummaryRoundTripKeepsEveryField() async throws {
        let database = try makeDatabase()
        let summary = PersistenceFixtures.summary()
        try await database.savePullRequestSummaries([summary])

        let loaded = try await database.fetchPullRequestSummary(id: summary.id)
        XCTAssertEqual(loaded, summary)
        XCTAssertEqual(loaded?.author.kind.agentIdentity?.id, "claude-code")
        XCTAssertEqual(loaded?.author.kind.agentIdentity?.matchedBy, .login)
        XCTAssertEqual(loaded?.checkRollup?.failureCount, 1)
        XCTAssertEqual(loaded?.labels, ["agent", "refactor"])
        XCTAssertEqual(loaded?.myRelation, [.reviewRequested])
    }

    func testSavingIsAnUpsert() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])

        var updated = PersistenceFixtures.summary(updatedAt: 600, headRefOid: "def456")
        updated.title = "Refactor the token store (v2)"
        try await database.savePullRequestSummaries([updated])

        let inbox = try await database.fetchInbox()
        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox.first?.title, "Refactor the token store (v2)")
        XCTAssertEqual(inbox.first?.headRefOid, "def456")
    }

    func testPruningRemovesPullRequestsThatAreNoLongerOpen() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1),
            PersistenceFixtures.summary(id: "PR_2", number: 2),
        ])
        let afterFirstSweep = try await database.fetchInbox()
        XCTAssertEqual(afterFirstSweep.count, 2)

        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_2", number: 2)
        ])
        let inbox = try await database.fetchInbox()
        XCTAssertEqual(inbox.map(\.id), ["PR_2"])
    }

    func testPruningCanBeDisabled() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1)
        ])
        try await database.savePullRequestSummaries(
            [PersistenceFixtures.summary(id: "PR_2", number: 2)],
            pruneMissing: false
        )
        let inbox = try await database.fetchInbox()
        XCTAssertEqual(inbox.count, 2)
    }

    func testAnEmptySweepEmptiesTheInbox() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        try await database.savePullRequestSummaries([])
        let inbox = try await database.fetchInbox()
        XCTAssertTrue(inbox.isEmpty)
    }

    func testInboxIsOrderedMostRecentlyUpdatedFirst() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_old", number: 1, updatedAt: -1_000),
            PersistenceFixtures.summary(id: "PR_new", number: 2, updatedAt: 1_000),
            PersistenceFixtures.summary(id: "PR_mid", number: 3, updatedAt: 0),
        ])
        let inbox = try await database.fetchInbox()
        XCTAssertEqual(inbox.map(\.id), ["PR_new", "PR_mid", "PR_old"])
    }

    func testInboxFilters() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_agent", number: 1),
            PersistenceFixtures.summary(
                id: "PR_human",
                number: 2,
                repo: PersistenceFixtures.otherRepo,
                author: PersistenceFixtures.humanActor(),
                relations: [.author]
            ),
        ])

        let byRepo = try await database.fetchInbox(
            filter: InboxFilter(repo: PersistenceFixtures.otherRepo)
        )
        XCTAssertEqual(byRepo.map(\.id), ["PR_human"])

        let byRelation = try await database.fetchInbox(
            filter: InboxFilter(anyOfRelations: [.reviewRequested])
        )
        XCTAssertEqual(byRelation.map(\.id), ["PR_agent"])

        let byAgent = try await database.fetchInbox(filter: InboxFilter(agentID: "claude-code"))
        XCTAssertEqual(byAgent.map(\.id), ["PR_agent"])

        let humansOnly = try await database.fetchInbox(
            filter: InboxFilter(isMachineAuthored: false)
        )
        XCTAssertEqual(humansOnly.map(\.id), ["PR_human"])

        let limited = try await database.fetchInbox(filter: InboxFilter(limit: 1))
        XCTAssertEqual(limited.count, 1)
    }

    func testDetailRoundTripsCompletely() async throws {
        let database = try makeDatabase()
        let detail = PersistenceFixtures.detail()
        try await database.savePullRequestDetail(detail)

        guard let loaded = try await database.fetchPullRequestDetail(id: detail.id) else {
            return XCTFail("detail was not stored")
        }
        XCTAssertEqual(loaded.summary, detail.summary)
        XCTAssertEqual(loaded.bodyMarkdown, detail.bodyMarkdown)
        XCTAssertEqual(loaded.files, detail.files)
        XCTAssertEqual(loaded.threads, detail.threads)
        XCTAssertEqual(loaded.commits, detail.commits)
        XCTAssertEqual(loaded.timeline, detail.timeline)
        XCTAssertEqual(loaded.checks, detail.checks)
        XCTAssertEqual(loaded, detail)
    }

    func testDetailReplacesChildRowsRatherThanAccumulatingThem() async throws {
        let database = try makeDatabase()
        var detail = PersistenceFixtures.detail()
        try await database.savePullRequestDetail(detail)

        detail.files = [detail.files[0]]
        detail.threads = [detail.threads[0]]
        detail.checks = []
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(loaded?.files.count, 1)
        XCTAssertEqual(loaded?.threads.count, 1)
        XCTAssertEqual(loaded?.checks.count, 0)
    }

    func testDetailSavePreservesRelationsFromTheSweep() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(relations: [.reviewRequested, .author])
        ])

        // A REST detail fetch cannot know the viewer's relation to the pull request.
        var detail = PersistenceFixtures.detail()
        detail.summary.myRelation = []
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestSummary(id: detail.id)
        XCTAssertEqual(loaded?.myRelation, [.reviewRequested, .author])
    }

    func testFetchingAnUnknownDetailReturnsNil() async throws {
        let database = try makeDatabase()
        let loaded = try await database.fetchPullRequestDetail(id: "nope")
        XCTAssertNil(loaded)
    }

    func testViewedFilesAreScopedToTheHeadCommit() async throws {
        let database = try makeDatabase()
        let detail = PersistenceFixtures.detail()
        try await database.savePullRequestDetail(detail)

        try await database.setFileViewed(
            prID: detail.id,
            path: "Sources/Auth/TokenStore.swift",
            headRefOid: detail.summary.headRefOid,
            isViewed: true
        )

        let viewed = try await database.viewedFiles(
            prID: detail.id,
            headRefOid: detail.summary.headRefOid
        )
        XCTAssertEqual(viewed, ["Sources/Auth/TokenStore.swift"])

        let loaded = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(loaded?.files.first?.isViewed, true)
        XCTAssertEqual(loaded?.files.last?.isViewed, false)

        // A new head commit resets the viewed state.
        let afterNewCommit = try await database.viewedFiles(
            prID: detail.id,
            headRefOid: "newhead"
        )
        XCTAssertTrue(afterNewCommit.isEmpty)
    }

    func testUnmarkingAFileRemovesIt() async throws {
        let database = try makeDatabase()
        let detail = PersistenceFixtures.detail()
        try await database.savePullRequestDetail(detail)
        try await database.setFileViewed(
            prID: detail.id,
            path: "Sources/Auth/TokenStore.swift",
            headRefOid: "abc123",
            isViewed: true
        )
        try await database.setFileViewed(
            prID: detail.id,
            path: "Sources/Auth/TokenStore.swift",
            headRefOid: "abc123",
            isViewed: false
        )
        let viewed = try await database.viewedFiles(prID: detail.id, headRefOid: "abc123")
        XCTAssertTrue(viewed.isEmpty)
    }

    func testSyncStateRoundTrip() async throws {
        let database = try makeDatabase()
        let missing = try await database.syncState(forKey: "notifications.lastModified")
        XCTAssertNil(missing)

        try await database.setSyncState("Mon, 31 Aug 2026", forKey: "notifications.lastModified")
        let first = try await database.syncState(forKey: "notifications.lastModified")
        XCTAssertEqual(first, "Mon, 31 Aug 2026")

        try await database.setSyncState("Tue, 01 Sep 2026", forKey: "notifications.lastModified")
        let second = try await database.syncState(forKey: "notifications.lastModified")
        XCTAssertEqual(second, "Tue, 01 Sep 2026")
    }

    func testAgentRegistryOverridesRoundTrip() async throws {
        let database = try makeDatabase()
        let entry = AgentRegistryEntry(
            id: "acme-bot",
            displayName: "Acme Bot",
            loginPatterns: ["acme-*"],
            branchPrefixes: ["acme/"],
            commitTrailers: ["Co-Authored-By: Acme"]
        )
        try await database.saveAgentRegistryOverride(entry)

        let loaded = try await database.agentRegistryOverrides()
        XCTAssertEqual(loaded, [entry])

        try await database.deleteAgentRegistryOverride(id: "acme-bot")
        let afterDeletion = try await database.agentRegistryOverrides()
        XCTAssertTrue(afterDeletion.isEmpty)
    }
}
