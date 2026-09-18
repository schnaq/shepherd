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
