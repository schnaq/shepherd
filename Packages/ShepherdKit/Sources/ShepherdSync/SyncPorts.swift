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
