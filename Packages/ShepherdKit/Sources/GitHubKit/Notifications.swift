import Foundation
import ShepherdCore

/// Why GitHub sent a notification thread.
public enum NotificationReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The user's review was requested — the reason Shepherd cares most about.
    case reviewRequested
    /// The user was @-mentioned.
    case mention
    /// The user was assigned.
    case assign
    /// The user opened the thing that changed.
    case author
    /// Someone commented on a thread the user is in.
    case comment
    /// The thread was opened, closed or merged.
    case stateChange
    /// The user subscribed to the repository.
    case subscribed
    /// A CI run the user cares about finished.
    case ciActivity
    /// A reason Shepherd does not model.
    case other

    /// Maps GitHub's `reason` string.
    /// - Parameter raw: The raw reason, e.g. `"review_requested"`.
    public static func fromAPI(_ raw: String) -> NotificationReason {
        switch raw.lowercased() {
        case "review_requested": return .reviewRequested
        case "mention", "team_mention": return .mention
        case "assign": return .assign
        case "author": return .author
        case "comment": return .comment
        case "state_change": return .stateChange
        case "subscribed": return .subscribed
        case "ci_activity": return .ciActivity
        default: return .other
        }
    }
}

/// One notification thread from `GET /notifications`.
public struct NotificationItem: Sendable, Hashable, Identifiable {
    /// GitHub's thread id.
    public let id: String
    /// Why the notification was sent.
    public var reason: NotificationReason
    /// Whether the thread is still unread.
    public var isUnread: Bool
    /// When the thread last changed.
    public var updatedAt: Date
    /// The subject title, e.g. the pull request title.
    public var subjectTitle: String
    /// The subject type, e.g. `"PullRequest"`.
    public var subjectType: String
    /// The repository the thread belongs to, when it could be parsed.
    public var repo: RepoRef?
    /// The pull request number, parsed from the subject URL when the subject is a pull request.
    public var pullRequestNumber: Int?

    /// Creates a notification item.
    public init(
        id: String,
        reason: NotificationReason,
        isUnread: Bool,
        updatedAt: Date,
        subjectTitle: String,
        subjectType: String,
        repo: RepoRef?,
        pullRequestNumber: Int?
    ) {
        self.id = id
        self.reason = reason
        self.isUnread = isUnread
        self.updatedAt = updatedAt
        self.subjectTitle = subjectTitle
        self.subjectType = subjectType
        self.repo = repo
        self.pullRequestNumber = pullRequestNumber
    }

    /// Whether the notification is about a pull request.
    public var isPullRequest: Bool { subjectType == "PullRequest" }
}

/// The result of one `GET /notifications` poll.
public struct NotificationsPage: Sendable, Hashable {
    /// The threads GitHub returned. Empty for a `304`.
    public var items: [NotificationItem]
    /// The server's requested minimum gap before the next poll, from `X-Poll-Interval`.
    ///
    /// ADR 0005 makes honouring this mandatory: it is how GitHub sheds load, and ignoring it
    /// is how clients get rate limited.
    public var pollInterval: TimeInterval?
    /// The `Last-Modified` value to replay as `If-Modified-Since` next time.
    public var lastModified: String?
    /// Whether the server answered `304 Not Modified` — a free poll.
    public var notModified: Bool

    /// Creates a page.
    public init(
        items: [NotificationItem],
        pollInterval: TimeInterval? = nil,
        lastModified: String? = nil,
        notModified: Bool = false
    ) {
        self.items = items
        self.pollInterval = pollInterval
        self.lastModified = lastModified
        self.notModified = notModified
    }
}
