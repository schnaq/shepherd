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

/// CI went red on a pull request the user owns, with what the previous sweep saw.
///
/// The "before" half is the whole point. A notification only needs "it is red now", but an
/// automation needs to know whether Shepherd *watched it turn* red: a first sweep after a fresh
/// install finds every long-broken pull request in the account at once, and treating those as
/// news would fire a rule for each of them (ADR 0016).
///
/// Flattened to values like ``SyncFailure`` and ``SentMutation``, so ``SyncEvent`` stays
/// `Hashable` and a test can assert on one directly.
public struct ChecksFailure: Sendable, Hashable, Codable {
    /// The pull request, as the sweep knows it.
    public var summary: PullRequestSummary
    /// The rolled-up state the previous sweep saw. `nil` means it reported no checks at all —
    /// or, when ``wasTracked`` is `false`, that there was no previous sweep to ask.
    public var previousState: CheckRollup.State?
    /// Whether the previous sweep had this pull request in the inbox at all.
    public var wasTracked: Bool

    /// Creates a failure notice.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - previousState: The rolled-up state the previous sweep saw.
    ///   - wasTracked: Whether the previous sweep had this pull request.
    public init(
        summary: PullRequestSummary,
        previousState: CheckRollup.State?,
        wasTracked: Bool
    ) {
        self.summary = summary
        self.previousState = previousState
        self.wasTracked = wasTracked
    }

    /// Whether Shepherd saw the state *change*, rather than finding it already failing.
    ///
    /// The engine only emits on a change of the rolled-up state, so this is exactly "the
    /// previous sweep knew this pull request".
    public var isTransition: Bool { wasTracked && previousState != .failure }
}

/// A reviewer asked for changes on a pull request the user owns, with the decision before.
///
/// The same shape and the same reason as ``ChecksFailure``: an automation may act on the edge,
/// never on the state (ADR 0016).
public struct ChangesRequested: Sendable, Hashable, Codable {
    /// The pull request, as the sweep knows it.
    public var summary: PullRequestSummary
    /// The review decision the previous sweep saw, if any.
    public var previousDecision: ReviewDecision?
    /// Whether the previous sweep had this pull request in the inbox at all.
    public var wasTracked: Bool

    /// Creates a notice.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - previousDecision: The review decision the previous sweep saw.
    ///   - wasTracked: Whether the previous sweep had this pull request.
    public init(
        summary: PullRequestSummary,
        previousDecision: ReviewDecision?,
        wasTracked: Bool
    ) {
        self.summary = summary
        self.previousDecision = previousDecision
        self.wasTracked = wasTracked
    }

    /// Whether Shepherd saw the decision *change*, rather than finding it already so.
    public var isTransition: Bool { wasTracked && previousDecision != .changesRequested }
}

/// Something the sync engine noticed that the app may want to tell the user about.
///
/// The app maps these onto macOS notifications; the engine itself has no opinion about
/// presentation and never blocks on delivery.
public enum SyncEvent: Sendable, Hashable {
    /// A pull request appeared that is waiting for the user's review.
    case newReviewRequest(PullRequestSummary)
    /// CI turned red on a pull request the user owns.
    case checksFailedOnOwnPR(ChecksFailure)
    /// A reviewer asked for changes on a pull request the user owns.
    ///
    /// Emitted on the change of GitHub's aggregate review decision, which is why it is not just
    /// ``prUpdated(_:)``: "somebody wants something from me" is a different fact from "this row
    /// moved".
    case changesRequestedOnOwnPR(ChangesRequested)
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
