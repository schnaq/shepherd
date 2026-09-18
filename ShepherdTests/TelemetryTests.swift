import Foundation
import XCTest

@testable import Shepherd

/// Usage telemetry (ADR 0036): the level, the identity, the heartbeat, the queue, the batch body,
/// and the gate that makes all of it absent rather than merely quiet.
///
/// Every test gets its own `UserDefaults` suite and its own temporary directory — never the real
/// Application Support folder — the same way `DiagnosticsTests` does.
@MainActor
final class TelemetryTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")
    private var createdSuites: [String] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-telemetry-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        for name in createdSuites {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        createdSuites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "shepherd-telemetry-tests-\(UUID().uuidString)"
        createdSuites.append(name)
        return UserDefaults(suiteName: name) ?? .standard
    }

    // MARK: - The level

    /// The default is the whole privacy story for a fresh install: anonymous *and* unacknowledged,
    /// so the mechanism stays inert until the notice has been seen.
    func testAFreshInstallIsAnonymousAndHasNotSeenTheNotice() {
        let defaults = makeDefaults()
        let fresh = AppSettings(defaults: defaults)

        XCTAssertEqual(fresh.telemetryLevel, .anonymous)
        XCTAssertFalse(fresh.telemetryNoticeAcknowledged)
    }

    func testTheLevelAndTheAcknowledgementSurviveARelaunch() {
        let defaults = makeDefaults()
        let fresh = AppSettings(defaults: defaults)

        fresh.telemetryLevel = .reach
        fresh.telemetryNoticeAcknowledged = true

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.telemetryLevel, .reach)
        XCTAssertTrue(reloaded.telemetryNoticeAcknowledged)
    }

    func testOnlyReachUsesAStoredIdentity() {
        XCTAssertFalse(TelemetryLevel.off.sendsEvents)
        XCTAssertTrue(TelemetryLevel.anonymous.sendsEvents)
        XCTAssertTrue(TelemetryLevel.reach.sendsEvents)

        XCTAssertFalse(TelemetryLevel.off.usesStoredIdentity)
        XCTAssertFalse(TelemetryLevel.anonymous.usesStoredIdentity)
        XCTAssertTrue(TelemetryLevel.reach.usesStoredIdentity)
    }
}

extension TelemetryTests {
    // MARK: - The vocabulary

    /// Buckets, not counts: "37 repositories" identifies better than "21+".
    func testCountsAreBucketedAndTheBucketsDoNotOverlap() {
        XCTAssertEqual(CountBucket(count: 0), .none)
        XCTAssertEqual(CountBucket(count: 1), .oneToThree)
        XCTAssertEqual(CountBucket(count: 3), .oneToThree)
        XCTAssertEqual(CountBucket(count: 4), .fourToTen)
        XCTAssertEqual(CountBucket(count: 10), .fourToTen)
        XCTAssertEqual(CountBucket(count: 11), .elevenPlus)
        XCTAssertEqual(CountBucket(count: 5_000), .elevenPlus)
    }

    func testTheDayIsUTCAndTheTimestampIsItsMidnight() {
        // 2026-09-18T23:30:00Z — an evening in UTC, already the 19th in Sydney and still the 18th
        // in Berlin. The day must follow UTC and nothing else, or two Macs disagree about "today".
        let evening = Date(timeIntervalSince1970: 1_789_774_200)
        XCTAssertEqual(TelemetryDay.utcDay(evening), "2026-09-18")
        XCTAssertEqual(TelemetryDay.dayStartTimestamp(evening), "2026-09-18T00:00:00Z")
    }

    /// The allow-list, enforced rather than described: every event's name and every choice it can
    /// carry has to come from an enum, so a repository name cannot reach the payload by accident.
    func testEveryChoiceInEveryEventComesFromItsEnum() {
        let allowed = Set(
            CountBucket.allCases.map(\.rawValue)
                + ReviewKind.allCases.map(\.rawValue)
                + MergeMethodChoice.allCases.map(\.rawValue)
                + MergeSource.allCases.map(\.rawValue)
                + DiffRendererChoice.allCases.map(\.rawValue)
                + IntelligenceChoice.allCases.map(\.rawValue)
                + SearchKind.allCases.map(\.rawValue)
                + DelegationTrigger.allCases.map(\.rawValue)
                + DelegationOutcomeChoice.allCases.map(\.rawValue)
                + IntelligenceFeature.allCases.map(\.rawValue)
                + IntelligenceTier.allCases.map(\.rawValue)
                + IntelligenceOutcomeChoice.allCases.map(\.rawValue)
                + AutoMergeOutcome.allCases.map(\.rawValue)
                + IssuesAction.allCases.map(\.rawValue)
                + FleetScope.allCases.map(\.rawValue)
                + DigestSource.allCases.map(\.rawValue)
                + TriageAction.allCases.map(\.rawValue)
        )

        for event in TelemetryEvent.allExamples {
            XCTAssertFalse(event.name.isEmpty)
            for (key, value) in event.properties {
                if case .choice(let raw) = value {
                    XCTAssertTrue(allowed.contains(raw), "\(event.name).\(key) carried \(raw)")
                }
            }
        }
    }

    func testTheEventNamesAreTheThirteenFromTheADR() {
        XCTAssertEqual(
            Set(TelemetryEvent.allExamples.map(\.name)),
            [
                "app_active_day", "review_submitted", "pull_request_merged",
                "focus_session_completed", "bulk_triage_performed", "search_used",
                "delegation_started", "delegation_finished", "intelligence_used",
                "auto_merge_rule_fired", "issues_inbox_used", "fleet_viewed", "digest_opened",
            ]
        )
    }
}
