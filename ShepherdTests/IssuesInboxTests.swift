import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// The app half of the issues inbox (ADR 0032): the model's facets and its selection, the
/// panel's fetch-once rule, the content-kind split, and the palette's merge of two ranked sets.
///
/// The *pure* halves are covered on the Linux runner — `IssueFacetTests` for the counting,
/// `IssueAgeBucketTests` for the bucketing, `IssueSearchRankerTests` for the ranking, and
/// `DeepLinkTests` for the grammar. What is tested here is everything those cannot see: the
/// observation, the two-level staleness gate over a real SQLite file, and the merge.
///
/// Nothing here needs a `SignedInSession`, a Keychain or a token, which is the point of
/// `IssueInboxModel` taking a database and an `IssueFetching` seam instead of a session.
@MainActor
final class IssuesInboxTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let webRepo = RepoRef(owner: "schnaq", name: "web")
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

    // MARK: - Doubles and fixtures

    /// The issue read, counted. The one production conformance is `GitHubClient`.
    private actor RecordingIssueReader: IssueFetching {
        private(set) var reads: [String] = []
        private let body: String

        init(body: String = "A body somebody typed.") {
            self.body = body
        }

        var readCount: Int { reads.count }

        func issue(repo: RepoRef, number: Int) async throws -> IssueSummary {
            reads.append("\(repo.fullName)#\(number)")
            return IssueSummary(
                repo: repo,
                number: number,
                title: "Issue \(number)",
                bodyMarkdown: body,
                state: .open
            )
        }
    }

    /// A machine author, spelled neutrally: what the facet asks is whether a machine wrote the
    /// linked pull request, and which one is the detector's own suite's business.
    private func agentActor() -> ShepherdCore.Actor {
        ShepherdCore.Actor(
            login: "example-agent[bot]",
            kind: .agent(
                AgentIdentity(
                    id: "example-agent",
                    displayName: "Example Agent",
                    matchedBy: .login
                )
            )
        )
    }

    private func issue(
        _ number: Int,
        repo: RepoRef? = nil,
        title: String? = nil,
        labels: [String] = [],
        daysAgo: Double = 0,
        updatedOffset: TimeInterval = 0,
        state: IssueSummary.State = .open,
        agentLink: Bool = false
    ) -> IssueRowSummary {
        let repository = repo ?? self.repo
        let links: [LinkedPullRequestReference] = agentLink
            ? [
                LinkedPullRequestReference(
                    repo: repository,
                    number: 900 + number,
                    title: "Fix issue \(number)",
                    state: "OPEN",
                    author: agentActor()
                ),
            ]
            : []
        return IssueRowSummary(
            id: "I_\(number)",
            repo: repository,
            number: number,
            title: title ?? "Issue \(number)",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            createdAt: clock.addingTimeInterval(-daysAgo * 24 * 3_600),
            updatedAt: clock.addingTimeInterval(updatedOffset),
            // A closed row the sweep captured always carries the moment: the retention window is
            // measured from it, and a row without one would be kept on `updatedAt` instead.
            closedAt: state == .closed ? clock.addingTimeInterval(updatedOffset) : nil,
            state: state,
            labels: labels,
            myRelation: [.assigned],
            commentCount: number,
            linkedPullRequests: links
        )
    }

    private var rows: [IssueRowSummary] {
        [
            issue(1, title: "Flaky login test", labels: ["bug", "ui"], daysAgo: 0),
            issue(2, title: "Bump GRDB", labels: ["bug"], daysAgo: 3, agentLink: true),
            issue(3, repo: webRepo, title: "A dark theme", labels: ["ui"], daysAgo: 40),
        ]
    }

    /// A closed issue the sweep captured and is holding for its retention window (ADR 0032).
    ///
    /// A fourth row rather than a state on one of the three, so every assertion about the three
    /// open ones keeps saying what it said before this facet existed.
    private func closedIssue(
        repo: RepoRef? = nil,
        labels: [String] = ["bug"]
    ) -> IssueRowSummary {
        issue(
            4,
            repo: repo,
            title: "Long since fixed",
            labels: labels,
            daysAgo: 9,
            state: .closed
        )
    }

    private func makeModel(
        database: DatabaseManager,
        issues: (any IssueFetching)?,
        viewerLogin: String? = nil
    ) -> IssueInboxModel {
        let fixedNow = clock
        return IssueInboxModel(
            database: database,
            issues: issues,
            viewerLogin: viewerLogin,
            now: { fixedNow }
        )
    }

    /// Spins the main actor until a condition holds, or gives up.
    ///
    /// A short sleep rather than a bare `Task.yield()`, unlike the coordinator tests: a GRDB
    /// `ValueObservation` schedules its first value on a background queue, so handing this actor
    /// back is not by itself enough for it to arrive.
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func started(
        _ model: IssueInboxModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        model.startObserving()
        await wait(until: { model.hasLoaded })
        XCTAssertTrue(model.hasLoaded, "the issues observation never spoke", file: file, line: line)
    }

    // MARK: - Facets

    func testTheFacetsAreCountedOverTheWholeSectionAndNotOverTheFilteredList() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        await started(model)

        XCTAssertEqual(model.allRows.count, 3)
        XCTAssertEqual(
            model.labelFacets.facets,
            [IssueLabelFacet(name: "bug", count: 2), IssueLabelFacet(name: "ui", count: 2)]
        )
        XCTAssertEqual(model.labelFacets.hiddenCount, 0)
        XCTAssertEqual(model.ageFacets.map(\.bucket), [.today, .thisWeek, .older])
        XCTAssertEqual(
            model.agentPullRequestFacets.map(\.filter),
            [.hasNone, .hasAgentPullRequest]
        )
        XCTAssertEqual(model.agentPullRequestFacets.map(\.count), [2, 1])
        XCTAssertEqual(model.repositoryFacets.map(\.repo), [repo, webRepo])
        XCTAssertEqual(model.repositoryFacets.map(\.count), [2, 1])

        // Selecting a facet narrows the list and leaves every count where it was — the property
        // that makes the numbers comparable.
        model.labelFilter = "ui"
        XCTAssertEqual(model.filteredRows.map(\.number), [1, 3])
        XCTAssertEqual(
            model.labelFacets.facets,
            [IssueLabelFacet(name: "bug", count: 2), IssueLabelFacet(name: "ui", count: 2)]
        )
    }

    func testTheFourFacetsCompose() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        await started(model)

        model.repoFilter = repo
        model.ageFilter = .thisWeek
        XCTAssertEqual(model.filteredRows.map(\.number), [2])
        model.agentPullRequestFilter = .hasNone
        XCTAssertTrue(model.filteredRows.isEmpty, "the agent facet composes rather than replaces")
        XCTAssertTrue(model.hasActiveFacet)
        model.clearFacets()
        XCTAssertFalse(model.hasActiveFacet)
        XCTAssertEqual(model.filteredRows.count, 3)
    }

    func testTheRepositoryFacetIsCaseInsensitive() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        await started(model)

        // A `shepherd://` link carries whatever casing was typed; the cache holds GitHub's.
        model.repoFilter = RepoRef(owner: "SCHNAQ", name: "Review")
        // The store orders by freshness; this test is about membership, not order.
        XCTAssertEqual(model.filteredRows.map(\.number).sorted(), [1, 2])
    }

    // MARK: - Selection

    func testTheFirstRowIsSelectedAndTheListIsMostRecentlyUpdatedFirst() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries([
            issue(1, updatedOffset: 0),
            issue(2, updatedOffset: 60),
            issue(3, updatedOffset: -60),
        ])
        let model = makeModel(database: database, issues: nil)
        await started(model)

        XCTAssertEqual(model.visibleRows.map(\.number), [2, 1, 3])
        XCTAssertEqual(model.selectedID, "I_2")
    }

    func testSelectionIsPrunedWhenAFacetHidesTheSelectedRow() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        await started(model)

        model.select("I_3")
        XCTAssertEqual(model.selectedID, "I_3")
        // `I_3` is the only issue in the other repository, so this facet hides it.
        model.repoFilter = repo
        XCTAssertNotEqual(model.selectedID, "I_3")
        XCTAssertEqual(model.selectedID, model.visibleRows.first?.id)
    }

    func testSelectionIsPrunedWhenTheSweepRemovesTheSelectedRow() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        await started(model)

        model.select("I_3")
        try await database.saveIssueSummaries([issue(1), issue(2)])
        await wait(until: { model.allRows.count == 2 })
        XCTAssertEqual(model.allRows.count, 2)
        XCTAssertNotEqual(model.selectedID, "I_3")
        XCTAssertNotNil(model.selectedID)
    }

    func testMoveSelectionWalksTheVisibleRowsAndStopsAtBothEnds() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries([
            issue(1, updatedOffset: 0),
            issue(2, updatedOffset: -60),
        ])
        let model = makeModel(database: database, issues: nil)
        await started(model)

        XCTAssertEqual(model.selectedID, "I_1")
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedID, "I_1", "k at the top stays put rather than wrapping")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, "I_2")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, "I_2", "j at the bottom stays put")
    }

    func testRevealWidensTheFacetsRatherThanSelectingNothing() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        await started(model)

        model.repoFilter = repo
        XCTAssertFalse(model.visibleRows.contains { $0.id == "I_3" })
        model.reveal(issueID: "I_3")
        XCTAssertEqual(model.selectedID, "I_3")
        XCTAssertNil(model.repoFilter, "a hidden row is shown, not silently not selected")
    }

    func testRevealingAClosedIssueWidensTheStateFacetAndShowsTheRow() async throws {
        // The bug this closes: a ⌘K hit on a closed issue used to switch to the section and show
        // nothing at all, because the section's observation left closed rows out and the ask was
        // parked forever waiting for a value that could not arrive.
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows + [closedIssue()])
        let model = makeModel(database: database, issues: nil)
        await started(model)

        XCTAssertEqual(model.allRows.count, 4, "the section observes the retained closed rows")
        XCTAssertEqual(model.stateFilter, IssueStateFilter.open)
        XCTAssertFalse(
            model.visibleRows.contains(where: { $0.id == "I_4" }),
            "and keeps them off screen"
        )

        model.reveal(issueID: "I_4")
        XCTAssertEqual(model.selectedID, "I_4")
        XCTAssertNil(model.stateFilter, "the reveal widens the facet rather than parking the ask")
        XCTAssertTrue(model.visibleRows.contains(where: { $0.id == "I_4" }))
        XCTAssertNotNil(model.selectedRow, "the panel has a row to draw, which is the whole point")
    }

    func testRevealingAClosedIssueTheRailIsAlsoFilteringSurvivesEveryClamp() async throws {
        // Two facets hiding one row: `clearFacets()` clamps once per assignment, so the cursor
        // has to be put back on the row that was asked for rather than trusted to survive.
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows + [closedIssue(repo: webRepo)])
        let model = makeModel(database: database, issues: nil)
        await started(model)

        model.repoFilter = repo
        model.labelFilter = "bug"
        model.reveal(issueID: "I_4")
        XCTAssertEqual(model.selectedID, "I_4")
        XCTAssertFalse(model.hasActiveFacet)
        XCTAssertTrue(model.visibleRows.contains(where: { $0.id == "I_4" }))
    }

    func testTheDefaultStateFacetHidesAClosedRowAndLeavesEveryOtherCountAlone() async throws {
        let database = try DatabaseManager.inMemory()
        let openOnly = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows + [closedIssue(labels: ["bug", "ui"])])
        try await openOnly.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        let reference = makeModel(database: openOnly, issues: nil)
        await started(model)
        await started(reference)

        // What the list shows is what it showed before closed rows were observed at all. As
        // sorted sets, because what is under test here is which rows survive the state facet;
        // the store's own order is pinned by the selection test above.
        XCTAssertEqual(model.allRows.count, 4)
        XCTAssertEqual(
            model.filteredRows.map(\.number).sorted(),
            reference.filteredRows.map(\.number).sorted()
        )

        // And so is every number in the rail: the four facets are counted over the rows the state
        // facet has already chosen, so a closed row cannot inflate one of them.
        XCTAssertEqual(model.labelFacets, reference.labelFacets)
        XCTAssertEqual(model.ageFacets, reference.ageFacets)
        XCTAssertEqual(model.agentPullRequestFacets, reference.agentPullRequestFacets)
        XCTAssertEqual(model.repositoryFacets.map(\.repo), reference.repositoryFacets.map(\.repo))
        XCTAssertEqual(
            model.repositoryFacets.map(\.count),
            reference.repositoryFacets.map(\.count)
        )
    }

    func testTheStateFacetCountsBothHalvesAndSelectingClosedDescribesTheClosedRows() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows + [closedIssue(labels: ["stale"])])
        let model = makeModel(database: database, issues: nil)
        await started(model)

        // Counted over the whole section, both halves: its own axis, so selecting one half must
        // not make the other disappear from the rail.
        XCTAssertEqual(model.stateFacets.map(\.filter), [.open, .closed])
        XCTAssertEqual(model.stateFacets.map(\.count), [3, 1])

        model.stateFilter = .closed
        XCTAssertEqual(model.filteredRows.map(\.number), [4])
        XCTAssertEqual(model.stateFacets.map(\.count), [3, 1], "the facet still counts both")
        XCTAssertTrue(model.hasActiveFacet, "closed is narrower than the section's default")
        // The other four now describe the closed rows rather than a mixed total.
        XCTAssertEqual(model.labelFacets.facets, [IssueLabelFacet(name: "stale", count: 1)])
        XCTAssertEqual(model.repositoryFacets.map(\.count), [1])

        model.stateFilter = nil
        XCTAssertEqual(model.filteredRows.count, 4, "nil is open and closed, as it is for the rest")
    }

    func testRevealOfAnIssueTheObservationDoesNotHaveYetIsHonouredWhenItArrives() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries([issue(1)])
        let model = makeModel(database: database, issues: nil)
        await started(model)

        model.reveal(issueID: "I_2")
        XCTAssertEqual(model.selectedID, "I_1", "nothing to reveal yet")
        try await database.saveIssueSummaries([issue(1), issue(2)])
        await wait(until: { model.selectedID == "I_2" })
        XCTAssertEqual(model.selectedID, "I_2")
    }

    // MARK: - The body fetch

    func testTheBodyIsFetchedOnceAndThenReadFromTheCache() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let reader = RecordingIssueReader()
        let model = makeModel(database: database, issues: reader)
        await started(model)

        // The first selection has no stored body, so it costs one read.
        await wait(until: { model.detail?.bodyMarkdown.isEmpty == false })
        let firstCount = await reader.readCount
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(model.detail?.bodyMarkdown, "A body somebody typed.")

        // Away and back: the stored body's fetch stamp is newer than the row's `updatedAt`, so
        // there is nothing that could have changed and nothing to ask for.
        let selected = try XCTUnwrap(model.selectedID)
        model.select(rows.first { $0.id != selected }?.id)
        await wait(until: { model.detail != nil })
        model.select(selected)
        await wait(until: { model.detail?.id == selected })
        let secondCount = await reader.readCount
        XCTAssertEqual(secondCount, 2, "one read per issue, and not one per selection")
    }

    func testAnIssueThatMovedAfterItsBodyWasStoredIsFetchedAgain() throws {
        let stored = Date(timeIntervalSince1970: 1_000)
        let row = issue(1)
        // Never fetched at all.
        XCTAssertTrue(
            IssueInboxModel.needsBodyFetch(row: row, cached: nil, fetchedAt: nil)
        )
        // A stamp with no cached record is a row whose body read failed; ask again.
        XCTAssertTrue(
            IssueInboxModel.needsBodyFetch(row: row, cached: nil, fetchedAt: stored)
        )
        let detail = IssueDetail(summary: row, bodyMarkdown: "body")
        // Fetched before the issue was last updated: the body may be out of date.
        XCTAssertTrue(
            IssueInboxModel.needsBodyFetch(row: row, cached: detail, fetchedAt: stored)
        )
        // Fetched at or after `updatedAt`: nothing can have changed since.
        XCTAssertFalse(
            IssueInboxModel.needsBodyFetch(row: row, cached: detail, fetchedAt: row.updatedAt)
        )
        XCTAssertFalse(
            IssueInboxModel.needsBodyFetch(
                row: row,
                cached: detail,
                fetchedAt: row.updatedAt.addingTimeInterval(1)
            )
        )
    }

    func testWithNoReaderThePanelStaysOnWhateverTheCacheHolds() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries([issue(1)])
        try await database.saveIssueDetail(
            IssueDetail(summary: issue(1), bodyMarkdown: "cached body")
        )
        let model = makeModel(database: database, issues: nil)
        await started(model)

        await wait(until: { model.detail != nil })
        XCTAssertEqual(model.detail?.bodyMarkdown, "cached body")
        XCTAssertFalse(model.isFetchingBody)
    }

    // MARK: - The content-kind split

    func testTheSectionTokenMovesThePickerAndLeavesThePullRequestRailAlone() {
        // The whole of what "switching the section does not disturb `j`/`k`" means at the level a
        // test can see it without a window: the mapping answers `nil` for the smart view, which
        // is what makes `InboxModel.apply` return before it touches the cursor, the facets or
        // the key sequence. Everything else about the split is that `InboxScreen` holds both
        // models for its own lifetime and hands each list its own `moveSelection`.
        let selection = InboxRailSelection(.issues)
        XCTAssertNil(selection.smartView)
        XCTAssertEqual(selection.contentKind, .issues)
        XCTAssertNil(selection.provenanceFilter)
        XCTAssertNil(selection.repoFilter)

        // Every other token stays on the pull-request side and keeps naming a rail state.
        for filter: InboxDeepLinkFilter in [
            .needsMyReview, .myPullRequests, .involved, .approvedByMe, .humans, .bots,
            .agent(id: "example-agent"), .repository(RepoRef(owner: "schnaq", name: "review")),
        ] {
            let mapped = InboxRailSelection(filter)
            XCTAssertEqual(mapped.contentKind, .pullRequests, "\(filter)")
            XCTAssertNotNil(mapped.smartView, "\(filter)")
        }
    }

    func testTheContentKindSurvivesSceneStorageAsItsRawValue() {
        // `@SceneStorage` stores the raw value, so a rename would silently reset every window's
        // picker to *Pull requests* rather than fail to build.
        for kind in ContentKind.allCases {
            XCTAssertEqual(ContentKind(rawValue: kind.rawValue), kind)
        }
        XCTAssertEqual(ContentKind.pullRequests.rawValue, "pullRequests")
        XCTAssertEqual(ContentKind.issues.rawValue, "issues")
    }

    func testMovingTheIssueCursorTouchesNothingElse() async throws {
        // The issue list raises the same `ShortcutAction` the pull-request list does and the
        // container routes it; what this pins is that the issue model's own cursor is the only
        // thing that moves, and that a half-typed pull-request sequence is a separate value that
        // nothing here can reach.
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        await started(model)

        var sequence = KeySequenceState()
        XCTAssertEqual(sequence.consume("r"), .awaitingSecondKey("r"))
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(sequence.armedPrefix, "r")
        XCTAssertEqual(sequence.consume("a"), .action(.approve))
    }

    // MARK: - Triage writes (ADR 0006, ADR 0032's Sprint 4a amendment)

    func testEveryTriageButtonWritesAnOutboxRowAndNothingElse() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil, viewerLogin: "octocat")
        await started(model)
        let row = try XCTUnwrap(model.allRows.first { $0.number == 1 })

        // Hoisted out of the assertions: `XCTAssertTrue` takes an autoclosure, and an `await`
        // inside one is not allowed.
        let commented = await model.comment("  On it.  ", on: row)
        let labelled = await model.addLabel("needs-triage", on: row)
        let assigned = await model.assignToMe(row)
        let closed = await model.close(.notPlanned, on: row)
        let reopened = await model.reopen(row)
        XCTAssertTrue(commented)
        XCTAssertTrue(labelled)
        XCTAssertTrue(assigned)
        XCTAssertTrue(closed)
        XCTAssertTrue(reopened)

        let queued = try await database.allOutboxItems()
        // As a set: five rows enqueued in the same millisecond are ordered by `createdAt`, and
        // what is being asserted here is *which* writes exist, not what order the drain sees.
        XCTAssertEqual(
            Set(queued.map(\.action)),
            [
                // Trimmed: a comment is prose, and trailing whitespace is not part of it.
                .addIssueComment(body: "On it.", basedOnUpdatedAt: row.updatedAt),
                .addIssueLabel(name: "needs-triage", basedOnUpdatedAt: row.updatedAt),
                .addIssueAssignee(login: "octocat", basedOnUpdatedAt: row.updatedAt),
                .closeIssue(reason: .notPlanned, basedOnUpdatedAt: row.updatedAt),
                .reopenIssue(basedOnUpdatedAt: row.updatedAt),
            ]
        )
        XCTAssertEqual(queued.count, 5)
        // The three target fields carry the issue, which is what the drain and the prune guard
        // both read them as.
        XCTAssertEqual(Set(queued.map(\.prID)), ["I_1"])
        XCTAssertEqual(Set(queued.map(\.number)), [1])
        XCTAssertEqual(Set(queued.map(\.repo)), [repo])
        XCTAssertTrue(queued.allSatisfy { $0.action.targetsIssue })
        XCTAssertTrue(
            queued.allSatisfy { $0.action.basedOnIssueUpdatedAt == row.updatedAt },
            "every write is pinned to the row the user was looking at"
        )
    }

    func testAnEmptyCommentIsNotAWrite() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        await started(model)
        let row = try XCTUnwrap(model.allRows.first)

        let queued = await model.comment("   \n  ", on: row)
        XCTAssertFalse(queued)
        let outbox = try await database.allOutboxItems()
        XCTAssertTrue(outbox.isEmpty)
    }

    func testAssignToMeNeedsSomebodyToAssign() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        // No login: a signed-out window does not draw the button, and the method refuses too.
        let model = makeModel(database: database, issues: nil)
        await started(model)
        let row = try XCTUnwrap(model.allRows.first)

        let assigned = await model.assignToMe(row)
        XCTAssertFalse(assigned)
        let outbox = try await database.allOutboxItems()
        XCTAssertTrue(outbox.isEmpty)
    }

    func testThePanelCountsWhatTheOutboxIsHoldingForOneIssue() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil, viewerLogin: "octocat")
        await started(model)
        let first = try XCTUnwrap(model.allRows.first { $0.number == 1 })
        let second = try XCTUnwrap(model.allRows.first { $0.number == 2 })

        await model.addLabel("bug", on: first)
        await model.close(.completed, on: second)
        await model.refreshPendingWrites()

        XCTAssertEqual(model.queuedWriteCount(for: first), 1)
        XCTAssertEqual(model.queuedWriteCount(for: second), 1)
        XCTAssertEqual(model.parkedWriteCount(for: first), 0)

        // Parked is the other half of what the pull-request side shows, and it is per row.
        let stored = try await database.allOutboxItems()
        let parked = try XCTUnwrap(stored.first { $0.prID == first.id })
        try await database.markOutboxItemConflicted(id: parked.id, reason: "moved on")
        await model.refreshPendingWrites()
        XCTAssertEqual(model.parkedWriteCount(for: first), 1)
        XCTAssertEqual(model.queuedWriteCount(for: first), 0)
        XCTAssertEqual(model.parkedWriteCount(for: second), 0)
    }

    func testAWriteThatWasGivenUpOnIsCountedAndIsNotConfusedWithTheOtherTwo() async throws {
        // The drain fails an issue row non-retriably when nothing is wired up to send it, and a
        // 4xx does the same. Such a row is neither waiting nor parked, so before this count it
        // was on nobody's screen.
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil, viewerLogin: "octocat")
        await started(model)
        let first = try XCTUnwrap(model.allRows.first { $0.number == 1 })
        let second = try XCTUnwrap(model.allRows.first { $0.number == 2 })

        await model.addLabel("needs-triage", on: first)
        await model.close(.completed, on: second)
        await model.refreshPendingWrites()
        XCTAssertEqual(model.failedWriteCount(for: first), 0)

        let stored = try await database.allOutboxItems()
        let doomed = try XCTUnwrap(stored.first { $0.prID == first.id })
        try await database.markOutboxItemFailed(
            id: doomed.id,
            error: "no writer is wired up",
            now: clock,
            retriable: false
        )
        await model.refreshPendingWrites()

        XCTAssertEqual(model.failedWriteCount(for: first), 1)
        XCTAssertEqual(model.queuedWriteCount(for: first), 0, "a failed row is not waiting")
        XCTAssertEqual(model.parkedWriteCount(for: first), 0, "and it is not parked either")
        // Per issue, like the other two: the other row's write is untouched.
        XCTAssertEqual(model.failedWriteCount(for: second), 0)
        XCTAssertEqual(model.queuedWriteCount(for: second), 1)
    }

    func testTheFailedCountIsRefreshedByTheEnqueueAndDrainCycle() async throws {
        // The panel's counters are read after every enqueue and every drain rather than observed;
        // a drain that fails the row must therefore leave the count on screen behind it.
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil, viewerLogin: "octocat")
        await started(model)
        let row = try XCTUnwrap(model.allRows.first)

        model.drain = {
            let items = (try? await database.allOutboxItems()) ?? []
            for item in items where item.state == .pending {
                try? await database.markOutboxItemFailed(
                    id: item.id,
                    error: "no writer is wired up",
                    now: Date(),
                    retriable: false
                )
            }
        }

        await model.addLabel("needs-triage", on: row)

        XCTAssertEqual(
            model.failedWriteCount(for: row),
            1,
            "the refresh after the drain is what puts it on screen"
        )
        XCTAssertEqual(model.queuedWriteCount(for: row), 0)
    }

    func testTheLabelPickerOffersWhatTheSectionHasSeenInThatRepositoryAndNoMore() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        await started(model)
        let first = try XCTUnwrap(model.allRows.first { $0.number == 1 })
        let other = try XCTUnwrap(model.allRows.first { $0.number == 3 })

        // `bug` and `ui` are both on this row already, so the picker has nothing left to add —
        // and `ui` from the *other* repository is deliberately not offered here.
        XCTAssertEqual(model.availableLabels(for: first), [])
        XCTAssertEqual(model.availableLabels(for: other), [])

        let second = try XCTUnwrap(model.allRows.first { $0.number == 2 })
        XCTAssertEqual(
            model.availableLabels(for: second),
            ["ui"],
            "a label another issue of the same repository carries, minus the ones it has"
        )
    }

    func testAQueuedWriteAsksForADrainWithoutCallingGitHub() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.saveIssueSummaries(rows)
        let model = makeModel(database: database, issues: nil)
        await started(model)
        let row = try XCTUnwrap(model.allRows.first)

        let drains = Counter()
        model.drain = { await drains.increment() }
        await model.addLabel("needs-triage", on: row)

        let count = await drains.value
        XCTAssertEqual(count, 1, "the write is queued locally and the engine is asked to push it")
    }

    /// A counting box, so the drain hook can be asserted without a sync engine.
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
