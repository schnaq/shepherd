import ShepherdCore
import SwiftUI

/// The centre pane: a grouped, keyboard-driven pull-request list.
struct InboxListView: View {
    @Environment(AppEnvironment.self) private var environment
    /// The inbox model.
    let model: InboxModel
    /// Opens the full review screen for a pull request.
    var onOpen: (String) -> Void

    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            list
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ShortcutBar()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isListFocused)
        .onKeyPress(phases: .down) { press in
            handle(press)
        }
        .onAppear { isListFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.smartView.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text(String(localized: "\(model.filteredRows.count) pull requests"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)

            if let filter = activeFilterLabel {
                ChipView(text: filter, color: Theme.accentText)
                Button {
                    model.provenanceFilter = nil
                    model.repoFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear filter"))
            }

            if model.hasMarks {
                ChipView(
                    text: String(localized: "\(model.markedIDs.count) selected"),
                    color: Theme.accent
                )
                Button {
                    model.clearMarks()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear the selection (esc)"))
            }

            Spacer(minLength: 8)

            // Only when there is something to work through: an entry point that starts an empty
            // session, or explains why it cannot, is worse than no entry point.
            if pendingReviewCount > 0 {
                Button {
                    environment.request(.startReviewSession)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.circle").font(.system(size: 11))
                        Text(String(localized: "Session · \(pendingReviewCount)"))
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: 26, tint: Theme.accentText))
                .help(String(
                    localized: "Work through the \(pendingReviewCount) pull requests waiting for your review, one at a time (r f)"
                ))
                .layoutPriority(1)
            }

            Picker(String(localized: "Group"), selection: groupBinding) {
                Text(String(localized: "Agent")).tag(InboxFacet.provenance)
                Text(String(localized: "Repository")).tag(InboxFacet.repository)
                Text(String(localized: "Review state")).tag(InboxFacet.reviewState)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 140)
            .help(String(localized: "Group the list (g a / g r / g s)"))

            Picker(String(localized: "Sort"), selection: sortBinding) {
                ForEach(InboxSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
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
        } else if model.visibleRows.isEmpty {
            EmptyStateView(
                systemImage: "checkmark.circle",
                title: String(localized: "Nothing to review"),
                message: emptyMessage
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.sections) { section in
                            Section {
                                ForEach(section.items) { row in
                                    InboxRowView(
                                        row: row,
                                        isSelected: model.selectedID == row.id,
                                        showsMarkColumn: model.hasMarks,
                                        isMarked: model.markedIDs.contains(row.id),
                                        onToggleMark: { model.toggleMark(row.id) }
                                    )
                                    .id(row.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { onOpen(row.id) }
                                    .onTapGesture { model.select(row.id) }
                                    // ⌘-click ticks one row, ⇧-click ticks the range from the
                                    // cursor. Attached outermost so a modified click never
                                    // falls through to plain selection (ADR 0015).
                                    .highPriorityGesture(
                                        TapGesture()
                                            .modifiers(.command)
                                            .onEnded { _ in model.toggleMark(row.id) }
                                    )
                                    .highPriorityGesture(
                                        TapGesture()
                                            .modifiers(.shift)
                                            .onEnded { _ in model.extendMarks(to: row.id) }
                                    )
                                    .contextMenu {
                                        rowMenu(for: row)
                                    }
                                }
                            } header: {
                                InboxSectionHeader(section: section)
                            }
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
    private func rowMenu(for row: PullRequestSummary) -> some View {
        Button(String(localized: "Open review")) { onOpen(row.id) }
        Button(
            model.markedIDs.contains(row.id)
                ? String(localized: "Deselect")
                : String(localized: "Select")
        ) {
            model.toggleMark(row.id)
        }
        Divider()
        Button(String(localized: "Open on GitHub")) {
            PullRequestActions(session: model.session, toasts: environment.toasts)
                .openOnGitHub(row)
        }
        Button(String(localized: "Copy branch name")) {
            PullRequestActions(session: model.session, toasts: environment.toasts)
                .copyBranch(row)
        }
        if model.hasMarks {
            Divider()
            // Bulk actions act on the ticked rows, not on the row that was right-clicked —
            // the count is in the title so that cannot be misread.
            Text(String(localized: "\(model.markedIDs.count) selected"))
            ForEach(BulkTriageAction.allCases, id: \.self) { action in
                Button(action.commandTitle) {
                    environment.request(.bulkTriage(action))
                }
            }
        }
    }

    // MARK: - Bindings and helpers

    private var groupBinding: Binding<InboxFacet> {
        Binding(
            get: { model.settings.groupBy },
            set: { model.settings.groupBy = $0 }
        )
    }

    private var sortBinding: Binding<InboxSortOrder> {
        Binding(
            get: { model.settings.sortOrder },
            set: { model.settings.sortOrder = $0 }
        )
    }

    /// How many pull requests a focus session would have in its queue.
    ///
    /// The rail's count for "Needs my review", not the filtered list: the session ignores the
    /// facets on purpose (``ReviewSession/make(from:startedAt:)``), so the button has to promise
    /// the same number the session will actually show.
    private var pendingReviewCount: Int {
        model.count(for: .needsMyReview)
    }

    private var activeFilterLabel: String? {
        if let repo = model.repoFilter { return repo.fullName }
        switch model.provenanceFilter {
        case .agent(let id):
            return model.provenanceFacets.first { $0.filter == .agent(id: id) }?.title ?? id
        case .bots: return String(localized: "Bots")
        case .humans: return String(localized: "Humans")
        case nil: return nil
        }
    }

    private var emptyMessage: String {
        if model.provenanceFilter != nil || model.repoFilter != nil {
            return String(localized: "No pull request matches this filter. Clear it to see everything again.")
        }
        switch model.smartView {
        case .needsMyReview:
            return String(localized: "No one is waiting on you. New review requests land here automatically.")
        case .myPullRequests:
            return String(localized: "You have no open pull requests.")
        case .involved:
            return String(localized: "Nothing synced yet. Press ⌘R to run a sync now.")
        case .approvedByMe:
            return String(localized: "Nothing you reviewed is still open.")
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // ⌘ is excluded so ⇧⌘⏎ — "Start Review Session" in the Review menu — cannot also read as
        // "open the row under the cursor" if it ever reaches the list instead of the main menu.
        if press.matches(.return), !press.modifiers.contains(.command) {
            if let id = model.selectedID {
                onOpen(id)
                return .handled
            }
            return .ignored
        }
        if press.matches(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        if press.matches(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        if press.matches(.escape) {
            model.keySequence.reset()
            // Escape is the way out of a selection as well as out of a half-typed command.
            model.clearMarks()
            return .handled
        }
        guard press.modifiers.isEmpty, let character = press.characters.first else {
            return .ignored
        }
        switch model.keySequence.consume(character) {
        case .action(let action):
            environment.request(action)
            return .handled
        case .awaitingSecondKey:
            return .handled
        case .unhandled:
            return .ignored
        }
    }
}

/// The pinned section header of the grouped list.
struct InboxSectionHeader: View {
    /// The section being rendered.
    let section: InboxSection

    var body: some View {
        HStack(spacing: 8) {
            if let color = dotColor {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(section.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.textSecondary)
            Text(String(localized: "· \(section.count) shown"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
    }

    private var dotColor: Color? {
        guard section.facet == .provenance else { return nil }
        if section.id.hasPrefix("agent:") {
            return AgentPalette.color(forAgentID: String(section.id.dropFirst("agent:".count)))
        }
        return section.id == "human" ? Theme.accent : Theme.textSecondary
    }
}

/// One inbox row, exactly as the mockup lays it out.
struct InboxRowView: View {
    /// The pull request.
    let row: PullRequestSummary
    /// Whether it is the selected row.
    let isSelected: Bool
    /// Whether the bulk-selection column is showing, i.e. whether anything is ticked at all.
    ///
    /// The column appears with the first tick and disappears with the last, so a list nobody is
    /// bulk-triaging looks exactly as it did before (ADR 0015).
    var showsMarkColumn = false
    /// Whether this row is ticked for a bulk action.
    var isMarked = false
    /// Ticks or unticks this row.
    var onToggleMark: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if showsMarkColumn {
                Button {
                    onToggleMark?()
                } label: {
                    Image(systemName: isMarked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(isMarked ? Theme.accent : Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help(
                    isMarked
                        ? String(localized: "Remove from the selection (x)")
                        : String(localized: "Add to the selection (x)")
                )
                .accessibilityLabel(
                    isMarked
                        ? Text(String(localized: "Selected"))
                        : Text(String(localized: "Not selected"))
                )
            }

            CheckDotView(state: row.checkRollup?.state)

            Text("\(row.repo.name) #\(row.number)")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textMuted)
                .layoutPriority(1)

            Text(row.title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Theme.textStrong : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)

            ProvenanceChip(actor: row.author)
                .layoutPriority(1)

            if row.isDraft {
                ChipView(text: String(localized: "Draft"), color: Theme.textMuted)
                    .layoutPriority(1)
            }

            Spacer(minLength: 8)

            if let status = statusChip {
                ChipView(text: status.text, color: status.color)
                    .layoutPriority(1)
            }

            DiffCountsView(additions: row.additions, deletions: row.deletions)
                .layoutPriority(1)

            RelativeDateText(date: row.updatedAt)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 38, alignment: .trailing)
                .layoutPriority(1)
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

    /// The row's spoken label, with the tick state in front when the column is showing.
    private var accessibilityText: String {
        let base = "\(row.slug): \(row.title)"
        guard showsMarkColumn else { return base }
        return isMarked
            ? String(localized: "Selected. \(base)")
            : String(localized: "Not selected. \(base)")
    }

    private var statusChip: (text: String, color: Color)? {
        if let rollup = row.checkRollup, rollup.state == .failure {
            let count = max(1, rollup.failureCount)
            return (String(localized: "\(count) checks failing"), Theme.failure)
        }
        if let rollup = row.checkRollup, rollup.state == .pending {
            return (String(localized: "CI running"), Theme.pending)
        }
        if let decision = row.reviewDecision {
            return (decision.chipTitle, decision.chipColor)
        }
        if row.myRelation.contains(.reviewRequested) {
            return (String(localized: "Review requested"), Theme.accentText)
        }
        return nil
    }
}

/// The footer with the key hints from the mockup.
struct ShortcutBar: View {
    var body: some View {
        HStack(spacing: 14) {
            ShortcutHintView(keys: ["j", "k"], label: String(localized: "navigate"))
            ShortcutHintView(keys: ["⏎"], label: String(localized: "open review"))
            ShortcutHintView(keys: ["r a"], label: String(localized: "approve"))
            ShortcutHintView(keys: ["r x"], label: String(localized: "request changes"))
            ShortcutHintView(keys: ["m"], label: String(localized: "merge"))
            ShortcutHintView(keys: ["x"], label: String(localized: "select"))
            ShortcutHintView(keys: ["r f"], label: String(localized: "session"))
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
