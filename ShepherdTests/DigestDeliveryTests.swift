import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The app half of the morning digest: when a notification is actually posted, when the inbox card
/// appears, and when both of them stay quiet.
///
/// The *decisions* are tested in `ShepherdCoreTests/DigestTests.swift` — this covers the three
/// things only the app layer can get wrong: posting a banner for a night when nothing happened,
/// posting a second one the same day, and leaving yesterday's card above the list.
@MainActor
final class DigestDeliveryTests: XCTestCase {
    private var createdSuites: [String] = []

    override func tearDown() {
        for name in createdSuites {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        createdSuites = []
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Collects what the coordinator posted, and owns the clock it reads.
    @MainActor
    private final class Harness {
        var posted: [NotificationPayload] = []
        var clock = Date()
    }

    private func makeSettings() -> AppSettings {
        let name = "com.schnaq.shepherd.tests.digest.\(UUID().uuidString)"
        createdSuites.append(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("a fresh suite name always opens")
        }
        return AppSettings(defaults: defaults)
    }

    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func moment(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let parts = DateComponents(year: 2_026, month: 9, day: day, hour: hour, minute: minute)
        guard let date = berlin.date(from: parts) else {
            preconditionFailure("a valid gregorian date")
        }
        return date
    }

    /// A settings store with the digest armed for nine o'clock on weekdays.
    private func armedSettings() -> AppSettings {
        let settings = makeSettings()
        settings.digest = DigestSchedule(
            isEnabled: true,
            hour: 9,
            minute: 0,
            weekdaysOnly: true
        )
        return settings
    }

    private func makeCoordinator(
        settings: AppSettings,
        harness: Harness
    ) -> DigestCoordinator {
        DigestCoordinator(
            settings: settings,
            now: { harness.clock },
            calendar: berlin,
            notify: { harness.posted.append($0) }
        )
    }

    /// One pull request that needs the user's review, updated inside any plausible window.
    private func waitingRow(updatedAt: Date) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_waiting",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 182,
            title: "Fix the login redirect",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: updatedAt,
            createdAt: updatedAt,
            headRefName: "fix/login",
            headRefOid: "abc123",
            baseRefName: "main",
            myRelation: [.reviewRequested]
        )
    }

    private func inputs(at moment: Date) -> DigestInputs {
        DigestInputs(pullRequests: [waitingRow(updatedAt: moment)], parkedReviewCount: 0)
    }

    // MARK: - Off by default

    func testWithTheDigestSwitchedOffNothingIsPostedAndNothingIsRecorded() {
        let settings = makeSettings()
        XCTAssertFalse(settings.digest.isEnabled)
        let harness = Harness()
        harness.clock = moment(1, 11)
        let coordinator = makeCoordinator(settings: settings, harness: harness)

        XCTAssertNil(coordinator.check(source: { self.inputs(at: harness.clock) }))
        XCTAssertTrue(harness.posted.isEmpty)
        XCTAssertNil(coordinator.report)
        XCTAssertNil(settings.digestLastDeliveredAt)
    }

    // MARK: - A delivery

    func testADueDigestPostsOneNotificationAndPutsUpACard() throws {
        let settings = armedSettings()
        let harness = Harness()
        harness.clock = moment(1, 9)
        let coordinator = makeCoordinator(settings: settings, harness: harness)

        let delivered = try XCTUnwrap(
            coordinator.check(source: { self.inputs(at: self.moment(1, 2)) })
        )
        XCTAssertEqual(delivered.sections.map(\.kind), [.newReviewRequests])
        XCTAssertEqual(coordinator.report, delivered)
        XCTAssertEqual(settings.digestLastDeliveredAt, harness.clock)

        let payload = try XCTUnwrap(harness.posted.first)
        XCTAssertEqual(harness.posted.count, 1)
        XCTAssertEqual(payload.categoryIdentifier, NotificationCategory.digest)
        // The day is in the identifier, so one day's digest never replaces another's.
        XCTAssertEqual(payload.identifier, "digest-2026-09-01")
        XCTAssertEqual(payload.title, DigestPresentation.greeting)
        XCTAssertTrue(payload.body.contains("1 new review request"))
    }

    func testAQuietNightRecordsTheDeliveryButPostsNothing() {
        let settings = armedSettings()
        let harness = Harness()
        harness.clock = moment(1, 9)
        let coordinator = makeCoordinator(settings: settings, harness: harness)

        XCTAssertNil(
            coordinator.check(
                source: { DigestInputs(pullRequests: [], parkedReviewCount: 0) }
            )
        )
        XCTAssertTrue(harness.posted.isEmpty)
        XCTAssertNil(coordinator.report)
        // Recorded anyway: an empty digest is a delivered digest, or the check would run again
        // every minute for the rest of the day.
        XCTAssertEqual(settings.digestLastDeliveredAt, harness.clock)
    }

    func testTheDigestIsDeliveredOnlyOnceADayHoweverOftenTheCheckRuns() {
        let settings = armedSettings()
        let harness = Harness()
        harness.clock = moment(1, 9)
        let coordinator = makeCoordinator(settings: settings, harness: harness)

        for minute in 0..<5 {
            harness.clock = moment(1, 9, minute)
            coordinator.check(source: { self.inputs(at: self.moment(1, 2)) })
        }
        XCTAssertEqual(harness.posted.count, 1)
    }

    func testTheNextMorningDeliversAgain() {
        let settings = armedSettings()
        let harness = Harness()
        harness.clock = moment(1, 9)
        let coordinator = makeCoordinator(settings: settings, harness: harness)
        coordinator.check(source: { self.inputs(at: self.moment(1, 2)) })

        harness.clock = moment(2, 9)
        coordinator.check(source: { self.inputs(at: self.moment(2, 2)) })

        XCTAssertEqual(harness.posted.count, 2)
        XCTAssertEqual(
            harness.posted.map(\.identifier),
            ["digest-2026-09-01", "digest-2026-09-02"]
        )
    }

    // MARK: - The card

    func testDismissingTheCardDoesNotRedeliverTheDigest() {
        let settings = armedSettings()
        let harness = Harness()
        harness.clock = moment(1, 9)
        let coordinator = makeCoordinator(settings: settings, harness: harness)
        coordinator.check(source: { self.inputs(at: self.moment(1, 2)) })
        XCTAssertNotNil(coordinator.report)

        coordinator.dismiss()
        XCTAssertNil(coordinator.report)

        harness.clock = moment(1, 14)
        coordinator.check(source: { self.inputs(at: self.moment(1, 2)) })
        XCTAssertNil(coordinator.report)
        XCTAssertEqual(harness.posted.count, 1)
    }

    func testTheCardDisappearsWhenTheDayRollsOver() {
        let settings = armedSettings()
        let harness = Harness()
        harness.clock = moment(1, 9)
        let coordinator = makeCoordinator(settings: settings, harness: harness)
        coordinator.check(source: { self.inputs(at: self.moment(1, 2)) })
        XCTAssertNotNil(coordinator.report)

        // Just after midnight, before the next delivery is due.
        harness.clock = moment(2, 1)
        coordinator.check(source: { self.inputs(at: self.moment(2, 0)) })
        XCTAssertNil(coordinator.report)
        XCTAssertEqual(harness.posted.count, 1)
    }

    func testSwitchingTheDigestOffTakesTheCardWithIt() {
        let settings = armedSettings()
        let harness = Harness()
        harness.clock = moment(1, 9)
        let coordinator = makeCoordinator(settings: settings, harness: harness)
        coordinator.check(source: { self.inputs(at: self.moment(1, 2)) })
        XCTAssertNotNil(coordinator.report)

        var schedule = settings.digest
        schedule.isEnabled = false
        settings.digest = schedule
        harness.clock = moment(1, 10)
        coordinator.check(source: { self.inputs(at: self.moment(1, 2)) })
        XCTAssertNil(coordinator.report)
    }

    // MARK: - Nothing to read from yet

    func testATickBeforeTheInboxHasLoadedDeliversNothingAndLeavesTheDayOpen() {
        let settings = armedSettings()
        let harness = Harness()
        harness.clock = moment(1, 9)
        let coordinator = makeCoordinator(settings: settings, harness: harness)

        // No session, or the first `SELECT` has not come back: the source answers `nil`.
        XCTAssertNil(coordinator.check(source: { nil }))
        XCTAssertNil(settings.digestLastDeliveredAt)
        XCTAssertTrue(harness.posted.isEmpty)

        // A minute later the rows are there, and the digest is still due.
        harness.clock = moment(1, 9, 1)
        XCTAssertNotNil(coordinator.check(source: { self.inputs(at: self.moment(1, 2)) }))
        XCTAssertEqual(harness.posted.count, 1)
    }

    // MARK: - Sign-out

    func testResetForgetsWhatThisMacDeliveredButKeepsTheSchedule() {
        let settings = armedSettings()
        let harness = Harness()
        harness.clock = moment(1, 9)
        let coordinator = makeCoordinator(settings: settings, harness: harness)
        coordinator.check(source: { self.inputs(at: self.moment(1, 2)) })

        coordinator.reset()

        XCTAssertNil(coordinator.report)
        XCTAssertNil(settings.digestLastDeliveredAt)
        XCTAssertTrue(settings.digest.isEnabled)
    }

    // MARK: - Wording

    func testTheNotificationBodyNamesEverySectionOnce() {
        let report = DigestReport(
            windowStart: moment(1, 2),
            generatedAt: moment(1, 9),
            sections: [
                DigestReport.Section(kind: .newReviewRequests, count: 4, items: []),
                DigestReport.Section(kind: .greenAgentPullRequests, count: 2, items: []),
                DigestReport.Section(
                    kind: .ownPullRequestsNeedingAttention,
                    count: 1,
                    items: []
                ),
                DigestReport.Section(kind: .parkedReviews, count: 1, items: []),
                DigestReport.Section(kind: .failedWrites, count: 2, items: []),
            ]
        )
        XCTAssertEqual(
            DigestPresentation.summary(for: report),
            "4 new review requests · 2 green agent pull requests ready · "
                + "1 of your pull requests needs attention · 1 queued review was not sent · "
                + "2 queued writes were given up on"
        )
    }

    func testAWriteTheOutboxGaveUpOnIsItsOwnDigestLine() throws {
        // The digest runs while nobody is watching, and a failed write is the one outbox state
        // that is certainly not going to fix itself — so it gets a line of its own rather than
        // being summed into the parked one, which needs a different thing done about it.
        let settings = armedSettings()
        let harness = Harness()
        harness.clock = moment(1, 9)
        let coordinator = makeCoordinator(settings: settings, harness: harness)

        let delivered = try XCTUnwrap(
            coordinator.check(
                source: {
                    DigestInputs(
                        pullRequests: [],
                        parkedReviewCount: 1,
                        failedWriteCount: 1
                    )
                }
            )
        )
        XCTAssertEqual(delivered.sections.map(\.kind), [.parkedReviews, .failedWrites])
        let payload = try XCTUnwrap(harness.posted.first)
        XCTAssertTrue(payload.body.contains("1 queued write was given up on"))
    }

    func testAnEmptyReportProducesNoNotificationPayloadAtAll() {
        let empty = DigestReport(
            windowStart: moment(1, 2),
            generatedAt: moment(1, 9),
            sections: []
        )
        XCTAssertNil(
            NotificationManager.payload(forDigest: empty, dayStamp: "2026-09-01")
        )
    }
}
