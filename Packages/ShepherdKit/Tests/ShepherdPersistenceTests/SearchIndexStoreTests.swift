import Foundation
import GRDB
import ShepherdCore
import XCTest
@testable import ShepherdPersistence

/// The v3 search index (ADR 0019): the round trip through the BLOB column, the pruning that is a
/// foreign key, the batched source read, and the numbers the settings card shows.
///
/// In-memory `DatabaseQueue` like every other persistence suite, so it behaves identically on the
/// macOS and the Linux runner.
final class SearchIndexStoreTests: XCTestCase {
    private func entry(
        prID: String = "PR_1",
        documentHash: String = "hash-1",
        model: String = "test-model",
        vector: SearchVector? = SearchVector([0.5, -0.5, 1, 0]),
        indexedAt: TimeInterval = 0
    ) -> SearchIndexEntry {
        SearchIndexEntry(
            prID: prID,
            documentHash: documentHash,
            modelIdentifier: model,
            vector: vector,
            indexedAt: PersistenceFixtures.date(indexedAt)
        )
    }

    func testTheSchemaGainsV3AndStaysAppendOnly() async throws {
        XCTAssertEqual(DatabaseManager.migrator.migrations, ["v1", "v2", "v3", "v4"])
        let database = try DatabaseManager.inMemory()
        try await database.writer.read { db in
            let columns = try db.columns(in: "search_index").map(\.name)
            XCTAssertEqual(
                columns.sorted(),
                [
                    "dimensions",
                    "documentHash",
                    "indexedAt",
                    "modelIdentifier",
                    "prID",
                    "vector",
                ]
            )
        }
    }

    func testAnEntryRoundTripsThroughTheBlobColumn() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        try await database.saveSearchIndexEntries([entry()])

        let stored = try await database.searchIndexEntries()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.documentHash, "hash-1")
        XCTAssertEqual(stored.first?.modelIdentifier, "test-model")
        XCTAssertEqual(stored.first?.vector, SearchVector([0.5, -0.5, 1, 0]))
        XCTAssertEqual(stored.first?.indexedAt, PersistenceFixtures.date(0))
    }

    func testAnEntryWithoutAVectorIsAValidRow() async throws {
        // What a Mac with no on-device embedding model stores for every pull request: the hashes
        // are worth keeping on their own, because they are what stops the lexical corpus being
        // rebuilt from every stored diff on every sweep.
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        try await database.saveSearchIndexEntries([entry(vector: nil)])

        let stored = try await database.searchIndexEntries()
        XCTAssertEqual(stored.count, 1)
        XCTAssertNil(stored.first?.vector)
    }

    func testSavingIsAnUpsert() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        try await database.saveSearchIndexEntries([entry()])
        try await database.saveSearchIndexEntries([
            entry(documentHash: "hash-2", vector: SearchVector([1, 0])),
        ])

        let stored = try await database.searchIndexEntries()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.documentHash, "hash-2")
        XCTAssertEqual(stored.first?.vector?.dimensions, 2)
    }

    func testAnIndexRowGoesWhenItsPullRequestLeavesTheInbox() async throws {
        // The pruning *is* the foreign key: no second sweep, nothing to remember, and it happens
        // inside the transaction the sweep is already doing.
        let database = try DatabaseManager.inMemory()
        let keep = PersistenceFixtures.summary(id: "PR_keep", number: 1)
        let goes = PersistenceFixtures.summary(id: "PR_goes", number: 2)
        try await database.savePullRequestSummaries([keep, goes])
        try await database.saveSearchIndexEntries([
            entry(prID: "PR_keep"),
            entry(prID: "PR_goes"),
        ])

        try await database.savePullRequestSummaries([keep])

        let stored = try await database.searchIndexEntries()
        XCTAssertEqual(stored.map(\.prID), ["PR_keep"])
    }

    func testAnEntryForAPullRequestThatIsAlreadyGoneIsSkippedRatherThanFailing() async throws {
        // The race the coordinator cannot avoid: the sweep pruned the pull request while its
        // embedding was being computed. Losing that one row is correct; losing the batch is not.
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary(id: "PR_1")])
        try await database.saveSearchIndexEntries([
            entry(prID: "PR_1"),
            entry(prID: "PR_vanished"),
        ])

        let stored = try await database.searchIndexEntries()
        XCTAssertEqual(stored.map(\.prID), ["PR_1"])
    }

    func testEntriesCanBeDeletedAndCleared() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1),
            PersistenceFixtures.summary(id: "PR_2", number: 2),
        ])
        try await database.saveSearchIndexEntries([entry(prID: "PR_1"), entry(prID: "PR_2")])

        try await database.deleteSearchIndexEntries(prIDs: ["PR_1"])
        var stored = try await database.searchIndexEntries()
        XCTAssertEqual(stored.map(\.prID), ["PR_2"])

        try await database.clearSearchIndex()
        stored = try await database.searchIndexEntries()
        XCTAssertTrue(stored.isEmpty)
    }

    func testErasingLocalDataTakesTheIndexWithIt() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])
        try await database.saveSearchIndexEntries([entry()])

        try await database.eraseAllData()

        let stored = try await database.searchIndexEntries()
        XCTAssertTrue(stored.isEmpty)
    }

    func testStatisticsCountRowsBytesAndTheNewestWrite() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1),
            PersistenceFixtures.summary(id: "PR_2", number: 2),
        ])
        try await database.saveSearchIndexEntries([
            entry(prID: "PR_1", vector: SearchVector([1, 0, 0, 0]), indexedAt: 0),
            entry(prID: "PR_2", vector: nil, indexedAt: 600),
        ])

        let statistics = try await database.searchIndexStatistics()
        XCTAssertEqual(statistics.entryCount, 2)
        // The gap between the two counts is exactly the state the settings line has to explain.
        XCTAssertEqual(statistics.vectorCount, 1)
        XCTAssertEqual(statistics.vectorByteCount, 16)
        XCTAssertEqual(statistics.lastIndexedAt, PersistenceFixtures.date(600))
    }

    func testStatisticsOfAnEmptyIndexAreZeroes() async throws {
        let database = try DatabaseManager.inMemory()
        let statistics = try await database.searchIndexStatistics()
        XCTAssertEqual(statistics.entryCount, 0)
        XCTAssertEqual(statistics.vectorByteCount, 0)
        XCTAssertNil(statistics.lastIndexedAt)
    }

    // MARK: - Sources

    func testASourceCarriesTheRowEvenWhenNoDetailWasEverFetched() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([PersistenceFixtures.summary()])

        let sources = try await database.searchIndexSources(prIDs: ["PR_1"])
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.summary.title, "Refactor the token store")
        XCTAssertEqual(sources.first?.bodyMarkdown, "")
        XCTAssertTrue(sources.first?.files.isEmpty == true)
        XCTAssertNil(sources.first?.detailFetchedAt)
    }

    func testASourceCarriesTheBodyThePathsAndThePatchesOnceADetailWasFetched() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestDetail(PersistenceFixtures.detail())

        let sources = try await database.searchIndexSources(prIDs: ["PR_1"])
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.bodyMarkdown, "Moves the Keychain wrapper behind a protocol.")
        XCTAssertEqual(
            source.files.map(\.path),
            ["Sources/Auth/TokenStore.swift", "Sources/Auth/KeychainTokenStore.swift"]
        )
        XCTAssertEqual(source.files.first?.patch, "@@ -1,3 +1,4 @@\n+protocol TokenStore {}")
        XCTAssertNotNil(source.detailFetchedAt)

        // And the composed document then carries the diff, which is the whole point of indexing
        // what the review screen already stored.
        let document = SearchDocument.make(source: source)
        XCTAssertTrue(document.hasDetail)
        XCTAssertNotNil(document.terms["keychain"])
        XCTAssertNotNil(document.terms["protocol"])
    }

    func testSourcesComeBackInTheOrderTheyWereAskedForAndSkipUnknownIDs() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1),
            PersistenceFixtures.summary(id: "PR_2", number: 2),
        ])

        let sources = try await database.searchIndexSources(prIDs: ["PR_2", "PR_nope", "PR_1"])
        XCTAssertEqual(sources.map(\.summary.id), ["PR_2", "PR_1"])
    }

    func testDetailTimestampsAreOnlyReportedForFetchedPullRequests() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries([
            PersistenceFixtures.summary(id: "PR_1", number: 1),
            PersistenceFixtures.summary(id: "PR_2", number: 2),
        ])
        try await database.savePullRequestDetail(
            PersistenceFixtures.detail(summary: PersistenceFixtures.summary(id: "PR_2", number: 2))
        )

        let timestamps = try await database.detailFetchTimestamps()
        XCTAssertEqual(timestamps.count, 1)
        XCTAssertNotNil(timestamps["PR_2"])

        // Which is what moves the cheap fingerprint: the same row, before and after somebody
        // opened the pull request, is a different document.
        let before = SearchDocument.make(
            source: SearchIndexSource(summary: PersistenceFixtures.summary(id: "PR_2", number: 2))
        )
        let refreshed = try await database.searchIndexSources(prIDs: ["PR_2"])
        let after = SearchDocument.make(source: try XCTUnwrap(refreshed.first))
        XCTAssertNotEqual(before.sourceFingerprint, after.sourceFingerprint)
    }
}
