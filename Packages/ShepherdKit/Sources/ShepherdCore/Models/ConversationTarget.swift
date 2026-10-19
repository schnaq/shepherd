import Foundation

/// A post of the conversation the viewer wrote and may change (ADR 0043).
///
/// Addressed by the **numeric REST database id**, not the GraphQL node id a reaction uses: the
/// edit and delete endpoints take it in their path. The pull request's description needs none,
/// because the pull request itself is the row's target.
public enum ConversationTarget: Sendable, Codable, Hashable {
    /// The pull request's description. Editable, never deletable.
    case description
    /// A comment on the conversation.
    case issueComment(databaseID: Int)
    /// An inline comment on the diff.
    case reviewComment(databaseID: Int)
    /// A submitted review's body. Editable, never deletable: GitHub only dismisses a review.
    case review(databaseID: Int)

    /// Whether GitHub has a delete for this kind of post — only the two comment kinds do.
    public var isDeletable: Bool {
        switch self {
        case .issueComment, .reviewComment: return true
        case .description, .review: return false
        }
    }
}
