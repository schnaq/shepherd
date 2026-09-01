import Foundation
import XCTest

@testable import Shepherd

/// The local diagnostics folder (ADR 0017): file names, retention, counting, deletion, and the
/// opt-in that gates all of it.
///
/// `MXDiagnosticPayload` cannot be constructed — there is no initialiser and no way to fake one —
/// so the seam under test is the one `DiagnosticsReporter` calls: JSON bytes plus the moment the
/// payload covers. Everything above that line is a four-line adapter; everything that can actually
/// be wrong about the feature is here.
///
/// Every test gets its own folder under the temporary directory — never the real Application
/// Support one — and `tearDown` removes it, the same way `SettingsSyncTests` gets a fresh
/// `UserDefaults` suite per test.
@MainActor
final class DiagnosticsTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")
    private var store = DiagnosticsStore()
    private var createdSuites: [String] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "shepherd-diagnostics-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        store = DiagnosticsStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        for name in createdSuites {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        createdSuites = []
        super.tearDown()
    }

    // MARK: - Fixtures

    /// `2026-09-01T10:15:00Z`, the same moment the settings-sync fixtures use.
    private let receivedAt = Date(timeIntervalSince1970: 1_788_257_700)

    private func payload(_ marker: String) -> Data {
        Data(#"{"crashDiagnostics":[{"marker":"\#(marker)"}]}"#.utf8)
    }

    private var storedNames: [String] {
        store.reportURLs().map(\.lastPathComponent)
    }

    // MARK: - Names

    /// The name has to be a pure function of the date: it is what orders the folder, and therefore
    /// what decides which report a trim drops.
    func testTheFileNameIsTheUTCTimestampAndNothingElse() {
        XCTAssertEqual(
            DiagnosticsStore.fileName(receivedAt: receivedAt),
            "diagnostic-2026-09-01-101500Z.json"
        )
        XCTAssertEqual(
            DiagnosticsStore.fileName(receivedAt: Date(timeIntervalSince1970: 0)),
            "diagnostic-1970-01-01-000000Z.json"
        )
        // Every component is zero-padded, so names are fixed width and sort chronologically.
        // `2026-01-01T01:04:05Z`.
        XCTAssertEqual(
            DiagnosticsStore.fileName(receivedAt: Date(timeIntervalSince1970: 1_767_229_445)),
            "diagnostic-2026-01-01-010405Z.json"
        )
        // The expectations above are UTC literals, so they also pin the second half of the
        // promise: a Mac in Tokyo and one in Berlin name the same report identically, which a
        // `DateFormatter` would not have given us.
    }

    func testOnlyOurOwnFilesAreRecognisedAsReports() {
        XCTAssertTrue(DiagnosticsStore.isReportFileName("diagnostic-2026-09-01-101500Z.json"))
        XCTAssertFalse(DiagnosticsStore.isReportFileName("notes.json"))
        XCTAssertFalse(DiagnosticsStore.isReportFileName("diagnostic-2026-09-01-101500Z.txt"))
        XCTAssertFalse(DiagnosticsStore.isReportFileName(".DS_Store"))
    }

    // MARK: - Writing

    func testStoringWritesTheBytesVerbatimUnderTheTimestampedName() throws {
        let bytes = payload("one")
        let url = try store.store(jsonRepresentation: bytes, receivedAt: receivedAt)

        XCTAssertEqual(url.lastPathComponent, "diagnostic-2026-09-01-101500Z.json")
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL,
            directory.standardizedFileURL
        )
        // Verbatim: Shepherd does not re-encode a payload, so what is on disk is what MetricKit
        // produced and what a user can paste into an issue.
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(store.reportCount, 1)
    }

    func testTheFolderIsCreatedOnDemandRatherThanAtLaunch() throws {
        // Nothing exists before the first report: an install that never crashed has no folder,
        // and the count says zero instead of throwing.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(store.reportCount, 0)
        XCTAssertTrue(store.reportURLs().isEmpty)
        XCTAssertNil(store.newestReportURL)

        try store.store(jsonRepresentation: payload("one"), receivedAt: receivedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// MetricKit delivers a batch, and two payloads in one batch can share a second. Neither may
    /// overwrite the other.
    func testTwoReportsFromTheSameSecondBothSurvive() throws {
        try store.store(jsonRepresentation: payload("one"), receivedAt: receivedAt)
        try store.store(jsonRepresentation: payload("two"), receivedAt: receivedAt)

        XCTAssertEqual(store.reportCount, 2)
        XCTAssertEqual(
            Set(storedNames),
            ["diagnostic-2026-09-01-101500Z.json", "diagnostic-2026-09-01-101500Z-2.json"]
        )
        let contents = try Set(store.reportURLs().map { try Data(contentsOf: $0) })
        XCTAssertEqual(contents, [payload("one"), payload("two")])
    }

    func testReportsAreListedOldestFirstAndTheNewestIsTheLast() throws {
        for offset in [0, 3_600, 60] {
            try store.store(
                jsonRepresentation: payload("\(offset)"),
                receivedAt: receivedAt.addingTimeInterval(TimeInterval(offset))
            )
        }
        XCTAssertEqual(storedNames, [
            "diagnostic-2026-09-01-101500Z.json",
            "diagnostic-2026-09-01-101600Z.json",
            "diagnostic-2026-09-01-111500Z.json",
        ])
        XCTAssertEqual(
            store.newestReportURL?.lastPathComponent,
            "diagnostic-2026-09-01-111500Z.json"
        )
    }

    // MARK: - Retention

    func testTheThirtyNewestReportsAreKeptAndTheOldestGo() throws {
        XCTAssertEqual(DiagnosticsStore.retentionLimit, 30)
        // 35 reports, one per minute, written oldest first.
        for minute in 0..<35 {
            try store.store(
                jsonRepresentation: payload("\(minute)"),
                receivedAt: receivedAt.addingTimeInterval(TimeInterval(minute * 60))
            )
        }

        XCTAssertEqual(store.reportCount, 30)
        // The five oldest are gone, the newest is still the one just written.
        XCTAssertEqual(storedNames.first, "diagnostic-2026-09-01-102000Z.json")
        XCTAssertEqual(storedNames.last, "diagnostic-2026-09-01-104900Z.json")
        XCTAssertFalse(storedNames.contains("diagnostic-2026-09-01-101500Z.json"))
    }

    /// The trim must not run over a foreign file to reach its quota, and it must not count one
    /// towards the quota either.
    func testTheTrimIgnoresFilesThatAreNotReports() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreign = directory.appendingPathComponent("my-notes.json", isDirectory: false)
        try Data("keep me".utf8).write(to: foreign)

        for minute in 0..<32 {
            try store.store(
                jsonRepresentation: payload("\(minute)"),
                receivedAt: receivedAt.addingTimeInterval(TimeInterval(minute * 60))
            )
        }

        XCTAssertEqual(store.reportCount, 30)
        XCTAssertEqual(try Data(contentsOf: foreign), Data("keep me".utf8))
    }

    // MARK: - Deleting

    func testDeleteAllEmptiesTheFolderAndLeavesForeignFilesAlone() throws {
        try store.store(jsonRepresentation: payload("one"), receivedAt: receivedAt)
        try store.store(
            jsonRepresentation: payload("two"),
            receivedAt: receivedAt.addingTimeInterval(60)
        )
        let foreign = directory.appendingPathComponent("my-notes.json", isDirectory: false)
        try Data("keep me".utf8).write(to: foreign)

        try store.deleteAll()

        XCTAssertEqual(store.reportCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        // The folder itself stays, so "Show in Finder" still lands somewhere.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDeletingAnEmptyFolderIsNotAnError() {
        XCTAssertNoThrow(try store.deleteAll())
    }

    // MARK: - The production folder

    /// The reports live beside the database, under Application Support, and are reached through
    /// the same `AppConfig` accessor everything else uses.
    func testTheProductionFolderIsInsideTheApplicationSupportDirectory() {
        let expected = AppConfig.applicationSupportDirectory
            .appendingPathComponent("Diagnostics", isDirectory: true)
        XCTAssertEqual(
            AppConfig.diagnosticsDirectory.standardizedFileURL,
            expected.standardizedFileURL
        )
        XCTAssertEqual(
            DiagnosticsStore().directory.standardizedFileURL,
            AppConfig.diagnosticsDirectory.standardizedFileURL
        )
    }

    // MARK: - The opt-in

    func testDiagnosticsAreOffOnAFreshInstallAndSurviveARelaunch() {
        let defaults = makeDefaults()
        let fresh = AppSettings(defaults: defaults)
        // The default is the whole privacy story: with this false the subscriber is never
        // registered, so MetricKit hands Shepherd nothing at all.
        XCTAssertFalse(fresh.diagnosticsEnabled)

        fresh.diagnosticsEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults).diagnosticsEnabled)

        fresh.diagnosticsEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).diagnosticsEnabled)
    }

    /// The reporter starts inert, subscribes exactly once when switched on, and — the half that
    /// matters — really *removes* the subscription when switched off. Idempotent in both
    /// directions, because launch, the Settings toggle and an applied sync document all call it
    /// without knowing about each other.
    func testSwitchingTheToggleAddsAndRemovesTheSubscriptionExactlyOnce() {
        var calls: [Bool] = []
        let reporter = DiagnosticsReporter(store: store) { _, subscribed in
            calls.append(subscribed)
        }
        XCTAssertFalse(reporter.isReceivingDiagnostics)
        XCTAssertTrue(calls.isEmpty)

        reporter.setSubscribed(true)
        reporter.setSubscribed(true)
        XCTAssertTrue(reporter.isReceivingDiagnostics)
        XCTAssertEqual(calls, [true])

        reporter.setSubscribed(false)
        reporter.setSubscribed(false)
        XCTAssertFalse(reporter.isReceivingDiagnostics)
        XCTAssertEqual(calls, [true, false])
    }

    /// The reporter reports the folder it was given, so Settings shows the path the reports are
    /// actually written to rather than a hard-coded one.
    func testTheReporterExposesItsOwnFolderAndCount() throws {
        let reporter = DiagnosticsReporter(store: store)
        XCTAssertEqual(
            reporter.directory.standardizedFileURL,
            directory.standardizedFileURL
        )
        XCTAssertEqual(reporter.reportCount, 0)

        try store.store(jsonRepresentation: payload("one"), receivedAt: receivedAt)
        XCTAssertEqual(reporter.reportCount, 1)

        try reporter.deleteAllReports()
        XCTAssertEqual(reporter.reportCount, 0)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let name = "com.schnaq.shepherd.tests.diagnostics.\(UUID().uuidString)"
        createdSuites.append(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("a fresh suite name always opens")
        }
        return defaults
    }
}
