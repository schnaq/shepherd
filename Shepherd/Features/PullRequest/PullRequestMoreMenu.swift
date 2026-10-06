import ShepherdCore
import SwiftUI

/// The rarer errands on one pull request — the ⋯ menu beside the verdicts in the inbox panel and
/// the review toolbar, and the middle of the inbox list's row menu.
///
/// One list in three places, so a new errand cannot reach one surface and miss the others. What
/// a pull request is *for* — a verdict, a merge — stays outside as buttons; this is everything a
/// reviewer does now and then. *Ready for review* and *Update branch* only appear when they would
/// do something, rather than sitting disabled in every menu for every pull request.
struct PullRequestMoreMenuItems: View {
    /// The pull request the errands act on.
    let summary: PullRequestSummary
    /// The outbox-backed write actions.
    let actions: PullRequestActions
    /// Opens the conversation composer, or `nil` where the surface has none (the list's row
    /// menu, whose panel beside it does).
    var onComment: (() -> Void)?
    /// Asks the close confirmation. Each surface owns its alert.
    var onClose: () -> Void

    var body: some View {
        if let onComment {
            Button(String(localized: "Comment…"), action: onComment)
        }
        if summary.isDraft {
            Button(String(localized: "Mark ready for review")) {
                Task { await actions.markReadyForReview(summary) }
            }
        }
        if summary.mergeStateStatus == .behind {
            Button(String(localized: "Update branch")) {
                Task { _ = await actions.updateBranch(summary) }
            }
        }
        Divider()
        Button(String(localized: "Open on GitHub")) { actions.openOnGitHub(summary) }
        Button(String(localized: "Copy branch name")) { actions.copyBranch(summary) }
        Divider()
        Button(String(localized: "Close pull request…"), role: .destructive, action: onClose)
    }
}

/// The ⋯ button that opens ``PullRequestMoreMenuItems``.
struct PullRequestMoreMenu: View {
    let summary: PullRequestSummary
    let actions: PullRequestActions
    var onComment: () -> Void
    var onClose: () -> Void

    var body: some View {
        Menu {
            PullRequestMoreMenuItems(
                summary: summary,
                actions: actions,
                onComment: onComment,
                onClose: onClose
            )
        } label: {
            Label(String(localized: "More"), systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help(String(localized: "Comment, close and more"))
        .accessibilityLabel(Text(String(localized: "More actions")))
    }
}
