import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence
import XCTest
@testable import ShepherdSync

/// The second sweep of the same cycle (ADR 0032): first sightings, the prune, the guard, and the
/// promise that none of it can take the review inbox down with it.
final class IssueSweepTests: XCTestCase {
    private let repo = SyncFixtures.repo

    private func makeEngine(
        github: MockGitHub,
        issues: MockIssueGitHub?,
        store: DatabaseManager
    ) -> SyncEngine {
        var capture: IssueCapture?
        if let issues {
            capture = IssueCapture(fetcher: issues, store: store)
        }
        return SyncEngine(
            github: github,
            store: store,
            issues: capture,
            sleeper: RecordingSleeper(),
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

    func testTheCycleRunsBothSweepsAndStoresBothKindsOfRow() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)]])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([[
            SyncFixtures.issue(id: "I_1", number: 41),
            SyncFixtures.issue(id: "I_2", number: 42, links: [SyncFixtures.link(number: 1)]),
        ]])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()

        let inbox = try await store.fetchInbox()
        XCTAssertEqual(inbox.map(\.id), ["PR_1"])
        let issues = try await store.fetchIssues()
        XCTAssertEqual(Set(issues.map(\.id)), ["I_1", "I_2"])
        // One sweep per cycle, not one per facet from the engine's side.
        let callCount = await issueGitHub.callCount
        XCTAssertEqual(callCount, 1)
        let queries = await issueGitHub.requestedQueries
        XCTAssertEqual(
            queries.first,
            [
                "is:issue is:open archived:false assignee:@me",
                "is:issue is:open archived:false author:@me",
                "is:issue is:open archived:false mentions:@me",
            ]
        )
        // The denormalised facet column travels with the row.
        let linked = issues.first { $0.id == "I_2" }
        XCTAssertEqual(linked?.hasAgentPullRequest, true)
    }

    func testFirstSightingsAreTheIssuesTheStoreHadNotSeen() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[]])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([
            [SyncFixtures.issue(id: "I_1", number: 41)],
            [
                SyncFixtures.issue(id: "I_1", number: 41),
                SyncFixtures.issue(id: "I_2", number: 42),
            ],
        ])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()
        let first = await engine.lastIssueSweep
        XCTAssertEqual(first?.newIssueIDs, ["I_1"])

        try await engine.syncNow()
        let second = await engine.lastIssueSweep
        XCTAssertEqual(second?.newIssueIDs, ["I_2"], "a row already stored is not a first sighting")
        XCTAssertEqual(second?.departedIssueIDs, [])
    }

    func testAnIssueTheSearchStoppedReturningIsPrunedAndReported() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[]])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([
            [
                SyncFixtures.issue(id: "I_1", number: 41),
                SyncFixtures.issue(id: "I_2", number: 42),
            ],
            [SyncFixtures.issue(id: "I_2", number: 42)],
        ])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()
        try await engine.syncNow()

        let issues = try await store.fetchIssues()
        XCTAssertEqual(issues.map(\.id), ["I_2"])
        let delta = await engine.lastIssueSweep
        XCTAssertEqual(delta?.departedIssueIDs, ["I_1"])
    }

    func testAnIssueWithAQueuedMutationIsNotPrunedAndIsNotReportedAsDeparted() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[]])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([
            [SyncFixtures.issue(id: "I_1", number: 41)],
            [],
        ])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()
        try await store.enqueue(
            OutboxItem(
                prID: "I_1",
                repo: repo,
                number: 41,
                action: .resolveThread(threadID: "PRRT_1")
            )
        )

        try await engine.syncNow()

        let issues = try await store.fetchIssues()
        XCTAssertEqual(issues.map(\.id), ["I_1"], "the guard keeps it")
        let delta = await engine.lastIssueSweep
        XCTAssertEqual(
            delta?.departedIssueIDs,
            [],
            "departed is what the prune removed, and it removed nothing"
        )
    }

    func testAnIssueSweepFailureDoesNotFailThePullRequestSweep() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)]])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([[SyncFixtures.issue(id: "I_1", number: 41)]])
        await issueGitHub.setError(.forbidden(message: "issues are disabled for this repository"))
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        let collected = try await events(from: engine) {
            try await engine.syncNow()
        }

        // The review inbox is what Shepherd is for: it is written, and its details are fetched.
        let inbox = try await store.fetchInbox()
        XCTAssertEqual(inbox.map(\.id), ["PR_1"])
        let detailRequests = await github.detailRequests
        XCTAssertEqual(detailRequests, ["schnaq/review#1"])
        let issues = try await store.fetchIssues()
        XCTAssertTrue(issues.isEmpty)

        // Reported rather than swallowed: the user asked for this section, so an inbox that is
        // quietly stale is worse than a line saying so.
        let failures: [SyncFailure] = collected.compactMap { event in
            guard case .syncFailed(let failure) = event else { return nil }
            return failure
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.stage, .sweep)
        XCTAssertTrue(failures.first?.message.hasPrefix("issue sweep:") == true)
    }

    func testAnEngineWithoutTheIssuePortsSweepsExactlyAsItDidBefore() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)]])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: nil, store: store)

        try await engine.syncNow()

        let inbox = try await store.fetchInbox()
        XCTAssertEqual(inbox.map(\.id), ["PR_1"])
        let issues = try await store.fetchIssues()
        XCTAssertTrue(issues.isEmpty, "no port, no query, no rows")
        let delta = await engine.lastIssueSweep
        XCTAssertNil(delta)
    }

    func testAPullRequestSweepDoesNotPruneARepositoryTheIssuesNeed() async throws {
        // Both tables cascade from `repos`, so the two sweeps share one repository prune.
        let github = MockGitHub()
        await github.setSearchResults([
            [SyncFixtures.summary(id: "PR_1", number: 1)],
            [],
        ])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([[SyncFixtures.issue(id: "I_1", number: 41)]])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()
        try await engine.syncNow()

        let inbox = try await store.fetchInbox()
        XCTAssertTrue(inbox.isEmpty)
        let issues = try await store.fetchIssues()
        XCTAssertEqual(issues.map(\.id), ["I_1"])
    }
}
