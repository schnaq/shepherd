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
    /// Where a merge decided on while the checks were still running is kept (ADR 0037).
    let mergeWhenGreen: MergeWhenGreenCoordinator
    /// The pull request's stack as far as the inbox holds it, when it is in one (ADR 0042) — for
    /// the line that says what else this merge takes along.
    var stack: PullRequestStackOverview?
    /// Called once the merge is queued, so a caller that was *showing* this pull request can go
    /// somewhere else. `nil` for the inbox, which is already where you would end up.
    var onMerged: (@MainActor () -> Void)?

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

            // A merge of an upper stack member merges every pull request below it too, and
            // there is no way to merge it alone — so the button stays *Merge*, and this says
            // what that means before the click rather than after (ADR 0042).
            if let alsoMerges = stack?.alsoMergesSentence {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(Theme.accentText)
                        .accessibilityHidden(true)
                    Text(alsoMerges)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textSecondary)
            }

            MergeMethodPicker(settings: settings)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    String(localized: "Delete the branch afterwards"),
                    isOn: deletesBranchBinding
                )
                .disabled(isStacked)
                Text(
                    isStacked
                        ? String(localized: "GitHub manages the branches of a stack, so Shepherd leaves them alone.")
                        : String(localized: "Removes the head branch once the merge has landed. Skipped for forks and for a repository's default branch.")
                )
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }

            if isArmed {
                armedStatus
            } else if let warning {
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
                if isArmed {
                    Button(String(localized: "Stop waiting")) {
                        mergeWhenGreen.disarm(pullRequestID: summary.id)
                        actions.toasts.success(
                            String(localized: "\(summary.slug) will not be merged when its checks pass.")
                        )
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else if offersMergeWhenGreen {
                    Button {
                        armMergeWhenGreen()
                    } label: {
                        Text(String(localized: "Merge when checks pass"))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    // ⇧⌘⏎: the deliberate keystroke's sibling, one modifier away from *Merge*.
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help(String(
                        localized: "Shepherd queues this merge on the first sweep that finds every check green on this commit — while the app is running. A new push or a failing check cancels it."
                    ))
                }
                Button {
                    let method = settings.defaultMergeMethod
                    let deletesBranch = deletesBranchForThisMerge
                    // Merging by hand supersedes a wait the sheet may be showing: the arm would
                    // otherwise fire behind this merge on the sweep that sees the checks go green,
                    // and be refused by the outbox's "one write in flight" rule rather than by
                    // anything that knew the user had already pressed the button.
                    mergeWhenGreen.disarm(pullRequestID: summary.id)
                    Task {
                        await actions.merge(
                            summary,
                            method: method,
                            deletesHeadBranch: deletesBranch
                        )
                        dismiss()
                        onMerged?()
                    }
                } label: {
                    Text(String(localized: "Merge"))
                }
                .buttonStyle(SuccessButtonStyle())
                // ⌘⏎ rather than ⏎, and always rather than only when the sheet has no warning.
                // Plain Return was refused while a warning stood, on the argument that a sheet
                // saying "this is still a draft" must not answer Return with a merge — which was
                // right about Return and wrong about the reviewer, who was then left aiming at a
                // button with the mouse. ⌘⏎ is the deliberate version of the same keystroke: it
                // is not what a stray Return does, so the warning keeps its job while the
                // keyboard keeps working.
                .keyboardShortcut(.return, modifiers: .command)
                // The one action Shepherd cannot undo is also the one where a second press is
                // worst, and ⏎ makes that easy to do by accident. ``busy`` disables as well as
                // spins, and `.disabled` takes the key with it, so the sheet stops answering
                // Return the moment the first merge is queueing.
                .busy(isMerging)
                .disabled(summary.mergeBlocker != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.panel)
    }

    /// Whether a merge decided on earlier is waiting for this commit's checks (ADR 0037).
    ///
    /// Read off the coordinator on every render rather than captured when the sheet opened: the
    /// store is `@Observable`, so a pass that fires the merge while the sheet is up turns the
    /// waiting line back into the ordinary buttons.
    private var isArmed: Bool { mergeWhenGreen.isArmed(summary) }

    /// Whether *Merge when checks pass* is on offer: nothing GitHub would refuse outright, and
    /// checks that are still running.
    ///
    /// Only while they run, not once one has failed. A red suite cannot go green without a re-run
    /// or a push — and a re-run makes it pending again, which is when the button comes back. A
    /// pull request with no checks has nothing to wait for, and the plain *Merge* is the honest
    /// button for it.
    private var offersMergeWhenGreen: Bool {
        summary.mergeBlocker == nil && checkState == .pending
    }

    /// The line the sheet shows instead of the warning while a merge is waiting for green.
    private var armedStatus: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(Theme.pending)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Waiting for the checks to pass. Shepherd will \(armedMethodName) this commit as soon as they are green — while the app is running."))
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "A new push or a failing check cancels it, with a notification."))
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.type(.callout))
        .foregroundStyle(Theme.textSecondary)
    }

    /// The verb for the method the arm was recorded with — the sheet's own at the time, which may
    /// differ from what the picker shows now.
    private var armedMethodName: String {
        let raw = mergeWhenGreen.request(forPullRequestID: summary.id)?.mergeMethod
        switch raw.flatMap(MergeMethod.init(rawValue:)) ?? settings.defaultMergeMethod {
        case .merge: return String(localized: "merge")
        case .squash: return String(localized: "squash-merge")
        case .rebase: return String(localized: "rebase-merge")
        }
    }

    /// Records the decision and leaves, the way a merge would.
    ///
    /// The method and the branch box are read now, because now is what the user is looking at.
    /// The focus session advances (``PullRequestActions/onDidQueueVerdict``) and the review screen
    /// goes away (``onMerged``) exactly as they do for *Merge*: the reviewer is finished with this
    /// pull request, and the rest is the sweep's.
    private func armMergeWhenGreen() {
        mergeWhenGreen.arm(
            summary,
            method: settings.defaultMergeMethod,
            deletesHeadBranch: deletesBranchForThisMerge
        )
        actions.toasts.success(
            String(localized: "\(summary.slug) will be merged once its checks pass.")
        )
        actions.onDidQueueVerdict?(summary.id)
        dismiss()
        onMerged?()
    }

    /// Whether the merge this sheet would queue is already on its way to the outbox.
    ///
    /// Read off the write helper's own tracker rather than a `@State` flag, so a merge started
    /// by `m` from the screen behind the sheet dims this button too.
    private var isMerging: Bool { actions.activity.isRunning(summary.id, .merge) }

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
    ///
    /// For a stacked pull request the box shows *off* and is disabled, and the remembered answer
    /// is left as it is for the next ordinary merge: GitHub re-targets the pull requests above a
    /// merged one onto its base itself and manages the stack's branches (ADR 0042), so a deletion
    /// of Shepherd's would at best be redundant and at worst pull a branch out from under it. The
    /// drain skips the follow-up for a stacked merge anyway; this keeps the sheet from promising
    /// one.
    private var deletesBranchBinding: Binding<Bool> {
        Binding(
            get: { isStacked ? false : settings.deletesBranchAfterMerge },
            set: { if !isStacked { settings.deletesBranchAfterMerge = $0 } }
        )
    }

    /// Whether the pull request is part of a GitHub stack, however far the inbox holds it.
    private var isStacked: Bool { summary.stack != nil }

    /// The branch answer this merge is queued with: the remembered one, except for a stack.
    private var deletesBranchForThisMerge: Bool {
        isStacked ? false : settings.deletesBranchAfterMerge
    }

    /// The one thing worth reading before merging, worst first.
    ///
    /// Draft leads, because it is the only one of the four GitHub refuses outright and the
    /// sheet used not to mention it at all — a draft merge went through this button, into the
    /// outbox, and came back as a failed write. Conflicts and unknown mergeability follow;
    /// failing and running checks are last, because they are the two the reviewer may knowingly
    /// merge past.
    ///
    /// The first two are ``ShepherdCore/PullRequestSummary/mergeBlocker``'s two cases, so the
    /// sheet reads them off it and says what the write funnel would have toasted
    /// (``PullRequestActions/blockerMessage(_:slug:)``) rather than writing a second sentence of
    /// its own. A refusal the app can name before the click is the same refusal here, in the
    /// same words, in the same fixed order — and there is then one place a reviewer's wording
    /// for "this is a draft" can be changed.
    private var warning: String? {
        if let blocker = summary.mergeBlocker {
            return PullRequestActions.blockerMessage(blocker, slug: summary.slug)
        }
        switch summary.mergeable {
        case .conflicting:
            // Unreachable: ``ShepherdCore/PullRequestSummary/mergeBlocker`` answered it above.
            return nil
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
