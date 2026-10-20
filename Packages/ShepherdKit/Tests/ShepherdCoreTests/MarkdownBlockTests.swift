import XCTest
@testable import ShepherdCore

/// The block structure ``MarkdownDocument/blocks(from:)`` reads out of a pull request body.
///
/// Inline formatting is not tested here and is not this parser's job: bold, code spans and links
/// are `AttributedString`'s, which already handles them. What it could never do is the block
/// level — headings, lists, fenced code — which is why a body rendered with it alone showed
/// "## Summary" and "- **Trigger row**" as literal text.
final class MarkdownBlockTests: XCTestCase {
    // MARK: - HTML that GitHub renders (ADR 0043)

    /// Bots open their comments with markers like `<!-- ccr-overview-v2 -->`; GitHub never shows
    /// them, so neither may the conversation tab.
    func testDropsHTMLCommentsOnTheirOwnLineInlineAndAcrossLines() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "<!-- marker -->\nHello <!-- hidden --> there\n<!-- one\ntwo -->\nAfter"),
            [.paragraph("Hello  there\nAfter")]
        )
    }

    /// A `<!--` in a sentence is the syntax being written about. Read as an open comment, it hid
    /// everything after it — the next paragraph included.
    func testAnOpenerInTheMiddleOfALineWithoutAnEndIsProse() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "Use <!-- to start a comment.\n\nThe next paragraph."),
            [.paragraph("Use <!-- to start a comment."), .paragraph("The next paragraph.")]
        )
    }

    /// The shape bots hide their state in: an opener at the start of a line, the end lines later.
    func testACommentOpeningALineStillHidesTheLinesUntilItsEnd() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "Before\n\n  <!-- state\n{\"runs\": 3}\n-->\nAfter"),
            [.paragraph("Before"), .paragraph("After")]
        )
    }

    func testLeavesAnHTMLCommentInsideAFenceAlone() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "```html\n<!-- kept -->\n```"),
            [.codeBlock(code: "<!-- kept -->", language: "html")]
        )
    }

    func testUnwrapsDetailsAndDrawsTheSummaryAsABoldLine() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "<details open>\n<summary> Full log </summary>\n\n- one\n\n</details>"),
            [.paragraph("**Full log**"), .listItem(text: "one", marker: "•", depth: 0)]
        )
    }

    /// A label is drawn bold as a whole, so the emphasis bots wrap inside it goes, and a `<code>`
    /// is a code span.
    func testASummaryLabelLosesItsEmphasisTagsAndKeepsItsCode() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "<summary>:warning: <b>Different runtime environments detected</b></summary>"),
            [.paragraph("**:warning: Different runtime environments detected**")]
        )
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "<details><summary><strong>Ran</strong> <code>swift test</code></summary>"),
            [.paragraph("**Ran `swift test`**")]
        )
    }

    func testTurnsBreakTagsIntoLineBreaks() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "first<br>second<BR/>third<br />"),
            [.paragraph("first\nsecond\nthird")]
        )
    }

    func testKeepsEveryOtherTagAsItIsWritten() {
        XCTAssertEqual(MarkdownDocument.blocks(from: "Press <kbd>⌘K</kbd>"), [.paragraph("Press <kbd>⌘K</kbd>")])
    }

    /// A review that names a tag is writing about it, and a code span is code: rewriting it left
    /// "Use `` and `\n` in bodies" on screen.
    func testLeavesTagsAndCommentsInsideCodeSpansAlone() {
        let source = "Use `<details>` and `<br>` in bodies, never `<!-- x -->`."
        XCTAssertEqual(MarkdownDocument.blocks(from: source), [.paragraph(source)])
        // Outside the span the same line still breaks.
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "`<br>` breaks<br>here"),
            [.paragraph("`<br>` breaks\nhere")]
        )
    }

    /// Only a line that is nothing but the markup unwraps; in a sentence the tag is prose.
    func testLeavesAMidLineDetailsTagInProseAlone() {
        let source = "Wrap the log in <details> so it folds."
        XCTAssertEqual(MarkdownDocument.blocks(from: source), [.paragraph(source)])
    }

    /// The other shape bots write: the opening tag and the summary on one line.
    func testUnwrapsDetailsAndSummaryWrittenOnOneLine() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "<details><summary>Full log</summary>\n\nok\n</details>"),
            [.paragraph("**Full log**"), .paragraph("ok")]
        )
    }

    // MARK: - CRLF (what github.com sends for anything typed there)

    func testACRLFParagraphStaysOneParagraph() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "one\r\ntwo\r\n\r\nthree"),
            [.paragraph("one\ntwo"), .paragraph("three")]
        )
    }

    func testACRLFFenceKeepsItsCodeExactly() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "```swift\r\nlet a = 1\r\n\r\nlet b = 2\r\n```"),
            [.codeBlock(code: "let a = 1\n\nlet b = 2", language: "swift")]
        )
    }

    func testCRLFListItemsAreItemsOfOneList() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "- one\r\n- two\r\n    - deeper"),
            [
                .listItem(text: "one", marker: "•", depth: 0),
                .listItem(text: "two", marker: "•", depth: 0),
                .listItem(text: "deeper", marker: "◦", depth: 1),
            ]
        )
    }

    // MARK: - Quoting

    func testAQuoteMarksEveryLineOfAnLFBody() {
        XCTAssertEqual(
            MarkdownDocument.quoted("Looks good.\nOne nit below."),
            "> Looks good.\n> One nit below."
        )
    }

    func testAQuoteKeepsEveryParagraphOfACRLFBodyInsideIt() {
        // What github.com sends for a comment typed there. Swift reads CRLF as one character, so
        // a split on "\n" alone quoted the first paragraph and sent the rest unquoted.
        XCTAssertEqual(
            MarkdownDocument.quoted("First paragraph.\r\n\r\nSecond paragraph,\r\nsecond line."),
            "> First paragraph.\n>\n> Second paragraph,\n> second line."
        )
    }

    func testAQuoteDropsTheTrailingLineBreak() {
        XCTAssertEqual(MarkdownDocument.quoted("Only line.\n"), "> Only line.")
        XCTAssertEqual(MarkdownDocument.quoted("Only line.\r\n"), "> Only line.")
    }

    /// A bot finds its own comment again by its `<!-- marker -->`; quoted, the marker would be in
    /// the reviewer's reply. A comment-only line leaves no bare `>` behind, and a comment inside a
    /// code span or a fence is code.
    func testAQuoteLeavesHTMLCommentsOut() {
        let body = """
        <!-- ccr-overview-v2 -->
        Looks good.<!-- inline -->
        <!-- one
        two -->
        See `<!-- kept -->`.

        ```html
        <!-- kept too -->
        ```
        """
        XCTAssertEqual(
            MarkdownDocument.quoted(body),
            "> Looks good.\n> See `<!-- kept -->`.\n>\n> ```html\n> <!-- kept too -->\n> ```"
        )
    }

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

    // MARK: - Tables

    /// schnaq/unlock#953: a light/dark grid of screenshots arrived as five lines of pipes.
    func testAGFMTableIsATableWithItsCellsStillInlineMarkdown() {
        let source = """
            Intro.

            | Light | Dark |
            | --- | :---: |
            | ![Feed light](https://a) | ![Feed dark](https://b) |
            | `a\\|b` | |

            Thumbnails are placeholders.
            """
        XCTAssertEqual(
            MarkdownDocument.blocks(from: source),
            [
                .paragraph("Intro."),
                .table(header: ["Light", "Dark"], rows: [
                    ["![Feed light](https://a)", "![Feed dark](https://b)"],
                    ["`a|b`", ""],
                ]),
                .paragraph("Thumbnails are placeholders."),
            ]
        )
    }

    /// Outer pipes are optional, a short row is padded and a long one cut to the header's width,
    /// and the table ends at the first line without a pipe even with no blank line before it.
    func testATableWithoutOuterPipesTakesItsWidthFromTheHeader() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "Screens:\na | b\n-|-\n1 |\n1 | 2 | 3\nAfter"),
            [
                .paragraph("Screens:"),
                .table(header: ["a", "b"], rows: [["1", ""], ["1", "2"]]),
                .paragraph("After"),
            ]
        )
    }

    /// A pipe in a sentence is not a table, and neither is a header whose delimiter row has another
    /// number of cells.
    func testPipesWithoutAMatchingDelimiterRowStayProse() {
        XCTAssertEqual(
            MarkdownDocument.blocks(from: "a | b\nnot | a | delimiter\n\n| a | b |\n| --- |"),
            [.paragraph("a | b\nnot | a | delimiter"), .paragraph("| a | b |\n| --- |")]
        )
    }
}
