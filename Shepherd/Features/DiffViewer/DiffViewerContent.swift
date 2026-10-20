import Foundation

/// The file a ``DiffViewerView`` is showing.
struct DiffViewerContent: Hashable, Sendable {
    /// The repository-relative path (also the viewer's model key).
    var path: String
    /// A Monaco language id.
    var language: String
    /// The left-hand document.
    var original: String
    /// The right-hand document.
    var modified: String
    /// Which lines came from the patch, and may therefore carry a comment.
    var commentableLines: BridgeCommentableLines?
}
