import Foundation
import ShepherdCore

/// The file a ``DiffListView`` is showing: the walkable rows, and the two sets that decide which
/// of them may carry a comment.
///
/// The same shape as ``DiffViewerContent`` and for the same reason — a renderer is handed a value
/// rather than reaching into the model — with one difference that matters. The sets are `Set<Int>`
/// here and sorted arrays there, because the bridge's JSON is defined in terms of arrays and a
/// list asks `contains` once per drawn row. They are the *same* sets: `ReviewModel`'s
/// `commentableLineSets(in:)` is where both come from, which is the first item of the contract in
/// `docs/plans/accessible-diff.md`. A padding line the reconstruction inserted between hunks is
/// unclickable in both renderers, because GitHub rejects a comment on one and rejects the whole
/// review along with it.
struct DiffListContent: Hashable, Sendable {
    /// The repository-relative path.
    var path: String
    /// The diff as hunk headers and lines, in reading order.
    var rows: [PatchReconstructor.DiffRow]
    /// Commentable base-side lines, already narrowed for the round being shown.
    var commentableLeft: Set<Int>
    /// Commentable head-side lines, already narrowed for the round being shown.
    var commentableRight: Set<Int>

    /// Which of the two numbers a row carries are the row's *own*.
    ///
    /// ``ShepherdCore/PatchRow`` fills both in on every row, and on a changed row one of them
    /// belongs to a different line: an added row's ``ShepherdCore/PatchRow/baseLine`` names the
    /// base line it sits *in front of*, and a removed row's ``ShepherdCore/PatchRow/headLine``
    /// the head line the deletion sits in front of. Both are useful facts about a *neighbour*,
    /// and neither is this row's number.
    ///
    /// Everything downstream is a reading of this one value: ``identity`` anchors a comment and
    /// names the line out loud, and ``DiffListView`` fills its two gutter columns from ``base``
    /// and ``head``. So the number a row shows, the number it announces and the number a comment
    /// on it lands on cannot come apart — which matters most in the last of the three, because a
    /// comment on a line outside the diff is one GitHub refuses along with the entire review.
    enum LineNumbers: Hashable, Sendable {
        /// An added row: it exists on the head side only, where it now is.
        case headOnly(Int)
        /// A removed row: it existed on the base side only, where it used to be.
        case baseOnly(Int)
        /// A context row: unchanged, so it is the same line on both sides and owns both numbers.
        case both(base: Int, head: Int)

        /// The row's own base-side number, or `nil` when it has none.
        var base: Int? {
            switch self {
            case .headOnly: return nil
            case .baseOnly(let line): return line
            case .both(let line, _): return line
            }
        }

        /// The row's own head-side number, or `nil` when it has none.
        var head: Int? {
            switch self {
            case .headOnly(let line): return line
            case .baseOnly: return nil
            case .both(_, let line): return line
            }
        }

        /// The one side the row *is*, and its number there.
        ///
        /// The head side whenever the row has a head-side number of its own: an added row is the
        /// line it now exists at, and a context row is read as the file as it will be, which is
        /// the document a review is written against. A removed row is the only row without one,
        /// and the base side is where it is.
        var identity: (side: DiffSide, line: Int) {
            switch self {
            case .headOnly(let line): return (.right, line)
            case .baseOnly(let line): return (.left, line)
            case .both(_, let head): return (.right, head)
            }
        }
    }

    /// Which of a row's two numbers are its own.
    ///
    /// The one switch. The rule is short and every case of it is load-bearing:
    ///
    /// | row | base | head |
    /// | --- | --- | --- |
    /// | added | none — it did not exist before | the line it now is |
    /// | removed | the line it used to be | none — it no longer exists |
    /// | context | the line it was | the line it still is |
    /// - Parameter row: The line.
    /// - Returns: The numbers it owns.
    static func lineNumbers(of row: PatchRow) -> LineNumbers {
        switch row.kind {
        case .added: return .headOnly(row.headLine)
        case .removed: return .baseOnly(row.baseLine)
        case .context: return .both(base: row.baseLine, head: row.headLine)
        }
    }

    /// Which side's line number a row *is*, before asking whether it may carry a comment.
    ///
    /// Kept as its own name because it is what a *comment* is anchored with and what the spoken
    /// sentence names the line by, and both read better for asking that question rather than for
    /// the pair; the answer itself comes from ``lineNumbers(of:)``, so there is still one switch
    /// deciding which of a row's two numbers belongs to it.
    /// - Parameter row: The line.
    /// - Returns: The side it lives on and its number there.
    static func lineIdentity(of row: PatchRow) -> (side: DiffSide, line: Int) {
        lineNumbers(of: row).identity
    }

    /// Where a comment on a row would be anchored, or `nil` when the row takes none.
    /// - Parameter row: The row the cursor is on.
    /// - Returns: The anchor, or `nil` for a hunk header and for a line this round does not
    ///   accept a comment on.
    func anchor(for row: PatchReconstructor.DiffRow) -> (side: DiffSide, line: Int)? {
        guard case .line(let patchRow) = row else { return nil }
        let identity = Self.lineIdentity(of: patchRow)
        let commentable = identity.side == .left ? commentableLeft : commentableRight
        return commentable.contains(identity.line) ? identity : nil
    }
}
