import ShepherdCore
import SwiftUI
import XCTest

@testable import Shepherd

/// The two pieces of the native diff's colouring that can go wrong without anything looking
/// broken in a screenshot (ADR 0044): cutting a line at UTF-8 byte offsets, where a span and a
/// change overlap, and refusing to paint one file's colours onto another file's rows.
final class SyntaxStyleTests: XCTestCase {
    /// `let café = "x"` — the `é` is two bytes, so every cut after it is off by one if the line
    /// is ever cut by characters rather than bytes. The change runs from `café` into the string
    /// and stops before its closing quote, so it crosses a span boundary.
    func testCutsAtByteOffsetsWhereSpansAndChangesOverlap() {
        let text = "let café = \"x\""
        XCTAssertEqual(text.utf8.count, 15)
        let line = SyntaxStyle.attributed(
            text,
            syntax: [SyntaxSpan(.keyword, 0..<3), SyntaxSpan(.string, 12..<15)],
            changes: [4..<14],
            tint: Theme.success
        )
        XCTAssertEqual(String(line.characters), text)
        let runs = line.runs.map {
            (String(line[$0.range].characters), $0.foregroundColor != nil, $0.backgroundColor != nil)
        }
        XCTAssertEqual(runs.map(\.0), ["let", " ", "café = ", "\"x", "\""])
        XCTAssertEqual(runs.map(\.1), [true, false, false, true, true], "token colour")
        XCTAssertEqual(runs.map(\.2), [false, false, true, true, false], "word highlight")
    }

    func testDrawsOnlyOntoTheRowsItWasBuiltFrom() async throws {
        let rows: [PatchReconstructor.DiffRow] = [
            .hunk(originalStart: 1, modifiedStart: 1),
            .line(PatchRow(kind: .removed, text: "let a = 1", baseLine: 1, headLine: 1)),
            .line(PatchRow(kind: .added, text: "let a = 2", baseLine: 2, headLine: 1)),
        ]
        let built = await HighlightedDiff.build(rows: rows, path: "A.swift")
        let highlighted = try XCTUnwrap(built)
        let lines = try XCTUnwrap(highlighted.lines(for: rows))
        XCTAssertEqual(lines.count, rows.count)
        XCTAssertNil(lines[0], "a hunk header has no line")
        XCTAssertNotNil(lines[1])

        // As many rows, another file: the colours are not this file's.
        var other = rows
        other[2] = .line(PatchRow(kind: .added, text: "let b = 2", baseLine: 2, headLine: 1))
        XCTAssertNil(highlighted.lines(for: other))
    }

    func testLeavesAFileOverTheRowLimitPlain() async {
        let rows = (1...HighlightedDiff.rowLimit + 1).map {
            PatchReconstructor.DiffRow.line(PatchRow(kind: .context, text: "x", baseLine: $0, headLine: $0))
        }
        let built = await HighlightedDiff.build(rows: rows, path: "A.swift")
        XCTAssertNil(built)
    }
}
