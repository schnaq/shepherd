import Foundation

/// Which side of a split diff a comment is anchored to.
public enum DiffSide: String, Sendable, Codable, Hashable, CaseIterable {
    /// The base (left) side — a deleted or unchanged line.
    case left = "LEFT"
    /// The head (right) side — an added or unchanged line.
    case right = "RIGHT"
}

/// A single comment inside a ``ReviewThread``.
public struct ReviewComment: Sendable, Codable, Hashable, Identifiable {
    /// The GraphQL node id of the comment.
    public let id: String
    /// The REST database id, needed to post replies (`POST …/comments/{id}/replies`).
    public var databaseID: Int?
    /// The comment author with detected provenance.
    public var author: Actor
    /// The comment body as Markdown source.
    public var bodyMarkdown: String
    /// When the comment was posted.
    public var createdAt: Date
    /// Set while a locally drafted comment has not been published yet.
    public var pendingLocalID: UUID?
    /// The node id of the review this comment was submitted in (ADR 0043).
    ///
    /// The first comment's is what places a thread under its review in the conversation tab.
    public var reviewID: String?
    /// The reactions anybody left on the comment.
    public var reactions: [ReactionGroup]
    /// Whether GitHub lets the viewer edit the comment.
    public var viewerCanUpdate: Bool
    /// Whether GitHub lets the viewer delete the comment.
    public var viewerCanDelete: Bool
    /// Whether the comment was edited after it was posted.
    public var isEdited: Bool
    /// The comment on github.com.
    public var url: URL?

    /// Creates a review comment.
    public init(
        id: String,
        databaseID: Int? = nil,
        author: Actor,
        bodyMarkdown: String,
        createdAt: Date,
        pendingLocalID: UUID? = nil,
        reviewID: String? = nil,
        reactions: [ReactionGroup] = [],
        viewerCanUpdate: Bool = false,
        viewerCanDelete: Bool = false,
        isEdited: Bool = false,
        url: URL? = nil
    ) {
        self.id = id
        self.databaseID = databaseID
        self.author = author
        self.bodyMarkdown = bodyMarkdown
        self.createdAt = createdAt
        self.pendingLocalID = pendingLocalID
        self.reviewID = reviewID
        self.reactions = reactions
        self.viewerCanUpdate = viewerCanUpdate
        self.viewerCanDelete = viewerCanDelete
        self.isEdited = isEdited
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id, databaseID, author, bodyMarkdown, createdAt, pendingLocalID
        case reviewID, reactions, viewerCanUpdate, viewerCanDelete, isEdited, url
    }

    /// Decodes a comment, tolerating the ADR 0043 fields being absent: a detail encoded before
    /// they existed carries no key for them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        databaseID = try container.decodeIfPresent(Int.self, forKey: .databaseID)
        author = try container.decode(Actor.self, forKey: .author)
        bodyMarkdown = try container.decode(String.self, forKey: .bodyMarkdown)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        pendingLocalID = try container.decodeIfPresent(UUID.self, forKey: .pendingLocalID)
        reviewID = try container.decodeIfPresent(String.self, forKey: .reviewID)
        reactions = try container.decodeIfPresent([ReactionGroup].self, forKey: .reactions) ?? []
        viewerCanUpdate = try container.decodeIfPresent(Bool.self, forKey: .viewerCanUpdate) ?? false
        viewerCanDelete = try container.decodeIfPresent(Bool.self, forKey: .viewerCanDelete) ?? false
        isEdited = try container.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
        url = try container.decodeIfPresent(URL.self, forKey: .url)
    }
}

/// A conversation anchored to a line of a diff (or to the pull request itself).
///
/// Thread ids come from GraphQL, which is also the only API that can resolve or unresolve a
/// thread (ADR 0005).
public struct ReviewThread: Sendable, Codable, Hashable, Identifiable {
    /// The GraphQL node id of the thread.
    public let id: String
    /// The file the thread is anchored to, or `nil` for a pull-request-level conversation.
    public var path: String?
    /// The line the thread is anchored to, or `nil` when the anchor was lost.
    ///
    /// GraphQL reports `nil` precisely when the thread no longer maps onto the current diff.
    /// That `nil` is load-bearing and must never be papered over with ``originalLine``: a
    /// thread rendered at a stale line points at unrelated code.
    public var line: Int?
    /// The line the thread was anchored to in the commit it was written against.
    ///
    /// Only useful for display ("was line 42"): it refers to an older diff, so it must not be
    /// used to position anything in the current one.
    public var originalLine: Int?
    /// Which side of the diff the thread is anchored to.
    public var side: DiffSide
    /// Whether the thread has been resolved.
    public var isResolved: Bool
    /// Whether the thread's anchor refers to an outdated version of the file.
    public var isOutdated: Bool
    /// The comments of the thread, oldest first.
    public var comments: [ReviewComment]

    /// Creates a review thread.
    public init(
        id: String,
        path: String? = nil,
        line: Int? = nil,
        originalLine: Int? = nil,
        side: DiffSide = .right,
        isResolved: Bool = false,
        isOutdated: Bool = false,
        comments: [ReviewComment] = []
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.originalLine = originalLine
        self.side = side
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.comments = comments
    }

    /// The first comment of the thread, which carries its subject.
    public var rootComment: ReviewComment? { comments.first }

    /// Whether the thread still maps onto the *current* diff.
    ///
    /// Only such a thread may be drawn as a view zone in the diff viewer; everything else —
    /// pull-request-level conversations, threads that lost their anchor, and outdated threads
    /// whose line refers to an older commit — belongs in the conversation view.
    public var isAnchoredInCurrentDiff: Bool {
        path != nil && line != nil && !isOutdated
    }
}
