import Foundation
import GitHubKit
import ShepherdCore
import XCTest

@testable import Shepherd

/// The app half of automatic merging (ADR 0018): running a pass over the rows a sweep wrote,
/// reserving the slot in the persistent ledger, asking for exactly one write per eligible pull
/// request, and announcing what happened.
///
/// The *decision* is covered exhaustively by `AutoMergePolicyTests` in ShepherdKit. What is tested
/// here is the wiring the policy cannot see: that a pass asks for one merge and not two, that the
/// audit log and the deduplication are the same list, that the ledger survives a relaunch, and
/// that the write is requested with the head commit the decision was made on.
///
/// The write itself goes through the injected ``AutoMergeWriting`` seam, which in the app is
/// ``PullRequestActions/merge(_:method:)`` — the same function the merge sheet's button calls. This
/// suite therefore asserts on the *requests*, exactly as `WebhookTests` asserts on plans rather
/// than on HTTP: the outbox row a `.merge` action produces is covered by ShepherdPersistence's own
/// tests, and duplicating a session and a database here would test neither better.
@MainActor
final class AutoMergeTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let clock = Date(timeIntervalSince1970: 1_788_162_000)

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

    /// One write the coordinator asked for. A struct rather than a tuple so the assertions can
    /// use key paths.
    private struct WriteRequest: Equatable {
        var prID: String
        var headRefOid: String
        var method: MergeMethod
    }

    /// Records what the coordinator asked for. Main-actor, so the assertions read straight
    /// through and no lock is ever held across an `await`.
    @MainActor
    private final class Harness {
        /// Every write the coordinator requested, in order.
        var writes: [WriteRequest] = []
        /// Every notice it posted.
        var notices: [NotificationPayload] = []
    }

    /// A pull request in the one shape v1 merges: an agent's, green, approved, mergeable.
    private func mergeable(
        id: String = "PR_1",
        number: Int = 42,
        headRefOid: String = "head-1",
        title: String = "Bump the client",
        labels: [String] = [],
        reviewDecision: ReviewDecision? = .approved,
        checkState: CheckRollup.State? = .success
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: title,
            author: ShepherdCore.Actor(
                login: "claude[bot]",
                kind: .agent(
                    AgentIdentity(id: "claude-code", displayName: "Claude Code", matchedBy: .login)
                )
            ),
            updatedAt: clock,
            createdAt: clock,
            isDraft: false,
            headRefName: "claude/bump",
            headRefOid: headRefOid,
            baseRefName: "main",
            reviewDecision: reviewDecision,
            checkRollup: checkState.map { CheckRollup(state: $0, total: 4, successCount: 4) },
            myRelation: [.reviewRequested],
            labels: labels,
            mergeable: .mergeable
        )
    }

    private func makeSettings(
        isEnabled: Bool = true,
        allowedRepositories: [String] = [],
        requiredLabels: [String] = [],
        method: MergeMethod = .squash
    ) -> AppSettings {
        let settings = AppSettings(defaults: defaults)
        settings.autoMerge = AutoMergeRules(
            isEnabled: isEnabled,
            allowedRepositories: allowedRepositories,
            requiredLabels: requiredLabels
        )
        settings.defaultMergeMethod = method
        return settings
    }

    private func makeCoordinator(
        settings: AppSettings,
        store: AutoMergeStore? = nil,
        harness: Harness
    ) -> AutoMergeCoordinator {
        let fixedNow = clock
        return AutoMergeCoordinator(
            settings: settings,
            store: store ?? AutoMergeStore(defaults: defaults, key: "test.autoMerge"),
            now: { fixedNow },
            notify: { harness.notices.append($0) }
        )
    }

    /// Runs one pass, recording what was asked for instead of writing anything.
    private func run(
        _ coordinator: AutoMergeCoordinator,
        rows: [PullRequestSummary],
        existingOutbox: Set<String> = [],
        harness: Harness
    ) async -> [AutoMergeQueuedWrite] {
        await coordinator.run(
            rows: rows,
            existingOutbox: existingOutbox,
            write: { summary, method in
                harness.writes.append(
                    WriteRequest(
                        prID: summary.id,
                        headRefOid: summary.headRefOid,
                        method: method
                    )
                )
            }
        )
    }

    // MARK: - Queueing

    func testAnEligiblePullRequestIsQueuedExactlyOnceAndRecorded() async throws {
        let harness = Harness()
        let store = AutoMergeStore(defaults: defaults, key: "test.autoMerge")
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            store: store,
            harness: harness
        )

        let queued = await run(coordinator, rows: [mergeable()], harness: harness)

        XCTAssertEqual(harness.writes.count, 1, "one pull request, one outbox write")
        XCTAssertEqual(harness.writes.first?.prID, "PR_1")
        XCTAssertEqual(
            harness.writes.first?.headRefOid,
            "head-1",
            "the merge is queued against the head the decision was made on"
        )
        XCTAssertEqual(harness.writes.first?.method, .squash)

        // The ledger — which is also the audit log — was written before the request.
        XCTAssertTrue(store.hasQueued(prID: "PR_1", headRefOid: "head-1"))
        let entry = try XCTUnwrap(store.displayedEntries.first)
        XCTAssertEqual(entry.slug, "schnaq/review#42")
        XCTAssertEqual(entry.title, "Bump the client")
        XCTAssertEqual(entry.headRefOid, "head-1")
        XCTAssertEqual(entry.mergeMethod, "squash")
        XCTAssertEqual(entry.authorLogin, "claude[bot]")
        XCTAssertEqual(entry.checkCount, 4)
        XCTAssertEqual(entry.queuedAt, clock)
        XCTAssertEqual(queued.map(\.entry), [entry])
    }

    func testASecondPassOverTheSameCommitAsksForNothing() async {
        let harness = Harness()
        let coordinator = makeCoordinator(settings: makeSettings(), harness: harness)
        let rows = [mergeable()]

        _ = await run(coordinator, rows: rows, harness: harness)
        _ = await run(coordinator, rows: rows, harness: harness)

        XCTAssertEqual(harness.writes.count, 1, "every sweep re-considers every row")
        XCTAssertEqual(coordinator.skipReason(forPullRequestID: "PR_1"), .alreadyQueued)
        XCTAssertEqual(harness.notices.count, 1, "and it is not announced twice either")
    }

    func testANewHeadCommitIsQueuedAgain() async {
        let harness = Harness()
        let coordinator = makeCoordinator(settings: makeSettings(), harness: harness)

        _ = await run(coordinator, rows: [mergeable(headRefOid: "head-1")], harness: harness)
        _ = await run(coordinator, rows: [mergeable(headRefOid: "head-2")], harness: harness)

        XCTAssertEqual(harness.writes.map(\.headRefOid), ["head-1", "head-2"])
        XCTAssertEqual(coordinator.auditEntryCount, 2)
    }

    func testABatchQueuesEveryEligibleRowAndAnnouncesItOnce() async throws {
        let harness = Harness()
        let coordinator = makeCoordinator(settings: makeSettings(), harness: harness)
        let rows = [
            mergeable(id: "PR_1", number: 1, headRefOid: "head-1"),
            // Not approved: the one row in the batch that must be left alone.
            mergeable(id: "PR_2", number: 2, headRefOid: "head-2", reviewDecision: nil),
            mergeable(id: "PR_3", number: 3, headRefOid: "head-3"),
        ]

        let queued = await run(coordinator, rows: rows, harness: harness)

        XCTAssertEqual(queued.map(\.pullRequest.id), ["PR_1", "PR_3"])
        XCTAssertEqual(harness.writes.map(\.prID), ["PR_1", "PR_3"])
        XCTAssertEqual(coordinator.skipReason(forPullRequestID: "PR_2"), .notApproved)
        // One banner for the pass, not one per merge.
        XCTAssertEqual(harness.notices.count, 1)
        let notice = try XCTUnwrap(harness.notices.first)
        XCTAssertTrue(notice.title.contains("2 pull requests"))
        XCTAssertTrue(notice.body.contains("schnaq/review#1"))
        XCTAssertTrue(notice.body.contains("schnaq/review#3"))
    }

    func testTheSingleMergeNoticeSaysQueuedRatherThanMerged() async throws {
        let harness = Harness()
        let coordinator = makeCoordinator(settings: makeSettings(method: .rebase), harness: harness)
        _ = await run(coordinator, rows: [mergeable()], harness: harness)

        let notice = try XCTUnwrap(harness.notices.first)
        XCTAssertTrue(notice.title.contains("schnaq/review#42"))
        XCTAssertTrue(
            notice.title.lowercased().contains("queued"),
            "the outbox has not sent anything yet, and the banner must not claim it has"
        )
        XCTAssertTrue(notice.body.contains("rebase"))
        XCTAssertEqual(notice.identifier, "auto-merge-PR_1-head-1")
    }

    // MARK: - Not queueing

    func testNothingHappensWhileTheFeatureIsOff() async {
        let harness = Harness()
        let store = AutoMergeStore(defaults: defaults, key: "test.autoMerge")
        let coordinator = makeCoordinator(
            settings: makeSettings(isEnabled: false),
            store: store,
            harness: harness
        )

        let queued = await run(coordinator, rows: [mergeable()], harness: harness)

        XCTAssertTrue(queued.isEmpty)
        XCTAssertTrue(harness.writes.isEmpty)
        XCTAssertTrue(harness.notices.isEmpty)
        XCTAssertEqual(store.entryCount, 0)
        XCTAssertNil(
            coordinator.skipReason(forPullRequestID: "PR_1"),
            "the switch is checked before anything is decided at all"
        )
    }

    func testAPullRequestWithAWriteAlreadyInTheOutboxIsLeftAlone() async {
        let harness = Harness()
        let coordinator = makeCoordinator(settings: makeSettings(), harness: harness)

        let queued = await run(
            coordinator,
            rows: [mergeable()],
            existingOutbox: ["PR_1"],
            harness: harness
        )

        XCTAssertTrue(queued.isEmpty)
        XCTAssertTrue(harness.writes.isEmpty)
        XCTAssertEqual(coordinator.skipReason(forPullRequestID: "PR_1"), .writeInFlight)
    }

    func testTheAllowListAndTheRequiredLabelsNarrowThePass() async {
        let harness = Harness()
        let coordinator = makeCoordinator(
            settings: makeSettings(
                allowedRepositories: ["schnaq/*"],
                requiredLabels: ["automerge"]
            ),
            harness: harness
        )

        _ = await run(coordinator, rows: [mergeable()], harness: harness)
        XCTAssertTrue(harness.writes.isEmpty)
        XCTAssertEqual(coordinator.skipReason(forPullRequestID: "PR_1"), .requiredLabelMissing)

        _ = await run(coordinator, rows: [mergeable(labels: ["automerge"])], harness: harness)
        XCTAssertEqual(harness.writes.map(\.prID), ["PR_1"])
    }

    func testTheLedgerSurvivesARelaunch() async {
        let harness = Harness()
        let settings = makeSettings()
        let rows = [mergeable()]

        let first = makeCoordinator(
            settings: settings,
            store: AutoMergeStore(defaults: defaults, key: "test.autoMerge"),
            harness: harness
        )
        _ = await run(first, rows: rows, harness: harness)

        // A second store over the same defaults is what the next launch sees.
        let second = makeCoordinator(
            settings: settings,
            store: AutoMergeStore(defaults: defaults, key: "test.autoMerge"),
            harness: harness
        )
        _ = await run(second, rows: rows, harness: harness)

        XCTAssertEqual(
            harness.writes.count,
            1,
            "restarting the app must not queue a merge it already queued"
        )
        XCTAssertEqual(second.skipReason(forPullRequestID: "PR_1"), .alreadyQueued)
    }

    // MARK: - The audit log

    func testTheAuditLogShowsTheNewestFirstAndIsCappedForDisplay() async {
        let harness = Harness()
        let store = AutoMergeStore(defaults: defaults, key: "test.autoMerge")
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            store: store,
            harness: harness
        )
        let total = AutoMergeStore.displayedEntryCount + 3
        let rows = (0..<total).map { index in
            mergeable(id: "PR_\(index)", number: index, headRefOid: "head-\(index)")
        }

        _ = await run(coordinator, rows: rows, harness: harness)

        XCTAssertEqual(coordinator.auditEntryCount, total)
        XCTAssertEqual(coordinator.auditEntries.count, AutoMergeStore.displayedEntryCount)
        XCTAssertEqual(coordinator.auditEntries.first?.prID, "PR_\(total - 1)")
    }

    func testClearingTheLogAlsoClearsTheDeduplicationItIs() async {
        let harness = Harness()
        let store = AutoMergeStore(defaults: defaults, key: "test.autoMerge")
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            store: store,
            harness: harness
        )
        _ = await run(coordinator, rows: [mergeable()], harness: harness)
        XCTAssertEqual(store.entryCount, 1)

        store.clear()
        XCTAssertEqual(store.entryCount, 0)
        // Documented consequence: the only pull requests this can affect are ones still open and
        // still eligible, where queueing the merge again is the right answer — and the outbox
        // check refuses it while the first write is still unsent.
        _ = await run(coordinator, rows: [mergeable()], harness: harness)
        XCTAssertEqual(harness.writes.count, 2)
    }

    func testResetForgetsTheLogWithTheAccount() async {
        let harness = Harness()
        let coordinator = makeCoordinator(settings: makeSettings(), harness: harness)
        _ = await run(coordinator, rows: [mergeable()], harness: harness)
        XCTAssertEqual(coordinator.auditEntryCount, 1)

        coordinator.reset()

        XCTAssertEqual(coordinator.auditEntryCount, 0)
        XCTAssertNil(coordinator.skipReason(forPullRequestID: "PR_1"))
    }

    // MARK: - The webhook (ADR 0012, additive)

    func testTheWebhookEventReportsTheDecisionAndCarriesThePullRequest() async throws {
        let harness = Harness()
        let coordinator = makeCoordinator(settings: makeSettings(), harness: harness)
        let queued = await run(
            coordinator,
            rows: [mergeable(labels: ["automerge"])],
            harness: harness
        )
        let write = try XCTUnwrap(queued.first)

        let plan = WebhookCoordinator.plan(for: write)
        XCTAssertEqual(plan.kind, .autoMergeQueued)
        XCTAssertEqual(plan.identity.prID, "PR_1")
        XCTAssertEqual(plan.identity.number, 42)
        XCTAssertEqual(plan.occurredAt, clock)
        // Carried, not looked up: the row is about to leave the inbox.
        XCTAssertEqual(plan.summary?.id, "PR_1")
        XCTAssertEqual(
            plan.details,
            .autoMergeQueued(mergeMethod: "squash", checkCount: 4, matchedLabels: [])
        )
        XCTAssertEqual(WebhookEventKind.autoMergeQueued.rawValue, "pr.auto_merge_queued")
    }

    // MARK: - Settings

    func testTheRulesAreOffOnAFreshInstallAndRoundTripThroughUserDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.autoMerge.isEnabled)
        XCTAssertTrue(settings.autoMerge.allowedRepositories.isEmpty)
        XCTAssertTrue(settings.autoMerge.requiredLabels.isEmpty)

        settings.autoMerge.isEnabled = true
        settings.autoMerge.allowedRepositories = ["schnaq/*"]
        settings.autoMerge.requiredLabels = ["automerge"]
        settings.defaultMergeMethod = .rebase

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.autoMerge.isEnabled)
        XCTAssertEqual(reloaded.autoMerge.allowedRepositories, ["schnaq/*"])
        XCTAssertEqual(reloaded.autoMerge.requiredLabels, ["automerge"])
        // The method is the app's one remembered merge method, not a second copy (ADR 0015).
        XCTAssertEqual(reloaded.autoMergeMethod, .rebase)
    }
}
