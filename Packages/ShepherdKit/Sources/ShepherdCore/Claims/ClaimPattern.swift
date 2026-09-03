import Foundation

/// A compiled regular expression, cached in a `static let` and shared across threads.
///
/// Three decisions are packed into this small type, and all three are about the two places this
/// code has to work: a Mac under Swift 6's strict concurrency, and a Linux CI runner.
///
/// - **`NSRegularExpression` rather than Swift Regex.** It is the one engine with identical
///   behaviour in `swift-corelibs-foundation` and on Darwin, and the claim patterns are the kind
///   of thing that must not match differently depending on which runner read the pull request.
/// - **Compiled once, in a static, and never mutated.** `NSRegularExpression` is immutable and
///   documented as thread-safe, which is what `@unchecked Sendable` asserts here — the alternative
///   (recompiling a pattern per sentence) would compile the same twelve patterns for every line of
///   every description.
/// - **A pattern that does not compile matches nothing.** Every pattern in this module is a
///   literal written in this repository, so `try?` can only fail if somebody edits one into
///   nonsense; failing to *find* a claim is the honest degradation, and a crash in a card that
///   opens on every pull request would not be.
struct ClaimPattern: @unchecked Sendable {
    /// The compiled expression, or `nil` when the pattern did not compile.
    private let regex: NSRegularExpression?

    /// Compiles a pattern.
    /// - Parameters:
    ///   - pattern: The ICU regular expression.
    ///   - caseInsensitive: Whether to match without regard to case. Claim prose is written by
    ///     people and by agents, in sentence case, in title case and in shouting caps, so this is
    ///     on by default.
    init(_ pattern: String, caseInsensitive: Bool = true) {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        regex = try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// Whether the pattern matches anywhere in `text`.
    /// - Parameter text: The text to search.
    func matches(_ text: String) -> Bool {
        firstRange(in: text) != nil
    }

    /// The range of the first match.
    /// - Parameter text: The text to search.
    /// - Returns: The range, or `nil` when there is no match.
    func firstRange(in text: String) -> Range<String.Index>? {
        guard let regex, !text.isEmpty else { return nil }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: whole) else { return nil }
        return Range<String.Index>(match.range, in: text)
    }

    /// The first match's capture group.
    /// - Parameters:
    ///   - group: The capture-group index. `1` is the first parenthesised group.
    ///   - text: The text to search.
    /// - Returns: The captured substring, or `nil` when there is no match or the group did not
    ///   participate in it.
    func firstCapture(_ group: Int = 1, in text: String) -> String? {
        guard let regex, !text.isEmpty else { return nil }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: whole) else { return nil }
        return capture(group, of: match, in: text)
    }

    /// Every match's capture group, in the order they occur.
    /// - Parameters:
    ///   - group: The capture-group index.
    ///   - text: The text to search.
    /// - Returns: One string per match that carried the group.
    func captures(_ group: Int = 1, in text: String) -> [String] {
        guard let regex, !text.isEmpty else { return [] }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: whole).compactMap { match in
            capture(group, of: match, in: text)
        }
    }

    private func capture(
        _ group: Int,
        of match: NSTextCheckingResult,
        in text: String
    ) -> String? {
        guard group < match.numberOfRanges,
              let range = Range<String.Index>(match.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }
}

/// Cutting a Markdown pull-request description into the sentences a claim can be quoted from.
///
/// Claims are **sentence-scoped** on purpose: "no tests, only a docs change" and "tests added,
/// only a docs change" differ by one word, and a pattern let loose on a whole description would
/// find both halves of the first sentence in two different paragraphs of the second. So the
/// extractor never sees the body — it sees a list of sentences, each of which is also the quote
/// the card shows, which is why the stripping below removes Markdown decoration rather than
/// rewriting prose.
enum ClaimText {
    /// Every sentence of a Markdown body, in reading order.
    ///
    /// A *line* is the outer unit — a bullet, a table row and a checklist item are each one
    /// thought, and joining them into a paragraph would let a claim's verb come from the bullet
    /// below it. Inside a line, a sentence ends at `.`, `!`, `?` or `;` **followed by whitespace
    /// or the end of the line**, so `1.2` and `v2.0.1` are not two sentences.
    /// - Parameter text: The Markdown source.
    /// - Returns: The sentences, decoration stripped and trimmed, empty ones dropped.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        for rawLine in lines(of: text) {
            let line = stripped(rawLine)
            guard !line.isEmpty else { continue }
            result.append(contentsOf: split(line))
        }
        return result
    }

    /// The description's first paragraph — the block a bare `#42` counts as an issue reference in.
    ///
    /// Leading blank lines and leading headings are skipped before the block is taken, because
    /// nearly every agent-written description opens with `## Summary` and a paragraph that was
    /// only ever a heading would make the bare-reference rule unreachable.
    /// - Parameter text: The Markdown source.
    /// - Returns: The first block of consecutive non-blank, non-heading lines.
    static func firstParagraph(of text: String) -> String {
        let all = lines(of: text)
        var index = 0
        while index < all.count {
            let trimmed = all[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || isHeading(trimmed) else { break }
            index += 1
        }
        var block: [String] = []
        while index < all.count, !all[index].trimmingCharacters(in: .whitespaces).isEmpty {
            block.append(all[index])
            index += 1
        }
        return block.joined(separator: "\n")
    }

    /// One line's text with its Markdown list, heading, quote and checkbox markers removed.
    ///
    /// Applied repeatedly, because `- [x] ` is three markers in a row. Only markers that are
    /// followed by whitespace are removed, so `well-known` keeps its hyphen and `#42` is not
    /// mistaken for a heading.
    /// - Parameter line: The raw line.
    /// - Returns: The line's prose, trimmed.
    static func stripped(_ line: String) -> String {
        var rest = Substring(line)
        var didStrip = true
        while didStrip {
            didStrip = false
            while let first = rest.first, first == " " || first == "\t" {
                rest = rest.dropFirst()
            }
            if let after = afterHeadingMarker(rest) {
                rest = after
                didStrip = true
                continue
            }
            if rest.first == ">" {
                rest = rest.dropFirst()
                didStrip = true
                continue
            }
            if let after = afterBulletMarker(rest) {
                rest = after
                didStrip = true
                continue
            }
            if let after = afterOrderedMarker(rest) {
                rest = after
                didStrip = true
                continue
            }
            if let after = afterCheckboxMarker(rest) {
                rest = after
                didStrip = true
                continue
            }
        }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Pieces

    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func isHeading(_ trimmed: String) -> Bool {
        afterHeadingMarker(Substring(trimmed)) != nil
    }

    /// `## ` … `###### `, hashes plus at least one space.
    private static func afterHeadingMarker(_ rest: Substring) -> Substring? {
        var probe = rest
        var hashes = 0
        while probe.first == "#", hashes < 6 {
            probe = probe.dropFirst()
            hashes += 1
        }
        guard hashes > 0, let next = probe.first, next == " " || next == "\t" else { return nil }
        return probe
    }

    /// `- `, `* `, `+ `.
    private static func afterBulletMarker(_ rest: Substring) -> Substring? {
        guard let first = rest.first, first == "-" || first == "*" || first == "+" else {
            return nil
        }
        let probe = rest.dropFirst()
        guard let next = probe.first, next == " " || next == "\t" else { return nil }
        return probe
    }

    /// `1. `, `2) `.
    private static func afterOrderedMarker(_ rest: Substring) -> Substring? {
        guard let first = rest.first, first.isNumber else { return nil }
        var probe = rest
        while let digit = probe.first, digit.isNumber {
            probe = probe.dropFirst()
        }
        guard let marker = probe.first, marker == "." || marker == ")" else { return nil }
        let after = probe.dropFirst()
        guard let next = after.first, next == " " || next == "\t" else { return nil }
        return after
    }

    /// `[ ] `, `[x] `, `[X] `.
    private static func afterCheckboxMarker(_ rest: Substring) -> Substring? {
        guard rest.first == "[" else { return nil }
        let box = rest.dropFirst()
        guard let mark = box.first, mark == " " || mark == "x" || mark == "X" else { return nil }
        let closing = box.dropFirst()
        guard closing.first == "]" else { return nil }
        let after = closing.dropFirst()
        guard let next = after.first, next == " " || next == "\t" else { return nil }
        return after
    }

    /// Splits one line into sentences at `.`, `!`, `?` and `;` before whitespace or the end.
    private static func split(_ line: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            current.append(character)
            let next = line.index(after: index)
            if character == "." || character == "!" || character == "?" || character == ";" {
                let endsHere = next == line.endIndex || line[next].isWhitespace
                if endsHere {
                    let piece = current.trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { pieces.append(piece) }
                    current = ""
                }
            }
            index = next
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}

/// One line of a unified diff with the line numbers it sits at on both sides.
///
/// Only the head-side number is used for a link (that is the number GitHub's review API and the
/// diff viewer both speak), but the base-side one is tracked because a deletion advances only one
/// of the two counters — getting that wrong shifts every line after the first hunk.
struct PatchRow: Sendable, Hashable {
    /// Which side of the diff a row exists on.
    enum Kind: Sendable, Hashable {
        /// A `+` row: it exists only after the change.
        case added
        /// A `-` row: it existed only before the change.
        case removed
        /// A context row: unchanged, present on both sides.
        case context
    }

    /// Whether the row was added, removed or is context.
    var kind: Kind
    /// The row's text with the diff marker removed.
    var text: String
    /// The base-side line the row sits at, or would sit at.
    var baseLine: Int
    /// The head-side line the row sits at, or would sit at.
    ///
    /// For a removed row this is the head line the deletion sits *in front of* — the line a
    /// reviewer following a link lands on, because the deleted line itself has no head-side
    /// number of its own.
    var headLine: Int
}

/// Walks a unified diff into rows, tracking both sides' line numbers.
///
/// The arithmetic is ``IntelligenceDiffWindow``'s, deliberately: that is the numbering GitHub's
/// review API speaks, so a line named by an evidence fact is the line the reviewer sees. It is a
/// second, small walker rather than a call into that type because the window's own `Row` is
/// private to it and answers a different question (what *text* is around a line) — this one
/// answers "which rows changed, and where", and a shared type would have to serve both.
enum PatchWalker {
    /// Walks a patch.
    /// - Parameter patch: The unified diff as GitHub returns it, starting at the first `@@`.
    /// - Returns: The rows, in order. Anything before the first `@@` is ignored, and
    ///   `\ No newline at end of file` is metadata rather than a line.
    static func rows(in patch: String) -> [PatchRow] {
        var rows: [PatchRow] = []
        var baseLine = 0
        var headLine = 0
        var insideHunk = false

        var lines = patch
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        // A unified diff ends with a newline; the empty component after it is not a line.
        if lines.last == "" { lines.removeLast() }

        for rawLine in lines {
            if rawLine.hasPrefix("@@") {
                guard let start = hunkStart(rawLine) else {
                    insideHunk = false
                    continue
                }
                baseLine = start.base
                headLine = start.head
                insideHunk = true
                continue
            }
            guard insideHunk else { continue }
            let marker = rawLine.first
            if marker == "\\" { continue }
            let body = rawLine.isEmpty ? "" : String(rawLine.dropFirst())
            switch marker {
            case "+":
                rows.append(
                    PatchRow(kind: .added, text: body, baseLine: baseLine, headLine: headLine)
                )
                headLine += 1
            case "-":
                rows.append(
                    PatchRow(kind: .removed, text: body, baseLine: baseLine, headLine: headLine)
                )
                baseLine += 1
            default:
                // " " is context, and so is anything else — the same safe failure mode the
                // window walker picks, because a mis-typed line that shifts both counters by one
                // is a smaller error than one that shifts only one of them.
                rows.append(
                    PatchRow(kind: .context, text: body, baseLine: baseLine, headLine: headLine)
                )
                baseLine += 1
                headLine += 1
            }
        }
        return rows
    }

    /// Parses an `@@ -a,b +c,d @@ section` header.
    /// - Parameter line: The header line.
    /// - Returns: The two start line numbers, or `nil` when the header is malformed.
    static func hunkStart(_ line: String) -> (base: Int, head: Int)? {
        guard line.hasPrefix("@@") else { return nil }
        let afterFirst = line.dropFirst(2)
        guard let closing = afterFirst.range(of: "@@") else { return nil }
        let ranges = afterFirst[afterFirst.startIndex..<closing.lowerBound]
            .split(separator: " ", omittingEmptySubsequences: true)
        var base: Int?
        var head: Int?
        for range in ranges {
            guard let sign = range.first, sign == "-" || sign == "+" else { continue }
            let numbers = range.dropFirst().split(separator: ",")
            guard let first = numbers.first, let start = Int(first) else { continue }
            if sign == "-" {
                base = start
            } else {
                head = start
            }
        }
        guard let base, let head else { return nil }
        return (base, head)
    }
}
