import ShepherdCore
import XCTest

@testable import Shepherd

/// The pure interaction logic: two-keystroke commands, palette matching, inbox ordering.
final class InteractionTests: XCTestCase {
    // MARK: - Key sequences

    func testSingleKeyCommands() {
        var state = KeySequenceState()
        XCTAssertEqual(state.consume("j"), .action(.selectNext))
        XCTAssertEqual(state.consume("k"), .action(.selectPrevious))
        XCTAssertEqual(state.consume("m"), .action(.merge))
        XCTAssertEqual(state.consume("x"), .action(.toggleMark))
        XCTAssertEqual(state.consume("q"), .unhandled)
    }

    func testTheSelectKeyDoesNotCollideWithTheRequestChangesSequence() {
        var state = KeySequenceState()
        // `r x` stays request-changes; a bare `x` ticks the row for a bulk action.
        XCTAssertEqual(state.consume("r"), .awaitingSecondKey("r"))
        XCTAssertEqual(state.consume("x"), .action(.requestChanges))
        XCTAssertEqual(state.consume("x"), .action(.toggleMark))
    }

    func testTwoKeystrokeReviewCommands() {
        var state = KeySequenceState()
        XCTAssertEqual(state.consume("r"), .awaitingSecondKey("r"))
        XCTAssertEqual(state.consume("a"), .action(.approve))
        XCTAssertEqual(state.consume("r"), .awaitingSecondKey("r"))
        XCTAssertEqual(state.consume("x"), .action(.requestChanges))
        XCTAssertEqual(state.consume("r"), .awaitingSecondKey("r"))
        XCTAssertEqual(state.consume("c"), .action(.comment))
    }

    func testGroupingCommands() {
        var state = KeySequenceState()
        XCTAssertEqual(state.consume("g"), .awaitingSecondKey("g"))
        XCTAssertEqual(state.consume("a"), .action(.groupBy(.provenance)))
        XCTAssertEqual(state.consume("g"), .awaitingSecondKey("g"))
        XCTAssertEqual(state.consume("r"), .action(.groupBy(.repository)))
        XCTAssertEqual(state.consume("g"), .awaitingSecondKey("g"))
        XCTAssertEqual(state.consume("s"), .action(.groupBy(.reviewState)))
    }

    func testAnArmedPrefixExpires() {
        var state = KeySequenceState(timeout: 1)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(state.consume("r", at: start), .awaitingSecondKey("r"))
        // Two seconds later the prefix is forgotten and "a" is just an unknown key.
        XCTAssertEqual(state.consume("a", at: start.addingTimeInterval(2)), .unhandled)
    }

    func testAnUnknownSecondKeyDropsThePrefix() {
        var state = KeySequenceState()
        XCTAssertEqual(state.consume("r"), .awaitingSecondKey("r"))
        XCTAssertEqual(state.consume("z"), .unhandled)
        XCTAssertNil(state.armedPrefix)
    }

    func testUppercaseIsFolded() {
        var state = KeySequenceState()
        XCTAssertEqual(state.consume("R"), .awaitingSecondKey("r"))
        XCTAssertEqual(state.consume("A"), .action(.approve))
    }

    // MARK: - Fuzzy matching

    func testFuzzyMatchFindsSubsequences() {
        XCTAssertEqual(FuzzyMatch.match(query: "appr", in: "Approve pull request"), [0, 1, 2, 3])
        XCTAssertNotNil(FuzzyMatch.match(query: "gia", in: "Group inbox by agent"))
        XCTAssertNil(FuzzyMatch.match(query: "zzz", in: "Approve pull request"))
    }

    func testEmptyQueryMatchesEverythingWithoutHighlighting() {
        XCTAssertEqual(FuzzyMatch.match(query: "", in: "anything"), [])
    }

    func testHighlightingDoesNotChangeTheText() {
        let attributed = FuzzyMatch.highlighted("Approve", indices: [0, 1])
        XCTAssertEqual(String(attributed.characters), "Approve")
    }

    // MARK: - Inbox ordering

    private func summary(
        id: String,
        relation: Set<Relation> = [],
        decision: ReviewDecision? = nil,
        checks: CheckRollup.State? = nil,
        isDraft: Bool = false
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 1,
            title: "Title",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 0),
            isDraft: isDraft,
            headRefName: "feature",
            headRefOid: "abc",
            baseRefName: "main",
            reviewDecision: decision,
            checkRollup: checks.map { CheckRollup(state: $0) },
            myRelation: relation
        )
    }

    func testReviewRequestedOutranksEverythingElse() {
        let requested = summary(id: "a", relation: [.reviewRequested])
        let failing = summary(id: "b", checks: .failure)
        XCTAssertGreaterThan(
            InboxModel.priorityScore(requested),
            InboxModel.priorityScore(failing)
        )
    }

    func testDraftsAndApprovedRowsSinkToTheBottom() {
        let plain = summary(id: "a")
        let draft = summary(id: "b", isDraft: true)
        let approved = summary(id: "c", decision: .approved)
        XCTAssertLessThan(InboxModel.priorityScore(draft), InboxModel.priorityScore(plain))
        XCTAssertLessThan(InboxModel.priorityScore(approved), InboxModel.priorityScore(plain))
    }

    func testSmartViewFilters() {
        let requested = summary(id: "a", relation: [.reviewRequested])
        let mine = summary(id: "b", relation: [.author])
        let approved = summary(id: "c", relation: [.reviewRequested], decision: .approved)

        XCTAssertTrue(SmartView.needsMyReview.matches(requested))
        XCTAssertFalse(SmartView.needsMyReview.matches(approved))
        XCTAssertTrue(SmartView.myPullRequests.matches(mine))
        XCTAssertFalse(SmartView.myPullRequests.matches(requested))
        XCTAssertTrue(SmartView.involved.matches(mine))
        XCTAssertTrue(SmartView.approvedByMe.matches(approved))
        XCTAssertFalse(SmartView.approvedByMe.matches(requested))
    }

    func testProvenanceFilterMatching() {
        let identity = AgentIdentity(id: "claude-code", displayName: "Claude Code", matchedBy: .login)
        var row = summary(id: "a")
        row.author = ShepherdCore.Actor(login: "claude[bot]", kind: .agent(identity))
        XCTAssertTrue(ProvenanceFilter.agent(id: "claude-code").matches(row))
        XCTAssertFalse(ProvenanceFilter.agent(id: "devin").matches(row))
        XCTAssertFalse(ProvenanceFilter.humans.matches(row))
    }

    // MARK: - Bulk-triage selection (ADR 0015)

    func testTickingAndUntickingOneRow() {
        var marks = InboxMarkSelection()
        XCTAssertTrue(marks.isEmpty)
        marks.toggle("a")
        XCTAssertTrue(marks.contains("a"))
        XCTAssertEqual(marks.count, 1)
        marks.toggle("a")
        XCTAssertTrue(marks.isEmpty)
    }

    func testShiftClickTicksTheRangeFromTheCursorInEitherDirection() {
        let order = ["a", "b", "c", "d"]
        var downwards = InboxMarkSelection()
        downwards.extend(to: "c", from: "b", in: order)
        XCTAssertEqual(downwards.ids, ["b", "c"])

        var upwards = InboxMarkSelection()
        upwards.extend(to: "a", from: "d", in: order)
        XCTAssertEqual(upwards.ids, ["a", "b", "c", "d"])
    }

    func testShiftClickWithoutACursorTicksTheOneRow() {
        var marks = InboxMarkSelection()
        marks.extend(to: "c", from: nil, in: ["a", "b", "c"])
        XCTAssertEqual(marks.ids, ["c"])
    }

    func testShiftClickOnARowThatIsNoLongerVisibleChangesNothing() {
        var marks = InboxMarkSelection(ids: ["a"])
        marks.extend(to: "zzz", from: "a", in: ["a", "b"])
        XCTAssertEqual(marks.ids, ["a"])
    }

    func testPreselectingAddsWithoutClearingWhatIsAlreadyTicked() {
        var marks = InboxMarkSelection(ids: ["a"])
        marks.insert(contentsOf: ["b", "c", "a"])
        XCTAssertEqual(marks.ids, ["a", "b", "c"])
    }

    func testARowThatLeavesTheViewLosesItsTick() {
        var marks = InboxMarkSelection(ids: ["a", "b", "c"])
        marks.prune(to: ["a", "c"])
        XCTAssertEqual(marks.ids, ["a", "c"])
        marks.removeAll()
        XCTAssertTrue(marks.isEmpty)
    }

    // MARK: - Bulk-triage labels

    func testEveryBulkTriageLabelIsFilledIn() {
        for action in BulkTriageAction.allCases {
            XCTAssertFalse(action.commandTitle.isEmpty)
            XCTAssertFalse(action.confirmButtonTitle.isEmpty)
            XCTAssertFalse(action.explanation.isEmpty)
            XCTAssertFalse(action.systemImage.isEmpty)
            XCTAssertTrue(action.confirmationTitle(count: 3).contains("3"))
        }
        for reason in BulkTriageSkipReason.allCases {
            XCTAssertTrue(reason.chipTitle.hasPrefix("skipped"))
            XCTAssertFalse(reason.explanation.isEmpty)
        }
        for caveat in BulkTriageCaveat.allCases {
            XCTAssertFalse(caveat.chipTitle.isEmpty)
            XCTAssertFalse(caveat.explanation.isEmpty)
        }
    }

    func testTheStepChipSaysWhatWillActuallyBeWritten() {
        let row = summary(id: "a")
        XCTAssertEqual(
            BulkTriagePlan.Entry(pullRequest: row, steps: [.approve]).stepsTitle,
            "approve"
        )
        XCTAssertEqual(
            BulkTriagePlan.Entry(pullRequest: row, steps: [.merge]).stepsTitle,
            "merge"
        )
        XCTAssertEqual(
            BulkTriagePlan.Entry(pullRequest: row, steps: [.approve, .merge]).stepsTitle,
            "approve + merge"
        )
    }

    // MARK: - Relative dates

    func testCompactRelativeDates() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(RelativeDate.short(now.addingTimeInterval(-30), relativeTo: now), "now")
        XCTAssertEqual(RelativeDate.short(now.addingTimeInterval(-720), relativeTo: now), "12 m")
        XCTAssertEqual(RelativeDate.short(now.addingTimeInterval(-7_200), relativeTo: now), "2 h")
        XCTAssertEqual(RelativeDate.short(now.addingTimeInterval(-172_800), relativeTo: now), "2 d")
    }

    func testDurationFormatting() {
        XCTAssertEqual(RelativeDate.duration(58), "58 s")
        XCTAssertEqual(RelativeDate.duration(102), "1 m 42 s")
    }
}
