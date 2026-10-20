import XCTest

@testable import ShepherdCore

/// The span rule for a multi-line comment picked on a touch list (ADR 0044).
///
/// Every case is one way two taps can describe a comment GitHub would refuse — and refuse the
/// whole review with it — while `validateAnchor` checks only the endpoints.
final class DiffLineRangeTests: XCTestCase {
    /// Two hunks: lines 10–13 on both sides with a replaced pair, then a second hunk at 40.
    ///
    /// ```
    /// 0 @@ -10 +10 @@
    /// 1   ctx      base 10 / head 10
    /// 2 - old a    base 11
    /// 3 - old b    base 12
    /// 4 + new a    head 11
    /// 5 + new b    head 12
    /// 6   ctx      base 13 / head 13
    /// 7 @@ -40 +40 @@
    /// 8   ctx      base 40 / head 40
    /// 9 + more     head 41
    /// ```
    private let rows = PatchReconstructor.reconstruct(patch: """
        @@ -10,4 +10,4 @@
         ctx
        -old a
        -old b
        +new a
        +new b
         ctx
        @@ -40,1 +40,2 @@
         ctx
        +more
        """).rows

    /// `DiffListContent.lineIdentity(of:)`'s rule, restated for the test: a removed row is its
    /// base line, every other row its head line.
    private func identity(_ row: PatchRow) -> (side: DiffSide, line: Int) {
        row.kind == .removed ? (.left, row.baseLine) : (.right, row.headLine)
    }

    private func span(_ a: Int, _ b: Int, commentable: (DiffSide, Int) -> Bool = { _, _ in true }) -> DiffLineRange.Span? {
        DiffLineRange.span(in: rows, from: a, to: b, identity: identity, isCommentable: commentable)
    }

    func testTheFixtureIsWhatTheDiagramSays() {
        XCTAssertEqual(rows.count, 10)
        guard case .hunk = rows[7] else { return XCTFail("row 7 should be the second hunk header") }
    }

    func testAHeadSideRangeOverRemovedRowsIsOneComment() {
        // ctx (head 10) to new b (head 12), with the two removed rows between.
        XCTAssertEqual(span(1, 5), .init(side: .right, startLine: 10, line: 12))
    }

    func testTheOrderOfTheTapsDoesNotMatter() {
        XCTAssertEqual(span(5, 1), span(1, 5))
    }

    func testOneRowIsASingleLineComment() {
        XCTAssertEqual(span(4, 4), .init(side: .right, startLine: nil, line: 11))
    }

    func testABaseSideRangeOverRemovedLines() {
        XCTAssertEqual(span(2, 3), .init(side: .left, startLine: 11, line: 12))
    }

    func testARangeAcrossSidesIsRefused() {
        XCTAssertNil(span(3, 4), "removed and added lines are on different sides")
    }

    func testARangeAcrossAHunkIsRefused() {
        XCTAssertNil(span(6, 9))
        XCTAssertNil(span(1, 7), "a hunk header is not a line")
    }

    func testAGapInTheCommentableSetEndsTheRange() {
        // "Since your review": head 11 is not in the pull request's own diff, so a range over it
        // would cross two of the pull request's hunks.
        let narrowed: (DiffSide, Int) -> Bool = { side, line in side == .right && line != 11 }
        XCTAssertNil(span(1, 6, commentable: narrowed))
        XCTAssertEqual(span(5, 6, commentable: narrowed), .init(side: .right, startLine: 12, line: 13))
        XCTAssertNil(span(2, 2, commentable: narrowed), "the base side takes no comment in that round")
    }

    func testTheWindowIsWhatASecondTapMayReach() {
        XCTAssertEqual(
            DiffLineRange.window(in: rows, around: 4, identity: identity, isCommentable: { _, _ in true }), 1...6)
        XCTAssertNil(DiffLineRange.window(in: rows, around: 0, identity: identity, isCommentable: { _, _ in true }))
        XCTAssertEqual(
            DiffLineRange.window(in: rows, around: 9, identity: identity, isCommentable: { _, _ in true }), 8...9)
    }
}
