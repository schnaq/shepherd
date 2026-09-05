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
        XCTAssertEqual(hunk?.lines.count, 3, "the deleted comment was dropped as a file header")
        XCTAssertEqual(UnifiedPatch.reconstruct(after: patch), ["SELECT 1", "SELECT 2"])
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
}
