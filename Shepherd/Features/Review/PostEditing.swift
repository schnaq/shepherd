import ShepherdCore

/// What the viewer may change about one post, and where the change is sent (ADR 0043, C).
///
/// Offered only where GitHub's own flags say so, and only for a post GitHub sent with its REST id:
/// the edit and delete endpoints take that number in their path, so a post without one cannot be
/// addressed. The description needs none — the pull request is its address. Pure, so the rule is
/// tested rather than read off a menu.
struct PostEditing: Hashable {
    /// The post's node id, which the overlay and the editor's draft are keyed by — the pull
    /// request's own for the description.
    let postID: String
    /// Where an edit or a delete of it is sent.
    let target: ConversationTarget
    /// Whether the menu offers *Edit*.
    let canEdit: Bool
    /// Whether the menu offers *Delete…* — never for a review or the description, which GitHub
    /// cannot delete.
    let canDelete: Bool

    /// The description: editable where GitHub says the viewer may, never deletable.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - conversation: The conversation, which carries the flag; `nil` until it has been read.
    /// - Returns: The description's, or `nil` when the viewer may not edit it.
    static func description(of prID: String, conversation: PullRequestConversation?) -> PostEditing? {
        guard conversation?.viewerCanUpdateDescription == true else { return nil }
        return PostEditing(postID: prID, target: .description, canEdit: true, canDelete: false)
    }

    /// A comment on the conversation.
    /// - Parameter comment: The comment.
    /// - Returns: Its, or `nil` when the viewer may neither edit nor delete it.
    static func comment(_ comment: ConversationComment) -> PostEditing? {
        comment.databaseID.flatMap { id in
            offered(comment.id, .issueComment(databaseID: id), comment.viewerCanUpdate, comment.viewerCanDelete)
        }
    }

    /// A review's words above its verdict: editable once submitted, never deletable — GitHub only
    /// dismisses a review. A verdict without words has no text to edit, and the viewer's pending
    /// review is not submitted.
    /// - Parameter review: The review.
    /// - Returns: Its, or `nil` when the viewer may not edit it.
    static func review(_ review: ConversationReview) -> PostEditing? {
        guard review.state != .pending, review.hasBody, let id = review.databaseID else { return nil }
        return offered(review.id, .review(databaseID: id), review.viewerCanUpdate, false)
    }

    /// A comment in a review thread.
    /// - Parameter comment: The comment.
    /// - Returns: Its, or `nil` when the viewer may neither edit nor delete it.
    static func threadComment(_ comment: ReviewComment) -> PostEditing? {
        comment.databaseID.flatMap { id in
            offered(comment.id, .reviewComment(databaseID: id), comment.viewerCanUpdate, comment.viewerCanDelete)
        }
    }

    /// The post's, or `nil` when GitHub allows neither.
    private static func offered(
        _ postID: String,
        _ target: ConversationTarget,
        _ canEdit: Bool,
        _ canDelete: Bool
    ) -> PostEditing? {
        guard canEdit || canDelete else { return nil }
        return PostEditing(postID: postID, target: target, canEdit: canEdit, canDelete: canDelete && target.isDeletable)
    }
}
