import ShepherdCore
import SwiftUI

/// The centre pane: a grouped, keyboard-driven pull-request list.
struct InboxListView: View {
    @Environment(AppEnvironment.self) private var environment
    /// The inbox model.
    let model: InboxModel
    /// Opens the full review screen for a pull request.
    var onOpen: (String) -> Void
    /// Whether the keyboard belongs to this list, or to something drawn over it (⌘K's palette).
    ///
    /// The palette is an overlay rather than a sheet or a window, so macOS does not take focus
    /// away from the list for it. Without this the two are both listening: an `x` typed into the
    /// search field also ticks the row under the cursor, and a `j` moves it.
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
            ShortcutBar()
        }
        .focusable(isKeyboardOwner)
        .focusEffectDisabled()
        .focused($isListFocused)
        .onKeyPress(phases: .down) { press in
            // Both halves, because they answer different windows of time: not being focusable
            // stops the *next* key from arriving here, and this stops the one already in flight.
            guard isKeyboardOwner else { return .ignored }
            return handle(press)
        }
        .onAppear { isListFocused = true }
        // And back again when the palette closes. Nothing else would return focus — the list
        // stopped being focusable while the palette was up, so `j` and `k` would be dead until
        // the reader clicked a row. The hop is the palette's own trick (`CommandPaletteView`):
        // the field it is being taken from is torn down in this same update, and focus asked for
        // during a teardown does not always stick.
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
                    model.riskFilter = nil
                    model.laneFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear filter"))
                .accessibilityLabel(Text(String(localized: "Clear filter")))
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
                .accessibilityLabel(Text(String(localized: "Clear the selection")))
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
        } else if isAwaitingFirstSweep {
            LoadingStateView(
                title: String(localized: "Checking your repositories…"),
                message: String(
                    localized: "Pull requests waiting on you, yours, and the ones you are part of."
                )
            )
        } else if model.visibleRows.isEmpty {
            // Two empty states, because an empty list means two opposite things. The designed one
            // is for the pile actually being cleared; the generic one is still what a filter with
            // no matches gets, and what the three other rails get, because "you have no open pull
            // requests" is not an achievement.
            if model.showsInboxZero {
                InboxZeroView(message: model.inboxZeroMessage)
            } else {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: String(localized: "Nothing to review"),
                    message: emptyMessage
                )
            }
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
                                        triage: model.triageSummary(for: row.id),
                                        rounds: model.reviewRounds(for: row.id),
                                        hasSession: model.sessionReference(for: row.id) != nil,
                                        trackRecord: model.trackRecord(for: row.id),
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
            PullRequestActions(
                session: model.session,
                toasts: environment.toasts,
                activity: environment.activity
            )
                .openOnGitHub(row)
        }
        Button(String(localized: "Copy branch name")) {
            PullRequestActions(
                session: model.session,
                toasts: environment.toasts,
                activity: environment.activity
            )
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
        // The lane before the two claims below it, because it is the coarsest of the three and
        // the one the reviewer chose a *mode of reading* with (ADR 0027).
        if let lane = model.laneFilter { return lane.facetTitle }
        // Risk before provenance, because it is the narrower claim of the two: a rail with both
        // selected is showing "this agent's high-risk pull requests", and the surprising half of
        // that sentence is the risk.
        if let risk = model.riskFilter { return risk.facetTitle }
        switch model.provenanceFilter {
        case .agent(let id):
            return model.provenanceFacets.first { $0.filter == .agent(id: id) }?.title ?? id
        case .bots: return String(localized: "Bots")
        case .humans: return String(localized: "Humans")
        case nil: return nil
        }
    }

    /// Whether the list is empty because Shepherd has not finished asking GitHub yet.
    ///
    /// Two conditions, and the second one is what keeps a facet honest. `hasLoaded` only says the
    /// local `SELECT` came back, which on a fresh database happens within a second of signing in
    /// while the sweep's five search queries are still in flight — so the empty state's "No one is
    /// waiting on you" was being drawn as a settled fact before anything had been asked. And the
    /// test is on ``InboxModel/allRows`` rather than on the *visible* rows on purpose: a rail
    /// selection or a filter that hides everything still has rows behind it, so it keeps its own
    /// "clear it to see everything again" sentence instead of being told the sync is still
    /// running.
    private var isAwaitingFirstSweep: Bool {
        model.allRows.isEmpty && !model.session.hasCompletedFirstSweep
    }

    private var emptyMessage: String {
        if model.hasActiveFilter {
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

/// The inbox actually being empty, as opposed to a filter matching nothing.
///
/// Inbox Zero and the end of a focus session are the only two moments this app has anything to
/// celebrate, and both of them were a plain string: this one was the same ``EmptyStateView``,
/// with the same muted grey tick, that "no pull request matches this filter" gets. A tick that
/// means "you are done" and a tick that means "there is nothing here" should not be the same
/// tick.
///
/// So: a larger sealed check in the success colour rather than a muted outline, a headline that
/// says it, and a second line that is *useful* — either where the user's own work is or what will
/// bring the next review request (``InboxModel/inboxZeroMessage(openPullRequestsOfMine:)``).
/// There is no sound and no confetti; the reward for finishing a review queue is a quiet screen.
///
/// The entrance is one quarter-second fade and a very small scale, and it is **off** when the
/// system's Reduce Motion is on (ADR 0033). That switch is why the animation is driven by a state
/// flag rather than by a `.transition`: with motion reduced the flag is simply set outside
/// `withAnimation`, so the view arrives at its final opacity and scale in one frame instead of
/// animating a shorter distance.
struct InboxZeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The second line: what to look at next, or what will bring the next review request.
    let message: String

    /// Whether the entrance has run. `false` for exactly one frame.
    @State private var hasEntered = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.success)
            Text(String(localized: "You are caught up."))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(hasEntered ? 1 : 0)
        .scaleEffect(hasEntered ? 1 : 0.96)
        .onAppear {
            guard !reduceMotion else {
                hasEntered = true
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { hasEntered = true }
        }
        // Combined and *not* relabelled, which is the other half of ADR 0033's rule: with no
        // `.accessibilityLabel` beside it the children keep their own labels, so this is
        // announced as the headline followed by the line under it — everything it draws, in the
        // order it draws it. The symbol carries no label of its own and adds nothing.
        .accessibilityElement(children: .combine)
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
    /// The row's triage state, or `nil` when there is nothing to show (ADR 0023).
    ///
    /// Passed in rather than read from the coordinator here, for ``PullRequestSearchResult``'s
    /// reason: a row is a value renderer, and a row that fetched its own chip would make the list
    /// depend on a coordinator it otherwise knows nothing about.
    var triage: TriageRowSummary?
    /// What this row says about its review rounds, or `nil` when it has none (ADR 0028).
    ///
    /// Passed in for ``triage``'s reason: a row is a value renderer, and the numbers come from
    /// the model that read them.
    var rounds: ReviewRoundsSummary?
    /// Whether this pull request's head commits carry a session to answer to (ADR 0030).
    ///
    /// Passed in for ``triage``'s reason again: the trailer lives in the detail row the model
    /// read, and a row that went looking for it itself would make the list depend on the
    /// database.
    var hasSession = false
    /// The author's track record in this repository, or `nil` when there is no history (ADR 0027).
    ///
    /// Passed in for ``triage``'s reason once more. A row with none renders exactly as it did
    /// before this feature: no badge, and the provenance chip in the agent palette's own colour.
    var trackRecord: TrackRecord?
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

            // The chip is tinted by the track record when there is one — that is ADR 0027's
            // "colours the provenance chip" — and keeps the agent palette's colour when there is
            // not.
            ProvenanceChip(actor: row.author, tint: trackRecord?.chipColor)
                .layoutPriority(1)

            // Beside the provenance chip, because it says the same kind of thing: this pull
            // request came from a session, and that session can still be answered (ADR 0030).
            if hasSession {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.agent)
                    .layoutPriority(1)
                    .help(String(localized: "Has a session to answer to"))
                    .accessibilityLabel(Text(String(localized: "Has a session to answer to")))
            }
            // Beside the chip it describes, and before the triage chip, so the row reads
            // "who · how they have done · what this is".
            if let trackRecord {
                TrackRecordBadge(
                    authorName: badgeAuthorName,
                    agentID: TrackRecordBadge.fleetAgentID(for: row.author),
                    record: trackRecord
                )
                    .layoutPriority(1)
            }

            // Beside the provenance chip, because the two say the same kind of thing about the
            // row — where it came from, and what it is — and both are read before the title's
            // truncation matters.
            if let triage {
                TriageChip(summary: triage)
                    .layoutPriority(1)
            }

            if row.isDraft {
                ChipView(text: String(localized: "Draft"), color: Theme.textMuted)
                    .layoutPriority(1)
            }

            // "3 rounds · 2 findings unchanged": the one thing a reviewer wants to know before
            // opening a pull request they have already reviewed once (ADR 0028).
            if let text = rounds?.chipText {
                ChipView(
                    text: text,
                    color: (rounds?.unchangedFindingCount ?? 0) > 0
                        ? Theme.pending
                        : Theme.textSecondary
                )
                .layoutPriority(1)
                .help(String(localized: "Rounds you have reviewed on this Mac"))
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

    /// The name the badge and its popover use for this row's author.
    ///
    /// The agent's display name where there is one, so the badge reads "Claude Code" rather than
    /// "claude[bot]" — it is the name the track record is *counted* under
    /// (``ShepherdCore/TrackRecordSubject``), and the two must agree or the popover would explain
    /// somebody else's numbers.
    private var badgeAuthorName: String {
        row.author.kind.agentIdentity?.displayName ?? row.author.login
    }

    /// The row's spoken label: everything the row shows, in the order it shows it.
    ///
    /// `.accessibilityElement(children: .combine)` would concatenate the siblings' own labels,
    /// and the `.accessibilityLabel` beside it *replaces* that — so this has to say the whole
    /// row or the row says only its number and title. Six facts are drawn here and six are
    /// spoken: the tick, the checks, which pull request, its title, who opened it, whether it
    /// answers a session, how that author has done before, what triage made of it, whether it
    /// is a draft, how many rounds it has been reviewed in, its status chip, its size and its
    /// age. Each part comes from the same value the view draws, through the components' own
    /// spoken forms, so the row cannot describe itself differently from its own chips.
    private var accessibilityText: String {
        SpokenRow.sentence([
            showsMarkColumn
                ? (isMarked
                    ? String(localized: "Selected")
                    : String(localized: "Not selected"))
                : nil,
            CheckDotView.spokenState(row.checkRollup?.state),
            "\(row.slug): \(row.title)",
            ProvenanceChip.spokenProvenance(of: row.author),
            hasSession ? String(localized: "Has a session to answer to") : nil,
            trackRecord.map { TrackRecordBadge.sentence(authorName: badgeAuthorName, record: $0) },
            triage.flatMap { TriageChip.spokenTitle(for: $0) },
            row.isDraft ? String(localized: "Draft") : nil,
            rounds?.chipText,
            statusChip?.text,
            DiffCountsView.spokenCounts(additions: row.additions, deletions: row.deletions),
            RelativeDate.long(row.updatedAt),
        ])
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
