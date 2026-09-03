import Foundation
import XCTest

@testable import ShepherdCore

/// The `fileDiff` tool's window, and the pair a tool-calling answer comes back as (plan §0.3).
///
/// Both are here rather than beside the tools in the app target for the reason the rest of the
/// contract is: the windowing arithmetic is the part that fails *quietly* — a window centred one
/// line off still reads like a diff, and a model handed the wrong twenty lines produces a
/// plausible diagnosis of the wrong thing — so it has to be checkable on Linux, without a Mac.
final class IntelligenceDiffWindowTests: XCTestCase {
    /// A patch of `lines` context lines numbered 1…n, plus one added line at the end.
    ///
    /// Context lines only, so the base and head numbering stay equal and an assertion about
    /// "line 100" is an assertion about one obvious row.
    private func longPatch(lines: Int = 200) -> String {
        var text = "@@ -1,\(lines) +1,\(lines) @@\n"
        for index in 1...lines {
            text += " context line \(index) — code long enough for the budget to matter\n"
        }
        text += "+added tail line\n"
        return text
    }

    private let cloudLimit = TokenBudget.cloud.maxCharacters

    // MARK: - Centring

    func testTheWindowIsTheNamedLinePlusContextOnEitherSide() {
        let window = IntelligenceDiffWindow.window(
            patch: longPatch(),
            aroundLine: 100,
            characterLimit: cloudLimit
        )

        XCTAssertEqual(window.centredOnLine, 100)
        XCTAssertTrue(window.text.contains("context line 100"))
        // `defaultContextLines` on either side, and nothing beyond it.
        XCTAssertTrue(window.text.contains("context line 76"))
        XCTAssertTrue(window.text.contains("context line 124"))
        XCTAssertFalse(window.text.contains("context line 75"))
        XCTAssertFalse(window.text.contains("context line 125"))
        XCTAssertEqual(window.lineCount, 49, "the line plus 24 on either side")
        XCTAssertTrue(window.wasTruncated, "a window into a longer patch says so")
        XCTAssertFalse(window.isEmpty)
    }

    func testAWindowThatStartsMidHunkCarriesAHeaderSoTheNumbersStayDerivable() {
        let window = IntelligenceDiffWindow.window(
            patch: longPatch(),
            aroundLine: 100,
            characterLimit: cloudLimit
        )

        // The first kept row is context line 76, on both sides — so the synthesised header has
        // to say 76, or a model reading the window cannot place a single line in the file.
        XCTAssertEqual(window.text.components(separatedBy: "\n").first, "@@ -76 +76 @@")
        XCTAssertEqual(
            window.text.components(separatedBy: "\n").filter { $0.hasPrefix("@@") }.count,
            1,
            "exactly one header, never two"
        )
    }

    func testAWindowThatStartsOnTheHunkHeaderIsNotGivenASecondOne() {
        let window = IntelligenceDiffWindow.window(
            patch: longPatch(),
            aroundLine: 3,
            characterLimit: cloudLimit
        )

        // The hunk's own header is re-synthesised rather than copied: the line *counts* in
        // GitHub's header are re-derivable and the section heading after the second `@@` is
        // noise, so every header in a window has the same two-number shape.
        XCTAssertEqual(window.text.components(separatedBy: "\n").first, "@@ -1 +1 @@")
        XCTAssertEqual(
            window.text.components(separatedBy: "\n").filter { $0.hasPrefix("@@") }.count,
            1
        )
        // The patch's own header is not a diff line, so it is not counted as one.
        XCTAssertEqual(window.lineCount, 27, "lines 1…27, the header not counted")
    }

    func testWithoutALineTheWindowStartsAtTheFirstHunk() {
        let window = IntelligenceDiffWindow.window(
            patch: longPatch(),
            characterLimit: cloudLimit
        )

        XCTAssertNil(window.centredOnLine)
        XCTAssertTrue(window.text.contains("context line 1"))
        XCTAssertTrue(window.text.contains("context line 48"))
        XCTAssertFalse(window.text.contains("context line 49"))
        XCTAssertTrue(window.wasTruncated)
    }

    func testALineThePatchDoesNotContainFallsBackToTheFirstHunkRatherThanToNothing() {
        // A model that misread a log names a line outside the diff. Answering with the head of
        // the file is useful; answering with nothing teaches it that the tool is broken.
        let window = IntelligenceDiffWindow.window(
            patch: longPatch(lines: 10),
            aroundLine: 4_000,
            characterLimit: cloudLimit
        )

        XCTAssertNil(window.centredOnLine)
        XCTAssertTrue(window.text.contains("context line 1"))
        XCTAssertFalse(window.isEmpty)
    }

    func testAShortPatchIsNotReportedAsTruncated() {
        let window = IntelligenceDiffWindow.window(
            patch: longPatch(lines: 4),
            characterLimit: cloudLimit
        )

        XCTAssertFalse(window.wasTruncated)
        XCTAssertEqual(window.lineCount, 5, "four context lines plus the added tail")
        XCTAssertTrue(window.text.contains("+added tail line"))
    }

    // MARK: - Which side a line number means

    func testALineNumberMeansTheHeadSideSoADeletionIsNeverMistakenForIt() {
        var patch = "@@ -10,4 +10,4 @@\n"
        patch += " kept line\n"
        patch += "-removed line\n"
        patch += "+added line\n"
        patch += " trailing line\n"

        // The removed line sits at base 11 and the added line at head 11. A log names the head
        // side, so centring on 11 must find the addition.
        let window = IntelligenceDiffWindow.window(
            patch: patch,
            aroundLine: 11,
            contextLines: 0,
            characterLimit: cloudLimit
        )

        XCTAssertEqual(window.centredOnLine, 11)
        XCTAssertEqual(window.lineCount, 1)
        XCTAssertTrue(window.text.contains("+added line"))
        XCTAssertFalse(window.text.contains("-removed line"))
        // An insertion has no base-side line of its own, so the header names the base line it
        // sits in front of — 12 — beside the head line it *is*.
        XCTAssertEqual(window.text.components(separatedBy: "\n").first, "@@ -12 +11 @@")
    }

    func testTheNoNewlineMarkerIsMetadataAndNotALine() {
        var patch = "@@ -1,2 +1,2 @@\n"
        patch += " first\n"
        patch += "-second\n"
        patch += "\\ No newline at end of file\n"
        patch += "+second changed\n"

        let window = IntelligenceDiffWindow.window(patch: patch, characterLimit: cloudLimit)

        XCTAssertFalse(window.text.contains("No newline"))
        XCTAssertEqual(window.lineCount, 3)
    }

    // MARK: - The budget

    func testTheWindowShrinksToTheCharacterBudgetAndKeepsTheCentre() {
        let window = IntelligenceDiffWindow.window(
            patch: longPatch(),
            aroundLine: 100,
            characterLimit: 400
        )

        XCTAssertLessThanOrEqual(window.text.count, 400)
        XCTAssertTrue(window.text.contains("context line 100"), "the centre is the last to go")
        XCTAssertTrue(window.wasTruncated)
        XCTAssertLessThan(window.lineCount, 49)
    }

    func testOneRowLongerThanTheWholeBudgetIsCutRatherThanSent() {
        var patch = "@@ -1,1 +1,1 @@\n"
        patch += "+" + String(repeating: "x", count: 5_000) + "\n"

        let window = IntelligenceDiffWindow.window(
            patch: patch,
            aroundLine: 1,
            characterLimit: 100
        )

        XCTAssertEqual(window.text.count, 100)
        XCTAssertTrue(window.wasTruncated)
    }

    func testNoPatchAndNoBudgetBothYieldTheEmptyWindow() {
        XCTAssertTrue(IntelligenceDiffWindow.window(patch: "", characterLimit: 1_000).isEmpty)
        XCTAssertTrue(
            IntelligenceDiffWindow.window(patch: longPatch(), characterLimit: 0).isEmpty
        )
        // Text with no `@@` at all is not a patch, whatever else it is.
        XCTAssertTrue(
            IntelligenceDiffWindow.window(
                patch: "this is not a diff\nand neither is this",
                characterLimit: 1_000
            ).isEmpty
        )
        XCTAssertEqual(IntelligenceDiffWindow.Window.empty.lineCount, 0)
    }
}

/// The pair a tool-calling answer comes back as.
final class IntelligenceToolRunTests: XCTestCase {
    private func diagnosis() -> CIDiagnosis {
        CIDiagnosis(
            failingTest: "testGermanRowsExistForEveryKey",
            file: "ShepherdTests/LocalizationTests.swift",
            line: 88,
            hypothesis: "The new catalog key has no German row.",
            confidence: .high
        )
    }

    private func trace() -> IntelligenceTrace {
        var trace = IntelligenceTrace()
        trace.append(tool: .failingChecks, summaryLine: "1 check failing", duration: 0.01)
        trace.append(
            tool: .fileDiff,
            arguments: ["line": .integer(88), "path": .string("ShepherdTests/Localization.swift")],
            summaryLine: "49 diff lines",
            duration: 0.02
        )
        return trace
    }

    func testARunCarriesTheValueAndEveryHopItTook() {
        let run = IntelligenceToolRun(value: diagnosis(), trace: trace())

        XCTAssertEqual(run.value.line, 88)
        XCTAssertEqual(run.hopCount, 2)
        XCTAssertEqual(run.trace.orderedSteps.map(\.toolName), [.failingChecks, .fileDiff])
    }

    func testARunWithNoHopsIsALegitimateAnswerRatherThanAnError() {
        // A model that answered from the check summaries in the prompt read nothing, and that is
        // an answer: the card shows a diagnosis with an empty trace, not a failure.
        let run = IntelligenceToolRun(value: diagnosis())

        XCTAssertTrue(run.trace.isEmpty)
        XCTAssertEqual(run.hopCount, 0)
    }

    func testARunRoundTripsThroughJSONWithItsTraceIntact() throws {
        let run = IntelligenceToolRun(value: diagnosis(), trace: trace())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(run)

        let decoded = try JSONDecoder().decode(
            IntelligenceToolRun<CIDiagnosis>.self,
            from: data
        )
        XCTAssertEqual(decoded, run)
        XCTAssertEqual(decoded.trace.steps.map(\.order), [0, 1])
        XCTAssertEqual(
            decoded.trace.orderedSteps.last?.argumentsDisplay,
            "line: 88, path: ShepherdTests/Localization.swift"
        )

        // The two keys are the wire shape: a run is a value and its trace, and nothing else.
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["value", "trace"])
    }
}
