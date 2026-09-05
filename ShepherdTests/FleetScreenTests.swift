import Foundation
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import Shepherd

/// The app half of the fleet (plan §5-P2): the model's three sparse states, its refreshing, the
/// em-dash rule the grid is drawn by, the sentences the screen states unprompted, and what a row
/// says to a screen reader.
///
/// The *pure* halves are covered on the Linux runner — `FleetRosterTests` for the bucketing and
/// the one fixed order, `FleetNoticeTests` for both sides of every threshold. What is tested here
/// is everything those cannot see: the model over a real SQLite file, the decisions the screen
/// branches on, and the wording, which lives in the app target because it is localised.
///
/// Nothing here needs a `SignedInSession`, a Keychain or a token, which is the point of
/// `FleetModel` taking a ``FleetReading`` seam rather than a session.
@MainActor
final class FleetScreenTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let other = RepoRef(owner: "schnaq", name: "konduit")
    private let clock = Date(timeIntervalSince1970: 1_788_162_000)

    // MARK: - Doubles

    /// The two reads, counted. The one production conformance is `DatabaseManager`, which this
    /// wraps rather than replaces: what is being asserted is *how often* the screen asks, and a
    /// double that answered from a dictionary would also be asserting the wrong query.
    private actor CountingReader: FleetReading {
        private let database: DatabaseManager
        private(set) var outcomeReads = 0

        init(database: DatabaseManager) {
            self.database = database
        }

        func pullRequestOutcomes(since: Date) async throws -> [PullRequestOutcome] {
            outcomeReads += 1
            return try await database.pullRequestOutcomes(since: since)
        }

        func agentRegistryOverrides() async throws -> [AgentRegistryEntry] {
            try await database.agentRegistryOverrides()
        }
    }

    // MARK: - The three sparse states (plan §6)

    func testAFleetWithNoAgentsIsTheEmptiestState() {
        XCTAssertEqual(FleetModel.emptyState(for: []), .noAgents)
    }

    func testAgentsWithNothingCountedAreTheOfferToCount() {
        let agent = FleetAgent(displayName: "Claude Code", overall: .empty, openCount: 3)
        XCTAssertEqual(
            FleetModel.emptyState(for: [agent]),
            .noHistory,
            "an agent that is only here because something of its is open"
        )
    }

    func testOneCountedOutcomeAnywhereMakesItTheOrdinaryScreen() {
        // The question is asked of the roster and not of a `SELECT COUNT(*)`: a table holding
        // only rows outside the window, or only a person's, is a table with a count and a fleet
        // with nothing counted.
        let counted = FleetAgent(displayName: "Claude Code", overall: TrackRecord(merged: 1))
        let bare = FleetAgent(displayName: "Example Agent", overall: .empty, openCount: 2)
        XCTAssertEqual(FleetModel.emptyState(for: [bare, counted]), .counted)
    }

    // MARK: - The model over a real database

    func testTheModelCountsTheStoredOutcomesAgainstTheOpenInbox() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestOutcomes([
            closed("PR_1", repo: repo, merged: true, firstPushGreen: true),
            closed("PR_2", repo: repo, merged: true, reverted: true, firstPushGreen: false),
            closed("PR_3", repo: repo, merged: false),
            // A person's pull request in the same repository, which must not enter the fleet at
            // all: membership is `agentName != nil` and nothing else.
            closed("PR_4", repo: repo, agentName: nil, merged: true),
        ])
        let model = FleetModel(reader: database, now: { [clock] in clock })

        model.refresh(openRows: [
            summary("PR_open_1", repo: repo, number: 10, needsReview: true),
            summary("PR_open_2", repo: other, number: 11),
            summary("PR_open_3", repo: repo, number: 12, author: human()),
        ])
        await wait(until: { model.hasLoaded })

        XCTAssertEqual(model.agents.count, 1, "one agent, and no row anywhere for the person")
        let agent = try XCTUnwrap(model.agents.first)
        XCTAssertEqual(agent.displayName, "Claude Code")
        XCTAssertEqual(agent.registryID, "claude-code", "the id travels on a live actor")
        XCTAssertEqual(agent.overall.merged, 2)
        XCTAssertEqual(agent.overall.closedUnmerged, 1)
        XCTAssertEqual(agent.overall.reverted, 1)
        XCTAssertEqual(agent.openCount, 2, "the person's open pull request is not this agent's")
        XCTAssertEqual(agent.openAwaitingReviewCount, 1)

        // And the page's "Open right now": grouped by repository, in the roster's own order.
        let groups = model.openPullRequests(for: agent)
        XCTAssertEqual(groups.map(\.repo.fullName), [repo.fullName, other.fullName])
        XCTAssertEqual(groups.first?.rows.map(\.id), ["PR_open_1"])
    }

    func testOneHistoryChangeIsOneReadOfTheOutcomeTable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestOutcomes([closed("PR_1", repo: repo, merged: true)])
        let reader = CountingReader(database: database)
        let model = FleetModel(reader: reader, now: { [clock] in clock })

        // Exactly what the screen does on `.onChange(of: trackRecord.historyVersion)`: one call.
        model.refresh(openRows: [])
        await wait(until: { model.hasLoaded })
        var reads = await reader.outcomeReads
        XCTAssertEqual(reads, 1, "one history change is one read of the whole window")

        // A second bump is a second refresh, and nothing else on the screen asks the table
        // anything — the notices and the grid are computed from the rows this read returned.
        model.refresh(openRows: [])
        await waitForReads(reader, atLeast: 2)
        // And a moment longer, so a stray third read would have had time to land.
        try? await Task.sleep(for: .milliseconds(30))
        reads = await reader.outcomeReads
        XCTAssertEqual(reads, 2, "and never more than one read per change")
    }

    // MARK: - The em-dash rule (plan §6.5)

    func testARepositoryWithNothingClosedShowsEmDashesAndMovesNoRate() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestOutcomes([
            closed("PR_1", repo: repo, merged: true, firstPushGreen: true, reviewRounds: 1),
            closed("PR_2", repo: repo, merged: true, firstPushGreen: true, reviewRounds: 1),
        ])
        let model = FleetModel(reader: database, now: { [clock] in clock })
        // The second repository exists only in the inbox: nothing of the agent's has closed there.
        model.refresh(openRows: [summary("PR_open_1", repo: other, number: 7)])
        await wait(until: { model.hasLoaded })

        let agent = try XCTUnwrap(model.agents.first)
        let empty = try XCTUnwrap(agent.repositories.first { $0.repo.fullName == other.fullName })
        XCTAssertTrue(empty.record.isEmpty)
        XCTAssertEqual(FleetCell.count(empty.record.merged, in: empty.record), FleetCell.absent)
        XCTAssertEqual(FleetCell.firstPush(empty.record), FleetCell.absent)
        XCTAssertEqual(FleetCell.rounds(empty.record), FleetCell.absent)
        XCTAssertNotEqual(FleetCell.firstPush(empty.record), "0 %", "never an invented rate")

        // And it is in no denominator: the aggregate is the counted repository's rate exactly.
        XCTAssertEqual(agent.overall.firstPushGreenPercent, 100)
        XCTAssertEqual(agent.overall.medianReviewRounds, 1)
        // While the open count on the same row stays a number — zero open is something Shepherd
        // knows rather than something it failed to count.
        XCTAssertEqual(empty.openCount, 1)
    }

    // MARK: - What a row says (ADR 0033)

    func testTheSpokenRowSaysEveryFactTheRowDrawsInTheOrderItDrawsThem() {
        let closedAt = clock.addingTimeInterval(-2 * 86_400)
        let agent = FleetAgent(
            displayName: "Claude Code",
            registryID: "claude-code",
            overall: TrackRecord(merged: 24, closedUnmerged: 2, reverted: 3),
            repositories: [
                FleetRepositoryRecord(repo: repo, record: TrackRecord(merged: 24)),
                FleetRepositoryRecord(repo: other, record: .empty),
            ],
            openCount: 7,
            openAwaitingReviewCount: 3,
            lastClosedAt: closedAt
        )

        XCTAssertEqual(
            FleetAgentRow.spokenSentence(for: agent),
            SpokenRow.sentence([
                "Claude Code",
                FleetAgentRow.openText(for: agent),
                String(localized: "\(24) merged"),
                String(localized: "\(3) reverted"),
                String(localized: "\(2) repositories"),
                String(localized: "last closed \(RelativeDate.long(closedAt))"),
            ]),
            "name, open, merged, reverted, repositories, last closed — the drawn order"
        )
        // The drawn lines and the spoken ones are the same strings, not two spellings of them.
        XCTAssertTrue(FleetAgentRow.spokenSentence(for: agent).contains(FleetAgentRow.openText(for: agent)))
        XCTAssertTrue(
            FleetAgentRow.closedText(for: agent).contains(String(localized: "\(24) merged"))
        )
    }

    func testTheEmDashIsSpokenAsWordsRatherThanAsPunctuation() {
        let agent = FleetAgent(
            displayName: "Example Agent",
            overall: .empty,
            repositories: [FleetRepositoryRecord(repo: repo, record: .empty, openCount: 2)],
            openCount: 2
        )
        XCTAssertTrue(
            FleetAgentRow.closedText(for: agent).hasPrefix(FleetCell.absent),
            "nothing counted draws a dash rather than a row of zeroes"
        )
        let spoken = FleetAgentRow.spokenSentence(for: agent)
        XCTAssertTrue(spoken.contains(FleetCell.absentSpoken))
        XCTAssertFalse(spoken.contains(FleetCell.absent), "a glyph is never the only carrier")
        XCTAssertFalse(
            spoken.contains(String(localized: "\(0) merged")),
            "'0 merged' is a claim about an agent nobody counted"
        )
    }

    // MARK: - The three sentences (plan §3)

    func testTheReworkStreakSentenceNamesTheRunTheAgentAndTheRepository() {
        XCTAssertEqual(
            FleetNoticeText.text(for: .reworkStreak(agent: "Claude Code", repo: repo, streak: 4)),
            String(
                localized: "The last \(4) pull requests \("Claude Code") closed in \(repo.fullName) all had changes requested at least once."
            )
        )
    }

    func testTheFirstPushGapSentenceCarriesBothRatesAndTheOtherRepositories() {
        let notice = FleetNotice.greenRateGap(
            agent: "Claude Code",
            repo: repo,
            greenHere: 9,
            totalHere: 20,
            greenElsewhere: 41,
            totalElsewhere: 50,
            otherRepositoryCount: 3
        )
        // The repository count is looked up as a clause of its own, so that the plural agreement
        // German needs can go through the catalog's variations (ADR 0022).
        let others = String(localized: "the other \(3) repositories Shepherd has counted")
        XCTAssertEqual(
            FleetNoticeText.text(for: notice),
            String(
                localized: "\("Claude Code")'s first push is green in \(TrackRecordBadge.percentText(45)) of its pull requests to \(repo.fullName), and in \(TrackRecordBadge.percentText(82)) across \(others)."
            )
        )
        // The rates are made here, from the counts the notice carries, so the sentence and the
        // grid below it cannot come apart.
        XCTAssertEqual(FleetNoticeText.percentText(9, of: 20), TrackRecordBadge.percentText(45))
        XCTAssertEqual(
            FleetNoticeText.percentText(0, of: 0),
            FleetCell.absent,
            "an empty denominator is never 0 %"
        )
    }

    func testThePairwiseRevertSentenceCarriesFourCountsAndBothNames() {
        let notice = FleetNotice.revertShareGap(
            repo: repo,
            higher: FleetNotice.RevertShare(agent: "Claude Code", reverted: 3, merged: 24),
            lower: FleetNotice.RevertShare(agent: "Example Agent", reverted: 0, merged: 19)
        )
        XCTAssertEqual(
            FleetNoticeText.text(for: notice),
            String(
                localized: "In \(repo.fullName), \(3) of \("Claude Code")'s \(24) merges were reverted; \(0) of \("Example Agent")'s \(19) were."
            )
        )
        XCTAssertFalse(
            FleetNoticeText.text(for: notice).contains("%"),
            "counts, not percentages — this is the one sentence that names two agents"
        )
    }

    // MARK: - Addressing an agent

    func testAnUnknownAgentIdSelectsNothingAndSaysSo() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.savePullRequestOutcomes([closed("PR_1", repo: repo, merged: true)])
        let model = FleetModel(reader: database, now: { [clock] in clock })

        model.request(agentID: "an-agent-that-left")
        model.refresh(openRows: [summary("PR_open_1", repo: repo, number: 3)])
        await wait(until: { model.hasLoaded })

        XCTAssertEqual(model.unknownAgentID, "an-agent-that-left")
        XCTAssertNil(model.selectedAgentID, "a stale link selects nothing")
        XCTAssertFalse(model.agents.isEmpty, "and the list is not filtered down to nothing")
    }

    func testAKnownAgentIdSelectsThatAgentAndClearsTheNote() async throws {
        let database = try DatabaseManager.inMemory()
        let model = FleetModel(reader: database, now: { [clock] in clock })

        // Asked for before anything has been counted, which is what a link that opens the window
        // does: the ask is remembered and answered by the first snapshot.
        model.request(agentID: "CLAUDE-CODE")
        model.refresh(openRows: [summary("PR_open_1", repo: repo, number: 3)])
        await wait(until: { model.hasLoaded })

        XCTAssertNil(model.unknownAgentID)
        XCTAssertEqual(model.selectedAgentID, "claude code", "case-insensitively, on the id")
        XCTAssertEqual(model.selectedAgent?.displayName, "Claude Code")
        XCTAssertEqual(
            model.selectedOpenPullRequestID,
            "PR_open_1",
            "Return opens the first of the agent's open pull requests"
        )
    }

    func testAFleetOfOneAgentOpensOnItAndStatesNoPairwiseNotice() async throws {
        let database = try DatabaseManager.inMemory()
        // Enough merges and reverts that the pairwise rule would fire if there were a second
        // agent to compare with. There is not, so the page states nothing rather than a
        // placeholder (plan §6.4).
        var rows: [ClosedPullRequest] = []
        for index in 0..<12 {
            rows.append(
                closed("PR_\(index)", repo: repo, merged: true, reverted: index < 4)
            )
        }
        try await database.savePullRequestOutcomes(rows)
        let model = FleetModel(reader: database, now: { [clock] in clock })

        model.refresh(openRows: [])
        await wait(until: { model.hasLoaded })

        XCTAssertEqual(model.agents.count, 1)
        let agent = try XCTUnwrap(model.agents.first)
        XCTAssertEqual(model.selectedAgentID, agent.id, "the one agent's page opens")
        XCTAssertFalse(
            model.notices(for: agent).contains {
                if case .revertShareGap = $0 { return true }
                return false
            },
            "one agent in a repository is a fact the grid above already states"
        )
    }

    // MARK: - The detection line

    func testTheDetectionLineNamesOnlyTheSignalsTheRegistryCarries() throws {
        let entry = AgentRegistryEntry(
            id: "claude-code",
            displayName: "Claude Code",
            loginPatterns: ["claude[bot]", "claude-*"],
            branchPrefixes: ["claude/"]
        )
        let line = try XCTUnwrap(FleetAgentDetail.detectionLine(for: entry))
        // Assembled from the same localised clauses rather than compared against English text:
        // `String(localized:)` resolves in the runner's own language, so what is worth asserting
        // is which clauses appear and in what order. The patterns themselves are not translated.
        let logins = String(localized: "logins \("claude[bot], claude-*")")
        let branches = String(localized: "branch prefixes \("claude/")")
        let signals = "\(logins) · \(branches)"
        XCTAssertEqual(line, String(localized: "Shepherd recognises this agent by \(signals)."))
        XCTAssertEqual(
            signals.components(separatedBy: " · ").count,
            2,
            "the entry names no commit trailer, so the line names none"
        )
    }

    func testARegistryEntryWithNoSignalsAtAllHasNoLine() {
        XCTAssertNil(
            FleetAgentDetail.detectionLine(
                for: AgentRegistryEntry(id: "ghost", displayName: "Ghost")
            ),
            "nothing truthful to say, so nothing is said"
        )
    }

    func testAnAgentOnlyHistoryKnowsHasNoDetectionLine() async throws {
        let database = try DatabaseManager.inMemory()
        let model = FleetModel(reader: database, now: { [clock] in clock })
        let agent = FleetAgent(displayName: "Claude Code", overall: TrackRecord(merged: 3))
        XCTAssertNil(agent.registryID, "the id travels on a live actor and nowhere else")
        XCTAssertNil(
            model.registryEntry(for: agent),
            "an agent nothing is open for can be named but not addressed"
        )
    }

    // MARK: - Fixtures

    /// Spins the main actor until a condition holds, or gives up.
    ///
    /// A short sleep rather than a bare `Task.yield()`: a refresh reads SQLite on the database's
    /// own executor and then counts in a detached task, so handing this actor back once is not by
    /// itself enough for the answer to have arrived.
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The same wait, against the counting double's own actor.
    ///
    /// A second helper rather than an `async` closure parameter, because the condition above
    /// touches main-actor state and this one hops to an actor: one signature cannot carry both
    /// isolations without erasing the one the compiler is checking.
    private func waitForReads(_ reader: CountingReader, atLeast count: Int) async {
        for _ in 0..<400 {
            if await reader.outcomeReads >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func agentActor(
        id: String = "claude-code",
        name: String = "Claude Code",
        login: String = "claude[bot]"
    ) -> ShepherdCore.Actor {
        ShepherdCore.Actor(
            login: login,
            kind: .agent(AgentIdentity(id: id, displayName: name, matchedBy: .login))
        )
    }

    private func human() -> ShepherdCore.Actor {
        ShepherdCore.Actor(login: "octocat", kind: .human)
    }

    private func summary(
        _ id: String,
        repo: RepoRef,
        number: Int,
        author: ShepherdCore.Actor? = nil,
        needsReview: Bool = false,
        updatedAt: Date? = nil
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: "Title \(number)",
            author: author ?? agentActor(),
            updatedAt: updatedAt ?? clock.addingTimeInterval(-3_600),
            createdAt: clock.addingTimeInterval(-7_200),
            headRefName: "claude/branch-\(number)",
            headRefOid: "sha-\(number)",
            baseRefName: "main",
            checkRollup: CheckRollup(state: .success, total: 2),
            myRelation: needsReview ? [.reviewRequested] : [.author]
        )
    }

    private func closed(
        _ id: String,
        repo: RepoRef,
        agentName: String? = "Claude Code",
        merged: Bool = true,
        reverted: Bool = false,
        firstPushGreen: Bool? = nil,
        reviewRounds: Int = 0
    ) -> ClosedPullRequest {
        ClosedPullRequest(
            outcome: PullRequestOutcome(
                prID: id,
                repo: repo,
                agentName: agentName,
                authorLogin: agentName == nil ? "octocat" : "claude[bot]",
                openedAt: clock.addingTimeInterval(-3 * 86_400),
                closedAt: clock.addingTimeInterval(-86_400),
                merged: merged,
                revertedByPRID: reverted ? "\(id)_revert" : nil,
                firstPushCIGreen: firstPushGreen,
                reviewRounds: reviewRounds,
                source: .backfill
            ),
            number: 1,
            title: "Closed \(id)"
        )
    }
}
