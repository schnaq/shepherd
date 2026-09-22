import Foundation
import GitHubKit
import ShepherdCore
import XCTest

@testable import Shepherd

/// The app half of "merge when checks pass" (ADR 0037): arming a merge from the sheet, keeping it
/// across a relaunch, firing it on the sweep that sees the checks go green, and dropping it — with
/// a word to the user — when the commit they judged is no longer the one that would be merged.
///
/// The *decision* is covered by `MergeWhenGreenPolicyTests` in ShepherdKit. What is tested here is
/// the wiring the policy cannot see: that a pass asks for one merge and not two, that the write
/// carries the method and the branch answer the sheet showed rather than today's settings, that
/// an arm survives a relaunch, and that the notices say what happened.
@MainActor
final class MergeWhenGreenTests: XCTestCase {
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

    private struct WriteRequest: Equatable {
        var prID: String
        var headRefOid: String
        var method: MergeMethod
        var deletesHeadBranch: Bool
    }

    @MainActor
    private final class Harness {
        var writes: [WriteRequest] = []
        var notices: [NotificationPayload] = []
    }

    private func row(
        id: String = "PR_1",
        number: Int = 42,
        headRefOid: String = "head-1",
        isDraft: Bool = false,
        checkState: CheckRollup.State? = .pending,
        mergeable: Mergeable? = .mergeable
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: "Bump the client",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: clock,
            createdAt: clock,
            isDraft: isDraft,
            headRefName: "feature",
            headRefOid: headRefOid,
            baseRefName: "main",
            reviewDecision: .approved,
            checkRollup: checkState.map { state in
                CheckRollup(
                    state: state,
                    total: 4,
                    successCount: state == .success ? 4 : 2,
                    failureCount: state == .failure ? 1 : 0,
                    pendingCount: state == .pending ? 2 : 0
                )
            },
            myRelation: [.reviewRequested],
            mergeable: mergeable
        )
    }

    private func makeCoordinator(
        store: MergeWhenGreenStore? = nil,
        harness: Harness
    ) -> MergeWhenGreenCoordinator {
        let settings = AppSettings(defaults: defaults)
        settings.defaultMergeMethod = .merge
        let fixedNow = clock
        return MergeWhenGreenCoordinator(
            settings: settings,
            store: store ?? MergeWhenGreenStore(defaults: defaults, key: "test.mergeWhenGreen"),
            now: { fixedNow },
            notify: { harness.notices.append($0) }
        )
    }

    private func run(
        _ coordinator: MergeWhenGreenCoordinator,
        rows: [PullRequestSummary],
        existingOutbox: Set<String> = [],
        harness: Harness
    ) async -> MergeWhenGreenPassResult {
        await coordinator.run(
            rows: rows,
            existingOutbox: existingOutbox,
            write: { summary, method, deletesHeadBranch in
                harness.writes.append(
                    WriteRequest(
                        prID: summary.id,
                        headRefOid: summary.headRefOid,
                        method: method,
                        deletesHeadBranch: deletesHeadBranch
                    )
                )
            }
        )
    }

    // MARK: - Arming

    func testArmingRecordsWhatTheSheetShowed() {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)

        let request = coordinator.arm(row(), method: .squash, deletesHeadBranch: true)

        XCTAssertEqual(request.prID, "PR_1")
        XCTAssertEqual(request.slug, "schnaq/review#42")
        XCTAssertEqual(request.headRefOid, "head-1")
        XCTAssertEqual(request.mergeMethod, "squash")
        XCTAssertTrue(request.deletesHeadBranch)
        XCTAssertEqual(request.armedAt, clock)
        XCTAssertTrue(coordinator.isArmed(row()))
        XCTAssertFalse(coordinator.isArmed(row(headRefOid: "head-2")), "an arm is about a commit")
        XCTAssertEqual(coordinator.armedCount, 1)
        XCTAssertTrue(harness.notices.isEmpty, "the click itself is announced by a toast, not a banner")
    }

    func testDisarmingForgetsThePullRequest() {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)
        coordinator.arm(row(), method: .squash, deletesHeadBranch: false)

        coordinator.disarm(pullRequestID: "PR_1")

        XCTAssertFalse(coordinator.isArmed(row()))
        XCTAssertEqual(coordinator.armedCount, 0)
    }

    func testAnArmSurvivesARelaunch() {
        let harness = Harness()
        let first = MergeWhenGreenStore(defaults: defaults, key: "test.mergeWhenGreen")
        makeCoordinator(store: first, harness: harness)
            .arm(row(), method: .rebase, deletesHeadBranch: true)

        // A second store on the same suite is what a relaunch sees.
        let second = MergeWhenGreenStore(defaults: defaults, key: "test.mergeWhenGreen")
        let request = second.request(forPullRequestID: "PR_1")
        XCTAssertEqual(request?.headRefOid, "head-1")
        XCTAssertEqual(request?.mergeMethod, "rebase")
        XCTAssertEqual(request?.deletesHeadBranch, true)
    }

    // MARK: - Firing

    func testGreenChecksOnTheArmedHeadQueueTheMergeTheUserAskedFor() async throws {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)
        coordinator.arm(row(checkState: .pending), method: .squash, deletesHeadBranch: true)

        let result = await run(coordinator, rows: [row(checkState: .success)], harness: harness)

        XCTAssertEqual(
            harness.writes,
            [WriteRequest(prID: "PR_1", headRefOid: "head-1", method: .squash, deletesHeadBranch: true)],
            "the method and the branch answer are the sheet's, not today's settings"
        )
        XCTAssertEqual(result.queued.map(\.request.prID), ["PR_1"])
        XCTAssertTrue(result.abandoned.isEmpty)
        XCTAssertFalse(coordinator.isArmed(row()), "an arm is spent once its merge is queued")
        let notice = try XCTUnwrap(harness.notices.first)
        XCTAssertTrue(notice.title.contains("schnaq/review#42"), notice.title)
        XCTAssertTrue(notice.body.localizedCaseInsensitiveContains("queued"), notice.body)
    }

    func testRunningChecksKeepTheArmAndAskForNothing() async {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)
        coordinator.arm(row(), method: .squash, deletesHeadBranch: false)

        let result = await run(coordinator, rows: [row(checkState: .pending)], harness: harness)

        XCTAssertTrue(harness.writes.isEmpty)
        XCTAssertTrue(result.queued.isEmpty)
        XCTAssertTrue(result.abandoned.isEmpty)
        XCTAssertTrue(coordinator.isArmed(row()))
        XCTAssertTrue(harness.notices.isEmpty, "waiting is not news")
    }

    func testASecondPassAfterTheMergeWasQueuedAsksForNothing() async {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)
        coordinator.arm(row(), method: .squash, deletesHeadBranch: false)
        let green = [row(checkState: .success)]

        _ = await run(coordinator, rows: green, harness: harness)
        _ = await run(coordinator, rows: green, harness: harness)

        XCTAssertEqual(harness.writes.count, 1, "the arm is spent by the first pass")
        XCTAssertEqual(harness.notices.count, 1)
    }

    func testAWriteAlreadyInTheOutboxWaitsInsteadOfStackingASecondMerge() async {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)
        coordinator.arm(row(), method: .squash, deletesHeadBranch: false)

        _ = await run(
            coordinator,
            rows: [row(checkState: .success)],
            existingOutbox: ["PR_1"],
            harness: harness
        )

        XCTAssertTrue(harness.writes.isEmpty)
        XCTAssertTrue(coordinator.isArmed(row()), "kept for the sweep after the outbox drains")
    }

    func testAnUnreadableMethodFallsBackToTheRememberedOne() async throws {
        let harness = Harness()
        let store = MergeWhenGreenStore(defaults: defaults, key: "test.mergeWhenGreen")
        store.arm(
            MergeWhenGreenRequest(
                prID: "PR_1",
                slug: "schnaq/review#42",
                title: "Bump the client",
                headRefOid: "head-1",
                mergeMethod: "not-a-method",
                deletesHeadBranch: false,
                armedAt: clock
            )
        )
        let coordinator = makeCoordinator(store: store, harness: harness)

        _ = await run(coordinator, rows: [row(checkState: .success)], harness: harness)

        XCTAssertEqual(harness.writes.first?.method, .merge, "`defaultMergeMethod` in this test")
    }

    // MARK: - Abandoning

    func testANewPushDropsTheArmAndSaysSo() async throws {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)
        coordinator.arm(row(headRefOid: "head-1"), method: .squash, deletesHeadBranch: false)

        let result = await run(
            coordinator,
            rows: [row(headRefOid: "head-2", checkState: .success)],
            harness: harness
        )

        XCTAssertTrue(harness.writes.isEmpty, "a commit nobody judged is never merged")
        XCTAssertEqual(result.abandoned.map(\.reason), [.headMoved])
        XCTAssertFalse(coordinator.isArmed(row(headRefOid: "head-1")))
        XCTAssertFalse(coordinator.isArmed(row(headRefOid: "head-2")))
        let notice = try XCTUnwrap(harness.notices.first)
        XCTAssertTrue(notice.title.contains("schnaq/review#42"), notice.title)
        XCTAssertTrue(notice.body.localizedCaseInsensitiveContains("push"), notice.body)
    }

    func testFailingChecksDropTheArmAndSaySo() async throws {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)
        coordinator.arm(row(), method: .squash, deletesHeadBranch: false)

        let result = await run(coordinator, rows: [row(checkState: .failure)], harness: harness)

        XCTAssertTrue(harness.writes.isEmpty)
        XCTAssertEqual(result.abandoned.map(\.reason), [.checksFailed])
        XCTAssertFalse(coordinator.isArmed(row()))
        let notice = try XCTUnwrap(harness.notices.first)
        XCTAssertTrue(notice.body.localizedCaseInsensitiveContains("fail"), notice.body)
    }

    func testAPullRequestMissingFromOneSweepKeepsItsArm() async {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)
        coordinator.arm(row(), method: .squash, deletesHeadBranch: false)

        let result = await run(coordinator, rows: [], harness: harness)

        XCTAssertTrue(harness.writes.isEmpty)
        XCTAssertTrue(result.abandoned.isEmpty, "a search that is one sweep behind is not a decision")
        XCTAssertTrue(coordinator.isArmed(row()), "kept for the sweep that brings the row back")
        XCTAssertTrue(harness.notices.isEmpty)

        // And when the row comes back green, the decision still stands.
        _ = await run(coordinator, rows: [row(checkState: .success)], harness: harness)
        XCTAssertEqual(harness.writes.count, 1)
    }

    func testAPullRequestMissingForLongerThanTheGracePeriodIsForgottenQuietly() async {
        let harness = Harness()
        let store = MergeWhenGreenStore(defaults: defaults, key: "test.mergeWhenGreen")
        store.arm(
            MergeWhenGreenRequest(
                prID: "PR_1",
                slug: "schnaq/review#42",
                title: "Bump the client",
                headRefOid: "head-1",
                mergeMethod: "squash",
                deletesHeadBranch: false,
                armedAt: clock.addingTimeInterval(-MergeWhenGreenCoordinator.missingRowGracePeriod - 60)
            )
        )
        let coordinator = makeCoordinator(store: store, harness: harness)

        let result = await run(coordinator, rows: [], harness: harness)

        XCTAssertTrue(result.abandoned.isEmpty, "somebody else merged or closed it — not Shepherd's news")
        XCTAssertEqual(coordinator.armedCount, 0)
        XCTAssertTrue(harness.notices.isEmpty)
    }

    func testAPassWithNothingArmedNeverLooksAtTheRows() async {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)

        let result = await run(coordinator, rows: [row(checkState: .success)], harness: harness)

        XCTAssertTrue(result.queued.isEmpty)
        XCTAssertTrue(harness.writes.isEmpty)
    }

    func testResetForgetsEveryArm() {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)
        coordinator.arm(row(id: "PR_1"), method: .squash, deletesHeadBranch: false)
        coordinator.arm(row(id: "PR_2", number: 43), method: .squash, deletesHeadBranch: false)

        coordinator.reset()

        XCTAssertEqual(coordinator.armedCount, 0)
    }

    // MARK: - Notices

    func testOneNoticeCoversSeveralMergesQueuedInOnePass() async {
        let harness = Harness()
        let coordinator = makeCoordinator(harness: harness)
        coordinator.arm(row(id: "PR_1", number: 1), method: .squash, deletesHeadBranch: false)
        coordinator.arm(row(id: "PR_2", number: 2), method: .squash, deletesHeadBranch: false)

        _ = await run(
            coordinator,
            rows: [row(id: "PR_1", number: 1, checkState: .success), row(id: "PR_2", number: 2, checkState: .success)],
            harness: harness
        )

        XCTAssertEqual(harness.writes.count, 2)
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertTrue(harness.notices.first?.title.contains("2") ?? false, harness.notices.first?.title ?? "")
    }
}
