import Foundation

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
public enum PatchReconstructor {
    /// The two documents a diff editor needs.
    public struct Reconstruction: Hashable, Sendable {
        /// The left-hand (base) document.
        public var original: String
        /// The right-hand (head) document.
        public var modified: String
        /// The 1-based line the first change lands on in the modified document, for scrolling.
        public var firstChangedLine: Int?
        /// The lines of ``original`` that came from the patch rather than from the padding.
        ///
        /// Only these may carry a comment. The inter-hunk filler is indistinguishable from
        /// real content once it is in the document, and GitHub rejects the *whole* review —
        /// summary and every valid inline comment with it — when one `comments[].line` is not
        /// part of the diff.
        public var commentableOriginalLines: Set<Int>
        /// The lines of ``modified`` that came from the patch rather than from the padding.
        public var commentableModifiedLines: Set<Int>

        // Deliberately no `public` initialiser. The two commentable-line sets are derived from
        // the same walk that built the two documents, so a ``Reconstruction`` whose fields were
        // supplied separately could claim a line is commentable that the documents do not
        // contain — and a comment on a line that is not in the diff is one GitHub refuses along
        // with the whole review. ``UnifiedPatch/Hunk`` has a public initialiser because it is a
        // plain value with nothing to hold together; this type is only ever correct when
        // ``reconstruct(patch:)`` makes it.

        /// The commentable lines for one side of the diff.
        /// - Parameter side: Which document to ask about.
        public func commentableLines(on side: DiffSide) -> Set<Int> {
            side == .left ? commentableOriginalLines : commentableModifiedLines
        }
    }

    /// Reconstructs both sides of a changed file.
    /// - Parameter file: The changed file, whose ``ShepherdCore/ChangedFile/patch`` may be `nil`.
    /// - Returns: The two documents, or `nil` when GitHub sent no patch (binary or truncated).
    public static func reconstruct(_ file: ChangedFile) -> Reconstruction? {
        guard let patch = file.patch, !patch.isEmpty else { return nil }
        return reconstruct(patch: patch)
    }

    /// Reconstructs both sides from raw unified-diff text.
    /// - Parameter patch: The patch, as GitHub returns it (starting at the first `@@`).
    /// - Returns: The two documents.
    public static func reconstruct(patch: String) -> Reconstruction {
        var original: [String] = []
        var modified: [String] = []
        var firstChangedLine: Int?
        var commentableOriginal: Set<Int> = []
        var commentableModified: Set<Int> = []

        for hunk in UnifiedPatch.hunks(in: patch) {
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
}
