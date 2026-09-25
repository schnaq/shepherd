import GitHubKit
import ShepherdCore
import SwiftUI

/// The one confirmation of a merge series (ADR 0041): which pull requests, in which order, how.
///
/// Built like a settings pane — a grouped `Form`, one section per repository — because it *is*
/// a small form: an ordered list per repository, one method and one branch answer for all of
/// them. Pressing **Start** is the only confirmation the series ever asks for, so everything it
/// will do is on this sheet: the order (dragged, pre-sorted smallest first by
/// ``ShepherdCore/MergeSeriesPlan``), what is left out and why, the method and the branch box.
struct MergeSeriesSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The plan, built by the caller from the ticks when the sheet opened.
    let plan: MergeSeriesPlan
    /// Where the shared merge method and branch answer live.
    let settings: AppSettings
    /// Called with the confirmed order when the user presses Start.
    var onStart: @MainActor ([(repository: RepoRef, pullRequests: [PullRequestSummary])], MergeMethod, Bool) -> Void

    /// The order per repository, as the user dragged it. Keyed by ``MergeSeriesPlan/Group/id``.
    @State private var order: [String: [PullRequestSummary]]

    /// Creates the sheet.
    init(
        plan: MergeSeriesPlan,
        settings: AppSettings,
        onStart: @escaping @MainActor ([(repository: RepoRef, pullRequests: [PullRequestSummary])], MergeMethod, Bool) -> Void
    ) {
        self.plan = plan
        self.settings = settings
        self.onStart = onStart
        _order = State(initialValue: Dictionary(
            plan.groups.map { ($0.id, $0.candidates) },
            uniquingKeysWith: { first, _ in first }
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(String(
                        localized: "Shepherd merges these one at a time. Before each merge it waits for the checks, and brings a branch that fell behind up to date first. Whatever cannot be merged is skipped, and the series goes on with the next."
                    ))
                    .font(Theme.type(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(plan.groups.filter(\.isActionable)) { group in
                    repositorySection(group)
                }

                if !excluded.isEmpty {
                    Section {
                        ForEach(excluded) { exclusion in
                            excludedRow(exclusion)
                        }
                    } header: {
                        Text(String(localized: "Excluded"))
                    }
                }

                Section {
                    MergeMethodPicker(settings: settings)
                    Toggle(isOn: deletesBranchBinding) {
                        Text(String(localized: "Delete the branch afterwards"))
                        Text(String(localized: "Removes each head branch once its merge has landed."))
                    }
                } footer: {
                    SettingsNote(String(
                        localized: "Nothing asks again after Start. A new push, a failed check or a conflict skips that pull request."
                    ))
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 560, height: 600)
    }

    // MARK: - Sections

    private func repositorySection(_ group: MergeSeriesPlan.Group) -> some View {
        Section {
            ForEach(Array((order[group.id] ?? []).enumerated()), id: \.element.id) { index, pullRequest in
                candidateRow(pullRequest, index: index, in: group)
            }
            .onMove { source, destination in
                order[group.id]?.move(fromOffsets: source, toOffset: destination)
            }
        } header: {
            Text(verbatim: group.repository.fullName)
        } footer: {
            SettingsNote(String(localized: "Drag to change the order. Smallest first causes the fewest conflicts."))
        }
    }

    private func candidateRow(
        _ pullRequest: PullRequestSummary,
        index: Int,
        in group: MergeSeriesPlan.Group
    ) -> some View {
        let count = order[group.id]?.count ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            CheckDotView(state: pullRequest.checkRollup?.state)
            // `verbatim`: a number after `#` must not be grouped into "#1.024" (check-localization
            // rule 5), and there is nothing to translate in it.
            Text(verbatim: "#\(pullRequest.number)")
                .font(Theme.mono(.callout))
                .foregroundStyle(.secondary)
            Text(pullRequest.title)
                .font(Theme.type(.body))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            lineCounts(pullRequest)
        }
        .contextMenu {
            // The same reorder without a drag, for the keyboard and for a trackpad that will not
            // start one inside a form.
            Button(String(localized: "Move up")) { move(group.id, from: index, by: -1) }
                .disabled(index == 0)
            Button(String(localized: "Move down")) { move(group.id, from: index, by: 1) }
                .disabled(index >= count - 1)
        }
    }

    private func lineCounts(_ pullRequest: PullRequestSummary) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(pullRequest.additions)")
                .foregroundStyle(Theme.success)
            Text(verbatim: "−\(pullRequest.deletions)")
                .foregroundStyle(Theme.failure)
        }
        .font(Theme.mono(.caption))
        .monospacedDigit()
        .accessibilityLabel(Text(DiffCountsView.spokenCounts(
            additions: pullRequest.additions,
            deletions: pullRequest.deletions
        )))
    }

    private func excludedRow(_ exclusion: MergeSeriesPlan.Exclusion) -> some View {
        LabeledContent {
            Text(exclusion.reason.title)
                .font(Theme.type(.callout))
                .foregroundStyle(.secondary)
        } label: {
            Text(exclusion.pullRequest.title)
                .lineLimit(1)
            Text(verbatim: exclusion.pullRequest.slug)
                .font(Theme.mono(.caption))
        }
        .help(exclusion.reason.explanation)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            // Green, as Merge is on every surface (ADR 0040's 2026-09-23 amendment): Start is
            // the merge decision for the whole series.
            Button(String(localized: "Start")) { start() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.success)
                .keyboardShortcut(.defaultAction)
                .disabled(!plan.isActionable)
        }
        .padding(16)
    }

    // MARK: - Actions

    private var excluded: [MergeSeriesPlan.Exclusion] {
        plan.groups.flatMap(\.excluded)
    }

    private var deletesBranchBinding: Binding<Bool> {
        Binding(
            get: { settings.deletesBranchAfterMerge },
            set: { settings.deletesBranchAfterMerge = $0 }
        )
    }

    private func move(_ groupID: String, from index: Int, by offset: Int) {
        guard var list = order[groupID] else { return }
        let target = index + offset
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        order[groupID] = list
    }

    private func start() {
        let groups = plan.groups.filter(\.isActionable).compactMap { group -> (repository: RepoRef, pullRequests: [PullRequestSummary])? in
            guard let pullRequests = order[group.id], !pullRequests.isEmpty else { return nil }
            return (repository: group.repository, pullRequests: pullRequests)
        }
        onStart(groups, settings.defaultMergeMethod, settings.deletesBranchAfterMerge)
        dismiss()
    }
}

// MARK: - Localized labels

extension MergeSeriesSheet {
    /// The menu, palette and context-menu label.
    static var commandTitle: String { String(localized: "Merge one after another…") }
}

extension MergeSeriesExclusionReason {
    /// The short reason on the sheet.
    var title: String {
        switch self {
        case .mergeOnItsWay: return String(localized: "merge already on its way")
        case .draft: return String(localized: "draft")
        case .conflicting: return String(localized: "conflicts")
        case .checksFailing: return String(localized: "checks failing")
        case .changesRequested: return String(localized: "changes requested")
        case .ownPullRequest: return String(localized: "your own")
        }
    }

    /// The tooltip.
    var explanation: String {
        switch self {
        case .mergeOnItsWay:
            return String(localized: "A merge is already queued, armed or part of another series.")
        case .draft:
            return String(localized: "A draft pull request is not ready to be reviewed or merged.")
        case .conflicting:
            return String(localized: "GitHub reports conflicts with the base branch. Resolve them first.")
        case .checksFailing:
            return String(localized: "At least one check on the head commit failed.")
        case .changesRequested:
            return String(localized: "A reviewer asked for changes. A series will not overrule that.")
        case .ownPullRequest:
            return String(localized: "Your own pull request is not merged by a series. Merge it yourself.")
        }
    }
}
