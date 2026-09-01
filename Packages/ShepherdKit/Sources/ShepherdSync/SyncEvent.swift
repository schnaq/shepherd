import Foundation
import ShepherdCore

/// Which part of the sync produced a failure.
public enum SyncStage: String, Sendable, Hashable, Codable, CaseIterable {
    /// The GraphQL search sweep.
    case sweep
    /// A pull-request detail fetch.
    case detail
    /// The notifications poll.
    case notifications
    /// Draining the outbox.
    case outbox
}

/// A sync failure, flattened to values so events stay `Equatable` and easy to assert on.
public struct SyncFailure: Sendable, Hashable, Codable {
    /// Where it happened.
    public var stage: SyncStage
    /// A human-readable description.
    public var message: String

    /// Creates a failure.
    /// - Parameters:
    ///   - stage: Where it happened.
    ///   - message: A human-readable description.
    public init(stage: SyncStage, message: String) {
        self.stage = stage
        self.message = message
    }
}

/// A queued review could not be submitted because the pull request moved on underneath it.
///
/// ADR 0006 is explicit that this must be surfaced rather than silently submitted against the
/// wrong commit: the user's inline comments would land on the wrong lines.
public struct DraftConflict: Sendable, Hashable, Codable {
    /// The pull request's node id.
    public var prID: String
    /// The repository.
    public var repo: RepoRef
    /// The pull request number.
    public var number: Int
    /// The head commit the draft was written against.
    public var expectedHeadOid: String
    /// The head commit the pull request is on now.
    public var actualHeadOid: String

    /// Creates a conflict description.
    public init(
        prID: String,
        repo: RepoRef,
        number: Int,
        expectedHeadOid: String,
        actualHeadOid: String
    ) {
        self.prID = prID
        self.repo = repo
        self.number = number
        self.expectedHeadOid = expectedHeadOid
        self.actualHeadOid = actualHeadOid
    }
}

/// A queued mutation that has now actually reached GitHub.
///
/// The outbox is the only write path (ADR 0006), which makes "the drain sent this row" the one
/// moment where an action is *definitely* done rather than merely intended. Anything that must
/// only happen after a real success — an outbound webhook, for instance (ADR 0012) — hangs off
/// this event instead of off the enqueue.
///
/// Flattened to values, like ``SyncFailure`` and ``DraftConflict``, so ``SyncEvent`` stays
/// `Hashable` and a test can assert on one directly. It deliberately carries only the pull
/// request's identity: the engine does not spend a fetch to describe an event, and a consumer
/// that wants the title looks the row up in the database it is already reading from.
public struct SentMutation: Sendable, Hashable, Codable {
    /// Which mutation was sent.
    public enum Kind: Sendable, Hashable, Codable {
        /// A review was submitted. A `nil` verdict means it was parked as a GitHub pending
        /// review; the count is how many inline comments went with it.
        case reviewSubmitted(verdict: ReviewVerdict?, inlineCommentCount: Int)
        /// A reply was posted to an existing review comment.
        case replyPosted
        /// A review thread was resolved.
        case threadResolved
        /// A review thread was reopened.
        case threadUnresolved
        /// The pull request was merged, with the method GitHub was asked for.
        case merged(method: String)
        /// The pull request was taken out of draft state.
        case markedReadyForReview
    }

    /// The pull request's node id.
    public var prID: String
    /// The repository.
    public var repo: RepoRef
    /// The pull request number.
    public var number: Int
    /// What was sent.
    public var kind: Kind
    /// When the drain sent it.
    public var sentAt: Date

    /// Creates a record of a sent mutation.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - repo: The repository.
    ///   - number: The pull request number.
    ///   - kind: What was sent.
    ///   - sentAt: When the drain sent it.
    public init(prID: String, repo: RepoRef, number: Int, kind: Kind, sentAt: Date) {
        self.prID = prID
        self.repo = repo
        self.number = number
        self.kind = kind
        self.sentAt = sentAt
    }
}

/// Something the sync engine noticed that the app may want to tell the user about.
///
/// The app maps these onto macOS notifications; the engine itself has no opinion about
/// presentation and never blocks on delivery.
public enum SyncEvent: Sendable, Hashable {
    /// A pull request appeared that is waiting for the user's review.
    case newReviewRequest(PullRequestSummary)
    /// CI turned red on a pull request the user authored.
    case checksFailedOnOwnPR(PullRequestSummary)
    /// A pull request the inbox was tracking is no longer open.
    ///
    /// An open-pull-request sweep cannot distinguish "merged" from "closed"; the app confirms
    /// on demand when the user opens the row. The name follows the overwhelmingly common case.
    case prMerged(PullRequestSummary)
    /// A tracked pull request changed (new commits, new reviews, new CI state).
    case prUpdated(PullRequestSummary)
    /// A queued review could not be submitted; the user has to decide what to do.
    case draftConflict(DraftConflict)
    /// An outbox row reached GitHub. The one point where a write is known to have succeeded.
    case mutationSent(SentMutation)
    /// A sync step failed.
    case syncFailed(SyncFailure)
}
