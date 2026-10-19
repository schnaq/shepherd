/// Which lines of a native diff one multi-line comment may span (ADR 0044).
///
/// GitHub anchors a multi-line review comment with `start_line` and `line` on one `side`, and
/// refuses it — together with the entire review it was submitted in — unless every line between
/// the two lies in one hunk of the pull request's diff. `ReviewModel.validateAnchor(of:)` checks
/// only the two endpoints, which is enough for the rich viewer, where Monaco's selection cannot
/// leave a hunk by accident. A touch list can: two taps are two rows anywhere in the file. So the
/// span rule lives here, once, as a pure function the phone's diff asks before it offers a range.
///
/// The rule, each part load-bearing:
///
/// - **One hunk.** No hunk header between the two rows; a header is where the patch skips lines
///   the diff does not contain.
/// - **One side.** Both rows *are* lines on the same side. Rows of the other side in between are
///   fine — a head-side range over a block of removed lines is an ordinary comment on the new code.
/// - **Every line between is commentable.** Not only the endpoints: in "Since your review" one
///   interdiff hunk can cover two of the pull request's hunks, and the narrowed commentable set is
///   what says where the pull request's own diff has a gap. A row on the range's side that the set
///   refuses ends the range there.
///
/// Which side a row is, and which lines take a comment, are the app's answers
/// (`DiffListContent.lineIdentity(of:)` and its commentable sets) and are passed in rather than
/// restated, so the rule that anchors a single-line comment and the rule that bounds a range
/// cannot come apart.
public enum DiffLineRange {
    /// A comment's anchor: GitHub's `side`, `start_line` and `line`.
    public struct Span: Sendable, Hashable {
        /// The side both lines are on.
        public var side: DiffSide
        /// The first line, or `nil` when the span is one line — GitHub's single-line shape.
        public var startLine: Int?
        /// The last line.
        public var line: Int

        /// Creates a span.
        public init(side: DiffSide, startLine: Int?, line: Int) {
            self.side = side
            self.startLine = startLine
            self.line = line
        }
    }

    /// The window of row indices a range starting at `anchor` may reach, or `nil` when the anchor
    /// row takes no comment at all.
    ///
    /// Walked outwards from the anchor until a hunk header, the end of the rows, or a row on the
    /// anchor's side that is not commentable. Cheap enough to ask once per draw, which is how the
    /// phone dims the rows a second tap would be refused on.
    /// - Parameters:
    ///   - rows: The file's rows, as the reconstruction returns them.
    ///   - anchor: The index of the first row picked.
    ///   - identity: Which side a row is, and its line there.
    ///   - isCommentable: Whether a line on a side takes a comment in the round being shown.
    /// - Returns: The reachable indices, the anchor included.
    public static func window(
        in rows: [PatchReconstructor.DiffRow],
        around anchor: Int,
        identity: (PatchRow) -> (side: DiffSide, line: Int),
        isCommentable: (DiffSide, Int) -> Bool
    ) -> ClosedRange<Int>? {
        guard rows.indices.contains(anchor), case .line(let row) = rows[anchor] else { return nil }
        let side = identity(row).side
        func reachable(_ index: Int) -> Bool {
            guard case .line(let row) = rows[index] else { return false }
            let own = identity(row)
            return own.side != side || isCommentable(own.side, own.line)
        }
        guard reachable(anchor), isCommentable(side, identity(row).line) else { return nil }
        var lower = anchor
        while lower > rows.startIndex, reachable(lower - 1) { lower -= 1 }
        var upper = anchor
        while upper < rows.endIndex - 1, reachable(upper + 1) { upper += 1 }
        return lower...upper
    }

    /// The comment anchor two picked rows describe, in either order, or `nil` when no single
    /// comment can span them.
    /// - Parameters:
    ///   - rows: The file's rows.
    ///   - first: The row picked first.
    ///   - second: The row picked second; the same row gives a single-line span.
    ///   - identity: Which side a row is, and its line there.
    ///   - isCommentable: Whether a line on a side takes a comment in the round being shown.
    /// - Returns: The span, with `startLine` below `line`, or `nil`.
    public static func span(
        in rows: [PatchReconstructor.DiffRow],
        from first: Int,
        to second: Int,
        identity: (PatchRow) -> (side: DiffSide, line: Int),
        isCommentable: (DiffSide, Int) -> Bool
    ) -> Span? {
        guard let window = window(in: rows, around: first, identity: identity, isCommentable: isCommentable),
            window.contains(second),
            case .line(let a) = rows[first], case .line(let b) = rows[second]
        else { return nil }
        let start = identity(a), end = identity(b)
        guard start.side == end.side else { return nil }
        let lines = min(start.line, end.line), last = max(start.line, end.line)
        return Span(side: start.side, startLine: lines == last ? nil : lines, line: last)
    }
}
