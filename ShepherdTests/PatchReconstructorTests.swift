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
