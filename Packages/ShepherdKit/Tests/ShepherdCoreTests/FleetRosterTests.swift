import Foundation
import XCTest

@testable import ShepherdCore

/// The fleet's counting: two sources, one join, one order — and no people in it.
final class FleetRosterTests: XCTestCase {
    private let repo = Fixtures.repo
    private let konduit = RepoRef(owner: "schnaq", name: "konduit")
    private let since = Fixtures.date(-10_000)

    // MARK: - Membership

    func testAnOutcomeWithoutAnAgentNameProducesNoRow() {
        let fleet = FleetRoster.make(
            outcomes: [outcome("PR_1", agent: nil, login: "octocat")],
            openRows: [],
            since: since
        )
        XCTAssertTrue(fleet.isEmpty, "a person's pull request is not part of a fleet of agents")
    }

    func testAnOpenRowFromAPersonIsNotAFleetMember() {
        let fleet = FleetRoster.make(outcomes: [], openRows: [humanRow("PR_1")], since: since)
        XCTAssertTrue(fleet.isEmpty)
    }

    func testAnAgentsRowHasNowhereForTheHumanLoginThatOpenedItToAppear() throws {
        // The structural half of ADR 0027's "agents, never people". A local session pushes with
        // the maintainer's own token, so an agent's outcome carries a person's login — and this
        // test exists because the way that leaks is not a filter someone forgets but a field
        // someone adds. `Mirror` sees a `login` however it is spelled or nested, which a test
        // against `FleetAgent`'s current fields would not.
        let fleet = FleetRoster.make(
            outcomes: [outcome("PR_1", agent: "Claude Code", login: "christian")],
            openRows: [],
            since: since
        )
        let agent = try XCTUnwrap(fleet.first)
        XCTAssertEqual(agent.displayName, "Claude Code")
        assertNoLogin(in: agent, label: "FleetAgent")
    }

    func testAnAgentWithNothingOpenStillAppearsFromItsHistoryAlone() throws {
        let fleet = FleetRoster.make(outcomes: [outcome("PR_1")], openRows: [], since: since)
        let agent = try XCTUnwrap(fleet.first)
        XCTAssertEqual(agent.openCount, 0)
        XCTAssertEqual(agent.repositories.count, 1)
        XCTAssertEqual(agent.overall.merged, 1)
    }

    func testOutcomesOlderThanTheWindowAreNotCountedEvenWhenTheCallerPassedThem() {
        // The store's query already filters; this function filters again, because the rule is
        // here and a rule that only held for callers who had filtered first is not testable.
        XCTAssertTrue(
            FleetRoster.make(
                outcomes: [outcome("PR_1", closedAt: -10_001)],
                openRows: [],
                since: since
            ).isEmpty
        )
        XCTAssertEqual(
            FleetRoster.make(
                outcomes: [outcome("PR_1", closedAt: -10_001), outcome("PR_2", closedAt: 0)],
                openRows: [],
                since: since
            ).first?.overall.merged,
            1
        )
    }

    // MARK: - The join between history and the inbox

    func testTheJoinBetweenHistoryAndTheInboxIgnoresCase() throws {
        let fleet = FleetRoster.make(
            outcomes: [outcome("PR_1", agent: "claude code")],
            openRows: [agentRow("PR_2", agent: "Claude Code")],
            since: since
        )
        XCTAssertEqual(fleet.count, 1, "one agent, spelled two ways, is one row")
        let agent = try XCTUnwrap(fleet.first)
        XCTAssertEqual(agent.displayName, "Claude Code", "the live actor names the agent")
        XCTAssertEqual(agent.openCount, 1)
        XCTAssertEqual(agent.overall.merged, 1)
    }

    func testAnAgentWithOnlyHistoryHasNoRegistryIdentifier() {
        let fleet = FleetRoster.make(outcomes: [outcome("PR_1")], openRows: [], since: since)
        XCTAssertNil(
            fleet.first?.registryID,
            "the identifier travels on a live actor; history keeps only the display name"
        )
    }

    func testTheRegistryIdentifierComesFromTheLiveActor() {
        let fleet = FleetRoster.make(
            outcomes: [outcome("PR_1")],
            openRows: [agentRow("PR_2")],
            since: since
        )
        XCTAssertEqual(fleet.first?.registryID, "claude-code")
    }

    func testAnAgentIsIdentifiedByItsNameAndARepositoryByItsFullNameIgnoringCase() throws {
        let fleet = FleetRoster.make(
            outcomes: [outcome("PR_1", repo: RepoRef(owner: "Schnaq", name: "Review"))],
            openRows: [],
            since: since
        )
        let agent = try XCTUnwrap(fleet.first)
        XCTAssertEqual(agent.id, "claude code")
        XCTAssertEqual(agent.repositories.first?.id, "schnaq/review")
    }

    // MARK: - Bucketing

    func testOutcomesAreBucketedByAgentAndThenByRepository() throws {
        let fleet = FleetRoster.make(
            outcomes: [
                outcome("PR_1", agent: "Claude Code", repo: repo),
                outcome("PR_2", agent: "Claude Code", repo: konduit),
                outcome("PR_3", agent: "Claude Code", repo: konduit),
                outcome("PR_4", agent: "Dependabot", repo: konduit),
            ],
            openRows: [],
            since: since
        )
        XCTAssertEqual(fleet.map(\.displayName), ["Claude Code", "Dependabot"])
        let claude = try XCTUnwrap(fleet.first)
        XCTAssertEqual(claude.repositories.map(\.id), ["schnaq/konduit", "schnaq/review"])
        XCTAssertEqual(claude.repositories.first?.record.merged, 2)
        XCTAssertEqual(claude.repositories.last?.record.merged, 1)
        XCTAssertEqual(fleet.last?.overall.merged, 1)
    }

    func testTheAggregateIsTheSameCountingAsTheRepositoryRowsBelowIt() throws {
        // ADR 0027's arithmetic is the only arithmetic: the fleet buckets and calls
        // `TrackRecord.compute`, so the card at the top of a page and the grid underneath it
        // cannot disagree about the same ninety days.
        let outcomes = [
            outcome("PR_1", repo: repo, merged: true),
            outcome("PR_2", repo: repo, merged: false),
            outcome("PR_3", repo: konduit, merged: true, revertedBy: "PR_9"),
        ]
        let agent = try XCTUnwrap(
            FleetRoster.make(outcomes: outcomes, openRows: [], since: since).first
        )
        XCTAssertEqual(
            agent.overall,
            TrackRecord.compute(outcomes: outcomes, agent: "Claude Code", repo: nil, since: since)
        )
        XCTAssertEqual(agent.repositories.map(\.record.merged).reduce(0, +), agent.overall.merged)
        XCTAssertEqual(
            agent.repositories.map(\.record.closedUnmerged).reduce(0, +),
            agent.overall.closedUnmerged
        )
        XCTAssertEqual(agent.overall.reverted, 1)
    }

    func testAnEmptyDenominatorStaysNilRatherThanBecomingZero() throws {
        let agent = try XCTUnwrap(
            FleetRoster.make(
                outcomes: [outcome("PR_1", firstPushGreen: nil)],
                openRows: [],
                since: since
            ).first
        )
        XCTAssertNil(agent.overall.firstPushGreenRate, "nothing known is not a red first push")
        XCTAssertNil(agent.repositories.first?.record.firstPushGreenRate)
        XCTAssertEqual(
            agent.overall.medianReviewRounds,
            0,
            "a counted pull request that needed no round is a zero; an absence is something else"
        )
    }

    func testARepositoryWithNothingClosedInItGetsTheEmptyRecord() throws {
        let agent = try XCTUnwrap(
            FleetRoster.make(
                outcomes: [],
                openRows: [agentRow("PR_1", repo: konduit)],
                since: since
            ).first
        )
        let repository = try XCTUnwrap(agent.repositories.first)
        XCTAssertEqual(repository.record, TrackRecord.empty)
        XCTAssertNil(repository.record.firstPushGreenRate, "never 0 %, which would be a claim")
        XCTAssertNil(repository.lastClosedAt)
        XCTAssertEqual(repository.openCount, 1)
    }

    // MARK: - Open counts

    func testWaitingOnYouCountsOnlyTheRowsThatStillNeedAReview() throws {
        let agent = try XCTUnwrap(
            FleetRoster.make(
                outcomes: [],
                openRows: [
                    agentRow("PR_1", relations: [.reviewRequested]),
                    agentRow("PR_2", relations: [.reviewRequested], reviewDecision: .approved),
                    agentRow("PR_3"),
                ],
                since: since
            ).first
        )
        XCTAssertEqual(agent.openCount, 3)
        XCTAssertEqual(
            agent.openAwaitingReviewCount,
            1,
            "an approved pull request keeps GitHub's review request; `needsMyReview` does not"
        )
        XCTAssertEqual(agent.repositories.first?.openAwaitingReviewCount, 1)
    }

    // MARK: - History only

    func testARepositoryTheInboxNoLongerCarriesIsMarkedHistoryOnly() throws {
        let agent = try XCTUnwrap(
            FleetRoster.make(
                outcomes: [outcome("PR_1", repo: repo), outcome("PR_2", repo: konduit)],
                openRows: [agentRow("PR_3", repo: repo)],
                since: since
            ).first
        )
        let konduitRow = try XCTUnwrap(agent.repositories.first { $0.id == "schnaq/konduit" })
        let reviewRow = try XCTUnwrap(agent.repositories.first { $0.id == "schnaq/review" })
        XCTAssertTrue(konduitRow.isHistoryOnly, "nothing in the inbox names it any more")
        XCTAssertFalse(reviewRow.isHistoryOnly)
    }

    func testARepositoryIsNotHistoryOnlyMerelyBecauseTheAgentHasNothingOpenThere() throws {
        // The question is whether the *inbox* still carries the repository, not whether this one
        // agent has something open in it — an agent having a quiet week in a repository the user
        // still reviews in must not be footnoted as history.
        let agent = try XCTUnwrap(
            FleetRoster.make(
                outcomes: [outcome("PR_1", repo: repo)],
                openRows: [humanRow("PR_2", repo: repo)],
                since: since
            ).first
        )
        let repository = try XCTUnwrap(agent.repositories.first)
        XCTAssertEqual(repository.openCount, 0)
        XCTAssertFalse(repository.isHistoryOnly)
    }

    // MARK: - The one order

    func testAgentsAreOrderedByOpenCountThenLastCloseThenName() {
        let fleet = FleetRoster.make(
            outcomes: [
                outcome("PR_10", agent: "Mid", closedAt: -100),
                outcome("PR_11", agent: "Nova", closedAt: -5_000),
            ],
            openRows: [
                agentRow("PR_1", agent: "Zed", registryID: "zed"),
                agentRow("PR_2", agent: "Zed", registryID: "zed"),
                agentRow("PR_3", agent: "Alpha", registryID: "alpha"),
            ],
            since: since
        )
        XCTAssertEqual(fleet.map(\.displayName), ["Zed", "Alpha", "Mid", "Nova"])
    }

    func testAnAgentThatHasNeverClosedAnythingSortsAfterOneThatHas() {
        let fleet = FleetRoster.make(
            outcomes: [outcome("PR_10", agent: "Zed")],
            openRows: [
                agentRow("PR_1", agent: "Zed", registryID: "zed"),
                agentRow("PR_2", agent: "Alpha", registryID: "alpha"),
            ],
            since: since
        )
        XCTAssertEqual(
            fleet.map(\.displayName),
            ["Zed", "Alpha"],
            "no last close sorts last, even against a name that would sort first"
        )
    }

    func testRepositoriesAreOrderedByOpenCountThenLastCloseThenFullName() throws {
        let aaa = RepoRef(owner: "schnaq", name: "aaa")
        let bbb = RepoRef(owner: "schnaq", name: "bbb")
        let ccc = RepoRef(owner: "schnaq", name: "ccc")
        let agent = try XCTUnwrap(
            FleetRoster.make(
                outcomes: [
                    outcome("PR_1", repo: aaa, closedAt: -5_000),
                    outcome("PR_2", repo: bbb, closedAt: -100),
                ],
                openRows: [agentRow("PR_3", repo: ccc)],
                since: since
            ).first
        )
        XCTAssertEqual(
            agent.repositories.map(\.repo.name),
            ["ccc", "bbb", "aaa"],
            "the one order, and it reverses the alphabet here on purpose"
        )
    }

    func testTheOrderDoesNotDependOnTheOrderOfTheInput() {
        let outcomes = [
            outcome("PR_1", agent: "Claude Code", repo: repo, closedAt: -100),
            outcome("PR_2", agent: "Claude Code", repo: konduit, closedAt: -200),
            outcome("PR_3", agent: "Dependabot", repo: konduit, closedAt: -300),
            outcome("PR_4", agent: "Dependabot", repo: repo, closedAt: -100),
        ]
        let rows = [
            agentRow("PR_5", agent: "Claude Code", repo: repo),
            agentRow("PR_6", agent: "Dependabot", registryID: "dependabot", repo: konduit),
        ]
        XCTAssertEqual(
            FleetRoster.make(outcomes: outcomes, openRows: rows, since: since),
            FleetRoster.make(
                outcomes: Array(outcomes.reversed()),
                openRows: Array(rows.reversed()),
                since: since
            ),
            "the answer is a function of the rows, not of the order a database returned them in"
        )
    }

    // MARK: - Fixtures

    private func outcome(
        _ id: String,
        agent: String? = "Claude Code",
        login: String = "claude[bot]",
        repo: RepoRef? = nil,
        merged: Bool = true,
        closedAt: TimeInterval = 0,
        revertedBy: String? = nil,
        firstPushGreen: Bool? = nil,
        reviewRounds: Int = 0
    ) -> PullRequestOutcome {
        PullRequestOutcome(
            prID: id,
            repo: repo ?? Fixtures.repo,
            agentName: agent,
            authorLogin: login,
            openedAt: Fixtures.date(closedAt - 3_600),
            closedAt: Fixtures.date(closedAt),
            merged: merged,
            revertedByPRID: revertedBy,
            firstPushCIGreen: firstPushGreen,
            reviewRounds: reviewRounds,
            changedLines: 42,
            source: .backfill
        )
    }

    private func agentRow(
        _ id: String,
        agent: String = "Claude Code",
        registryID: String = "claude-code",
        repo: RepoRef? = nil,
        relations: Set<Relation> = [],
        reviewDecision: ReviewDecision? = nil
    ) -> PullRequestSummary {
        Fixtures.summary(
            id: id,
            repo: repo ?? Fixtures.repo,
            author: Fixtures.makeActor("claude[bot]", kind: Fixtures.agent(registryID, agent)),
            reviewDecision: reviewDecision,
            relations: relations
        )
    }

    private func humanRow(_ id: String, repo: RepoRef? = nil) -> PullRequestSummary {
        Fixtures.summary(
            id: id,
            repo: repo ?? Fixtures.repo,
            author: Fixtures.makeActor("christian")
        )
    }

    /// Fails when anything reachable from `value` is called a login or carries one.
    ///
    /// Names as well as values, for ``TrustLaneTests``' reason: the failure mode is a field a
    /// later change adds, and `Mirror` reports the label whatever type it was given.
    private func assertNoLogin(
        in value: Any,
        label: String,
        depth: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard depth < 6 else { return }
        for child in Mirror(reflecting: value).children {
            let childLabel = child.label ?? "?"
            XCTAssertFalse(
                childLabel.lowercased().contains("login"),
                """
                \(label).\(childLabel) is a login. The fleet counts agents: a login here would \
                let the screen describe a person who never opened it (ADR 0027).
                """,
                file: file,
                line: line
            )
            XCTAssertNotEqual(
                child.value as? String,
                "christian",
                "\(label).\(childLabel) carries the login that opened the pull request",
                file: file,
                line: line
            )
            assertNoLogin(
                in: child.value,
                label: "\(label).\(childLabel)",
                depth: depth + 1,
                file: file,
                line: line
            )
        }
    }
}
