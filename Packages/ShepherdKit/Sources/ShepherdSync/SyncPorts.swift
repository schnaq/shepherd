import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence

/// The slice of ``GitHubKit/GitHubClient`` the sync engine uses.
///
/// Declaring it here — rather than depending on the concrete actor — is what lets the engine's
/// tests run against a scripted double with no network and no fixtures of their own.
public protocol PullRequestFetching: Sendable {
    /// Runs the inbox sweep.
    func searchOpenPullRequests(queries: [InboxQuery]) async throws -> [PullRequestSummary]
    /// Fetches one pull request in full.
    func pullRequestDetail(repo: RepoRef, number: Int) async throws -> PullRequestDetail
    /// Reads the current head commit of a pull request.
    func headRefOid(repo: RepoRef, number: Int) async throws -> String
    /// Polls the notifications endpoint.
    func notifications(
        since: Date?,
        lastModified: String?,
        participating: Bool
    ) async throws -> NotificationsPage
    /// Submits or parks a review.
    func submitReview(
        _ draft: ReviewDraft,
        repo: RepoRef,
        number: Int
    ) async throws -> SubmittedReview
    /// Replies to a review comment.
    func replyToComment(repo: RepoRef, number: Int, commentID: Int, body: String) async throws
    /// Resolves a review thread.
    func resolveThread(id: String) async throws
    /// Unresolves a review thread.
    func unresolveThread(id: String) async throws
    /// Merges a pull request.
    func mergePullRequest(
        repo: RepoRef,
        number: Int,
        method: MergeMethod,
        expectedHeadOid: String?,
        commitTitle: String?
    ) async throws -> String?
    /// Takes a pull request out of draft state.
    func markReadyForReview(pullRequestID: String) async throws
}

/// `GitHubClient` already has exactly this shape; the conformance is the contract check.
extension GitHubClient: PullRequestFetching {}

/// The slice of ``ShepherdPersistence/DatabaseManager`` the sync engine uses.
public protocol SyncStoring: Sendable {
    /// Stores the result of one sweep.
    func savePullRequestSummaries(
        _ summaries: [PullRequestSummary],
        pruneMissing: Bool
    ) async throws
    /// Reads the cached inbox — the "before" side of delta detection.
    func fetchInbox(filter: InboxFilter) async throws -> [PullRequestSummary]
    /// Stores a detail fetch.
    func savePullRequestDetail(_ detail: PullRequestDetail) async throws
    /// Reads a review draft.
    func fetchDraft(prID: String) async throws -> ReviewDraft?
    /// Deletes a review draft after it has been submitted.
    func deleteDraft(prID: String) async throws
    /// Claims the outbox rows that are due, moving them out of `pending` in the same
    /// transaction so two overlapping drains cannot send the same mutation twice.
    func claimReadyOutboxItems(now: Date, limit: Int) async throws -> [OutboxItem]
    /// Hands back rows that were claimed but never attempted.
    func releaseOutboxItems(ids: [UUID]) async throws
    /// Removes a sent outbox row.
    func markOutboxItemSucceeded(id: UUID) async throws
    /// Records a failed attempt and schedules a retry.
    func markOutboxItemFailed(id: UUID, error: String, now: Date, retriable: Bool) async throws
    /// Parks an outbox row that conflicts with the server state.
    func markOutboxItemConflicted(id: UUID, reason: String) async throws
    /// Reads a scalar sync-state value.
    func syncState(forKey key: String) async throws -> String?
    /// Writes a scalar sync-state value.
    func setSyncState(_ value: String?, forKey key: String) async throws
}

/// `DatabaseManager` already has exactly this shape; the conformance is the contract check.
extension DatabaseManager: SyncStoring {}

/// The slice of ``ShepherdPersistence/DatabaseManager`` that keeps the interdiff's baseline.
///
/// A port of its own rather than two more requirements on ``SyncStoring``, for two reasons: the
/// drain's snapshot hook is the *only* thing in the engine that writes it, so a test can hand
/// the engine a counting double while the store stays the real database; and an engine built
/// without one — which is every existing test — behaves exactly as it did before (ADR 0028).
public protocol ReviewSnapshotWriting: Sendable {
    /// Whether a baseline for one reviewed head is already stored.
    func hasReviewSnapshot(prID: String, reviewedHeadOid: String) async throws -> Bool
    /// Stores the pull request's current diff as the head that was reviewed.
    func captureReviewSnapshot(
        prID: String,
        reviewedHeadOid: String,
        reviewedAt: Date
    ) async throws -> Bool
}

/// `DatabaseManager` already has exactly this shape; the conformance is the contract check.
extension DatabaseManager: ReviewSnapshotWriting {}

/// The slice of ``ShepherdPersistence/DatabaseManager`` that keeps the track record (ADR 0027).
///
/// A port of its own for ``ReviewSnapshotWriting``'s two reasons: the sweep's capture is the
/// *only* thing in the engine that writes it, so a test can hand the engine a counting double
/// while the store stays the real database; and an engine built without one — which is every
/// existing test — behaves exactly as it did before.
public protocol OutcomeRecording: Sendable {
    /// Whether one pull request already has a stored outcome.
    func hasPullRequestOutcome(prID: String) async throws -> Bool
    /// Writes outcomes, replacing any row for the same pull request.
    func savePullRequestOutcomes(_ closed: [ClosedPullRequest]) async throws -> Int
    /// The stored merged pull requests a revert could be pointing at.
    func mergedClosedPullRequests(repo: RepoRef, since: Date) async throws -> [ClosedPullRequest]
    /// Records that some stored pull requests were reverted.
    func applyRevertLinks(_ links: [String: String]) async throws -> Int
}

/// `DatabaseManager` already has exactly this shape; the conformance is the contract check.
extension DatabaseManager: OutcomeRecording {}

/// The slice of ``GitHubKit/GitHubClient`` the track record reads through (ADR 0027).
///
/// Separate from ``PullRequestFetching`` rather than two more requirements on it, and
/// deliberately so: the inbox port is what the engine's loops need to *run*, and every double in
/// every test implements all of it. Two reads that only one optional feature makes belong behind
/// a protocol only that feature's tests have to satisfy.
public protocol ClosedPullRequestReading: Sendable {
    /// Reads the final state of one pull request by number.
    func closedPullRequest(repo: RepoRef, number: Int) async throws -> ClosedPullRequest?
    /// Reads one page of a repository's closed pull requests.
    func searchClosedPullRequests(
        repo: RepoRef,
        since: Date,
        cursor: String?,
        pageSize: Int
    ) async throws -> ClosedPullRequestPage
}

/// `GitHubClient` already has exactly this shape; the conformance is the contract check.
extension GitHubClient: ClosedPullRequestReading {}

/// The two ports the track record needs, handed to the engine as one value.
///
/// One initialiser parameter instead of two, because neither half is any use without the other:
/// an engine that could read a closed pull request but not store it would spend a request per
/// disappearance and throw the answer away.
public struct OutcomeCapture: Sendable {
    /// Where a closed pull request is read from.
    public let reader: any ClosedPullRequestReading
    /// Where the outcome is written.
    public let store: any OutcomeRecording

    /// Creates the pair.
    /// - Parameters:
    ///   - reader: The GitHub side.
    ///   - store: The database side.
    public init(reader: any ClosedPullRequestReading, store: any OutcomeRecording) {
        self.reader = reader
        self.store = store
    }
}
