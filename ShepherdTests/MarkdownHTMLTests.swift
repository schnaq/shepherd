import XCTest

@testable import Shepherd

/// The `bodyHTML` sanitisation contract: the webview renders this with `innerHTML`, so the
/// converter must never emit markup it did not build itself.
final class MarkdownHTMLTests: XCTestCase {
    func testEverythingIsEscapedBeforeAnyTagIsEmitted() {
        let html = MarkdownHTML.render("<script>alert('x')</script>")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testRawHTMLNeverPassesThrough() {
        let html = MarkdownHTML.render("<img src=x onerror=alert(1)>")
        // The tag survives only as escaped text, which the browser renders, never executes.
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
    }

    func testParagraphsAndLineBreaks() {
        let html = MarkdownHTML.render("first line\nsecond line\n\nnew paragraph")
        XCTAssertEqual(html, "<p>first line<br>second line</p><p>new paragraph</p>")
    }

    func testCodeSpansAndFences() {
        XCTAssertEqual(
            MarkdownHTML.render("use `let x = 1` here"),
            "<p>use <code>let x = 1</code> here</p>"
        )
        let fenced = MarkdownHTML.render("```swift\nlet a = 1 < 2\n```")
        XCTAssertEqual(fenced, "<pre><code>let a = 1 &lt; 2</code></pre>")
    }

    func testEmphasisInsideCodeSpansIsLeftAlone() {
        let html = MarkdownHTML.render("`a * b * c`")
        XCTAssertEqual(html, "<p><code>a * b * c</code></p>")
    }

    func testBoldAndItalic() {
        XCTAssertEqual(MarkdownHTML.render("**bold**"), "<p><strong>bold</strong></p>")
        XCTAssertEqual(MarkdownHTML.render("*italic*"), "<p><em>italic</em></p>")
        XCTAssertEqual(MarkdownHTML.render("_italic_"), "<p><em>italic</em></p>")
    }

    func testHttpsLinksOnly() {
        XCTAssertEqual(
            MarkdownHTML.render("[docs](https://example.com/a)"),
            "<p><a href=\"https://example.com/a\">docs</a></p>"
        )
        let javascript = MarkdownHTML.render("[bad](javascript:alert(1))")
        XCTAssertFalse(javascript.contains("<a "))
        let insecure = MarkdownHTML.render("[bad](http://example.com)")
        XCTAssertFalse(insecure.contains("<a "))
        let data = MarkdownHTML.render("[bad](data:text/html;base64,PHN2Zz4=)")
        XCTAssertFalse(data.contains("<a "))
    }

    func testListsAndQuotesAndHeadings() {
        XCTAssertEqual(
            MarkdownHTML.render("- one\n- two"),
            "<ul><li>one</li><li>two</li></ul>"
        )
        XCTAssertEqual(
            MarkdownHTML.render("> quoted"),
            "<blockquote><p>quoted</p></blockquote>"
        )
        XCTAssertEqual(
            MarkdownHTML.render("## Heading"),
            "<p><strong>Heading</strong></p>"
        )
    }

    func testAmpersandsInsideLinkTargetsStayEscaped() {
        let html = MarkdownHTML.render("[q](https://example.com/?a=1&b=2)")
        XCTAssertTrue(html.contains("href=\"https://example.com/?a=1&amp;b=2\""))
    }

    func testUnterminatedMarkersDegradeToText() {
        XCTAssertEqual(MarkdownHTML.render("a * b"), "<p>a * b</p>")
        XCTAssertEqual(MarkdownHTML.render("unclosed `code"), "<p>unclosed `code</p>")
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertEqual(MarkdownHTML.render(""), "")
        XCTAssertEqual(MarkdownHTML.render("\n\n"), "")
    }
}
