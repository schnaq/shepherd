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
/// numbered lists with nesting, task items, fenced code, block quotes and thematic breaks.
public enum MarkdownDocument {
    /// Reads the blocks out of a Markdown body.
    /// - Parameter markdown: The source.
    /// - Returns: The blocks, in order. Empty for an empty or blank body.
    public static func blocks(from markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var fence: (language: String?, lines: [String])?
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
        func flushProse() {
            flushParagraph()
            flushQuote()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            // Inside a fence every line is literal until the closing fence, which is the whole
            // point of a fence: a `#` in a shell snippet is a comment and a `-` is a flag.
            if var open = fence {
                let fenceLine = rawLine.trimmingCharacters(in: .whitespaces)
                if fenceLine.hasPrefix("```") || fenceLine.hasPrefix("~~~") {
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

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushProse()
                let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                fence = (language: info.isEmpty ? nil : info, lines: [])
                continue
            }

            if trimmed.isEmpty {
                flushProse()
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

    // MARK: - HTML

    /// One line with the HTML GitHub renders and this parser would otherwise print taken care of:
    /// `<!-- comments -->` vanish (an unterminated one swallows the lines after it, as on GitHub),
    /// `<details>` unwraps, a `<summary>` becomes a bold line, and `<br>` breaks the line. Every
    /// other tag is left exactly as written — a `<kbd>` shown as text says more than one dropped.
    /// - Parameters:
    ///   - line: The line as written.
    ///   - isInComment: Whether an HTML comment is open, carried from line to line.
    /// - Returns: The line without that markup; the same string when it had none.
    private static func unwrappingHTML(in line: String, isInComment: inout Bool) -> String {
        var text = ""
        var rest = Substring(line)
        while !rest.isEmpty {
            if isInComment {
                guard let end = rest.range(of: "-->") else { break }
                rest = rest[end.upperBound...]
                isInComment = false
            } else if let start = rest.range(of: "<!--") {
                text += rest[..<start.lowerBound]
                rest = rest[start.upperBound...]
                isInComment = true
            } else {
                text += rest
                break
            }
        }
        guard text.contains("<") else { return text }

        if let summary = summaryPattern {
            let range = NSRange(text.startIndex..., in: text)
            for match in summary.matches(in: text, range: range).reversed() {
                guard let whole = Range(match.range, in: text),
                      let inner = Range(match.range(at: 1), in: text) else { continue }
                let label = text[inner].trimmingCharacters(in: .whitespaces)
                text.replaceSubrange(whole, with: label.isEmpty ? "" : "**\(label)**")
            }
        }
        for (pattern, replacement) in [(detailsPattern, ""), (breakPattern, "\n")] {
            guard let pattern else { continue }
            text = pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: replacement
            )
        }
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// `<summary>label</summary>` on one line; a lone opening or closing tag is caught by
    /// ``detailsPattern``.
    private static let summaryPattern = try? NSRegularExpression(
        pattern: "<summary>(.*?)</summary>",
        options: [.caseInsensitive]
    )

    /// `<details>`, `<details open>`, `</details>`, and a `<summary>` split over lines.
    private static let detailsPattern = try? NSRegularExpression(
        pattern: "</?(?:details|summary)(?:\\s[^>]*)?>",
        options: [.caseInsensitive]
    )

    /// `<br>`, `<br/>` and `<br />`.
    private static let breakPattern = try? NSRegularExpression(
        pattern: "<br\\s*/?>",
        options: [.caseInsensitive]
    )

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
