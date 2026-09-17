import Foundation
import ShepherdCore
import ShepherdSync
import SwiftUI
import XCTest

@testable import Shepherd

/// The inbox's half of the trust lanes (ADR 0027): which lane a row lands in once the cached diff
/// is taken into account, what the rail counts, and what the badge says.
final class TrustLaneUITests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let other = RepoRef(owner: "schnaq", name: "konduit")
    private let since = Date(timeIntervalSince1970: 1_000)

    // MARK: - The snapshot

    func testAGreenSmallRowWithACleanCachedDiffIsAShortLook() {
        let row = summary(id: "PR_1", checks: .success, files: 2, additions: 10, deletions: 5)
        let snapshot = TrustLaneLoader.snapshot(
            rows: [row],
            files: ["PR_1": [file("Sources/App/View.swift")]],
            outcomes: [],
            configuration: .default,
            since: since
        )
        XCTAssertEqual(snapshot.lane(for: "PR_1"), .shortLook)
    }

    func testARowWhoseDiffIsNotCachedIsAFullReview() {
        let row = summary(id: "PR_1", checks: .success, files: 1, additions: 1, deletions: 1)
        let snapshot = TrustLaneLoader.snapshot(
            rows: [row],
            files: [:],
            outcomes: [],
            configuration: .default,
            since: since
        )
        XCTAssertEqual(
            snapshot.lane(for: "PR_1"),
            .fullReview,
            "Shepherd cannot claim 'no sensitive path' about a diff it has never seen"
        )
    }

    func testACachedDiffWithASensitiveFileIsAFullReview() {
        let row = summary(id: "PR_1", checks: .success, files: 2, additions: 3, deletions: 1)
        let snapshot = TrustLaneLoader.snapshot(
            rows: [row],
            files: [
                "PR_1": [
                    file("Sources/App/View.swift"),
                    file(".github/workflows/ci.yml"),
                ]
            ],
            outcomes: [],
            configuration: .default,
            since: since
        )
        XCTAssertEqual(snapshot.lane(for: "PR_1"), .fullReview)
    }

    func testARowNothingHasBeenComputedForIsAFullReview() {
        XCTAssertEqual(TrustLaneSnapshot.empty.lane(for: "PR_unknown"), .fullReview)
        XCTAssertNil(TrustLaneSnapshot.empty.record(for: "PR_unknown"))
    }

    func testARecordIsCountedPerAuthorAndRepositoryAndIsAbsentWhenEmpty() {
        let rows = [
            summary(id: "PR_1", author: agent()),
            summary(id: "PR_2", author: agent()),
            summary(id: "PR_3", author: human()),
            summary(id: "PR_4", author: agent(), repo: other),
        ]
        let snapshot = TrustLaneLoader.snapshot(
            rows: rows,
            files: [:],
            outcomes: [
                outcome("PR_old_1", merged: true),
                outcome("PR_old_2", merged: true),
                outcome("PR_old_3", merged: false),
            ],
            configuration: .default,
            since: since
        )

        XCTAssertEqual(snapshot.record(for: "PR_1")?.merged, 2)
        XCTAssertEqual(
            snapshot.record(for: "PR_2")?.merged,
            2,
            "two rows of the same agent in the same repository share one count"
        )
        XCTAssertNil(snapshot.record(for: "PR_3"), "the human has no history, so no badge")
        XCTAssertNil(
            snapshot.record(for: "PR_4"),
            "the other repository has none of this agent's history"
        )
    }

    // MARK: - The rail

    func testTheFacetsCountEachLaneShortLaneFirst() {
        let rows = [
            summary(id: "PR_1", checks: .success, files: 1, additions: 1, deletions: 1),
            summary(id: "PR_2", checks: .success, files: 1, additions: 1, deletions: 1),
            summary(id: "PR_3", checks: .failure, files: 1, additions: 1, deletions: 1),
        ]
        let snapshot = TrustLaneLoader.snapshot(
            rows: rows,
            files: [
                "PR_1": [file("a.swift")],
                "PR_2": [file("b.swift")],
                "PR_3": [file("c.swift")],
            ],
            outcomes: [],
            configuration: .default,
            since: since
        )
        let facets = TrustLaneLoader.facets(rows: rows, snapshot: snapshot)

        XCTAssertEqual(facets.map(\.lane), [.shortLook, .fullReview])
        XCTAssertEqual(facets.map(\.count), [2, 1])
    }

    func testALaneNobodyIsInHasNoRailRow() {
        let rows = [summary(id: "PR_1", checks: .failure, files: 1, additions: 1, deletions: 1)]
        let snapshot = TrustLaneLoader.snapshot(
            rows: rows,
            files: ["PR_1": [file("a.swift")]],
            outcomes: [],
            configuration: .default,
            since: since
        )
        XCTAssertEqual(
            TrustLaneLoader.facets(rows: rows, snapshot: snapshot).map(\.lane),
            [.fullReview],
            "a rail row that filters to nothing is a dead control"
        )
        XCTAssertTrue(TrustLaneLoader.facets(rows: [], snapshot: snapshot).isEmpty)
    }

    func testTheTwoLanesHaveTheirOwnLabelAndTheirOwnTooltip() {
        // Compared against each other rather than against English text, like
        // ``StreamingDraftUITests``: `String(localized:)` resolves in the runner's own language,
        // and a test that spelled the English out would fail on a German Mac.
        XCTAssertFalse(TrustLane.shortLook.facetTitle.isEmpty)
        XCTAssertNotEqual(TrustLane.shortLook.facetTitle, TrustLane.fullReview.facetTitle)
        XCTAssertNotEqual(TrustLane.shortLook.railHelp, TrustLane.fullReview.railHelp)
    }

    // MARK: - The badge

    func testTheChipSaysTheMergedCountAndOnlyMentionsRevertsWhenThereAreSome() {
        // Assembled from the same localised clauses rather than compared against English text:
        // `String(localized:)` resolves in the runner's own language, so what is worth asserting
        // is *which* clauses appear and in what order.
        XCTAssertEqual(
            TrackRecordBadge.chipText(for: TrackRecord(merged: 23)),
            String(localized: "\(23) merged")
        )
        XCTAssertEqual(
            TrackRecordBadge.chipText(for: TrackRecord(merged: 23, reverted: 2)),
            "\(String(localized: "\(23) merged")) · \(String(localized: "\(2) reverted"))"
        )
    }

    func testTheBadgeSentenceIsTheShapeTheInterviewAskedFor() {
        let record = TrackRecord(
            merged: 23,
            closedUnmerged: 4,
            reverted: 2,
            firstPushGreenRate: 0.78,
            medianReviewRounds: 1
        )
        let sentence = TrackRecordBadge.sentence(authorName: "Claude Code", record: record)
        let clauses = sentence.components(separatedBy: " · ")

        XCTAssertEqual(clauses.count, 5, "name, repo, merged, reverted, first-push rate")
        XCTAssertEqual(clauses.first, "Claude Code", "the agent's own name leads")
        XCTAssertEqual(clauses[2], String(localized: "\(23) merged"))
        XCTAssertEqual(clauses[3], String(localized: "\(2) reverted"))
        XCTAssertTrue(clauses[4].contains("78 %"), "the rate is whole percent")
    }

    func testAClauseWithNothingToSayIsLeftOutRatherThanPrintedAsAZero() {
        let sentence = TrackRecordBadge.sentence(
            authorName: "Claude Code",
            record: TrackRecord(merged: 5)
        )
        let clauses = sentence.components(separatedBy: " · ")
        XCTAssertEqual(
            clauses.count,
            3,
            "no reverts and no measured first pushes means neither clause"
        )
        XCTAssertEqual(clauses[2], String(localized: "\(5) merged"))
        XCTAssertFalse(sentence.contains("%"), "a rate with an empty denominator is not invented")
    }

    // MARK: - The popover's way into the fleet (ADR 0035)

    func testOnlyAnAgentsBadgeCarriesAnIDIntoTheFleet() {
        // The gate, at the surface a reviewer actually clicks. A person and a generic bot both
        // answer `nil`, so the popover on their badge has no button — the fleet is a ledger of
        // agents, and there is deliberately no route from this row to a page about a colleague.
        XCTAssertEqual(
            TrackRecordBadge.fleetAgentID(
                for: ShepherdCore.Actor(
                    login: "claude[bot]",
                    kind: .agent(
                        AgentIdentity(
                            id: "claude-code",
                            displayName: "Claude Code",
                            matchedBy: .login
                        )
                    )
                )
            ),
            "claude-code"
        )
        XCTAssertNil(
            TrackRecordBadge.fleetAgentID(
                for: ShepherdCore.Actor(login: "christian", kind: .human)
            )
        )
        XCTAssertNil(
            TrackRecordBadge.fleetAgentID(
                for: ShepherdCore.Actor(login: "dependabot[bot]", kind: .bot)
            )
        )
    }

    func testTheRoundsTextDropsAPointlessDecimal() {
        XCTAssertEqual(TrackRecordBadge.roundsText(2), "2")
        XCTAssertEqual(TrackRecordBadge.roundsText(0.5), "0.5")
    }

    func testTheChipColourIsAmberForARevertGreenOnlyForASettledRecord() {
        XCTAssertEqual(TrackRecord(merged: 30, reverted: 1).chipTone, .reverted)
        XCTAssertEqual(TrackRecord(merged: 30, firstPushGreenRate: 0.9).chipTone, .settled)
        XCTAssertEqual(
            TrackRecord(merged: 3, firstPushGreenRate: 1).chipTone,
            .muted,
            "three merges are not evidence of anything"
        )
        XCTAssertEqual(TrackRecord(merged: 30, firstPushGreenRate: 0.2).chipTone, .muted)
        XCTAssertEqual(
            TrackRecord(merged: 30).chipTone,
            .muted,
            "no measured first push is not a settled record"
        )
    }

    // MARK: - The backfill's lines

    func testTheProgressLineNamesTheRepositoryAndTheEstimate() {
        let line = TrackRecordProgressLine.text(
            for: TrackRecordBackfillProgress(
                repo: RepoRef(owner: "schnaq", name: "konduit"),
                stored: 120,
                estimatedTotal: 340,
                repositoryIndex: 1,
                repositoryCount: 1
            )
        )
        XCTAssertTrue(line.hasPrefix("konduit"), "the repository's short name leads the line")
        XCTAssertTrue(line.contains("120"))
        XCTAssertTrue(line.contains("340"))
        XCTAssertFalse(
            line.contains(" · "),
            "one repository has no position to report"
        )
    }

    func testTheProgressLineAddsThePositionWhenThereIsMoreThanOneRepository() {
        let line = TrackRecordProgressLine.text(
            for: TrackRecordBackfillProgress(
                repo: RepoRef(owner: "schnaq", name: "konduit"),
                stored: 120,
                estimatedTotal: 340,
                repositoryIndex: 2,
                repositoryCount: 6
            )
        )
        let clauses = line.components(separatedBy: " · ")
        XCTAssertEqual(clauses.count, 2)
        XCTAssertTrue(clauses[1].contains("2"))
        XCTAssertTrue(clauses[1].contains("6"))
    }

    func testAFinishedRunSaysWhatItDidAndWhatItCouldNot() {
        let plain = TrackRecordProgressLine.text(for: TrackRecordBackfillResult(stored: 412))
        XCTAssertEqual(
            plain.components(separatedBy: " · ").count,
            1,
            "nothing was reverted, nothing was capped and nothing was stopped"
        )
        XCTAssertTrue(plain.contains("412"))

        let full = TrackRecordProgressLine.text(
            for: TrackRecordBackfillResult(
                stored: 500,
                revertsLinked: 3,
                cappedRepositories: [repo],
                wasCancelled: true
            )
        )
        XCTAssertEqual(
            full.components(separatedBy: " · ").count,
            4,
            "read, reverts matched, capped, stopped early"
        )
        XCTAssertTrue(full.contains("500"))
        XCTAssertTrue(full.contains("3"))
    }

    func testAFailedRepositoryIsOneLineInItsOwnWords() {
        let line = TrackRecordProgressLine.text(
            for: TrackRecordBackfillFailure(repo: repo, message: "no access")
        )
        XCTAssertTrue(line.hasPrefix("schnaq/review"))
        XCTAssertTrue(line.hasSuffix("no access"), "the server's own words end the line")
    }

    // MARK: - The inbox's one-time offer (ADR 0027's 2026-09-05 amendment)

    func testTheOfferIsMadeOnceTheSweepIsBackAndAnAgentHasWrittenSomething() {
        XCTAssertTrue(
            InboxModel.showsTrackRecordNotice(
                hasCompletedFirstSweep: true,
                rows: [summary(id: "PR_1", author: agent())],
                hasReadStoredCount: true,
                storedOutcomeCount: 0,
                isDismissed: false
            )
        )
    }

    func testAnInboxWithNoAgentInItIsNotOfferedAHistoryOfAgents() {
        XCTAssertFalse(
            InboxModel.showsTrackRecordNotice(
                hasCompletedFirstSweep: true,
                rows: [summary(id: "PR_1", author: human())],
                hasReadStoredCount: true,
                storedOutcomeCount: 0,
                isDismissed: false
            ),
            "the backfill would read five hundred pull requests per repository and badge nothing"
        )
    }

    func testACountThatHasNotBeenReadYetOffersNothing() {
        // The first body evaluation happens before the screen's `.task` has run, so the count is
        // still its initial zero — which is also what "nothing is stored" looks like. Offering on
        // it would flash the notice at an account that has a history and then take it away.
        XCTAssertFalse(
            InboxModel.showsTrackRecordNotice(
                hasCompletedFirstSweep: true,
                rows: [summary(id: "PR_1", author: agent())],
                hasReadStoredCount: false,
                storedOutcomeCount: 0,
                isDismissed: false
            ),
            "zero means nothing until somebody has counted"
        )
    }

    func testAStoredHistoryAnswersTheOfferByItself() {
        XCTAssertFalse(
            InboxModel.showsTrackRecordNotice(
                hasCompletedFirstSweep: true,
                rows: [summary(id: "PR_1", author: agent())],
                hasReadStoredCount: true,
                storedOutcomeCount: 412,
                isDismissed: false
            ),
            "the badges are already on the rows"
        )
    }

    func testAnAnsweredOfferIsNotMadeAgain() {
        XCTAssertFalse(
            InboxModel.showsTrackRecordNotice(
                hasCompletedFirstSweep: true,
                rows: [summary(id: "PR_1", author: agent())],
                hasReadStoredCount: true,
                storedOutcomeCount: 0,
                isDismissed: true
            )
        )
    }

    func testNothingIsOfferedBeforeTheFirstSweepHasComeBack() {
        // The empty-inbox case the loading state already covers, and the one under it: an inbox
        // that has rows but has not finished being swept is not yet a statement about anything.
        XCTAssertFalse(
            InboxModel.showsTrackRecordNotice(
                hasCompletedFirstSweep: false,
                rows: [],
                hasReadStoredCount: true,
                storedOutcomeCount: 0,
                isDismissed: false
            )
        )
        XCTAssertFalse(
            InboxModel.showsTrackRecordNotice(
                hasCompletedFirstSweep: false,
                rows: [summary(id: "PR_1", author: agent())],
                hasReadStoredCount: true,
                storedOutcomeCount: 0,
                isDismissed: false
            )
        )
    }

    @MainActor
    func testTheDismissalIsOffOnAFreshInstallAndSurvivesARelaunch() {
        let name = "com.schnaq.shepherd.tests.trackRecordNotice.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            return XCTFail("a fresh suite name always opens")
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let fresh = AppSettings(defaults: defaults)
        XCTAssertFalse(
            fresh.hasDismissedTrackRecordNotice,
            "an install that has never been offered the backfill has not answered"
        )

        fresh.hasDismissedTrackRecordNotice = true
        XCTAssertTrue(AppSettings(defaults: defaults).hasDismissedTrackRecordNotice)

        fresh.hasDismissedTrackRecordNotice = false
        XCTAssertFalse(AppSettings(defaults: defaults).hasDismissedTrackRecordNotice)
    }

    // MARK: - Fixtures

    private func summary(
        id: String,
        author: ShepherdCore.Actor? = nil,
        repo: RepoRef? = nil,
        checks: CheckRollup.State? = .success,
        files: Int = 1,
        additions: Int = 1,
        deletions: Int = 1
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo ?? self.repo,
            number: 1,
            title: "Title",
            author: author ?? agent(),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            createdAt: Date(timeIntervalSince1970: 1_500),
            additions: additions,
            deletions: deletions,
            changedFiles: files,
            headRefName: "claude/branch",
            headRefOid: "abc",
            baseRefName: "main",
            checkRollup: checks.map { CheckRollup(state: $0, total: 2) },
            myRelation: [.reviewRequested]
        )
    }

    private func agent() -> ShepherdCore.Actor {
        ShepherdCore.Actor(
            login: "claude[bot]",
            kind: .agent(
                AgentIdentity(id: "claude-code", displayName: "Claude Code", matchedBy: .login)
            )
        )
    }

    private func human() -> ShepherdCore.Actor {
        ShepherdCore.Actor(login: "octocat", kind: .human)
    }

    private func file(_ path: String) -> ChangedFile {
        ChangedFile(path: path, status: .modified, additions: 1, deletions: 1)
    }

    private func outcome(_ id: String, merged: Bool) -> PullRequestOutcome {
        PullRequestOutcome(
            prID: id,
            repo: repo,
            agentName: "Claude Code",
            authorLogin: "claude[bot]",
            openedAt: Date(timeIntervalSince1970: 1_100),
            closedAt: Date(timeIntervalSince1970: 1_200),
            merged: merged,
            source: .backfill
        )
    }
}
