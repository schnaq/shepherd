import Foundation

/// One block of a Markdown body, in the order it was written.
///
/// Deliberately flat: a list is a run of ``listItem`` values carrying their own depth rather than
/// a tree of nested lists. A renderer that draws one row per item needs no more than that, and a
/// tree would buy structure nothing on screen depends on.
public enum MarkdownBlock: Equatable, Sendable {
    /// `# Heading` — level 1 to 6.
    case heading(level: Int, text: String)
    /// A run of prose. Line breaks inside it are the author's and are kept.
    case paragraph(String)
    /// One item of a list, with the glyph to draw in front of it and how deep it sits.
    case listItem(text: String, marker: String, depth: Int)
    /// A fenced code block, with its info string where there was one.
    case codeBlock(code: String, language: String?)
    /// A `>` quote, its lines joined.
    case quote(String)
    /// A thematic break.
    case rule
    /// A table: the header's cells and each row's, every row as wide as the header and every cell
    /// still inline Markdown.
    case table(header: [String], rows: [[String]])
}

/// Splits a Markdown body into blocks.
///
/// Why this exists at all: `AttributedString(markdown:)` handles *inline* Markdown — bold,
/// italics, code spans, links — and nothing above it. `.inlineOnlyPreservingWhitespace` is not a
/// setting that can be turned up, and the full syntax it offers instead flattens a document into
/// a single run with no way to ask which parts were headings. So a pull request body rendered
/// through it alone showed "## Summary" and "- **Trigger row**" as literal text, which is what
/// most agent-written descriptions are made of.
///
/// This parser answers only the block level and leaves every line's contents untouched, so the
/// inline parser still does the half it is good at. It is not a CommonMark implementation and
/// does not try to be: it covers what GitHub bodies actually contain — ATX headings, bullet and
/// numbered lists with nesting, task items, fenced code, block quotes, thematic breaks and tables.
public enum MarkdownDocument {
    /// Reads the blocks out of a Markdown body.
    /// - Parameter markdown: The source.
    /// - Returns: The blocks, in order. Empty for an empty or blank body.
    public static func blocks(from markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var fence: (language: String?, lines: [String])?
        var table: (header: [String], rows: [[String]])?
        var isInHTMLComment = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }
        func flushTable() {
            guard let open = table else { return }
            blocks.append(.table(header: open.header, rows: open.rows))
            table = nil
        }
        func flushProse() {
            flushParagraph()
            flushQuote()
            flushTable()
        }

        // Split on any line break rather than on `CharacterSet.newlines`: whatever was typed on
        // github.com arrives with CRLF, which Swift reads as *one* character and the character set
        // as two — so every line break became a paragraph break, and a fence gained a blank line
        // between every two lines of its code.
        for piece in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let rawLine = String(piece)
            // Inside a fence every line is literal until the closing fence, which is the whole
            // point of a fence: a `#` in a shell snippet is a comment and a `-` is a flag.
            if var open = fence {
                if isFence(rawLine) {
                    blocks.append(.codeBlock(code: open.lines.joined(separator: "\n"), language: open.language))
                    fence = nil
                } else {
                    open.lines.append(rawLine)
                    fence = open
                }
                continue
            }

            // Outside a fence, the few HTML shapes GitHub renders and bots write (ADR 0043). A line
            // that was markup and nothing else is skipped without ending the paragraph around it.
            let unwrapped = unwrappingHTML(in: rawLine, isInComment: &isInHTMLComment)
            let line = unwrapped.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, unwrapped != rawLine {
                continue
            }

            // A table runs to the first line without a pipe. GitHub would make a prose line right
            // after it one more row; here it is the paragraph it was most likely meant to be.
            if let open = table {
                if let cells = tableCells(trimmed) {
                    table?.rows.append(Array((cells + repeatElement("", count: open.header.count)).prefix(open.header.count)))
                    continue
                }
                flushTable()
            }

            if isFence(trimmed) {
                flushProse()
                let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                fence = (language: info.isEmpty ? nil : info, lines: [])
                continue
            }

            if trimmed.isEmpty {
                flushProse()
                continue
            }

            // A delimiter row turns the line before it into a table's header, so that line has
            // already gone into the paragraph by now. Checked before lists and rules, which a
            // delimiter row such as `- | -` would otherwise be read as.
            if let header = paragraph.last.flatMap(tableCells), isDelimiterRow(trimmed, columns: header.count) {
                paragraph.removeLast()
                flushProse()
                table = (header, [])
                continue
            }

            if isThematicBreak(trimmed) {
                flushProse()
                blocks.append(.rule)
                continue
            }

            if let heading = heading(in: trimmed) {
                flushProse()
                blocks.append(heading)
                continue
            }

            if let item = listItem(in: line) {
                flushProse()
                blocks.append(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var text = String(trimmed.dropFirst())
                if text.hasPrefix(" ") { text.removeFirst() }
                quote.append(text)
                continue
            }

            flushQuote()
            paragraph.append(trimmed)
        }

        if let open = fence {
            // An unclosed fence still has to render, and what follows it is code.
            blocks.append(.codeBlock(code: open.lines.joined(separator: "\n"), language: open.language))
        }
        flushProse()
        return blocks
    }

    /// A body as a Markdown quote: `> ` in front of every line and `>` on every blank one, so a
    /// quoted paragraph break stays inside the quote.
    ///
    /// What *Quote reply* puts into the comment field and what a delegation task quotes a review
    /// comment as. Split on any line break rather than on `"\n"`, for ``blocks(from:)``'s reason:
    /// a body typed on github.com arrives with CRLF, a split on `"\n"` alone found no line break in
    /// it at all, and only the first paragraph went out quoted.
    ///
    /// HTML comments are left out, by the rules ``blocks(from:)`` hides them by — outside code
    /// spans and fences — and a line that was a comment and nothing else goes with it rather than
    /// leaving a bare `>` behind. A bot's `<!-- marker -->` is how it finds its own comment again,
    /// and the reviewer's reply is not it.
    /// - Parameter markdown: The body as Markdown source.
    /// - Returns: The quote, without a trailing line break.
    public static func quoted(_ markdown: String) -> String {
        var lines: [String] = []
        var isInFence = false
        var isInComment = false
        for piece in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(piece)
            if isInFence {
                if isFence(line) { isInFence = false }
                lines.append(line)
                continue
            }
            let text = removingComments(from: line, isInComment: &isInComment) { $0 }
            if text != line, text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if isFence(text) { isInFence = true }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }

    /// Whether a line opens or closes a fenced code block.
    private static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    // MARK: - HTML

    /// One line with the HTML GitHub renders and this parser would otherwise print taken care of:
    /// `<!-- comments -->` vanish (``removingComments(from:isInComment:prose:)``), `<br>` breaks
    /// the line, and `<details>` and `<summary>` unwrap — the summary into a bold line — when they
    /// stand on a line of their own, which is how bots write them. Every other tag is left exactly
    /// as written — a `<kbd>` shown as text says more than one dropped.
    ///
    /// Nothing inside a code span is touched, and neither is a `<details>` in the middle of a
    /// sentence: a review that names the `<br>` tag in backticks is writing *about* the tag, and
    /// rewriting it left an empty pair of backticks where the tag's name had been.
    /// - Parameters:
    ///   - line: The line as written.
    ///   - isInComment: Whether an HTML comment is open, carried from line to line.
    /// - Returns: The line without that markup; the same string when it had none.
    private static func unwrappingHTML(in line: String, isInComment: inout Bool) -> String {
        guard isInComment || line.contains("<") else { return line }
        if !isInComment, let markup = wholeLineMarkup(line.trimmingCharacters(in: .whitespaces)) {
            return markup
        }
        return removingComments(from: line, isInComment: &isInComment, prose: lineBreak.applied(to:))
    }

    /// One line without its HTML comments, with `prose` applied to what is left outside code spans.
    ///
    /// A comment that ends on its own line vanishes wherever it stands. One that opens a line and
    /// does not end on it runs on to the line that ends it, as on GitHub — which is how a bot hides
    /// a block of its state. A `<!--` further along a line with no `-->` after it is prose: "Use
    /// <!-- to start a comment" is about the syntax, and read as an open comment it swallowed the
    /// rest of the body. Inside a code span nothing is a comment.
    /// - Parameters:
    ///   - line: The line as written.
    ///   - isInComment: Whether an HTML comment is open, carried from line to line.
    ///   - prose: What becomes of the text outside comments and code spans.
    /// - Returns: The line without its comments; the same string when it had none.
    private static func removingComments(
        from line: String,
        isInComment: inout Bool,
        prose: (String) -> String
    ) -> String {
        guard isInComment || line.contains("<") else { return line }
        var text = ""
        var rest = Substring(line)
        while !rest.isEmpty {
            if isInComment {
                // Inside a comment a backtick is comment text, not the start of code.
                guard let end = rest.range(of: "-->") else { break }
                rest = rest[end.upperBound...]
                isInComment = false
                continue
            }
            // Prose runs to whichever opens first: a comment, or a code span.
            let tick = rest.firstIndex(of: "`")
            if let open = rest.range(of: "<!--"), tick.map({ open.lowerBound < $0 }) ?? true {
                if let end = rest[open.upperBound...].range(of: "-->") {
                    text += prose(String(rest[..<open.lowerBound]))
                    rest = rest[end.upperBound...]
                } else if line[..<open.lowerBound].allSatisfy(\.isWhitespace) {
                    isInComment = true
                    break
                } else {
                    text += prose(String(rest[..<open.upperBound]))
                    rest = rest[open.upperBound...]
                }
            } else if let tick {
                text += prose(String(rest[..<tick]))
                // The span, backticks and all, as written; one left open runs to the line's end.
                let afterTick = rest.index(after: tick)
                let end = rest[afterTick...].firstIndex(of: "`").map { rest.index(after: $0) } ?? rest.endIndex
                text += rest[tick..<end]
                rest = rest[end...]
            } else {
                text += prose(String(rest))
                break
            }
        }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// What a line that is `<details>` or `<summary>` markup and nothing else becomes: nothing, or
    /// its summary as a bold line.
    ///
    /// The label is bold as a whole, so the emphasis tags bots put inside it go, and a `<code>`
    /// becomes the code span it is.
    /// - Parameter trimmed: The line, without its surrounding spaces.
    /// - Returns: The replacement, or `nil` when the line is more than that markup.
    private static func wholeLineMarkup(_ trimmed: String) -> String? {
        if lonelyTagLine.matches(trimmed) { return "" }
        guard let label = summaryLine.firstCapture(in: trimmed) else { return nil }
        let text = labelCode.applied(to: labelEmphasis.applied(to: label)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "" : "**\(text)**"
    }

    /// `<b>`, `<strong>`, `<i>` and `<em>`, opening or closing.
    private static let labelEmphasis = InlineRewrite(#"(?i)</?(?:b|strong|i|em)>"#, template: "")

    /// `<code>` and `</code>`, each the backtick it stands for.
    private static let labelCode = InlineRewrite(#"(?i)</?code>"#, template: "`")

    /// `<details>`, `<details open>`, `</details>`, and a `<summary>` or `</summary>` whose label
    /// is on the lines between them.
    private static let lonelyTagLine = ClaimPattern(#"^</?(?:details(?:\s[^>]*)?|summary)>$"#)

    /// `<summary>label</summary>`, with the `<details>` that opens it in front where a bot wrote
    /// both on one line.
    private static let summaryLine = ClaimPattern(#"^(?:<details(?:\s[^>]*)?>\s*)?<summary>(.*)</summary>$"#)

    /// `<br>`, `<br/>` and `<br />`.
    private static let lineBreak = InlineRewrite(#"(?i)<br\s*/?>"#, template: "\n")

    // MARK: - Line shapes

    /// `#` to `######` followed by a space. Seven hashes is a paragraph, and so is `#hashtag`.
    private static func heading(in trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    /// Three or more `-`, `*` or `_` and nothing else.
    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    /// A bullet, a number or a task box, with its indentation read as depth.
    ///
    /// The marker is resolved here rather than in the view so the glyph is part of what a test can
    /// assert: three bullet levels read `•`, `◦`, `▪`, a numbered item keeps its own number, and a
    /// task item becomes a box that says whether it is ticked.
    private static func listItem(in line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Two spaces is a nesting level in some editors, four in others, and a body written by an
        // agent uses whichever its generator preferred. Rounding to the nearest four-space step
        // reads both the same way — 2 and 4 are one level, 6 and 8 are two — and anything deeper
        // than three flattens rather than marching off the edge of the column.
        let depth = indent >= 2 ? min((indent + 2) / 4, 3) : 0

        var rest: Substring
        var marker: String

        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().hasPrefix(" ") {
            rest = trimmed.dropFirst(2)
            marker = ["•", "◦", "▪", "·"][depth]
        } else if let number = numberedPrefix(trimmed) {
            rest = trimmed.dropFirst(number.length)
            marker = "\(number.value)."
        } else {
            return nil
        }

        let text = rest.trimmingCharacters(in: .whitespaces)
        // `- [x] done` / `- [ ] open`: the box replaces the bullet, because a checklist whose
        // items keep their bullets *and* show a box reads as two lists interleaved.
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            return .listItem(text: String(text.dropFirst(4)), marker: "☑", depth: depth)
        }
        if text.hasPrefix("[ ] ") {
            return .listItem(text: String(text.dropFirst(4)), marker: "☐", depth: depth)
        }
        guard !text.isEmpty else { return nil }
        return .listItem(text: text, marker: marker, depth: depth)
    }

    /// A table row's cells, or `nil` for a line without a pipe.
    ///
    /// The outer pipes are optional and `\|` is a pipe inside a cell. A pipe inside a code span
    /// still splits, as on GitHub, which is why a table's code spans escape theirs.
    private static func tableCells(_ trimmed: String) -> [String]? {
        guard trimmed.contains("|") else { return nil }
        var row = Substring(trimmed)
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row = row.dropLast() }
        var cells = [""]
        for character in row {
            if character == "|", cells[cells.count - 1].hasSuffix("\\") {
                cells[cells.count - 1].removeLast()
                cells[cells.count - 1].append("|")
            } else if character == "|" {
                cells.append("")
            } else {
                cells[cells.count - 1].append(character)
            }
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `| --- | :---: |`, with as many cells as the header above it.
    private static func isDelimiterRow(_ trimmed: String, columns: Int) -> Bool {
        guard let cells = tableCells(trimmed), cells.count == columns else { return false }
        return cells.allSatisfy { cell in
            let dashes = cell.drop { $0 == ":" }.reversed().drop { $0 == ":" }
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
        }
    }

    /// `12. ` or `12) ` at the start of a line.
    private static func numberedPrefix(_ trimmed: String) -> (value: Int, length: Int)? {
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9, let value = Int(digits) else { return nil }
        let after = trimmed.dropFirst(digits.count)
        guard let separator = after.first, separator == "." || separator == ")" else { return nil }
        guard after.dropFirst().hasPrefix(" ") else { return nil }
        return (value, digits.count + 2)
    }
}
