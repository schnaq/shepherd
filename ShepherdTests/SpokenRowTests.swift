import ShepherdCore
import XCTest

@testable import Shepherd

/// How a list row describes itself to a screen reader.
///
/// The bug these exist to stop coming back: `.accessibilityElement(children: .combine)` followed
/// by `.accessibilityLabel(…)` **replaces** the combined label, so every list in the app used to
/// announce `owner/repo #12: title` and silently drop the five other facts the row was drawing.
/// The assembly is a pure function precisely so the sentence can be asserted here rather than
/// listened to in a window.
final class SpokenRowTests: XCTestCase {
    func testThePartsBecomeOneSentenceInTheOrderTheyWereGiven() {
        XCTAssertEqual(
            SpokenRow.sentence(["All checks passed", "schnaq/review #12: Fix the thing", "42 added, 3 deleted"]),
            "All checks passed. schnaq/review #12: Fix the thing. 42 added, 3 deleted."
        )
    }

    func testAPartThatIsNotThereIsLeftOutRatherThanAnnouncedAsAGap() {
        // Most parts are conditional on screen too — a row with no triage chip should not say
        // "no triage" — so a `nil` is silence, and so is a string that is only whitespace.
        XCTAssertEqual(
            SpokenRow.sentence([nil, "One", "   ", nil, "Two"]),
            "One. Two."
        )
        XCTAssertEqual(SpokenRow.sentence([]), "")
        XCTAssertEqual(SpokenRow.sentence([nil, "  ", nil]), "")
    }

    func testAPartThatIsAlreadyASentenceDoesNotGetASecondFullStop() {
        // Several parts come from a component's tooltip, which is written as a sentence.
        XCTAssertEqual(
            SpokenRow.sentence(["Opened by a person.", "Draft"]),
            "Opened by a person. Draft."
        )
    }
}

/// The spoken forms the components hand to a row.
///
/// `@MainActor` because the three types are `View`s, and a view's static members inherit that
/// isolation; the assembly above needs none.
@MainActor
final class SpokenComponentTests: XCTestCase {
    func testTheCheckDotSaysWhatItsColourMeans() {
        XCTAssertEqual(CheckDotView.spokenState(.success), String(localized: "All checks passed"))
        XCTAssertEqual(CheckDotView.spokenState(.failure), String(localized: "Checks failing"))
        XCTAssertEqual(CheckDotView.spokenState(.pending), String(localized: "Checks running"))
        XCTAssertEqual(CheckDotView.spokenState(CheckRollup.State.none), String(localized: "No checks"))
        XCTAssertEqual(CheckDotView.spokenState(nil), String(localized: "No checks"))
    }

    func testTheProvenanceChipSaysWhoOpenedItAndHowShepherdKnows() {
        let human = ShepherdCore.Actor(login: "octocat", kind: .human)
        XCTAssertEqual(
            ProvenanceChip.spokenProvenance(of: human),
            String(localized: "Opened by a person")
        )

        let bot = ShepherdCore.Actor(login: "dependabot[bot]", kind: .bot)
        XCTAssertEqual(
            ProvenanceChip.spokenProvenance(of: bot),
            String(localized: "Opened by a bot account")
        )

        let agent = ShepherdCore.Actor(
            login: "example-agent[bot]",
            kind: .agent(
                AgentIdentity(id: "example-agent", displayName: "Example Agent", matchedBy: .login)
            )
        )
        // The display name and how it was matched, because that is what the tooltip says and the
        // row must not describe the same chip differently.
        XCTAssertTrue(ProvenanceChip.spokenProvenance(of: agent).contains("Example Agent"))
        XCTAssertTrue(ProvenanceChip.spokenProvenance(of: agent).contains("login"))
    }

    func testTheTriageChipIsSilentWhenItIsNotDrawn() {
        XCTAssertNil(TriageChip.spokenTitle(for: TriageRowSummary()))
    }

    func testTheTriageChipSaysTheRiskAloneAndTheVerdictWhenThereIsOne() throws {
        let heuristic = TriageRowSummary(heuristicRisk: .high)
        XCTAssertEqual(TriageChip.spokenTitle(for: heuristic), TriageVerdict.Risk.high.chipTitle)

        let classified = TriageRowSummary(
            verdict: TriageVerdict(kind: .fix, risk: .high, reason: "touches the token store")
        )
        let spoken = try XCTUnwrap(TriageChip.spokenTitle(for: classified))
        XCTAssertEqual(
            spoken,
            "\(TriageVerdict.Kind.fix.chipTitle) · \(TriageVerdict.Risk.high.chipTitle)"
        )
    }

    func testTheDiffCountsAreSpokenAsWords() {
        XCTAssertEqual(
            DiffCountsView.spokenCounts(additions: 42, deletions: 3),
            String(localized: "42 added, 3 deleted")
        )
    }
}
