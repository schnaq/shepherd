import GitHubKit
import ShepherdCore
import SwiftUI

/// The merge confirmation on the phone (ADR 0044) — the Mac's `MergeSheet`, as a sheet with
/// detents.
///
/// Merging is the one action Shepherd cannot undo, so it keeps a confirmation step here too. The
/// rules are the Mac sheet's, read off the same values: the method and the delete-branch box write
/// straight through to ``AppSettings`` (ADR 0015), a stacked pull request says what else the merge
/// takes along and leaves its branches to GitHub (ADR 0042), and the warning is the Mac's sentence
/// in the Mac's order — at the top here, where the medium detent keeps it in view. *Merge when
/// checks pass* is not offered: that coordinator only runs while the Mac app is running
/// (ADR 0037), and the phone does not sweep in the background.
struct PhoneMergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The pull request to merge.
    let summary: PullRequestSummary
    /// The freshest CI state the presenting screen knows (``ReviewModel/checkRollup``).
    let checkState: CheckRollup.State?
    /// The outbox-backed write actions.
    let actions: PullRequestActions
    /// Where the remembered merge method and branch answer live.
    let settings: AppSettings
    /// The pull request's stack as far as the inbox holds it, when it is in one.
    var stack: PullRequestStackOverview?
    /// Called once the merge is queued.
    var onMerged: (@MainActor () -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.title)
                            .font(Theme.type(.headline))
                            .foregroundStyle(Theme.textStrong)
                            .lineLimit(3)
                        Text(verbatim: "\(summary.headRefName) → \(summary.baseRefName)")
                            .font(Theme.mono(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    // A merge of an upper stack member merges every pull request below it too, so
                    // this says what that means before the tap (ADR 0042).
                    if let alsoMerges = stack?.alsoMergesSentence {
                        Label(alsoMerges, systemImage: "square.stack.3d.up")
                            .font(Theme.type(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                // Right under the title, so red CI is on screen at the medium detent beside the
                // green Merge rather than below the fold.
                if let warning {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(Theme.type(.subheadline))
                            .foregroundStyle(summary.mergeBlocker != nil || checkState == .failure ? Theme.failure : Theme.pending)
                    }
                }

                Section {
                    MergeMethodPicker(settings: settings)
                }

                Section {
                    Toggle(String(localized: "Delete the branch afterwards"), isOn: deletesBranchBinding)
                        .disabled(isStacked)
                } footer: {
                    Text(isStacked
                        ? String(localized: "GitHub manages the branches of a stack, so Shepherd leaves them alone.")
                        : String(localized: "Removes the head branch once the merge has landed. Skipped for forks and for a repository's default branch."))
                }

            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(String(localized: "Merge"))
            .navigationSubtitle(summary.slug)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                }
                // The sheet's confirmation, where iOS puts one: always in reach at the medium
                // detent, which a button at the end of the form would not be.
                ToolbarItem(placement: .confirmationAction) {
                    mergeButton
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The green Merge — the only green on the sheet (ADR 0040). A second press while
    /// the first is being written is refused by the guard and by ``ActionActivity`` behind it.
    private var mergeButton: some View {
        Button {
            guard !isMerging else { return }
            let method = settings.defaultMergeMethod
            let deletesBranch = deletesBranchForThisMerge
            Task {
                let queued = await actions.merge(summary, method: method, deletesHeadBranch: deletesBranch)
                dismiss()
                if queued { onMerged?() }
            }
        } label: {
            Text(String(localized: "Merge"))
                .busyLabel(isBusy: isMerging)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.success)
        .disabled(summary.mergeBlocker != nil)
    }

    private var isMerging: Bool { actions.activity.isRunning(summary.id, .merge) }

    /// The remembered branch answer, written straight through; off and disabled for a stack.
    private var deletesBranchBinding: Binding<Bool> {
        Binding(
            get: { deletesBranchForThisMerge },
            set: { if !isStacked { settings.deletesBranchAfterMerge = $0 } }
        )
    }

    private var isStacked: Bool { summary.stack != nil }

    private var deletesBranchForThisMerge: Bool {
        isStacked ? false : settings.deletesBranchAfterMerge
    }

    /// The one thing worth reading before merging, worst first — the Mac sheet's sentence and order:
    /// a refusal first, in the write funnel's own words, then unknown mergeability, then failing and
    /// running checks, which a reviewer may knowingly merge past.
    private var warning: String? {
        if let blocker = summary.mergeBlocker {
            return PullRequestActions.blockerMessage(blocker, slug: summary.slug)
        }
        switch summary.mergeable {
        case .conflicting:
            return nil
        case .unknown, nil:
            return String(localized: "GitHub has not finished computing mergeability. The merge may be refused.")
        case .mergeable:
            if checkState == .failure { return String(localized: "Checks are failing on the head commit.") }
            if checkState == .pending { return String(localized: "Checks are still running.") }
            return nil
        }
    }
}
