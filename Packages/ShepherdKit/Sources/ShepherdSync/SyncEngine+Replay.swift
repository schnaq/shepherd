import Foundation
import ShepherdCore

/// Idempotent replay of the writes GitHub cannot deduplicate.
///
/// A `POST` whose answer was lost — the app suspended or killed mid-request, a timeout, a 5xx —
/// may or may not have landed. The claim counts the attempt *before* the request leaves, a
/// relaunch keeps that count, and a release of a row that never left takes it back, so a claimed
/// row with `attemptCount > 1` is exactly a row an earlier attempt may have delivered. Only then
/// is the pull request read, and a post by the viewer that says the same thing since the row was
/// queued means the write is done. The first attempt never reads anything.
extension SyncEngine {
    /// The thrown answer when the read that decides cannot say: the row is retried, never sent
    /// blind.
    struct ReplayUndecided: Error, CustomStringConvertible {
        var description: String
    }

    /// How far before the row's `createdAt` a post still counts — the device clock against
    /// GitHub's.
    static let replayClockSkew: TimeInterval = 300

    /// Whether an earlier attempt of `item` already landed on GitHub.
    ///
    /// `false` for a first attempt and for every action that is safe to send twice (or is
    /// decided by a read of its own, like a merge or a reaction removal).
    func previousAttemptLanded(_ item: OutboxItem) async throws -> Bool {
        guard item.attemptCount > 1, Self.replayNeedsProbe(item.action) else { return false }
        guard let viewer = configuration.viewerLogin, !viewer.isEmpty else {
            throw ReplayUndecided(description: "Cannot tell whether an earlier attempt landed: no signed-in login")
        }
        let detail = try await github.pullRequestDetail(repo: item.repo, number: item.number)
        guard let landed = Self.landed(
            item.action,
            in: detail,
            viewer: viewer,
            since: item.createdAt.addingTimeInterval(-Self.replayClockSkew)
        ) else {
            throw ReplayUndecided(description: "GitHub did not return the conversation")
        }
        return landed
    }

    static func replayNeedsProbe(_ action: OutboxAction) -> Bool {
        switch action {
        case .submitReview, .replyToComment, .addReviewComment, .addPullRequestComment:
            return true
        case .closePullRequest(let comment):
            return !(comment ?? "").isEmpty
        default:
            // Resolve/unresolve, reactions, merges, branch updates and the issue writes either
            // repeat harmlessly or are decided by a read of their own.
            return false
        }
    }

    /// The pure decision: does `detail` hold the viewer's post that `action` would create?
    /// `nil` when the part of the detail that decides was not read.
    static func landed(
        _ action: OutboxAction,
        in detail: PullRequestDetail,
        viewer: String,
        since cutoff: Date
    ) -> Bool? {
        func isViewer(_ actor: ShepherdCore.Actor) -> Bool {
            actor.login.caseInsensitiveCompare(viewer) == .orderedSame
        }
        func same(_ lhs: String, _ rhs: String) -> Bool {
            normalized(lhs) == normalized(rhs)
        }
        func threadComments() -> [(ReviewThread, ReviewComment)] {
            detail.threads.flatMap { thread in thread.comments.map { (thread, $0) } }
                .filter { isViewer($0.1.author) && $0.1.createdAt >= cutoff }
        }
        switch action {
        case .submitReview(let draft):
            guard let items = detail.conversation?.items else { return nil }
            let state: ConversationReview.State = switch draft.verdict {
            case .approve: .approved
            case .requestChanges: .changesRequested
            case .comment: .commented
            case nil: .pending
            }
            return items.contains {
                guard case .review(let review) = $0 else { return false }
                return isViewer(review.author) && review.createdAt >= cutoff
                    && review.state == state
                    && same(review.bodyMarkdown, draft.summaryBody)
                    && (draft.basedOnHeadOid.isEmpty || review.commitOid == draft.basedOnHeadOid)
            }
        case .addReviewComment(let comment, _):
            return threadComments().contains { $0.0.path == comment.path && same($0.1.bodyMarkdown, comment.body) }
        case .replyToComment(let parentID, let body):
            return threadComments().contains { thread, posted in
                thread.comments.contains { $0.databaseID == parentID } && same(posted.bodyMarkdown, body)
            }
        case .addPullRequestComment(let body), .closePullRequest(.some(let body)):
            guard let items = detail.conversation?.items else { return nil }
            return items.contains {
                guard case .comment(let posted) = $0 else { return false }
                return isViewer(posted.author) && posted.createdAt >= cutoff
                    && same(posted.bodyMarkdown, body)
            }
        default:
            return false
        }
    }

    static func normalized(_ body: String) -> String {
        body.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
