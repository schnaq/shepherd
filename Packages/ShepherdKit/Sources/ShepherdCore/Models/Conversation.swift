import Foundation

/// One of GitHub's eight reactions (ADR 0043).
///
/// The raw values are GraphQL's `ReactionContent` names, so the mapping layer reads them with
/// `init(rawValue:)` and drops a ninth one GitHub might add rather than failing the whole page.
public enum ReactionContent: String, Sendable, Codable, Hashable, CaseIterable {
    case thumbsUp = "THUMBS_UP"
    case thumbsDown = "THUMBS_DOWN"
    case laugh = "LAUGH"
    case hooray = "HOORAY"
    case confused = "CONFUSED"
    case heart = "HEART"
    case rocket = "ROCKET"
    case eyes = "EYES"

    /// The emoji GitHub draws for the reaction.
    public var emoji: String {
        switch self {
        case .thumbsUp: return "👍"
        case .thumbsDown: return "👎"
        case .laugh: return "😄"
        case .hooray: return "🎉"
        case .confused: return "😕"
        case .heart: return "❤️"
        case .rocket: return "🚀"
        case .eyes: return "👀"
        }
    }
}

/// How many people reacted one way to one post, and whether the viewer is one of them.
///
/// GitHub answers all eight groups for every post, most of them at zero; only the groups somebody
/// actually used are kept, so an absent content means "nobody, and not the viewer either".
public struct ReactionGroup: Sendable, Codable, Hashable {
    /// Which reaction.
    public var content: ReactionContent
    /// How many people reacted this way.
    public var count: Int
    /// Whether the signed-in user is one of them.
    public var viewerHasReacted: Bool

    /// Creates a reaction group.
    public init(content: ReactionContent, count: Int, viewerHasReacted: Bool = false) {
        self.content = content
        self.count = count
        self.viewerHasReacted = viewerHasReacted
    }
}

/// A comment on the pull request's conversation — an issue comment, in GitHub's model.
public struct ConversationComment: Sendable, Codable, Hashable, Identifiable {
    /// The GraphQL node id, which is also what a reaction is addressed to.
    public let id: String
    /// The REST database id, which is what an edit or a delete is addressed to.
    public var databaseID: Int?
    /// Who wrote it, with detected provenance.
    public var author: Actor
    /// The comment as Markdown source.
    public var bodyMarkdown: String
    /// When it was posted.
    public var createdAt: Date
    /// Whether it was edited after it was posted.
    public var isEdited: Bool
    /// The comment on github.com.
    public var url: URL?
    /// The reactions anybody left on it.
    public var reactions: [ReactionGroup]
    /// Whether GitHub lets the viewer edit it.
    public var viewerCanUpdate: Bool
    /// Whether GitHub lets the viewer delete it.
    public var viewerCanDelete: Bool
    /// Whether a maintainer hid it (off-topic, outdated, spam …).
    public var isMinimized: Bool
    /// GitHub's word for why it is hidden, lowercased (`off-topic`, `outdated`, `resolved`,
    /// `duplicate`, `spam`, `abuse`), or `nil` when it is not hidden or GitHub gave none.
    public var minimizedReason: String?

    /// Creates a conversation comment.
    public init(
        id: String,
        databaseID: Int? = nil,
        author: Actor,
        bodyMarkdown: String,
        createdAt: Date,
        isEdited: Bool = false,
        url: URL? = nil,
        reactions: [ReactionGroup] = [],
        viewerCanUpdate: Bool = false,
        viewerCanDelete: Bool = false,
        isMinimized: Bool = false,
        minimizedReason: String? = nil
    ) {
        self.id = id
        self.databaseID = databaseID
        self.author = author
        self.bodyMarkdown = bodyMarkdown
        self.createdAt = createdAt
        self.isEdited = isEdited
        self.url = url
        self.reactions = reactions
        self.viewerCanUpdate = viewerCanUpdate
        self.viewerCanDelete = viewerCanDelete
        self.isMinimized = isMinimized
        self.minimizedReason = minimizedReason
    }
}

/// A submitted (or the viewer's pending) review, as the conversation shows it: who, which
/// verdict, and what they wrote above their inline comments.
public struct ConversationReview: Sendable, Codable, Hashable, Identifiable {
    /// The review's verdict, as GitHub records it.
    public enum State: String, Sendable, Codable, Hashable {
        case approved
        case changesRequested
        case commented
        case dismissed
        /// Started and not submitted. Only the viewer's own can be seen.
        case pending
    }

    /// The GraphQL node id — what a reaction is addressed to, and what the review's inline
    /// comments name as ``ReviewComment/reviewID``.
    public let id: String
    /// The REST database id, which is what an edit is addressed to.
    public var databaseID: Int?
    /// Who reviewed.
    public var author: Actor
    /// The verdict.
    public var state: State
    /// The review's summary as Markdown source; empty for a verdict without words.
    public var bodyMarkdown: String
    /// When it was submitted, or created when it is still pending.
    public var createdAt: Date
    /// Whether the summary was edited after it was submitted.
    public var isEdited: Bool
    /// The review on github.com.
    public var url: URL?
    /// The reactions anybody left on it.
    public var reactions: [ReactionGroup]
    /// Whether GitHub lets the viewer edit the summary. A submitted review is never deletable.
    public var viewerCanUpdate: Bool
    /// The head commit the review was submitted against.
    public var commitOid: String?

    /// Creates a conversation review.
    public init(
        id: String,
        databaseID: Int? = nil,
        author: Actor,
        state: State,
        bodyMarkdown: String = "",
        createdAt: Date,
        isEdited: Bool = false,
        url: URL? = nil,
        reactions: [ReactionGroup] = [],
        viewerCanUpdate: Bool = false,
        commitOid: String? = nil
    ) {
        self.id = id
        self.databaseID = databaseID
        self.author = author
        self.state = state
        self.bodyMarkdown = bodyMarkdown
        self.createdAt = createdAt
        self.isEdited = isEdited
        self.url = url
        self.reactions = reactions
        self.viewerCanUpdate = viewerCanUpdate
        self.commitOid = commitOid
    }

    /// Whether the reviewer wrote anything above the verdict — a summary that is not blank.
    public var hasBody: Bool {
        !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Another issue or pull request that mentioned this one.
public struct ConversationReference: Sendable, Codable, Hashable {
    /// Where it lives.
    public var repo: RepoRef
    /// Its number.
    public var number: Int
    /// Its title.
    public var title: String
    /// Whether it is a pull request rather than an issue.
    public var isPullRequest: Bool
    /// It on github.com.
    public var url: URL?

    /// Creates a reference.
    public init(repo: RepoRef, number: Int, title: String, isPullRequest: Bool, url: URL? = nil) {
        self.repo = repo
        self.number = number
        self.title = title
        self.isPullRequest = isPullRequest
        self.url = url
    }
}

/// Something that happened to the pull request between the comments (ADR 0043).
///
/// Values only, never words: ShepherdKit carries no user-visible strings, so every sentence these
/// become is the app's, through `String(localized:)`.
public enum ConversationEvent: Sendable, Codable, Hashable {
    /// A label was added. `color` is GitHub's six-digit hex, without `#`.
    case labeled(name: String, color: String?)
    /// A label was removed.
    case unlabeled(name: String, color: String?)
    /// Somebody was assigned; the login of the assignee.
    case assigned(login: String)
    /// Somebody was unassigned.
    case unassigned(login: String)
    /// A review was requested from a person, a bot or a team (a team's name).
    case reviewRequested(reviewer: String)
    /// A review request was withdrawn.
    case reviewRequestRemoved(reviewer: String)
    /// The title changed.
    case renamed(from: String, to: String)
    /// The pull request left draft state.
    case readyForReview
    /// The pull request went back to draft.
    case convertedToDraft
    /// The pull request was merged, as `commitOid`, into the branch `into`.
    case merged(commitOid: String?, into: String?)
    /// The pull request was closed.
    case closed
    /// The pull request was reopened.
    case reopened
    /// The head branch was deleted.
    case headRefDeleted(branch: String?)
    /// The head branch was restored.
    case headRefRestored
    /// The base branch changed.
    case baseRefChanged(from: String?, to: String?)
    /// The head branch was force-pushed from one commit to another.
    case forcePushed(fromOid: String?, toOid: String?)
    /// Another issue or pull request mentioned this one; `willClose` when merging that one will
    /// close this one.
    case crossReferenced(ConversationReference, willClose: Bool)
    /// A review was dismissed, with the dismisser's message.
    case reviewDismissed(message: String?)
    /// Auto-merge was switched on.
    case autoMergeEnabled
    /// Auto-merge was switched off.
    case autoMergeDisabled
}

/// One event, with who caused it and when.
public struct ConversationEventItem: Sendable, Codable, Hashable, Identifiable {
    /// The event's GraphQL node id.
    public let id: String
    /// When it happened.
    public var createdAt: Date
    /// Who caused it, or `nil` when GitHub no longer knows (a deleted account).
    public var actor: Actor?
    /// What happened.
    public var event: ConversationEvent

    /// Creates an event item.
    public init(id: String, createdAt: Date, actor: Actor?, event: ConversationEvent) {
        self.id = id
        self.createdAt = createdAt
        self.actor = actor
        self.event = event
    }
}

/// One entry of GitHub's timeline as Shepherd reads it.
public enum ConversationItem: Sendable, Codable, Hashable, Identifiable {
    /// A comment on the conversation.
    case comment(ConversationComment)
    /// A review.
    case review(ConversationReview)
    /// Anything else that happened.
    case event(ConversationEventItem)

    /// The item's GraphQL node id.
    public var id: String {
        switch self {
        case .comment(let comment): return comment.id
        case .review(let review): return review.id
        case .event(let event): return event.id
        }
    }

    /// When the item happened.
    public var createdAt: Date {
        switch self {
        case .comment(let comment): return comment.createdAt
        case .review(let review): return review.createdAt
        case .event(let event): return event.createdAt
        }
    }
}

/// A pull request's conversation: GitHub's timeline plus what the description carries
/// (ADR 0043).
///
/// Read on the detail fetch and stored as JSON beside the detail. `nil` on a
/// ``PullRequestDetail`` means the read did not happen or failed, which is not the same as an
/// empty conversation — the store keeps the copy it has rather than writing "nothing" over it.
public struct PullRequestConversation: Sendable, Codable, Hashable {
    /// The reactions on the description.
    public var descriptionReactions: [ReactionGroup]
    /// Whether the description was edited after the pull request was opened.
    public var isDescriptionEdited: Bool
    /// Whether GitHub lets the viewer edit the description.
    public var viewerCanUpdateDescription: Bool
    /// Whether GitHub lets the viewer react at all — `false` on a locked conversation or an
    /// archived repository.
    public var viewerCanReact: Bool
    /// The timeline, oldest first.
    public var items: [ConversationItem]
    /// Whether GitHub has older items than these: the read stops after a fixed number of pages,
    /// newest first, so what is cut is the start of the conversation.
    public var hasEarlierItems: Bool

    /// Creates a conversation.
    public init(
        descriptionReactions: [ReactionGroup] = [],
        isDescriptionEdited: Bool = false,
        viewerCanUpdateDescription: Bool = false,
        viewerCanReact: Bool = false,
        items: [ConversationItem] = [],
        hasEarlierItems: Bool = false
    ) {
        self.descriptionReactions = descriptionReactions
        self.isDescriptionEdited = isDescriptionEdited
        self.viewerCanUpdateDescription = viewerCanUpdateDescription
        self.viewerCanReact = viewerCanReact
        self.items = items
        self.hasEarlierItems = hasEarlierItems
    }
}
