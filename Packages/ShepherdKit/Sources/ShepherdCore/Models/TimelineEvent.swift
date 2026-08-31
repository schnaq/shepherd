import Foundation

/// One entry of a pull request's condensed activity timeline.
///
/// Shepherd does not mirror GitHub's full timeline API; it keeps the events a reviewer needs
/// to understand the state of a conversation.
public struct TimelineEvent: Sendable, Codable, Hashable, Identifiable {
    /// The kind of activity an event represents.
    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        /// A commit was pushed to the head branch.
        case commit
        /// A review was submitted with an approval.
        case reviewApproved
        /// A review was submitted requesting changes.
        case reviewChangesRequested
        /// A review was submitted as a comment.
        case reviewCommented
        /// A standalone issue comment was posted.
        case comment
        /// The pull request was merged.
        case merged
        /// The pull request was closed without merging.
        case closed
        /// The pull request was reopened.
        case reopened
        /// The pull request left draft state.
        case readyForReview
        /// Something Shepherd does not model specifically.
        case other
    }

    /// A stable identifier for the event.
    public let id: String
    /// What happened.
    public var kind: Kind
    /// Who or what caused the event.
    public var author: Actor
    /// When it happened.
    public var createdAt: Date
    /// A short, already human-readable description of the event.
    public var summary: String

    /// Creates a timeline event.
    public init(id: String, kind: Kind, author: Actor, createdAt: Date, summary: String) {
        self.id = id
        self.kind = kind
        self.author = author
        self.createdAt = createdAt
        self.summary = summary
    }
}
