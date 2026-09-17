import XCTest
@testable import ShepherdCore

/// The block structure ``MarkdownDocument/blocks(from:)`` reads out of a pull request body.
///
/// Inline formatting is not tested here and is not this parser's job: bold, code spans and links
/// are `AttributedString`'s, which already handles them. What it could never do is the block
/// level — headings, lists, fenced code — which is why a body rendered with it alone showed
/// "## Summary" and "- **Trigger row**" as literal text.
final class MarkdownBlockTests: XCTestCase {
    // MARK: - Headings

    func testReadsHeadings() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "# One\n## Two\n###### Six"),
            [.heading(level: 1, text: "One"), .heading(level: 2, text: "Two"), .heading(level: 6, text: "Six")]
        )
    }

    /// Seven hashes is not a heading in any Markdown dialect, and a `#hashtag` is not one either.
    func testRefusesOverlongAndUnspacedHashes() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "####### Seven"),
            [.paragraph("####### Seven")]
        )
        XCTAssertEqual(MarkdownDocument.blocks(from: "#hashtag"), [.paragraph("#hashtag")])
    }

    // MARK: - Lists

    func testReadsBulletsOfEveryMarker() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "- one\n* two\n+ three"),
            [
                .listItem(text: "one", marker: "•", depth: 0),
                .listItem(text: "two", marker: "•", depth: 0),
                .listItem(text: "three", marker: "•", depth: 0),
            ]
        )
    }

    func testReadsNumberedItemsKeepingTheirNumbers() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "1. one\n2. two\n10) ten"),
            [
                .listItem(text: "one", marker: "1.", depth: 0),
                .listItem(text: "two", marker: "2.", depth: 0),
                .listItem(text: "ten", marker: "10.", depth: 0),
            ]
        )
    }

    func testReadsNesting() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "- one\n    - deeper\n        - deepest"),
            [
                .listItem(text: "one", marker: "•", depth: 0),
                .listItem(text: "deeper", marker: "◦", depth: 1),
                .listItem(text: "deepest", marker: "▪", depth: 2),
            ]
        )
    }

    /// A task list is the shape half of GitHub's checklists arrive in.
    func testReadsTaskItems() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "- [x] done\n- [ ] open"),
            [
                .listItem(text: "done", marker: "☑", depth: 0),
                .listItem(text: "open", marker: "☐", depth: 0),
            ]
        )
    }

    /// A dash with no space after it is a sentence, not a bullet.
    func testRefusesADashWithoutASpace() {
        XCTAssertEqual(MarkdownDocument.blocks(from: "-notalist"), [.paragraph("-notalist")])
    }

    // MARK: - Fenced code

    func testReadsFencedCodeWithItsLanguage() {
        let source = "```swift\nlet a = 1\nlet b = 2\n```"
        XCTAssertEqual(
            MarkdownDocument.blocks(from: source),
            [.codeBlock(code: "let a = 1\nlet b = 2", language: "swift")]
        )
    }

    func testReadsFencedCodeWithoutALanguage() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "```\nplain\n```"),
            [.codeBlock(code: "plain", language: nil)]
        )
    }

    /// Everything inside a fence is literal — a `#` in a shell snippet is a comment, not a
    /// heading, and a `-` is a flag, not a bullet.
    func testFencedCodeIsLiteral() {
        let source = "```sh\n# not a heading\n- not a bullet\n```"
        XCTAssertEqual(
            MarkdownDocument.blocks(from: source),
            [.codeBlock(code: "# not a heading\n- not a bullet", language: "sh")]
        )
    }

    /// A body that opens a fence and never closes it still has to render; the rest of it is code.
    func testAnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "```\nstill code"),
            [.codeBlock(code: "still code", language: nil)]
        )
    }

    // MARK: - Quotes and rules

    func testReadsQuotesAsOneBlock() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "> first\n> second"),
            [.quote("first\nsecond")]
        )
    }

    func testReadsThematicBreaks() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "a\n\n---\n\nb"),
            [.paragraph("a"), .rule, .paragraph("b")]
        )
    }

    // MARK: - Paragraphs

    /// GitHub renders a single newline inside a paragraph as a line break, so the parser keeps it
    /// rather than reflowing: a body whose lines were joined would run its own list-like prose
    /// together.
    func testKeepsLineBreaksWithinAParagraph() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "one\ntwo\n\nthree"),
            [.paragraph("one\ntwo"), .paragraph("three")]
        )
    }

    func testDropsTrailingWhitespaceAndEmptyInput() {
        XCTAssertEqual(MarkdownDocument.blocks(from: ""), [])
        XCTAssertEqual(MarkdownDocument.blocks(from: "   \n\n  "), [])
    }

    /// The shape the report that prompted this arrives in.
    func testReadsARealPullRequestBody() {
        let source = """
            ## Summary

            The bottom of the dashboard sidebar stacked four unrelated rows.

            - **Trigger row** with the same geometry as the nav items
            - **Menu** opening upward at trigger width

            ## Verification

            - packages/ui: Jest green
            """
        XCTAssertEqual(
            MarkdownDocument.blocks(from: source),
            [
                .heading(level: 2, text: "Summary"),
                .paragraph("The bottom of the dashboard sidebar stacked four unrelated rows."),
                .listItem(text: "**Trigger row** with the same geometry as the nav items", marker: "•", depth: 0),
                .listItem(text: "**Menu** opening upward at trigger width", marker: "•", depth: 0),
                .heading(level: 2, text: "Verification"),
                .listItem(text: "packages/ui: Jest green", marker: "•", depth: 0),
            ]
        )
    }
}
