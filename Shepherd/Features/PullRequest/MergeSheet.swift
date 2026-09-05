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
                .foregroundStyle(Theme.textSecondary)
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
                .keyboardShortcut(.defaultAction)
                .disabled(summary.mergeable == .conflicting)
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

    private var warning: String? {
        switch summary.mergeable {
        case .conflicting:
            return String(localized: "GitHub reports conflicts with \(summary.baseRefName). Resolve them first.")
        case .unknown, nil:
            return String(localized: "GitHub has not finished computing mergeability. The merge may be refused.")
        case .mergeable:
            if summary.checkRollup?.state == .failure {
                return String(localized: "Checks are failing on the head commit.")
            }
            if summary.checkRollup?.state == .pending {
                return String(localized: "Checks are still running.")
            }
            return nil
        }
    }
}
