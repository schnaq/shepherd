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

extension TelemetryTests {
    // MARK: - Identity

    /// Level 1 mints in memory: two identities from two `TelemetryIdentity` instances differ, and
    /// nothing is written, so a relaunch can never produce the same value twice.
    func testAnonymousIdentityIsNeverStored() {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_789_774_200)

        let first = TelemetryIdentity(defaults: defaults).distinctID(for: .anonymous, now: now)
        let second = TelemetryIdentity(defaults: defaults).distinctID(for: .anonymous, now: now)

        XCTAssertNotEqual(first, second)
        XCTAssertNil(defaults.string(forKey: "telemetry.monthlyIdentity"))
    }

    /// The same instance answers consistently within a launch, so one launch is one session.
    func testAnonymousIdentityIsStableWithinOneLaunch() {
        let identity = TelemetryIdentity(defaults: makeDefaults())
        let now = Date(timeIntervalSince1970: 1_789_774_200)

        XCTAssertEqual(identity.distinctID(for: .anonymous, now: now), identity.distinctID(for: .anonymous, now: now))
    }

    /// Level 2 stores, survives a relaunch, and rotates when the UTC month turns — with no secret
    /// anywhere that could link September's value to October's.
    func testReachIdentityIsStoredAndRotatesWithTheMonth() {
        let defaults = makeDefaults()
        let september = Date(timeIntervalSince1970: 1_789_774_200)  // 2026-09-18
        let october = Date(timeIntervalSince1970: 1_792_000_000)    // 2026-10-14

        let first = TelemetryIdentity(defaults: defaults).distinctID(for: .reach, now: september)
        let afterRelaunch = TelemetryIdentity(defaults: defaults).distinctID(for: .reach, now: september)
        XCTAssertEqual(first, afterRelaunch)

        let next = TelemetryIdentity(defaults: defaults).distinctID(for: .reach, now: october)
        XCTAssertNotEqual(first, next)
    }

    func testClearingTheIdentityRemovesItFromDisk() {
        let defaults = makeDefaults()
        let identity = TelemetryIdentity(defaults: defaults)
        _ = identity.distinctID(for: .reach, now: Date(timeIntervalSince1970: 1_789_774_200))
        XCTAssertNotNil(defaults.string(forKey: "telemetry.monthlyIdentity"))

        identity.clearStoredIdentity()

        XCTAssertNil(defaults.string(forKey: "telemetry.monthlyIdentity"))
        XCTAssertNil(defaults.string(forKey: "telemetry.monthlyIdentityMonth"))
    }

    // MARK: - Heartbeat

    /// Two launches on one day are one heartbeat; the next UTC day is due again. This is what makes
    /// the event count equal the number of active installations rather than the number of launches.
    func testTheHeartbeatIsDueOncePerUTCDay() {
        let defaults = makeDefaults()
        let morning = Date(timeIntervalSince1970: 1_789_732_800)  // 2026-09-18T12:00:00Z
        let evening = Date(timeIntervalSince1970: 1_789_774_200)  // 2026-09-18T23:30:00Z
        let nextDay = Date(timeIntervalSince1970: 1_789_819_200)  // 2026-09-19T12:00:00Z

        let heartbeat = TelemetryHeartbeat(defaults: defaults)
        XCTAssertTrue(heartbeat.isDue(now: morning))
        heartbeat.markSent(now: morning)

        XCTAssertFalse(heartbeat.isDue(now: evening))
        XCTAssertFalse(TelemetryHeartbeat(defaults: defaults).isDue(now: evening))

        XCTAssertTrue(TelemetryHeartbeat(defaults: defaults).isDue(now: nextDay))
    }

    func testClearingTheHeartbeatForgetsTheDay() {
        let defaults = makeDefaults()
        let heartbeat = TelemetryHeartbeat(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_789_732_800)
        heartbeat.markSent(now: now)

        heartbeat.clear()

        XCTAssertTrue(heartbeat.isDue(now: now))
        XCTAssertNil(defaults.string(forKey: "telemetry.lastHeartbeatDay"))
    }
}

extension TelemetryTests {
    // MARK: - The queue

    private func makeQueue() -> TelemetryQueue { TelemetryQueue(directory: directory) }

    private func sampleEvent(_ marker: String) -> QueuedEvent {
        QueuedEvent(
            name: "fleet_viewed",
            day: "2026-09-18",
            distinctID: marker,
            properties: ["scope": TelemetryValue(FleetScope.all)]
        )
    }

    func testAppendedEventsSurviveANewQueueInstance() {
        let queue = makeQueue()
        queue.append(sampleEvent("a"))
        queue.append(sampleEvent("b"))

        let reloaded = makeQueue().load()

        XCTAssertEqual(reloaded.map(\.distinctID), ["a", "b"])
        XCTAssertEqual(reloaded.first?.properties["scope"], TelemetryValue(FleetScope.all))
    }

    /// A Mac that is offline for a month must not grow a queue without bound, and the events worth
    /// keeping are the recent ones.
    func testTheQueueIsCappedAndDropsTheOldest() {
        let queue = makeQueue()
        for index in 0..<(TelemetryQueue.capacity + 10) {
            queue.append(sampleEvent("event-\(index)"))
        }

        let stored = queue.load()

        XCTAssertEqual(stored.count, TelemetryQueue.capacity)
        XCTAssertEqual(stored.first?.distinctID, "event-10")
        XCTAssertEqual(stored.last?.distinctID, "event-\(TelemetryQueue.capacity + 9)")
    }

    /// A successful flush removes exactly what was sent, and leaves anything recorded meanwhile.
    func testRemovingTheSentPrefixLeavesTheRest() {
        let queue = makeQueue()
        queue.append(sampleEvent("a"))
        queue.append(sampleEvent("b"))
        queue.append(sampleEvent("c"))

        queue.remove(2)

        XCTAssertEqual(queue.load().map(\.distinctID), ["c"])
    }

    func testDeletingAllRemovesTheFileItself() {
        let queue = makeQueue()
        queue.append(sampleEvent("a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.fileURL.path))

        queue.deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.fileURL.path))
        XCTAssertTrue(queue.load().isEmpty)
    }

    /// The file is meant to be opened and read by the person whose Mac it is — that is what
    /// "Zeigen, was gesendet würde" shows — so it must be pretty-printed JSON, not a blob.
    func testTheQueueFileIsReadableJSON() throws {
        let queue = makeQueue()
        queue.append(sampleEvent("a"))

        let text = try String(contentsOf: queue.fileURL, encoding: .utf8)

        XCTAssertTrue(text.contains("\n"))
        XCTAssertTrue(text.contains("fleet_viewed"))
    }
}

extension TelemetryTests {
    // MARK: - The batch body

    private func decodedBody(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testTheBatchBodyCarriesTheKeyAndOneEntryPerEvent() throws {
        let data = try PostHogBatchBody.make(
            apiKey: "phc_test",
            events: [
                QueuedEvent(name: "fleet_viewed", day: "2026-09-18", distinctID: "abc",
                            properties: ["scope": TelemetryValue(FleetScope.all)]),
                QueuedEvent(name: "digest_opened", day: "2026-09-18", distinctID: "abc",
                            properties: ["source": TelemetryValue(DigestSource.app)]),
            ],
            appVersion: "1.2.0",
            osMajor: 26,
            language: "de"
        )

        let body = try decodedBody(data)
        XCTAssertEqual(body["api_key"] as? String, "phc_test")
        let batch = try XCTUnwrap(body["batch"] as? [[String: Any]])
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch.first?["event"] as? String, "fleet_viewed")
        XCTAssertEqual(batch.first?["timestamp"] as? String, "2026-09-18T00:00:00Z")
    }

    /// The four privacy-carrying properties, checked as a unit: they are the reason this is
    /// defensible at all, and any one of them missing changes what PostHog stores.
    func testEveryEventSuppressesProfilesAndIP() throws {
        let data = try PostHogBatchBody.make(
            apiKey: "phc_test",
            events: [QueuedEvent(name: "fleet_viewed", day: "2026-09-18", distinctID: "abc",
                                 properties: ["scope": TelemetryValue(FleetScope.all)])],
            appVersion: "1.2.0",
            osMajor: 26,
            language: "de"
        )

        let body = try decodedBody(data)
        let batch = try XCTUnwrap(body["batch"] as? [[String: Any]])
        let properties = try XCTUnwrap(batch.first?["properties"] as? [String: Any])

        XCTAssertEqual(properties["distinct_id"] as? String, "abc")
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertTrue(properties["$ip"] is NSNull)
        XCTAssertEqual(properties["$lib"] as? String, "shepherd")
        XCTAssertEqual(properties["app_version"] as? String, "1.2.0")
        XCTAssertEqual(properties["os_major"] as? Int, 26)
        XCTAssertEqual(properties["locale"] as? String, "de")
        XCTAssertEqual(properties["scope"] as? String, "all")
    }

    /// Nothing outside the allow-list may appear, ever — this is the test that would fail if
    /// somebody added a "helpful" hostname or device model later.
    func testNoPropertyOutsideTheAllowListAppears() throws {
        let allowed: Set<String> = [
            "distinct_id", "$process_person_profile", "$ip", "$lib",
            "app_version", "os_major", "locale", "scope",
        ]

        let data = try PostHogBatchBody.make(
            apiKey: "phc_test",
            events: [QueuedEvent(name: "fleet_viewed", day: "2026-09-18", distinctID: "abc",
                                 properties: ["scope": TelemetryValue(FleetScope.all)])],
            appVersion: "1.2.0",
            osMajor: 26,
            language: "de"
        )

        let body = try decodedBody(data)
        let batch = try XCTUnwrap(body["batch"] as? [[String: Any]])
        let properties = try XCTUnwrap(batch.first?["properties"] as? [String: Any])

        XCTAssertTrue(Set(properties.keys).isSubset(of: allowed), "unexpected keys: \(Set(properties.keys).subtracting(allowed))")

        let entry = try XCTUnwrap(batch.first)
        XCTAssertEqual(Set(entry.keys), ["event", "properties", "timestamp"])
    }

    func testTheLanguageIsOnlyEverGermanOrEnglish() {
        XCTAssertEqual(PostHogSender.language(for: Locale(identifier: "de_DE")), "de")
        XCTAssertEqual(PostHogSender.language(for: Locale(identifier: "de_AT")), "de")
        XCTAssertEqual(PostHogSender.language(for: Locale(identifier: "en_GB")), "en")
        // A Mac in French runs Shepherd's English UI (ADR 0022), so that is what is reported.
        XCTAssertEqual(PostHogSender.language(for: Locale(identifier: "fr_FR")), "en")
    }
}

/// A sender that records what it was handed and can be told to fail.
private final class RecordingSender: TelemetrySender, @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [[QueuedEvent]] = []
    var shouldFail = false

    var batches: [[QueuedEvent]] {
        lock.withLock { _batches }
    }

    // `withLock` rather than a bare `lock()`/`unlock()` pair: this method is `async`, and calling
    // those directly is unavailable there — an await between them could hand the lock to another
    // task.
    func send(_ events: [QueuedEvent]) async throws {
        let fail = lock.withLock {
            _batches.append(events)
            return shouldFail
        }
        if fail { throw URLError(.notConnectedToInternet) }
    }
}

extension TelemetryTests {
    // MARK: - The façade

    private func makeTelemetry(
        level: TelemetryLevel,
        defaults: UserDefaults,
        sender: RecordingSender,
        now: Date = Date(timeIntervalSince1970: 1_789_732_800)
    ) -> UsageTelemetry {
        UsageTelemetry(
            level: level,
            identity: TelemetryIdentity(defaults: defaults),
            heartbeat: TelemetryHeartbeat(defaults: defaults),
            queue: TelemetryQueue(directory: directory),
            sender: sender,
            now: { now }
        )
    }

    /// The gate, in the only two forms it takes: no key, or a level of `off`. Both mean the
    /// mechanism is absent rather than quiet.
    func testNoInstanceExistsWithoutAKeyOrWithTelemetryOff() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.telemetryNoticeAcknowledged = true

        settings.telemetryLevel = .off
        XCTAssertNil(UsageTelemetry.make(settings: settings, key: "phc_test", queue: TelemetryQueue(directory: directory), sender: RecordingSender()))

        settings.telemetryLevel = .anonymous
        XCTAssertNil(UsageTelemetry.make(settings: settings, key: nil, queue: TelemetryQueue(directory: directory), sender: RecordingSender()))

        XCTAssertNotNil(UsageTelemetry.make(settings: settings, key: "phc_test", queue: TelemetryQueue(directory: directory), sender: RecordingSender()))
    }

    /// Nothing is recorded before the notice is answered — the difference between "on by default"
    /// and "on by default, after you were told".
    func testNothingExistsBeforeTheNoticeIsAcknowledged() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.telemetryLevel = .anonymous
        settings.telemetryNoticeAcknowledged = false

        XCTAssertNil(UsageTelemetry.make(settings: settings, key: "phc_test", queue: TelemetryQueue(directory: directory), sender: RecordingSender()))
    }

    func testRecordingQueuesTheEventWithTodaysDayAndTheCurrentIdentity() {
        let defaults = makeDefaults()
        let telemetry = makeTelemetry(level: .anonymous, defaults: defaults, sender: RecordingSender())

        telemetry.record(.fleetViewed(scope: .all))

        let stored = TelemetryQueue(directory: directory).load()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.name, "fleet_viewed")
        XCTAssertEqual(stored.first?.day, "2026-09-18")
        XCTAssertFalse(stored.first?.distinctID.isEmpty ?? true)
    }

    func testFlushSendsTheQueueAndEmptiesItOnSuccess() async {
        let sender = RecordingSender()
        let telemetry = makeTelemetry(level: .anonymous, defaults: makeDefaults(), sender: sender)
        telemetry.record(.fleetViewed(scope: .all))
        telemetry.record(.digestOpened(source: .app))

        await telemetry.flush()

        XCTAssertEqual(sender.batches.count, 1)
        XCTAssertEqual(sender.batches.first?.count, 2)
        XCTAssertTrue(TelemetryQueue(directory: directory).load().isEmpty)
    }

    /// A failed flush keeps the events: the next flush tries again, and nothing is lost because
    /// the network was down.
    func testAFailedFlushKeepsTheQueue() async {
        let sender = RecordingSender()
        sender.shouldFail = true
        let telemetry = makeTelemetry(level: .anonymous, defaults: makeDefaults(), sender: sender)
        telemetry.record(.fleetViewed(scope: .all))

        await telemetry.flush()

        XCTAssertEqual(TelemetryQueue(directory: directory).load().count, 1)
    }

    /// Switching off erases rather than merely stopping — the queue, the heartbeat day and the
    /// monthly identity all go.
    func testSwitchingOffDeletesTheQueueTheDayAndTheIdentity() {
        let defaults = makeDefaults()
        let telemetry = makeTelemetry(level: .reach, defaults: defaults, sender: RecordingSender())
        telemetry.record(.fleetViewed(scope: .all))
        telemetry.recordHeartbeatIfDue { .digestOpened(source: .app) }
        XCTAssertNotNil(defaults.string(forKey: TelemetryIdentity.identityKey))

        telemetry.apply(level: .off)

        XCTAssertTrue(TelemetryQueue(directory: directory).load().isEmpty)
        XCTAssertNil(defaults.string(forKey: TelemetryIdentity.identityKey))
        XCTAssertNil(defaults.string(forKey: TelemetryHeartbeat.lastDayKey))
    }

    /// Dropping from reach to anonymous deletes only the stored identity: the counts stay, the
    /// recognisability goes.
    func testDroppingFromReachToAnonymousDeletesOnlyTheIdentity() {
        let defaults = makeDefaults()
        let telemetry = makeTelemetry(level: .reach, defaults: defaults, sender: RecordingSender())
        telemetry.record(.fleetViewed(scope: .all))

        telemetry.apply(level: .anonymous)

        XCTAssertNil(defaults.string(forKey: TelemetryIdentity.identityKey))
        XCTAssertEqual(TelemetryQueue(directory: directory).load().count, 1)
    }

    func testTheHeartbeatIsRecordedOncePerDayThroughTheFacade() {
        let defaults = makeDefaults()
        let telemetry = makeTelemetry(level: .anonymous, defaults: defaults, sender: RecordingSender())

        telemetry.recordHeartbeatIfDue { .digestOpened(source: .app) }
        telemetry.recordHeartbeatIfDue { .digestOpened(source: .app) }

        XCTAssertEqual(TelemetryQueue(directory: directory).load().count, 1)
    }
}

extension TelemetryTests {
    // MARK: - Settings sync

    /// The one that matters: a document from a Mac that predates telemetry has no group, and an
    /// absent group must leave the local choice alone. A default of `anonymous` here would switch
    /// telemetry back on for somebody who had turned it off.
    func testADocumentWithoutATelemetryGroupLeavesTheLevelAlone() throws {
        let json = Data(#"{"v":1,"telemetry":null}"#.utf8)
        let document = try JSONDecoder().decode(SyncedSettingsDocument.self, from: json)

        XCTAssertNil(document.telemetry)
    }

    func testTheGroupRoundTripsThroughJSON() throws {
        var document = SyncedSettingsDocument()
        document.telemetry = SyncedSettingsDocument.TelemetryGroup(level: .reach, noticeAcknowledged: true)

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SyncedSettingsDocument.self, from: data)

        XCTAssertEqual(decoded.telemetry?.level, .reach)
        XCTAssertEqual(decoded.telemetry?.noticeAcknowledged, true)
    }
}

extension TelemetryTests {
    // MARK: - The launch heartbeat

    /// The day-event carries the feature flags, which is how "which functions are used at all" is
    /// answered without an event per feature.
    func testTheLaunchHeartbeatCarriesTheFeatureFlags() {
        let event = TelemetryEvent.appActiveDay(
            repoCount: CountBucket(count: 7),
            inboxSize: CountBucket(count: 2),
            diffRenderer: .native,
            intelligence: .onDevice,
            webhooks: true,
            settingsSync: false,
            autoMerge: true,
            autoDelegation: false,
            digest: true,
            menuBar: true,
            diagnostics: false
        )

        XCTAssertEqual(event.name, "app_active_day")
        XCTAssertEqual(event.properties["repo_count"], TelemetryValue(CountBucket.fourToTen))
        XCTAssertEqual(event.properties["inbox_size"], TelemetryValue(CountBucket.oneToThree))
        XCTAssertEqual(event.properties["webhooks"], .flag(true))
        XCTAssertEqual(event.properties["settings_sync"], .flag(false))
    }
}

extension TelemetryTests {
    func testEveryEventInTheVocabularyCanBeRecordedAndQueued() {
        let telemetry = makeTelemetry(level: .anonymous, defaults: makeDefaults(), sender: RecordingSender())

        for event in TelemetryEvent.allExamples {
            telemetry.record(event)
        }

        XCTAssertEqual(Set(TelemetryQueue(directory: directory).load().map(\.name)).count, 13)
    }
}
