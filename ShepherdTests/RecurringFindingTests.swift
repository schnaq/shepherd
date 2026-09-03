import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// The app half of the feedback loop: what the pass reads, what it costs, what a dismissal does,
/// and what the delegation sheet is handed (ADR 0029).
///
/// The *clustering* is covered exhaustively by `RecurringFindingDetectorTests` in ShepherdKit,
/// which runs on the Linux runner. What is tested here is what a pure function cannot see: that
/// only the reviewer's own comments are ever read, that a comment outside the window is not even
/// embedded, that a dismissal survives into Settings, and that the task the sheet opens with says
/// "add a rule" rather than "fix this pull request".
///
/// Every embedding goes through the injected ``EmbeddingProviding`` seam, the same one ⌘K search
/// and the saved-reply suggester are tested through, so nothing here depends on Apple's model
/// being present or on its output being stable.
@MainActor
final class RecurringFindingTests: XCTestCase {
    // MARK: - Doubles

    /// An embedder that answers from a table a test wrote, and remembers every question.
    ///
    /// The same lookup-table double `SavedReplySuggestionTests` uses, and for the same reason: a
    /// vector this file can point at is what makes "these three cluster and that one does not" a
    /// readable test rather than a coincidence. A text that is not in the table gets `nil`, which
    /// is what the real model does for input it cannot embed.
    private actor FakeEmbedder: EmbeddingProviding {
        nonisolated let modelIdentifier = "fake-recurring-1"

        private let isAvailable: Bool
        private let table: [String: SearchVector]
        private(set) var embeddedTexts: [String] = []

        init(table: [String: SearchVector], isAvailable: Bool = true) {
            self.table = table
            self.isAvailable = isAvailable
        }

        var callCount: Int { embeddedTexts.count }

        func availability() async -> EmbeddingAvailability {
            isAvailable ? .available : .unavailable("no model in this test")
        }

        func vector(for text: String) async -> SearchVector? {
            embeddedTexts.append(text)
            guard isAvailable else { return nil }
            return table[text]
        }
    }

    // MARK: - Fixtures

    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let viewer = "christian"
    private let now = Date(timeIntervalSince1970: 1_788_162_000)
    private let day: TimeInterval = 24 * 60 * 60

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "shepherd.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removeSuite(named: suiteName)
    }

    /// The three "add a test" comments, and the bodies' vectors.
    private let firstBody = "Please add a test for the error path here."
    private let secondBody = "Needs a test for the failure branch."
    private let thirdBody = "Add a test covering the error path, please."
    /// A comment about something else entirely — it must never join the cluster.
    private let nitBody = "Nit: this name reads better as `retryCount`."
    /// A comment a colleague wrote. It must never be *read*, let alone clustered.
    private let colleagueBody = "Could you rename this type before we merge?"

    private var table: [String: SearchVector] {
        [
            firstBody: SearchVector([1, 0, 0]),
            secondBody: SearchVector([4, 1, 0]),
            thirdBody: SearchVector([2, 1, 0]),
            nitBody: SearchVector([1, 3, 0]),
            colleagueBody: SearchVector([1, 0, 0]),
        ]
    }

    private func summary(number: Int) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_\(number)",
            repo: repo,
            number: number,
            title: "Change number \(number)",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: now,
            createdAt: now.addingTimeInterval(-40 * day),
            additions: 12,
            deletions: 3,
            changedFiles: 1,
            headRefName: "agent/fix-\(number)",
            headRefOid: "0123456789abcdef012\(number)",
            baseRefName: "main",
            myRelation: [.reviewRequested]
        )
    }

    /// One thread per comment, which is how a review finding actually arrives.
    private func detail(
        number: Int,
        comments: [(id: String, body: String, author: String, daysAgo: Double)]
    ) -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(number: number),
            bodyMarkdown: "What this changes.",
            threads: comments.enumerated().map { pair in
                ReviewThread(
                    id: "T_\(number)_\(pair.offset)",
                    path: "Sources/App.swift",
                    line: 42,
                    comments: [
                        ReviewComment(
                            id: pair.element.id,
                            author: ShepherdCore.Actor(
                                login: pair.element.author,
                                kind: .human
                            ),
                            bodyMarkdown: pair.element.body,
                            createdAt: now.addingTimeInterval(-pair.element.daysAgo * day)
                        ),
                    ]
                )
            }
        )
    }

    private func makeCoordinator(embedder: FakeEmbedder) -> RecurringFindingCoordinator {
        // The clock is copied into a local first, so the injected closure captures a `Date` and
        // not this test case.
        let clock = now
        return RecurringFindingCoordinator(
            embedder: embedder,
            defaults: defaults,
            dismissalKey: "tests.recurringFindings",
            now: { clock }
        )
    }

    /// Stores three pull requests: two of them carry the cluster, one carries a nit.
    private func seed(_ database: DatabaseManager) async throws -> [PullRequestSummary] {
        let rows = [summary(number: 11), summary(number: 12), summary(number: 13)]
        try await database.savePullRequestSummaries(rows)
        try await database.savePullRequestDetail(
            detail(
                number: 11,
                comments: [(id: "C_1", body: firstBody, author: viewer, daysAgo: 20)]
            )
        )
        try await database.savePullRequestDetail(
            detail(
                number: 12,
                comments: [
                    (id: "C_2", body: secondBody, author: viewer, daysAgo: 10),
                    (id: "C_3", body: thirdBody, author: viewer, daysAgo: 2),
                ]
            )
        )
        try await database.savePullRequestDetail(
            detail(
                number: 13,
                comments: [
                    (id: "C_4", body: nitBody, author: viewer, daysAgo: 1),
                    (id: "C_5", body: colleagueBody, author: "colleague", daysAgo: 1),
                ]
            )
        )
        return rows
    }

    private func scan(
        _ coordinator: RecurringFindingCoordinator,
        rows: [PullRequestSummary],
        database: DatabaseManager
    ) async {
        coordinator.considerScanning(rows: rows, database: database, viewerLogin: viewer)
        if let task = coordinator.passTask { await task.value }
    }

    // MARK: - The pass

    func testTheThirdTimeTheReviewerSaysItACardAppears() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = try await seed(database)
        let embedder = FakeEmbedder(table: table)
        let coordinator = makeCoordinator(embedder: embedder)

        await scan(coordinator, rows: rows, database: database)

        let findings = coordinator.findings(for: repo)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.count, 3)
        XCTAssertEqual(findings.first?.comments.map(\.id), ["C_1", "C_2", "C_3"])
        // The numbers the card puts beside the quotes.
        XCTAssertEqual(findings.first?.comments.map(\.number), [11, 12, 12])
        XCTAssertEqual(findings.first?.exemplar, secondBody)
    }

    func testTheNitIsNeitherClusteredNorACardOfItsOwn() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = try await seed(database)
        let coordinator = makeCoordinator(embedder: FakeEmbedder(table: table))

        await scan(coordinator, rows: rows, database: database)

        XCTAssertEqual(coordinator.findings(for: repo).count, 1)
        XCTAssertFalse(
            coordinator.findings(for: repo).contains { $0.comments.contains { $0.id == "C_4" } }
        )
    }

    func testAColleaguesCommentIsNeverEvenRead() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = try await seed(database)
        let embedder = FakeEmbedder(table: table)
        let coordinator = makeCoordinator(embedder: embedder)

        await scan(coordinator, rows: rows, database: database)

        // Its vector points along the cluster's own axis, so if it had been read it *would* have
        // joined — which is what makes this an assertion about the query rather than about luck.
        let asked = await embedder.embeddedTexts
        XCTAssertFalse(asked.contains(colleagueBody))
        XCTAssertEqual(coordinator.findings(for: repo).first?.count, 3)
    }

    func testACommentOutsideTheWindowIsNotEvenEmbedded() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = [summary(number: 11), summary(number: 12)]
        try await database.savePullRequestSummaries(rows)
        try await database.savePullRequestDetail(
            detail(
                number: 11,
                comments: [(id: "C_1", body: firstBody, author: viewer, daysAgo: 40)]
            )
        )
        try await database.savePullRequestDetail(
            detail(
                number: 12,
                comments: [
                    (id: "C_2", body: secondBody, author: viewer, daysAgo: 10),
                    (id: "C_3", body: thirdBody, author: viewer, daysAgo: 2),
                ]
            )
        )
        let embedder = FakeEmbedder(table: table)
        let coordinator = makeCoordinator(embedder: embedder)

        await scan(coordinator, rows: rows, database: database)

        // The window is a floor in the SQL, so the old comment costs nothing at all — not one
        // embedding, and not a place in the *n*² clustering.
        let asked = await embedder.embeddedTexts
        XCTAssertFalse(asked.contains(firstBody))
        // And two comments are not three, so there is no card.
        XCTAssertTrue(coordinator.findings(for: repo).isEmpty)
    }

    func testASecondSweepReusesEveryCommentVector() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = try await seed(database)
        let embedder = FakeEmbedder(table: table)
        let coordinator = makeCoordinator(embedder: embedder)

        await scan(coordinator, rows: rows, database: database)
        let afterFirst = await embedder.callCount
        // A fourth comment, so the fingerprint changes and the pass actually runs again.
        try await database.savePullRequestDetail(
            detail(
                number: 12,
                comments: [
                    (id: "C_2", body: secondBody, author: viewer, daysAgo: 10),
                    (id: "C_3", body: thirdBody, author: viewer, daysAgo: 2),
                    (id: "C_6", body: secondBody, author: viewer, daysAgo: 1),
                ]
            )
        )
        await scan(coordinator, rows: rows, database: database)

        // The fourth comment repeats a body the cache already holds, so the second pass spends
        // nothing: the cache is keyed by the *body*, which is the whole point of the choice.
        let afterSecond = await embedder.callCount
        XCTAssertEqual(afterSecond, afterFirst)
        XCTAssertEqual(coordinator.findings(for: repo).first?.count, 4)
    }

    func testAnUnchangedSweepCostsNothing() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = try await seed(database)
        let embedder = FakeEmbedder(table: table)
        let coordinator = makeCoordinator(embedder: embedder)

        await scan(coordinator, rows: rows, database: database)
        let afterFirst = await embedder.callCount
        await scan(coordinator, rows: rows, database: database)

        let afterSecond = await embedder.callCount
        XCTAssertEqual(afterSecond, afterFirst)
        XCTAssertEqual(coordinator.findings(for: repo).count, 1)
    }

    func testWithNoModelOnThisMacThereIsNoCardAndNoComplaint() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = try await seed(database)
        let coordinator = makeCoordinator(
            embedder: FakeEmbedder(table: table, isAvailable: false)
        )

        await scan(coordinator, rows: rows, database: database)

        // The degraded state is the ordinary state: no card, and nothing anywhere saying why. A
        // suggestion nobody asked for is not news when it cannot be made.
        XCTAssertTrue(coordinator.findings(for: repo).isEmpty)
        XCTAssertTrue(coordinator.everyFinding.isEmpty)
        XCTAssertEqual(coordinator.cachedBodyCount, 0)
    }

    func testAnEmptyInboxLeavesNoFindingsBehind() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = try await seed(database)
        let coordinator = makeCoordinator(embedder: FakeEmbedder(table: table))

        await scan(coordinator, rows: rows, database: database)
        XCTAssertEqual(coordinator.findings(for: repo).count, 1)

        coordinator.considerScanning(rows: [], database: database, viewerLogin: viewer)
        XCTAssertTrue(coordinator.findings(for: repo).isEmpty)
    }

    // MARK: - Dismissal

    func testADismissedFindingLeavesTheReviewScreenAndStaysInSettings() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = try await seed(database)
        let coordinator = makeCoordinator(embedder: FakeEmbedder(table: table))
        await scan(coordinator, rows: rows, database: database)
        let finding = try XCTUnwrap(coordinator.findings(for: repo).first)

        coordinator.dismiss(finding)

        XCTAssertTrue(coordinator.findings(for: repo).isEmpty)
        XCTAssertNil(coordinator.topFinding(for: repo))
        // Still listed where it can be brought back — a dismissal nobody can undo would make the
        // button one nobody dares press.
        XCTAssertEqual(coordinator.everyFinding.map(\.id), [finding.id])
        XCTAssertTrue(coordinator.isDismissed(finding))

        coordinator.showAgain(finding)
        XCTAssertEqual(coordinator.findings(for: repo).map(\.id), [finding.id])
    }

    func testADismissalSurvivesARelaunchAndStaysOnThisMac() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = try await seed(database)
        let coordinator = makeCoordinator(embedder: FakeEmbedder(table: table))
        await scan(coordinator, rows: rows, database: database)
        let finding = try XCTUnwrap(coordinator.findings(for: repo).first)
        coordinator.dismiss(finding)

        // A second coordinator over the same defaults is what a relaunch looks like.
        let relaunched = makeCoordinator(embedder: FakeEmbedder(table: table))
        await scan(relaunched, rows: rows, database: database)
        XCTAssertTrue(relaunched.findings(for: repo).isEmpty)
        XCTAssertTrue(relaunched.isDismissed(finding))
    }

    func testSigningOutForgetsTheFindingsAndTheDismissals() async throws {
        let database = try DatabaseManager.inMemory()
        let rows = try await seed(database)
        let coordinator = makeCoordinator(embedder: FakeEmbedder(table: table))
        await scan(coordinator, rows: rows, database: database)
        let finding = try XCTUnwrap(coordinator.findings(for: repo).first)
        coordinator.dismiss(finding)

        coordinator.reset()

        XCTAssertTrue(coordinator.everyFinding.isEmpty)
        XCTAssertFalse(coordinator.isDismissed(finding))
        XCTAssertEqual(coordinator.cachedBodyCount, 0)
    }

    // MARK: - What the delegation sheet is handed

    private func finding(count: Int = 3) -> RecurringFinding {
        let bodies = [firstBody, secondBody, thirdBody]
        return RecurringFinding(
            repo: repo,
            exemplar: secondBody,
            comments: (0..<count).map { index in
                RecurringFindingComment(
                    id: "C_\(index)",
                    body: bodies[index % bodies.count],
                    prID: "PR_\(11 + index)",
                    number: 11 + index,
                    createdAt: now.addingTimeInterval(Double(index) * day)
                )
            }
        )
    }

    func testTheContextIsTheWholePullRequestAndCarriesTheThreeQuotes() {
        let context = RecurringFindingRule.context(
            finding: finding(),
            pullRequest: summary(number: 42),
            viewerLogin: viewer
        )
        // Not a review finding: a rule is not anchored to a file or a line, and claiming it was
        // would make both the prefilled task and the drafted brief talk about a place in the diff.
        XCTAssertEqual(context.origin, .pullRequest)
        XCTAssertEqual(context.prID, "PR_42")
        XCTAssertEqual(context.number, 42)
        XCTAssertEqual(context.repo, repo)
        XCTAssertEqual(context.findingComments, [firstBody, secondBody, thirdBody])
        // The reviewer's own login, stated rather than omitted, so the cloud rung is allowed by a
        // decision over the data rather than by a missing author.
        XCTAssertEqual(context.findingCommentAuthors, [viewer, viewer, viewer])
        XCTAssertFalse(
            AgentBriefRequest.requiresOnDevice(context: context, viewerLogin: viewer)
        )
    }

    func testOnlyThreeCommentsAreQuotedHoweverLongTheClusterGets() {
        let context = RecurringFindingRule.context(
            finding: finding(count: 7),
            pullRequest: summary(number: 42),
            viewerLogin: viewer
        )
        XCTAssertEqual(context.findingComments.count, 3)
        XCTAssertEqual(RecurringFindingRule.quotes(of: finding(count: 7)).count, 3)
    }

    func testTheTemplateAsksForOneRuleAndQuotesTheThreeComments() {
        let text = RecurringFindingRule.template(for: finding())
        XCTAssertTrue(text.contains("CLAUDE.md"))
        XCTAssertTrue(text.contains("AGENTS.md"))
        for body in [firstBody, secondBody, thirdBody] {
            XCTAssertTrue(text.contains("> \(body)"), "the template quotes \(body)")
        }
        // The whole point of the wording: the task is the instructions file, not this diff.
        XCTAssertTrue(text.lowercased().contains("one paragraph"))
    }

    func testTheSteeringSentenceLeadsTheQuotedCommentsAndNamesItself() {
        let context = RecurringFindingRule.context(
            finding: finding(),
            pullRequest: summary(number: 42),
            viewerLogin: viewer
        )
        let steered = RuleBriefDrafter.steer(context)
        XCTAssertEqual(steered.findingComments.first, RuleBriefDrafter.steeringComment)
        XCTAssertEqual(steered.findingComments.count, 4)
        // Prepended, because the budget fills the comments' share from the front: a steering
        // sentence at the end is the one a long finding would silently drop.
        XCTAssertEqual(Array(steered.findingComments.dropFirst()), context.findingComments)
        // Paired with an empty author, so the privacy rule still reads the three real comments.
        XCTAssertEqual(steered.findingCommentAuthors, ["", viewer, viewer, viewer])
        XCTAssertFalse(
            AgentBriefRequest.requiresOnDevice(context: steered, viewerLogin: viewer)
        )
        XCTAssertTrue(
            RuleBriefDrafter.steeringComment.contains("not a review comment"),
            "it appears among review comments and must say what it is"
        )
    }

    func testTheSteeringSentenceTravelsInTheRequestTheProviderIsGiven() {
        let context = RuleBriefDrafter.steer(
            RecurringFindingRule.context(
                finding: finding(),
                pullRequest: summary(number: 42),
                viewerLogin: viewer
            )
        )
        let request = AgentBriefRequest.build(
            context: context,
            digest: AgentBriefRequest.digest(
                for: detail(
                    number: 42,
                    comments: [(id: "C_1", body: firstBody, author: viewer, daysAgo: 1)]
                ),
                budget: OnDeviceProvider.budget
            ),
            budget: OnDeviceProvider.budget,
            viewerLogin: viewer
        )
        XCTAssertEqual(request.findings.first?.body, RuleBriefDrafter.steeringComment)
        XCTAssertNil(request.findings.first?.author)
        XCTAssertFalse(request.onDeviceOnly)
        // And it survives into the prompt body the provider sends.
        XCTAssertTrue(IntelligencePrompt.body(for: request).contains("Write ONE rule"))
        // Uncut: the sentence is under the per-comment character cap, so nothing of it is lost.
        XCTAssertFalse(request.findings.first?.body.hasSuffix("…") ?? true)
    }

    // MARK: - The rules engine gets nothing from here

    func testTheAutoDelegationRulesCarryNoRecurringFindingTrigger() {
        // Mirrors `AgentBriefTests.testTheRulesInputsAndOutputsCarryNoDraftedText`: the point is
        // not that no rule fires on a recurring finding today, it is that there is no *case* one
        // could be armed with (ADR 0016, ADR 0029). Adding a third trigger later would break this
        // assertion on purpose.
        XCTAssertEqual(
            Set(AutoDelegationTrigger.allCases),
            [.checksFailed, .changesRequested]
        )
        for trigger in AutoDelegationTrigger.allCases {
            XCTAssertFalse(trigger.rawValue.lowercased().contains("recurring"))
            XCTAssertFalse(trigger.rawValue.lowercased().contains("finding"))
        }
        // And the rendered task of a rule never quotes a finding: the template has no placeholder
        // that could carry one.
        let rules = AutoDelegationRules(isEnabled: true, triggers: [.checksFailed])
        XCTAssertFalse(rules.promptTemplate.contains("CLAUDE.md"))
        XCTAssertFalse(rules.promptTemplate.contains("AGENTS.md"))
        XCTAssertFalse(rules.promptTemplate.lowercased().contains("recurring"))
    }
}
