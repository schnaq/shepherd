import GitHubKit
import ShepherdCore
import SwiftUI

/// The one confirmation step of bulk triage (ADR 0015).
///
/// Everything a bulk run will do is on this sheet and nowhere else: which pull requests are
/// included, which are left out and why, and — when the run merges — with which method. It is
/// the merge sheet's argument scaled up: a batch of writes is not undoable, so it keeps a
/// confirmation instead of the undo toast the reversible actions use.
struct BulkTriageSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The partition to confirm, rebuilt by the caller from the current ticks.
    let plan: BulkTriagePlan
    /// The outbox-backed write actions.
    let actions: PullRequestActions
    /// Where the remembered merge method lives.
    let settings: AppSettings
    /// Called after the writes are queued, so the caller can drop its ticks.
    var onQueued: @MainActor @Sendable () -> Void

    @State private var isQueueing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if plan.action.includesMerge {
                MergeMethodPicker(settings: settings)
            }
            entryList
            note
            footer
        }
        .padding(20)
        .frame(width: 560)
        .background(Theme.panel)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.action.confirmationTitle(count: plan.eligible.count))
                .font(Theme.type(.title3, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text(plan.action.explanation)
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The partition

    private var entryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !plan.eligible.isEmpty {
                    section(
                        title: String(localized: "WILL BE QUEUED (\(plan.eligible.count))"),
                        entries: plan.eligible
                    )
                }
                if !plan.skipped.isEmpty {
                    section(
                        title: String(localized: "SKIPPED (\(plan.skipped.count))"),
                        entries: plan.skipped
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
    }

    private func section(title: String, entries: [BulkTriagePlan.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(title)
            ForEach(entries) { entry in
                BulkTriageRowView(entry: entry)
            }
        }
    }

    private var note: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "tray.and.arrow.up")
                .foregroundStyle(Theme.textMuted)
            Text(String(
                localized: "Each pull request is queued separately in the outbox and sent one by one, with the same staleness check as a single review. A pull request whose head moved on is parked as a conflict instead of being written blind."
            ))
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.type(.subheadline))
        .foregroundStyle(Theme.textMuted)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button {
                queue()
            } label: {
                Text(plan.action.confirmButtonTitle)
            }
            .buttonStyle(SuccessButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(isQueueing || !plan.isActionable)
        }
    }

    private func queue() {
        guard !isQueueing else { return }
        isQueueing = true
        let method = settings.defaultMergeMethod
        Task {
            await actions.queue(plan, method: method)
            onQueued()
            dismiss()
        }
    }
}

/// One pull request on the bulk-triage sheet, with the state the decision was made on.
struct BulkTriageRowView: View {
    /// The entry to render.
    let entry: BulkTriagePlan.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CheckDotView(state: entry.pullRequest.checkRollup?.state)
            Text(entry.pullRequest.slug)
                .font(Theme.mono(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .layoutPriority(1)
            Text(entry.pullRequest.title)
                .font(Theme.type(.callout))
                .foregroundStyle(entry.isEligible ? Theme.text : Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            ForEach(chips, id: \.text) { chip in
                ChipView(text: chip.text, color: chip.color, size: 10)
                    .layoutPriority(1)
            }
        }
        .frame(minHeight: 22)
        .opacity(entry.isEligible ? 1 : 0.75)
        .help(helpText)
    }

    /// Review state first, then what the run will (not) do with the row.
    private var chips: [(text: String, color: Color)] {
        var result: [(text: String, color: Color)] = []
        if let decision = entry.pullRequest.reviewDecision {
            result.append((decision.chipTitle, decision.chipColor))
        }
        if let reason = entry.skipReason {
            result.append((reason.chipTitle, Theme.pending))
            return result
        }
        result.append((entry.stepsTitle, Theme.success))
        for caveat in entry.caveats {
            result.append((caveat.chipTitle, Theme.pending))
        }
        return result
    }

    private var helpText: String {
        if let reason = entry.skipReason { return reason.explanation }
        return entry.caveats.map(\.explanation)
            .joined(separator: "\n")
    }
}

// MARK: - Localized labels

extension BulkTriageAction {
    /// The sheet's title.
    /// - Parameter count: How many pull requests will actually be written.
    func confirmationTitle(count: Int) -> String {
        switch self {
        case .approve: return String(localized: "Approve \(count) pull requests")
        case .approveAndMerge: return String(localized: "Approve and merge \(count) pull requests")
        case .merge: return String(localized: "Merge \(count) pull requests")
        }
    }

    /// The one line under the title.
    var explanation: String {
        switch self {
        case .approve:
            return String(localized: "Queues an approving review with no comment on each of them.")
        case .approveAndMerge:
            return String(localized: "Queues an approving review and, behind it, the merge — in that order, so a branch-protection rule that needs the approval sees it first.")
        case .merge:
            return String(localized: "Queues a merge for each pull request that already carries an approval.")
        }
    }

    /// The confirm button.
    var confirmButtonTitle: String {
        switch self {
        case .approve: return String(localized: "Approve")
        case .approveAndMerge: return String(localized: "Approve & merge")
        case .merge: return String(localized: "Merge")
        }
    }

    /// The menu, palette and context-menu label.
    var commandTitle: String {
        switch self {
        case .approve: return String(localized: "Approve selected…")
        case .approveAndMerge: return String(localized: "Approve & merge selected…")
        case .merge: return String(localized: "Merge selected…")
        }
    }

    /// An SF Symbol for the palette row.
    var systemImage: String {
        switch self {
        case .approve: return "checkmark.circle"
        case .approveAndMerge: return "checkmark.circle.badge.checkmark"
        case .merge: return "arrow.triangle.merge"
        }
    }
}

extension BulkTriagePlan.Entry {
    /// What the run will write for this entry, as a chip.
    var stepsTitle: String {
        if steps.contains(.approve), steps.contains(.merge) {
            return String(localized: "approve + merge")
        }
        if steps.contains(.merge) { return String(localized: "merge") }
        return String(localized: "approve")
    }
}

extension BulkTriageSkipReason {
    /// The chip text.
    var chipTitle: String {
        switch self {
        case .draft: return String(localized: "skipped · draft")
        case .conflicting: return String(localized: "skipped · conflicts")
        case .checksFailing: return String(localized: "skipped · checks failing")
        case .checksRunning: return String(localized: "skipped · checks running")
        case .changesRequested: return String(localized: "skipped · changes requested")
        case .ownPullRequest: return String(localized: "skipped · your own")
        case .alreadyApproved: return String(localized: "skipped · already approved")
        case .notApproved: return String(localized: "skipped · not approved")
        }
    }

    /// The tooltip.
    var explanation: String {
        switch self {
        case .draft:
            return String(localized: "A draft pull request is not ready to be reviewed or merged.")
        case .conflicting:
            return String(localized: "GitHub reports conflicts with the base branch. Resolve them first.")
        case .checksFailing:
            return String(localized: "At least one check on the head commit failed.")
        case .checksRunning:
            return String(localized: "Checks are still running, so there is no green to act on yet.")
        case .changesRequested:
            return String(localized: "A reviewer asked for changes. Bulk triage will not overrule that.")
        case .ownPullRequest:
            return String(localized: "GitHub refuses an approval on a pull request you opened yourself.")
        case .alreadyApproved:
            return String(localized: "Already approved — a second approving review would change nothing.")
        case .notApproved:
            return String(localized: "Not approved yet. Use “Approve & merge selected” instead.")
        }
    }
}

extension BulkTriageCaveat {
    /// The chip text.
    var chipTitle: String {
        switch self {
        case .noChecksConfigured: return String(localized: "no checks")
        case .mergeabilityUnknown: return String(localized: "mergeability unknown")
        case .staleDraftComments: return String(localized: "draft comments on an older commit")
        }
    }

    /// The tooltip.
    var explanation: String {
        switch self {
        case .noChecksConfigured:
            return String(localized: "The head commit has no checks at all, so there is nothing green to rely on.")
        case .mergeabilityUnknown:
            return String(localized: "GitHub has not finished computing mergeability. The merge may be refused and will then be retried.")
        case .staleDraftComments:
            return String(localized: "You have a local draft whose inline comments were written on an older commit. The approval keeps that draft, so it will be parked as a conflict rather than sent — open the pull request to check the comments against the new commit.")
        }
    }
}
