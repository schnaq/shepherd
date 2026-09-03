import Foundation
import XCTest

@testable import ShepherdCore

/// What the morning digest says, and when it is delivered.
///
/// Both halves of the feature are pure functions and both are here, because both of them run
/// **unattended**: the digest decides on its own to interrupt somebody, and every awkward case —
/// a Mac that was asleep at nine, a Saturday, a clock that jumps, a first run with no history, an
/// inbox with nothing in it — is a case nobody would notice going wrong in a notification banner.
final class DigestTests: XCTestCase {
    // MARK: - Fixtures

    private static let agentAuthor = Fixtures.makeActor(
        "claude[bot]",
        kind: Fixtures.agent("claude-code", "Claude Code")
    )

    /// A pull request that asks for the user's review.
    private func waiting(
        id: String,
        number: Int = 1,
        updatedAt: TimeInterval = 0,
        title: String = "Fix the thing"
    ) -> PullRequestSummary {
        Fixtures.summary(
            id: id,
            number: number,
            title: title,
            updatedAt: updatedAt,
            relations: [.reviewRequested]
        )
    }

    /// A green, agent-authored pull request: checks passed, mergeable, nobody blocking it.
    private func greenAgent(
        id: String,
        number: Int = 10,
        updatedAt: TimeInterval = 0
    ) -> PullRequestSummary {
        Fixtures.summary(
            id: id,
            number: number,
            author: DigestTests.agentAuthor,
            updatedAt: updatedAt,
            checkRollup: CheckRollup(state: .success, total: 3, successCount: 3),
            relations: [.assigned]
        )
    }

    /// One of the user's own pull requests, with failing checks.
    private func ownRed(
        id: String,
        number: Int = 20,
        isDraft: Bool = false,
        updatedAt: TimeInterval = 0
    ) -> PullRequestSummary {
        Fixtures.summary(
            id: id,
            number: number,
            updatedAt: updatedAt,
            isDraft: isDraft,
            checkRollup: CheckRollup(state: .failure, total: 3, successCount: 2, failureCount: 1),
            relations: [.author]
        )
    }

    private func report(
        _ rows: [PullRequestSummary],
        issues: [IssueRowSummary] = [],
        parked: Int = 0,
        windowStart: TimeInterval = -3_600,
        now: TimeInterval = 0
    ) -> DigestReport {
        DigestReport.make(
            pullRequests: rows,
            issues: issues,
            parkedReviewCount: parked,
            windowStart: Fixtures.date(windowStart),
            now: Fixtures.date(now)
        )
    }

    /// One issue row (ADR 0032). Assigned to the user by default, because that is what the
    /// windowed line asks about.
    private func issue(
        id: String,
        number: Int = 1,
        title: String = "The login flow drops the session",
        updatedAt: TimeInterval = 0,
        relations: Set<IssueRelation> = [.assigned],
        state: IssueSummary.State = .open,
        stateReason: String? = nil,
        links: [LinkedPullRequestReference] = []
    ) -> IssueRowSummary {
        IssueRowSummary(
            id: id,
            repo: Fixtures.repo,
            number: number,
            title: title,
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            createdAt: Fixtures.date(-86_400),
            updatedAt: Fixtures.date(updatedAt),
            closedAt: state == .closed ? Fixtures.date(updatedAt) : nil,
            state: state,
            stateReason: stateReason,
            myRelation: relations,
            linkedPullRequests: links
        )
    }

    /// One linked pull request, machine-authored by default.
    private func link(
        number: Int = 90,
        author: ShepherdCore.Actor = DigestTests.agentAuthor
    ) -> LinkedPullRequestReference {
        LinkedPullRequestReference(
            repo: Fixtures.repo,
            number: number,
            title: "fix: the session drop",
            state: "MERGED",
            author: author
        )
    }

    // MARK: - Nothing to report

    func testAnEmptyDatabaseProducesAnEmptyReportAndThereforeNoNotification() {
        let built = report([])
        XCTAssertTrue(built.isEmpty)
        XCTAssertTrue(built.sections.isEmpty)
        XCTAssertEqual(built.totalCount, 0)
    }

    func testAnInboxFullOfThingsThatConcernNobodyProducesNothing() {
        let rows = [
            // Someone else's pull request, already approved, green.
            Fixtures.summary(
                id: "PR_other",
                checkRollup: CheckRollup(state: .success, total: 1, successCount: 1),
                relations: [.mentioned]
            ),
            // Review requested but already approved by the user: the rail drops it, so must this.
            Fixtures.summary(id: "PR_done", reviewDecision: .approved, relations: [.reviewRequested]),
        ]
        XCTAssertTrue(report(rows).isEmpty)
    }

    // MARK: - New review requests (the windowed section)

    func testOnlyReviewRequestsInsideTheWindowAreCountedAsNew() throws {
        let rows = [
            waiting(id: "PR_fresh", number: 1, updatedAt: -600),
            waiting(id: "PR_stale", number: 2, updatedAt: -7_200),
        ]
        let section = try XCTUnwrap(report(rows).section(.newReviewRequests))
        XCTAssertEqual(section.count, 1)
        XCTAssertEqual(section.items.map(\.prID), ["PR_fresh"])
    }

    func testARequestExactlyOnTheWindowBoundaryCounts() throws {
        let rows = [waiting(id: "PR_edge", updatedAt: -3_600)]
        let section = try XCTUnwrap(report(rows).section(.newReviewRequests))
        XCTAssertEqual(section.count, 1)
    }

    func testASectionNamesTheFirstFewAndCountsTheRest() throws {
        let rows = (1...7).map { index in
            waiting(
                id: "PR_\(index)",
                number: index,
                updatedAt: TimeInterval(-index * 60),
                title: "Title \(index)"
            )
        }
        let section = try XCTUnwrap(report(rows).section(.newReviewRequests))
        XCTAssertEqual(section.count, 7)
        // Most recently updated first — `InboxGrouper.sorted`, the inbox's own order.
        XCTAssertEqual(section.items.map(\.prID), ["PR_1", "PR_2", "PR_3"])
        XCTAssertEqual(section.items.first?.slug, "schnaq/review#1")
        XCTAssertEqual(section.items.first?.title, "Title 1")
        XCTAssertEqual(section.overflow, 4)
    }

    // MARK: - The standing sections

    func testGreenAgentPullRequestsAreReportedNoMatterHowOldTheyAre() throws {
        // Two weeks older than the window: still green, still unmerged, still one click from done.
        let rows = [greenAgent(id: "PR_green", updatedAt: -14 * 86_400)]
        let section = try XCTUnwrap(report(rows).section(.greenAgentPullRequests))
        XCTAssertEqual(section.count, 1)
        XCTAssertEqual(section.items.map(\.prID), ["PR_green"])
    }

    func testAHumansGreenPullRequestIsNotInTheAgentLine() {
        var human = greenAgent(id: "PR_human")
        human.author = Fixtures.makeActor("octocat")
        XCTAssertNil(report([human]).section(.greenAgentPullRequests))
    }

    func testARunningOrRedAgentPullRequestIsNotReadyAndIsNotReported() {
        var pending = greenAgent(id: "PR_pending")
        pending.checkRollup = CheckRollup(state: .pending, total: 2, pendingCount: 1)
        var draft = greenAgent(id: "PR_draft")
        draft.isDraft = true
        XCTAssertNil(report([pending, draft]).section(.greenAgentPullRequests))
    }

    func testOwnPullRequestsWithRedCIOrAChangeRequestAreReported() throws {
        var changesRequested = Fixtures.summary(
            id: "PR_changes",
            number: 21,
            relations: [.author]
        )
        changesRequested.reviewDecision = .changesRequested
        let rows = [ownRed(id: "PR_red", updatedAt: -60), changesRequested]
        let section = try XCTUnwrap(report(rows).section(.ownPullRequestsNeedingAttention))
        XCTAssertEqual(section.count, 2)
    }

    func testADraftOfMineWithRedCIIsNotNews() {
        XCTAssertNil(
            report([ownRed(id: "PR_wip", isDraft: true)])
                .section(.ownPullRequestsNeedingAttention)
        )
    }

    func testSomebodyElsesRedPullRequestIsNotMyProblem() {
        var theirs = ownRed(id: "PR_theirs")
        // Only mentioned — `AutoDelegationPolicy.isOwn` deliberately refuses this (ADR 0016).
        theirs.myRelation = [.mentioned]
        XCTAssertNil(report([theirs]).section(.ownPullRequestsNeedingAttention))
    }

    func testAnAgentPullRequestAssignedToMeCountsAsMyWorkWhenItGoesRed() throws {
        var delegated = ownRed(id: "PR_delegated")
        delegated.author = DigestTests.agentAuthor
        delegated.myRelation = [.assigned]
        let section = try XCTUnwrap(
            report([delegated]).section(.ownPullRequestsNeedingAttention)
        )
        XCTAssertEqual(section.count, 1)
    }

    // MARK: - Parked reviews

    func testParkedReviewsAreCountedWithoutNamingAnyPullRequest() throws {
        let section = try XCTUnwrap(report([], parked: 3).section(.parkedReviews))
        XCTAssertEqual(section.count, 3)
        XCTAssertTrue(section.items.isEmpty)
        XCTAssertEqual(section.overflow, 0)
    }

    func testNoParkedReviewsMeansNoLineAboutThem() {
        XCTAssertNil(report([], parked: 0).section(.parkedReviews))
    }

    // MARK: - Order

    func testTheSectionsAreAlwaysInTheSameOrder() {
        let rows = [
            ownRed(id: "PR_red", updatedAt: -60),
            greenAgent(id: "PR_green", updatedAt: -120),
            waiting(id: "PR_waiting", updatedAt: -180),
        ]
        let issues = [
            issue(id: "I_assigned", number: 5, updatedAt: -60),
            issue(
                id: "I_done",
                number: 6,
                updatedAt: -600,
                relations: [.authored],
                state: .closed,
                stateReason: "COMPLETED",
                links: [link()]
            ),
        ]
        XCTAssertEqual(
            report(rows, issues: issues, parked: 1).sections.map(\.kind),
            [
                .newReviewRequests,
                .issuesAssignedToYou,
                .greenAgentPullRequests,
                .agentPullRequestsThatClosedAnIssue,
                .ownPullRequestsNeedingAttention,
                .parkedReviews,
            ]
        )
    }

    func testOnlyTheTwoEventShapedLinesAreWindowed() {
        XCTAssertEqual(
            DigestSectionKind.allCases.filter(\.isWindowed),
            [.newReviewRequests, .issuesAssignedToYou]
        )
        XCTAssertEqual(
            DigestSectionKind.allCases.filter(\.isAboutIssues),
            [.issuesAssignedToYou, .agentPullRequestsThatClosedAnIssue]
        )
    }

    // MARK: - Issues assigned to you (the second windowed section, ADR 0032)

    func testOnlyIssuesAssignedToYouInsideTheWindowAreReported() throws {
        let rows = [
            issue(id: "I_fresh", number: 1, updatedAt: -600),
            issue(id: "I_stale", number: 2, updatedAt: -7_200),
            // Opened by the user, but nobody assigned it to them.
            issue(id: "I_mine", number: 3, updatedAt: -600, relations: [.authored]),
        ]
        let section = try XCTUnwrap(report([], issues: rows).section(.issuesAssignedToYou))
        XCTAssertEqual(section.count, 1)
        XCTAssertEqual(section.items.map(\.prID), ["I_fresh"])
        XCTAssertEqual(section.items.map(\.slug), ["schnaq/review#1"])
    }

    func testAnIssueExactlyOnTheWindowBoundaryCounts() throws {
        let section = try XCTUnwrap(
            report([], issues: [issue(id: "I_edge", updatedAt: -3_600)])
                .section(.issuesAssignedToYou)
        )
        XCTAssertEqual(section.count, 1)
    }

    func testQuietOnTheSecondMorningIsTheCorrectAnswerForTheAssignedLine() {
        // Nothing happened overnight: the issue is still assigned, still open, and was last
        // touched before this digest's window. A line about it would be the same line as
        // yesterday's, which is what a windowed section exists to avoid.
        let rows = [issue(id: "I_yesterday", updatedAt: -90_000)]
        XCTAssertNil(report([], issues: rows).section(.issuesAssignedToYou))
    }

    func testTheAssignedLineNamesTheMostRecentlyUpdatedFirstAndCountsTheRest() throws {
        let rows = [
            issue(id: "I_c", number: 3, updatedAt: -900),
            issue(id: "I_a", number: 1, updatedAt: -60),
            issue(id: "I_b", number: 2, updatedAt: -300),
            issue(id: "I_d", number: 4, updatedAt: -1_200),
        ]
        let section = try XCTUnwrap(report([], issues: rows).section(.issuesAssignedToYou))
        XCTAssertEqual(section.count, 4)
        XCTAssertEqual(section.items.map(\.prID), ["I_a", "I_b", "I_c"])
        XCTAssertEqual(section.overflow, 1)
    }

    func testTwoIssuesUpdatedInTheSameSecondKeepAStableOrder() throws {
        let rows = [
            issue(id: "I_two", number: 12, updatedAt: -60),
            issue(id: "I_one", number: 11, updatedAt: -60),
        ]
        let section = try XCTUnwrap(report([], issues: rows).section(.issuesAssignedToYou))
        XCTAssertEqual(
            section.items.map(\.prID),
            ["I_one", "I_two"],
            "the tie-break is repository then number, so two digests agree"
        )
    }

    // MARK: - Issues an agent closed (the state-shaped section, ADR 0032)

    func testAnIssueAnAgentPullRequestClosedAsCompletedIsReported() throws {
        let rows = [
            issue(
                id: "I_done",
                number: 7,
                updatedAt: -600,
                state: .closed,
                stateReason: "COMPLETED",
                links: [link()]
            )
        ]
        let section = try XCTUnwrap(
            report([], issues: rows).section(.agentPullRequestsThatClosedAnIssue)
        )
        XCTAssertEqual(section.count, 1)
        XCTAssertEqual(section.items.map(\.prID), ["I_done"])
    }

    func testThatStateSurvivesTheNight() {
        // Closed long before this digest's window, and still reported: it is a state, not an
        // event, so a windowed version would go quiet exactly because nothing had been done
        // about it. It stops repeating by itself because the row does not live forever: the
        // sweep captures the close onto it and prunes it once its retention window runs out
        // (ADR 0032's 2026-09-03 amendment).
        let rows = [
            issue(
                id: "I_old",
                number: 8,
                updatedAt: -900_000,
                state: .closed,
                stateReason: "completed",
                links: [link()]
            )
        ]
        XCTAssertNotNil(
            report([], issues: rows).section(.agentPullRequestsThatClosedAnIssue)
        )
    }

    func testNotPlannedIsNotAnAgentsSuccessAndNeitherIsAHumansFix() {
        let notPlanned = issue(
            id: "I_wontfix",
            number: 9,
            state: .closed,
            stateReason: "not_planned",
            links: [link()]
        )
        let humanFix = issue(
            id: "I_human",
            number: 10,
            state: .closed,
            stateReason: "completed",
            links: [link(number: 91, author: Fixtures.makeActor("octocat", kind: .human))]
        )
        let stillOpen = issue(
            id: "I_open",
            number: 11,
            stateReason: "completed",
            links: [link(number: 92)]
        )
        let noLinks = issue(id: "I_none", number: 12, state: .closed, stateReason: "completed")
        XCTAssertNil(
            report([], issues: [notPlanned, humanFix, stillOpen, noLinks])
                .section(.agentPullRequestsThatClosedAnIssue)
        )
        XCTAssertFalse(DigestReport.wasClosedByAnAgent(notPlanned))
        XCTAssertFalse(DigestReport.wasClosedByAnAgent(humanFix))
        XCTAssertFalse(DigestReport.wasClosedByAnAgent(stillOpen))
        XCTAssertFalse(DigestReport.wasClosedByAnAgent(noLinks))
    }

    func testTheClosedReasonIsMatchedCaseInsensitivelyBecauseItIsGitHubsRawWord() {
        for spelling in ["COMPLETED", "completed", "Completed"] {
            let row = issue(
                id: "I_\(spelling)",
                number: 13,
                state: .closed,
                stateReason: spelling,
                links: [link()]
            )
            XCTAssertTrue(DigestReport.wasClosedByAnAgent(row), "\(spelling) is closed as done")
        }
    }

    func testAnAccountWithIssuesAndNothingToSayAboutThemStaysSilent() {
        XCTAssertTrue(
            report([], issues: [issue(id: "I_quiet", updatedAt: -90_000, relations: [.mentioned])])
                .isEmpty
        )
    }

    func testAReportBuiltWithoutIssuesIsTheReportItAlwaysWas() {
        // The `issues:` parameter defaults to none, which is what keeps every call site that
        // predates the issues inbox both compiling and correct.
        let built = DigestReport.make(
            pullRequests: [waiting(id: "PR_1", updatedAt: -60)],
            parkedReviewCount: 0,
            windowStart: Fixtures.date(-3_600),
            now: Fixtures.date(0)
        )
        XCTAssertEqual(built.sections.map(\.kind), [.newReviewRequests])
    }

    // MARK: - Schedule fixtures

    /// A calendar with a fixed time zone, so nothing here depends on the machine it runs on.
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// A local moment in ``berlin``.
    private func moment(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0
    ) -> Date {
        let parts = DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        guard let date = berlin.date(from: parts) else {
            preconditionFailure("a valid gregorian date")
        }
        return date
    }

    private func schedule(
        isEnabled: Bool = true,
        hour: Int = 9,
        minute: Int = 0,
        weekdaysOnly: Bool = true
    ) -> DigestSchedule {
        DigestSchedule(
            isEnabled: isEnabled,
            hour: hour,
            minute: minute,
            weekdaysOnly: weekdaysOnly
        )
    }

    // MARK: - Schedule: the master switch

    func testWithTheDigestSwitchedOffNothingIsEverDue() {
        // Tuesday, well past nine, never delivered — every other condition says yes.
        XCTAssertNil(
            schedule(isEnabled: false).window(
                now: moment(2026, 9, 1, 11),
                lastDeliveredAt: nil,
                calendar: berlin
            )
        )
    }

    // MARK: - Schedule: time of day

    func testBeforeTheDeliveryTimeNothingIsDue() {
        XCTAssertNil(
            schedule().window(
                now: moment(2026, 9, 1, 8, 59),
                lastDeliveredAt: nil,
                calendar: berlin
            )
        )
    }

    func testTheFirstDigestEverLooksBackSixteenHours() throws {
        let now = moment(2026, 9, 1, 9)
        let window = try XCTUnwrap(
            schedule().window(now: now, lastDeliveredAt: nil, calendar: berlin)
        )
        XCTAssertTrue(window.isFirstEver)
        XCTAssertEqual(window.end, now)
        XCTAssertEqual(window.start, now.addingTimeInterval(-DigestSchedule.firstWindow))
        // 09:00 minus sixteen hours is 17:00 the previous day — "since you stopped working".
        XCTAssertEqual(berlin.component(.hour, from: window.start), 17)
    }

    func testADigestMissedBecauseTheMacWasAsleepIsDeliveredLaterTheSameDay() throws {
        // Nine o'clock passed with the lid shut; the check runs at 11:30.
        let window = try XCTUnwrap(
            schedule().window(
                now: moment(2026, 9, 1, 11, 30),
                lastDeliveredAt: moment(2026, 8, 31, 9),
                calendar: berlin
            )
        )
        XCTAssertFalse(window.isFirstEver)
        XCTAssertEqual(window.start, moment(2026, 8, 31, 9))
    }

    func testOnlyOneDigestADayEvenAfterTheDeliveryTimeIsMovedForward() {
        // Delivered at 07:00, then the user changes the schedule to 09:00 the same morning.
        XCTAssertNil(
            schedule(hour: 9).window(
                now: moment(2026, 9, 1, 12),
                lastDeliveredAt: moment(2026, 9, 1, 7),
                calendar: berlin
            )
        )
    }

    func testADigestAlreadyDeliveredTodayIsNotDeliveredAgain() {
        XCTAssertNil(
            schedule().window(
                now: moment(2026, 9, 1, 17),
                lastDeliveredAt: moment(2026, 9, 1, 9),
                calendar: berlin
            )
        )
    }

    func testTheNextDayIsDueAgainAndReportsOnTheSpanSinceTheLastOne() throws {
        let window = try XCTUnwrap(
            schedule().window(
                now: moment(2026, 9, 2, 9),
                lastDeliveredAt: moment(2026, 9, 1, 9),
                calendar: berlin
            )
        )
        XCTAssertEqual(window.start, moment(2026, 9, 1, 9))
        XCTAssertEqual(window.end, moment(2026, 9, 2, 9))
    }

    // MARK: - Schedule: weekends

    func testWeekdaysOnlySkipsSaturdayAndSunday() {
        for day in [5, 6] {
            XCTAssertNil(
                schedule(weekdaysOnly: true).window(
                    now: moment(2026, 9, day, 10),
                    lastDeliveredAt: moment(2026, 9, 4, 9),
                    calendar: berlin
                ),
                "2026-09-\(day) is a weekend day"
            )
        }
    }

    func testWithoutWeekdaysOnlyTheWeekendGetsItsDigestToo() throws {
        let window = try XCTUnwrap(
            schedule(weekdaysOnly: false).window(
                now: moment(2026, 9, 5, 10),
                lastDeliveredAt: moment(2026, 9, 4, 9),
                calendar: berlin
            )
        )
        XCTAssertEqual(window.start, moment(2026, 9, 4, 9))
    }

    func testAFridayDigestSkippedOverTheWeekendIsNotCaughtUpButMondayCoversTheSpan() throws {
        // Friday's digest was delivered; Saturday and Sunday were skipped above. Monday reports on
        // everything since Friday rather than delivering three digests.
        let window = try XCTUnwrap(
            schedule(weekdaysOnly: true).window(
                now: moment(2026, 9, 7, 9),
                lastDeliveredAt: moment(2026, 9, 4, 9),
                calendar: berlin
            )
        )
        XCTAssertEqual(window.start, moment(2026, 9, 4, 9))
    }

    // MARK: - Schedule: odd inputs

    func testAWindowIsNeverLongerThanAWeek() throws {
        let now = moment(2026, 9, 1, 9)
        let window = try XCTUnwrap(
            schedule().window(
                now: now,
                lastDeliveredAt: moment(2026, 6, 1, 9),
                calendar: berlin
            )
        )
        XCTAssertEqual(window.start, now.addingTimeInterval(-DigestSchedule.maxWindow))
    }

    func testALastDeliveryInTheFutureIsTreatedAsAlreadyDelivered() {
        // A clock that was moved backwards, or a settings restore from a Mac ahead of this one.
        XCTAssertNil(
            schedule().window(
                now: moment(2026, 9, 1, 9),
                lastDeliveredAt: moment(2026, 9, 4, 9),
                calendar: berlin
            )
        )
    }

    func testAnOutOfRangeTimeFromAnotherBuildStillDeliversAtASaneHour() throws {
        var absurd = schedule()
        absurd.hour = 99
        absurd.minute = -5
        XCTAssertEqual(absurd.normalizedHour, 23)
        XCTAssertEqual(absurd.normalizedMinute, 0)
        let due = try XCTUnwrap(absurd.deliveryTime(on: moment(2026, 9, 1, 9), calendar: berlin))
        XCTAssertEqual(berlin.component(.hour, from: due), 23)
        XCTAssertEqual(berlin.component(.minute, from: due), 0)
    }

    func testTheDeliveryTimeIsLocalToTheCalendarsTimeZone() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let berlinNine = try XCTUnwrap(
            schedule().deliveryTime(on: moment(2026, 9, 1, 12), calendar: berlin)
        )
        let utcNine = try XCTUnwrap(
            schedule().deliveryTime(on: moment(2026, 9, 1, 12), calendar: utc)
        )
        // Berlin is UTC+2 in September, so its nine o'clock is two hours earlier in absolute time.
        XCTAssertEqual(utcNine.timeIntervalSince(berlinNine), 2 * 3_600)
    }

    // MARK: - Schedule: storage

    func testAScheduleFromAnOlderBuildKeepsItsOwnValuesAndDefaultsTheRest() throws {
        let json = Data(#"{"isEnabled":true,"hour":7}"#.utf8)
        let decoded = try JSONDecoder().decode(DigestSchedule.self, from: json)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.hour, 7)
        XCTAssertEqual(decoded.minute, DigestSchedule.defaultMinute)
        // The absent key falls back to the quieter setting, which is what a fresh install has.
        XCTAssertTrue(decoded.weekdaysOnly)
    }

    func testAnUnreadableScheduleDecodesAsSwitchedOffRatherThanThrowing() throws {
        let json = Data(#"{"isEnabled":"yes","hour":"nine"}"#.utf8)
        let decoded = try JSONDecoder().decode(DigestSchedule.self, from: json)
        XCTAssertFalse(decoded.isEnabled)
        XCTAssertEqual(decoded.hour, DigestSchedule.defaultHour)
    }

    func testAScheduleRoundTripsThroughItsOwnCodec() throws {
        let original = DigestSchedule(
            isEnabled: true,
            hour: 6,
            minute: 45,
            weekdaysOnly: false
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(DigestSchedule.self, from: data), original)
    }
}
