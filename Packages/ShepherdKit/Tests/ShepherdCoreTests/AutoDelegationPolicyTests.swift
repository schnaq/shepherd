import Foundation
import XCTest

@testable import ShepherdCore

/// The auto-delegation decision, branch by branch (ADR 0016).
///
/// This is the file that has to be exhaustive: everything the feature can do wrong — running on
/// somebody else's pull request, running twice for one commit, running on a state instead of a
/// change, ignoring a cap — is a case here.
final class AutoDelegationPolicyTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    /// A fixed clock: 2025-08-31 02:26 in Berlin, safely away from a day boundary.
    private let clock = Fixtures.date(0)

    // MARK: - Helpers

    private func rules(
        isEnabled: Bool = true,
        triggers: Set<AutoDelegationTrigger> = [.checksFailed],
        promptTemplate: String = AutoDelegationRules.defaultPromptTemplate,
        maxConcurrent: Int = 1,
        maxPerDay: Int = 5
    ) -> AutoDelegationRules {
        AutoDelegationRules(
            isEnabled: isEnabled,
            triggers: triggers,
            promptTemplate: promptTemplate,
            maxConcurrent: maxConcurrent,
            maxPerDay: maxPerDay
        )
    }

    /// A pull request the signed-in user opened, with red CI.
    private func ownRedPullRequest(
        id: String = "PR_1",
        headRefOid: String = "abc123abc123def",
        relations: Set<Relation> = [.author],
        author: ShepherdCore.Actor = Fixtures.makeActor("octocat")
    ) -> PullRequestSummary {
        Fixtures.summary(
            id: id,
            number: 42,
            author: author,
            headRefOid: headRefOid,
            checkRollup: CheckRollup(state: .failure, total: 7, successCount: 4, failureCount: 3),
            relations: relations
        )
    }

    private func signal(
        _ pullRequest: PullRequestSummary,
        trigger: AutoDelegationTrigger = .checksFailed,
        isTransition: Bool = true
    ) -> AutoDelegationSignal {
        AutoDelegationSignal(
            trigger: trigger,
            pullRequest: pullRequest,
            isTransition: isTransition
        )
    }

    private func context(
        rules: AutoDelegationRules? = nil,
        isConfigured: Bool = true,
        hasRunningDelegation: Bool = false,
        runningAutomaticCount: Int = 0,
        ledger: AutoDelegationLedger = AutoDelegationLedger(),
        now: Date? = nil
    ) -> AutoDelegationContext {
        AutoDelegationContext(
            rules: rules ?? self.rules(),
            isConfigured: isConfigured,
            hasRunningDelegation: hasRunningDelegation,
            runningAutomaticCount: runningAutomaticCount,
            ledger: ledger,
            now: now ?? clock,
            timeZone: timeZone
        )
    }

    private func decide(
        _ signal: AutoDelegationSignal,
        _ context: AutoDelegationContext
    ) -> AutoDelegationDecision {
        AutoDelegationPolicy.decide(signal, context: context)
    }

    // MARK: - The happy path

    func testRedCIOnAnOwnPullRequestStartsADelegationWithTheRenderedTask() throws {
        let pullRequest = ownRedPullRequest()
        let decision = decide(signal(pullRequest), context())

        let plan = try XCTUnwrap(decision.plan)
        XCTAssertEqual(plan.trigger, .checksFailed)
        XCTAssertEqual(plan.pullRequest.id, "PR_1")
        XCTAssertEqual(
            plan.fingerprint,
            AutoDelegationLedger.Fingerprint(
                prID: "PR_1",
                headRefOid: "abc123abc123def",
                trigger: .checksFailed
            )
        )
        // The default template names the pull request and the actual check counts.
        XCTAssertTrue(plan.task.contains("#42"))
        XCTAssertTrue(plan.task.contains("schnaq/review"))
        XCTAssertTrue(plan.task.contains("3 of 7 checks are failing"))
        XCTAssertTrue(plan.task.contains("CI turned red"))
        XCTAssertFalse(plan.task.contains("{"), "every placeholder was substituted")
    }

    func testEveryPlaceholderIsSubstituted() {
        let pullRequest = ownRedPullRequest()
        let template = AutoDelegationPrompt.placeholders.joined(separator: "\n")
        let rendered = AutoDelegationPrompt.render(
            template: template,
            signal: signal(pullRequest)
        )
        XCTAssertEqual(
            rendered.split(separator: "\n").map(String.init),
            [
                "42",
                "schnaq/review",
                "Fix the thing",
                "feature",
                // Twelve characters of the head commit, not the whole thing.
                "abc123abc123",
                "3 of 7 checks are failing",
                "CI turned red",
            ]
        )
    }

    func testAnEmptiedTemplateFallsBackToTheDefaultRatherThanStartingWithNoTask() {
        let pullRequest = ownRedPullRequest()
        let rendered = AutoDelegationPrompt.render(
            template: "   \n  ",
            signal: signal(pullRequest)
        )
        XCTAssertFalse(rendered.isEmpty)
        XCTAssertTrue(rendered.contains("#42"))
    }

    func testTheChecksSummaryCoversEveryRollupState() {
        func summary(_ rollup: CheckRollup?) -> String {
            AutoDelegationPrompt.checksSummary(
                for: Fixtures.summary(id: "PR_1", checkRollup: rollup)
            )
        }
        XCTAssertEqual(
            summary(CheckRollup(state: .failure, total: 4, failureCount: 1)),
            "1 of 4 checks are failing"
        )
        // A rollup that only knows its state (the cheap GraphQL sweep) still says something true.
        XCTAssertEqual(summary(CheckRollup(state: .failure)), "the rolled-up CI state is failing")
        XCTAssertEqual(summary(CheckRollup(state: .pending, total: 2)), "checks are still running")
        XCTAssertEqual(summary(CheckRollup(state: .success, total: 2)), "all checks are green")
        XCTAssertEqual(
            summary(CheckRollup(state: CheckRollup.State.none)),
            "no checks are reported for the head commit"
        )
        XCTAssertEqual(summary(nil), "no checks are reported for the head commit")
    }

    // MARK: - Off by default

    func testNothingHappensWhileAutomaticDelegationIsOff() {
        let decision = decide(
            signal(ownRedPullRequest()),
            context(rules: rules(isEnabled: false))
        )
        XCTAssertEqual(decision.skipReason, .disabled)
    }

    func testAFreshRuleSetIsOffAndArmsRedCIOnly() {
        let fresh = AutoDelegationRules()
        XCTAssertFalse(fresh.isEnabled)
        XCTAssertEqual(fresh.triggers, [.checksFailed])
        XCTAssertEqual(fresh.maxConcurrent, 1)
        XCTAssertEqual(fresh.maxPerDay, 5)
        XCTAssertFalse(fresh.isArmed(.checksFailed), "the master switch still has to be on")
    }

    func testAConditionThatIsNotTickedDoesNothing() {
        let decision = decide(
            signal(
                Fixtures.summary(
                    id: "PR_1",
                    reviewDecision: .changesRequested,
                    relations: [.author]
                ),
                trigger: .changesRequested
            ),
            context(rules: rules(triggers: [.checksFailed]))
        )
        XCTAssertEqual(decision.skipReason, .triggerNotArmed)
    }

    func testChangesRequestedStartsARunWhenItIsTicked() throws {
        let pullRequest = Fixtures.summary(
            id: "PR_1",
            number: 42,
            reviewDecision: .changesRequested,
            relations: [.author]
        )
        let decision = decide(
            signal(pullRequest, trigger: .changesRequested),
            context(rules: rules(triggers: [.checksFailed, .changesRequested]))
        )
        let plan = try XCTUnwrap(decision.plan)
        XCTAssertEqual(plan.trigger, .changesRequested)
        XCTAssertTrue(plan.task.contains("a reviewer requested changes"))
    }

    // MARK: - Whose pull request it is

    func testAPullRequestTheUserOnlyReviewsIsNeverTouched() {
        let decision = decide(
            signal(ownRedPullRequest(relations: [.reviewRequested])),
            context()
        )
        XCTAssertEqual(decision.skipReason, .notOwnPullRequest)
    }

    func testBeingMerelyMentionedOrInvolvedIsNotOwnership() {
        for relations in [Set<Relation>([.mentioned]), Set<Relation>()] {
            let decision = decide(
                signal(ownRedPullRequest(relations: relations)),
                context()
            )
            XCTAssertEqual(decision.skipReason, .notOwnPullRequest)
        }
    }

    func testAnAgentPullRequestAssignedToTheUserCountsAsTheirOwn() throws {
        // The normal shape of delegated work coming back: the agent opened it, the user owns it.
        let pullRequest = ownRedPullRequest(
            relations: [.assigned],
            author: Fixtures.makeActor(
                "claude[bot]",
                kind: Fixtures.agent("claude-code", "Claude Code")
            )
        )
        XCTAssertTrue(AutoDelegationPolicy.isOwn(pullRequest))
        XCTAssertNotNil(decide(signal(pullRequest), context()).plan)
    }

    func testAnAgentPullRequestTheUserIsNotAssignedToIsNotTheirOwn() {
        let pullRequest = ownRedPullRequest(
            relations: [.mentioned],
            author: Fixtures.makeActor(
                "claude[bot]",
                kind: Fixtures.agent("claude-code", "Claude Code")
            )
        )
        XCTAssertFalse(AutoDelegationPolicy.isOwn(pullRequest))
    }

    func testAHumanPullRequestAssignedToTheUserIsNotTheirOwnWork() {
        // Assignee on somebody else's pull request means "please look at this", not "this is
        // yours to rewrite with an agent".
        let pullRequest = ownRedPullRequest(
            relations: [.assigned],
            author: Fixtures.makeActor("somebody-else")
        )
        XCTAssertFalse(AutoDelegationPolicy.isOwn(pullRequest))
    }

    // MARK: - The edge, not the state

    func testAPullRequestThatWasAlreadyRedIsNotATransition() {
        let decision = decide(
            signal(ownRedPullRequest(), isTransition: false),
            context()
        )
        XCTAssertEqual(
            decision.skipReason,
            .notATransition,
            "the first sweep after a fresh install must not delegate the whole backlog"
        )
    }

    // MARK: - Readiness

    func testAnUnconfiguredRepositoryIsSkippedRatherThanStartedAndWasted() {
        let decision = decide(
            signal(ownRedPullRequest()),
            context(isConfigured: false)
        )
        XCTAssertEqual(decision.skipReason, .notConfigured)
        XCTAssertFalse(AutoDelegationSkipReason.notConfigured.isCap)
    }

    // MARK: - Deduplication

    func testTheSameHeadCommitNeverTriggersTwice() {
        let pullRequest = ownRedPullRequest()
        var ledger = AutoDelegationLedger()

        let first = decide(signal(pullRequest), context(ledger: ledger))
        guard let plan = first.plan else { return XCTFail("expected a start, got \(first)") }

        ledger = ledger.recording(plan.fingerprint, at: clock, timeZone: timeZone)
        let second = decide(signal(pullRequest), context(ledger: ledger))
        XCTAssertEqual(second.skipReason, .alreadyHandled)
    }

    func testASecondConditionOnTheSameCommitIsAlsoDeduplicated() {
        // CI went red, the agent was sent; a reviewer then also asks for changes on the *same*
        // commit. That is not new work, and a second run would fight the first one's worktree.
        let pullRequest = ownRedPullRequest()
        let ledger = AutoDelegationLedger().recording(
            AutoDelegationLedger.Fingerprint(
                prID: pullRequest.id,
                headRefOid: pullRequest.headRefOid,
                trigger: .checksFailed
            ),
            at: clock,
            timeZone: timeZone
        )
        let decision = decide(
            signal(pullRequest, trigger: .changesRequested),
            context(
                rules: rules(triggers: [.checksFailed, .changesRequested]),
                ledger: ledger
            )
        )
        XCTAssertEqual(decision.skipReason, .alreadyHandled)
    }

    func testANewHeadCommitTriggersAgain() {
        let ledger = AutoDelegationLedger().recording(
            AutoDelegationLedger.Fingerprint(
                prID: "PR_1",
                headRefOid: "old-head",
                trigger: .checksFailed
            ),
            at: clock,
            timeZone: timeZone
        )
        let decision = decide(
            signal(ownRedPullRequest(headRefOid: "new-head")),
            context(ledger: ledger)
        )
        XCTAssertNotNil(decision.plan, "a new commit is new work")
    }

    func testTheLedgerKeepsAtMostItsCapAndForgetsTheOldestFirst() {
        var ledger = AutoDelegationLedger()
        let total = AutoDelegationLedger.maxFingerprints + 10
        for index in 0..<total {
            ledger = ledger.recording(
                AutoDelegationLedger.Fingerprint(
                    prID: "PR_\(index)",
                    headRefOid: "head-\(index)",
                    trigger: .checksFailed
                ),
                at: clock,
                timeZone: timeZone
            )
        }
        XCTAssertEqual(ledger.handled.count, AutoDelegationLedger.maxFingerprints)
        XCTAssertEqual(ledger.handled.first?.prID, "PR_10")
        XCTAssertEqual(ledger.handled.last?.prID, "PR_\(total - 1)")
    }

    func testRecordingTheSameCommitTwiceDoesNotGrowTheLedger() {
        let fingerprint = AutoDelegationLedger.Fingerprint(
            prID: "PR_1",
            headRefOid: "head-1",
            trigger: .checksFailed
        )
        let ledger = AutoDelegationLedger()
            .recording(fingerprint, at: clock, timeZone: timeZone)
            .recording(fingerprint, at: clock, timeZone: timeZone)
        XCTAssertEqual(ledger.handled.count, 1)
        XCTAssertEqual(ledger.startsToday, 2, "the day counter still counts both starts")
    }

    // MARK: - Caps

    func testTheConcurrencyCapStopsASecondSimultaneousRun() {
        let decision = decide(
            signal(ownRedPullRequest()),
            context(rules: rules(maxConcurrent: 1), runningAutomaticCount: 1)
        )
        XCTAssertEqual(decision.skipReason, .concurrencyCapReached)
        XCTAssertTrue(AutoDelegationSkipReason.concurrencyCapReached.isCap)
    }

    func testRaisingTheConcurrencyCapAllowsTheSecondRun() {
        let decision = decide(
            signal(ownRedPullRequest()),
            context(rules: rules(maxConcurrent: 2), runningAutomaticCount: 1)
        )
        XCTAssertNotNil(decision.plan)
    }

    func testADelegationAlreadyRunningForThisPullRequestWins() {
        let decision = decide(
            signal(ownRedPullRequest()),
            context(hasRunningDelegation: true)
        )
        XCTAssertEqual(
            decision.skipReason,
            .delegationRunning,
            "ADR 0011's one-run-per-pull-request rule is not bent by automation"
        )
    }

    func testTheDailyCapStopsTheSixthRunOfTheDay() {
        let ledger = AutoDelegationLedger(
            day: AutoDelegationLedger.dayStamp(for: clock, timeZone: timeZone),
            startsToday: 5
        )
        let decision = decide(
            signal(ownRedPullRequest()),
            context(rules: rules(maxPerDay: 5), ledger: ledger)
        )
        XCTAssertEqual(decision.skipReason, .dailyCapReached)
        XCTAssertTrue(AutoDelegationSkipReason.dailyCapReached.isCap)
    }

    func testTheDailyCounterResetsWhenTheCalendarDayChanges() {
        let yesterday = clock.addingTimeInterval(-24 * 3_600)
        let ledger = AutoDelegationLedger(
            day: AutoDelegationLedger.dayStamp(for: yesterday, timeZone: timeZone),
            startsToday: 5
        )
        XCTAssertEqual(ledger.starts(onDayOf: yesterday, timeZone: timeZone), 5)
        XCTAssertEqual(
            ledger.starts(onDayOf: clock, timeZone: timeZone),
            0,
            "yesterday's budget is not carried over"
        )
        XCTAssertNotNil(
            decide(
                signal(ownRedPullRequest()),
                context(rules: rules(maxPerDay: 5), ledger: ledger)
            ).plan
        )
    }

    func testRecordingOnANewDayRestartsTheCounterAtOne() {
        let yesterday = clock.addingTimeInterval(-24 * 3_600)
        var ledger = AutoDelegationLedger()
        for index in 0..<3 {
            ledger = ledger.recording(
                AutoDelegationLedger.Fingerprint(
                    prID: "PR_\(index)",
                    headRefOid: "head-\(index)",
                    trigger: .checksFailed
                ),
                at: yesterday,
                timeZone: timeZone
            )
        }
        XCTAssertEqual(ledger.startsToday, 3)

        ledger = ledger.recording(
            AutoDelegationLedger.Fingerprint(
                prID: "PR_new",
                headRefOid: "head-new",
                trigger: .checksFailed
            ),
            at: clock,
            timeZone: timeZone
        )
        XCTAssertEqual(ledger.startsToday, 1)
        XCTAssertEqual(ledger.day, AutoDelegationLedger.dayStamp(for: clock, timeZone: timeZone))
        XCTAssertEqual(ledger.handled.count, 4, "the dedup set is not day-scoped")
    }

    func testTheDayStampFollowsTheTimeZoneItIsGiven() {
        // 2025-08-31 22:10 UTC is already 1 September in Berlin (UTC+2) and still 31 August in
        // New York (UTC−4).
        let evening = Date(timeIntervalSince1970: 1_756_678_200)
        let berlin = AutoDelegationLedger.dayStamp(
            for: evening,
            timeZone: TimeZone(identifier: "Europe/Berlin") ?? .gmt
        )
        let newYork = AutoDelegationLedger.dayStamp(
            for: evening,
            timeZone: TimeZone(identifier: "America/New_York") ?? .gmt
        )
        XCTAssertNotEqual(berlin, newYork)
        XCTAssertEqual(berlin.count, 10, "yyyy-MM-dd")
    }

    func testCapsCannotBeDrivenBelowOne() {
        let broken = rules(maxConcurrent: 0, maxPerDay: -3)
        XCTAssertEqual(broken.concurrencyCap, 1)
        XCTAssertEqual(broken.dailyCap, 1)
    }

    // MARK: - Ordering

    func testTheFirstFailedPreconditionIsTheOneReported() {
        // Everything is wrong at once; the reason is the first check in the documented order,
        // not whichever branch happens to run first.
        let ledger = AutoDelegationLedger(
            day: AutoDelegationLedger.dayStamp(for: clock, timeZone: timeZone),
            startsToday: 99,
            handled: [
                AutoDelegationLedger.Fingerprint(
                    prID: "PR_1",
                    headRefOid: "abc123abc123def",
                    trigger: .checksFailed
                )
            ]
        )
        let decision = decide(
            signal(ownRedPullRequest(relations: [.reviewRequested]), isTransition: false),
            context(
                isConfigured: false,
                hasRunningDelegation: true,
                runningAutomaticCount: 9,
                ledger: ledger
            )
        )
        XCTAssertEqual(decision.skipReason, .notOwnPullRequest)
    }

    // MARK: - Persistence shape

    func testTheRuleSetSurvivesAJSONRoundTripAndSortsItsTriggers() throws {
        let subject = rules(
            isEnabled: true,
            triggers: [.changesRequested, .checksFailed],
            promptTemplate: "fix {number}",
            maxConcurrent: 2,
            maxPerDay: 9
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(subject)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        // Canonical bytes: a Set has no order, the document does (ADR 0014).
        XCTAssertTrue(text.contains("\"triggers\":[\"changesRequested\",\"checksFailed\"]"))
        XCTAssertEqual(try JSONDecoder().decode(AutoDelegationRules.self, from: data), subject)
    }

    func testAnOlderRuleSetKeepsItsFieldsAndDefaultsTheRest() throws {
        let json = Data(#"{"isEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AutoDelegationRules.self, from: json)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.triggers, AutoDelegationRules.defaultTriggers)
        XCTAssertEqual(decoded.promptTemplate, AutoDelegationRules.defaultPromptTemplate)
        XCTAssertEqual(decoded.maxPerDay, AutoDelegationRules.defaultMaxPerDay)
    }

    func testAnExplicitlyEmptyTriggerListIsKeptRatherThanDefaulted() throws {
        // The user unticked every box; re-arming red CI behind their back would be worse than
        // a rule set that does nothing.
        let json = Data(#"{"isEnabled":true,"triggers":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(AutoDelegationRules.self, from: json)
        XCTAssertTrue(decoded.triggers.isEmpty)
        XCTAssertFalse(decoded.isArmed(.checksFailed))
    }

    func testAnUnknownTriggerFromANewerBuildIsDroppedNotFatal() throws {
        let json = Data(#"{"triggers":["checksFailed","somethingNew"]}"#.utf8)
        let decoded = try JSONDecoder().decode(AutoDelegationRules.self, from: json)
        XCTAssertEqual(decoded.triggers, [.checksFailed])
    }

    func testTheLedgerSurvivesAJSONRoundTrip() throws {
        let ledger = AutoDelegationLedger().recording(
            AutoDelegationLedger.Fingerprint(
                prID: "PR_1",
                headRefOid: "head-1",
                trigger: .checksFailed
            ),
            at: clock,
            timeZone: timeZone
        )
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(AutoDelegationLedger.self, from: data)
        XCTAssertEqual(decoded, ledger)
        XCTAssertTrue(decoded.hasHandled(
            AutoDelegationLedger.Fingerprint(
                prID: "PR_1",
                headRefOid: "head-1",
                // Trigger-blind on purpose: the commit is what was already worked on.
                trigger: .changesRequested
            )
        ))
    }

    func testAMalformedLedgerDecodesAsEmptyRatherThanThrowing() throws {
        let decoded = try JSONDecoder().decode(
            AutoDelegationLedger.self,
            from: Data(#"{"day":42}"#.utf8)
        )
        XCTAssertEqual(decoded.day, "")
        XCTAssertEqual(decoded.startsToday, 0)
        XCTAssertTrue(decoded.handled.isEmpty)
    }
}
