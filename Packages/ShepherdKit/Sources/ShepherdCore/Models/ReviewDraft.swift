import Foundation

/// The verdict a review is submitted with.
///
/// A draft with a `nil` verdict is submitted as a GitHub `PENDING` review (ADR 0005).
public enum ReviewVerdict: String, Sendable, Codable, Hashable, CaseIterable {
    /// Approve the pull request (`APPROVE`).
    case approve
    /// Request changes (`REQUEST_CHANGES`).
    case requestChanges
    /// Comment without a verdict (`COMMENT`).
    case comment

    /// The `event` value the REST reviews endpoint expects.
    public var apiEvent: String {
        switch self {
        case .approve: return "APPROVE"
        case .requestChanges: return "REQUEST_CHANGES"
        case .comment: return "COMMENT"
        }
    }
}

/// One inline comment inside a locally drafted review.
public struct DraftComment: Sendable, Codable, Hashable, Identifiable {
    /// The local identity of the comment; stable across app restarts.
    public let localID: UUID
    /// The file the comment is anchored to.
    public var path: String
    /// The (last) line the comment is anchored to.
    public var line: Int
    /// Which side of the diff the comment belongs to.
    public var side: DiffSide
    /// The first line of a multi-line comment, when the user selected a range.
    public var startLine: Int?
    /// The comment body as Markdown source.
    public var body: String

    /// Creates a draft comment.
    public init(
        localID: UUID = UUID(),
        path: String,
        line: Int,
        side: DiffSide = .right,
        startLine: Int? = nil,
        body: String
    ) {
        self.localID = localID
        self.path = path
        self.line = line
        self.side = side
        self.startLine = startLine
        self.body = body
    }

    /// `DraftComment` is identified by its ``localID``.
    public var id: UUID { localID }
}

/// A pending review the user is composing locally.
///
/// Drafts are written to SQLite immediately and pushed to GitHub explicitly, so they survive
/// crashes and offline periods (ADR 0006). ``basedOnHeadOid`` lets the sync engine detect that
/// the pull request moved on underneath the draft before submitting it.
public struct ReviewDraft: Sendable, Codable, Hashable, Identifiable {
    /// The pull request this draft belongs to (a GraphQL node id).
    public let prID: String
    /// The verdict, or `nil` to keep the review pending on GitHub.
    public var verdict: ReviewVerdict?
    /// The review summary body as Markdown source.
    public var summaryBody: String
    /// Inline comments, in the order they were added.
    public var comments: [DraftComment]
    /// The head commit the draft was written against.
    public var basedOnHeadOid: String
    /// When the draft was last modified.
    public var updatedAt: Date

    /// Creates a review draft.
    public init(
        prID: String,
        verdict: ReviewVerdict? = nil,
        summaryBody: String = "",
        comments: [DraftComment] = [],
        basedOnHeadOid: String,
        updatedAt: Date = Date()
    ) {
        self.prID = prID
        self.verdict = verdict
        self.summaryBody = summaryBody
        self.comments = comments
        self.basedOnHeadOid = basedOnHeadOid
        self.updatedAt = updatedAt
    }

    /// `ReviewDraft` is identified by the pull request it belongs to.
    public var id: String { prID }

    /// Whether the draft carries nothing worth submitting.
    public var isEmpty: Bool {
        verdict == nil && comments.isEmpty
            && summaryBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The draft a one-click verdict amounts to.
    ///
    /// An existing local draft is *reused* rather than replaced, so a verdict fired from the
    /// inbox — or from a bulk-triage run — never throws away inline comments the user already
    /// wrote. The head the user saw is what the draft is anchored to, which is what lets the
    /// drain refuse a review whose pull request moved on (ADR 0006).
    /// - Parameters:
    ///   - verdict: The verdict to record.
    ///   - summary: The pull request the draft belongs to.
    ///   - existing: The draft already on disk, if any.
    ///   - body: A summary body to set; an empty string leaves the existing one alone.
    ///   - now: The modification timestamp.
    /// - Returns: The draft to persist and enqueue.
    public static func verdict(
        _ verdict: ReviewVerdict,
        on summary: PullRequestSummary,
        existing: ReviewDraft? = nil,
        body: String = "",
        at now: Date = Date()
    ) -> ReviewDraft {
        var draft = existing ?? ReviewDraft(prID: summary.id, basedOnHeadOid: summary.headRefOid)
        draft.verdict = verdict
        if !body.isEmpty { draft.summaryBody = body }
        draft.updatedAt = now
        if draft.basedOnHeadOid.isEmpty {
            draft.basedOnHeadOid = summary.headRefOid
        }
        return draft
    }
}
