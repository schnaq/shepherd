import Foundation
import XCTest

@testable import ShepherdCore

/// The badge's arithmetic (ADR 0027): counting, and never a score.
final class TrackRecordTests: XCTestCase {
    private let repo = Fixtures.repo
    private let other = RepoRef(owner: "schnaq", name: "konduit")

    // MARK: - Counting

    func testMergedClosedAndRevertedAreCountedSeparately() {
        let record = TrackRecord.compute(
            outcomes: [
                outcome("PR_1", merged: true),
                outcome("PR_2", merged: true, revertedBy: "PR_9"),
                outcome("PR_3", merged: false),
            ],
            agent: "Claude Code",
            repo: repo,
            since: Fixtures.date(-10_000)
        )
        XCTAssertEqual(record.merged, 2)
        XCTAssertEqual(record.closedUnmerged, 1)
        XCTAssertEqual(record.reverted, 1)
        XCTAssertEqual(record.total, 3)
        XCTAssertFalse(record.isEmpty)
    }

    func testARevertedPullRequestIsStillCountedAsMerged() {
        // It *was* merged; the revert is the second fact, not a correction of the first. A badge
        // that subtracted it would say "21 merged" about twenty-three merges.
        let record = TrackRecord.compute(
            outcomes: [outcome("PR_1", merged: true, revertedBy: "PR_2")],
            agent: "Claude Code",
            repo: repo,
            since: Fixtures.date(-10_000)
        )
        XCTAssertEqual(record.merged, 1)
        XCTAssertEqual(record.reverted, 1)
    }

    func testAnUnmergedPullRequestIsNeverCountedAsReverted() {
        let record = TrackRecord.compute(
            outcomes: [outcome("PR_1", merged: false, revertedBy: "PR_2")],
            agent: "Claude Code",
            repo: repo,
            since: Fixtures.date(-10_000)
        )
        XCTAssertEqual(record.closedUnmerged, 1)
        XCTAssertEqual(record.reverted, 0, "nothing was merged, so nothing was taken back out")
    }

    func testAnEmptyInputIsTheEmptyRecordAndShowsNoBadge() {
        let record = TrackRecord.compute(
            outcomes: [],
            agent: "Claude Code",
            repo: repo,
            since: Fixtures.date(0)
        )
        XCTAssertEqual(record, TrackRecord.empty)
        XCTAssertTrue(record.isEmpty)
        XCTAssertNil(record.firstPushGreenRate)
        XCTAssertNil(record.medianReviewRounds)
    }

    // MARK: - Filtering

    func testOutcomesOutsideTheWindowAreNotCounted() {
        let record = TrackRecord.compute(
            outcomes: [
                outcome("PR_1", merged: true, closedAt: -100),
                outcome("PR_2", merged: true, closedAt: -10_000),
            ],
            agent: "Claude Code",
            repo: repo,
            since: Fixtures.date(-1_000)
        )
        XCTAssertEqual(record.merged, 1)
    }

    func testTheWindowBoundaryIsInclusive() {
        let record = TrackRecord.compute(
            outcomes: [outcome("PR_1", merged: true, closedAt: -1_000)],
            agent: "Claude Code",
            repo: repo,
            since: Fixtures.date(-1_000)
        )
        XCTAssertEqual(record.merged, 1, "closed exactly at the cutoff still counts")
    }

    func testAnotherRepositorysOutcomesAreNotCounted() {
        let outcomes = [
            outcome("PR_1", merged: true),
            outcome("PR_2", merged: true, repo: other),
        ]
        XCTAssertEqual(
            TrackRecord.compute(
                outcomes: outcomes,
                agent: "Claude Code",
                repo: repo,
                since: Fixtures.date(-10_000)
            ).merged,
            1
        )
        XCTAssertEqual(
            TrackRecord.compute(
                outcomes: outcomes,
                agent: "Claude Code",
                repo: nil,
                since: Fixtures.date(-10_000)
            ).merged,
            2,
            "`nil` counts every repository, which is what the popover's wider view would use"
        )
    }

    func testTheRepositoryComparisonIgnoresCase() {
        let record = TrackRecord.compute(
            outcomes: [outcome("PR_1", merged: true, repo: RepoRef(owner: "Schnaq", name: "Review"))],
            agent: "Claude Code",
            repo: repo,
            since: Fixtures.date(-10_000)
        )
        XCTAssertEqual(record.merged, 1)
    }

    func testAnAgentsRecordAndAHumansDoNotShareAPullRequest() {
        let outcomes = [
            outcome("PR_1", merged: true, agent: "Claude Code", login: "octocat"),
            outcome("PR_2", merged: true, agent: nil, login: "octocat"),
        ]
        XCTAssertEqual(
            TrackRecord.compute(
                outcomes: outcomes,
                subject: .agent(name: "Claude Code"),
                repo: repo,
                since: Fixtures.date(-10_000)
            ).merged,
            1
        )
        XCTAssertEqual(
            TrackRecord.compute(
                outcomes: outcomes,
                subject: .author(login: "octocat"),
                repo: repo,
                since: Fixtures.date(-10_000)
            ).merged,
            1,
            "the pull request that carries an agent name belongs to the agent, not to the token"
        )
    }

    func testTheAgentNameComparisonIgnoresCase() {
        XCTAssertEqual(
            TrackRecord.compute(
                outcomes: [outcome("PR_1", merged: true, agent: "claude code")],
                subject: .agent(name: "Claude Code"),
                repo: repo,
                since: Fixtures.date(-10_000)
            ).merged,
            1
        )
    }

    func testTheSubjectOfAnAgentRowIsItsDisplayName() {
        let agentActor = Fixtures.makeActor(
            "claude[bot]",
            kind: Fixtures.agent("claude-code", "Claude Code")
        )
        XCTAssertEqual(TrackRecordSubject(actor: agentActor), .agent(name: "Claude Code"))
        XCTAssertEqual(
            TrackRecordSubject(actor: Fixtures.makeActor("octocat")),
            .author(login: "octocat")
        )
    }

    // MARK: - The first-push rate

    func testTheFirstPushRateCountsOnlyThePullRequestsThatSaidSomething() {
        let record = TrackRecord.compute(
            outcomes: [
                outcome("PR_1", merged: true, firstPushGreen: true),
                outcome("PR_2", merged: true, firstPushGreen: true),
                outcome("PR_3", merged: true, firstPushGreen: false),
                outcome("PR_4", merged: true, firstPushGreen: nil),
            ],
            agent: "Claude Code",
            repo: repo,
            since: Fixtures.date(-10_000)
        )
        XCTAssertEqual(record.firstPushGreenRate ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(record.firstPushGreenPercent, 67)
    }

    func testAnUnknownFirstPushIsNeverCountedAsARedOne() {
        let record = TrackRecord.compute(
            outcomes: [
                outcome("PR_1", merged: true, firstPushGreen: nil),
                outcome("PR_2", merged: true, firstPushGreen: nil),
            ],
            agent: "Claude Code",
            repo: repo,
            since: Fixtures.date(-10_000)
        )
        XCTAssertNil(
            record.firstPushGreenRate,
            "an empty denominator has no rate; the badge leaves the clause out"
        )
        XCTAssertNil(record.firstPushGreenPercent)
    }

    func testTheRateRoundsToWholePercent() {
        let record = TrackRecord(firstPushGreenRate: 0.785)
        XCTAssertEqual(record.firstPushGreenPercent, 79)
    }

    // MARK: - The median

    func testTheMedianOfAnOddCountIsTheMiddleValue() {
        XCTAssertEqual(TrackRecord.median(of: [0, 3, 1]), 1)
    }

    func testTheMedianOfAnEvenCountIsTheAverageOfTheTwoMiddleValues() {
        XCTAssertEqual(TrackRecord.median(of: [0, 1]), 0.5)
        XCTAssertEqual(TrackRecord.median(of: [4, 0, 2, 2]), 2)
    }

    func testTheMedianOfNothingIsNothing() {
        XCTAssertNil(TrackRecord.median(of: []))
    }

    func testANegativeRoundCountIsFloorEdAtZeroRatherThanSubtracting() {
        let record = TrackRecord.compute(
            outcomes: [outcome("PR_1", merged: true, reviewRounds: -3)],
            agent: "Claude Code",
            repo: repo,
            since: Fixtures.date(-10_000)
        )
        XCTAssertEqual(record.medianReviewRounds, 0)
    }

    // MARK: - The window

    func testTheWindowIsNinetyDays() {
        XCTAssertEqual(TrackRecord.windowDays, 90)
        let now = Fixtures.date(0)
        XCTAssertEqual(
            TrackRecord.windowStart(from: now).timeIntervalSince1970,
            now.timeIntervalSince1970 - 90 * 24 * 60 * 60,
            accuracy: 0.001
        )
    }

    // MARK: - Fixtures

    private func outcome(
        _ id: String,
        merged: Bool,
        repo: RepoRef? = nil,
        agent: String? = "Claude Code",
        login: String = "claude[bot]",
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
}
