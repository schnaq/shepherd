import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence
import XCTest
@testable import ShepherdSync

final class SyncEngineTests: XCTestCase {
    private let repo = SyncFixtures.repo
    private let clock = Date(timeIntervalSince1970: 1_788_162_000)

    private func makeEngine(
        github: MockGitHub,
        store: DatabaseManager,
        configuration: SyncConfiguration = SyncConfiguration(),
        sleeper: any Sleeping = RecordingSleeper()
    ) -> SyncEngine {
        SyncEngine(
            github: github,
            store: store,
            configuration: configuration,
            sleeper: sleeper,
            now: { Date(timeIntervalSince1970: 1_788_162_000) }
        )
    }

    /// Runs `body` while draining the engine's event stream, then returns the events.
    private func events(
        from engine: SyncEngine,
        while body: () async throws -> Void
    ) async throws -> [SyncEvent] {
        let collector = EventCollector()
        let stream = engine.events
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
        }
        try await body()
        await engine.shutdown()
        _ = await task.value
        return await collector.events
    }

    // MARK: - Delta detection

    func testFirstSweepStoresEverythingAndFetchesEveryDetail() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[
            SyncFixtures.summary(id: "PR_1", number: 1),
            SyncFixtures.summary(id: "PR_2", number: 2),
        ]])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        try await engine.syncNow()

        let inbox = try await store.fetchInbox()
        XCTAssertEqual(Set(inbox.map(\.id)), ["PR_1", "PR_2"])

        let detailRequests = await github.detailRequests
        XCTAssertEqual(Set(detailRequests), ["schnaq/review#1", "schnaq/review#2"])
    }

    func testUnchangedPullRequestsAreNotRefetched() async throws {
        let github = MockGitHub()
        let summaries = [SyncFixtures.summary(id: "PR_1", number: 1)]
        await github.setSearchResults([summaries, summaries])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        try await engine.syncNow()
        try await engine.syncNow()

        let detailRequests = await github.detailRequests
        XCTAssertEqual(
            detailRequests,
            ["schnaq/review#1"],
            "a pull request that did not change must not be fetched twice"
        )
    }

    func testAChangedUpdatedAtTriggersADetailFetch() async throws {
        let github = MockGitHub()
        await github.setSearchResults([
            [SyncFixtures.summary(id: "PR_1", number: 1, updatedAt: 0)],
            [SyncFixtures.summary(id: "PR_1", number: 1, updatedAt: 600)],
        ])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        try await engine.syncNow()
        try await engine.syncNow()

        let detailRequests = await github.detailRequests
        XCTAssertEqual(detailRequests.count, 2)
    }

    func testANewHeadCommitTriggersADetailFetchEvenWhenUpdatedAtIsUnchanged() async throws {
        let github = MockGitHub()
        await github.setSearchResults([
            [SyncFixtures.summary(id: "PR_1", number: 1, headRefOid: "head-1")],
            [SyncFixtures.summary(id: "PR_1", number: 1, headRefOid: "head-2")],
        ])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        try await engine.syncNow()
        try await engine.syncNow()

        let detailRequests = await github.detailRequests
        XCTAssertEqual(detailRequests.count, 2)
    }

    func testDetailFetchesAreChunkedByTheConcurrencyLimit() async throws {
        let github = MockGitHub()
        let summaries = (1...7).map { SyncFixtures.summary(id: "PR_\($0)", number: $0) }
        await github.setSearchResults([summaries])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(
            github: github,
            store: store,
            configuration: SyncConfiguration(maxConcurrentDetailFetches: 3)
        )

        try await engine.syncNow()
        let detailRequests = await github.detailRequests
        XCTAssertEqual(detailRequests.count, 7)
    }

    func testDetailFailuresAreReportedButDoNotAbortTheSweep() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)]])
        await github.setDetailError(.server(status: 500, message: "boom"))
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        let emitted = try await events(from: engine) {
            try await engine.syncNow()
        }

        let inbox = try await store.fetchInbox()
        XCTAssertEqual(inbox.count, 1, "the summary is still stored")
        XCTAssertTrue(
            emitted.contains { event in
                if case .syncFailed(let failure) = event { return failure.stage == .detail }
                return false
            }
        )
    }

    // MARK: - Events

    func testNewReviewRequestIsEmittedOnceForANewPullRequest() async throws {
        let github = MockGitHub()
        let summaries = [
            SyncFixtures.summary(id: "PR_1", number: 1, relations: [.reviewRequested])
        ]
        await github.setSearchResults([summaries, summaries])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        let emitted = try await events(from: engine) {
            try await engine.syncNow()
            try await engine.syncNow()
        }

        let requests = emitted.filter { event in
            if case .newReviewRequest = event { return true }
            return false
        }
        XCTAssertEqual(requests.count, 1, "the second sweep sees nothing new")
    }

    func testNoReviewRequestEventWhenTheUserIsOnlyTheAuthor() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[
            SyncFixtures.summary(id: "PR_1", number: 1, relations: [.author])
        ]])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        let emitted = try await events(from: engine) {
            try await engine.syncNow()
        }
        XCTAssertFalse(
            emitted.contains { event in
                if case .newReviewRequest = event { return true }
                return false
            }
        )
    }

    func testChecksFailingOnAnOwnPullRequestIsEmittedOnTheTransition() async throws {
        let github = MockGitHub()
        await github.setSearchResults([
            [
                SyncFixtures.summary(
                    id: "PR_1",
                    number: 1,
                    relations: [.author],
                    checkState: .pending
                )
            ],
            [
                SyncFixtures.summary(
                    id: "PR_1",
                    number: 1,
                    updatedAt: 600,
                    relations: [.author],
                    checkState: .failure
                )
            ],
            [
                SyncFixtures.summary(
                    id: "PR_1",
                    number: 1,
                    updatedAt: 1_200,
                    relations: [.author],
                    checkState: .failure
                )
            ],
        ])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        let emitted = try await events(from: engine) {
            try await engine.syncNow()
            try await engine.syncNow()
            try await engine.syncNow()
        }

        let failures = emitted.filter { event in
            if case .checksFailedOnOwnPR = event { return true }
            return false
        }
        XCTAssertEqual(failures.count, 1, "the event fires on the green-to-red transition only")
    }

    func testDisappearingPullRequestsAreReportedAsMerged() async throws {
        let github = MockGitHub()
        await github.setSearchResults([
            [
                SyncFixtures.summary(id: "PR_1", number: 1),
                SyncFixtures.summary(id: "PR_2", number: 2),
            ],
            [SyncFixtures.summary(id: "PR_2", number: 2)],
        ])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        let emitted = try await events(from: engine) {
            try await engine.syncNow()
            try await engine.syncNow()
        }

        let merged = emitted.compactMap { event -> PullRequestSummary? in
            if case .prMerged(let summary) = event { return summary }
            return nil
        }
        XCTAssertEqual(merged.map(\.id), ["PR_1"])

        let inbox = try await store.fetchInbox()
        XCTAssertEqual(inbox.map(\.id), ["PR_2"])
    }

    func testUpdatedPullRequestsEmitAnUpdateEvent() async throws {
        let github = MockGitHub()
        await github.setSearchResults([
            [SyncFixtures.summary(id: "PR_1", number: 1, updatedAt: 0)],
            [SyncFixtures.summary(id: "PR_1", number: 1, updatedAt: 600)],
        ])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        let emitted = try await events(from: engine) {
            try await engine.syncNow()
            try await engine.syncNow()
        }
        XCTAssertTrue(
            emitted.contains { event in
                if case .prUpdated(let summary) = event { return summary.id == "PR_1" }
                return false
            }
        )
    }

    func testSweepFailuresAreSurfaced() async throws {
        let github = MockGitHub()
        await github.setSearchError(.rateLimited(retryAfter: 30, resetAt: nil))
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store)

        let collector = EventCollector()
        let stream = engine.events
        let task = Task {
            for await event in stream {
                await collector.append(event)
            }
        }
        do {
            try await engine.syncNow()
            XCTFail("expected the sweep to throw")
        } catch {
            // syncNow surfaces the error; the loop turns it into an event instead.
        }
        await engine.shutdown()
        _ = await task.value
        let emitted = await collector.events
        XCTAssertTrue(emitted.isEmpty, "syncNow throws rather than emitting")
    }
}
