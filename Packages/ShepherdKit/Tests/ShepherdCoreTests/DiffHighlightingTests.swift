import XCTest

@testable import ShepherdCore

/// Word-level changes and whole-file highlighting over reconstructed diff rows (ADR 0044).
///
/// `IntraLineDiff` decides which removed and added lines are one line edited and what changed
/// within them; `DiffHighlighting` is what a renderer actually reads, so it gets its own cases on
/// real `PatchReconstructor` output — the state it threads across rows and hunks is where a
/// tokenizer that is right line by line still goes wrong.
final class DiffHighlightingTests: XCTestCase {
    // MARK: IntraLineDiff

    func testAWordChangeMarksOnlyThatWord() throws {
        let ranges = try XCTUnwrap(
            IntraLineDiff.changedRanges(
                old: "    let total = items.count + 1", new: "    let total = items.count + offset"))
        XCTAssertEqual(ranges.old, [30..<31])
        XCTAssertEqual(ranges.new, [30..<36])
    }

    func testDissimilarLinesAreNotPaired() {
        XCTAssertNil(IntraLineDiff.changedRanges(old: "    return nil", new: "    completely different text here"))
        XCTAssertNil(IntraLineDiff.changedRanges(old: "same", new: "same"))
    }

    func testAnAppendIsStillAnEdit() throws {
        // difflib's ratio rather than common/longest: the longer line is still the same line.
        let ranges = try XCTUnwrap(IntraLineDiff.changedRanges(old: "    foo(a)", new: "    foo(a, b: c, d: e)"))
        XCTAssertEqual(ranges.old, [])
        XCTAssertEqual(ranges.new, [9..<21])
        XCTAssertNotNil(
            IntraLineDiff.changedRanges(
                old: "    \"\"\"One review.\"\"\"", new: "    \"\"\"One review, as GitHub sent it.\"\"\""))
    }

    func testALoneSpaceBetweenChangesIsAbsorbed() throws {
        let ranges = try XCTUnwrap(IntraLineDiff.changedRanges(old: "x = foo bar + y", new: "x = baz qux + y"))
        XCTAssertEqual(ranges.new, [4..<11])
    }

    func testChangedRangesNeverCutAScalar() throws {
        let new = "let ä = \"Größen\""
        let ranges = try XCTUnwrap(IntraLineDiff.changedRanges(old: "let ä = \"Größe\"", new: new))
        let bytes = Array(new.utf8)
        for range in ranges.new {
            XCTAssertNotNil(String(validating: bytes[range], as: UTF8.self), "\(range) cuts a scalar")
        }
    }

    // MARK: DiffHighlighting

    func testRowsAreParallelAndPairedEditsCarryChanges() {
        let rows = PatchReconstructor.reconstruct(
            patch: """
                @@ -1,3 +1,3 @@
                 let a = 1
                -let total = items.count + 1
                +let total = items.count + offset
                 let c = 4
                """
        ).rows
        let highlighting = DiffHighlighting(rows: rows, language: .swift)
        XCTAssertEqual(highlighting.syntax.count, rows.count)
        XCTAssertEqual(highlighting.changes.count, rows.count)
        XCTAssertEqual(highlighting.syntax[0], [], "a hunk header has no spans")
        XCTAssertEqual(highlighting.changes[1], [], "context carries no word changes")
        XCTAssertEqual(highlighting.changes[2], [26..<27])
        XCTAssertEqual(highlighting.changes[3], [26..<32])
        XCTAssertEqual(highlighting.syntax[1].first, SyntaxSpan(.keyword, 0..<3))
    }

    func testACommentOpenedOnAContextLineColoursTheNextAddedLine() {
        let rows = PatchReconstructor.reconstruct(
            patch: """
                @@ -1,2 +1,3 @@
                 /* starts here
                +let inside = 1
                 */
                """
        ).rows
        let highlighting = DiffHighlighting(rows: rows, language: .swift)
        XCTAssertEqual(highlighting.syntax[2], [SyntaxSpan(.comment, 0..<14)])
    }

    func testEachHunkRestartsItsState() {
        // The first hunk leaves a block comment open; the second starts mid-file, and its first
        // delimiter is an opener, so it starts in normal code rather than inheriting the comment.
        let rows = PatchReconstructor.reconstruct(
            patch: """
                @@ -1,1 +1,2 @@
                 let a = 1
                +/* never closed
                @@ -40,1 +41,1 @@
                -let b = 2
                +let b = 3 /* x */
                """
        ).rows
        let highlighting = DiffHighlighting(rows: rows, language: .swift)
        XCTAssertEqual(highlighting.syntax[2], [SyntaxSpan(.comment, 0..<15)])
        XCTAssertEqual(highlighting.syntax[4].first, SyntaxSpan(.keyword, 0..<3))
        XCTAssertEqual(highlighting.syntax[5].first, SyntaxSpan(.keyword, 0..<3))
    }

    func testAHunkStartingInsideACommentIsColouredAsOne() {
        let rows = PatchReconstructor.reconstruct(
            patch: """
                @@ -10,2 +10,2 @@
                - * old text */
                + * new text */
                 let x = 1
                """
        ).rows
        let highlighting = DiffHighlighting(rows: rows, language: .swift)
        XCTAssertEqual(highlighting.syntax[1], [SyntaxSpan(.comment, 0..<14)])
        XCTAssertEqual(highlighting.syntax[2], [SyntaxSpan(.comment, 0..<14)])
        XCTAssertEqual(highlighting.syntax[3].first, SyntaxSpan(.keyword, 0..<3))
    }
}
