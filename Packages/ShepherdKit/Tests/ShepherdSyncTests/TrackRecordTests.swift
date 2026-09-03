import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence
import XCTest

@testable import ShepherdSync

/// The sweep's outcome capture (ADR 0027): one read when a pull request leaves the inbox.
final class OutcomeCaptureTests: XCTestCase {
    func testAPullRequestThatLeftTheInboxIsReadOnceAndStored() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        let outcomes = FakeOutcomeStore()
        let summary = SyncFixtures.summary(id: "PR_1", number: 1)
        await outcomes.setSingleResult(
            SyncFixtures.closed(prID: "PR_1", number: 1),
            repo: SyncFixtures.repo,
            number: 1
        )
        await github.setSearchResults([[summary], []])

        let engine = makeEngine(github: github, store: store, outcomes: outcomes)
        try await engine.syncNow()
        try await engine.syncNow()

        let awaited1 = await outcomes.singleReads
        XCTAssertEqual(awaited1, ["schnaq/review#1"])
        let stored = await outcomes.stored
        XCTAssertEqual(stored["PR_1"]?.outcome.merged, true)
        XCTAssertEqual(stored["PR_1"]?.outcome.repo, SyncFixtures.repo)
    }

    func testAPullRequestThatStayedInTheInboxIsNeverRead() async throws {
        let github = MockGitHub()
        let outcomes = FakeOutcomeStore()
        let summary = SyncFixtures.summary(id: "PR_1", number: 1)
        await github.setSearchResults([[summary], [summary]])

        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store, outcomes: outcomes)
        try await engine.syncNow()
        try await engine.syncNow()

        let awaited2 = await outcomes.singleReads.isEmpty
        XCTAssertTrue(awaited2)
    }

    func testAPullRequestThatAlreadyHasARowIsNotReadAgain() async throws {
        let github = MockGitHub()
        let outcomes = FakeOutcomeStore()
        _ = try await outcomes.savePullRequestOutcomes([
            SyncFixtures.closed(prID: "PR_1", number: 1)
        ])
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)], []])

        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store, outcomes: outcomes)
        try await engine.syncNow()
        try await engine.syncNow()

        let singleReads = await outcomes.singleReads
        XCTAssertTrue(
            singleReads.isEmpty,
            "the store is asked before GitHub is, so a backfilled pull request costs no request"
        )
    }

    func testAPullRequestGitHubStillCallsOpenIsNotStored() async throws {
        let github = MockGitHub()
        let outcomes = FakeOutcomeStore()
        // No scripted result, which is what the client answers with for a pull request that is
        // still open: the user's search facets simply stopped matching it.
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)], []])

        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store, outcomes: outcomes)
        try await engine.syncNow()
        try await engine.syncNow()

        let awaited3 = await outcomes.singleReads
        XCTAssertEqual(awaited3, ["schnaq/review#1"])
        let awaited4 = await outcomes.stored.isEmpty
        XCTAssertTrue(awaited4)
    }

    func testAFailedReadNeverFailsTheSweep() async throws {
        let github = MockGitHub()
        let store = try DatabaseManager.inMemory()
        let outcomes = FakeOutcomeStore()
        await outcomes.setReadError(.forbidden(message: "no access"))
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)], []])

        let engine = makeEngine(github: github, store: store, outcomes: outcomes)
        let collector = EventCollector()
        let events = engine.events
        let listener = Task {
            for await event in events {
                await collector.append(event)
            }
        }

        try await engine.syncNow()
        // The second sweep is the one that sees the disappearance, and it must succeed.
        try await engine.syncNow()
        listener.cancel()

        let awaited5 = await outcomes.stored.isEmpty
        XCTAssertTrue(awaited5)
        let collected = await collector.events
        let failures = collected.filter {
            if case .syncFailed = $0 { return true }
            return false
        }
        XCTAssertTrue(failures.isEmpty, "the user did not ask for this; it must be silent")
    }

    func testARevertIsLinkedAgainstWhatIsAlreadyStored() async throws {
        let github = MockGitHub()
        let outcomes = FakeOutcomeStore()
        // The target was imported by an earlier backfill.
        _ = try await outcomes.savePullRequestOutcomes([
            SyncFixtures.closed(
                prID: "PR_1",
                number: 10,
                title: "feat: parser",
                merged: true,
                closedAt: -1_000
            )
        ])
        // Today the revert closes, and the sweep sees it disappear.
        await outcomes.setSingleResult(
            SyncFixtures.closed(
                prID: "PR_2",
                number: 11,
                title: #"Revert "feat: parser""#,
                merged: true,
                closedAt: 0
            ),
            repo: SyncFixtures.repo,
            number: 11
        )
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_2", number: 11)], []])

        let store = try DatabaseManager.inMemory()
        let engine = makeEngine(github: github, store: store, outcomes: outcomes)
        try await engine.syncNow()
        try await engine.syncNow()

        let awaited6 = await outcomes.links
        XCTAssertEqual(awaited6, ["PR_1": "PR_2"])
    }

    func testAnEngineWithNoPortsDoesNothingAtAll() async throws {
        let github = MockGitHub()
        await github.setSearchResults([[SyncFixtures.summary(id: "PR_1", number: 1)], []])
        let store = try DatabaseManager.inMemory()
        let engine = SyncEngine(
            github: github,
            store: store,
            sleeper: BoundedSleeper(allowedSleeps: 0)
        )
        // The assertion is that this does not trap and does not throw: with no capture wired,
        // the sweep is exactly what it was before ADR 0027.
        try await engine.syncNow()
        try await engine.syncNow()
    }

    private func makeEngine(
        github: MockGitHub,
        store: DatabaseManager,
        outcomes: FakeOutcomeStore
    ) -> SyncEngine {
        SyncEngine(
            github: github,
            store: store,
            outcomes: OutcomeCapture(reader: outcomes, store: outcomes),
            configuration: SyncConfiguration(queries: [.reviewRequested]),
            sleeper: BoundedSleeper(allowedSleeps: 0),
            now: { SyncFixtures.date(0) }
        )
    }
}

/// The backfill pager (ADR 0027).
final class TrackRecordBackfillTests: XCTestCase {
    private let repo = SyncFixtures.repo
    private let other = RepoRef(owner: "schnaq", name: "konduit")

    func testEveryPageIsFollowedAndStored() async throws {
        let store = FakeOutcomeStore()
        await store.setPages(
            [
                ClosedPullRequestPage(
                    pullRequests: [
                        SyncFixtures.closed(prID: "PR_1", number: 1),
                        SyncFixtures.closed(prID: "PR_2", number: 2),
                    ],
                    totalCount: 3,
                    hasNextPage: true,
                    endCursor: "cursor-1"
                ),
                ClosedPullRequestPage(
                    pullRequests: [SyncFixtures.closed(prID: "PR_3", number: 3)],
                    totalCount: 3
                ),
            ],
            repo: repo
        )

        let backfill = TrackRecordBackfill(
            reader: store,
            store: store,
            now: { SyncFixtures.date(0) }
        )
        let result = await backfill.run(repos: [repo])

        XCTAssertEqual(result.stored, 3)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertTrue(result.failures.isEmpty)
        let pageReads = await store.pageReads
        XCTAssertEqual(
            pageReads,
            ["schnaq/review|-", "schnaq/review|cursor-1"],
            "the second page is asked for with the first page's cursor"
        )
        let awaited7 = await store.stored.count
        XCTAssertEqual(awaited7, 3)
    }

    func testTheProgressLineCountsUpPerPage() async throws {
        let store = FakeOutcomeStore()
        await store.setPages(
            [
                ClosedPullRequestPage(
                    pullRequests: [SyncFixtures.closed(prID: "PR_1", number: 1)],
                    totalCount: 2,
                    hasNextPage: true,
                    endCursor: "c1"
                ),
                ClosedPullRequestPage(
                    pullRequests: [SyncFixtures.closed(prID: "PR_2", number: 2)],
                    totalCount: 2
                ),
            ],
            repo: repo
        )
        let collector = ProgressCollector()

        let backfill = TrackRecordBackfill(
            reader: store,
            store: store,
            now: { SyncFixtures.date(0) }
        )
        _ = await backfill.run(repos: [repo]) { update in
            collector.append(update)
        }

        let updates = collector.read()
        XCTAssertEqual(updates.map(\.stored), [1, 2])
        XCTAssertEqual(updates.map(\.estimatedTotal), [2, 2])
        XCTAssertEqual(updates.map(\.repositoryIndex), [1, 1])
        XCTAssertEqual(updates.map(\.repositoryCount), [1, 1])
    }

    func testCancellingMidWayKeepsWhatWasAlreadyRead() async throws {
        // A cancellation that lands between two pages reaches the pager as a `CancellationError`
        // from the read it was waiting on. Scripted rather than raced: a test that cancelled a
        // real `Task` and then asserted on how far it got would pass or fail on scheduling.
        let store = CancellingOnSecondPageStore(
            first: ClosedPullRequestPage(
                pullRequests: [SyncFixtures.closed(prID: "PR_1", number: 1)],
                totalCount: 2,
                hasNextPage: true,
                endCursor: "c1"
            )
        )

        let backfill = TrackRecordBackfill(
            reader: store,
            store: store,
            now: { SyncFixtures.date(0) }
        )
        let result = await backfill.run(repos: [repo])

        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(result.failures.isEmpty, "a cancellation is not a failure")
        let storedCount = await store.stored.count
        XCTAssertEqual(
            storedCount,
            1,
            "a cancel keeps everything read so far — the table upserts, so a second run continues"
        )
    }

    func testCancellingBeforeTheFirstRepositoryReadsNothing() async throws {
        let store = FakeOutcomeStore()
        let backfill = TrackRecordBackfill(
            reader: store,
            store: store,
            now: { SyncFixtures.date(0) }
        )
        // Cancelled from inside its own task, before the first `await`, so the assertion does not
        // depend on how fast the pager gets going. The repositories are copied out first: the
        // closure is sent to another task, and `self` (the test case) must not travel with it.
        let repos = [repo, other]
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await backfill.run(repos: repos)
        }.value

        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.stored, 0)
        let awaited8 = await store.pageReads.isEmpty
        XCTAssertTrue(awaited8)
    }

    func testTheCapStopsAtFiveHundredPerRepository() async throws {
        let store = FakeOutcomeStore()
        // Six pages of a hundred, one more than the cap allows.
        let pages = (0..<6).map { pageIndex in
            ClosedPullRequestPage(
                pullRequests: (0..<100).map { row in
                    SyncFixtures.closed(
                        prID: "PR_\(pageIndex)_\(row)",
                        number: pageIndex * 100 + row
                    )
                },
                totalCount: 600,
                hasNextPage: true,
                endCursor: "cursor-\(pageIndex)"
            )
        }
        await store.setPages(pages, repo: repo)

        let backfill = TrackRecordBackfill(
            reader: store,
            store: store,
            now: { SyncFixtures.date(0) }
        )
        let result = await backfill.run(repos: [repo])

        XCTAssertEqual(result.stored, TrackRecordBackfill.maximumPullRequestsPerRepository)
        XCTAssertEqual(result.cappedRepositories, [repo])
        let awaited9 = await store.pageReads.count
        XCTAssertEqual(awaited9, 5, "five pages of a hundred, then it stops")
    }

    func testOneRepositorysFailureIsALineAndTheRunContinues() async throws {
        let store = FailingFirstRepoStore(failing: repo)
        await store.setPages(
            [
                ClosedPullRequestPage(
                    pullRequests: [SyncFixtures.closed(prID: "PR_1", number: 1, repo: other)],
                    totalCount: 1
                )
            ],
            repo: other
        )

        let backfill = TrackRecordBackfill(
            reader: store,
            store: store,
            now: { SyncFixtures.date(0) }
        )
        let result = await backfill.run(repos: [repo, other])

        XCTAssertEqual(result.failures.map(\.repo), [repo])
        XCTAssertFalse(result.failures.first?.message.isEmpty ?? true)
        XCTAssertEqual(result.stored, 1, "the second repository was still read")
    }

    func testRevertsAreLinkedAcrossPagesOfOneRepository() async throws {
        let store = FakeOutcomeStore()
        await store.setPages(
            [
                // The revert arrives first, which is what a "newest first" search does.
                ClosedPullRequestPage(
                    pullRequests: [
                        SyncFixtures.closed(
                            prID: "PR_2",
                            number: 11,
                            title: #"Revert "feat: parser""#,
                            closedAt: 0
                        )
                    ],
                    totalCount: 2,
                    hasNextPage: true,
                    endCursor: "c1"
                ),
                ClosedPullRequestPage(
                    pullRequests: [
                        SyncFixtures.closed(
                            prID: "PR_1",
                            number: 10,
                            title: "feat: parser",
                            closedAt: -1_000
                        )
                    ],
                    totalCount: 2
                ),
            ],
            repo: repo
        )

        let backfill = TrackRecordBackfill(
            reader: store,
            store: store,
            now: { SyncFixtures.date(0) }
        )
        let result = await backfill.run(repos: [repo])

        XCTAssertEqual(result.revertsLinked, 1)
        let awaited10 = await store.links
        XCTAssertEqual(awaited10, ["PR_1": "PR_2"])
    }

    func testRunningItTwiceChangesNothing() async throws {
        let store = FakeOutcomeStore()
        let page = ClosedPullRequestPage(
            pullRequests: [SyncFixtures.closed(prID: "PR_1", number: 1)],
            totalCount: 1
        )
        await store.setPages([page, page], repo: repo)

        let backfill = TrackRecordBackfill(
            reader: store,
            store: store,
            now: { SyncFixtures.date(0) }
        )
        _ = await backfill.run(repos: [repo])
        _ = await backfill.run(repos: [repo])

        let awaited11 = await store.stored.count
        XCTAssertEqual(awaited11, 1)
    }

    func testNoRepositoriesIsNoWork() async throws {
        let store = FakeOutcomeStore()
        let backfill = TrackRecordBackfill(
            reader: store,
            store: store,
            now: { SyncFixtures.date(0) }
        )
        let result = await backfill.run(repos: [])
        XCTAssertEqual(result.stored, 0)
        let awaited12 = await store.pageReads.isEmpty
        XCTAssertTrue(awaited12)
    }
}

/// Collects the pager's progress updates from whichever executor they arrive on.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [TrackRecordBackfillProgress] = []

    func append(_ update: TrackRecordBackfillProgress) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    func read() -> [TrackRecordBackfillProgress] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

/// A store that refuses one repository's pages and answers normally for the rest.
private actor FailingFirstRepoStore: OutcomeRecording, ClosedPullRequestReading {
    private let failing: RepoRef
    private var pages: [String: [ClosedPullRequestPage]] = [:]
    private(set) var stored: [String: ClosedPullRequest] = [:]

    init(failing: RepoRef) {
        self.failing = failing
    }

    func setPages(_ pages: [ClosedPullRequestPage], repo: RepoRef) {
        self.pages[repo.fullName] = pages
    }

    func hasPullRequestOutcome(prID: String) async throws -> Bool { stored[prID] != nil }

    func savePullRequestOutcomes(_ closed: [ClosedPullRequest]) async throws -> Int {
        for entry in closed { stored[entry.outcome.prID] = entry }
        return closed.count
    }

    func mergedClosedPullRequests(
        repo: RepoRef,
        since: Date
    ) async throws -> [ClosedPullRequest] {
        []
    }

    func applyRevertLinks(_ links: [String: String]) async throws -> Int { 0 }

    func closedPullRequest(repo: RepoRef, number: Int) async throws -> ClosedPullRequest? { nil }

    func searchClosedPullRequests(
        repo: RepoRef,
        since: Date,
        cursor: String?,
        pageSize: Int
    ) async throws -> ClosedPullRequestPage {
        if repo.isSameRepository(as: failing) {
            throw GitHubError.forbidden(message: "Resource not accessible by integration")
        }
        var remaining = pages[repo.fullName] ?? []
        guard !remaining.isEmpty else {
            return ClosedPullRequestPage(pullRequests: [], totalCount: 0)
        }
        let page = remaining.removeFirst()
        pages[repo.fullName] = remaining
        return page
    }
}

/// A store whose second page read reports a cancellation, so the pager's partial-progress
/// behaviour can be asserted without racing a real `Task.cancel()`.
private actor CancellingOnSecondPageStore: OutcomeRecording, ClosedPullRequestReading {
    private let first: ClosedPullRequestPage
    private var reads = 0
    private(set) var stored: [String: ClosedPullRequest] = [:]

    init(first: ClosedPullRequestPage) {
        self.first = first
    }

    func hasPullRequestOutcome(prID: String) async throws -> Bool { stored[prID] != nil }

    func savePullRequestOutcomes(_ closed: [ClosedPullRequest]) async throws -> Int {
        for entry in closed { stored[entry.outcome.prID] = entry }
        return closed.count
    }

    func mergedClosedPullRequests(
        repo: RepoRef,
        since: Date
    ) async throws -> [ClosedPullRequest] {
        []
    }

    func applyRevertLinks(_ links: [String: String]) async throws -> Int { 0 }

    func closedPullRequest(repo: RepoRef, number: Int) async throws -> ClosedPullRequest? { nil }

    func searchClosedPullRequests(
        repo: RepoRef,
        since: Date,
        cursor: String?,
        pageSize: Int
    ) async throws -> ClosedPullRequestPage {
        reads += 1
        if reads == 1 { return first }
        throw CancellationError()
    }
}
