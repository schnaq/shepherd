import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The claims-vs-evidence card's state (ADR 0026, plan §2.A).
///
/// Everything worth testing about this card is a rule about *when it appears and what pressing a
/// button does*, and none of it needs a window:
///
/// - an empty report draws no card at all;
/// - an agent's pull request opens expanded and a person's collapsed (ADR 0008's facet), and the
///   reviewer's own toggle then outranks that default across a background refresh;
/// - "Turn into a comment" assembles the claim and its facts, and — exactly like a drafted
///   summary — never overwrites text the reviewer has already written without asking.
@MainActor
final class ClaimsEvidenceCardTests: XCTestCase {
    // MARK: - Fixtures

    private func summary(kind: ActorKind = .human) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            title: "Retry the flaky upload",
            author: ShepherdCore.Actor(login: "claude[bot]", kind: kind),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 0),
            additions: 12,
            deletions: 3,
            changedFiles: 1,
            headRefName: "claude/retry",
            headRefOid: "abc123",
            baseRefName: "main",
            checkRollup: CheckRollup(state: .failure, total: 1, failureCount: 1)
        )
    }

    /// A pull request that claims tests were added and changed no test file, with red CI — the
    /// one shape that produces a contradicted line, which is what the button hangs off.
    private func detail(kind: ActorKind = .human, body: String = "Tests added.") -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(kind: kind),
            bodyMarkdown: body,
            files: [
                ChangedFile(
                    path: "Sources/Uploader/Upload.swift",
                    status: .modified,
                    additions: 12,
                    deletions: 3,
                    patch: "@@ -1,2 +1,2 @@\n-old\n+new\n"
                )
            ]
        )
    }

    private static let agent = ActorKind.agent(
        AgentIdentity(id: "claude-code", displayName: "Claude Code", matchedBy: .commitTrailer)
    )

    private func loaded(kind: ActorKind = .human, body: String = "Tests added.") -> ClaimsEvidenceModel {
        let model = ClaimsEvidenceModel()
        model.refresh(detail: detail(kind: kind, body: body))
        return model
    }

    // MARK: - Hidden and expanded

    func testADescriptionThatClaimsNothingDrawsNoCard() {
        let model = loaded(body: "typo fix")
        XCTAssertTrue(model.state.isHidden)
        XCTAssertTrue(model.state.lines.isEmpty)
    }

    func testAPullRequestStillLoadingDrawsNoCard() {
        let model = ClaimsEvidenceModel()
        model.refresh(detail: nil)
        XCTAssertTrue(model.state.isHidden)
    }

    func testAnAgentsPullRequestOpensExpandedAndAPersonsCollapsed() {
        XCTAssertTrue(loaded(kind: Self.agent).state.isExpanded)
        XCTAssertFalse(loaded(kind: .human).state.isExpanded)
    }

    func testAnUnrecognisedBotIsTreatedLikeAPerson() {
        // ADR 0008 distinguishes a bot from a recognised coding agent; only the second one is the
        // flood this card exists for.
        XCTAssertFalse(loaded(kind: .bot).state.isExpanded)
    }

    func testTheReviewersOwnToggleSurvivesABackgroundRefresh() {
        let model = loaded(kind: .human)
        XCTAssertFalse(model.state.isExpanded)
        model.state.toggleExpansion()
        XCTAssertTrue(model.state.isExpanded)

        // A refresh with new data must not re-apply the collapsed default.
        var moved = detail(kind: .human)
        moved.summary.headRefOid = "def456"
        model.refresh(detail: moved)
        XCTAssertTrue(model.state.isExpanded)
        XCTAssertFalse(model.state.isHidden)
    }

    func testARefreshWithTheSameDataKeepsThePendingQuestion() throws {
        let model = loaded()
        let line = try XCTUnwrap(model.state.report.contradictedLines.first)
        XCTAssertEqual(
            model.state.turnIntoComment(line, existingSummary: "Looks good so far."),
            .askFirst
        )
        // Same detail: nothing is rebuilt, so the question the reviewer is looking at stays up.
        model.refresh(detail: detail())
        XCTAssertNotNil(model.state.pendingInsertion)
    }

    // MARK: - The finding as text

    func testTheCommentTextIsTheClaimThenItsFacts() throws {
        let model = loaded()
        let line = try XCTUnwrap(model.state.report.contradictedLines.first)
        let text = ClaimsEvidenceCardState.commentText(for: line)
        XCTAssertTrue(text.hasPrefix("Tests added. — "), text)
        XCTAssertTrue(text.contains("No changed file matches a test naming convention."), text)
        XCTAssertTrue(text.contains("CI is red"), text)
    }

    func testAClaimWithNoFactsIsStillQuotable() {
        let line = ClaimsEvidenceReport.Line(
            claim: Claim(kind: .testsAdded, quote: "Tests added."),
            verdict: EvidenceVerdict(status: .contradicted, facts: [])
        )
        XCTAssertEqual(ClaimsEvidenceCardState.commentText(for: line), "Tests added.")
    }

    // MARK: - Writing into the review summary

    func testAnEmptySummaryTakesTheFindingDirectly() throws {
        let model = loaded()
        let line = try XCTUnwrap(model.state.report.contradictedLines.first)
        let insertion = model.state.turnIntoComment(line, existingSummary: "   \n ")
        XCTAssertEqual(insertion, .write(ClaimsEvidenceCardState.commentText(for: line)))
        XCTAssertNil(model.state.pendingInsertion)
        XCTAssertTrue(model.state.didInsertIntoSummary)
    }

    func testANonEmptySummaryIsAskedAboutAndNothingIsWrittenYet() throws {
        let model = loaded()
        let line = try XCTUnwrap(model.state.report.contradictedLines.first)
        XCTAssertEqual(model.state.turnIntoComment(line, existingSummary: "My own text."), .askFirst)
        XCTAssertEqual(model.state.pendingInsertion?.text, ClaimsEvidenceCardState.commentText(for: line))
        XCTAssertFalse(model.state.didInsertIntoSummary)
    }

    func testReplaceWritesTheFindingAndAppendKeepsWhatWasThere() throws {
        let model = loaded()
        let line = try XCTUnwrap(model.state.report.contradictedLines.first)
        let finding = ClaimsEvidenceCardState.commentText(for: line)

        _ = model.state.turnIntoComment(line, existingSummary: "My own text.")
        XCTAssertEqual(
            model.state.resolveInsertion(.replace, existingSummary: "My own text."),
            finding
        )
        XCTAssertNil(model.state.pendingInsertion)

        _ = model.state.turnIntoComment(line, existingSummary: "My own text.")
        XCTAssertEqual(
            model.state.resolveInsertion(.append, existingSummary: "My own text."),
            "My own text.\n\n" + finding
        )
    }

    func testDiscardingLeavesTheSummaryAlone() throws {
        let model = loaded()
        let line = try XCTUnwrap(model.state.report.contradictedLines.first)
        _ = model.state.turnIntoComment(line, existingSummary: "My own text.")
        model.state.discardInsertion()
        XCTAssertNil(model.state.pendingInsertion)
        XCTAssertNil(model.state.resolveInsertion(.replace, existingSummary: "My own text."))
        XCTAssertFalse(model.state.didInsertIntoSummary)
    }

    // MARK: - Copy

    func testEveryStatusHasAGlyphAColourAndAnAccessibilityLabel() {
        for status in EvidenceVerdict.Status.allCases {
            XCTAssertFalse(ClaimsEvidenceCard.glyph(status).isEmpty)
            XCTAssertFalse(ClaimsEvidenceCard.statusLabel(status).isEmpty)
        }
        XCTAssertEqual(ClaimsEvidenceCard.statusOrder.count, EvidenceVerdict.Status.allCases.count)
    }

    func testTheClaimLabelNamesTheModuleAndFallsBackWhenThereIsNone() {
        XCTAssertEqual(
            ClaimsEvidenceCard.claimLabel(.scopeLimited(module: "Sources/Parser")),
            "Only Sources/Parser changed"
        )
        XCTAssertEqual(
            ClaimsEvidenceCard.claimLabel(.scopeLimited(module: "")),
            "Nothing else changed"
        )
        XCTAssertEqual(ClaimsEvidenceCard.claimLabel(.fixesIssue(number: 142)), "Fixes issue #142")
    }

    func testTheEvidenceLabelIsSingularForOneFact() {
        XCTAssertEqual(ClaimsEvidenceCard.evidenceLabel(1), "1 fact")
        XCTAssertEqual(ClaimsEvidenceCard.evidenceLabel(3), "3 facts")
    }

    func testTheLinkTextNamesTheLineWhenThereIsOne() {
        XCTAssertEqual(
            ClaimsEvidenceCard.locationText(path: "Tests/A.swift", line: 12),
            "Tests/A.swift:12"
        )
        XCTAssertEqual(
            ClaimsEvidenceCard.locationText(path: "Tests/A.swift", line: nil),
            "Tests/A.swift"
        )
    }
}
