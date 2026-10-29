import Foundation
import ShepherdCore

extension OutboxAction {
    /// What one queued write would have done, in the user's words.
    ///
    /// An exhaustive switch over the action rather than its `kind` discriminator: that string is
    /// a database column and a log token ("markReadyForReview"), and a settings screen is not the
    /// place to read one. A case added to the action is a compile error here, which is the point.
    /// Shared by the Mac's sync settings and the phone's settings screen (ADR 0044), so the German
    /// carries over and a new case is one edit.
    var localizedName: String {
        switch self {
        case .submitReview: return String(localized: "Submit review")
        case .replyToComment: return String(localized: "Reply")
        case .addReviewComment: return String(localized: "Comment on a line")
        case .resolveThread: return String(localized: "Resolve")
        case .unresolveThread: return String(localized: "Unresolve")
        case .merge: return String(localized: "Merge")
        case .markReadyForReview: return String(localized: "Mark ready for review")
        case .updateBranch: return String(localized: "Update branch")
        case .addIssueComment: return String(localized: "Comment on an issue")
        case .addIssueLabel: return String(localized: "Add a label")
        case .addIssueAssignee: return String(localized: "Add an assignee")
        case .closeIssue: return String(localized: "Close an issue")
        case .reopenIssue: return String(localized: "Reopen an issue")
        case .addPullRequestComment: return String(localized: "Comment on a pull request")
        case .closePullRequest(let comment):
            return comment == nil
                ? String(localized: "Close a pull request")
                : String(localized: "Comment and close")
        case .react(_, _, let adding):
            // Two names for the two directions: an add and a removal are two different things to
            // re-send or discard.
            return adding ? String(localized: "Add a reaction") : String(localized: "Remove a reaction")
        case .editComment: return String(localized: "Edit a comment")
        case .deleteComment: return String(localized: "Delete a comment")
        }
    }
}

extension OutboxItem {
    /// Whether this is a parked review: the one parked write *Send anyway* applies to, and the
    /// one whose *Discard* also deletes the user's draft, so it asks first (ADR 0006's 2026-10-29
    /// amendment).
    var isParkedReview: Bool {
        guard state == .conflicted, case .submitReview = action else { return false }
        return true
    }

    /// Why a parked or failed write is stuck, in the user's words. A parked row's stored reason
    /// names two commit SHAs, so it is said rather than shown; a failed row says what GitHub said.
    var unsentReason: String {
        guard state == .conflicted else {
            return localizedLastError ?? String(localized: "No reason was recorded.")
        }
        if action.targetsIssue {
            return String(localized: "The issue changed after you queued this.")
        }
        switch action {
        case .submitReview:
            return String(localized: "New commits arrived after you wrote this review.")
        case .merge:
            return String(localized: "New commits arrived after you chose to merge. Look at them, then merge again.")
        case .updateBranch:
            return String(localized: "New commits arrived before the branch could be updated.")
        default:
            return String(localized: "The pull request changed after you queued this.")
        }
    }
}
