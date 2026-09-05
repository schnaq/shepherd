import Foundation

/// One line of a unified diff with the line numbers it sits at on both sides.
///
/// This is the shared per-line model for anything in this package that walks a patch — it began
/// as the claims layer's own row type and is no longer claims-specific. `PatchWalker` names the
/// line an evidence fact points at with it, and ``PatchReconstructor/DiffRow`` carries it so a
/// native list can render a diff row by row instead of handing two whole documents to a diff
/// editor that computes the difference itself.
///
/// Both numbers are tracked, not just the one a given caller reads: a deletion advances only one
/// of the two counters, and getting that wrong shifts every line after the first hunk.
public struct PatchRow: Sendable, Hashable {
    /// Which side of the diff a row exists on.
    public enum Kind: Sendable, Hashable {
        /// A `+` row: it exists only after the change.
        case added
        /// A `-` row: it existed only before the change.
        case removed
        /// A context row: unchanged, present on both sides.
        case context
    }

    /// Whether the row was added, removed or is context.
    public var kind: Kind
    /// The row's text with the diff marker removed.
    public var text: String
    /// The base-side line the row sits at, or would sit at.
    public var baseLine: Int
    /// The head-side line the row sits at, or would sit at.
    ///
    /// For a removed row this is the head line the deletion sits *in front of* — the line a
    /// reviewer following a link lands on, because the deleted line itself has no head-side
    /// number of its own.
    public var headLine: Int

    /// Creates a row.
    ///
    /// Unlike ``PatchReconstructor/Reconstruction`` this is a plain value with nothing to hold
    /// together — the same reason ``UnifiedPatch/Hunk`` has a public initialiser — so a caller
    /// outside the walk may make one.
    /// - Parameters:
    ///   - kind: Added, removed or context.
    ///   - text: The line's text without its marker.
    ///   - baseLine: The base-side line.
    ///   - headLine: The head-side line.
    public init(kind: Kind, text: String, baseLine: Int, headLine: Int) {
        self.kind = kind
        self.text = text
        self.baseLine = baseLine
        self.headLine = headLine
    }
}
