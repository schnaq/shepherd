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
        XCTAssertEqual(count, DatabaseManager.migrator.migrations.count)
    }

    func testTheSchemaIsAppendOnly() async throws {
        // v1 is frozen; every change is a new migration. Locking the *order* here means an
        // edit to `createV1` — which would silently skip on existing installs — fails CI.
        XCTAssertEqual(DatabaseManager.migrator.migrations, ["v1", "v2"])
    }

    func testV2AddsTheETagIndexAndTheOriginalLineColumn() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.writer.read { db in
            let indexes = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'etags'"
            )
            XCTAssertTrue(indexes.contains("idx_etags_storedAt"))
            let columns = try db.columns(in: "review_threads").map(\.name)
            XCTAssertTrue(columns.contains("originalLine"))
        }
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

    func testPruningKeepsAPullRequestTheUserHasADraftFor() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1),
            PersistenceFixtures.summary(id: "PR_2", number: 2),
        ])
        try await database.savePullRequestDetail(
            PersistenceFixtures.detail(
                summary: PersistenceFixtures.summary(id: "PR_1", number: 1)
            )
        )
        try await database.saveDraft(PersistenceFixtures.draft(prID: "PR_1"))

        // PR_1 fell out of the search — merged, or past the five-page cap.
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_2", number: 2)
        ])

        let inbox = try await database.fetchInbox()
        XCTAssertEqual(Set(inbox.map(\.id)), ["PR_1", "PR_2"], "a drafted PR is not pruned")
        let detail = try await database.fetchPullRequestDetail(id: "PR_1")
        XCTAssertNotNil(detail, "its files must survive too, or the draft has nothing to anchor to")
        let survivingDraft = try await database.fetchDraft(prID: "PR_1")
        XCTAssertNotNil(survivingDraft)
    }

    func testPruningKeepsAPullRequestWithANonTerminalOutboxRow() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1),
            PersistenceFixtures.summary(id: "PR_2", number: 2),
            PersistenceFixtures.summary(id: "PR_3", number: 3),
        ])
        let queued = OutboxItem(
            prID: "PR_1",
            repo: PersistenceFixtures.repo,
            number: 1,
            action: .resolveThread(threadID: "PRRT_1")
        )
        try await database.enqueue(queued)
        let settled = OutboxItem(
            prID: "PR_3",
            repo: PersistenceFixtures.repo,
            number: 3,
            action: .resolveThread(threadID: "PRRT_3")
        )
        try await database.enqueue(settled)
        try await database.markOutboxItemFailed(
            id: settled.id,
            error: "422",
            now: Date(),
            retriable: false
        )

        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_2", number: 2)
        ])

        let inbox = try await database.fetchInbox()
        XCTAssertEqual(
            Set(inbox.map(\.id)),
            ["PR_1", "PR_2"],
            "a queued mutation holds its PR open; a failed one does not"
        )
    }

    func testAnEmptySweepStillKeepsDraftedPullRequests() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary(id: "PR_1")])
        try await database.saveDraft(PersistenceFixtures.draft(prID: "PR_1"))

        try await database.savePullRequestSummaries([])

        let remainingIDs = try await database.fetchInbox().map(\.id)
        XCTAssertEqual(remainingIDs, ["PR_1"])
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
        detail.checks = [detail.checks[0]]
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(loaded?.files.count, 1)
        XCTAssertEqual(loaded?.threads.count, 1)
        XCTAssertEqual(loaded?.checks.count, 1)
    }

    func testADetailWithoutChecksKeepsTheRollupTheSweepComputed() async throws {
        let database = try makeDatabase()
        // The sweep's GraphQL `statusCheckRollup` includes classic commit statuses…
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(
                checkRollup: CheckRollup(
                    state: .failure,
                    total: 2,
                    successCount: 1,
                    failureCount: 1,
                    pendingCount: 0
                )
            )
        ])

        // …but `/commits/{sha}/check-runs` does not, so a repo on Jenkins reports none.
        var detail = PersistenceFixtures.detail()
        detail.summary.checkRollup = nil
        detail.checks = []
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestSummary(id: detail.id)
        XCTAssertEqual(loaded?.checkRollup?.state, .failure, "the badge must not blink out")
        XCTAssertEqual(loaded?.checkRollup?.total, 2)
        XCTAssertEqual(loaded?.checkRollup?.failureCount, 1)

        let stored = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(stored?.checks.count, 2, "the previously fetched runs are kept too")
    }

    func testADetailWithChecksReplacesTheRollup() async throws {
        let database = try makeDatabase()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])

        var detail = PersistenceFixtures.detail()
        detail.summary.checkRollup = CheckRollup(state: .success, total: 2, successCount: 2)
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestSummary(id: detail.id)
        XCTAssertEqual(loaded?.checkRollup?.state, .success)
        XCTAssertEqual(loaded?.checkRollup?.successCount, 2)
    }

    func testOutdatedThreadsKeepTheirOriginalLineAcrossAReload() async throws {
        let database = try makeDatabase()
        var detail = PersistenceFixtures.detail()
        detail.threads = [
            ReviewThread(
                id: "PRRT_9",
                path: "Sources/Auth/TokenStore.swift",
                line: nil,
                originalLine: 42,
                side: .right,
                isResolved: false,
                isOutdated: true
            )
        ]
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertNil(loaded?.threads.first?.line, "a lost anchor stays lost")
        XCTAssertEqual(loaded?.threads.first?.originalLine, 42)
        XCTAssertEqual(loaded?.threads.first?.isAnchoredInCurrentDiff, false)
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
