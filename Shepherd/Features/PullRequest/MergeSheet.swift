import GitHubKit
import ShepherdCore
import SwiftUI

/// The merge confirmation sheet (`m`).
///
/// Merging is the one action Shepherd cannot undo, so it is the one action that keeps a
/// confirmation step instead of the undo toast used everywhere else.
struct MergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The pull request to merge.
    let summary: PullRequestSummary
    /// The freshest CI state the presenting screen knows.
    ///
    /// Handed in rather than read off ``summary``: the review screen has the head commit's actual
    /// check runs and the inbox row only carries the rollup the search sweep returned, so a sheet
    /// that read `summary.checkRollup` would warn about a red suite the screen behind it already
    /// shows as green (ADR 0005 — the rollup is the cheap half, the runs are the detail fetch).
    let checkState: CheckRollup.State?
    /// The outbox-backed write actions.
    let actions: PullRequestActions
    /// Where the remembered merge method lives, shared with the bulk-triage dialog (ADR 0015).
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Merge \(summary.slug)"))
                    .font(Theme.type(.title3, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                Text(summary.title)
                    .font(Theme.type(.callout))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(summary.headRefName) → \(summary.baseRefName)")
                    .font(Theme.mono(.subheadline))
                    .foregroundStyle(Theme.textMuted)
            }

            MergeMethodPicker(settings: settings)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    String(localized: "Delete the branch afterwards"),
                    isOn: deletesBranchBinding
                )
                Text(String(
                    localized: "Removes the head branch once the merge has landed. Skipped for forks and for a repository's default branch."
                ))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let warning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.pending)
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.pending)
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    let method = settings.defaultMergeMethod
                    let deletesBranch = settings.deletesBranchAfterMerge
                    Task {
                        await actions.merge(
                            summary,
                            method: method,
                            deletesHeadBranch: deletesBranch
                        )
                        dismiss()
                    }
                } label: {
                    Text(String(localized: "Merge"))
                }
                .buttonStyle(SuccessButtonStyle())
                // ⏎ merges only when there is nothing to read first. A sheet that says "this is
                // still a draft" and answers Return with a merge is a sheet whose warning nobody
                // has to look at; with the shortcut gone the reviewer has to aim at the button.
                .keyboardShortcut(warning == nil ? .defaultAction : nil)
                .disabled(summary.mergeBlocker != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.panel)
    }

    /// The remembered answer, written straight through the way ``MergeMethodPicker`` writes the
    /// method: the box is sticky rather than a per-merge choice, because "delete the branch" is
    /// nearly always a habit rather than a decision (ADR 0015's argument for the method).
    ///
    /// The two guards the deletion is subject to — a fork's branch is not ours, and a
    /// repository's default branch is never a leftover — are *not* checked here, and the
    /// footnote says so instead of the box going grey. Nothing the sheet can see answers either
    /// question: ``ShepherdCore/PullRequestSummary`` carries the branch's name but not the
    /// repository it lives in, and no part of Shepherd knows a repository's default branch. The
    /// drain reads both from GitHub at the moment it would delete, which is also the only place
    /// they are still true — a pull request can be re-targeted between this click and the sweep
    /// that drains it (ADR 0005's 2026-09-05 amendment).
    private var deletesBranchBinding: Binding<Bool> {
        Binding(
            get: { settings.deletesBranchAfterMerge },
            set: { settings.deletesBranchAfterMerge = $0 }
        )
    }

    /// The one thing worth reading before merging, worst first.
    ///
    /// Draft leads, because it is the only one of the four GitHub refuses outright and the
    /// sheet used not to mention it at all — a draft merge went through this button, into the
    /// outbox, and came back as a failed write. Conflicts and unknown mergeability follow;
    /// failing and running checks are last, because they are the two the reviewer may knowingly
    /// merge past.
    private var warning: String? {
        if summary.isDraft {
            return String(localized: "This pull request is still a draft. GitHub will refuse the merge.")
        }
        switch summary.mergeable {
        case .conflicting:
            return String(localized: "GitHub reports conflicts with \(summary.baseRefName). Resolve them first.")
        case .unknown, nil:
            return String(localized: "GitHub has not finished computing mergeability. The merge may be refused.")
        case .mergeable:
            if checkState == .failure {
                return String(localized: "Checks are failing on the head commit.")
            }
            if checkState == .pending {
                return String(localized: "Checks are still running.")
            }
            return nil
        }
    }
}
