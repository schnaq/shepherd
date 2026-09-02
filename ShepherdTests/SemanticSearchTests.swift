import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// The app half of semantic ⌘K search (ADR 0019): when an embedding is spent, what the corpus
/// holds, what the palette gets back, and what the switched-off and no-model states do.
///
/// The *ranking* is covered exhaustively by `SearchRankerTests` in ShepherdKit, which runs on the
/// Linux runner. What is tested here is everything the pure function cannot see: the pass over the
/// rows a sweep wrote, the two staleness gates, the pruning, and the two degraded states that have
/// to keep working — the toggle off and a Mac with no embedding model.
///
/// Every embedding goes through the injected ``EmbeddingProviding`` seam, so nothing here depends
/// on Apple's model being present or on its output being stable.
@MainActor
final class SemanticSearchTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let clock = Date(timeIntervalSince1970: 1_788_162_000)

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "shepherd.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removeSuite(named: suiteName)
    }

    // MARK: - Doubles

    /// A deterministic stand-in for the on-device model.
    ///
    /// Three "concepts", each a list of words: a text's vector is how many words of each list it
    /// contains. That is enough to be a real embedding for test purposes — two texts that share a
    /// concept but no word have a cosine of 1 — while staying something a reader can predict.
    /// It also counts its calls, which is what the re-embed gate is asserted through.
    private actor FakeEmbedder: EmbeddingProviding {
        nonisolated let modelIdentifier: String
        private let isAvailable: Bool
        private(set) var embeddedTexts: [String] = []

        private static let concepts: [[String]] = [
            ["login", "auth", "session", "signin", "credential", "password"],
            ["dependency", "dependencies", "bump", "version", "library", "grdb", "package"],
            ["theme", "appearance", "settings", "dark", "colour", "color"],
        ]

        init(modelIdentifier: String = "fake-1", isAvailable: Bool = true) {
            self.modelIdentifier = modelIdentifier
            self.isAvailable = isAvailable
        }

        var callCount: Int { embeddedTexts.count }

        func availability() async -> EmbeddingAvailability {
            isAvailable ? .available : .unavailable("no model in this test")
        }

        func vector(for text: String) async -> SearchVector? {
            embeddedTexts.append(text)
            guard isAvailable else { return nil }
            let tokens = Set(SearchText.tokens(in: text))
            let values = FakeEmbedder.concepts.map { concept -> Float in
                Float(concept.filter { tokens.contains($0) }.count)
            }
            let vector = SearchVector(values)
            // A text that hits no concept has no direction, and a zero vector is not a vector:
            // returning nil is what the real model does for input it cannot embed.
            return vector.values.contains(where: { $0 > 0 }) ? vector.normalized : nil
        }
    }

    // MARK: - Fixtures

    private func summary(
        id: String,
        number: Int,
        title: String,
        labels: [String] = [],
        branch: String = "main",
        updatedAt: TimeInterval = 0
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: title,
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: clock.addingTimeInterval(updatedAt),
            createdAt: clock,
            headRefName: branch,
            headRefOid: "head-\(number)",
            baseRefName: "main",
            myRelation: [.reviewRequested],
            labels: labels,
            mergeable: .mergeable
        )
    }

    private var rows: [PullRequestSummary] {
        [
            summary(id: "PR_1", number: 1, title: "Fix the flaky login test", labels: ["bug"]),
            summary(id: "PR_2", number: 2, title: "Bump GRDB", labels: ["automerge"]),
            summary(id: "PR_3", number: 3, title: "A dark theme for the sidebar"),
        ]
    }

    private func makeSettings(semanticSearchEnabled: Bool = true) -> AppSettings {
        let settings = AppSettings(defaults: defaults)
        settings.semanticSearchEnabled = semanticSearchEnabled
        return settings
    }

    private func makeCoordinator(
        settings: AppSettings,
        embedder: any EmbeddingProviding
    ) -> SearchIndexCoordinator {
        let fixedNow = clock
        return SearchIndexCoordinator(
            settings: settings,
            embedder: embedder,
            now: { fixedNow }
        )
    }

    /// Runs one pass and waits for it, which is what ``SearchIndexCoordinator/passTask`` is for.
    private func index(
        _ coordinator: SearchIndexCoordinator,
        rows: [PullRequestSummary],
        database: DatabaseManager
    ) async {
        coordinator.considerIndexing(rows: rows, database: database)
        await waitForPass(coordinator)
    }

    /// Awaits the running pass, if there is one.
    ///
    /// Written as an `if let` rather than as `await coordinator.passTask?.value` because an
    /// optional-chained `await` on a property is the kind of expression that reads as a typo.
    private func waitForPass(_ coordinator: SearchIndexCoordinator) async {
        guard let task = coordinator.passTask else { return }
        await task.value
    }

    // MARK: - Indexing

    func testAFirstPassEmbedsEveryRowOnceAndStoresIt() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let embedder = FakeEmbedder()
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: embedder)

        await index(coordinator, rows: rows, database: database)

        let calls = await embedder.callCount
        XCTAssertEqual(calls, 3, "one embedding per pull request, and not one more")
        let entries = try await database.searchIndexEntries()
        XCTAssertEqual(Set(entries.map(\.prID)), ["PR_1", "PR_2", "PR_3"])
        XCTAssertEqual(entries.first?.modelIdentifier, "fake-1")
        XCTAssertEqual(entries.first?.indexedAt, clock)
        XCTAssertEqual(coordinator.status.documentCount, 3)
        XCTAssertFalse(coordinator.status.isIndexing)
    }

    func testASecondPassOverUnchangedRowsSpendsNoEmbeddings() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let embedder = FakeEmbedder()
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: embedder)

        await index(coordinator, rows: rows, database: database)
        await index(coordinator, rows: rows, database: database)

        let calls = await embedder.callCount
        XCTAssertEqual(calls, 3, "the fingerprint gate stops the second pass before it reads")
    }

    func testANewTitleCostsExactlyOneEmbedding() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let embedder = FakeEmbedder()
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: embedder)
        await index(coordinator, rows: rows, database: database)

        var edited = rows
        edited[0].title = "Fix the flaky authentication test"
        try await database.savePullRequestSummaries(edited)
        await index(coordinator, rows: edited, database: database)

        let calls = await embedder.callCount
        XCTAssertEqual(calls, 4)
    }

    func testARowThatChangedWithoutChangingItsTextKeepsItsVector() async throws {
        // The common case by far: a sweep re-reads a pull request whose `updatedAt` moved because
        // somebody commented. The fingerprint moves, the *document* does not, and the stored
        // vector is reused rather than recomputed.
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let embedder = FakeEmbedder()
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: embedder)
        await index(coordinator, rows: rows, database: database)

        var touched = rows
        touched[1].updatedAt = clock.addingTimeInterval(600)
        try await database.savePullRequestSummaries(touched)
        await index(coordinator, rows: touched, database: database)

        let calls = await embedder.callCount
        XCTAssertEqual(calls, 3)
    }

    func testAPullRequestThatLeftTheInboxLeavesTheCorpusAndTheTable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: FakeEmbedder())
        await index(coordinator, rows: rows, database: database)

        let remaining = Array(rows.prefix(2))
        try await database.savePullRequestSummaries(remaining)
        await index(coordinator, rows: remaining, database: database)

        XCTAssertEqual(coordinator.status.documentCount, 2)
        let entries = try await database.searchIndexEntries()
        XCTAssertEqual(Set(entries.map(\.prID)), ["PR_1", "PR_2"])
        let results = await coordinator.results(for: "dark theme")
        XCTAssertTrue(results.isEmpty, "a pruned pull request is not a search result")
    }

    func testADiffStoredForReviewBecomesSearchable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: FakeEmbedder())
        await index(coordinator, rows: rows, database: database)

        let beforeTheDiff = await coordinator.results(for: "retryUntilStable")
        XCTAssertTrue(beforeTheDiff.isEmpty, "the diff is not in the database yet")

        let detail = PullRequestDetail(
            summary: rows[0],
            bodyMarkdown: "The suite fails once in twenty runs.",
            files: [
                ChangedFile(
                    path: "Tests/LoginTests.swift",
                    previousPath: nil,
                    status: .modified,
                    additions: 4,
                    deletions: 1,
                    patch: "@@ -1 +1 @@\n+retryUntilStable(attempts: 3)",
                    isViewed: false
                ),
            ]
        )
        try await database.savePullRequestDetail(detail)
        // The review screen's hook (ADR 0019). The next ordinary pass would find it too — the
        // stored `detailFetchedAt` moved — which is exactly what the next assertion relies on.
        coordinator.indexAfterDetailLoad(prID: "PR_1", database: database)
        await waitForPass(coordinator)

        let found = await coordinator.results(for: "retryUntilStable")
        XCTAssertEqual(found.map(\.id), ["PR_1"])
        XCTAssertEqual(found.first?.reason, .addedLine("retryUntilStable(attempts: 3)"))

        let byDescription = await coordinator.results(for: "twenty runs")
        XCTAssertEqual(byDescription.map(\.id), ["PR_1"], "the description is indexed too")
    }

    // MARK: - Searching

    func testAnExactSlugOpensThatPullRequestFirst() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: FakeEmbedder())
        await index(coordinator, rows: rows, database: database)

        let bySlug = await coordinator.results(for: "schnaq/review#3")
        XCTAssertEqual(bySlug.first?.id, "PR_3")
        let byNumber = await coordinator.results(for: "#2")
        XCTAssertEqual(byNumber.first?.id, "PR_2")
    }

    func testTheEmbeddingFindsAPullRequestTheWordsDoNot() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: FakeEmbedder())
        await index(coordinator, rows: rows, database: database)

        // "newer library version" shares no word with "Bump GRDB" — but both are about the same
        // concept, which is the whole feature.
        let results = await coordinator.results(for: "newer library version")
        XCTAssertEqual(results.map(\.id), ["PR_2"])
        XCTAssertEqual(results.first?.reason, .semantic)
    }

    func testAQueryAboutNothingInTheInboxAnswersNothing() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: FakeEmbedder())
        await index(coordinator, rows: rows, database: database)

        let results = await coordinator.results(for: "kubernetes helm chart")
        XCTAssertTrue(results.isEmpty)
    }

    func testAnEmptyQueryAnswersNothing() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: FakeEmbedder())
        await index(coordinator, rows: rows, database: database)

        let results = await coordinator.results(for: "   ")
        XCTAssertTrue(results.isEmpty)
    }

    func testTheResultLimitIsTheCallersAndTheOrderIsStable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: FakeEmbedder())
        await index(coordinator, rows: rows, database: database)

        let first = await coordinator.results(for: "the", limit: 2)
        XCTAssertLessThanOrEqual(first.count, 2)
        let second = await coordinator.results(for: "the", limit: 2)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    // MARK: - The two degraded states

    func testWithoutAnEmbeddingModelSearchStillMatchesWordsAndSettingsSaysWhy() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            embedder: FakeEmbedder(isAvailable: false)
        )

        await index(coordinator, rows: rows, database: database)

        XCTAssertEqual(coordinator.status.embeddingUnavailabilityReason, "no model in this test")
        XCTAssertEqual(coordinator.status.embeddedCount, 0)
        // The rows are still indexed — the hashes are what stop the next sweep re-reading every
        // diff — and the lexical ranker still answers.
        let entries = try await database.searchIndexEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.allSatisfy { $0.vector == nil })
        let results = await coordinator.results(for: "flaky login")
        XCTAssertEqual(results.map(\.id), ["PR_1"])
    }

    func testWithTheToggleOffNothingIsReadEmbeddedOrStored() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let embedder = FakeEmbedder()
        let coordinator = makeCoordinator(
            settings: makeSettings(semanticSearchEnabled: false),
            embedder: embedder
        )

        await index(coordinator, rows: rows, database: database)

        let calls = await embedder.callCount
        XCTAssertEqual(calls, 0)
        let entries = try await database.searchIndexEntries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(coordinator.status.isEnabled)
        // And ⌘K still finds pull requests by their words, which is what makes the toggle an
        // "off" rather than a broken palette.
        XCTAssertEqual(coordinator.status.documentCount, 3)
        let results = await coordinator.results(for: "flaky login")
        XCTAssertEqual(results.map(\.id), ["PR_1"])
    }

    func testSwitchingItOffEmptiesTheTable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let settings = makeSettings()
        let coordinator = makeCoordinator(settings: settings, embedder: FakeEmbedder())
        await index(coordinator, rows: rows, database: database)

        settings.semanticSearchEnabled = false
        await coordinator.disable(database: database)

        let entries = try await database.searchIndexEntries()
        XCTAssertTrue(entries.isEmpty, "a switch named after an index leaves none behind")
        XCTAssertFalse(coordinator.status.isEnabled)
        XCTAssertEqual(coordinator.status.vectorByteCount, 0)
    }

    // MARK: - Rebuild and reset

    func testRebuildingClearsTheTableAndEmbedsAgain() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let embedder = FakeEmbedder()
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: embedder)
        await index(coordinator, rows: rows, database: database)

        await coordinator.rebuild(database: database)
        await waitForPass(coordinator)

        let calls = await embedder.callCount
        XCTAssertEqual(calls, 6, "a rebuild is a full re-embed, on purpose")
        let entries = try await database.searchIndexEntries()
        XCTAssertEqual(entries.count, 3)
    }

    func testResetDropsTheCorpusSoASignOutLeavesNothingSearchable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: FakeEmbedder())
        await index(coordinator, rows: rows, database: database)

        coordinator.reset()

        XCTAssertEqual(coordinator.status.documentCount, 0)
        let results = await coordinator.results(for: "flaky login")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Chunking

    func testALongDocumentIsChunkedAtWordBoundaries() {
        let text = "alpha beta gamma delta epsilon zeta eta theta"
        let chunks = EmbeddingChunker.chunks(
            in: text,
            maximumCharacters: 12,
            maximumChunks: 8
        )
        XCTAssertEqual(chunks, ["alpha beta", "gamma delta", "epsilon zeta", "eta theta"])
        for chunk in chunks {
            XCTAssertFalse(chunk.hasPrefix(" "))
            XCTAssertFalse(chunk.hasSuffix(" "))
        }
    }

    func testChunkingIsBoundedSoOnePullRequestCannotCostFiftyEmbeddings() {
        let text = String(repeating: "word ", count: 5_000)
        let chunks = EmbeddingChunker.chunks(
            in: text,
            maximumCharacters: 20,
            maximumChunks: 3
        )
        XCTAssertEqual(chunks.count, 3)
    }

    func testAWordLongerThanTheWindowIsCutHardRatherThanLoopingForever() {
        let chunks = EmbeddingChunker.chunks(
            in: String(repeating: "x", count: 25),
            maximumCharacters: 10,
            maximumChunks: 8
        )
        XCTAssertEqual(chunks, [String(repeating: "x", count: 10),
                                String(repeating: "x", count: 10),
                                String(repeating: "x", count: 5)])
    }

    func testAnEmptyDocumentProducesNoChunks() {
        XCTAssertTrue(
            EmbeddingChunker.chunks(in: "  \n ", maximumCharacters: 10, maximumChunks: 3)
                .isEmpty
        )
    }
}
