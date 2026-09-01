import Foundation

/// An outbound mutation waiting to be sent to GitHub.
///
/// Every write Shepherd performs — submitting a review, replying, resolving a thread,
/// merging — is written to the outbox first and executed by the sync engine (ADR 0006). That
/// is what makes writes survive a crash, a quit, or a train tunnel.
public enum OutboxAction: Sendable, Codable, Hashable {
    /// Submit a locally composed review.
    case submitReview(ReviewDraft)
    /// Reply to an existing review comment, addressed by its REST database id.
    case replyToComment(commentDatabaseID: Int, body: String)
    /// Resolve a review thread by its GraphQL node id.
    case resolveThread(threadID: String)
    /// Unresolve a review thread by its GraphQL node id.
    case unresolveThread(threadID: String)
    /// Merge the pull request.
    /// - Parameters:
    ///   - method: `"merge"`, `"squash"` or `"rebase"`. A raw string so that `ShepherdCore`
    ///     stays free of GitHub-specific types.
    ///   - expectedHeadOid: The head SHA the user saw, sent as a merge precondition.
    case merge(method: String, expectedHeadOid: String?)
    /// Take the pull request out of draft state.
    case markReadyForReview

    /// A short, stable discriminator, used as a database column and in logs.
    public var kind: String {
        switch self {
        case .submitReview: return "submitReview"
        case .replyToComment: return "replyToComment"
        case .resolveThread: return "resolveThread"
        case .unresolveThread: return "unresolveThread"
        case .merge: return "merge"
        case .markReadyForReview: return "markReadyForReview"
        }
    }
}

/// Where an outbox row is in its lifecycle.
public enum OutboxState: String, Sendable, Codable, Hashable, CaseIterable {
    /// Waiting to be sent, or waiting out a backoff.
    case pending
    /// Claimed by a drain and currently in flight.
    ///
    /// The claim is what makes the drain safe to call from several places at once: a row is
    /// moved out of ``pending`` inside the same write transaction that selects it, so a second
    /// drain overlapping the first can never pick the same row up and send it twice. Rows left
    /// in this state by a crash are reset to ``pending`` when the database is next opened.
    case sending
    /// Given up on: it failed in a way retrying cannot fix.
    case failed
    /// Not sent because the pull request moved on underneath it; needs the user to decide.
    case conflicted
    /// Sent successfully.
    case succeeded
}

/// One row of the outbox.
public struct OutboxItem: Sendable, Codable, Hashable, Identifiable {
    /// The row's local identity.
    public let id: UUID
    /// The pull request the mutation targets (a GraphQL node id).
    public var prID: String
    /// The repository the pull request lives in.
    public var repo: RepoRef
    /// The pull request number.
    public var number: Int
    /// What to do.
    public var action: OutboxAction
    /// When the row was enqueued.
    public var createdAt: Date
    /// How many times sending has been attempted.
    public var attemptCount: Int
    /// The earliest moment the next attempt may be made.
    public var nextAttemptAt: Date
    /// The last error message, for the UI and the log.
    public var lastError: String?
    /// The row's lifecycle state.
    public var state: OutboxState

    /// Creates an outbox row.
    public init(
        id: UUID = UUID(),
        prID: String,
        repo: RepoRef,
        number: Int,
        action: OutboxAction,
        createdAt: Date = Date(),
        attemptCount: Int = 0,
        nextAttemptAt: Date = Date(timeIntervalSince1970: 0),
        lastError: String? = nil,
        state: OutboxState = .pending
    ) {
        self.id = id
        self.prID = prID
        self.repo = repo
        self.number = number
        self.action = action
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.state = state
    }
}

/// The retry schedule for failed outbox rows.
///
/// Exponential with a ceiling: a GitHub outage must not turn into a request storm, and a
/// user who comes back after lunch must not wait an hour for their queued approval.
public enum OutboxBackoff {
    /// The delay before attempt number `attempt` (1-based).
    /// - Parameters:
    ///   - attempt: How many attempts have already failed.
    ///   - base: The delay after the first failure, in seconds. Defaults to 5.
    ///   - maximum: The ceiling, in seconds. Defaults to 15 minutes.
    /// - Returns: The delay in seconds.
    public static func delay(
        forAttempt attempt: Int,
        base: TimeInterval = 5,
        maximum: TimeInterval = 900
    ) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        // Cap the exponent before it can overflow a Double for absurd attempt counts.
        let exponent = min(attempt - 1, 16)
        let delay = base * pow(2, Double(exponent))
        return min(maximum, delay)
    }
}
