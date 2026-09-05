import Foundation
import XCTest

@testable import ShepherdCore

/// The patch → two-documents mapping the diff viewer depends on.
///
/// These cases used to run only under `xcodebuild`, because `PatchReconstructor` sat in the app
/// target — the same gap `UnifiedPatchTests` closed for the grammar underneath it, left open for
/// the fiddliest pure logic in the app. The type moved into this package and its tests came with
/// it, so both legs exercise them now (`docs/ARCHITECTURE.md` § Verification reality check).
final class PatchReconstructorTests: XCTestCase {
    func testSimpleModification() {
        let patch = """
            @@ -1,3 +1,3 @@
             let a = 1
            -let b = 2
            +let b = 3
             let c = 4
            """
        let result = PatchReconstructor.reconstruct(patch: patch)
        XCTAssertEqual(result.original, "let a = 1\nlet b = 2\nlet c = 4")
        XCTAssertEqual(result.modified, "let a = 1\nlet b = 3\nlet c = 4")
        XCTAssertEqual(result.firstChangedLine, 2)
    }

    func testATerminatingNewlineChangesNothing() {
        // No producer this app has ends a patch with a newline — GitHub's `files[].patch` does
        // not, and the interdiff synthesizes its patch with `joined(separator:)` — so this is a
        // guard against a third one rather than a fix. It is worth a test because of what the
        // difference costs: the empty component after the newline reads as an unchanged empty
        // line, which lands in *both* documents and in *both* commentable sets, and a comment on
        // a line that is not in the diff is one GitHub refuses along with the whole review.
        let patch = """
            @@ -1,3 +1,3 @@
             let a = 1
            -let b = 2
            +let b = 3
             let c = 4
            """
        let terminated = PatchReconstructor.reconstruct(patch: patch + "\n")
        let bare = PatchReconstructor.reconstruct(patch: patch)

        XCTAssertEqual(terminated, bare, "a terminating newline changed the reconstruction")
        XCTAssertEqual(terminated.modified, "let a = 1\nlet b = 3\nlet c = 4")
        XCTAssertEqual(terminated.commentableModifiedLines, [1, 2, 3], "line 4 does not exist")
        XCTAssertEqual(terminated.commentableOriginalLines, [1, 2, 3], "line 4 does not exist")
    }

    func testAddedFileHasAnEmptyOriginal() {
        let patch = """
            @@ -0,0 +1,2 @@
            +first
            +second
            """
        let result = PatchReconstructor.reconstruct(patch: patch)
        XCTAssertEqual(result.original, "")
        XCTAssertEqual(result.modified, "first\nsecond")
    }

    func testGapsBetweenHunksArePaddedSoLineNumbersMatchGitHub() {
        let patch = """
            @@ -1,2 +1,2 @@
             one
            -two
            +TWO
            @@ -10,2 +10,2 @@
             ten
            -eleven
            +ELEVEN
            """
        let result = PatchReconstructor.reconstruct(patch: patch)
        let modifiedLines = result.modified.components(separatedBy: "\n")
        // Line 10 of the modified document must still be "ten".
        XCTAssertEqual(modifiedLines.count, 11)
        XCTAssertEqual(modifiedLines[9], "ten")
        XCTAssertEqual(modifiedLines[10], "ELEVEN")
        // The padding is identical on both sides, so the diff editor sees it as unchanged.
        let originalLines = result.original.components(separatedBy: "\n")
        XCTAssertEqual(Array(originalLines[2..<9]), Array(modifiedLines[2..<9]))
    }

    func testNoNewlineMarkerIsIgnored() {
        let patch = """
            @@ -1,1 +1,1 @@
            -old
            \\ No newline at end of file
            +new
            """
        let result = PatchReconstructor.reconstruct(patch: patch)
        XCTAssertEqual(result.original, "old")
        XCTAssertEqual(result.modified, "new")
    }

    // MARK: - Content that looks like a file header

    func testADeletedSQLCommentIsNotMistakenForAFileHeader() {
        // GitHub's `files[].patch` starts at the first `@@` and never carries `--- a/x` or
        // `+++ b/x`. A removed SQL/Lua comment "-- foo" serialises as "--- foo", and an added
        // "++ x" as "+++ x": filtering for header prefixes inside a hunk silently drops real
        // content and shifts every following line number by one.
        let patch = """
            @@ -1,4 +1,4 @@
             CREATE TABLE etags (
            --- keyed by absolute URL
            +++ keyed by normalised URL
               key TEXT PRIMARY KEY
             );
            """
        let result = PatchReconstructor.reconstruct(patch: patch)
        let originalLines = result.original.components(separatedBy: "\n")
        let modifiedLines = result.modified.components(separatedBy: "\n")

        XCTAssertEqual(originalLines[1], "-- keyed by absolute URL")
        XCTAssertEqual(modifiedLines[1], "++ keyed by normalised URL")
        // Line 3 of both documents must still be the primary-key line: a dropped line here
        // would anchor every LEFT-side thread and draft comment one line high.
        XCTAssertEqual(originalLines[2], "  key TEXT PRIMARY KEY")
        XCTAssertEqual(modifiedLines[2], "  key TEXT PRIMARY KEY")
        XCTAssertEqual(originalLines.count, 4)
        XCTAssertEqual(modifiedLines.count, 4)
    }

    func testTextBeforeTheFirstHunkHeaderIsIgnored() {
        let patch = """
            diff --git a/a.txt b/a.txt
            index 1111111..2222222 100644
            --- a/a.txt
            +++ b/a.txt
            @@ -1,1 +1,1 @@
            -old
            +new
            """
        let result = PatchReconstructor.reconstruct(patch: patch)
        XCTAssertEqual(result.original, "old")
        XCTAssertEqual(result.modified, "new")
    }

    // MARK: - Commentable lines

    func testOnlyLinesFromTheHunksAreCommentable() {
        let patch = """
            @@ -1,2 +1,2 @@
             one
            -two
            +TWO
            @@ -10,2 +10,2 @@
             ten
            -eleven
            +ELEVEN
            """
        let result = PatchReconstructor.reconstruct(patch: patch)

        // The inter-hunk filler (lines 3…9) is padding, not diff: GitHub rejects a comment on
        // it — and rejects the whole review with it.
        XCTAssertEqual(result.commentableOriginalLines, [1, 2, 10, 11])
        XCTAssertEqual(result.commentableModifiedLines, [1, 2, 10, 11])
        for line in 3...9 {
            XCTAssertFalse(result.commentableModifiedLines.contains(line), "line \(line)")
            XCTAssertFalse(result.commentableOriginalLines.contains(line), "line \(line)")
        }
    }

    func testEachSideCountsOnlyTheLinesItActuallyGained() {
        let patch = """
            @@ -1,3 +1,2 @@
            -removed one
            -removed two
            +added
             context
            """
        let result = PatchReconstructor.reconstruct(patch: patch)

        // Three original lines, two modified ones: the sets are per side, never shared.
        XCTAssertEqual(result.original, "removed one\nremoved two\ncontext")
        XCTAssertEqual(result.modified, "added\ncontext")
        XCTAssertEqual(result.commentableOriginalLines, [1, 2, 3])
        XCTAssertEqual(result.commentableModifiedLines, [1, 2])
        XCTAssertEqual(result.commentableLines(on: .left), result.commentableOriginalLines)
        XCTAssertEqual(result.commentableLines(on: .right), result.commentableModifiedLines)
    }

    func testAnAddedFileHasNoCommentableOriginalLines() {
        let patch = """
            @@ -0,0 +1,2 @@
            +first
            +second
            """
        let result = PatchReconstructor.reconstruct(patch: patch)
        XCTAssertTrue(result.commentableOriginalLines.isEmpty)
        XCTAssertEqual(result.commentableModifiedLines, [1, 2])
    }

    func testTheNoNewlineMarkerIsNotCommentable() {
        let patch = """
            @@ -1,1 +1,1 @@
            -old
            \\ No newline at end of file
            +new
            """
        let result = PatchReconstructor.reconstruct(patch: patch)
        XCTAssertEqual(result.commentableOriginalLines, [1])
        XCTAssertEqual(result.commentableModifiedLines, [1])
    }

    func testBinaryFileHasNoReconstruction() {
        let file = ChangedFile(path: "logo.png", status: .modified, patch: nil)
        XCTAssertNil(PatchReconstructor.reconstruct(file))
    }

    // MARK: - Rows

    func testTheRowsOfASimpleModificationNameBothSidesOfEveryLine() {
        let patch = """
            @@ -1,3 +1,3 @@
             let a = 1
            -let b = 2
            +let b = 3
             let c = 4
            """
        let result = PatchReconstructor.reconstruct(patch: patch)

        // Pinned as one literal so that a kind, a text and either line number cannot change
        // without this failing: the four facts a list row renders are one fact together.
        XCTAssertEqual(
            result.rows,
            [
                .hunk(originalStart: 1, modifiedStart: 1),
                .line(PatchRow(kind: .context, text: "let a = 1", baseLine: 1, headLine: 1)),
                .line(PatchRow(kind: .removed, text: "let b = 2", baseLine: 2, headLine: 2)),
                .line(PatchRow(kind: .added, text: "let b = 3", baseLine: 3, headLine: 2)),
                .line(PatchRow(kind: .context, text: "let c = 4", baseLine: 3, headLine: 3)),
            ]
        )
    }

    func testARemovedRowNamesTheHeadLineTheDeletionSitsInFrontOf() {
        // Two additions before the deletion pull the two sides apart, so the answer differs
        // from the head-side count at the moment the deletion is read. Without that gap the
        // right answer and the naive one coincide and the test proves nothing.
        let result = PatchReconstructor.reconstruct(patch: Self.twoSidesPulledApart)
        let removed = Self.lineRows(of: result).filter { $0.kind == .removed }

        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.text, "three")
        XCTAssertEqual(removed.first?.baseLine, 3, "the deleted line is base line 3")
        XCTAssertEqual(
            removed.first?.headLine,
            5,
            "the deletion sits in front of head line 5, not at the head count of 4"
        )
        // …and head line 5 is the line a reviewer following that number lands on.
        XCTAssertEqual(result.modified.components(separatedBy: "\n")[4], "four")
    }

    func testAnAddedRowNamesTheBaseLineTheAdditionSitsInFrontOf() {
        let result = PatchReconstructor.reconstruct(patch: Self.twoSidesPulledApart)
        let added = Self.lineRows(of: result).filter { $0.kind == .added }

        XCTAssertEqual(added.map(\.text), ["inserted", "another"])
        XCTAssertEqual(added.last?.headLine, 3, "the second addition is head line 3")
        XCTAssertEqual(
            added.last?.baseLine,
            2,
            "the addition sits in front of base line 2, not at the base count of 1"
        )
        // …and base line 2 is the line it was inserted ahead of.
        XCTAssertEqual(result.original.components(separatedBy: "\n")[1], "two")
    }

    func testEveryRowsLineNumberIsCommentableOnTheSideItExistsOn() {
        // The invariant the row model rests on: a row's number and the commentable set for its
        // side come from the same count, so a row can never offer a comment on a line GitHub
        // would reject. Checked over every row of a two-hunk patch, not a spot check.
        let patch = """
            @@ -1,3 +1,4 @@
             alpha
            -beta
            +BETA
            +gamma
             delta
            @@ -20,3 +21,3 @@
             twenty
            -twentyone
            +TWENTYONE
             twentytwo
            """
        let result = PatchReconstructor.reconstruct(patch: patch)
        let rows = Self.lineRows(of: result)

        for row in rows {
            if row.kind != .added {
                XCTAssertTrue(
                    result.commentableOriginalLines.contains(row.baseLine),
                    "\(row.kind) row \"\(row.text)\" claims base line \(row.baseLine)"
                )
            }
            if row.kind != .removed {
                XCTAssertTrue(
                    result.commentableModifiedLines.contains(row.headLine),
                    "\(row.kind) row \"\(row.text)\" claims head line \(row.headLine)"
                )
            }
        }
        // A loop that ran over the wrong rows, or over none, would pass in silence.
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows.filter { $0.kind == .removed }.count, 2)
        XCTAssertEqual(rows.filter { $0.kind == .added }.count, 3)
        XCTAssertEqual(rows.filter { $0.kind == .context }.count, 4)
    }

    func testTheGapBetweenHunksProducesNoRows() {
        // The same fixture the padding test uses: seven filler lines between the hunks, which
        // are in both documents and in neither commentable set. A list shows hunks with a
        // header between them, so the filler is not a row either.
        let patch = """
            @@ -1,2 +1,2 @@
             one
            -two
            +TWO
            @@ -10,2 +10,2 @@
             ten
            -eleven
            +ELEVEN
            """
        let result = PatchReconstructor.reconstruct(patch: patch)

        // Six patch lines and two headers, and nothing at all for the gap between them.
        XCTAssertEqual(result.rows.count, 8)
        for row in Self.lineRows(of: result) {
            if row.kind != .added {
                XCTAssertFalse(
                    (3...9).contains(row.baseLine),
                    "base line \(row.baseLine) is filler"
                )
            }
            if row.kind != .removed {
                XCTAssertFalse(
                    (3...9).contains(row.headLine),
                    "head line \(row.headLine) is filler"
                )
            }
            XCTAssertFalse(row.text.isEmpty, "a filler line reached the rows")
        }
    }

    func testTheNoNewlineMarkerProducesNoRow() {
        let patch = """
            @@ -1,1 +1,1 @@
            -old
            \\ No newline at end of file
            +new
            """
        let result = PatchReconstructor.reconstruct(patch: patch)

        // The marker is metadata about the file's last byte, not a line anyone can comment on,
        // so it is absent from the rows exactly as it is absent from the two documents.
        XCTAssertEqual(
            result.rows,
            [
                .hunk(originalStart: 1, modifiedStart: 1),
                .line(PatchRow(kind: .removed, text: "old", baseLine: 1, headLine: 1)),
                .line(PatchRow(kind: .added, text: "new", baseLine: 2, headLine: 1)),
            ]
        )
    }

    func testATwoHunkPatchYieldsOneHeaderRowPerHunk() {
        let result = PatchReconstructor.reconstruct(patch: Self.twoHunksWithUnequalStarts)
        let headers = result.rows.filter { row -> Bool in
            if case .hunk = row { return true }
            return false
        }

        // The first hunk is a net addition of one line, so the second hunk starts one line
        // further along on the head side than on the base side. A header that reported one of
        // the two numbers for both sides would be caught here rather than by a reader.
        XCTAssertEqual(
            headers,
            [.hunk(originalStart: 1, modifiedStart: 1), .hunk(originalStart: 20, modifiedStart: 21)]
        )
    }

    // MARK: - Row fixtures and helpers

    /// A hunk whose two sides drift apart: two lines added, then one removed, then context.
    ///
    /// Base is `one two three four`, head is `one inserted another two four`, so the removed
    /// line's head number and the added lines' base numbers are all different from the count of
    /// the side they were read on — which is what makes an assertion about them mean anything.
    private static let twoSidesPulledApart = """
        @@ -1,4 +1,5 @@
         one
        +inserted
        +another
         two
        -three
         four
        """

    private static let twoHunksWithUnequalStarts = """
        @@ -1,3 +1,4 @@
         alpha
        -beta
        +BETA
        +gamma
         delta
        @@ -20,3 +21,3 @@
         twenty
        -twentyone
        +TWENTYONE
         twentytwo
        """

    /// The `.line` rows of a reconstruction, in order, with the headers dropped.
    private static func lineRows(
        of reconstruction: PatchReconstructor.Reconstruction
    ) -> [PatchRow] {
        reconstruction.rows.compactMap { row -> PatchRow? in
            guard case let .line(patchRow) = row else { return nil }
            return patchRow
        }
    }
}
