import AppKit
import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence

/// Every write Shepherd performs, funnelled through the persisted outbox.
///
/// ADR 0006 is explicit: outbound mutations are written to SQLite first and executed by the
/// sync engine, so an approval survives a crash, a quit or a tunnel. Nothing here calls
/// `GitHubClient` directly for a mutation that the outbox models.
@MainActor
struct PullRequestActions {
    /// The active session.
    let session: SignedInSession
    /// Where failures are surfaced.
    let toasts: ToastCenter

    // MARK: - Reviews

    /// Submits (or queues) a review for a pull request.
    ///
    /// An existing local draft is reused so a queued verdict never throws away inline comments
    /// the user already wrote.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - verdict: Approve, request changes, or comment.
    ///   - body: The review summary text.
    func submitReview(
        on summary: PullRequestSummary,
        verdict: ReviewVerdict,
        body: String = ""
    ) async {
        do {
            let existing = try await session.database.fetchDraft(prID: summary.id)
            var draft = existing ?? ReviewDraft(
                prID: summary.id,
                basedOnHeadOid: summary.headRefOid
            )
            draft.verdict = verdict
            if !body.isEmpty { draft.summaryBody = body }
            draft.updatedAt = Date()
            if draft.basedOnHeadOid.isEmpty {
                draft.basedOnHeadOid = summary.headRefOid
            }
            try await session.database.saveDraft(draft)
            try await enqueue(.submitReview(draft), on: summary)
            toasts.success(confirmation(for: verdict, summary: summary))
        } catch {
            toasts.failure(error, context: String(localized: "Could not queue the review"))
        }
    }

    /// Replies to an existing review comment.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - commentDatabaseID: The REST database id of the comment being replied to.
    ///   - body: The reply text.
    func reply(
        on summary: PullRequestSummary,
        commentDatabaseID: Int,
        body: String
    ) async {
        do {
            try await enqueue(
                .replyToComment(commentDatabaseID: commentDatabaseID, body: body),
                on: summary
            )
            toasts.success(String(localized: "Reply queued."))
        } catch {
            toasts.failure(error, context: String(localized: "Could not queue the reply"))
        }
    }

    /// Resolves or unresolves a review thread.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - threadID: The thread's GraphQL node id.
    ///   - resolved: The state to move to.
    func setThread(
        on summary: PullRequestSummary,
        threadID: String,
        resolved: Bool
    ) async {
        do {
            try await enqueue(
                resolved ? .resolveThread(threadID: threadID) : .unresolveThread(threadID: threadID),
                on: summary
            )
            toasts.success(
                resolved
                    ? String(localized: "Thread resolved.")
                    : String(localized: "Thread reopened.")
            )
        } catch {
            toasts.failure(error, context: String(localized: "Could not update the thread"))
        }
    }

    // MARK: - Merge

    /// Merges a pull request.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - method: Merge, squash or rebase.
    func merge(_ summary: PullRequestSummary, method: MergeMethod) async {
        do {
            try await enqueue(
                .merge(method: method.rawValue, expectedHeadOid: summary.headRefOid),
                on: summary
            )
            toasts.success(String(localized: "Merge queued for \(summary.slug)."))
        } catch {
            toasts.failure(error, context: String(localized: "Could not queue the merge"))
        }
    }

    /// Takes a pull request out of draft state.
    /// - Parameter summary: The pull request.
    func markReadyForReview(_ summary: PullRequestSummary) async {
        do {
            try await enqueue(.markReadyForReview, on: summary)
            toasts.success(String(localized: "Marked ready for review."))
        } catch {
            toasts.failure(error, context: String(localized: "Could not update the pull request"))
        }
    }

    // MARK: - Local conveniences

    /// Opens the pull request on github.com.
    /// - Parameter summary: The pull request.
    func openOnGitHub(_ summary: PullRequestSummary) {
        NSWorkspace.shared.open(
            AppConfig.pullRequestURL(
                owner: summary.repo.owner,
                name: summary.repo.name,
                number: summary.number
            )
        )
    }

    /// Copies the head branch name to the pasteboard.
    /// - Parameter summary: The pull request.
    func copyBranch(_ summary: PullRequestSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary.headRefName, forType: .string)
        toasts.info(String(localized: "Copied \(summary.headRefName)"))
    }

    /// Marks a file viewed (or not) for the current head commit.
    /// - Parameters:
    ///   - path: The file path.
    ///   - summary: The pull request.
    ///   - isViewed: The new state.
    func setFileViewed(path: String, on summary: PullRequestSummary, isViewed: Bool) async {
        do {
            try await session.database.setFileViewed(
                prID: summary.id,
                path: path,
                headRefOid: summary.headRefOid,
                isViewed: isViewed
            )
        } catch {
            toasts.failure(error, context: String(localized: "Could not save the viewed state"))
        }
    }

    // MARK: - Plumbing

    private func enqueue(_ action: OutboxAction, on summary: PullRequestSummary) async throws {
        try await session.database.enqueue(
            OutboxItem(
                prID: summary.id,
                repo: summary.repo,
                number: summary.number,
                action: action
            )
        )
        await session.drainOutbox()
    }

    private func confirmation(
        for verdict: ReviewVerdict,
        summary: PullRequestSummary
    ) -> String {
        switch verdict {
        case .approve: return String(localized: "Approved \(summary.slug).")
        case .requestChanges: return String(localized: "Requested changes on \(summary.slug).")
        case .comment: return String(localized: "Review comment queued for \(summary.slug).")
        }
    }
}
