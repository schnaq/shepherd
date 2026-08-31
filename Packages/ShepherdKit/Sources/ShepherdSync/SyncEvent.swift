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
    /// A sync step failed.
    case syncFailed(SyncFailure)
}
