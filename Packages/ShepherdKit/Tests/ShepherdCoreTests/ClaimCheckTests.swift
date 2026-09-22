import Foundation
import ShepherdCore
import XCTest

final class ClaimCheckTests: XCTestCase {
    private let patch = """
        @@ -10,4 +10,5 @@ struct Parser {
         struct Parser {
        -    func parse(text: String) -> AST {
        +    func parse(_ text: String) -> AST {
        +        precondition(!text.isEmpty)
                 return AST(text)
         }
        """

    private func file(_ path: String = "Sources/Parser.swift", patch: String? = nil) -> ChangedFile {
        ChangedFile(path: path, status: .modified, additions: 2, deletions: 1, patch: patch ?? self.patch)
    }

    private func note(
        _ excerpt: String,
        path: String = "Sources/Parser.swift",
        sentence: String = "The label of the parameter changed."
    ) -> ClaimCheck.Note {
        ClaimCheck.Note(path: path, excerpt: excerpt, sentence: sentence)
    }

    // MARK: - locate

    func testAnAddedLineIsFoundAtItsHeadSideLine() {
        let location = DiffExcerpt.locate("func parse(_ text: String) -> AST {", inPatch: patch)
        XCTAssertEqual(location, DiffExcerpt.Location(line: 11))
    }

    func testAContextLineIsFoundAtItsHeadSideLine() {
        let location = DiffExcerpt.locate("return AST(text)", inPatch: patch)
        XCTAssertEqual(location, DiffExcerpt.Location(line: 13))
    }

    func testARemovedLineIsFoundWithoutAHeadLine() {
        let location = DiffExcerpt.locate("func parse(text: String) -> AST {", inPatch: patch)
        XCTAssertEqual(location, DiffExcerpt.Location(line: nil))
    }

    func testConsecutiveLinesAreFoundTogether() {
        let excerpt = """
            func parse(_ text: String) -> AST {
                precondition(!text.isEmpty)
            """
        XCTAssertEqual(DiffExcerpt.locate(excerpt, inPatch: patch)?.line, 11)
    }

    func testLinesThatAreNotConsecutiveAreNotAnExcerpt() {
        let excerpt = """
            struct Parser {
                return AST(text)
            """
        XCTAssertNil(DiffExcerpt.locate(excerpt, inPatch: patch))
    }

    func testDiffMarkersInTheExcerptAreIgnored() {
        let excerpt = """
            -    func parse(text: String) -> AST {
            +    func parse(_ text: String) -> AST {
            """
        XCTAssertEqual(DiffExcerpt.locate(excerpt, inPatch: patch), DiffExcerpt.Location(line: nil))
    }

    func testWhitespaceIsFoldedButCaseIsKept() {
        XCTAssertNotNil(DiffExcerpt.locate("\tprecondition(!text.isEmpty)\t", inPatch: patch))
        XCTAssertNotNil(DiffExcerpt.locate("   return    AST(text)  ", inPatch: patch))
        XCTAssertNil(DiffExcerpt.locate("RETURN AST(text)", inPatch: patch))
    }

    func testAnEmptyExcerptIsNotFound() {
        XCTAssertNil(DiffExcerpt.locate("  \n ", inPatch: patch))
    }

    // MARK: - verified

    func testANoteIsKeptWithTheLineItWasFoundAt() {
        let kept = ClaimCheck.verified([note("precondition(!text.isEmpty)")], in: [file()])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.line, 12)
        XCTAssertEqual(kept.first?.sentence, "The label of the parameter changed.")
    }

    func testANoteForAFileThePullRequestDidNotChangeIsDropped() {
        XCTAssertTrue(ClaimCheck.verified([note("return AST(text)", path: "Other.swift")], in: [file()]).isEmpty)
    }

    func testANoteWhoseExcerptIsNotInTheDiffIsDropped() {
        XCTAssertTrue(ClaimCheck.verified([note("func tokenize()")], in: [file()]).isEmpty)
    }

    func testAPreviousPathFindsTheRenamedFile() {
        var renamed = file("Sources/NewParser.swift")
        renamed.previousPath = "Sources/Parser.swift"
        let kept = ClaimCheck.verified([note("return AST(text)")], in: [renamed])
        XCTAssertEqual(kept.first?.path, "Sources/NewParser.swift")
    }

    func testDuplicatesAreDroppedAndTheListIsCapped() {
        let notes = [
            note("return AST(text)"),
            note("   return AST(text)"),
            note("struct Parser {"),
            note("precondition(!text.isEmpty)"),
            note("func parse(_ text: String) -> AST {"),
            note("func parse(text: String) -> AST {"),
        ]
        let kept = ClaimCheck.verified(notes, in: [file()])
        XCTAssertEqual(kept.count, ClaimCheck.maximumNotes)
        XCTAssertEqual(kept.map(\.excerpt).first, "return AST(text)")
        XCTAssertEqual(Set(kept.map(\.id)).count, kept.count)
    }

    func testAnEmptySentenceIsDropped() {
        XCTAssertTrue(ClaimCheck.verified([note("return AST(text)", sentence: "  ")], in: [file()]).isEmpty)
    }
}
