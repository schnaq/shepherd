import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence
import XCTest
@testable import ShepherdSync

final class SyncLoopTests: XCTestCase {
    private let repo = SyncFixtures.repo

    // MARK: - Notification triage

    func testOnlyInterestingNotificationsPullASweepForward() {
        XCTAssertTrue(
            SyncEngine.warrantsSweep([
                SyncFixtures.notification(id: "1", reason: .reviewRequested)
            ])
        )
        XCTAssertTrue(
            SyncEngine.warrantsSweep([SyncFixtures.notification(id: "2", reason: .mention)])
        )
        XCTAssertTrue(
            SyncEngine.warrantsSweep([SyncFixtures.notification(id: "3", reason: .ciActivity)])
        )
        XCTAssertFalse(
            SyncEngine.warrantsSweep([SyncFixtures.notification(id: "4", reason: .subscribed)])
        )
        XCTAssertFalse(
            SyncEngine.warrantsSweep([SyncFixtures.notification(id: "5", reason: .author)])
        )
        XCTAssertFalse(SyncEngine.warrantsSweep([]))
    }

    func testNonPullRequestNotificationsAreIgnored() {
        XCTAssertFalse(
            SyncEngine.warrantsSweep([
                SyncFixtures.notification(id: "6", reason: .mention, type: "Issue")
            ])
        )
    }

    // MARK: - Loop scheduling

    func testTheSweepLoopWaitsTheConfiguredInterval() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)]])
        let store = try DatabaseManager.inMemory()
        let sleeper = BoundedSleeper(allowedSleeps: 40)
        let engine = SyncEngine(
            github: github,
            store: store,
            configuration: SyncConfiguration(
                sweepInterval: 120,
                notificationsFallbackInterval: 45,
                minimumNotificationsInterval: 30
            ),
            sleeper: sleeper,
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )

        await engine.start()
        // The bounded sleeper cancels both loops after a few iterations.
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.stop()

        let seconds = await sleeper.recordedSeconds
        XCTAssertFalse(seconds.isEmpty)
        XCTAssertTrue(
            seconds.contains(120),
            "the sweep loop must wait the configured interval, saw \(seconds)"
        )
        XCTAssertTrue(
            seconds.contains(45),
            "the notifications loop falls back to its configured interval, saw \(seconds)"
        )

        let inbox = try await store.fetchInbox()
        XCTAssertEqual(inbox.count, 1, "the loop performed at least one sweep")
    }

    func testTheNotificationsLoopHonoursTheServerPollInterval() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)]])
        await github.setNotificationPages([
            NotificationsPage(
                items: [],
                pollInterval: 90,
                lastModified: "Mon, 31 Aug 2026 07:41:12 GMT",
                notModified: false
            )
        ])
        let store = try DatabaseManager.inMemory()
        let sleeper = BoundedSleeper(allowedSleeps: 40)
        let engine = SyncEngine(
            github: github,
            store: store,
            configuration: SyncConfiguration(notificationsFallbackInterval: 60),
            sleeper: sleeper,
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )

        await engine.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.stop()

        let seconds = await sleeper.recordedSeconds
        XCTAssertTrue(
            seconds.contains(90),
            "X-Poll-Interval must win over the fallback, saw \(seconds)"
        )

        let storedLastModified = try await store.syncState(
            forKey: "notifications.lastModified"
        )
        XCTAssertEqual(storedLastModified, "Mon, 31 Aug 2026 07:41:12 GMT")
    }

    func testAServerIntervalBelowTheFloorIsClamped() async throws {
        let github = MockGitHub()
        await github.setNotificationPages([
            NotificationsPage(items: [], pollInterval: 1)
        ])
        let store = try DatabaseManager.inMemory()
        let sleeper = BoundedSleeper(allowedSleeps: 40)
        let engine = SyncEngine(
            github: github,
            store: store,
            configuration: SyncConfiguration(minimumNotificationsInterval: 30),
            sleeper: sleeper,
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )

        await engine.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.stop()

        let seconds = await sleeper.recordedSeconds
        XCTAssertFalse(seconds.contains(1), "a 1 s poll interval must be clamped")
        XCTAssertTrue(seconds.contains(30), "clamped to the floor, saw \(seconds)")
    }

    func testStartIsIdempotentAndStopEndsTheLoops() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)]])
        let store = try DatabaseManager.inMemory()
        let engine = SyncEngine(
            github: github,
            store: store,
            configuration: SyncConfiguration(),
            sleeper: BoundedSleeper(allowedSleeps: 1),
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )

        await engine.start()
        await engine.start()
        var running = await engine.isRunning
        XCTAssertTrue(running)

        await engine.stop()
        running = await engine.isRunning
        XCTAssertFalse(running)
    }

    /// Bug 1 in its original shape: the *loop*, on an account where nothing is open, has to tell
    /// the app it swept. `syncNow()` was never the broken path — ⌘R sets the indicator itself —
    /// so the assertion belongs on the loop rather than only on the actor's method.
    func testTheSweepLoopReportsCompletionsOnAQuietAccount() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[]])
        let store = try DatabaseManager.inMemory()
        let engine = SyncEngine(
            github: github,
            store: store,
            configuration: SyncConfiguration(),
            sleeper: BoundedSleeper(allowedSleeps: 1),
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )

        let collector = EventCollector()
        let stream = engine.events
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
        }

        await engine.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.shutdown()
        _ = await task.value

        let emitted = await collector.events
        XCTAssertTrue(
            emitted.contains { event in
                if case .sweepCompleted(let completion) = event {
                    return completion.finishedAt == Date(timeIntervalSince1970: 1_788_162_000)
                }
                return false
            },
            "a sweep that found nothing still has to say it ran, or the title bar never moves"
        )
    }

    func testAnAccountThatCannotReadNotificationsNeverPollsThem() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)]])
        let store = try DatabaseManager.inMemory()
        let engine = SyncEngine(
            github: github,
            store: store,
            configuration: SyncConfiguration(sweepInterval: 120, pollsNotifications: false),
            sleeper: BoundedSleeper(allowedSleeps: 40),
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )

        await engine.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.stop()

        let polls = await github.notificationCallCount
        XCTAssertEqual(
            polls,
            0,
            "a device-flow token is refused this endpoint, so the loop must not run at all"
        )
        let inbox = try await store.fetchInbox()
        XCTAssertEqual(inbox.count, 1, "the sweep — the source of truth — still ran")
    }

    func testARefusedNotificationsPollEndsTheLoopAfterSayingSoOnce() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)]])
        await github.setNotificationsError(.forbidden(message: "Resource not accessible"))
        let store = try DatabaseManager.inMemory()
        let engine = SyncEngine(
            github: github,
            store: store,
            configuration: SyncConfiguration(sweepInterval: 120),
            sleeper: BoundedSleeper(allowedSleeps: 40),
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )

        let collector = EventCollector()
        let stream = engine.events
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
        }

        await engine.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.shutdown()
        _ = await task.value

        let polls = await github.notificationCallCount
        XCTAssertEqual(
            polls,
            1,
            "a refusal is not retryable; polling again would fail identically forever"
        )
        let emitted = await collector.events
        let complaints = emitted.filter { event in
            if case .syncFailed(let failure) = event { return failure.stage == .notifications }
            return false
        }
        XCTAssertEqual(complaints.count, 1, "the user hears about it once, not once a minute")
        let inbox = try await store.fetchInbox()
        XCTAssertEqual(inbox.count, 1, "and the sweep loop is left running")
    }

    func testSweepFailuresInTheLoopBecomeEventsRatherThanCrashes() async throws {
        let github = MockGitHub()
        await github.setSearchError(.rateLimited(retryAfter: 30, resetAt: nil))
        let store = try DatabaseManager.inMemory()
        let engine = SyncEngine(
            github: github,
            store: store,
            configuration: SyncConfiguration(),
            sleeper: BoundedSleeper(allowedSleeps: 1),
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )

        let collector = EventCollector()
        let stream = engine.events
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
        }

        await engine.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.shutdown()
        _ = await task.value

        let emitted = await collector.events
        XCTAssertTrue(
            emitted.contains { event in
                if case .syncFailed(let failure) = event { return failure.stage == .sweep }
                return false
            },
            "a failing sweep must surface as an event, not take the loop down"
        )
    }
}
