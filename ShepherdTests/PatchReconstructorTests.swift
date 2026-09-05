import ShepherdCore
import XCTest

@testable import Shepherd

/// The patch → two-documents mapping the diff viewer depends on.
final class PatchReconstructorTests: XCTestCase {
    func testHeaderParsing() {
        XCTAssertEqual(
            PatchReconstructor.header("@@ -12,7 +14,9 @@ func thing()").map { [$0.0, $0.1] },
            [12, 14]
        )
        XCTAssertEqual(
            PatchReconstructor.header("@@ -0,0 +1 @@").map { [$0.0, $0.1] },
            [0, 1]
        )
        XCTAssertNil(PatchReconstructor.header("not a hunk header"))
        XCTAssertNil(PatchReconstructor.header("@@ nonsense @@"))
    }

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

    func testLanguageMapping() {
        XCTAssertEqual(MonacoLanguage.id(forPath: "Sources/App/Main.swift"), "swift")
        XCTAssertEqual(MonacoLanguage.id(forPath: "web/src/main.ts"), "typescript")
        XCTAssertEqual(MonacoLanguage.id(forPath: "Dockerfile"), "dockerfile")
        XCTAssertEqual(MonacoLanguage.id(forPath: "Cargo.toml"), "toml")
        XCTAssertEqual(MonacoLanguage.id(forPath: "LICENSE"), "plaintext")
        XCTAssertEqual(MonacoLanguage.id(forPath: "deploy/values.YAML"), "yaml")
    }
}
