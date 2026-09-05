import Foundation
import ShepherdCore
import ShepherdSync
import XCTest

@testable import Shepherd

/// The app half of automatic delegation (ADR 0016): mapping sweep events onto signals, reserving
/// the slot in the persistent ledger, and announcing what happened.
///
/// The *decision* itself is covered exhaustively by `AutoDelegationPolicyTests` in ShepherdKit.
/// What is tested here is the wiring the policy cannot see: that the ledger survives a relaunch,
/// that a notification is posted for every start, and that nothing outside the two transition
/// events can ever become a signal.
@MainActor
final class AutoDelegationTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let clock = Date(timeIntervalSince1970: 1_788_162_000)
    /// The zone the coordinator under test counts days in; passed explicitly everywhere so the
    /// runner's own time zone cannot decide what "today" means.
    private let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt

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

    /// Collects what would have been shown to the user.
    private final class NoticeCollector {
        var payloads: [NotificationPayload] = []
    }

    private func summary(
        id: String = "PR_1",
        headRefOid: String = "head-1",
        relations: Set<Relation> = [.author],
        checkState: CheckRollup.State? = .failure,
        reviewDecision: ReviewDecision? = nil
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: 42,
            title: "Fix the off-by-one",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: clock,
            createdAt: clock,
            isDraft: false,
            headRefName: "feature",
            headRefOid: headRefOid,
            baseRefName: "main",
            reviewDecision: reviewDecision,
            checkRollup: checkState.map { CheckRollup(state: $0, total: 3, failureCount: 1) },
            myRelation: relations
        )
    }

    private func checksFailedEvent(
        _ summary: PullRequestSummary,
        wasTracked: Bool = true
    ) -> SyncEvent {
        .checksFailedOnOwnPR(
            ChecksFailure(
                summary: summary,
                previousState: wasTracked ? .success : nil,
                wasTracked: wasTracked
            )
        )
    }

    private func makeSettings(
        isEnabled: Bool = true,
        triggers: Set<AutoDelegationTrigger> = [.checksFailed],
        maxPerDay: Int = 5,
        maxConcurrent: Int = 1
    ) -> AppSettings {
        let settings = AppSettings(defaults: defaults)
        settings.autoDelegation = AutoDelegationRules(
            isEnabled: isEnabled,
            triggers: triggers,
            maxConcurrent: maxConcurrent,
            maxPerDay: maxPerDay
        )
        return settings
    }

    private func makeCoordinator(
        settings: AppSettings,
        store: AutoDelegationStore? = nil,
        center: DelegationCenter = DelegationCenter(),
        isConfigured: Bool = true,
        now: Date? = nil,
        notices: NoticeCollector
    ) -> AutoDelegationCoordinator {
        let fixedNow = now ?? clock
        return AutoDelegationCoordinator(
            settings: settings,
            delegation: center,
            store: store ?? AutoDelegationStore(defaults: defaults, key: "test.ledger"),
            now: { fixedNow },
            timeZone: zone,
            isConfigured: { _ in isConfigured },
            notify: { notices.payloads.append($0) }
        )
    }

    // MARK: - Starting

    func testARedCITransitionOnAnOwnPullRequestIsPlannedAndAnnounced() throws {
        let notices = NoticeCollector()
        let store = AutoDelegationStore(defaults: defaults, key: "test.ledger")
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            store: store,
            notices: notices
        )

        let plan = try XCTUnwrap(coordinator.plan(for: checksFailedEvent(summary())))
        XCTAssertEqual(plan.trigger, .checksFailed)
        XCTAssertEqual(plan.pullRequest.id, "PR_1")
        XCTAssertTrue(plan.task.contains("#42"))

        // The slot is reserved before the caller starts anything.
        XCTAssertEqual(store.startsToday(now: clock, timeZone: zone), 1)
        XCTAssertTrue(store.hasHandled(plan.fingerprint))

        let notice = try XCTUnwrap(notices.payloads.first)
        XCTAssertTrue(notice.title.contains("schnaq/review#42"))
        XCTAssertTrue(notice.title.contains("Claude Code"))
        XCTAssertTrue(notice.title.contains("CI failed"))
    }

    func testTheSameHeadCommitIsPlannedOnlyOnce() {
        let notices = NoticeCollector()
        let coordinator = makeCoordinator(settings: makeSettings(), notices: notices)
        let event = checksFailedEvent(summary())

        XCTAssertNotNil(coordinator.plan(for: event))
        XCTAssertNil(coordinator.plan(for: event), "a second red check on the same commit")
        XCTAssertEqual(coordinator.lastDecision?.skipReason, .alreadyHandled)
        XCTAssertEqual(notices.payloads.count, 1, "and it is not announced twice either")
    }

    func testANewHeadCommitIsPlannedAgain() {
        let notices = NoticeCollector()
        let coordinator = makeCoordinator(settings: makeSettings(), notices: notices)

        XCTAssertNotNil(coordinator.plan(for: checksFailedEvent(summary(headRefOid: "head-1"))))
        XCTAssertNotNil(coordinator.plan(for: checksFailedEvent(summary(headRefOid: "head-2"))))
        XCTAssertEqual(notices.payloads.count, 2)
    }

    func testTheLedgerSurvivesARelaunch() {
        let notices = NoticeCollector()
        let settings = makeSettings()
        let event = checksFailedEvent(summary())

        let first = makeCoordinator(
            settings: settings,
            store: AutoDelegationStore(defaults: defaults, key: "test.ledger"),
            notices: notices
        )
        XCTAssertNotNil(first.plan(for: event))

        // A second store over the same defaults is what the next launch sees.
        let second = makeCoordinator(
            settings: settings,
            store: AutoDelegationStore(defaults: defaults, key: "test.ledger"),
            notices: notices
        )
        XCTAssertNil(
            second.plan(for: event),
            "restarting the app must not re-delegate work the agent already got"
        )
        XCTAssertEqual(second.lastDecision?.skipReason, .alreadyHandled)
    }

    // MARK: - Not starting

    func testNothingIsPlannedWhileTheFeatureIsOff() {
        let notices = NoticeCollector()
        let store = AutoDelegationStore(defaults: defaults, key: "test.ledger")
        let coordinator = makeCoordinator(
            settings: makeSettings(isEnabled: false),
            store: store,
            notices: notices
        )

        XCTAssertNil(coordinator.plan(for: checksFailedEvent(summary())))
        XCTAssertNil(coordinator.lastDecision, "the switch is checked before anything else")
        XCTAssertEqual(store.startsToday(now: clock, timeZone: zone), 0)
        XCTAssertTrue(notices.payloads.isEmpty)
    }

    func testAConditionThatIsNotTickedIsNotEvenEvaluated() {
        let notices = NoticeCollector()
        let coordinator = makeCoordinator(
            settings: makeSettings(triggers: [.checksFailed]),
            notices: notices
        )
        let event = SyncEvent.changesRequestedOnOwnPR(
            ChangesRequested(
                summary: summary(reviewDecision: .changesRequested),
                previousDecision: .reviewRequired,
                wasTracked: true
            )
        )
        XCTAssertNil(coordinator.plan(for: event))
        XCTAssertNil(coordinator.lastDecision)
    }

    func testAPullRequestThatWasAlreadyRedIsNotPlanned() {
        let notices = NoticeCollector()
        let coordinator = makeCoordinator(settings: makeSettings(), notices: notices)

        XCTAssertNil(
            coordinator.plan(for: checksFailedEvent(summary(), wasTracked: false))
        )
        XCTAssertEqual(coordinator.lastDecision?.skipReason, .notATransition)
        XCTAssertTrue(notices.payloads.isEmpty, "a non-event is not worth a notification")
    }

    func testAnUnconfiguredRepositoryIsNotPlanned() {
        let notices = NoticeCollector()
        let coordinator = makeCoordinator(
            settings: makeSettings(),
            isConfigured: false,
            notices: notices
        )
        XCTAssertNil(coordinator.plan(for: checksFailedEvent(summary())))
        XCTAssertEqual(coordinator.lastDecision?.skipReason, .notConfigured)
    }

    func testTheDailyCapNotifiesInsteadOfStarting() throws {
        let notices = NoticeCollector()
        let coordinator = makeCoordinator(
            settings: makeSettings(maxPerDay: 1),
            notices: notices
        )

        XCTAssertNotNil(coordinator.plan(for: checksFailedEvent(summary(id: "PR_1"))))
        XCTAssertNil(
            coordinator.plan(
                for: checksFailedEvent(summary(id: "PR_2", headRefOid: "head-2"))
            )
        )
        XCTAssertEqual(coordinator.lastDecision?.skipReason, .dailyCapReached)

        // Two notices: the start, then the one that says a cap stopped the next one.
        XCTAssertEqual(notices.payloads.count, 2)
        let capped = try XCTUnwrap(notices.payloads.last)
        XCTAssertTrue(capped.title.contains("Not auto-delegated"))
        XCTAssertTrue(capped.body.contains("1"))
    }

    func testACapNoticeIsPostedOncePerCommitRatherThanOnEverySweep() {
        // The identifier is keyed on the head commit, so macOS replaces the previous notice
        // instead of stacking one per sweep.
        let notices = NoticeCollector()
        let coordinator = makeCoordinator(
            settings: makeSettings(maxPerDay: 1),
            notices: notices
        )
        _ = coordinator.plan(for: checksFailedEvent(summary(id: "PR_1")))
        let blocked = checksFailedEvent(summary(id: "PR_2", headRefOid: "head-2"))
        _ = coordinator.plan(for: blocked)
        _ = coordinator.plan(for: blocked)
        XCTAssertEqual(
            Set(notices.payloads.dropFirst().map(\.identifier)).count,
            1
        )
    }

    func testResetForgetsWhatWasAlreadyHandled() {
        let notices = NoticeCollector()
        let coordinator = makeCoordinator(settings: makeSettings(), notices: notices)
        let event = checksFailedEvent(summary())

        XCTAssertNotNil(coordinator.plan(for: event))
        coordinator.reset()
        XCTAssertNil(coordinator.lastDecision)
        XCTAssertEqual(coordinator.startsToday, 0)
        XCTAssertNotNil(coordinator.plan(for: event), "the ledger was cleared with the account")
    }

    // MARK: - Mapping

    func testOnlyTheTwoTransitionEventsBecomeSignals() {
        let summary = summary()
        XCTAssertEqual(
            AutoDelegationCoordinator.signal(for: checksFailedEvent(summary))?.trigger,
            .checksFailed
        )
        XCTAssertEqual(
            AutoDelegationCoordinator.signal(
                for: .changesRequestedOnOwnPR(
                    ChangesRequested(
                        summary: summary,
                        previousDecision: nil,
                        wasTracked: true
                    )
                )
            )?.trigger,
            .changesRequested
        )

        let ignored: [SyncEvent] = [
            .newReviewRequest(summary),
            .prMerged(summary),
            // "Something moved" is not a condition, however often it fires.
            .prUpdated(summary),
            .draftConflict(
                DraftConflict(
                    prID: "PR_1",
                    repo: repo,
                    number: 42,
                    expectedHeadOid: "a",
                    actualHeadOid: "b"
                )
            ),
            .mutationSent(
                SentMutation(
                    prID: "PR_1",
                    repo: repo,
                    number: 42,
                    kind: .merged(method: "squash"),
                    sentAt: clock
                )
            ),
            .syncFailed(SyncFailure(stage: .sweep, message: "nope")),
            // The one event that names no pull request at all, so there is nothing a rule could
            // even be about.
            .sweepCompleted(SweepCompletion(finishedAt: clock)),
        ]
        for event in ignored {
            XCTAssertNil(
                AutoDelegationCoordinator.signal(for: event),
                "this event must never start an agent"
            )
        }
    }

    func testTheTransitionFlagIsCarriedThroughFromTheEvent() {
        let tracked = AutoDelegationCoordinator.signal(
            for: checksFailedEvent(summary(), wasTracked: true)
        )
        XCTAssertEqual(tracked?.isTransition, true)
        let firstSighting = AutoDelegationCoordinator.signal(
            for: checksFailedEvent(summary(), wasTracked: false)
        )
        XCTAssertEqual(firstSighting?.isTransition, false)
    }

    // MARK: - Settings

    func testTheRulesAreOffOnAFreshInstallAndRoundTripThroughUserDefaults() throws {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.autoDelegation.isEnabled)
        XCTAssertEqual(settings.autoDelegation.triggers, [.checksFailed])

        settings.autoDelegation.isEnabled = true
        settings.autoDelegation.triggers = [.checksFailed, .changesRequested]
        settings.autoDelegation.maxPerDay = 9
        settings.autoDelegation.promptTemplate = "fix #{number}"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.autoDelegation.isEnabled)
        XCTAssertEqual(reloaded.autoDelegation.triggers, [.checksFailed, .changesRequested])
        XCTAssertEqual(reloaded.autoDelegation.maxPerDay, 9)
        XCTAssertEqual(reloaded.autoDelegation.promptTemplate, "fix #{number}")
    }
}
