import Foundation
import GitHubKit
import ShepherdCore
import ShepherdSync
import XCTest

@testable import Shepherd

/// The app half of a merge series (ADR 0041): the store, the pass that feeds the policy, the
/// events, and the one notice at the end.
///
/// The step itself is covered by `MergeSeriesPolicyTests` in ShepherdKit. What is tested here is
/// what the policy cannot see: that the stepped series is saved before the write is awaited, that
/// the outcome is read off the outbox when no event arrives, that an old refusal does not count
/// against an entry, that the next entry waits for rows from after the merge, and that a finished
/// series says so exactly once and is gone.
@MainActor
final class MergeSeriesCoordinatorTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let start = Date(timeIntervalSince1970: 1_788_162_000)

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "shepherd.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removeSuite(named: suiteName)
    }

    // MARK: - Helpers

    @MainActor
    private final class Harness {
        var clock: Date
        var writes: [MergeSeriesWrite] = []
        var notices: [NotificationPayload] = []
        var outbox = MergeSeriesOutboxSnapshot()
        /// What the store said about the written entry at the moment the write was made.
        var stateAtWrite: [MergeSeriesEntryState?] = []
        var accepts = true

        init(clock: Date) {
            self.clock = clock
        }
    }

    private func row(
        _ id: String,
        number: Int = 1,
        head: String? = nil,
        checkState: CheckRollup.State = .success,
        mergeStateStatus: MergeStateStatus? = .clean
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: "Title \(id)",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: start,
            createdAt: start,
            headRefName: "feature-\(id)",
            headRefOid: head ?? "head-\(id)",
            baseRefName: "main",
            reviewDecision: .approved,
            checkRollup: CheckRollup(
                state: checkState,
                total: 2,
                successCount: checkState == .success ? 2 : 0,
                failureCount: checkState == .failure ? 1 : 0,
                pendingCount: checkState == .pending ? 2 : 0
            ),
            myRelation: [.reviewRequested],
            mergeable: .mergeable,
            mergeStateStatus: mergeStateStatus
        )
    }

    private func outboxRow(
        _ prID: String,
        _ action: OutboxAction = .merge(method: "squash", expectedHeadOid: "x"),
        state: OutboxState,
        createdAt: Date
    ) -> OutboxItem {
        OutboxItem(
            prID: prID,
            repo: repo,
            number: 1,
            action: action,
            createdAt: createdAt,
            state: state
        )
    }

    private func makeStore() -> MergeSeriesStore {
        MergeSeriesStore(defaults: defaults, key: "test.mergeSeries")
    }

    private func makeCoordinator(store: MergeSeriesStore, harness: Harness) -> MergeSeriesCoordinator {
        let settings = AppSettings(defaults: defaults)
        settings.defaultMergeMethod = .merge
        return MergeSeriesCoordinator(
            settings: settings,
            store: store,
            now: { harness.clock },
            notify: { harness.notices.append($0) }
        )
    }

    @discardableResult
    private func run(
        _ coordinator: MergeSeriesCoordinator,
        store: MergeSeriesStore,
        rows: [PullRequestSummary],
        harness: Harness
    ) async -> MergeSeriesPassResult {
        await coordinator.run(
            rows: rows,
            readOutbox: { harness.outbox },
            write: { request in
                harness.writes.append(request)
                let prID = request.pullRequest.id
                harness.stateAtWrite.append(store.series(containing: prID)?.entry(for: prID)?.state)
                return harness.accepts
            }
        )
    }

    private func entryState(_ store: MergeSeriesStore, _ prID: String) -> MergeSeriesEntryState? {
        store.series.first { $0.entry(for: prID) != nil }?.entry(for: prID)?.state
    }

    // MARK: - Starting

    func testStartStoresOneSeriesPerRepositoryInTheSheetsOrder() {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        let other = RepoRef(owner: "schnaq", name: "shepherd")
        var foreign = row("C")
        foreign.repo = other

        let started = coordinator.start(
            [(repository: repo, pullRequests: [row("B"), row("A")]), (repository: other, pullRequests: [foreign])],
            method: .squash,
            deletesHeadBranch: true
        )

        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(store.series.first?.entries.map(\.prID), ["B", "A"], "the dragged order, not a re-sort")
        XCTAssertEqual(store.series.first?.mergeMethod, "squash")
        XCTAssertEqual(store.series.first?.deletesHeadBranch, true)
        XCTAssertEqual(coordinator.pullRequestIDsInSeries, ["A", "B", "C"])

        coordinator.start([(repository: repo, pullRequests: [row("A")])], method: .merge, deletesHeadBranch: false)
        XCTAssertEqual(store.series.count, 2, "a pull request already in a running series is not put in a second")
    }

    func testASeriesSurvivesARelaunch() {
        let harness = Harness(clock: start)
        let coordinator = makeCoordinator(store: makeStore(), harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A")])], method: .squash, deletesHeadBranch: false)

        let reopened = makeStore()
        XCTAssertEqual(reopened.series.first?.entries.map(\.prID), ["A"])
    }

    // MARK: - Save before write

    func testTheSteppedSeriesIsSavedBeforeTheMergeIsWritten() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A")])], method: .squash, deletesHeadBranch: true)

        await run(coordinator, store: store, rows: [row("A")], harness: harness)

        XCTAssertEqual(harness.writes, [.merge(row("A"), method: .squash, deletesHeadBranch: true)])
        XCTAssertEqual(harness.stateAtWrite, [.merging], "a confirmation arriving inside the write must find the entry merging")
    }

    func testTheSteppedSeriesIsSavedBeforeTheBranchUpdateIsWritten() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A")])], method: .squash, deletesHeadBranch: false)
        let behind = row("A", checkState: .pending, mergeStateStatus: .behind)

        await run(coordinator, store: store, rows: [behind], harness: harness)

        XCTAssertEqual(harness.writes, [.updateBranch(behind)])
        XCTAssertEqual(harness.stateAtWrite, [.updatingBranch(from: "head-A")])
        // The drain's confirmation, arriving inside the write in the app, now finds its entry.
        coordinator.noteBranchUpdated("A")
        XCTAssertEqual(entryState(store, "A"), .branchUpdated(from: "head-A"))
    }

    // MARK: - Reconciling without events

    func testAMergeWhoseRowLeftTheOutboxAndTheInboxCountsAsMergedWithoutAnEvent() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)
        XCTAssertEqual(entryState(store, "A"), .merging)

        // No `mutationSent` arrives. The merge row is gone and so is the pull request.
        harness.clock = start.addingTimeInterval(60)
        harness.outbox = MergeSeriesOutboxSnapshot()
        await run(coordinator, store: store, rows: [row("B")], harness: harness)

        XCTAssertEqual(entryState(store, "A"), .merged)
        XCTAssertEqual(harness.writes.last, .merge(row("B"), method: .squash, deletesHeadBranch: false))
    }

    func testAMergeStillQueuedKeepsWaiting() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)

        harness.outbox = MergeSeriesOutboxSnapshot(items: [outboxRow("A", state: .pending, createdAt: start)])
        await run(coordinator, store: store, rows: [row("B")], harness: harness)

        XCTAssertEqual(entryState(store, "A"), .merging)
        XCTAssertEqual(harness.writes.count, 1, "B waits for A")
    }

    func testAnUpdateWhoseRowLeftTheOutboxCountsAsAcceptedWithoutAnEvent() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A", mergeStateStatus: .behind)], harness: harness)

        // No event; the row is gone and GitHub has made the new head.
        harness.clock = start.addingTimeInterval(30)
        await run(coordinator, store: store, rows: [row("A", head: "head-A2", checkState: .pending)], harness: harness)

        XCTAssertEqual(store.series.first?.entry(for: "A")?.pinnedHeadOid, "head-A2", "re-pinned once")
        XCTAssertEqual(entryState(store, "A"), .pending)

        await run(coordinator, store: store, rows: [row("A", head: "head-A2")], harness: harness)
        XCTAssertEqual(harness.writes.last, .merge(row("A", head: "head-A2"), method: .squash, deletesHeadBranch: false))
    }

    func testAMergeGitHubConfirmedThisSessionCountsEvenForAnEntryThatWasStillWaiting() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)

        // B was merged by hand before the series got to it.
        harness.outbox = MergeSeriesOutboxSnapshot(mergedIDs: ["B"])
        await run(coordinator, store: store, rows: [row("A", checkState: .pending)], harness: harness)

        XCTAssertEqual(entryState(store, "B"), .merged)
    }

    // MARK: - Failed writes

    func testAnOldParkedWriteDoesNotCountAgainstTheEntry() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A")])], method: .squash, deletesHeadBranch: false)
        // A 405 an earlier bulk merge left behind, an hour before the series started.
        harness.outbox = MergeSeriesOutboxSnapshot(items: [
            outboxRow("A", state: .failed, createdAt: start.addingTimeInterval(-3_600)),
        ])

        await run(coordinator, store: store, rows: [row("A")], harness: harness)

        XCTAssertEqual(entryState(store, "A"), .merging)
        XCTAssertEqual(harness.writes.count, 1, "neither skipped nor held back as a write in flight")
    }

    func testAWriteThatFailedDuringTheEntrysTurnSkipsIt() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)

        harness.clock = start.addingTimeInterval(10)
        harness.outbox = MergeSeriesOutboxSnapshot(items: [
            outboxRow("A", state: .failed, createdAt: start.addingTimeInterval(1)),
        ])
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)

        XCTAssertEqual(entryState(store, "A"), .skipped(.mergeRefused))
        XCTAssertEqual(harness.writes.last?.pullRequest.id, "B", "the series goes on with the next")
    }

    func testAWriteTheFunnelRefusedBeforeWritingSkipsTheEntry() async {
        let harness = Harness(clock: start)
        harness.accepts = false
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)

        await run(coordinator, store: store, rows: [row("A"), row("B", checkState: .pending)], harness: harness)

        XCTAssertEqual(entryState(store, "A"), .skipped(.mergeRefused), "an entry waiting for a row nobody wrote would wait for ever")
    }

    // MARK: - Fresh rows after a merge

    func testTheNextEntryWaitsForRowsFromAfterTheMerge() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)

        // GitHub confirms A. The inbox still shows A, and B as it was before main moved.
        coordinator.noteMerged("A")
        harness.outbox = MergeSeriesOutboxSnapshot(mergedIDs: ["A"])
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)
        XCTAssertEqual(harness.writes.count, 1, "B's CLEAN is from before A landed")

        // The sweep after the merge: A is gone, B is behind.
        await run(coordinator, store: store, rows: [row("B", mergeStateStatus: .behind)], harness: harness)
        XCTAssertEqual(harness.writes.last, .updateBranch(row("B", mergeStateStatus: .behind)))
    }

    // MARK: - Finishing

    func testAFinishedSeriesPostsOneNoticeAndIsPruned() async throws {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start(
            [(repository: repo, pullRequests: [row("A", number: 11), row("B", number: 12)])],
            method: .squash,
            deletesHeadBranch: false
        )
        await run(coordinator, store: store, rows: [row("A", number: 11), row("B", number: 12, checkState: .failure)], harness: harness)
        coordinator.noteMerged("A")
        harness.outbox = MergeSeriesOutboxSnapshot(mergedIDs: ["A"])
        await run(coordinator, store: store, rows: [row("B", number: 12, checkState: .failure)], harness: harness)

        XCTAssertTrue(store.series.isEmpty, "pruned once announced")
        XCTAssertFalse(coordinator.hasRunningSeries)
        let notice = try XCTUnwrap(harness.notices.first)
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertEqual(notice.title, String(localized: "\("schnaq/review"): \(1) merged, \(1) skipped"))
        XCTAssertTrue(notice.body.contains("#12"), notice.body)
        XCTAssertTrue(notice.body.contains(MergeSeriesSkipReason.checksFailed.title), notice.body)

        await run(coordinator, store: store, rows: [], harness: harness)
        coordinator.noteMerged("A")
        XCTAssertEqual(harness.notices.count, 1, "said once")
    }

    func testTheNoticeNamesOnlyTheFirstFewSkips() throws {
        let entries = (1...5).map { index in
            MergeSeriesEntry(
                prID: "P\(index)",
                slug: "schnaq/review#\(index)",
                number: index,
                title: "T\(index)",
                pinnedHeadOid: "h",
                state: index == 1 ? .merged : .skipped(.checksFailed)
            )
        }
        let series = MergeSeries(repository: repo, mergeMethod: "squash", deletesHeadBranch: false, createdAt: start, entries: entries)
        let notice = try XCTUnwrap(NotificationManager.payload(forFinishedMergeSeries: series))
        XCTAssertEqual(notice.body.components(separatedBy: "\n").count, NotificationManager.mergeSeriesSkipsNamed + 1)
        XCTAssertTrue(notice.body.hasSuffix(String(localized: "and \(1) more")), notice.body)
    }

    // MARK: - Removing and cancelling

    func testRemovingAnEntrySkipsItAndTheSeriesGoesOn() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)

        XCTAssertTrue(coordinator.canRemove("A", hasUnsentWrite: false))
        coordinator.remove("A")
        XCTAssertEqual(entryState(store, "A"), .skipped(.removedByUser))

        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)
        XCTAssertEqual(harness.writes.map(\.pullRequest.id), ["B"])
        XCTAssertFalse(coordinator.canRemove("B", hasUnsentWrite: true), "a queued merge cannot be taken back")
        XCTAssertTrue(coordinator.canRemove("B", hasUnsentWrite: false), "a merge whose row is gone can")
    }

    func testRemovingAMergingEntryNeedsItsOutboxRowToBeGone() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)

        coordinator.remove("A", outbox: MergeSeriesOutboxSnapshot(items: [outboxRow("A", state: .pending, createdAt: start)]))
        XCTAssertEqual(entryState(store, "A"), .merging, "the queued merge still decides")
        coordinator.remove("A")
        XCTAssertEqual(entryState(store, "A"), .merging, "without an outbox read nothing is assumed")

        coordinator.remove("A", outbox: MergeSeriesOutboxSnapshot())
        XCTAssertEqual(entryState(store, "A"), .skipped(.removedByUser))
    }

    func testCancellingRemovesAMergingEntryWhoseRowIsGone() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        let series = coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)

        coordinator.cancel(seriesID: series[0].id, outbox: MergeSeriesOutboxSnapshot())

        XCTAssertTrue(store.series.isEmpty, "nothing is left to wait for, so the series is over")
        XCTAssertTrue(harness.notices.isEmpty, "every entry was taken out by the user")
    }

    // MARK: - A merge that can never be confirmed

    func testAMergingEntryWithNoOutboxRowIsLetGoAfterTheGracePeriod() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)
        XCTAssertEqual(store.series.first?.entry(for: "A")?.mergeQueuedAt, start)

        // No row, no failure, no confirmation, and A is still open.
        harness.clock = start.addingTimeInterval(MergeSeriesCoordinator.missingRowGracePeriod - 1)
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)
        XCTAssertEqual(entryState(store, "A"), .merging, "a sweep behind the merge gets its hour")

        harness.clock = start.addingTimeInterval(MergeSeriesCoordinator.missingRowGracePeriod)
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)
        XCTAssertEqual(entryState(store, "A"), .skipped(.mergeRefused))
        XCTAssertEqual(harness.writes.last?.pullRequest.id, "B", "the series goes on")
    }

    func testAMergingEntryWhoseRowIsStillQueuedWaitsPastTheGracePeriod() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A")], harness: harness)

        harness.clock = start.addingTimeInterval(3 * MergeSeriesCoordinator.missingRowGracePeriod)
        harness.outbox = MergeSeriesOutboxSnapshot(items: [outboxRow("A", state: .pending, createdAt: start)])
        await run(coordinator, store: store, rows: [row("A")], harness: harness)

        XCTAssertEqual(entryState(store, "A"), .merging, "an offline Mac's merge is still on its way")
    }

    func testCancellingASeriesBeforeAnythingHappenedEndsItQuietly() {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        let series = coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)

        coordinator.cancel(seriesID: series[0].id)

        XCTAssertTrue(store.series.isEmpty)
        XCTAssertTrue(harness.notices.isEmpty, "the user pressed Cancel; there is nothing to tell them")
    }

    func testCancellingLeavesAQueuedMergeToFinishTheSeries() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        let series = coordinator.start([(repository: repo, pullRequests: [row("A"), row("B")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A"), row("B")], harness: harness)

        coordinator.cancel(seriesID: series[0].id)
        XCTAssertEqual(entryState(store, "B"), .skipped(.removedByUser))
        XCTAssertEqual(entryState(store, "A"), .merging)

        coordinator.noteMerged("A")
        XCTAssertTrue(store.series.isEmpty)
        XCTAssertEqual(harness.notices.count, 1, "a merge landed, so the summary is news")
    }

    // MARK: - The draft-conflict alert

    func testAParkedBranchUpdateOfASeriesDoesNotRaiseTheDraftAlert() async {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A")])], method: .squash, deletesHeadBranch: false)
        await run(coordinator, store: store, rows: [row("A", mergeStateStatus: .behind)], harness: harness)

        let conflict = DraftConflict(prID: "A", repo: repo, number: 1, expectedHeadOid: "head-A", actualHeadOid: "pushed")
        XCTAssertTrue(coordinator.handlesConflict(conflict))
        let other = DraftConflict(prID: "Z", repo: repo, number: 9, expectedHeadOid: "head-A", actualHeadOid: "pushed")
        XCTAssertFalse(coordinator.handlesConflict(other), "a review draft elsewhere still gets its alert")
    }

    // MARK: - Sign-out

    func testResetForgetsEverySeries() {
        let harness = Harness(clock: start)
        let store = makeStore()
        let coordinator = makeCoordinator(store: store, harness: harness)
        coordinator.start([(repository: repo, pullRequests: [row("A")])], method: .squash, deletesHeadBranch: false)

        coordinator.reset()

        XCTAssertTrue(makeStore().series.isEmpty)
    }
}
