import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence
import XCTest
@testable import ShepherdSync

/// The second sweep of the same cycle (ADR 0032): first sightings, the prune, the guard, the
/// outcome of a row that left the search (its 2026-09-03 amendment), and the promise that none of
/// it can take the review inbox down with it.
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

    // MARK: - The outcome of a disappeared issue (ADR 0032's 2026-09-03 amendment)

    func testAnIssueThatClosedIsCapturedOntoItsRowRatherThanPruned() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[]])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([
            [SyncFixtures.issue(id: "I_1", number: 41)],
            [],
        ])
        // What the by-number read answers with: closed, completed, and with the agent pull
        // request that closed it — the three facts the digest's second line is made of.
        await issueGitHub.setRow(
            SyncFixtures.issue(
                id: "I_1",
                number: 41,
                updatedAt: 60,
                relations: [],
                links: [SyncFixtures.link(number: 7)],
                state: .closed,
                stateReason: "COMPLETED",
                closedAt: 60
            ),
            repo: repo,
            number: 41
        )
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()
        try await engine.syncNow()

        let stored = try await store.fetchIssues(filter: IssueFilter(includeClosed: true))
        let row = try XCTUnwrap(stored.first { $0.id == "I_1" }, "the row outlives the sweep")
        XCTAssertEqual(row.state, .closed)
        XCTAssertEqual(row.stateReason, "COMPLETED")
        XCTAssertEqual(row.closedAt, SyncFixtures.date(60))
        XCTAssertEqual(row.updatedAt, SyncFixtures.date(60))
        XCTAssertEqual(row.linkedPullRequests.map(\.number), [7])
        XCTAssertTrue(row.hasAgentPullRequest)
        // The by-number read claims no relation; the stored facets are the ones the sweep saw.
        XCTAssertEqual(row.myRelation, [.assigned])

        // The digest line this whole capture exists for now has something to say.
        let report = DigestReport.make(
            pullRequests: [],
            issues: stored,
            parkedReviewCount: 0,
            windowStart: SyncFixtures.date(-3_600),
            now: SyncFixtures.date(120)
        )
        let section = try XCTUnwrap(report.section(.agentPullRequestsThatClosedAnIssue))
        XCTAssertEqual(section.items.map(\.prID), ["I_1"])

        // The section's own observation is open-only, so nothing on screen changed.
        let open = try await store.fetchIssues()
        XCTAssertTrue(open.isEmpty)

        // One read, and only for the issue that went.
        let reads = await issueGitHub.rowReads
        XCTAssertEqual(reads, ["schnaq/review#41"])
    }

    func testAnIssueThatIsStillOpenOnGitHubIsPrunedAsBefore() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[]])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([
            [SyncFixtures.issue(id: "I_1", number: 41)],
            [],
        ])
        // Still open: it left the user's facets — unassigned, or the mention was edited away.
        await issueGitHub.setRow(
            SyncFixtures.issue(id: "I_1", number: 41, relations: []),
            repo: repo,
            number: 41
        )
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()
        try await engine.syncNow()

        let stored = try await store.fetchIssues(filter: IssueFilter(includeClosed: true))
        XCTAssertTrue(stored.isEmpty, "an issue that is not this user's business is still pruned")
        let delta = await engine.lastIssueSweep
        XCTAssertEqual(delta?.departedIssueIDs, ["I_1"])
    }

    func testAFailedOutcomeReadKeepsTheRowUnchangedAndTriesAgain() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[]])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([
            [SyncFixtures.issue(id: "I_1", number: 41)],
            [],
        ])
        await issueGitHub.setRowError(.transport(message: "the tunnel"))
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()
        let collected = try await events(from: engine) {
            try await engine.syncNow()
            // A third sweep is the retry: the row is still there and still missing from the
            // search, so it is asked about again.
            try await engine.syncNow()
        }

        let stored = try await store.fetchIssues(filter: IssueFilter(includeClosed: true))
        XCTAssertEqual(stored.map(\.id), ["I_1"])
        XCTAssertEqual(stored.first?.state, .open, "nothing was learned, so nothing changed")
        let reads = await issueGitHub.rowReads
        XCTAssertEqual(reads, ["schnaq/review#41", "schnaq/review#41"])
        let delta = await engine.lastIssueSweep
        XCTAssertEqual(delta?.departedIssueIDs, [], "a row that is still there has not departed")
        // Swallowed like the track record's capture: nobody asked for this read.
        XCTAssertFalse(collected.contains { event in
            guard case .syncFailed = event else { return false }
            return true
        })
    }

    func testAClosedRowIsPrunedOnceTheRetentionWindowHasRunOut() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[]])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([[]])
        let store = try DatabaseManager.inMemory()
        // Two rows already on disk, both closed and neither in the search: one closed an hour
        // ago, one three weeks ago.
        try await store.saveIssueSummaries(
            [
                SyncFixtures.issue(
                    id: "I_fresh",
                    number: 41,
                    state: .closed,
                    stateReason: "COMPLETED",
                    closedAt: -3_600
                ),
                SyncFixtures.issue(
                    id: "I_ancient",
                    number: 42,
                    state: .closed,
                    stateReason: "COMPLETED",
                    closedAt: -21 * 24 * 3_600
                ),
            ],
            pruneMissing: false
        )
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()

        let stored = try await store.fetchIssues(filter: IssueFilter(includeClosed: true))
        XCTAssertEqual(stored.map(\.id), ["I_fresh"])
        // A row that was already captured costs no second read.
        let reads = await issueGitHub.rowReads
        XCTAssertTrue(reads.isEmpty)
    }

    func testTheOutcomeReadsAreCappedPerSweepAndTheRestAreKept() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[]])
        let issueGitHub = MockIssueGitHub()
        let many = (1...12).map { SyncFixtures.issue(id: "I_\($0)", number: $0) }
        await issueGitHub.setResults([many, []])
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()
        try await engine.syncNow()

        let reads = await issueGitHub.rowReads
        XCTAssertEqual(reads.count, 10, "the cap, not the batch")
        // The two nobody got to are kept rather than pruned, so the next sweep can read them.
        let stored = try await store.fetchIssues(filter: IssueFilter(includeClosed: true))
        XCTAssertEqual(stored.count, 2)

        try await engine.syncNow()
        let afterThird = await issueGitHub.rowReads
        XCTAssertEqual(afterThird.count, 12)
        let remaining = try await store.fetchIssues(filter: IssueFilter(includeClosed: true))
        XCTAssertTrue(remaining.isEmpty, "read, still open, pruned")
    }

    func testThePruneGuardStillHoldsARowWithAPendingWriteAfterTheOutcomeRead() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[]])
        let issueGitHub = MockIssueGitHub()
        await issueGitHub.setResults([
            [SyncFixtures.issue(id: "I_1", number: 41)],
            [],
        ])
        // Still open on GitHub, so the capture wants it pruned — and the guard says no.
        await issueGitHub.setRow(
            SyncFixtures.issue(id: "I_1", number: 41, relations: []),
            repo: repo,
            number: 41
        )
        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, issues: issueGitHub, store: store)

        try await engine.syncNow()
        try await store.enqueue(
            OutboxItem(
                prID: "I_1",
                repo: repo,
                number: 41,
                action: .addIssueComment(
                    body: "on it",
                    basedOnUpdatedAt: SyncFixtures.date(0)
                )
            )
        )

        try await engine.syncNow()

        let stored = try await store.fetchIssues(filter: IssueFilter(includeClosed: true))
        XCTAssertEqual(stored.map(\.id), ["I_1"], "the prune guard still holds it")
        let delta = await engine.lastIssueSweep
        XCTAssertEqual(delta?.departedIssueIDs, [])
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
