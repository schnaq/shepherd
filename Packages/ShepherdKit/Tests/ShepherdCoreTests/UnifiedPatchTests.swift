import Foundation
import XCTest

@testable import ShepherdCore

/// The unified-diff grammar, which is now read in exactly one place.
///
/// These cases used to live in the app target's `PatchReconstructorTests`, against a second copy
/// of the same twenty lines. They belong here for two reasons: the copy is gone, and this is the
/// leg that runs on Linux — the parser is the fiddliest pure logic in the app and it had never
/// been exercised there (`docs/ARCHITECTURE.md` § Verification reality check).
final class UnifiedPatchTests: XCTestCase {
    func testHeaderParsing() {
        XCTAssertEqual(
            UnifiedPatch.header("@@ -12,7 +14,9 @@ func thing()").map { [$0.0, $0.1] },
            [12, 14]
        )
        XCTAssertEqual(
            UnifiedPatch.header("@@ -0,0 +1 @@").map { [$0.0, $0.1] },
            [0, 1]
        )
        XCTAssertNil(UnifiedPatch.header("not a hunk header"))
        XCTAssertNil(UnifiedPatch.header("@@ nonsense @@"))
    }

    func testATerminatingNewlineAddsNoLine() {
        // The empty component a trailing newline leaves behind is not a line. It matters because
        // of what the app-side reconstructor does with one: no marker character means "unchanged
        // empty line", so it would land in both documents and in both commentable-line sets, and
        // a comment on a line that is not in the diff is one GitHub refuses along with the whole
        // review.
        let patch = """
            @@ -1,2 +1,2 @@
             kept
            -old
            +new
            """
        XCTAssertEqual(
            UnifiedPatch.hunks(in: patch + "\n"),
            UnifiedPatch.hunks(in: patch),
            "a terminating newline changed the hunks"
        )
        XCTAssertEqual(UnifiedPatch.hunks(in: patch + "\n").first?.lines.count, 3)
    }

    func testADeletedCommentIsNotMistakenForAFileHeader() {
        // GitHub's patch starts at the first `@@` and never carries `--- a/x` / `+++ b/x`, so
        // filtering for those here would only ever eat content: a removed `-- SQL comment`
        // serialises as `--- SQL comment`, and dropping it shifts every following original-side
        // line number by one.
        let patch = """
            @@ -1,3 +1,2 @@
             SELECT 1
            --- a/a.txt
             SELECT 2
            """
        let hunk = UnifiedPatch.hunks(in: patch).first
        // The line itself, not just the count: a `-` row never reaches the head side either way,
        // so asserting the *reconstruction* here would hold whether the guard existed or not.
        XCTAssertEqual(hunk?.lines, [" SELECT 1", "--- a/a.txt", " SELECT 2"])
    }

    func testTextBeforeTheFirstHeaderIsIgnored() {
        let patch = """
            diff --git a/a.txt b/a.txt
            index 1234567..89abcde 100644
            @@ -1,1 +1,1 @@
            -old
            +new
            """
        XCTAssertEqual(UnifiedPatch.hunks(in: patch).count, 1)
        XCTAssertEqual(UnifiedPatch.reconstruct(after: patch), ["new"])
    }

    func testHeaderRoundTrip() {
        let written = UnifiedPatch.writeHeader(
            originalStart: 12, originalCount: 7, modifiedStart: 14, modifiedCount: 9
        )
        XCTAssertEqual(written, "@@ -12,7 +14,9 @@")
        XCTAssertEqual(UnifiedPatch.header(written).map { [$0.0, $0.1] }, [12, 14])
    }

    func testCarriageReturnsAreStrippedFromTheContentToo() {
        // Worth stating precisely, because the two readings of these bytes are the same bytes.
        // A patch "with CRLF separators" and a patch of a CRLF *file* — where git writes LF
        // separators and each content line keeps the file's own trailing `\r` — are
        // indistinguishable: both are `…content\r\n…`. So this normalisation is not only about
        // accepting Windows separators; it always takes the carriage return off the content as
        // well. That is what the viewer wants (an invisible CR would otherwise be drawn, and
        // quoted into comment bodies), it is what nothing had written down, and line numbers are
        // unaffected either way. The assertion below is the one that shows it: a surviving `\r`
        // would make the lines unequal.
        let patch = "@@ -1,2 +1,2 @@\r\n kept\r\n-old\r\n+new\r\n"
        let hunk = UnifiedPatch.hunks(in: patch).first

        XCTAssertEqual(hunk?.lines, [" kept", "-old", "+new"])
        XCTAssertEqual(UnifiedPatch.reconstruct(after: patch), ["kept", "new"])
        XCTAssertEqual(hunk?.originalStart, 1)
    }

    func testTheNoNewlineMarkerIsMetadataRatherThanALine() {
        // `\ No newline at end of file` is the one body line that is not content. Counted as a
        // line it would shift every following line number by one, which is the number review
        // threads are anchored by.
        let patch = """
            @@ -1,1 +1,1 @@
            -old
            \\ No newline at end of file
            +new
            \\ No newline at end of file
            """
        XCTAssertEqual(UnifiedPatch.reconstruct(after: patch), ["new"])
    }

    func testAPatchWithNoHunkHeaderYieldsNothing() {
        XCTAssertEqual(UnifiedPatch.hunks(in: "").count, 0)
        XCTAssertEqual(UnifiedPatch.hunks(in: "just some text\nand more").count, 0)
        XCTAssertEqual(UnifiedPatch.reconstruct(after: nil), [])
        XCTAssertEqual(UnifiedPatch.reconstruct(after: "no hunks here"), [])
    }
}
