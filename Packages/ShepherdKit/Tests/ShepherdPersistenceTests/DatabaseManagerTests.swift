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
        XCTAssertEqual(
            DatabaseManager.migrator.migrations,
            ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9"]
        )
    }

    func testV6AddsThePullRequestOutcomesTableWithItsIndex() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.writer.read { db in
            let columns = try db.columns(in: "pull_request_outcomes").map(\.name)
            XCTAssertEqual(
                columns,
                [
                    "prID", "repoFullName", "repoOwner", "repoName", "number", "title",
                    "agentName", "authorLogin", "openedAt", "closedAt", "merged",
                    "mergeCommitOid", "revertedByPRID", "firstPushCIGreen", "reviewRounds",
                    "changedLines", "source",
                ]
            )
            // `prID` alone, so both writers upsert and the table cannot hold two opinions about
            // one pull request (ADR 0027).
            let primaryKey = try db.primaryKey("pull_request_outcomes")
            XCTAssertEqual(primaryKey.columns, ["prID"])
            let indexes = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index' AND tbl_name = 'pull_request_outcomes'
                    """
            )
            XCTAssertTrue(indexes.contains("idx_pull_request_outcomes_repo_agent_closedAt"))
        }
    }

    func testTheOutcomeTableHasNoForeignKeyOntoPullRequests() async throws {
        // The one derived table that deliberately has no cascade: a row is written exactly when
        // the pull request leaves the inbox, so a cascade would delete every row the track record
        // is made of (ADR 0027).
        let database = try DatabaseManager.inMemory()
        try await database.writer.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_foreign_key_list('pull_request_outcomes')"
            ) ?? -1
            XCTAssertEqual(count, 0)
        }
    }

    func testAnOutcomeSurvivesThePullRequestLeavingTheInbox() async throws {
        let database = try DatabaseManager.inMemory()
        let summary = PersistenceFixtures.summary()
        try await database.savePullRequestSummaries([summary])
        try await database.savePullRequestOutcomes([
            OutcomeFixtures.closed(prID: summary.id, number: summary.number, merged: true)
        ])

        // The sweep prunes the pull request, exactly as it does when a merge lands.
        try await database.savePullRequestSummaries([], pruneMissing: true)

        let awaited1 = try await database.fetchInbox().isEmpty
        XCTAssertTrue(awaited1)
        let outcomes = try await database.pullRequestOutcomes(
            since: PersistenceFixtures.date(-10_000)
        )
        XCTAssertEqual(outcomes.map(\.prID), [summary.id])
    }

    func testV5AddsTheReviewSnapshotsTable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.writer.read { db in
            let columns = try db.columns(in: "review_snapshots").map(\.name)
            XCTAssertEqual(columns, ["prID", "reviewedHeadOid", "reviewedAt", "filesJSON"])
            // The composite primary key is what makes one row per reviewed head, and therefore
            // what makes `COUNT(*)` the number of rounds (ADR 0028).
            let primaryKey = try db.primaryKey("review_snapshots")
            XCTAssertEqual(primaryKey.columns, ["prID", "reviewedHeadOid"])
        }
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

        // An earlier detail fetch stored some check runs alongside that rollup.
        var detail = PersistenceFixtures.detail()
        detail.summary.checkRollup = CheckRollup(
            state: .failure,
            total: 2,
            successCount: 1,
            failureCount: 1,
            pendingCount: 0
        )
        let previouslyFetchedRuns = detail.checks.count
        try await database.savePullRequestDetail(detail)

        // …but `/commits/{sha}/check-runs` does not include commit statuses, so a repo
        // on Jenkins reports none on the next detail fetch.
        detail.summary.checkRollup = nil
        detail.checks = []
        try await database.savePullRequestDetail(detail)

        let loaded = try await database.fetchPullRequestSummary(id: detail.id)
        XCTAssertEqual(loaded?.checkRollup?.state, .failure, "the badge must not blink out")
        XCTAssertEqual(loaded?.checkRollup?.total, 2)
        XCTAssertEqual(loaded?.checkRollup?.failureCount, 1)

        let stored = try await database.fetchPullRequestDetail(id: detail.id)
        XCTAssertEqual(
            stored?.checks.count,
            previouslyFetchedRuns,
            "the previously fetched runs are kept too"
        )
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

/// Migration v7 and the issues store (ADR 0032).
final class IssueMigrationTests: XCTestCase {
    func testV7AddsTheFourTablesWithTheirColumnsAndIndexes() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.writer.read { db in
            let issueColumns = try db.columns(in: "issues").map(\.name)
            XCTAssertEqual(
                issueColumns,
                [
                    "id", "repoFullName", "number", "title", "authorLogin",
                    "authorDisplayName", "authorAvatarURL", "authorKind", "agentID",
                    "agentDisplayName", "agentMatchedBy", "createdAt", "updatedAt", "closedAt",
                    "state", "stateReason", "relations", "labels", "commentCount",
                    "linkedPullRequestCount", "hasAgentLinkedPullRequest", "bodyMarkdown",
                    "detailFetchedAt",
                ]
            )
            let indexes = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index' AND tbl_name = 'issues'
                    """
            )
            XCTAssertTrue(indexes.contains("idx_issues_repo_number"))
            XCTAssertTrue(indexes.contains("idx_issues_updatedAt"))

            let indexColumns = try db.columns(in: "issue_search_index").map(\.name)
            XCTAssertEqual(
                indexColumns,
                ["issueID", "documentHash", "modelIdentifier", "dimensions", "vector", "indexedAt"]
            )
            let indexKey = try db.primaryKey("issue_search_index").columns
            XCTAssertEqual(indexKey, ["issueID"])

            let linkColumns = try db.columns(in: "issue_linked_pull_requests").map(\.name)
            XCTAssertEqual(
                linkColumns,
                [
                    "issueID", "prRepoFullName", "prNumber", "prTitle", "prState",
                    "authorLogin", "authorKind", "agentDisplayName", "sortIndex",
                ]
            )
            let linkKey = try db.primaryKey("issue_linked_pull_requests").columns
            XCTAssertEqual(linkKey, ["issueID", "prRepoFullName", "prNumber"])

            let closingColumns = try db.columns(in: "pull_request_closing_issues").map(\.name)
            XCTAssertEqual(
                closingColumns,
                [
                    "prID", "issueRepoFullName", "issueNumber", "issueTitle", "issueState",
                    "sortIndex",
                ]
            )
            let closingKey = try db.primaryKey("pull_request_closing_issues").columns
            XCTAssertEqual(closingKey, ["prID", "issueRepoFullName", "issueNumber"])
        }
    }

    func testTheLinkingTableToPullRequestsDeliberatelyHasNoForeignKey() async throws {
        // The linked pull request may not be in the local inbox at all, so the row is about what
        // the sweep saw rather than about a join that might not resolve (ADR 0032). The other
        // direction *does* cascade, because it is about a pull request that is in the inbox.
        let database = try DatabaseManager.inMemory()
        try await database.writer.read { db in
            let outbound = try String.fetchAll(
                db,
                sql: """
                    SELECT "table" FROM pragma_foreign_key_list('issue_linked_pull_requests')
                    """
            )
            XCTAssertEqual(outbound, ["issues"], "issues only — never pull_requests")

            let inbound = try String.fetchAll(
                db,
                sql: """
                    SELECT "table" FROM pragma_foreign_key_list('pull_request_closing_issues')
                    """
            )
            XCTAssertEqual(inbound, ["pull_requests"])
        }
    }

    func testEraseEmptiesAllFourNewTables() async throws {
        let database = try DatabaseManager.inMemory()
        let summary = IssueFixtures.summary(
            links: [IssueFixtures.link(number: 128, author: IssueFixtures.machineActor())]
        )
        try await database.saveIssueSummaries([summary])
        try await database.saveIssueSearchIndexEntries([
            IssueSearchIndexEntry(
                issueID: summary.id,
                documentHash: "hash",
                modelIdentifier: "test",
                vector: SearchVector([0.5, 0.5]),
                indexedAt: PersistenceFixtures.date(0)
            )
        ])
        try await database.savePullRequestSummaries([PersistenceFixtures.summary(id: "PR_1")])
        try await database.writer.write { db in
            try PullRequestClosingIssueRecord(
                prID: "PR_1",
                reference: LinkedIssueReference(
                    repo: PersistenceFixtures.repo,
                    number: 42,
                    title: "Login times out after the token refresh",
                    state: .open
                ),
                sortIndex: 0
            ).save(db)
        }

        try await database.eraseAllData()

        let counts = try await database.writer.read { db -> [Int] in
            try [
                "issues",
                "issue_search_index",
                "issue_linked_pull_requests",
                "pull_request_closing_issues",
            ].map { table in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
        }
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }
}

final class IssueStoreTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager.inMemory()
    }

    /// The two denormalised columns of one issue, read as scalars.
    ///
    /// Two typed reads rather than one `Row` and two casts: `Row`'s subscript is generic over
    /// every `DatabaseValueConvertible`, and a cast on an optionally-chained subscript is exactly
    /// the expression whose overload resolution is not obvious to a reader.
    static func denormalisedColumns(
        of database: DatabaseManager,
        issueID: String
    ) async throws -> (count: Int, hasAgent: Bool) {
        try await database.writer.read { db -> (count: Int, hasAgent: Bool) in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT linkedPullRequestCount FROM issues WHERE id = ?",
                arguments: [issueID]
            ) ?? -1
            let hasAgent = try Bool.fetchOne(
                db,
                sql: "SELECT hasAgentLinkedPullRequest FROM issues WHERE id = ?",
                arguments: [issueID]
            ) ?? false
            return (count: count, hasAgent: hasAgent)
        }
    }

    func testSummaryRoundTripKeepsEveryFieldIncludingItsLinks() async throws {
        let database = try makeDatabase()
        let summary = IssueFixtures.summary(
            links: [
                IssueFixtures.link(number: 128, author: IssueFixtures.machineActor()),
                IssueFixtures.link(
                    number: 131,
                    repo: PersistenceFixtures.otherRepo,
                    title: "test: cover the timeout",
                    state: "MERGED"
                ),
            ]
        )
        try await database.saveIssueSummaries([summary])

        let loaded = try await database.fetchIssueSummary(id: summary.id)
        XCTAssertEqual(loaded?.id, summary.id)
        XCTAssertEqual(loaded?.number, 42)
        XCTAssertEqual(loaded?.title, summary.title)
        XCTAssertEqual(loaded?.repo, PersistenceFixtures.repo)
        XCTAssertEqual(loaded?.state, .open)
        XCTAssertEqual(loaded?.labels, ["bug", "auth"])
        XCTAssertEqual(loaded?.myRelation, [.assigned])
        XCTAssertEqual(loaded?.commentCount, 4)
        XCTAssertEqual(loaded?.createdAt, summary.createdAt)
        XCTAssertEqual(loaded?.updatedAt, summary.updatedAt)
        XCTAssertNil(loaded?.closedAt)
        // The links come back in the order the sweep stored them, repository included.
        XCTAssertEqual(loaded?.linkedPullRequests.map(\.number), [128, 131])
        XCTAssertEqual(
            loaded?.linkedPullRequests.map(\.repo.fullName),
            ["schnaq/review", "schnaq/shepherd-web"]
        )
        XCTAssertEqual(loaded?.linkedPullRequests.map(\.state), ["OPEN", "MERGED"])
        XCTAssertEqual(loaded?.linkedPullRequests[0].author.kind.isMachine, true)
        XCTAssertEqual(loaded?.hasAgentPullRequest, true)
    }

    func testTheTwoDenormalisedColumnsAreDerivedFromTheStoredLinks() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([
            IssueFixtures.summary(
                links: [IssueFixtures.link(number: 128, author: IssueFixtures.machineActor())]
            )
        ])

        var stored = try await IssueStoreTests.denormalisedColumns(of: database, issueID: "I_1")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.hasAgent, true)

        // A later sweep that sees a human link instead replaces the rows *and* the columns: the
        // list and the facet cannot come to different conclusions.
        try await database.saveIssueSummaries([
            IssueFixtures.summary(links: [IssueFixtures.link(number: 131)])
        ])
        stored = try await IssueStoreTests.denormalisedColumns(of: database, issueID: "I_1")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.hasAgent, false)
        let reloaded = try await database.fetchIssueSummary(id: "I_1")
        XCTAssertEqual(reloaded?.linkedPullRequests.map(\.number), [131])
    }

    func testADetailFetchKeepsTheRelationsAndTheLinksTheSweepSaw() async throws {
        let database = try makeDatabase()
        let stored = IssueFixtures.summary(
            relations: [.assigned, .mentioned],
            links: [IssueFixtures.link(number: 128, author: IssueFixtures.machineActor())]
        )
        try await database.saveIssueSummaries([stored])

        // What a "cache first, then fetch that one issue" read looks like: no facet ran, so it
        // knows neither the relations nor the links.
        let detail = IssueDetail(
            summary: IssueFixtures.summary(relations: [], links: []),
            bodyMarkdown: "Steps to reproduce: sign in, wait an hour."
        )
        try await database.saveIssueDetail(detail)

        let loaded = try await database.fetchIssueDetail(id: stored.id)
        XCTAssertEqual(loaded?.bodyMarkdown, "Steps to reproduce: sign in, wait an hour.")
        XCTAssertEqual(loaded?.summary.myRelation, [.assigned, .mentioned])
        XCTAssertEqual(loaded?.summary.linkedPullRequests.map(\.number), [128])
        XCTAssertEqual(loaded?.summary.hasAgentPullRequest, true)
    }

    func testTheFilterNarrowsOnEveryAxisItCarries() async throws {
        let database = try makeDatabase()
        let now = PersistenceFixtures.date(0)
        try await database.saveIssueSummaries([
            IssueFixtures.summary(id: "I_1", number: 1, relations: [.assigned]),
            IssueFixtures.summary(
                id: "I_2",
                number: 2,
                repo: PersistenceFixtures.otherRepo,
                author: IssueFixtures.machineActor(),
                relations: [.authored],
                links: [IssueFixtures.link(number: 128, author: IssueFixtures.machineActor())]
            ),
            IssueFixtures.summary(
                id: "I_3",
                number: 3,
                createdAt: -40 * 24 * 60 * 60,
                state: .closed,
                relations: [.mentioned]
            ),
        ])

        let inbox = try await database.fetchIssues(filter: IssueFilter(now: now))
        XCTAssertEqual(Set(inbox.map(\.id)), ["I_1", "I_2"], "closed issues are out by default")

        let withClosed = try await database.fetchIssues(
            filter: IssueFilter(now: now, includeClosed: true)
        )
        XCTAssertEqual(withClosed.count, 3)

        let byRepo = try await database.fetchIssues(
            filter: IssueFilter(repo: PersistenceFixtures.otherRepo, now: now)
        )
        XCTAssertEqual(byRepo.map(\.id), ["I_2"])

        let byRelation = try await database.fetchIssues(
            filter: IssueFilter(anyOfRelations: [.authored], now: now)
        )
        XCTAssertEqual(byRelation.map(\.id), ["I_2"])

        let byAgent = try await database.fetchIssues(
            filter: IssueFilter(agentID: "dependabot", now: now)
        )
        XCTAssertEqual(byAgent.map(\.id), ["I_2"])

        let byMachine = try await database.fetchIssues(
            filter: IssueFilter(isMachineAuthored: false, now: now)
        )
        XCTAssertEqual(byMachine.map(\.id), ["I_1"])

        let byLinkedAgent = try await database.fetchIssues(
            filter: IssueFilter(hasLinkedAgentPullRequest: true, now: now)
        )
        XCTAssertEqual(byLinkedAgent.map(\.id), ["I_2"])

        let byAge = try await database.fetchIssues(
            filter: IssueFilter(ageBucket: .older, now: now, includeClosed: true)
        )
        XCTAssertEqual(byAge.map(\.id), ["I_3"])

        let limited = try await database.fetchIssues(filter: IssueFilter(now: now, limit: 1))
        XCTAssertEqual(limited.count, 1)
    }

    func testIssuesAreOrderedMostRecentlyUpdatedFirst() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([
            IssueFixtures.summary(id: "I_1", number: 1, updatedAt: -600),
            IssueFixtures.summary(id: "I_2", number: 2, updatedAt: 0),
        ])
        let inbox = try await database.fetchIssues()
        XCTAssertEqual(inbox.map(\.id), ["I_2", "I_1"])
    }

    func testAnEmptySweepEmptiesTheIssuesInbox() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([IssueFixtures.summary()])
        try await database.saveIssueSummaries([])
        let inbox = try await database.fetchIssues()
        XCTAssertTrue(inbox.isEmpty)
    }

    func testPruningKeepsAnIssueWithANonTerminalOutboxRow() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([
            IssueFixtures.summary(id: "I_1", number: 1),
            IssueFixtures.summary(id: "I_2", number: 2),
            IssueFixtures.summary(id: "I_3", number: 3),
        ])
        // The outbox names the node it targets in `prID`, whichever kind of node that is.
        let queued = OutboxItem(
            prID: "I_1",
            repo: PersistenceFixtures.repo,
            number: 1,
            action: .resolveThread(threadID: "PRRT_1")
        )
        try await database.enqueue(queued)
        let settled = OutboxItem(
            prID: "I_3",
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

        try await database.saveIssueSummaries([IssueFixtures.summary(id: "I_2", number: 2)])

        let inbox = try await database.fetchIssues()
        XCTAssertEqual(
            Set(inbox.map(\.id)),
            ["I_1", "I_2"],
            "a queued mutation holds its issue open; a failed one does not"
        )

        // And once the queued row succeeds, the next sweep lets it go.
        try await database.markOutboxItemSucceeded(id: queued.id)
        try await database.saveIssueSummaries([IssueFixtures.summary(id: "I_2", number: 2)])
        let after = try await database.fetchIssues()
        XCTAssertEqual(after.map(\.id), ["I_2"])
    }

    func testAPrunedIssueTakesItsLinksAndItsIndexRowWithIt() async throws {
        let database = try makeDatabase()
        let summary = IssueFixtures.summary(links: [IssueFixtures.link(number: 128)])
        try await database.saveIssueSummaries([summary])
        try await database.saveIssueSearchIndexEntries([
            IssueSearchIndexEntry(
                issueID: summary.id,
                documentHash: "hash",
                modelIdentifier: "test",
                vector: nil,
                indexedAt: PersistenceFixtures.date(0)
            )
        ])

        try await database.saveIssueSummaries([])

        let counts = try await database.writer.read { db -> [Int] in
            try [
                "issues", "issue_linked_pull_requests", "issue_search_index",
            ].map { table in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
        }
        XCTAssertEqual(counts, [0, 0, 0], "the cascade is the pruning")
    }

    func testARepositoryWithIssuesButNoPullRequestsSurvivesThePullRequestSweep() async throws {
        // `repos` is the parent of both tables with `ON DELETE CASCADE`, so a prune that looked
        // only at `pull_requests` would delete the repository and every issue in it (ADR 0032).
        let database = try makeDatabase()
        try await database.saveIssueSummaries([IssueFixtures.summary()])
        try await database.savePullRequestSummaries([], pruneMissing: true)

        let inbox = try await database.fetchIssues()
        XCTAssertEqual(inbox.map(\.id), ["I_1"])
    }

    func testAnIssueOnlyRepositoryIsPrunedOnceItsIssuesAreGone() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([IssueFixtures.summary()])
        try await database.saveIssueSummaries([])

        let repos = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repos") ?? -1
        }
        XCTAssertEqual(repos, 0)
    }

    func testTheObservationEmitsTheCurrentInbox() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([
            IssueFixtures.summary(id: "I_1", number: 1),
            IssueFixtures.summary(id: "I_2", number: 2, state: .closed),
        ])

        var iterator = database.observeIssues().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.map(\.id), ["I_1"], "the filter travels with the observation")
    }
}

/// The issue search index's own store operations (ADR 0032).
final class IssueSearchIndexStoreTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager.inMemory()
    }

    private func entry(
        issueID: String,
        hash: String = "hash-1",
        model: String = "test-embedder",
        vector: SearchVector? = SearchVector([0.6, 0.8])
    ) -> IssueSearchIndexEntry {
        IssueSearchIndexEntry(
            issueID: issueID,
            documentHash: hash,
            modelIdentifier: model,
            vector: vector,
            indexedAt: PersistenceFixtures.date(0)
        )
    }

    func testEntriesRoundTripIncludingTheirVector() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([IssueFixtures.summary()])
        try await database.saveIssueSearchIndexEntries([entry(issueID: "I_1")])

        let entries = try await database.issueSearchIndexEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].documentHash, "hash-1")
        XCTAssertEqual(entries[0].modelIdentifier, "test-embedder")
        XCTAssertEqual(entries[0].vector?.dimensions, 2)
    }

    func testARowWhoseIssueLeftTheInboxIsSkippedRatherThanFailingTheBatch() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([IssueFixtures.summary(id: "I_1", number: 1)])

        try await database.saveIssueSearchIndexEntries([
            entry(issueID: "I_1"),
            entry(issueID: "I_gone"),
        ])

        let entries = try await database.issueSearchIndexEntries()
        XCTAssertEqual(entries.map(\.issueID), ["I_1"])
    }

    func testStatisticsCountRowsAndVectorBytes() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([
            IssueFixtures.summary(id: "I_1", number: 1),
            IssueFixtures.summary(id: "I_2", number: 2),
        ])
        try await database.saveIssueSearchIndexEntries([
            entry(issueID: "I_1"),
            entry(issueID: "I_2", vector: nil),
        ])

        let statistics = try await database.issueSearchIndexStatistics()
        XCTAssertEqual(statistics.entryCount, 2)
        XCTAssertEqual(statistics.vectorCount, 1, "a row without a vector is a normal row")
        XCTAssertEqual(statistics.vectorByteCount, 8)
        XCTAssertEqual(statistics.lastIndexedAt, PersistenceFixtures.date(0))
    }

    func testDeletingAndClearingRemoveRowsWithoutTouchingTheIssue() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([
            IssueFixtures.summary(id: "I_1", number: 1),
            IssueFixtures.summary(id: "I_2", number: 2),
        ])
        try await database.saveIssueSearchIndexEntries([
            entry(issueID: "I_1"),
            entry(issueID: "I_2"),
        ])

        try await database.deleteIssueSearchIndexEntries(issueIDs: ["I_1"])
        var entries = try await database.issueSearchIndexEntries()
        XCTAssertEqual(entries.map(\.issueID), ["I_2"])

        try await database.clearIssueSearchIndex()
        entries = try await database.issueSearchIndexEntries()
        XCTAssertTrue(entries.isEmpty)
        let inbox = try await database.fetchIssues()
        XCTAssertEqual(inbox.count, 2, "rebuilding the index must not touch the inbox")
    }

    func testSourcesCarryTheBodyAndTheDetailStampInTheOrderAsked() async throws {
        let database = try makeDatabase()
        try await database.saveIssueSummaries([
            IssueFixtures.summary(id: "I_1", number: 1),
            IssueFixtures.summary(id: "I_2", number: 2),
        ])
        try await database.saveIssueDetail(
            IssueDetail(
                summary: IssueFixtures.summary(id: "I_2", number: 2),
                bodyMarkdown: "The token refresh window is an hour."
            )
        )

        let sources = try await database.issueSearchIndexSources(issueIDs: ["I_2", "I_1"])
        XCTAssertEqual(sources.map(\.summary.id), ["I_2", "I_1"])
        XCTAssertEqual(sources[0].bodyMarkdown, "The token refresh window is an hour.")
        XCTAssertNotNil(sources[0].detailFetchedAt)
        XCTAssertEqual(sources[1].bodyMarkdown, "")
        XCTAssertNil(sources[1].detailFetchedAt)

        let stamps = try await database.issueDetailFetchTimestamps()
        XCTAssertEqual(Set(stamps.keys), ["I_2"])
    }
}

/// Migration v8: `outbox.lastErrorCode` (ADR 0022, 2026-09-22 amendment).
final class OutboxErrorCodeMigrationTests: XCTestCase {
    func testV8AddsOneNullableColumnAndLeavesARowWrittenBeforeItReadable() async throws {
        // A database migrated only as far as v7, holding a failed row the way an older build left
        // it: English text, no code.
        let queue = try DatabaseQueue()
        var upToV7 = DatabaseMigrator()
        upToV7.registerMigration("v1", migrate: DatabaseSchema.createV1)
        upToV7.registerMigration("v2", migrate: DatabaseSchema.addV2)
        upToV7.registerMigration("v3", migrate: DatabaseSchema.addV3)
        upToV7.registerMigration("v4", migrate: DatabaseSchema.addV4)
        upToV7.registerMigration("v5", migrate: DatabaseSchema.addV5)
        upToV7.registerMigration("v6", migrate: DatabaseSchema.addV6)
        upToV7.registerMigration("v7", migrate: DatabaseSchema.addV7)
        try upToV7.migrate(queue)
        let before = try await queue.read { db in try db.columns(in: "outbox").map(\.name) }
        XCTAssertFalse(before.contains("lastErrorCode"))

        let id = UUID()
        let payload = try JSONEncoder().encode(OutboxAction.markReadyForReview)
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO outbox (id, kind, prID, repoFullName, number, payload, createdAt,
                                        attemptCount, nextAttemptAt, lastError, state)
                    VALUES (?, 'markReadyForReview', 'PR_1', 'schnaq/review', 1, ?, 0, 3, 0, ?, 'failed')
                    """,
                arguments: [id.uuidString, payload, "GitHub returned 502: bad gateway"]
            )
        }

        let database = try DatabaseManager(writer: queue)
        let columns = try await database.writer.read { db in try db.columns(in: "outbox") }
        let code = try XCTUnwrap(columns.first { $0.name == "lastErrorCode" })
        XCTAssertEqual(code.type, "TEXT")
        XCTAssertFalse(code.isNotNull, "additive: every existing row has no code")

        let row = try await database.outboxItem(id: id)
        XCTAssertEqual(row?.lastError, "GitHub returned 502: bad gateway")
        XCTAssertNil(row?.lastErrorCode)
    }

    func testTheCodeIsWrittenWithAFailureAndClearedByARetryOrAConflict() async throws {
        let database = try DatabaseManager.inMemory()
        let item = OutboxItem(
            prID: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 1,
            action: .markReadyForReview
        )
        try await database.enqueue(item)
        try await database.markOutboxItemFailed(
            id: item.id,
            error: "GitHub rejected the data: nope",
            errorCode: "code-1",
            retriable: false
        )
        let failed = try await database.outboxItem(id: item.id)
        XCTAssertEqual(failed?.lastError, "GitHub rejected the data: nope")
        XCTAssertEqual(failed?.lastErrorCode, "code-1")

        try await database.retryOutboxItem(id: item.id)
        let retried = try await database.outboxItem(id: item.id)
        XCTAssertNil(retried?.lastErrorCode, "a retried row no longer describes a failure")

        try await database.markOutboxItemFailed(id: item.id, error: "x", errorCode: "code-2")
        try await database.markOutboxItemConflicted(id: item.id, reason: "head moved")
        let parked = try await database.outboxItem(id: item.id)
        XCTAssertEqual(parked?.lastError, "head moved")
        XCTAssertNil(parked?.lastErrorCode, "the code never outlives the text it belongs to")
    }
}

/// Migration v9: `pull_requests.mergeStateStatus` (ADR 0041).
final class MergeStateStatusMigrationTests: XCTestCase {
    func testV9AddsOneNullableColumnAndARowWrittenBeforeItReadsBackWithoutAState() async throws {
        // A database migrated only as far as v8, holding a pull request an older build stored.
        let queue = try DatabaseQueue()
        var upToV8 = DatabaseMigrator()
        upToV8.registerMigration("v1", migrate: DatabaseSchema.createV1)
        upToV8.registerMigration("v2", migrate: DatabaseSchema.addV2)
        upToV8.registerMigration("v3", migrate: DatabaseSchema.addV3)
        upToV8.registerMigration("v4", migrate: DatabaseSchema.addV4)
        upToV8.registerMigration("v5", migrate: DatabaseSchema.addV5)
        upToV8.registerMigration("v6", migrate: DatabaseSchema.addV6)
        upToV8.registerMigration("v7", migrate: DatabaseSchema.addV7)
        upToV8.registerMigration("v8", migrate: DatabaseSchema.addV8)
        try upToV8.migrate(queue)
        let before = try await queue.read { db in
            try db.columns(in: "pull_requests").map(\.name)
        }
        XCTAssertFalse(before.contains("mergeStateStatus"))
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO repos (fullName, owner, name) VALUES ('schnaq/review', 'schnaq', 'review')")
            try db.execute(
                sql: """
                    INSERT INTO pull_requests (id, repoFullName, number, title, authorLogin,
                        authorKind, createdAt, updatedAt, isDraft, additions, deletions,
                        changedFiles, headRefName, headRefOid, baseRefName, checkTotal,
                        checkSuccess, checkFailure, checkPending, relations, labels, mergeable)
                    VALUES ('PR_old', 'schnaq/review', 7, 'Old row', 'octocat', 'human', 0, 0, 0,
                        1, 1, 1, 'fix', 'abc', 'main', 0, 0, 0, 0, '[]', '[]', 'mergeable')
                    """
            )
        }

        let database = try DatabaseManager(writer: queue)
        let columns = try await database.writer.read { db in try db.columns(in: "pull_requests") }
        let column = try XCTUnwrap(columns.first { $0.name == "mergeStateStatus" })
        XCTAssertEqual(column.type, "TEXT")
        XCTAssertFalse(column.isNotNull, "additive: every existing row has no state")

        let loaded = try await database.fetchPullRequestSummary(id: "PR_old")
        XCTAssertEqual(loaded?.mergeable, .mergeable)
        XCTAssertNil(loaded?.mergeStateStatus)
    }

    func testEveryMergeStateStatusRoundTripsThroughTheInbox() async throws {
        let database = try DatabaseManager.inMemory()
        for state in MergeStateStatus.allCases {
            var summary = PersistenceFixtures.summary()
            summary.mergeStateStatus = state
            try await database.savePullRequestSummaries([summary])
            let loaded = try await database.fetchPullRequestSummary(id: summary.id)
            XCTAssertEqual(loaded?.mergeStateStatus, state)
        }

        var cleared = PersistenceFixtures.summary()
        cleared.mergeStateStatus = nil
        try await database.savePullRequestSummaries([cleared])
        let loaded = try await database.fetchPullRequestSummary(id: cleared.id)
        XCTAssertNil(loaded?.mergeStateStatus, "a sweep without the field clears it")
    }

    func testADetailWithoutAStateKeepsTheOneTheSweepStored() async throws {
        let database = try DatabaseManager.inMemory()
        var summary = PersistenceFixtures.summary()
        summary.mergeStateStatus = .behind
        try await database.savePullRequestSummaries([summary])

        var detailSummary = summary
        detailSummary.mergeStateStatus = nil
        try await database.savePullRequestDetail(PersistenceFixtures.detail(summary: detailSummary))
        let kept = try await database.fetchPullRequestSummary(id: summary.id)
        XCTAssertEqual(kept?.mergeStateStatus, .behind)

        detailSummary.mergeStateStatus = .clean
        try await database.savePullRequestDetail(PersistenceFixtures.detail(summary: detailSummary))
        let replaced = try await database.fetchPullRequestSummary(id: summary.id)
        XCTAssertEqual(replaced?.mergeStateStatus, .clean, "a detail that knows the state wins")
    }
}
