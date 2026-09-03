import Foundation

/// Cuts a budgeted window out of a unified diff, around a line or around its first hunk.
///
/// This is what the `fileDiff` tool answers with (`docs/plans/apple-intelligence-v2.md` §0.3/§3.F):
/// a CI log names a file and a line, and the model needs the lines *there* — not the file, and not
/// the whole patch, which for a 4,000-line diff would spend the tier's entire context on one read.
///
/// It lives in `ShepherdCore`, pure and Linux-tested, for the reason the rest of the tool contract
/// does: the windowing arithmetic is the part that can be wrong in a way nobody notices (a
/// window centred one line off still looks plausible), and it must be checkable without a Mac.
/// The app target's `InlineCommentDraftBuilder` cuts a *marked-up* window for a different question
/// — "what should I say about the line I clicked" — and keeps its `>> ` markers and its anchor
/// semantics; this one keeps the diff exactly as GitHub wrote it, because a model reads unified
/// diff natively and every character spent on decoration is a character not spent on code.
///
/// Line numbers are tracked the way GitHub's own `comments[].line` is: the head (right-hand) side
/// for added and context lines, which is the side a compiler or a test runner names in a log.
public enum IntelligenceDiffWindow {
    /// How many diff lines are kept on either side of the line the window is centred on.
    ///
    /// The same 24 the inline-comment excerpt uses, and for the same reason: it is roughly a
    /// screenful, which is the amount of context a person needs to judge a line — and a model
    /// given much more starts explaining the neighbourhood instead of the failure.
    public static let defaultContextLines = 24

    /// A window into a patch.
    public struct Window: Sendable, Hashable {
        /// The window's text: a synthesised `@@` header, then the diff lines verbatim.
        ///
        /// Empty when the patch is empty or holds no hunk — GitHub sends no patch for binaries
        /// and for diffs it truncated, and a caller must say so rather than send nothing.
        public var text: String
        /// How many diff lines the window holds, hunk headers not counted.
        public var lineCount: Int
        /// The head-side line the window is centred on, when one was asked for and found.
        ///
        /// `nil` covers both "no line was asked for" and "that line is not in this patch" — the
        /// window then starts at the first hunk, which is the honest answer to "show me this
        /// file" and keeps a model that misread a log from getting nothing at all.
        public var centredOnLine: Int?
        /// Whether the patch has more in it than the window shows.
        public var wasTruncated: Bool

        /// Creates a window.
        /// - Parameters:
        ///   - text: The window text.
        ///   - lineCount: How many diff lines it holds.
        ///   - centredOnLine: The head-side line it is centred on, if any.
        ///   - wasTruncated: Whether anything was left out.
        public init(
            text: String,
            lineCount: Int,
            centredOnLine: Int? = nil,
            wasTruncated: Bool = false
        ) {
            self.text = text
            self.lineCount = lineCount
            self.centredOnLine = centredOnLine
            self.wasTruncated = wasTruncated
        }

        /// Whether there is any diff to show at all.
        public var isEmpty: Bool { text.isEmpty }

        /// The empty window, for a file GitHub sent no patch for.
        public static let empty = Window(text: "", lineCount: 0)
    }

    /// Cuts the window.
    ///
    /// The order is deliberate and is the same order the inline excerpt uses: pick the window in
    /// *diff lines* first, then shrink it to the character budget from its edges inwards, with the
    /// centre line the last thing surrendered. Picking by characters first would make the window
    /// around a line of dense JSON three lines tall and the window around a line of prose forty,
    /// for the same question.
    /// - Parameters:
    ///   - patch: The file's unified diff, as GitHub returns it (starting at the first `@@`).
    ///   - line: The head-side line to centre on, or `nil` to start at the first hunk.
    ///   - contextLines: How many lines to keep on either side. Defaults to
    ///     ``defaultContextLines``.
    ///   - characterLimit: The most characters the window may use. Zero or less yields the empty
    ///     window rather than a negative-sized one.
    /// - Returns: The window.
    public static func window(
        patch: String,
        aroundLine line: Int? = nil,
        contextLines: Int = defaultContextLines,
        characterLimit: Int
    ) -> Window {
        guard characterLimit > 0, !patch.isEmpty else { return .empty }
        let rows = self.rows(in: patch)
        guard !rows.isEmpty else { return .empty }

        let centre = line.flatMap { wanted in
            rows.firstIndex { $0.headLine == wanted && $0.isHeadSide }
        }
        let context = max(0, contextLines)
        var start = 0
        var end = rows.count - 1
        if let centre {
            start = max(0, centre - context)
            end = min(rows.count - 1, centre + context)
        } else {
            // No line to centre on: the head of the patch, bounded the same way, so "show me
            // this file" costs the same as "show me this line".
            end = min(rows.count - 1, 2 * context)
        }
        var truncated = start > 0 || end < rows.count - 1

        // The centre is the answer to the question, so it is the last row to go; with no centre
        // the first kept row plays that part, which is what makes this terminate either way.
        let keep = centre ?? start
        func size(_ from: Int, _ through: Int) -> Int {
            (from...through).reduce(0) { $0 + rows[$1].text.count + 1 }
        }
        while size(start, end) > characterLimit, start < keep || end > keep {
            if end > keep {
                end -= 1
            } else {
                start += 1
            }
            truncated = true
        }

        let body = rows[start...end]
        var pieces = body.map(\.text)
        if !rows[start].isHeader {
            // The window starts mid-hunk, so it gets a header of its own; a window that starts
            // *on* a header already has one and must not be given a second.
            pieces.insert(header(before: rows[start]), at: 0)
        }
        var text = pieces.joined(separator: "\n")
        if text.count > characterLimit {
            // One row longer than the whole budget — a minified bundle on a single line. Cut it
            // rather than hand a caller a window it cannot afford to send.
            text = String(text.prefix(characterLimit))
            truncated = true
        }
        return Window(
            text: text,
            lineCount: body.filter { !$0.isHeader }.count,
            centredOnLine: centre.map { rows[$0].headLine },
            wasTruncated: truncated
        )
    }

    // MARK: - Rows

    /// One line of a patch, with the line numbers it sits at on both sides.
    private struct Row {
        /// The diff line, marker character included, or a hunk header.
        var text: String
        /// The base-side line number this row sits at (or would sit at, for an addition).
        var baseLine: Int
        /// The head-side line number this row sits at (or would sit at, for a deletion).
        var headLine: Int
        /// Whether this row *exists* on the head side — an addition or a context line.
        ///
        /// The distinction is what keeps a deletion from being mistaken for the head-side line it
        /// happens to sit in front of: a `-` row's ``headLine`` is the next head line, which
        /// would otherwise match a search for it.
        var isHeadSide: Bool
        /// Whether this row is the hunk's own `@@` header.
        var isHeader: Bool
    }

    /// The header put in front of a window, so absolute line numbers stay derivable.
    ///
    /// A window that starts mid-hunk would otherwise be a page of `+`/`-`/` ` lines with no
    /// anchor in the file at all, and the one thing a diagnosis has to get right is *where*.
    /// - Parameter row: The window's first row.
    /// - Returns: The row's own header when it is one, a synthesised header otherwise.
    private static func header(before row: Row) -> String {
        row.isHeader ? row.text : "@@ -\(row.baseLine) +\(row.headLine) @@"
    }

    /// Walks a patch into rows, tracking both sides' line numbers.
    ///
    /// The arithmetic is the app target's `PatchReconstructor`'s, deliberately: that is the
    /// numbering GitHub's review API speaks, so a line named here is the line a reviewer sees.
    /// Anything before the first `@@` is ignored, and `\ No newline at end of file` is metadata
    /// rather than a line.
    /// - Parameter patch: The patch text.
    /// - Returns: The rows, in order.
    private static func rows(in patch: String) -> [Row] {
        var rows: [Row] = []
        var baseLine = 0
        var headLine = 0
        var insideHunk = false

        var lines = patch
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        // A unified diff ends with a newline, and the empty component after it is not a line of
        // anything: left in, it would put a blank row at the end of every window and count as
        // one, so a five-line patch would report six.
        if lines.last == "" { lines.removeLast() }

        for rawLine in lines {
            if rawLine.hasPrefix("@@") {
                guard let start = header(rawLine) else {
                    insideHunk = false
                    continue
                }
                baseLine = start.baseStart
                headLine = start.headStart
                insideHunk = true
                rows.append(
                    Row(
                        text: "@@ -\(start.baseStart) +\(start.headStart) @@",
                        baseLine: baseLine,
                        headLine: headLine,
                        isHeadSide: false,
                        isHeader: true
                    )
                )
                continue
            }
            guard insideHunk else { continue }
            let marker = rawLine.first
            if marker == "\\" { continue }
            let row = Row(
                text: rawLine,
                baseLine: baseLine,
                headLine: headLine,
                isHeadSide: marker != "-",
                isHeader: false
            )
            rows.append(row)
            switch marker {
            case "+":
                headLine += 1
            case "-":
                baseLine += 1
            default:
                // " " is context, and so is anything else — the same safe failure mode the
                // reconstructor picks, because a mis-typed line that shifts both counters by one
                // is a smaller error than one that shifts only one of them.
                baseLine += 1
                headLine += 1
            }
        }
        return rows
    }

    /// Parses an `@@ -a,b +c,d @@ section` header.
    /// - Parameter line: The header line.
    /// - Returns: The two start line numbers, or `nil` when the header is malformed.
    private static func header(_ line: String) -> (baseStart: Int, headStart: Int)? {
        guard line.hasPrefix("@@") else { return nil }
        let afterFirst = line.dropFirst(2)
        guard let closing = afterFirst.range(of: "@@") else { return nil }
        let ranges = afterFirst[afterFirst.startIndex..<closing.lowerBound]
            .split(separator: " ", omittingEmptySubsequences: true)
        var baseStart: Int?
        var headStart: Int?
        for range in ranges {
            guard let sign = range.first, sign == "-" || sign == "+" else { continue }
            let numbers = range.dropFirst().split(separator: ",")
            guard let first = numbers.first, let start = Int(first) else { continue }
            if sign == "-" {
                baseStart = start
            } else {
                headStart = start
            }
        }
        guard let baseStart, let headStart else { return nil }
        return (baseStart, headStart)
    }
}
