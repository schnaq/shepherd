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

        for hunk in hunks(in: patch) {
            while original.count < max(0, hunk.originalStart - 1) { original.append("") }
            while modified.count < max(0, hunk.modifiedStart - 1) { modified.append("") }

            for line in hunk.lines {
                guard let marker = line.first else {
                    // A completely empty line inside a hunk is an unchanged empty line.
                    original.append("")
                    modified.append("")
                    continue
                }
                let content = String(line.dropFirst())
                switch marker {
                case "+":
                    modified.append(content)
                    if firstChangedLine == nil { firstChangedLine = modified.count }
                case "-":
                    original.append(content)
                    if firstChangedLine == nil { firstChangedLine = max(1, modified.count + 1) }
                case "\\":
                    // "\ No newline at end of file" — metadata, not content.
                    continue
                default:
                    // " " is context; anything else is treated as context too, which is the
                    // safe failure mode: the line shows up unchanged on both sides.
                    original.append(content)
                    modified.append(content)
                }
            }
        }

        return Reconstruction(
            original: original.joined(separator: "\n"),
            modified: modified.joined(separator: "\n"),
            firstChangedLine: firstChangedLine
        )
    }

    /// Splits a unified patch into hunks.
    /// - Parameter patch: The patch text.
    /// - Returns: The hunks, in order. Text before the first `@@` header is ignored.
    static func hunks(in patch: String) -> [Hunk] {
        var result: [Hunk] = []
        var current: Hunk?

        for rawLine in patch.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if rawLine.hasPrefix("@@") {
                if let current { result.append(current) }
                current = header(rawLine).map {
                    Hunk(originalStart: $0.originalStart, modifiedStart: $0.modifiedStart, lines: [])
                }
                continue
            }
            if rawLine.hasPrefix("diff --git") || rawLine.hasPrefix("index ")
                || rawLine.hasPrefix("--- ") || rawLine.hasPrefix("+++ ") {
                continue
            }
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
