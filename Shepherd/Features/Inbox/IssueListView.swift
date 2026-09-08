import AppKit
import Foundation
import ShepherdCore
import SwiftUI

/// The centre pane while the issues section is showing: a flat, keyboard-driven issue list
/// (ADR 0032).
///
/// ``InboxListView``'s twin, with three things deliberately missing. There is no grouping and no
/// sort picker — nothing in the brief asks for one, and a second sort vocabulary beside
/// ``InboxSortOrder`` would be a decision nobody has made — and there is no tick column, because
/// bulk triage writes reviews (ADR 0015) and an issue has none. The order is the store's:
/// most-recently-updated first.
///
/// The keys it handles are `j`/`k` and the arrows, and it handles them the way the pull-request
/// list does: by raising ``ShortcutAction/selectNext``/``ShortcutAction/selectPrevious`` on the
/// container, which routes them to *the model that owns the current selection*. That is what
/// keeps one implementation of "move the cursor" and why switching the section cannot disturb the
/// pull-request list's own state — it is never told anything happened.
struct IssueListView: View {
    @Environment(AppEnvironment.self) private var environment
    /// The issues model.
    let model: IssueInboxModel
    /// Whether the keyboard belongs to this list, or to something drawn over it (⌘K's palette).
    ///
    /// ``InboxListView/isKeyboardOwner``'s twin, for its reason: the palette is an overlay rather
    /// than a sheet or a window, so macOS does not take focus away from the list for it, and this
    /// list answers `j` and the arrows exactly as the pull-request one does.
    let isKeyboardOwner: Bool

    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            list
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IssueShortcutBar()
        }
        .focusable(isKeyboardOwner)
        .focusEffectDisabled()
        .focused($isListFocused)
        .onKeyPress(phases: .down) { press in
            // ``InboxListView``'s two halves, for its reason: not being focusable stops the next
            // key from arriving here, and this stops the one already in flight.
            guard isKeyboardOwner else { return .ignored }
            return handle(press)
        }
        .onAppear { isListFocused = true }
        // And back again when the palette closes, with ``InboxListView``'s 60 ms hop and the same
        // argument: nothing else would return focus to a list that stopped being focusable.
        .onChange(of: isKeyboardOwner) { _, owner in
            guard owner else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                isListFocused = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(ContentKind.issues.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text(String(localized: "\(model.filteredRows.count) issues"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)

            if let label = activeFacetLabel {
                ChipView(text: label, color: Theme.accentText)
                Button {
                    model.clearFacets()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear filter"))
                .accessibilityLabel(Text(String(localized: "Clear filter")))
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(Theme.background)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if !model.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.allRows.isEmpty {
            // The two empty states are different claims and must not share a sentence: this one
            // says "the sweep found nothing", the one below says "your facets hid everything".
            EmptyStateView(
                systemImage: "smallcircle.circle",
                title: String(localized: "No issues yet"),
                message: String(
                    localized: "Issues assigned to you, opened by you or mentioning you land here on the next sweep. Press ⌘R to run one now."
                )
            )
        } else if model.visibleRows.isEmpty {
            EmptyStateView(
                systemImage: "line.3.horizontal.decrease.circle",
                title: String(localized: "Nothing matches these facets"),
                message: String(localized: "Clear them to see every issue again.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.visibleRows) { row in
                            IssueRowView(row: row, isSelected: model.selectedID == row.id)
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.select(row.id) }
                                .contextMenu { rowMenu(for: row) }
                        }
                    }
                }
                .onChange(of: model.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(for row: IssueRowSummary) -> some View {
        Button(String(localized: "Open on GitHub")) {
            NSWorkspace.shared.open(
                AppConfig.issueURL(
                    owner: row.repo.owner,
                    name: row.repo.name,
                    number: row.number
                )
            )
        }
        Button(String(localized: "Copy reference")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.slug, forType: .string)
            environment.toasts.info(String(localized: "Copied \(row.slug)"))
        }
    }

    // MARK: - Helpers

    /// The one chip the header shows for whichever facet is narrowing the list.
    ///
    /// The narrowest claim wins, exactly as ``InboxListView``'s does: a rail with a label *and* a
    /// repository selected is showing "this label, in this repository", and the surprising half
    /// of that sentence is the label.
    ///
    /// The state facet leads all four of them when it is showing closed issues, because that is
    /// the most surprising thing a list of triage work can be doing — and it is silent on the
    /// section's own default, and silent again when it has been widened to open *and* closed,
    /// since the rows in the list say which they are themselves.
    private var activeFacetLabel: String? {
        if let state = model.stateFilter, state == .closed { return state.facetTitle }
        if let label = model.labelFilter { return label }
        if let filter = model.agentPullRequestFilter { return filter.facetTitle }
        if let bucket = model.ageFilter { return bucket.facetTitle }
        if let repo = model.repoFilter { return repo.fullName }
        return nil
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.matches(.downArrow) {
            environment.request(.selectNext)
            return .handled
        }
        if press.matches(.upArrow) {
            environment.request(.selectPrevious)
            return .handled
        }
        if press.matches(.escape) {
            model.clearFacets()
            return .handled
        }
        guard press.modifiers.isEmpty, let character = press.characters.first else {
            return .ignored
        }
        // Only the two navigation keys, spelled out rather than run through
        // ``KeySequenceState``: every other sequence that machine knows (`r a`, `m`, `x`, `g r`)
        // is a pull-request verb, and consuming one here would report an action against a
        // selection the user is not looking at. Everything else travels on, which is what leaves
        // ⌘K, the menu bar and ⌘R working from this section unchanged.
        switch character {
        case "j":
            environment.request(.selectNext)
            return .handled
        case "k":
            environment.request(.selectPrevious)
            return .handled
        default:
            return .ignored
        }
    }
}

/// One issue row (ADR 0032).
///
/// A value renderer, like ``InboxRowView``: everything it draws comes from the row it was handed,
/// so the list depends on no coordinator and no database.
struct IssueRowView: View {
    /// The issue.
    let row: IssueRowSummary
    /// Whether it is the selected row.
    let isSelected: Bool
    /// How many labels are drawn before the rest become a `+n` chip.
    private static let visibleLabelCount = 2

    /// The row's spoken label: everything the row shows, in the order it shows it.
    ///
    /// ``InboxRowView/accessibilityText``'s reasoning, for the issues side: the combined label
    /// this replaces would have carried the state chip, the provenance, the agent glyph, the
    /// labels, the comment count and the age, and a label that says only the number and the
    /// title throws all six away. Every part is the value the row draws.
    private var accessibilityText: String {
        SpokenRow.sentence([
            row.state == .closed ? String(localized: "Closed") : nil,
            "\(row.slug): \(row.title)",
            ProvenanceChip.spokenProvenance(of: row.author),
            row.hasAgentPullRequest
                ? String(localized: "An agent has a pull request for this issue")
                : nil,
            // All of them, not the two the row has room for: the `+n` chip's tooltip says the
            // same thing, and a reader who cannot see the chip has no other way to the rest.
            row.labels.isEmpty ? nil : row.labels.joined(separator: ", "),
            row.commentCount > 0 ? String(localized: "\(row.commentCount) comments") : nil,
            String(localized: "opened \(RelativeDate.long(row.createdAt))"),
        ])
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(row.repo.name) #\(row.number)")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textMuted)
                .layoutPriority(1)

            Text(row.title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.textStrong : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)

            // The section can show closed rows since the state facet arrived (ADR 0032's
            // 2026-09-04 amendment), so a row that is one says so where the eye already is,
            // in the panel's and the ⌘K row's word for it rather than a third one.
            if row.state == .closed {
                ChipView(text: String(localized: "Closed"), color: Theme.textMuted, size: 10)
                    .layoutPriority(1)
            }

            // The unchanged chip, from the unchanged detector: an issue's author is produced by
            // the same `AgentDetector` the pull-request sweep uses (ADR 0008, ADR 0032).
            ProvenanceChip(actor: row.author)
                .layoutPriority(1)

            // Beside the provenance chip, because it says the same kind of thing about the row:
            // this one has already been handed to a machine.
            if row.hasAgentPullRequest {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.agent)
                    .layoutPriority(1)
                    .help(String(localized: "An agent has a pull request for this issue"))
                    .accessibilityLabel(
                        Text(String(localized: "An agent has a pull request for this issue"))
                    )
            }

            ForEach(row.labels.prefix(IssueRowView.visibleLabelCount), id: \.self) { label in
                // `ChipView`'s `text` is a plain `String`, so a label — somebody else's word —
                // never becomes a catalog key.
                ChipView(text: label, color: Theme.textSecondary, size: 10)
                    .layoutPriority(1)
            }
            if row.labels.count > IssueRowView.visibleLabelCount {
                ChipView(
                    text: "+\(row.labels.count - IssueRowView.visibleLabelCount)",
                    color: Theme.textMuted,
                    size: 10
                )
                .layoutPriority(1)
                .help(row.labels.joined(separator: ", "))
            }

            Spacer(minLength: 8)

            if row.commentCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 10))
                    Text("\(row.commentCount)")
                        .font(Theme.mono(11))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.textMuted)
                .layoutPriority(1)
                .help(String(localized: "\(row.commentCount) comments"))
            }

            // `createdAt`, not `updatedAt`: the age is what the rail's facet buckets and what a
            // triage pass reads — an issue somebody commented on this morning has not become a
            // new issue.
            RelativeDateText(date: row.createdAt)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 38, alignment: .trailing)
                .layoutPriority(1)
                .help(String(localized: "opened \(RelativeDate.long(row.createdAt))"))
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(isSelected ? Theme.selection : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.accent).frame(width: 2)
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }
}

/// The footer with the key hints for the issues section.
///
/// Shorter than ``ShortcutBar`` on purpose: it lists the keys this section actually has, and an
/// `r a` hint under a list with nothing to approve would be a promise the section cannot keep
/// until the issue writes land.
struct IssueShortcutBar: View {
    var body: some View {
        HStack(spacing: 14) {
            ShortcutHintView(keys: ["j", "k"], label: String(localized: "navigate"))
            ShortcutHintView(keys: ["l"], label: String(localized: "linked pull request"))
            ShortcutHintView(keys: ["esc"], label: String(localized: "clear facets"))
            Spacer(minLength: 0)
            ShortcutHintView(keys: ["⌘K"], label: String(localized: "commands"))
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}
