import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// The app half of structured triage (ADR 0023): when a verdict is spent, what invalidates one,
/// what the three disabled paths do, and what the inbox renders in each of them.
///
/// The *decisions* are covered by `StructuredTriageTests` in ShepherdKit, which runs on the Linux
/// runner. What is tested here is everything a pure function cannot see: the pass over the rows a
/// sweep wrote, the two staleness gates, the pruning, the queue that merges mid-pass rows, and the
/// degraded states that have to keep working — the switch off, the tiers off, and a Mac whose
/// tagging model is not there.
///
/// Every generation goes through the injected ``TriageClassifying`` seam, so nothing here depends
/// on Apple's model being present or on its answers being stable.
@MainActor
final class StructuredTriageTests: XCTestCase {
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

    /// A deterministic stand-in for the on-device tagging model.
    ///
    /// It answers from the title — the one input a test can predict — and records what it was
    /// asked, in order, which is how "one row at a time" and "one verdict per changed document"
    /// are asserted. A failing variant is what the retry rule is asserted through.
    private actor FakeClassifier: TriageClassifying {
        nonisolated let modelIdentifier: String
        private let availabilityReason: String?
        private let failsFor: Set<String>
        private(set) var classifiedIDs: [String] = []
        private(set) var titles: [String] = []
        private(set) var prompts: [String] = []

        init(
            modelIdentifier: String = "fake-tagger-1",
            availabilityReason: String? = nil,
            failsFor: Set<String> = []
        ) {
            self.modelIdentifier = modelIdentifier
            self.availabilityReason = availabilityReason
            self.failsFor = failsFor
        }

        var callCount: Int { classifiedIDs.count }

        func availability() async -> TriageClassifierAvailability {
            guard let availabilityReason else { return .available }
            return .unavailable(availabilityReason)
        }

        func classify(_ input: TriageInput) async throws -> TriageVerdict {
            classifiedIDs.append(input.prID)
            titles.append(input.title)
            prompts.append(input.promptText)
            if failsFor.contains(input.prID) { throw IntelligenceError.guardrailDeclined }
            let lowercased = input.title.lowercased()
            if lowercased.contains("bump") {
                return TriageVerdict(
                    kind: .dependencyBump,
                    risk: .low,
                    reason: "Only a lockfile moved."
                )
            }
            if lowercased.contains("auth") {
                return TriageVerdict(kind: .fix, risk: .high, reason: "Touches the auth path.")
            }
            return TriageVerdict(kind: .feature, risk: .medium, reason: "New behaviour.")
        }
    }

    // MARK: - Fixtures

    private func summary(
        id: String,
        number: Int,
        title: String,
        labels: [String] = [],
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
            headRefName: "feature",
            headRefOid: "head-\(number)",
            baseRefName: "main",
            myRelation: [.reviewRequested],
            labels: labels,
            mergeable: .mergeable
        )
    }

    private var rows: [PullRequestSummary] {
        [
            summary(id: "PR_1", number: 1, title: "Fix the auth middleware", labels: ["bug"]),
            summary(id: "PR_2", number: 2, title: "Bump GRDB", labels: ["automerge"]),
            summary(id: "PR_3", number: 3, title: "A dark theme for the sidebar"),
        ]
    }

    private func makeSettings(
        structuredTriageEnabled: Bool = true,
        mode: IntelligenceMode = .onDevice
    ) -> AppSettings {
        let settings = AppSettings(defaults: defaults)
        settings.structuredTriageEnabled = structuredTriageEnabled
        settings.intelligenceMode = mode
        return settings
    }

    private func makeCoordinator(
        settings: AppSettings,
        classifier: any TriageClassifying
    ) -> TriageCoordinator {
        let fixedNow = clock
        return TriageCoordinator(
            settings: settings,
            classifier: classifier,
            now: { fixedNow }
        )
    }

    /// Runs one pass and waits for it, which is what ``TriageCoordinator/passTask`` is for.
    private func classify(
        _ coordinator: TriageCoordinator,
        rows: [PullRequestSummary],
        database: DatabaseManager
    ) async {
        coordinator.considerClassifying(rows: rows, database: database)
        await waitForPass(coordinator)
    }

    private func waitForPass(_ coordinator: TriageCoordinator) async {
        guard let task = coordinator.passTask else { return }
        await task.value
    }

    /// A detail with one changed file, so the tier-1 hints have something to say.
    private func detail(
        for row: PullRequestSummary,
        path: String,
        status: FileChangeStatus = .modified
    ) -> PullRequestDetail {
        PullRequestDetail(
            summary: row,
            bodyMarkdown: "What this changes.",
            files: [
                ChangedFile(
                    path: path,
                    previousPath: nil,
                    status: status,
                    additions: 12,
                    deletions: 3,
                    patch: "@@ -1 +1 @@\n+let token = refresh()",
                    isViewed: false
                ),
            ]
        )
    }

    // MARK: - Passes

    func testAFirstPassClassifiesEveryRowOnceAndStoresIt() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let classifier = FakeClassifier()
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: classifier)

        await classify(coordinator, rows: rows, database: database)

        let calls = await classifier.callCount
        XCTAssertEqual(calls, 3, "one verdict per pull request, and not one more")
        let stored = try await database.triageVerdicts()
        XCTAssertEqual(Set(stored.map(\.prID)), ["PR_1", "PR_2", "PR_3"])
        XCTAssertEqual(stored.first?.modelIdentifier, "fake-tagger-1")
        XCTAssertEqual(stored.first?.classifiedAt, clock)
        XCTAssertEqual(coordinator.verdict(for: "PR_2")?.kind, .dependencyBump)
        XCTAssertEqual(coordinator.verdict(for: "PR_1")?.risk, .high)
        XCTAssertEqual(coordinator.status.classifiedCount, 3)
        XCTAssertEqual(coordinator.status.rowCount, 3)
        XCTAssertNil(coordinator.status.unavailabilityReason)
        XCTAssertFalse(coordinator.status.isClassifying)
    }

    func testTheRowsAreClassifiedOneAtATimeInTheOrderTheyWereRead() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let classifier = FakeClassifier()
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: classifier)

        await classify(coordinator, rows: rows, database: database)

        let ids = await classifier.classifiedIDs
        XCTAssertEqual(
            ids.count,
            Set(ids).count,
            "sequential means each pull request is asked about exactly once"
        )
        XCTAssertEqual(Set(ids), ["PR_1", "PR_2", "PR_3"])
    }

    func testASecondPassOverUnchangedRowsClassifiesNothing() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let classifier = FakeClassifier()
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: classifier)

        await classify(coordinator, rows: rows, database: database)
        await classify(coordinator, rows: rows, database: database)

        let calls = await classifier.callCount
        XCTAssertEqual(calls, 3, "the fingerprint gate stops the second pass before it reads")
    }

    func testANewTitleCostsExactlyOneVerdictAndReplacesTheOldOne() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let classifier = FakeClassifier()
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: classifier)
        await classify(coordinator, rows: rows, database: database)
        XCTAssertEqual(coordinator.verdict(for: "PR_2")?.kind, .dependencyBump)

        var edited = rows
        // No "bump" in the new title: the fake answers on the first word it recognises.
        edited[1].title = "Fix the auth middleware regression"
        try await database.savePullRequestSummaries(edited)
        await classify(coordinator, rows: edited, database: database)

        let calls = await classifier.callCount
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(
            coordinator.verdict(for: "PR_2")?.risk,
            .high,
            "the document changed, so the verdict is the new text's"
        )
    }

    func testARowThatChangedWithoutChangingItsTextKeepsItsVerdict() async throws {
        // The common case by far: a sweep re-reads a pull request whose `updatedAt` moved because
        // somebody commented. The fingerprint moves, the *document* does not, and the stored
        // verdict is reused rather than recomputed.
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let classifier = FakeClassifier()
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: classifier)
        await classify(coordinator, rows: rows, database: database)

        var touched = rows
        touched[0].updatedAt = clock.addingTimeInterval(600)
        try await database.savePullRequestSummaries(touched)
        await classify(coordinator, rows: touched, database: database)

        let calls = await classifier.callCount
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(coordinator.verdict(for: "PR_1")?.kind, .fix)
    }

    func testAStoredVerdictFromAnotherModelIsNotShown() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let first = FakeClassifier(modelIdentifier: "fake-tagger-1")
        await classify(
            makeCoordinator(settings: makeSettings(), classifier: first),
            rows: rows,
            database: database
        )

        // A new session on a Mac whose model identifier moved — an OS update, or a prompt change
        // Shepherd itself made. Every verdict has to be made again.
        let second = FakeClassifier(modelIdentifier: "fake-tagger-2")
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: second)
        await classify(coordinator, rows: rows, database: database)

        let calls = await second.callCount
        XCTAssertEqual(calls, 3)
        let stored = try await database.triageVerdicts()
        XCTAssertEqual(Set(stored.map(\.modelIdentifier)), ["fake-tagger-2"])
    }

    func testAFailedClassificationIsRetriedOnTheNextPass() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let classifier = FakeClassifier(failsFor: ["PR_3"])
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: classifier)

        await classify(coordinator, rows: rows, database: database)
        XCTAssertNil(coordinator.verdict(for: "PR_3"))
        XCTAssertEqual(coordinator.status.classifiedCount, 2)

        await classify(coordinator, rows: rows, database: database)
        let calls = await classifier.callCount
        XCTAssertEqual(calls, 4, "the two that worked are settled; the one that failed is asked again")
    }

    func testAPullRequestThatLeftTheInboxLeavesTheCoordinatorAndTheTable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: FakeClassifier())
        await classify(coordinator, rows: rows, database: database)

        let remaining = Array(rows.prefix(2))
        try await database.savePullRequestSummaries(remaining)
        await classify(coordinator, rows: remaining, database: database)

        XCTAssertNil(coordinator.verdict(for: "PR_3"))
        XCTAssertNil(coordinator.row(for: "PR_3"))
        let stored = try await database.triageVerdicts()
        XCTAssertEqual(Set(stored.map(\.prID)), ["PR_1", "PR_2"], "the foreign key pruned it")
    }

    func testADetailAnnouncementDuringAPassDoesNotDiscardAWaitingSnapshot() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let classifier = FakeClassifier()
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: classifier)

        // Three calls in one main-actor turn, so nothing can run in between: a pass over two
        // rows starts and cannot progress until this test yields, the sweep's full snapshot —
        // which has a third pull request in it — queues behind it, and then the review screen
        // announces a stored diff for a *different* pull request. With a single "last write
        // wins" slot that last call replaced the snapshot and the third pull request waited for
        // the next sweep. The queue merges by pull request instead.
        coordinator.considerClassifying(rows: Array(rows.prefix(2)), database: database)
        coordinator.considerClassifying(rows: rows, database: database)
        coordinator.classifyAfterDetailLoad(prID: "PR_1", database: database)
        await waitForPass(coordinator)

        XCTAssertEqual(
            coordinator.verdict(for: "PR_3")?.kind,
            .feature,
            "the queued snapshot was classified, not dropped"
        )
        XCTAssertEqual(coordinator.status.classifiedCount, 3)
    }

    // MARK: - The tier-1 half

    func testTheHeuristicRiskAndHintsComeFromTheStoredDiff() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        try await database.savePullRequestDetail(
            detail(for: rows[0], path: "Sources/Auth/TokenStore.swift")
        )
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: FakeClassifier())

        await classify(coordinator, rows: rows, database: database)

        let row = try XCTUnwrap(coordinator.row(for: "PR_1"))
        XCTAssertEqual(row.heuristicRisk, .high, "an auth path is review-first without a model")
        XCTAssertTrue(row.riskHints.contains { $0.contains("Sources/Auth/TokenStore.swift") })
        XCTAssertTrue(row.isClassified, "and the verdict is there too")

        let unopened = try XCTUnwrap(coordinator.row(for: "PR_2"))
        XCTAssertNil(
            unopened.heuristicRisk,
            "nobody has opened it, so there is no diff to judge"
        )
        XCTAssertTrue(unopened.riskHints.isEmpty)
    }

    func testTheHintsReachThePrompt() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        try await database.savePullRequestDetail(
            detail(for: rows[0], path: "Tests/LoginTests.swift", status: .removed)
        )
        let classifier = FakeClassifier()
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: classifier)

        await classify(coordinator, rows: rows, database: database)

        let prompts = await classifier.prompts
        let authPrompt = try XCTUnwrap(prompts.first { $0.contains("Fix the auth middleware") })
        XCTAssertTrue(
            authPrompt.contains("Deletes a test file"),
            "the tier-1 analysis is handed to the model as a fact rather than left to be inferred"
        )
    }

    // MARK: - The three disabled paths

    func testWithTheSwitchOffNothingIsClassifiedAndTheTableIsEmptied() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let classifier = FakeClassifier()
        let settings = makeSettings()
        let coordinator = makeCoordinator(settings: settings, classifier: classifier)
        await classify(coordinator, rows: rows, database: database)

        settings.structuredTriageEnabled = false
        await coordinator.disable(database: database)

        XCTAssertFalse(coordinator.status.isEnabled)
        XCTAssertEqual(coordinator.status.classifiedCount, 0)
        XCTAssertNil(coordinator.row(for: "PR_1"))
        let stored = try await database.triageVerdicts()
        XCTAssertTrue(stored.isEmpty, "a switch that left its rows on disk would be lying")

        // And a sweep that lands while it is off costs nothing.
        await classify(coordinator, rows: rows, database: database)
        let calls = await classifier.callCount
        XCTAssertEqual(calls, 3, "the three from before the switch went off, and none since")
    }

    func testWithTheTiersOffTheFacetFallsBackToTheHeuristics() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        try await database.savePullRequestDetail(
            detail(for: rows[0], path: "Sources/Auth/TokenStore.swift")
        )
        let classifier = FakeClassifier()
        let coordinator = makeCoordinator(
            settings: makeSettings(mode: .off),
            classifier: classifier
        )

        await classify(coordinator, rows: rows, database: database)

        let calls = await classifier.callCount
        XCTAssertEqual(calls, 0, "there is no model to ask")
        XCTAssertNotNil(coordinator.status.unavailabilityReason)
        XCTAssertEqual(coordinator.risk(for: "PR_1"), .high, "tier 1 still answers")
        XCTAssertFalse(try XCTUnwrap(coordinator.row(for: "PR_1")).isClassified)
        XCTAssertEqual(
            coordinator.riskFacets(for: rows.map(\.id)),
            [TriageRiskFacet(risk: .high, count: 1, classifiedCount: 0)],
            "the rail keeps a RISK section, and it says none of it is the model's"
        )
        XCTAssertTrue(coordinator.verdicts.isEmpty, "and ⌘K's tokens have nothing to filter on")
    }

    func testWithNoTaggingModelTheReasonIsTheModelsOwnWords() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let classifier = FakeClassifier(availabilityReason: "no tagging model in this test")
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: classifier)

        await classify(coordinator, rows: rows, database: database)

        let calls = await classifier.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(coordinator.status.unavailabilityReason, "no tagging model in this test")
        let stored = try await database.triageVerdicts()
        XCTAssertTrue(stored.isEmpty)
    }

    func testResetForgetsEverything() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: FakeClassifier())
        await classify(coordinator, rows: rows, database: database)

        coordinator.reset()

        XCTAssertNil(coordinator.verdict(for: "PR_1"))
        XCTAssertTrue(coordinator.verdicts.isEmpty)
        XCTAssertEqual(coordinator.status.classifiedCount, 0)
        XCTAssertTrue(coordinator.riskFacets(for: rows.map(\.id)).isEmpty)
    }

    // MARK: - What the inbox renders

    func testTheFacetCountsWhatTheModelSaidAndWhatTheHeuristicsDid() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let coordinator = makeCoordinator(settings: makeSettings(), classifier: FakeClassifier())
        await classify(coordinator, rows: rows, database: database)

        XCTAssertEqual(
            coordinator.riskFacets(for: rows.map(\.id)),
            [
                TriageRiskFacet(risk: .high, count: 1, classifiedCount: 1),
                TriageRiskFacet(risk: .medium, count: 1, classifiedCount: 1),
                TriageRiskFacet(risk: .low, count: 1, classifiedCount: 1),
            ]
        )
    }

    func testTheChipSaysKindAndRiskWithAVerdictAndRiskAloneWithout() {
        let classified = TriageRowSummary(
            verdict: TriageVerdict(kind: .fix, risk: .high, reason: "Touches auth."),
            heuristicRisk: .medium,
            riskHints: ["Sources/Auth/TokenStore.swift — Touches security-sensitive path"]
        )
        XCTAssertEqual(classified.risk, .high, "the verdict wins over the heuristic")
        XCTAssertTrue(classified.isClassified)
        XCTAssertEqual(classified.rowRisk, TriageRowRisk(risk: .high, isClassified: true))

        let heuristic = TriageRowSummary(heuristicRisk: .medium, riskHints: ["one hint"])
        XCTAssertEqual(heuristic.risk, .medium)
        XCTAssertFalse(heuristic.isClassified)
        XCTAssertEqual(heuristic.rowRisk, TriageRowRisk(risk: .medium, isClassified: false))

        let nothing = TriageRowSummary()
        XCTAssertTrue(nothing.isEmpty)
        XCTAssertNil(nothing.rowRisk, "a row with nothing to say shows no chip at all")
    }

    // MARK: - ⌘K

    func testThePaletteFiltersOnTheVerdictsItIsHandedRatherThanOnWords() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestSummaries(rows)
        let triage = makeCoordinator(settings: makeSettings(), classifier: FakeClassifier())
        await classify(triage, rows: rows, database: database)

        let settings = AppSettings(defaults: defaults)
        settings.semanticSearchEnabled = false
        let search = SearchIndexCoordinator(settings: settings)
        search.considerIndexing(rows: rows, database: database)

        let dependencies = await search.results(
            for: "kind:dependency",
            verdicts: triage.verdicts
        )
        XCTAssertEqual(dependencies.map(\.id), ["PR_2"])

        let high = await search.results(for: "risk:high", verdicts: triage.verdicts)
        XCTAssertEqual(high.map(\.id), ["PR_1"])

        let combined = await search.results(
            for: "risk:high auth",
            verdicts: triage.verdicts
        )
        XCTAssertEqual(combined.map(\.id), ["PR_1"], "the words rank inside the filtered set")

        let contradiction = await search.results(
            for: "risk:high theme",
            verdicts: triage.verdicts
        )
        XCTAssertTrue(
            contradiction.isEmpty,
            "the dark-theme pull request is medium risk, so the filter excludes it"
        )

        let withoutVerdicts = await search.results(for: "risk:high")
        XCTAssertTrue(
            withoutVerdicts.isEmpty,
            "a Mac that classified nothing answers a verdict question with nothing"
        )
    }
}
