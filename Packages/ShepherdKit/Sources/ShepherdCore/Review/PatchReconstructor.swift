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
///
/// A native list needs the opposite of two documents: it has to announce each line as it draws
/// it — added, removed or context, and which number it carries on each side. Those facts are
/// known during the walk anyway, so ``Reconstruction/rows`` keeps them instead of discarding
/// them. One walk answers both questions, which is the point: a second walk is a second reading
/// of the same patch, and two readings that disagree are a bug waiting for the input that tells
/// them apart.
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
        /// The diff as a walkable sequence of hunk headers and lines.
        public var rows: [DiffRow]

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

    /// One entry of ``Reconstruction/rows``.
    ///
    /// It is nested here beside ``Reconstruction`` because it means nothing on its own: a row is
    /// a row *of a reconstruction*, numbered by the same walk, and reading it as
    /// `PatchReconstructor.DiffRow` says so at every use site. ``PatchRow`` is the type that had
    /// to move out, because a patch line is a patch line whoever walked it.
    public enum DiffRow: Hashable, Sendable {
        /// A hunk's `@@` header, carrying the line each side starts at.
        case hunk(originalStart: Int, modifiedStart: Int)
        /// One line of the patch.
        case line(PatchRow)
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
        // Every row below reads its line numbers off `original.count` and `modified.count` —
        // the same two counts that fill the commentable-line sets beside it — rather than off a
        // pair of counters kept for the rows alone. A row's number and the set it must belong
        // to are then literally the same variable, and cannot drift apart. A pair of counters
        // that are supposed to agree is precisely the shape of the bug fixed on this branch
        // last week, where a trailing newline made two copies of `hunks(in:)` disagree about
        // the end of a file; what a drift would cost here is a row offering a comment on a line
        // the sets do not contain, and GitHub refuses such a comment along with the whole
        // review.
        var rows: [DiffRow] = []

        for hunk in UnifiedPatch.hunks(in: patch) {
            while original.count < max(0, hunk.originalStart - 1) { original.append("") }
            while modified.count < max(0, hunk.modifiedStart - 1) { modified.append("") }
            // The inter-hunk padding above produces no rows: a list shows the hunks with a
            // header between them, which is what the header row is for.
            rows.append(.hunk(originalStart: hunk.originalStart, modifiedStart: hunk.modifiedStart))

            for line in hunk.lines {
                guard let marker = line.first else {
                    // A completely empty line inside a hunk is an unchanged empty line.
                    original.append("")
                    modified.append("")
                    commentableOriginal.insert(original.count)
                    commentableModified.insert(modified.count)
                    rows.append(
                        .line(
                            PatchRow(
                                kind: .context,
                                text: "",
                                baseLine: original.count,
                                headLine: modified.count
                            )
                        )
                    )
                    continue
                }
                let content = String(line.dropFirst())
                switch marker {
                case "+":
                    modified.append(content)
                    commentableModified.insert(modified.count)
                    if firstChangedLine == nil { firstChangedLine = modified.count }
                    // The base side has no line for an addition, so it names the base line the
                    // addition sits in front of.
                    rows.append(
                        .line(
                            PatchRow(
                                kind: .added,
                                text: content,
                                baseLine: original.count + 1,
                                headLine: modified.count
                            )
                        )
                    )
                case "-":
                    original.append(content)
                    commentableOriginal.insert(original.count)
                    if firstChangedLine == nil { firstChangedLine = max(1, modified.count + 1) }
                    // Mirror image: the deleted line has no head-side number, so it names the
                    // head line the deletion sits in front of.
                    rows.append(
                        .line(
                            PatchRow(
                                kind: .removed,
                                text: content,
                                baseLine: original.count,
                                headLine: modified.count + 1
                            )
                        )
                    )
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
                    rows.append(
                        .line(
                            PatchRow(
                                kind: .context,
                                text: content,
                                baseLine: original.count,
                                headLine: modified.count
                            )
                        )
                    )
                }
            }
        }

        return Reconstruction(
            original: original.joined(separator: "\n"),
            modified: modified.joined(separator: "\n"),
            firstChangedLine: firstChangedLine,
            commentableOriginalLines: commentableOriginal,
            commentableModifiedLines: commentableModified,
            rows: rows
        )
    }
}
