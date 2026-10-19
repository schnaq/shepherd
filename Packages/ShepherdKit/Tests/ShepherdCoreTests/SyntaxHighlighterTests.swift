import XCTest

@testable import ShepherdCore

/// The line tokenizer behind the native diff's colours (ADR 0044).
///
/// Each case is an edge where a naive tokenizer colours the rest of a line — or, with multi-line
/// state, the rest of a hunk — inside-out: an apostrophe that is prose, a `#` that is not a
/// comment, a closer that looks like an opener. Spans are compared as `kind:text` strings so a
/// failure prints what the tokenizer actually saw.
final class SyntaxHighlighterTests: XCTestCase {
    /// The line's spans as `kind:text`, tokenized from `state`.
    private func spans(_ line: String, _ language: SourceLanguage, _ state: SyntaxState = .normal) -> [String] {
        var state = state
        let bytes = Array(line.utf8)
        return SyntaxHighlighter.tokenize(line, language: language, state: &state).map {
            "\($0.kind):\(String(decoding: bytes[$0.range], as: UTF8.self))"
        }
    }

    /// The state left after tokenizing `lines` in order.
    private func endState(_ lines: [String], _ language: SourceLanguage) -> SyntaxState {
        var state = SyntaxState.normal
        for line in lines { _ = SyntaxHighlighter.tokenize(line, language: language, state: &state) }
        return state
    }

    // MARK: Swift

    func testSwiftInterpolationWithNestedStringsStaysOneString() {
        let line = #"let s = "\(cond ? "a" : "b") ok" // done"#
        let result = spans(line, .swift)
        XCTAssertEqual(result.first, "keyword:let")
        XCTAssertEqual(result.last, "comment:// done", "the trailing comment survives the interpolation")
        // Adjacent runs of one kind merge, so the inner `"b"` and the resumed `) ok"` are one span.
        XCTAssertEqual(result[result.count - 2], #"string:"b") ok""#, "the string resumes after the interpolation")
        XCTAssertFalse(result.contains { $0.hasPrefix("comment:") && $0 != "comment:// done" }, "\(result)")
    }

    func testAnUnclosedCommentInsideAnInterpolationStopsAtItsBracket() {
        var state = SyntaxState.normal
        let line = #"let s = "\(a /* )" + b"#
        let raw = SyntaxHighlighter.tokenize(line, language: .swift, state: &state)
        XCTAssertEqual(state, .normal)
        XCTAssertTrue(zip(raw, raw.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound }, "\(raw)")
        XCTAssertTrue(spans(line, .swift).contains("comment:/* "), "\(spans(line, .swift))")
    }

    func testSwiftDeclaration() {
        XCTAssertEqual(
            spans("@MainActor final class Foo: Bar {", .swift),
            ["annotation:@MainActor", "keyword:final", "keyword:class", "type:Foo", "type:Bar"])
        XCTAssertEqual(spans("#if DEBUG", .swift).first, "keyword:#if")
    }

    func testSwiftMultiLineConstructsClose() {
        XCTAssertEqual(endState(["let x = \"\"\"", "  it's \"quoted\"", "  \"\"\""], .swift), .normal)
        XCTAssertEqual(endState(["/* a /* nested */ still", "*/ x"], .swift), .normal)
        XCTAssertEqual(endState(["/* a /* nested */ still"], .swift), .blockComment(depth: 1))
    }

    // MARK: Non-ASCII

    func testUmlautsAndEmojiAreNeverCut() {
        let line = #"String(localized: "Öffnen 🎉 für \(name)") // Überschrift"#
        let result = spans(line, .swift)
        XCTAssertFalse(result.contains { $0.contains("\u{FFFD}") }, "\(result)")
        XCTAssertEqual(result.last, "comment:// Überschrift")
        XCTAssertEqual(spans("let größe = 1", .swift), ["keyword:let", "literal:1"])
    }

    // MARK: Other languages

    func testRustLifetimeIsNotAStringButACharIsALiteral() {
        let result = spans("fn f<'a>(x: &'a str) -> char { 'x' }", .rust)
        XCTAssertFalse(result.contains { $0.hasPrefix("string:") }, "\(result)")
        XCTAssertTrue(result.contains("literal:'x'"), "\(result)")
        XCTAssertEqual(spans("#[derive(Debug)] struct A;", .rust).first, "annotation:#[derive(Debug)]")
    }

    func testYAMLApostrophesAndHashes() {
        XCTAssertEqual(
            spans("description: don't panic # really", .yaml), ["property:description", "comment:# really"])
        XCTAssertEqual(spans("url: http://x/#anchor", .yaml), ["property:url"])
        XCTAssertEqual(spans("  - name: \"x\"", .yaml), ["keyword:-", "property:name", "string:\"x\""])
        XCTAssertEqual(spans("enabled: true", .yaml).last, "literal:true")
    }

    func testShellDollarHashIsNotAComment() {
        XCTAssertEqual(spans("echo $# ${#arr[@]} # c", .shell).last, "comment:# c")
        XCTAssertTrue(spans(#"echo "home: $HOME""#, .shell).contains("property:$HOME"))
    }

    func testMarkdownApostrophesAreProse() {
        XCTAssertEqual(spans("It's a `code` span, isn't it", .markdown), ["string:`code`"])
        XCTAssertEqual(spans("## Heading", .markdown).first, "keyword:## Heading")
        XCTAssertEqual(endState(["```swift", "let x = 1"], .markdown), .fence)
        XCTAssertEqual(endState(["```swift", "let x = 1", "```"], .markdown), .normal)
    }

    func testClojureForms() {
        let result = spans(#"(defn greet [^String name] (str "hi " name :done \a 42)) ; note"#, .clojure)
        XCTAssertTrue(result.contains("keyword:defn"), "\(result)")
        XCTAssertTrue(result.contains("property::done"), "\(result)")
        XCTAssertTrue(result.contains(#"literal:\a"#), "\(result)")
        XCTAssertTrue(result.contains("annotation:^String"), "\(result)")
        XCTAssertEqual(result.last, "comment:; note")
        // `'` quotes a form in Clojure; it never opens a string.
        XCTAssertFalse(spans("(swap! state update-in ['a :b] inc)", .clojure).contains { $0.hasPrefix("string:") })
    }

    func testTypeScriptTemplateLiterals() {
        XCTAssertEqual(spans("const s = `a ${b + \"}\"} c`; // x", .typescript).last, "comment:// x")
        XCTAssertEqual(endState(["const s = `multi", "line`"], .typescript), .normal)
        XCTAssertEqual(endState(["const s = `multi"], .typescript), .string(quote: UInt8(ascii: "`"), triple: false))
    }

    func testGoPythonAndJSON() {
        XCTAssertEqual(spans("func (s *Server) Run() error {", .go), ["keyword:func", "type:error"])
        XCTAssertEqual(spans("@dataclass", .python).first, "annotation:@dataclass")
        XCTAssertEqual(endState(["x = '''", "doc", "'''"], .python), .normal)
        XCTAssertEqual(
            spans(#"  "key": "value", "n": 1.5e3"#, .json),
            [#"property:"key""#, #"string:"value""#, #"property:"n""#, "literal:1.5e3"])
        // `?` is not an identifier byte, so Ruby's `defined?` is scanned, and listed, as `defined`.
        XCTAssertEqual(spans("defined?(x)", .ruby), ["keyword:defined"])
    }

    func testPlainTextAndOverlongLinesGetNoSpans() {
        XCTAssertEqual(spans("let x = 1", .plaintext), [])
        var state = SyntaxState.blockComment(depth: 1)
        let minified = String(repeating: "a", count: SyntaxHighlighter.maxLineBytes + 1)
        XCTAssertEqual(SyntaxHighlighter.tokenize(minified, language: .javascript, state: &state), [])
    }

    // MARK: Hunk start

    func testAHunkCutInsideABlockComment() {
        XCTAssertEqual(
            SyntaxHighlighter.initialState(forHunk: [" * more text */", "let x = 1"], language: .swift),
            .blockComment(depth: 1))
        // A `*/` inside a string (here a regex) is not a closer.
        XCTAssertEqual(
            SyntaxHighlighter.initialState(forHunk: [##"let re = #"<br\s*/?>"#"##, "x"], language: .swift), .normal)
        // Nor inside a single-quoted string, in a language where those are strings.
        XCTAssertEqual(
            SyntaxHighlighter.initialState(
                forHunk: ["function a() {", "  const x = 1", "  testMatch: ['**/*.test.ts'],"], language: .typescript),
            .normal)
    }

    func testAHunkCutInsideATripleQuotedString() {
        let quote = UInt8(ascii: "\"")
        // Text after `"""` means only a closer can stand there.
        XCTAssertEqual(
            SyntaxHighlighter.initialState(forHunk: ["  SELECT 1", "  \"\"\")"], language: .swift),
            .string(quote: quote, triple: true))
        XCTAssertEqual(SyntaxHighlighter.initialState(forHunk: ["let q = \"\"\""], language: .swift), .normal)
        // A bare `"""` opens after an expression head, and closes otherwise.
        XCTAssertEqual(
            SyntaxHighlighter.initialState(
                forHunk: ["XCTAssertEqual(", "    parse(", "        \"\"\""], language: .swift),
            .normal)
        XCTAssertEqual(
            SyntaxHighlighter.initialState(forHunk: ["    SELECT 1", "    \"\"\""], language: .swift),
            .string(quote: quote, triple: true))
    }
}
