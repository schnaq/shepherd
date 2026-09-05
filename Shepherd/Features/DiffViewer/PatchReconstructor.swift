import Foundation
import ShepherdCore

/// Rebuilds the two sides of a diff from GitHub's unified patch.
///
/// Monaco's diff editor wants two *documents*, but GitHub's `/pulls/{n}/files` endpoint only
/// returns the unified hunks — the file's untouched regions are never sent. Fetching whole
/// blobs for both sides would mean two extra API calls per file and would break offline
/// review (ADR 0006), so Shepherd reconstructs both sides from the patch instead:
///
/// - context lines (`" "`) go into **both** documents,
/// - `-` lines only into the original, `+` lines only into the modified,
/// - the gaps *between* hunks are filled with empty lines on **both** sides.
///
/// Filling the gaps is what keeps 1-based line numbers identical to GitHub's, which is a hard
/// requirement: review threads and draft comments are anchored by absolute line number, and an
/// off-by-N would attach a comment to the wrong line. Because the filler is identical on both
/// sides, Monaco treats it as unchanged and never highlights it.
enum PatchReconstructor {
    /// The two documents a diff editor needs.
    struct Reconstruction: Hashable, Sendable {
        /// The left-hand (base) document.
        var original: String
        /// The right-hand (head) document.
        var modified: String
        /// The 1-based line the first change lands on in the modified document, for scrolling.
        var firstChangedLine: Int?
        /// The lines of ``original`` that came from the patch rather than from the padding.
        ///
        /// Only these may carry a comment. The inter-hunk filler is indistinguishable from
        /// real content once it is in the document, and GitHub rejects the *whole* review —
        /// summary and every valid inline comment with it — when one `comments[].line` is not
        /// part of the diff.
        var commentableOriginalLines: Set<Int>
        /// The lines of ``modified`` that came from the patch rather than from the padding.
        var commentableModifiedLines: Set<Int>

        /// The commentable lines for one side of the diff.
        /// - Parameter side: Which document to ask about.
        func commentableLines(on side: DiffSide) -> Set<Int> {
            side == .left ? commentableOriginalLines : commentableModifiedLines
        }
    }

    /// One `@@ -a,b +c,d @@` hunk.
    struct Hunk: Hashable, Sendable {
        /// First line of the hunk in the original file (1-based; `0` for an empty side).
        var originalStart: Int
        /// First line of the hunk in the modified file (1-based; `0` for an empty side).
        var modifiedStart: Int
        /// The hunk's body lines, including their leading marker character.
        var lines: [String]
    }

    /// Reconstructs both sides of a changed file.
    /// - Parameter file: The changed file, whose ``ShepherdCore/ChangedFile/patch`` may be `nil`.
    /// - Returns: The two documents, or `nil` when GitHub sent no patch (binary or truncated).
    static func reconstruct(_ file: ChangedFile) -> Reconstruction? {
        guard let patch = file.patch, !patch.isEmpty else { return nil }
        return reconstruct(patch: patch)
    }

    /// Reconstructs both sides from raw unified-diff text.
    /// - Parameter patch: The patch, as GitHub returns it (starting at the first `@@`).
    /// - Returns: The two documents.
    static func reconstruct(patch: String) -> Reconstruction {
        var original: [String] = []
        var modified: [String] = []
        var firstChangedLine: Int?
        var commentableOriginal: Set<Int> = []
        var commentableModified: Set<Int> = []

        for hunk in hunks(in: patch) {
            while original.count < max(0, hunk.originalStart - 1) { original.append("") }
            while modified.count < max(0, hunk.modifiedStart - 1) { modified.append("") }

            for line in hunk.lines {
                guard let marker = line.first else {
                    // A completely empty line inside a hunk is an unchanged empty line.
                    original.append("")
                    modified.append("")
                    commentableOriginal.insert(original.count)
                    commentableModified.insert(modified.count)
                    continue
                }
                let content = String(line.dropFirst())
                switch marker {
                case "+":
                    modified.append(content)
                    commentableModified.insert(modified.count)
                    if firstChangedLine == nil { firstChangedLine = modified.count }
                case "-":
                    original.append(content)
                    commentableOriginal.insert(original.count)
                    if firstChangedLine == nil { firstChangedLine = max(1, modified.count + 1) }
                case "\\":
                    // "\ No newline at end of file" — metadata, not content.
                    continue
                default:
                    // " " is context; anything else is treated as context too, which is the
                    // safe failure mode: the line shows up unchanged on both sides.
                    original.append(content)
                    modified.append(content)
                    commentableOriginal.insert(original.count)
                    commentableModified.insert(modified.count)
                }
            }
        }

        return Reconstruction(
            original: original.joined(separator: "\n"),
            modified: modified.joined(separator: "\n"),
            firstChangedLine: firstChangedLine,
            commentableOriginalLines: commentableOriginal,
            commentableModifiedLines: commentableModified
        )
    }

    /// Splits a unified patch into hunks.
    /// - Parameter patch: The patch text.
    /// - Returns: The hunks, in order. Text before the first `@@` header is ignored.
    static func hunks(in patch: String) -> [Hunk] {
        var result: [Hunk] = []
        var current: Hunk?

        var rawLines = patch.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // The empty component after a terminating newline is not a line. Neither producer this
        // app has emits one — GitHub's `files[].patch` ends without a newline, and the
        // interdiff's synthesized patch is `joined(separator:)` — but a patch from anywhere else
        // does (`git diff` for one), and the cost of the difference is not cosmetic: an empty
        // component falls into the "unchanged empty line" branch below, so it would be appended
        // to *both* documents and inserted into *both* commentable sets. A reviewer could then
        // put a comment on a line that is not in the diff, which GitHub refuses — taking the
        // whole review with it. `UnifiedPatch.hunks(in:)` in ShepherdCore has always dropped it;
        // this is the same rule, so the two readings of a patch agree.
        if rawLines.last == "" { rawLines.removeLast() }

        for rawLine in rawLines {
            if rawLine.hasPrefix("@@") {
                if let current { result.append(current) }
                current = header(rawLine).map {
                    Hunk(originalStart: $0.originalStart, modifiedStart: $0.modifiedStart, lines: [])
                }
                continue
            }
            // Only `@@` is structural. GitHub's `files[].patch` starts at the first hunk
            // header and never carries `diff --git` / `index` / `---` / `+++` lines, so
            // filtering for them here only ever eats real content: a deleted `-- SQL comment`
            // serialises as `--- SQL comment`, and dropping it shifts every following
            // original-side line number by one. Anything before the first `@@` is ignored
            // anyway, because `current` is still nil.
            current?.lines.append(rawLine)
        }
        if let current { result.append(current) }
        return result
    }

    /// Parses an `@@ -a,b +c,d @@ section` header.
    /// - Parameter line: The header line.
    /// - Returns: The two start line numbers, or `nil` when the header is malformed.
    static func header(_ line: String) -> (originalStart: Int, modifiedStart: Int)? {
        // Take everything between the first "@@" and the closing "@@".
        guard line.hasPrefix("@@") else { return nil }
        let afterFirst = line.dropFirst(2)
        guard let closing = afterFirst.range(of: "@@") else { return nil }
        let ranges = afterFirst[afterFirst.startIndex..<closing.lowerBound]
            .split(separator: " ", omittingEmptySubsequences: true)
        var originalStart: Int?
        var modifiedStart: Int?
        for range in ranges {
            guard let sign = range.first, sign == "-" || sign == "+" else { continue }
            let numbers = range.dropFirst().split(separator: ",")
            guard let first = numbers.first, let start = Int(first) else { continue }
            if sign == "-" {
                originalStart = start
            } else {
                modifiedStart = start
            }
        }
        guard let originalStart, let modifiedStart else { return nil }
        return (originalStart, modifiedStart)
    }
}
