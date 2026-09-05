import Foundation
import XCTest

@testable import ShepherdCore

/// The three sentences the fleet states unprompted, at both sides of every threshold.
final class FleetNoticeTests: XCTestCase {
    private let repo = Fixtures.repo
    private let konduit = RepoRef(owner: "schnaq", name: "konduit")
    private let alpha = RepoRef(owner: "schnaq", name: "alpha")
    private let since = Fixtures.date(-100_000)

    // MARK: - S1, the rework streak

    func testThreeReworkedPullRequestsInARowAreANotice() {
        let outcomes = (0..<3).map { reworked("PR_\($0)", closedAt: TimeInterval(-300 + $0)) }
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since),
            [.reworkStreak(agent: "Claude Code", repo: repo, streak: 3)]
        )
    }

    func testTwoReworkedPullRequestsInARowAreNotANotice() {
        // ADR 0029's three, borrowed for its reason: twice is a coincidence.
        let outcomes = [
            reworked("PR_1", closedAt: -100),
            reworked("PR_2", closedAt: -200),
            outcome("PR_3", closedAt: -300, reviewRounds: 0),
        ]
        XCTAssertTrue(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).isEmpty
        )
    }

    func testTheStreakStopsAtTheFirstPullRequestThatNeededNoRound() {
        let outcomes = [
            reworked("PR_1", closedAt: -100),
            reworked("PR_2", closedAt: -200),
            reworked("PR_3", closedAt: -300),
            outcome("PR_4", closedAt: -400, reviewRounds: 0),
            reworked("PR_5", closedAt: -500),
            reworked("PR_6", closedAt: -600),
        ]
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since),
            [.reworkStreak(agent: "Claude Code", repo: repo, streak: 3)],
            "the streak is a statement about now, so it ends at the first clean pull request"
        )
    }

    func testTheLongestStreakWinsWhenSeveralRepositoriesQualify() {
        let outcomes = (0..<3).map { reworked("PR_R\($0)", closedAt: TimeInterval(-300 + $0)) }
            + (0..<4).map {
                reworked("PR_K\($0)", repo: konduit, closedAt: TimeInterval(-400 + $0))
            }
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since),
            [.reworkStreak(agent: "Claude Code", repo: konduit, streak: 4)]
        )
    }

    func testEquallyLongStreaksAreBrokenByTheMostRecentClose() {
        let outcomes = (0..<3).map { reworked("PR_R\($0)", closedAt: TimeInterval(-300 + $0)) }
            + (0..<3).map {
                reworked("PR_K\($0)", repo: konduit, closedAt: TimeInterval(-200 + $0))
            }
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since),
            [.reworkStreak(agent: "Claude Code", repo: konduit, streak: 3)],
            "two streaks of three, so the one that closed last is the news"
        )
    }

    // MARK: - S2, the first-push gap

    func testOneRepositoryStandingOutAgainstTheOthersIsANotice() {
        let beta = RepoRef(owner: "schnaq", name: "beta")
        let gamma = RepoRef(owner: "schnaq", name: "gamma")
        let outcomes = firstPushes("PR_K", green: 9, total: 20, repo: konduit)
            + firstPushes("PR_A", green: 8, total: 10, repo: alpha)
            + firstPushes("PR_B", green: 8, total: 10, repo: beta)
            + firstPushes("PR_C", green: 9, total: 10, repo: gamma)
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since),
            [
                .greenRateGap(
                    agent: "Claude Code",
                    repo: konduit,
                    greenHere: 9,
                    totalHere: 20,
                    greenElsewhere: 25,
                    totalElsewhere: 30,
                    otherRepositoryCount: 3
                )
            ],
            "45 % here against 83 % across the other three, and the counts to check it with"
        )
    }

    func testAGapOfThirtyPointsIsANotice() {
        let outcomes = firstPushes("PR_R", green: 0, total: 5, repo: repo)
            + firstPushes("PR_K", green: 30, total: 100, repo: konduit)
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).count,
            1
        )
    }

    func testAGapOfTwentyNinePointsIsNotANotice() {
        let outcomes = firstPushes("PR_R", green: 0, total: 5, repo: repo)
            + firstPushes("PR_K", green: 29, total: 100, repo: konduit)
        XCTAssertTrue(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).isEmpty,
            "a gap the next pull request could erase is not worth stating unprompted"
        )
    }

    func testADenominatorOfFourIsTooSmallToCompare() {
        let outcomes = firstPushes("PR_R", green: 0, total: 4, repo: repo)
            + firstPushes("PR_K", green: 10, total: 10, repo: konduit)
        XCTAssertTrue(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).isEmpty,
            "four pull requests are one pull request away from a twenty-five point swing"
        )
    }

    func testADenominatorOfFiveIsEnoughToCompare() {
        let outcomes = firstPushes("PR_R", green: 0, total: 5, repo: repo)
            + firstPushes("PR_K", green: 10, total: 10, repo: konduit)
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).count,
            1
        )
    }

    func testAnUnknownFirstPushIsInNeitherNumeratorNorDenominator() {
        let outcomes = firstPushes("PR_R", green: 0, total: 5, repo: repo)
            + (0..<5).map { outcome("PR_U\($0)", firstPushGreen: nil) }
            + firstPushes("PR_K", green: 10, total: 10, repo: konduit)
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since),
            [
                .greenRateGap(
                    agent: "Claude Code",
                    repo: konduit,
                    greenHere: 10,
                    totalHere: 10,
                    greenElsewhere: 0,
                    totalElsewhere: 5,
                    otherRepositoryCount: 1
                )
            ],
            "the five pull requests that said nothing are in neither half of the other rate"
        )
    }

    func testTheGapNoticeCountsOnlyTheRepositoriesThatBackTheOtherRate() {
        let silent = RepoRef(owner: "schnaq", name: "silent")
        let outcomes = firstPushes("PR_R", green: 0, total: 5, repo: repo)
            + firstPushes("PR_A", green: 10, total: 10, repo: alpha)
            + (0..<10).map { outcome("PR_S\($0)", repo: silent, firstPushGreen: nil) }
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since),
            [
                .greenRateGap(
                    agent: "Claude Code",
                    repo: alpha,
                    greenHere: 10,
                    totalHere: 10,
                    greenElsewhere: 0,
                    totalElsewhere: 5,
                    otherRepositoryCount: 1
                )
            ],
            "a repository that says nothing about its first pushes backs no rate"
        )
    }

    // MARK: - S3, the pairwise revert share

    func testARevertShareGapNamesBothAgentsAndTheirCounts() {
        let outcomes = merges("PR_C", count: 20, reverted: 3)
            + merges("PR_N", count: 19, reverted: 0, agent: "Nightly Bot")
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since),
            [
                .revertShareGap(
                    repo: repo,
                    higher: FleetNotice.RevertShare(agent: "Claude Code", reverted: 3, merged: 20),
                    lower: FleetNotice.RevertShare(agent: "Nightly Bot", reverted: 0, merged: 19)
                )
            ]
        )
    }

    func testTheSameSentenceIsProducedForBothAgentsInvolved() {
        // The one cross-agent statement on the screen, and the thing that keeps it from being a
        // ranking: it is assembled from the repository's rows and never from whose page asked, so
        // the two agents read one sentence rather than two that could disagree.
        let outcomes = merges("PR_C", count: 20, reverted: 3)
            + merges("PR_N", count: 19, reverted: 0, agent: "Nightly Bot")
        let asked = FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since)
        let other = FleetNotices.detect(for: "Nightly Bot", outcomes: outcomes, since: since)
        XCTAssertFalse(asked.isEmpty)
        XCTAssertEqual(asked, other, "same pair, same roles, whichever page asked")
    }

    func testAnAgentThatIsNeitherSideOfThePairIsToldNothing() {
        let outcomes = merges("PR_C", count: 20, reverted: 3)
            + merges("PR_N", count: 19, reverted: 0, agent: "Nightly Bot")
            + merges("PR_M", count: 15, reverted: 1, agent: "Middle Bot")
        XCTAssertTrue(
            FleetNotices.detect(for: "Middle Bot", outcomes: outcomes, since: since).isEmpty,
            "a page naming two other agents would be a table of everybody, one page at a time"
        )
    }

    func testASingleAgentInARepositoryProducesNoPairwiseNotice() {
        XCTAssertTrue(
            FleetNotices.detect(
                for: "Claude Code",
                outcomes: merges("PR_C", count: 20, reverted: 5),
                since: since
            ).isEmpty,
            "one agent in a repository is not a pair, and the grid above already says this"
        )
    }

    func testNineMergesAreTooFewToBeComparedWithAnotherAgent() {
        let outcomes = merges("PR_C", count: 9, reverted: 3)
            + merges("PR_N", count: 20, reverted: 0, agent: "Nightly Bot")
        XCTAssertTrue(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).isEmpty,
            "at nine merges the arithmetic is about one pull request, not about a pattern"
        )
    }

    func testTenMergesAreEnoughToBeComparedWithAnotherAgent() {
        let outcomes = merges("PR_C", count: 10, reverted: 3)
            + merges("PR_N", count: 20, reverted: 0, agent: "Nightly Bot")
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).count,
            1
        )
    }

    func testOneRevertOnTheHigherSideIsNotEnough() {
        // Both guards refuse this one, which is the point of keeping the second: at ten merges a
        // single revert is ten points and cannot reach the gap either, so the reverts floor is
        // what would still hold if the gap were ever loosened.
        let outcomes = merges("PR_C", count: 10, reverted: 1)
            + merges("PR_N", count: 10, reverted: 0, agent: "Nightly Bot")
        XCTAssertTrue(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).isEmpty,
            "one merge taken back out is an incident; the sentence is about a tendency"
        )
    }

    func testTwoRevertsOnTheHigherSideAreEnough() {
        let outcomes = merges("PR_C", count: 10, reverted: 2)
            + merges("PR_N", count: 10, reverted: 0, agent: "Nightly Bot")
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since),
            [
                .revertShareGap(
                    repo: repo,
                    higher: FleetNotice.RevertShare(agent: "Claude Code", reverted: 2, merged: 10),
                    lower: FleetNotice.RevertShare(agent: "Nightly Bot", reverted: 0, merged: 10)
                )
            ]
        )
    }

    func testAShareGapBelowFifteenPointsIsNotANotice() {
        let outcomes = merges("PR_C", count: 20, reverted: 2)
            + merges("PR_N", count: 20, reverted: 0, agent: "Nightly Bot")
        XCTAssertTrue(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).isEmpty,
            "ten points is a difference that two more merges could close"
        )
    }

    func testARevertedPullRequestIsStillOneOfTheMergesItIsCountedAgainst() {
        // ADR 0027's rule, and the denominator rests on it: the pull request *was* merged, and
        // the revert is the second fact rather than a correction of the first.
        let outcomes = merges("PR_C", count: 10, reverted: 3)
            + merges("PR_N", count: 10, reverted: 0, agent: "Nightly Bot")
        XCTAssertEqual(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since),
            [
                .revertShareGap(
                    repo: repo,
                    higher: FleetNotice.RevertShare(agent: "Claude Code", reverted: 3, merged: 10),
                    lower: FleetNotice.RevertShare(agent: "Nightly Bot", reverted: 0, merged: 10)
                )
            ]
        )
    }

    // MARK: - The shape of the answer

    func testTheNoticesComeBackStreakFirstAndAtMostThree() {
        let reworkedAndReverted = (0..<20).map { index in
            outcome(
                "PR_R\(index)",
                closedAt: TimeInterval(-1_000 + index),
                revertedBy: index < 3 ? "PR_X\(index)" : nil,
                firstPushGreen: false,
                reviewRounds: 1
            )
        }
        let outcomes = reworkedAndReverted
            + firstPushes("PR_K", green: 10, total: 10, repo: konduit)
            + merges("PR_N", count: 19, reverted: 0, agent: "Nightly Bot")
        let notices = FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since)
        XCTAssertEqual(notices.count, 3, "three rules, one sentence each, and no fourth")
        guard notices.count == 3 else { return }
        if case .reworkStreak = notices[0] {} else { XCTFail("the streak comes first") }
        if case .greenRateGap = notices[1] {} else { XCTFail("then the first-push gap") }
        if case .revertShareGap = notices[2] {} else { XCTFail("then the pairwise sentence") }
    }

    func testOutcomesOlderThanTheWindowAreNotCounted() {
        // The store's query already cuts at the window; the rule is applied here as well, so the
        // function is correct on any input rather than only on the one the app happens to pass.
        let outcomes = [
            reworked("PR_1", closedAt: -100),
            reworked("PR_2", closedAt: -200),
            reworked("PR_3", closedAt: -100_001),
        ]
        XCTAssertTrue(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).isEmpty,
            "the oldest pull request is outside the window, so the streak is two"
        )
    }

    func testAnAgentWithNoHistoryIsToldNothing() {
        let outcomes = (0..<5).map { reworked("PR_\($0)", closedAt: TimeInterval(-$0)) }
        XCTAssertTrue(
            FleetNotices.detect(for: "Nightly Bot", outcomes: outcomes, since: since).isEmpty
        )
    }

    func testAnOutcomeWithoutAnAgentNameIsInNoNotice() {
        let outcomes = (0..<5).map {
            outcome("PR_\($0)", agent: nil, closedAt: TimeInterval(-$0), reviewRounds: 1)
        }
        XCTAssertTrue(
            FleetNotices.detect(for: "Claude Code", outcomes: outcomes, since: since).isEmpty,
            "a person's pull requests are counted nowhere on this screen"
        )
    }

    func testTheThresholdsAreTheDocumentedOnes() {
        XCTAssertEqual(FleetNotices.minimumReworkStreak, 3)
        XCTAssertEqual(FleetNotices.minimumFirstPushDenominator, 5)
        XCTAssertEqual(FleetNotices.minimumFirstPushGap, 0.30)
        XCTAssertEqual(FleetNotices.minimumMergesForRevertShare, 10)
        XCTAssertEqual(FleetNotices.minimumRevertShareGap, 0.15)
        XCTAssertEqual(FleetNotices.minimumRevertsOnTheHigherSide, 2)
    }

    // MARK: - Fixtures

    private func outcome(
        _ id: String,
        agent: String? = "Claude Code",
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
            authorLogin: "claude[bot]",
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

    /// One merged pull request that needed at least one round of requested changes.
    private func reworked(
        _ id: String,
        repo: RepoRef? = nil,
        closedAt: TimeInterval = 0
    ) -> PullRequestOutcome {
        outcome(id, repo: repo, closedAt: closedAt, reviewRounds: 1)
    }

    /// `count` merged pull requests, the first `reverted` of them taken back out again.
    private func merges(
        _ prefix: String,
        count: Int,
        reverted: Int,
        agent: String = "Claude Code",
        repo: RepoRef? = nil
    ) -> [PullRequestOutcome] {
        (0..<count).map { index in
            outcome(
                "\(prefix)_\(index)",
                agent: agent,
                repo: repo,
                closedAt: TimeInterval(index),
                revertedBy: index < reverted ? "\(prefix)_revert_\(index)" : nil
            )
        }
    }

    /// `total` pull requests that said something about their first push, `green` of them green.
    private func firstPushes(
        _ prefix: String,
        green: Int,
        total: Int,
        repo: RepoRef,
        agent: String = "Claude Code"
    ) -> [PullRequestOutcome] {
        (0..<total).map { index in
            outcome(
                "\(prefix)_\(index)",
                agent: agent,
                repo: repo,
                closedAt: TimeInterval(index),
                firstPushGreen: index < green
            )
        }
    }
}
