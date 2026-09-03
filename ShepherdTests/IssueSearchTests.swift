import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// The app half of ⌘K's second pass (ADR 0032): when an issue embedding is spent, what the second
/// corpus holds, and how the two ranked sets become one ordered answer.
///
/// The *ranking* is `IssueSearchRankerTests` on the Linux runner; the *document* is
/// `IssueSearchDocumentTests` there too. What is tested here is the pass over the rows the second
/// sweep wrote, the two staleness gates, the pruning, the merge, and the two degraded states that
/// have to keep working — the toggle off and a Mac with no embedding model.
@MainActor
final class IssueSearchTests: XCTestCase {
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

    /// A counting stand-in for the on-device model.
    ///
    /// Deliberately *unavailable* by default, because that is the state this suite mostly needs:
    /// with no vectors the blended score collapses to the normalised lexical score, which makes
    /// the merge order something a reader can predict rather than something a model decides.
    private actor CountingEmbedder: EmbeddingProviding {
        nonisolated let modelIdentifier: String
        private let isAvailable: Bool
        private(set) var embeddedTexts: [String] = []

        init(modelIdentifier: String = "fake-1", isAvailable: Bool = false) {
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
            // One dimension per word, so two texts sharing a word have a positive cosine. Enough
            // to be a real embedding for the gate this suite asserts.
            let tokens = SearchText.tokens(in: text)
            let values: [Float] = ["login", "theme", "grdb"].map { word in
                Float(tokens.filter { $0 == word }.count)
            }
            let vector = SearchVector(values)
            return vector.values.contains(where: { $0 > 0 }) ? vector.normalized : nil
        }
    }

    // MARK: - Fixtures

    private func pullRequest(
        id: String,
        number: Int,
        title: String
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: title,
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: clock,
            createdAt: clock,
            headRefName: "main",
            headRefOid: "head-\(number)",
            baseRefName: "main",
            myRelation: [.reviewRequested],
            labels: [],
            mergeable: .mergeable
        )
    }

    private func issue(
        id: String,
        number: Int,
        title: String,
        labels: [String] = []
    ) -> IssueRowSummary {
        IssueRowSummary(
            id: id,
            repo: repo,
            number: number,
            title: title,
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            createdAt: clock,
            updatedAt: clock,
            labels: labels,
            myRelation: [.assigned]
        )
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
        return SearchIndexCoordinator(settings: settings, embedder: embedder, now: { fixedNow })
    }

    /// Runs one issues pass and waits for it.
    private func indexIssues(
        _ coordinator: SearchIndexCoordinator,
        rows: [IssueRowSummary],
        database: DatabaseManager
    ) async {
        coordinator.considerIndexingIssues(rows: rows, database: database)
        if let task = coordinator.issuePassTask { await task.value }
    }

    private func indexPullRequests(
        _ coordinator: SearchIndexCoordinator,
        rows: [PullRequestSummary],
        database: DatabaseManager
    ) async {
        coordinator.considerIndexing(rows: rows, database: database)
        if let task = coordinator.passTask { await task.value }
    }

    // MARK: - The second pass

    func testAFirstIssuePassEmbedsEveryIssueOnceAndStoresIt() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = [
            issue(id: "I_1", number: 11, title: "Flaky login test", labels: ["bug"]),
            issue(id: "I_2", number: 12, title: "Bump GRDB"),
        ]
        try await database.saveIssueSummaries(rows)
        let embedder = CountingEmbedder(isAvailable: true)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: embedder)

        await indexIssues(coordinator, rows: rows, database: database)

        let calls = await embedder.callCount
        XCTAssertEqual(calls, 2, "one embedding per issue, and not one more")
        let entries = try await database.issueSearchIndexEntries()
        XCTAssertEqual(Set(entries.map(\.issueID)), ["I_1", "I_2"])
        XCTAssertEqual(entries.first?.modelIdentifier, "fake-1")
        XCTAssertEqual(entries.first?.indexedAt, clock)
        XCTAssertEqual(coordinator.status.issueDocumentCount, 2)
        XCTAssertEqual(coordinator.status.issueEmbeddedCount, 2)
    }

    func testASecondIssuePassOverUnchangedRowsSpendsNoEmbeddings() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = [issue(id: "I_1", number: 11, title: "Flaky login test")]
        try await database.saveIssueSummaries(rows)
        let embedder = CountingEmbedder(isAvailable: true)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: embedder)

        await indexIssues(coordinator, rows: rows, database: database)
        await indexIssues(coordinator, rows: rows, database: database)

        let calls = await embedder.callCount
        XCTAssertEqual(calls, 1, "the source fingerprint stopped the second pass at one column")
    }

    func testStoringABodyMakesTheNextPassGrowTheDocument() async throws {
        let database = try DatabaseManager.inMemory()
        let row = issue(id: "I_1", number: 11, title: "Flaky login test")
        try await database.saveIssueSummaries([row])
        let embedder = CountingEmbedder(isAvailable: true)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: embedder)

        await indexIssues(coordinator, rows: [row], database: database)
        // Opening the issue stores its body and moves `detailFetchedAt`, which is the whole
        // reason that column is in the fingerprint (ADR 0032).
        try await database.saveIssueDetail(
            IssueDetail(summary: row, bodyMarkdown: "The login screen loses the session.")
        )
        await indexIssues(coordinator, rows: [row], database: database)

        let texts = await embedder.embeddedTexts
        XCTAssertEqual(texts.count, 2, "a stored body is a new document and costs one embedding")
        XCTAssertTrue(texts[1].contains("loses the session"))
    }

    func testAnIssueThatLeavesTheSweepLeavesTheCorpus() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = [
            issue(id: "I_1", number: 11, title: "Flaky login test"),
            issue(id: "I_2", number: 12, title: "Bump GRDB"),
        ]
        try await database.saveIssueSummaries(rows)
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            embedder: CountingEmbedder(isAvailable: true)
        )
        await indexIssues(coordinator, rows: rows, database: database)
        XCTAssertEqual(coordinator.status.issueDocumentCount, 2)

        try await database.saveIssueSummaries([rows[0]])
        await indexIssues(coordinator, rows: [rows[0]], database: database)
        XCTAssertEqual(coordinator.status.issueDocumentCount, 1)
        let hits = await coordinator.issueResults(for: "GRDB")
        XCTAssertTrue(hits.isEmpty, "a pruned issue is not an answer any more")
    }

    func testWithTheToggleOffIssuesAreStillFoundByTitleAndNothingIsStored() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = [issue(id: "I_1", number: 11, title: "Flaky login test", labels: ["bug"])]
        try await database.saveIssueSummaries(rows)
        let embedder = CountingEmbedder(isAvailable: true)
        let coordinator = makeCoordinator(
            settings: makeSettings(semanticSearchEnabled: false),
            embedder: embedder
        )

        await indexIssues(coordinator, rows: rows, database: database)

        let calls = await embedder.callCount
        XCTAssertEqual(calls, 0, "no embedding is spent with the index switched off")
        let entries = try await database.issueSearchIndexEntries()
        XCTAssertTrue(entries.isEmpty)
        let hits = await coordinator.issueResults(for: "login")
        XCTAssertEqual(hits.map(\.summary.id), ["I_1"], "the lexical half always answers")
    }

    func testRebuildEmptiesBothIndexes() async throws {
        let database = try DatabaseManager.inMemory()
        let pullRequests = [pullRequest(id: "PR_1", number: 1, title: "Fix the login screen")]
        let issues = [issue(id: "I_1", number: 11, title: "Flaky login test")]
        try await database.savePullRequestSummaries(pullRequests)
        try await database.saveIssueSummaries(issues)
        let embedder = CountingEmbedder(isAvailable: true)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: embedder)
        await indexPullRequests(coordinator, rows: pullRequests, database: database)
        await indexIssues(coordinator, rows: issues, database: database)
        let before = try await database.issueSearchIndexEntries()
        XCTAssertEqual(before.count, 1)

        let embeddedBefore = await embedder.callCount
        XCTAssertEqual(embeddedBefore, 2)

        await coordinator.rebuild(database: database)
        if let task = coordinator.passTask { await task.value }
        if let task = coordinator.issuePassTask { await task.value }

        // Asserted through the embedder rather than through an empty table, because *Rebuild*
        // clears and then immediately rebuilds: the observable fact is that neither stored vector
        // could be reused, which is only true if both tables were emptied.
        let embeddedAfter = await embedder.callCount
        XCTAssertEqual(embeddedAfter, 4, "one button, both corpora thrown away and made again")
        let pullRequestEntries = try await database.searchIndexEntries()
        let issueEntries = try await database.issueSearchIndexEntries()
        XCTAssertEqual(pullRequestEntries.count, 1)
        XCTAssertEqual(issueEntries.count, 1)
    }

    // MARK: - The merge

    func testTheTwoRankedSetsAreMergedByScoreAndSlicedOnce() async throws {
        let database = try DatabaseManager.inMemory()
        let pullRequests = [pullRequest(id: "PR_1", number: 1, title: "Fix the login screen")]
        let issues = [issue(id: "I_1", number: 11, title: "Flaky login test")]
        try await database.savePullRequestSummaries(pullRequests)
        try await database.saveIssueSummaries(issues)
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            // Lexical only, so both corpora normalise their best row to 1.0 and the tie-break is
            // the only thing left to observe.
            embedder: CountingEmbedder(isAvailable: false)
        )
        await indexPullRequests(coordinator, rows: pullRequests, database: database)
        await indexIssues(coordinator, rows: issues, database: database)

        let both = await coordinator.paletteResults(for: "login", limit: 4)
        XCTAssertEqual(both.pullRequests.map(\.id), ["PR_1"])
        XCTAssertEqual(both.issues.map(\.id), ["I_1"])

        // The slice is the point: with room for one row, the merge decides — it does not give
        // each kind a quota.
        let one = await coordinator.paletteResults(for: "login", limit: 1)
        XCTAssertEqual(one.pullRequests.count + one.issues.count, 1)
        XCTAssertEqual(
            one.pullRequests.map(\.id),
            ["PR_1"],
            "equal scores break towards the pull request, which is what Shepherd is for"
        )
        XCTAssertTrue(one.issues.isEmpty)
    }

    func testAQueryThatMatchesNothingAnswersWithNothing() async throws {
        let database = try DatabaseManager.inMemory()
        let issues = [issue(id: "I_1", number: 11, title: "Flaky login test")]
        try await database.saveIssueSummaries(issues)
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            embedder: CountingEmbedder(isAvailable: false)
        )
        await indexIssues(coordinator, rows: issues, database: database)

        let empty = await coordinator.paletteResults(for: "", limit: 4)
        XCTAssertTrue(empty.isEmpty)
        let unrelated = await coordinator.paletteResults(for: "zzzzz", limit: 4)
        XCTAssertTrue(unrelated.isEmpty)
    }

    func testATriageOnlyQueryAnswersWithNoIssuesAtAll() async throws {
        let database = try DatabaseManager.inMemory()
        let issues = [issue(id: "I_1", number: 11, title: "Flaky login test")]
        try await database.saveIssueSummaries(issues)
        let embedder = CountingEmbedder(isAvailable: true)
        let coordinator = makeCoordinator(settings: makeSettings(), embedder: embedder)
        await indexIssues(coordinator, rows: issues, database: database)
        let embeddingsAfterIndexing = await embedder.callCount

        // ADR 0032's one deliberate divergence: a verdict is a statement about a pull request, so
        // there is no issue the filter could have narrowed and listing the whole inbox in answer
        // would be an opinion nobody asked for.
        let hits = await coordinator.issueResults(for: "risk:high")
        XCTAssertTrue(hits.isEmpty)
        let merged = await coordinator.paletteResults(for: "kind:dependency", limit: 4)
        XCTAssertTrue(merged.issues.isEmpty)
        let after = await embedder.callCount
        XCTAssertEqual(
            after,
            embeddingsAfterIndexing,
            "a query with no words left spends no embedding either"
        )
    }

    func testAnExactReferenceWinsOnTheIssueSideToo() async throws {
        let database = try DatabaseManager.inMemory()
        let issues = [
            issue(id: "I_1", number: 11, title: "Flaky login test"),
            issue(id: "I_2", number: 128, title: "Something else entirely"),
        ]
        try await database.saveIssueSummaries(issues)
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            embedder: CountingEmbedder(isAvailable: false)
        )
        await indexIssues(coordinator, rows: issues, database: database)

        let hits = await coordinator.issueResults(for: "schnaq/review#128")
        XCTAssertEqual(hits.first?.summary.id, "I_2")
        XCTAssertEqual(hits.first?.reason, .exactReference)
    }

    func testTheReasonLineNeverRepeatsWhatTheRowAlreadyShows() {
        XCTAssertNil(IssueSearchResultPresentation.reasonLine(for: nil))
        XCTAssertNil(IssueSearchResultPresentation.reasonLine(for: .exactReference))
        // Compared on the substance rather than on the whole sentence: the wording goes through
        // the same catalog key the pull-request presenter uses, so a German test bundle must not
        // make this fail.
        XCTAssertEqual(
            IssueSearchResultPresentation.reasonLine(for: .label("bug"))?.contains("bug"),
            true
        )
        XCTAssertNotNil(IssueSearchResultPresentation.reasonLine(for: .body))
        XCTAssertNotNil(IssueSearchResultPresentation.reasonLine(for: .semantic))
    }

    // MARK: - Statistics

    func testTheSettingsLineAddsBothIndexesUp() async throws {
        let database = try DatabaseManager.inMemory()
        let pullRequests = [pullRequest(id: "PR_1", number: 1, title: "Fix the login screen")]
        let issues = [issue(id: "I_1", number: 11, title: "Flaky login test")]
        try await database.savePullRequestSummaries(pullRequests)
        try await database.saveIssueSummaries(issues)
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            embedder: CountingEmbedder(isAvailable: true)
        )
        await indexPullRequests(coordinator, rows: pullRequests, database: database)
        await indexIssues(coordinator, rows: issues, database: database)

        let pullRequestBytes = try await database.searchIndexStatistics().vectorByteCount
        let issueBytes = try await database.issueSearchIndexStatistics().vectorByteCount
        XCTAssertGreaterThan(issueBytes, 0)
        XCTAssertEqual(coordinator.status.vectorByteCount, pullRequestBytes + issueBytes)
        XCTAssertEqual(coordinator.status.documentCount, 1)
        XCTAssertEqual(coordinator.status.issueDocumentCount, 1)
        XCTAssertEqual(coordinator.status.issueEmbeddedCount, 1)
    }
}
