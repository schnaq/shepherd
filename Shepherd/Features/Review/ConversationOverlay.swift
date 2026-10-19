import ShepherdCore

/// What the reviewer did to the conversation that the stored detail does not show yet
/// (ADR 0043): reaction clicks (B), and the new text of posts they edited and the comments they
/// deleted (C).
///
/// What makes a change visible on the click and, while the review screen is open, an offline
/// change visible until it is sent. A key goes when a detail reaching the screen agrees with it
/// (``settled(against:)``) — not when its write is sent, because the re-read after a send can still
/// carry the state from before it and would flicker the change off and on. It also goes when the
/// change could not be written, and when its own drain saw its row refused
/// (``drop(_:ifStill:)`` and its two siblings). A refusal that comes later — from a drain the
/// change did not wait for, which is what a change gets whose row another change's drain is still
/// sending — leaves its key until the screen closes; the failed row is in Settings → Sync.
///
/// A value, and pure, so every rule here is tested without a ``ReviewModel``, which holds one
/// (``ReviewModel/conversationOverlay``).
struct ConversationOverlay: Equatable {
    /// One reaction on one post — what ``reactions`` is keyed by.
    struct ReactionKey: Hashable {
        /// The post's node id — the pull request's own for the description.
        var subjectID: String
        /// Which reaction.
        var content: ReactionContent
    }

    /// The reaction clicks: `true` wants the viewer's reaction on, `false` off.
    var reactions: [ReactionKey: Bool] = [:]
    /// The text of each post the reviewer edited, by node id — the pull request's own for the
    /// description.
    var editedBodies: [String: String] = [:]
    /// The comments the reviewer deleted, by node id.
    var deletedPosts: Set<String> = []

    /// A post's reactions as its bar shows them: GitHub's stored groups with the reviewer's clicks
    /// laid over them.
    ///
    /// A click moves its group by one and marks it as the viewer's or not; a group that reaches
    /// zero goes, and a new one takes its place in GitHub's order of the eight, which is
    /// ``ShepherdCore/ReactionContent``'s.
    /// - Parameters:
    ///   - groups: The post's groups as stored.
    ///   - subjectID: The post's node id.
    /// - Returns: The groups to draw.
    func reactions(_ groups: [ReactionGroup], on subjectID: String) -> [ReactionGroup] {
        guard !reactions.isEmpty else { return groups }
        return ReactionContent.allCases.compactMap { content in
            let stored = groups.first { $0.content == content }
            guard let wanted = reactions[ReactionKey(subjectID: subjectID, content: content)],
                  wanted != (stored?.viewerHasReacted ?? false)
            else { return stored }
            let count = (stored?.count ?? 0) + (wanted ? 1 : -1)
            return count > 0 ? ReactionGroup(content: content, count: count, viewerHasReacted: wanted) : nil
        }
    }

    /// The detail as the conversation tab draws it: each edited post with its new text, and the
    /// deleted comments gone, from the conversation and from the threads.
    ///
    /// Only the conversation tab draws this; every other surface — the diff and its thread
    /// popover — keeps reading the stored detail. A thread whose comments are all deleted is left
    /// with none, and the stream draws no thread without a comment
    /// (``ShepherdCore/ConversationTimeline``).
    /// - Parameter detail: The stored detail.
    /// - Returns: The detail to build the stream and the description from.
    func applied(to detail: PullRequestDetail) -> PullRequestDetail {
        guard !editedBodies.isEmpty || !deletedPosts.isEmpty else { return detail }
        var shown = detail
        shown.bodyMarkdown = editedBodies[detail.summary.id] ?? detail.bodyMarkdown
        shown.conversation?.items = (detail.conversation?.items ?? []).compactMap { item in
            switch item {
            case .comment(var comment):
                guard !deletedPosts.contains(comment.id) else { return nil }
                comment.bodyMarkdown = editedBodies[comment.id] ?? comment.bodyMarkdown
                return .comment(comment)
            case .review(var review):
                review.bodyMarkdown = editedBodies[review.id] ?? review.bodyMarkdown
                return .review(review)
            case .event:
                return item
            }
        }
        for index in shown.threads.indices {
            shown.threads[index].comments = shown.threads[index].comments.compactMap { comment in
                guard !deletedPosts.contains(comment.id) else { return nil }
                var edited = comment
                edited.bodyMarkdown = editedBodies[comment.id] ?? comment.bodyMarkdown
                return edited
            }
        }
        return shown
    }

    /// The overlay a detail reaching the screen leaves: the keys it does not agree with yet.
    ///
    /// A click goes once the detail shows the viewer's reaction the way the click wanted it, an
    /// edit once the post's text is the edited text, a delete once the post is gone. A click on a
    /// post the detail does not carry keeps its key, and so do an edit and a delete while the
    /// conversation is `nil`: it is `nil` until it has been read, or when its read failed, and
    /// "not read" is neither "not reacted", "not edited" nor "gone". A post the threads or the
    /// description carry settles all the same — those are always read.
    /// - Parameter detail: The detail reaching the screen.
    /// - Returns: The keys to keep.
    func settled(against detail: PullRequestDetail) -> ConversationOverlay {
        guard self != ConversationOverlay() else { return self }
        // What the detail stores for every post it carries.
        var storedReactions: [String: [ReactionGroup]] = [:]
        var storedBodies: [String: String] = [detail.summary.id: detail.bodyMarkdown]
        if let conversation = detail.conversation {
            storedReactions[detail.summary.id] = conversation.descriptionReactions
            for item in conversation.items {
                switch item {
                case .comment(let comment):
                    storedReactions[comment.id] = comment.reactions
                    storedBodies[comment.id] = comment.bodyMarkdown
                case .review(let review):
                    storedReactions[review.id] = review.reactions
                    storedBodies[review.id] = review.bodyMarkdown
                case .event:
                    break
                }
            }
        }
        for comment in detail.threads.flatMap(\.comments) {
            storedReactions[comment.id] = comment.reactions
            storedBodies[comment.id] = comment.bodyMarkdown
        }
        let isRead = detail.conversation != nil
        var settled = self
        settled.reactions = reactions.filter { key, wanted in
            guard let groups = storedReactions[key.subjectID] else { return true }
            return groups.contains { $0.content == key.content && $0.viewerHasReacted } != wanted
        }
        // ponytail: equality with the text that was sent; should GitHub ever answer with another
        // spelling of it, the key stays until the screen closes — compare a normalised form then.
        settled.editedBodies = editedBodies.filter { postID, body in
            storedBodies[postID].map { $0 != body } ?? !isRead
        }
        settled.deletedPosts = deletedPosts.filter { postID in
            storedBodies[postID] != nil || !isRead
        }
        return settled
    }

    /// Drops a click's key — unless a later click on the same emoji has moved it since.
    /// - Parameters:
    ///   - key: The post and the emoji.
    ///   - adding: The direction the click went.
    mutating func drop(_ key: ReactionKey, ifStill adding: Bool) {
        if reactions[key] == adding { reactions[key] = nil }
    }

    /// Drops an edit's text — unless a later edit of the same post has replaced it since.
    /// - Parameters:
    ///   - postID: The post's node id.
    ///   - body: The text the edit put there.
    mutating func drop(editOf postID: String, ifStill body: String) {
        if editedBodies[postID] == body { editedBodies[postID] = nil }
    }

    /// Hides a comment its delete is queued for, and forgets any edit of it.
    ///
    /// The delete's write takes a waiting edit of this comment out of the outbox, and that edit's
    /// own drain then reads its row as sent — so its text would outlive a refused delete, as text
    /// that never went out. An edit the drain already holds either lands, and its re-read brings its
    /// text back the way it brings any sent write, or gives way to the delete.
    /// - Parameter postID: The comment's node id.
    mutating func delete(_ postID: String) {
        deletedPosts.insert(postID)
        editedBodies[postID] = nil
    }

    /// Drops a delete, so the comment is drawn again.
    /// - Parameter postID: The comment's node id.
    mutating func drop(deletionOf postID: String) {
        deletedPosts.remove(postID)
    }
}
