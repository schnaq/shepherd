import Foundation
import XCTest

@testable import ShepherdCore

/// The auto-merge decision, branch by branch (ADR 0018).
///
/// This is the file that has to be exhaustive, and for a blunter reason than its auto-delegation
/// sibling: an automatic delegation that fires wrongly wastes an agent run, while an automatic
/// merge that fires wrongly writes to somebody's default branch. Every condition therefore has a
/// test that fails it *on its own*, with everything else satisfied.
final class AutoMergePolicyTests: XCTestCase {
    private let clock = Fixtures.date(0)

    // MARK: - Helpers

    private func rules(
        isEnabled: Bool = true,
        allowedRepositories: [String] = [],
        requiredLabels: [String] = []
    ) -> AutoMergeRules {
        AutoMergeRules(
            isEnabled: isEnabled,
            allowedRepositories: allowedRepositories,
            requiredLabels: requiredLabels
        )
    }

    /// The one shape v1 merges: an agent's pull request, green, approved, mergeable, not a draft.
    private func mergeable(
        id: String = "PR_1",
        headRefOid: String = "abc123abc123def",
        repo: RepoRef = Fixtures.repo,
        author: ShepherdCore.Actor = Fixtures.makeActor(
            "claude[bot]",
            kind: Fixtures.agent("claude-code", "Claude Code")
        ),
        isDraft: Bool = false,
        checkRollup: CheckRollup? = CheckRollup(state: .success, total: 7, successCount: 7),
        reviewDecision: ReviewDecision? = .approved,
        labels: [String] = []
    ) -> PullRequestSummary {
        Fixtures.summary(
            id: id,
            number: 42,
            repo: repo,
            author: author,
            isDraft: isDraft,
            headRefOid: headRefOid,
            reviewDecision: reviewDecision,
            checkRollup: checkRollup,
            labels: labels
        )
    }

    private func decide(
        _ pullRequest: PullRequestSummary,
        rules ruleSet: AutoMergeRules? = nil,
        ledger: AutoMergeLedger = AutoMergeLedger(),
        existingOutbox: Set<String> = []
    ) -> AutoMergeDecision {
        AutoMergePolicy.decide(
            pullRequest: pullRequest,
            rules: ruleSet ?? rules(),
            ledger: ledger,
            existingOutbox: existingOutbox
        )
    }

    private func entry(
        prID: String = "PR_1",
        headRefOid: String = "abc123abc123def",
        at date: Date? = nil
    ) -> AutoMergeAuditEntry {
        AutoMergeAuditEntry(
            prID: prID,
            slug: "schnaq/review#42",
            title: "Fix the thing",
            headRefOid: headRefOid,
            mergeMethod: "squash",
            authorLogin: "claude[bot]",
            checkCount: 7,
            matchedLabels: [],
            queuedAt: date ?? clock
        )
    }

    // MARK: - The happy path

    func testAGreenApprovedMergeableAgentPullRequestIsMergedAtItsCurrentHead() {
        let decision = decide(mergeable())
        XCTAssertEqual(
            decision.expectedHeadOid,
            "abc123abc123def",
            "the merge is pinned to the commit the decision was made on"
        )
        XCTAssertNil(decision.skipReason)
    }

    func testAFreshRuleSetIsOffAndNarrowsNothing() {
        let fresh = AutoMergeRules()
        XCTAssertFalse(fresh.isEnabled)
        XCTAssertTrue(fresh.allowedRepositories.isEmpty)
        XCTAssertTrue(fresh.requiredLabels.isEmpty)
        XCTAssertTrue(fresh.allows(Fixtures.repo), "an empty allow-list is not an empty allowance")
        XCTAssertEqual(decide(mergeable(), rules: fresh).skipReason, .disabled)
    }

    // MARK: - One failing condition at a time

    func testAHumansPullRequestIsNeverMerged() {
        let human = mergeable(author: Fixtures.makeActor("somebody"))
        XCTAssertEqual(decide(human).skipReason, .notAgentAuthored)
        XCTAssertFalse(AutoMergePolicy.isAgentAuthored(human))
    }

    func testAnUnrecognisedBotIsNotAnAgentEither() {
        // `type == Bot` from the API is authoritative for `.bot`; only the registry promotes to
        // `.agent` (ADR 0008). A CI bot's pull request is not delegated work coming back.
        let bot = mergeable(author: Fixtures.makeActor("renovate[bot]", kind: .bot))
        XCTAssertEqual(decide(bot).skipReason, .notAgentAuthored)
    }

    func testADraftIsNeverMerged() {
        XCTAssertEqual(decide(mergeable(isDraft: true)).skipReason, .draft)
    }

    func testAPullRequestWithNoChecksIsNotGreen() {
        // Deliberately stricter than the bulk-triage plan, which lets a human confirm such a pull
        // request with a note. There is nobody to confirm here.
        let rollups: [CheckRollup?] = [
            nil,
            CheckRollup(state: CheckRollup.State.none),
            CheckRollup(state: .success, total: 0),
        ]
        for rollup in rollups {
            let pullRequest = mergeable(checkRollup: rollup)
            XCTAssertEqual(decide(pullRequest).skipReason, .noChecks)
            XCTAssertFalse(AutoMergePolicy.hasGreenChecks(pullRequest))
        }
    }

    func testFailingOrRunningChecksAreNotGreen() {
        for state in [CheckRollup.State.failure, .pending] {
            let rollup = CheckRollup(state: state, total: 7, successCount: 6, failureCount: 1)
            XCTAssertEqual(
                decide(mergeable(checkRollup: rollup)).skipReason,
                .checksNotGreen
            )
        }
    }

    func testOnlyAnApprovalCounts() {
        let decisions: [ReviewDecision?] = [nil, .reviewRequired, .changesRequested]
        for decision in decisions {
            XCTAssertEqual(
                decide(mergeable(reviewDecision: decision)).skipReason,
                .notApproved,
                "an automatic merge only ever records a decision a human already made"
            )
        }
    }

    func testUnknownMergeabilityIsARefusalRatherThanANote() {
        var conflicting = mergeable()
        conflicting.mergeable = .conflicting
        XCTAssertEqual(decide(conflicting).skipReason, .notMergeable)

        var unknown = mergeable()
        unknown.mergeable = .unknown
        XCTAssertEqual(decide(unknown).skipReason, .notMergeable)

        var absent = mergeable()
        absent.mergeable = nil
        XCTAssertEqual(decide(absent).skipReason, .notMergeable)
    }

    // MARK: - The allow-list

    func testAnEmptyAllowListMeansEveryRepository() {
        XCTAssertNil(decide(mergeable(), rules: rules(allowedRepositories: [])).skipReason)
    }

    func testARepositoryOutsideTheAllowListIsLeftAlone() {
        let decision = decide(
            mergeable(),
            rules: rules(allowedRepositories: ["someone-else/thing"])
        )
        XCTAssertEqual(decision.skipReason, .repositoryNotAllowed)
    }

    func testTheAllowListTakesWildcardsAndIgnoresCase() {
        for pattern in ["schnaq/review", "schnaq/*", "Schnaq/Review", "*", "schnaq/rev?ew"] {
            XCTAssertNil(
                decide(mergeable(), rules: rules(allowedRepositories: [pattern])).skipReason,
                "\(pattern) should match schnaq/review"
            )
        }
        XCTAssertFalse(rules(allowedRepositories: ["schnaq/rev"]).allows(Fixtures.repo))
    }

    func testABlankAllowListEntryIsNotAPatternThatMatchesNothing() {
        // A trailing comma in the settings field must not silently disable the feature.
        let ruleSet = rules(allowedRepositories: ["  ", ""])
        XCTAssertTrue(ruleSet.usableRepositories.isEmpty)
        XCTAssertNil(decide(mergeable(), rules: ruleSet).skipReason)
    }

    // MARK: - Required labels

    func testEveryRequiredLabelHasToBePresent() {
        let ruleSet = rules(requiredLabels: ["automerge", "agent"])
        XCTAssertEqual(
            decide(mergeable(labels: ["automerge"]), rules: ruleSet).skipReason,
            .requiredLabelMissing
        )
        XCTAssertNil(
            decide(mergeable(labels: ["agent", "automerge", "bug"]), rules: ruleSet).skipReason
        )
    }

    func testLabelsAreComparedWithoutCase() {
        let ruleSet = rules(requiredLabels: ["AutoMerge"])
        XCTAssertNil(decide(mergeable(labels: ["automerge"]), rules: ruleSet).skipReason)
        XCTAssertEqual(ruleSet.matchedLabels(from: ["automerge"]), ["AutoMerge"])
    }

    func testTheMissingLabelsAreNamedInTheUsersOwnOrder() {
        let ruleSet = rules(requiredLabels: ["ship-it", "automerge"])
        XCTAssertEqual(
            ruleSet.missingLabels(from: ["bug"]),
            ["ship-it", "automerge"],
            "so the UI can say which label is missing rather than that one is"
        )
        XCTAssertEqual(ruleSet.missingLabels(from: ["automerge"]), ["ship-it"])
    }

    // MARK: - Queueing at most once

    func testTheSameHeadCommitIsNeverQueuedTwice() {
        let pullRequest = mergeable()
        let ledger = AutoMergeLedger().recording(entry())
        XCTAssertEqual(decide(pullRequest, ledger: ledger).skipReason, .alreadyQueued)
    }

    func testANewHeadCommitIsEligibleAgain() {
        let ledger = AutoMergeLedger().recording(entry(headRefOid: "old-head"))
        XCTAssertEqual(
            decide(mergeable(headRefOid: "new-head"), ledger: ledger).expectedHeadOid,
            "new-head",
            "a push is new work, and the new head is what the drain will re-validate"
        )
    }

    func testAPullRequestWithAWriteStillInTheOutboxIsLeftAlone() {
        // The parked-conflict case is the important one: a merge waiting for the user must not
        // grow a second merge behind it on every sweep (ADR 0006).
        XCTAssertEqual(
            decide(mergeable(), existingOutbox: ["PR_1"]).skipReason,
            .writeInFlight
        )
        XCTAssertNil(decide(mergeable(), existingOutbox: ["PR_other"]).skipReason)
    }

    func testTheLedgerIsAlsoTheAuditLogAndKeepsItsNewestEntriesLast() {
        var ledger = AutoMergeLedger()
        let total = AutoMergeLedger.maxEntries + 5
        for index in 0..<total {
            ledger = ledger.recording(entry(prID: "PR_\(index)", headRefOid: "head-\(index)"))
        }
        XCTAssertEqual(ledger.entries.count, AutoMergeLedger.maxEntries)
        XCTAssertEqual(ledger.entries.first?.prID, "PR_5")
        XCTAssertEqual(ledger.entries.last?.prID, "PR_\(total - 1)")
        // The card reads the tail, newest first.
        XCTAssertEqual(
            ledger.recent(limit: 2).map(\.prID),
            ["PR_\(total - 1)", "PR_\(total - 2)"]
        )
        XCTAssertTrue(ledger.recent(limit: 0).isEmpty)
    }

    func testRecordingTheSamePairTwiceReplacesItRatherThanListingItTwice() {
        let ledger = AutoMergeLedger()
            .recording(entry())
            .recording(entry(at: clock.addingTimeInterval(60)))
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries.first?.queuedAt, clock.addingTimeInterval(60))
        XCTAssertTrue(ledger.hasQueued(prID: "PR_1", headRefOid: "abc123abc123def"))
        XCTAssertFalse(ledger.hasQueued(prID: "PR_1", headRefOid: "other"))
        XCTAssertFalse(ledger.hasQueued(prID: "PR_2", headRefOid: "abc123abc123def"))
    }

    // MARK: - Ordering

    func testTheFirstFailedConditionIsTheOneReported() {
        // Everything is wrong at once; the reason is the first check in the documented order,
        // not whichever branch happens to run first.
        var pullRequest = mergeable(
            author: Fixtures.makeActor("somebody"),
            isDraft: true,
            checkRollup: CheckRollup(state: .failure, total: 2, failureCount: 2),
            reviewDecision: .changesRequested,
            labels: []
        )
        pullRequest.mergeable = .conflicting
        let decision = decide(
            pullRequest,
            rules: rules(allowedRepositories: ["nobody/nothing"], requiredLabels: ["automerge"]),
            ledger: AutoMergeLedger().recording(entry()),
            existingOutbox: ["PR_1"]
        )
        XCTAssertEqual(decision.skipReason, .notAgentAuthored)
    }

    func testEverySkipReasonIsReachableFromTheDocumentedOrder() {
        // A reason nothing can produce is a lie in the UI, so the enum is pinned to the order the
        // policy documents.
        XCTAssertEqual(
            AutoMergeSkipReason.allCases.map(\.rawValue),
            [
                "disabled",
                "notAgentAuthored",
                "repositoryNotAllowed",
                "requiredLabelMissing",
                "draft",
                "noChecks",
                "checksNotGreen",
                "notApproved",
                "notMergeable",
                "alreadyQueued",
                "writeInFlight",
            ]
        )
    }

    // MARK: - The settings fields

    func testACommaSeparatedFieldRoundTripsThroughTheList() {
        XCTAssertEqual(
            AutoMergeRules.list(from: " schnaq/review , schnaq/* ,, "),
            ["schnaq/review", "schnaq/*"]
        )
        XCTAssertEqual(AutoMergeRules.list(from: "a\nb, c"), ["a", "b", "c"])
        XCTAssertTrue(AutoMergeRules.list(from: "   ").isEmpty)
        XCTAssertEqual(
            AutoMergeRules.text(from: ["schnaq/review", " ", "schnaq/*"]),
            "schnaq/review, schnaq/*"
        )
        XCTAssertEqual(
            AutoMergeRules.list(from: AutoMergeRules.text(from: ["a", "b"])),
            ["a", "b"]
        )
    }

    // MARK: - Persistence shape

    func testTheRuleSetSurvivesAJSONRoundTrip() throws {
        let subject = rules(
            isEnabled: true,
            allowedRepositories: ["schnaq/*"],
            requiredLabels: ["zebra", "apple"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(subject)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        // Lists, not sets: the order the user typed is the order that travels, so two identical
        // rule sets still produce identical bytes (ADR 0014's canonical encoding).
        XCTAssertTrue(text.contains("\"requiredLabels\":[\"zebra\",\"apple\"]"))
        XCTAssertEqual(try JSONDecoder().decode(AutoMergeRules.self, from: data), subject)
    }

    func testAnOlderRuleSetKeepsItsFieldsAndDefaultsTheRest() throws {
        let json = Data(#"{"isEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AutoMergeRules.self, from: json)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertTrue(decoded.allowedRepositories.isEmpty)
        XCTAssertTrue(decoded.requiredLabels.isEmpty)
    }

    func testAnUnreadableListCostsOnlyThatListAndNeverWidensTheRule() throws {
        let json = Data(#"{"isEnabled":true,"allowedRepositories":"schnaq/*"}"#.utf8)
        let decoded = try JSONDecoder().decode(AutoMergeRules.self, from: json)
        XCTAssertTrue(decoded.isEnabled)
        // An unreadable allow-list falls back to "no allow-list", which is *wider* — and is safe
        // only because the conditions that matter are not fields at all.
        XCTAssertTrue(decoded.allowedRepositories.isEmpty)
        let human = mergeable(author: Fixtures.makeActor("somebody"))
        XCTAssertEqual(decide(human, rules: decoded).skipReason, .notAgentAuthored)
    }

    func testTheLedgerSurvivesAJSONRoundTrip() throws {
        let ledger = AutoMergeLedger().recording(entry())
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(AutoMergeLedger.self, from: data)
        XCTAssertEqual(decoded, ledger)
        XCTAssertTrue(decoded.hasQueued(prID: "PR_1", headRefOid: "abc123abc123def"))
        XCTAssertEqual(decoded.entries.first?.shortHead, "abc123abc123")
        XCTAssertEqual(decoded.entries.first?.id, "PR_1@abc123abc123def")
    }

    func testAMalformedLedgerDecodesAsEmptyRatherThanThrowing() throws {
        let decoded = try JSONDecoder().decode(
            AutoMergeLedger.self,
            from: Data(#"{"entries":42}"#.utf8)
        )
        XCTAssertTrue(decoded.entries.isEmpty)
    }

    func testAnAuditEntryFromAnotherBuildKeepsWhatItCanRead() throws {
        let json = Data(#"{"prID":"PR_9","slug":"schnaq/review#9","futureKey":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AutoMergeAuditEntry.self, from: json)
        XCTAssertEqual(decoded.prID, "PR_9")
        XCTAssertEqual(decoded.slug, "schnaq/review#9")
        XCTAssertEqual(decoded.checkCount, 0)
        XCTAssertTrue(decoded.matchedLabels.isEmpty)
    }
}
