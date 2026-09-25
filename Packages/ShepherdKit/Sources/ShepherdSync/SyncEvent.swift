import Foundation
import GitHubKit
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
///
/// **Two readings of one failure.** ``message`` is the English sentence, for tests and logs, and
/// it is the only description a failure that is not a ``GitHubKit/GitHubError`` has. ``error``
/// and ``context`` are the same failure as typed values, so the app can say it in the user's
/// language: this package is Foundation-only and cannot call `String(localized:)` (ADR 0022, the
/// 2026-09-22 amendment), and an English sentence cannot be translated after it was composed. The
/// typed error travels rather than a code because nothing here outlives the process — a
/// ``SyncEvent`` goes from the engine to the session and no further — so the value itself is the
/// least that carries a German sentence, payload included.
public struct SyncFailure: Sendable, Hashable, Codable {
    /// What the failure was about beyond its stage, where the English ``message`` says more than
    /// the error alone.
    ///
    /// Closed, so the app renders each one with its own catalog key rather than parsing
    /// ``message``.
    public enum Context: Sendable, Hashable, Codable {
        /// Nothing beyond the error itself.
        case none
        /// A pull request's detail fetch, for the pull request `slug` (`owner/repo#12`).
        case pullRequestDetail(slug: String)
        /// The issue sweep (ADR 0032), as opposed to the pull-request sweep of the same stage.
        case issueSweep
        /// The token is not allowed the notifications API at all, so the poll has stopped for
        /// good and the sweep keeps the inbox current on its own.
        case notificationsUnavailable
        /// A close landed, but the comment meant to go with it did not; `slug` names the target.
        case closedButCommentNotPosted(slug: String)
    }

    /// Where it happened.
    public var stage: SyncStage
    /// A human-readable description, in English.
    public var message: String
    /// The GitHub error behind the failure, when it was one.
    public var error: GitHubError?
    /// What the failure was about, for a display that re-composes ``message`` in another
    /// language.
    public var context: Context

    /// Creates a failure.
    /// - Parameters:
    ///   - stage: Where it happened.
    ///   - message: A human-readable description, in English.
    ///   - error: The GitHub error behind it, when it was one.
    ///   - context: What it was about, beyond the stage.
    public init(
        stage: SyncStage,
        message: String,
        error: GitHubError? = nil,
        context: Context = .none
    ) {
        self.stage = stage
        self.message = message
        self.error = error
        self.context = context
    }
}

/// A queued review could not be submitted because the pull request moved on underneath it.
///
/// ADR 0006 is explicit that this must be surfaced rather than silently submitted against the
/// wrong commit: the user's inline comments would land on the wrong lines.
public struct DraftConflict: Sendable, Hashable, Codable {
    /// The target's node id — the pull request's, or the issue's for an issue action
    /// (ADR 0032). Named for the pull request it usually is, exactly as
    /// ``ShepherdCore/OutboxItem/prID`` is and for the same reason.
    public var prID: String
    /// The repository.
    public var repo: RepoRef
    /// The target's number within its repository.
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
        /// GitHub accepted an *Update branch* for the pull request (ADR 0041). Accepted, not
        /// finished: the new head arrives with a later sweep, which is what a merge series waits
        /// for before it re-pins.
        case branchUpdated
        /// A comment was posted on an issue (ADR 0032's Sprint 4a amendment).
        case issueCommentAdded
        /// A label was added to an issue.
        case issueLabelAdded(name: String)
        /// An assignee was added to an issue.
        case issueAssigneeAdded(login: String)
        /// An issue was closed, with GitHub's own `state_reason` word.
        case issueClosed(reason: String)
        /// A closed issue was reopened.
        case issueReopened
        /// A comment was posted on a pull request's conversation.
        case pullRequestCommentAdded
        /// A pull request was closed. `true` when a comment went out with it.
        case pullRequestClosed(withComment: Bool)
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

/// A sweep ran all the way to the end without failing.
///
/// The one payload in this file that describes no pull request, and that is exactly why it had to
/// exist. Every other case reports something the sweep *found*, so an account with nothing open
/// produced no event at all — and the app, which learned "we are in touch with GitHub" only from
/// those events, went on saying "Not synced yet" in the title bar for as long as the account
/// stayed quiet, while the engine was in fact sweeping every two minutes. "The sweep came back" is
/// a different fact from "the sweep found something", and only the engine can state it.
///
/// A struct rather than a bare `Date`, for ``SentMutation``'s reason: the payloads here are
/// flattened values, and a named type can gain a field later without every `case sweepCompleted`
/// pattern in the app having to be rewritten around it.
public struct SweepCompletion: Sendable, Hashable, Codable {
    /// When the sweep finished, read from the engine's own clock.
    ///
    /// Carried rather than left to the consumer's `Date()`, so the "Synced · 32 s ago" indicator
    /// counts from the moment the sweep actually came back rather than from the moment the main
    /// actor got round to the event.
    public var finishedAt: Date

    /// Creates a completion notice.
    /// - Parameter finishedAt: When the sweep finished.
    public init(finishedAt: Date) {
        self.finishedAt = finishedAt
    }
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
    /// A sweep finished without failing — **including** a sweep that found nothing.
    ///
    /// The only case a quiet cycle emits, and the only one that means "the local database is now
    /// as current as GitHub". See ``SweepCompletion`` for why that needed saying out loud.
    case sweepCompleted(SweepCompletion)
    /// A sync step failed.
    case syncFailed(SyncFailure)
}
