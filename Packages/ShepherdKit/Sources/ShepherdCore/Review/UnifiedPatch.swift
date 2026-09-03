import Foundation

/// Reading and writing unified diffs, as pure text (ADR 0028).
///
/// The app target already reconstructs both sides of a patch for the Monaco viewer
/// (`Shepherd/Features/DiffViewer/PatchReconstructor.swift`); that type stays where it is,
/// because it also produces the viewer's commentable-line sets and is tested against the
/// bridge. What the interdiff needs is smaller and has to run on Linux: the *head* side of a
/// patch as an array of lines, and a way to write a synthesized patch back out so the viewer
/// can render it through the same `loadFile` path.
///
/// Both halves follow the same rule as the app-side reconstructor, and the rule is
/// load-bearing: **line numbers are absolute**. GitHub only sends the hunks, so the gaps
/// between them are padded with empty lines, which keeps a 1-based line number in this array
/// equal to the same line number in GitHub's diff — the number review threads and draft
/// comments are anchored by. Padding is indistinguishable from a genuinely empty line, which
/// is why nothing here claims to know a file's real content: two rounds of the *same* pull
/// request are compared with each other, and a region neither round patched is padding on
/// both sides and therefore identical.
public enum UnifiedPatch {
    /// One `@@ -a,b +c,d @@` hunk of a patch.
    public struct Hunk: Sendable, Hashable {
        /// First line of the hunk in the base file (1-based; `0` for an empty side).
        public var originalStart: Int
        /// First line of the hunk in the head file (1-based; `0` for an empty side).
        public var modifiedStart: Int
        /// The hunk's body lines, including their leading marker character.
        public var lines: [String]

        /// Creates a hunk.
        /// - Parameters:
        ///   - originalStart: First base-side line.
        ///   - modifiedStart: First head-side line.
        ///   - lines: Body lines with their markers.
        public init(originalStart: Int, modifiedStart: Int, lines: [String]) {
            self.originalStart = originalStart
            self.modifiedStart = modifiedStart
            self.lines = lines
        }
    }

    /// Rebuilds the head side of a unified patch, one array element per line.
    ///
    /// Context lines and `+` lines are kept, `-` lines are dropped, and the gaps between hunks
    /// are padded with empty strings so that the index of a line plus one is its line number in
    /// GitHub's diff.
    /// - Parameter patch: The patch as GitHub returns it (starting at the first `@@`), or `nil`
    ///   for a binary or truncated diff.
    /// - Returns: The head-side lines. Empty when there is no patch to read.
    public static func reconstruct(after patch: String?) -> [String] {
        guard let patch, !patch.isEmpty else { return [] }
        var modified: [String] = []
        for hunk in hunks(in: patch) {
            while modified.count < max(0, hunk.modifiedStart - 1) { modified.append("") }
            for line in hunk.lines {
                guard let marker = line.first else {
                    // A completely empty line inside a hunk is an unchanged empty line.
                    modified.append("")
                    continue
                }
                switch marker {
                case "+":
                    modified.append(String(line.dropFirst()))
                case "-":
                    continue
                case "\\":
                    // "\ No newline at end of file" — metadata, not content.
                    continue
                default:
                    // " " is context; anything else is treated as context too, which is the
                    // safe failure mode: the line shows up on both sides.
                    modified.append(String(line.dropFirst()))
                }
            }
        }
        return modified
    }

    /// Splits a unified patch into hunks.
    ///
    /// Only `@@` is structural: GitHub's `files[].patch` starts at the first hunk header and
    /// never carries `diff --git` / `index` / `---` / `+++` lines, so filtering for those here
    /// would only ever eat real content (a deleted `-- SQL comment` serialises as
    /// `--- SQL comment`).
    /// - Parameter patch: The patch text.
    /// - Returns: The hunks, in order. Anything before the first `@@` is ignored.
    public static func hunks(in patch: String) -> [Hunk] {
        var result: [Hunk] = []
        var current: Hunk?
        let normalised = patch.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalised.components(separatedBy: "\n") {
            if rawLine.hasPrefix("@@") {
                if let current { result.append(current) }
                current = header(rawLine).map {
                    Hunk(originalStart: $0.originalStart, modifiedStart: $0.modifiedStart, lines: [])
                }
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
    public static func header(_ line: String) -> (originalStart: Int, modifiedStart: Int)? {
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

    /// Writes a `@@ -a,b +c,d @@` header.
    /// - Parameters:
    ///   - originalStart: First base-side line (`0` when the base side is empty).
    ///   - originalCount: How many base-side lines the hunk covers.
    ///   - modifiedStart: First head-side line (`0` when the head side is empty).
    ///   - modifiedCount: How many head-side lines the hunk covers.
    /// - Returns: The header line, without a trailing newline.
    public static func writeHeader(
        originalStart: Int,
        originalCount: Int,
        modifiedStart: Int,
        modifiedCount: Int
    ) -> String {
        "@@ -\(originalStart),\(originalCount) +\(modifiedStart),\(modifiedCount) @@"
    }
}
