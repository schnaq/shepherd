import ShepherdCore
import SwiftUI

/// One row of the ⌘K palette.
struct PaletteCommand: Identifiable {
    /// A stable identifier.
    let id: String
    /// The section header this command sits under.
    let section: String
    /// The command title, which is what the fuzzy filter matches against.
    let title: String
    /// An SF Symbol.
    let systemImage: String
    /// The keyboard shortcut hint, when the command has one.
    var keyHint: String?
    /// What running the command does.
    let run: @MainActor () -> Void
}

/// Subsequence ("fuzzy") matching with the matched character positions, for highlighting.
enum FuzzyMatch {
    /// Matches a query against a candidate.
    /// - Parameters:
    ///   - query: What the user typed. An empty query matches everything.
    ///   - text: The candidate string.
    /// - Returns: The matched character offsets, or `nil` when the query does not match.
    static func match(query: String, in text: String) -> [Int]? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return [] }
        let haystack = Array(text.lowercased())
        var indices: [Int] = []
        var position = 0
        for character in needle {
            var found = false
            while position < haystack.count {
                if haystack[position] == character {
                    indices.append(position)
                    position += 1
                    found = true
                    break
                }
                position += 1
            }
            if !found { return nil }
        }
        return indices
    }

    /// Renders a title with the matched characters highlighted.
    /// - Parameters:
    ///   - text: The title.
    ///   - indices: The matched offsets from ``match(query:in:)``.
    static func highlighted(_ text: String, indices: [Int]) -> AttributedString {
        var attributed = AttributedString(text)
        guard !indices.isEmpty else { return attributed }
        for offset in indices {
            guard offset >= 0, offset < text.count else { continue }
            let start = attributed.characters.index(attributed.startIndex, offsetBy: offset)
            let end = attributed.characters.index(after: start)
            attributed[start..<end].backgroundColor = Theme.accent.opacity(0.25)
            attributed[start..<end].foregroundColor = Theme.textStrong
        }
        return attributed
    }
}

/// The ⌘K command palette: every action in the app, reachable by typing.
struct CommandPaletteView: View {
    @Environment(AppEnvironment.self) private var environment
    /// The active session.
    let session: SignedInSession
    /// The pull request the visible screen's cursor is on, if any
    /// (``AppEnvironment/selectedPullRequest``).
    ///
    /// Every review command below acts on it, so with nothing selected they are left out rather
    /// than listed and ignored — and the two GitHub would refuse (an approve on your own pull
    /// request, a merge of a draft) are left out even when there is one, because the palette is
    /// the one surface where a command cannot be greyed out with an explanation attached.
    let selectedRow: PullRequestSummary?

    @State private var query = ""
    @State private var selectionIndex = 0
    /// The best-matching pull requests for the current query (ADR 0019).
    ///
    /// Held here rather than on the coordinator because it is *this* palette's view state: the
    /// coordinator owns the corpus and answers questions, and a second palette (or the same one
    /// reopened) starts from an empty query with nothing to show.
    @State private var pullRequestResults: [PullRequestSearchResult] = []
    /// The best-matching issues for the current query (ADR 0032).
    ///
    /// Held beside the pull requests rather than merged into one array, because the two are
    /// rendered by two row views and grouped under two headers — the *ordering* decision is the
    /// coordinator's (``SearchIndexCoordinator/paletteResults(for:limit:verdicts:)`` merges by
    /// score and slices once), and by the time they arrive here the slice has happened.
    @State private var issueResults: [IssueSearchMatch] = []
    /// Whether this palette session has already counted its search (ADR 0036).
    ///
    /// One event per *search*, not per keystroke: the ranking below re-runs on every character,
    /// and counting there would measure typing speed. The event is recorded when the palette is
    /// done instead — on the way out through a result, or on the way out without one — and this
    /// flag is what keeps those two paths from counting the same search twice. It resets with the
    /// rest of this view's state when the palette is reopened.
    @State private var didRecordSearch = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }

            panel
                .padding(.top, 90)
        }
        .onExitCommand { close() }
        .onKeyPress(phases: .down) { press in
            if press.matches(.downArrow) {
                move(by: 1)
                return .handled
            }
            if press.matches(.upArrow) {
                move(by: -1)
                return .handled
            }
            if press.matches(.escape) {
                close()
                return .handled
            }
            return .ignored
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            Divider().overlay(Theme.border)
            results
            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 560)
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.controlBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 32, y: 18)
        // The palette is an overlay in `RootView`, not a sheet: the inbox list underneath it is
        // still in the window and was holding focus when ⌘K was pressed. This is what makes the
        // field the focused thing on arrival rather than the thing the reader has to click.
        .defaultFocus($isFieldFocused, true)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
            TextField(String(localized: "Type a command…"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textStrong)
                .focused($isFieldFocused)
                .onSubmit { runSelected() }
                .onChange(of: query) { _, _ in selectionIndex = 0 }
                // Escape and the arrows on the field itself, because a focused single-line
                // `TextField` swallows all three before the container's handler above ever sees
                // them — which is why the palette used to need a click on the dimmed background
                // to go away, and why ↓ moved the caret instead of the selection. The container
                // keeps its own copies: they are what answers the keys before anything is
                // focused. Field and container call the same two methods, so there is one
                // behaviour with two doors into it.
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    move(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(by: -1)
                    return .handled
                }
            KeyCapView(keys: "esc")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .onAppear { isFieldFocused = true }
        // And once more a frame or two later: the list underneath is giving focus up in this same
        // update, and on the pass where it wins the race the ask above is lost
        // (``View/reassertingFocus(_:when:after:)``).
        .reassertingFocus($isFieldFocused, when: true)
        // `task(id:)` is the debounce: a keystroke cancels the previous ranking and starts a new
        // one. Everything it does is local — the corpus and the vectors are already in memory,
        // and the query's own embedding is an on-device call — so there is nothing to throttle
        // and nothing that could reach the network (ADR 0019).
        .task(id: query) {
            let answer = await environment.search.paletteResults(
                for: query,
                limit: CommandPaletteView.searchResultLimit,
                // Read here, at the one call site, rather than held by the search coordinator:
                // `risk:high kind:dependency` is a *filter over* the ranking, and the two
                // coordinators stay unaware of each other (ADR 0023).
                verdicts: environment.triage.verdicts
            )
            pullRequestResults = answer.pullRequests
            issueResults = answer.issues
        }
    }

    @ViewBuilder
    private var results: some View {
        let groups = sections
        if groups.isEmpty {
            Text(String(localized: "Nothing matches “\(query)”."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(groups) { group in
                            Text(group.title.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .kerning(0.7)
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(group.rows) { row in
                                paletteRow(row)
                                    .id(row.id)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 330)
                .onChange(of: selectionIndex) { _, index in
                    let rows = flatRows
                    guard index >= 0, index < rows.count else { return }
                    proxy.scrollTo(rows[index].id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func paletteRow(_ row: PaletteRow) -> some View {
        switch row {
        case .command(let matched):
            commandRow(matched, isSelected: isSelected(row))
        case .pullRequest(let result):
            Button {
                open(result)
            } label: {
                SearchResultRowView(result: result, isSelected: isSelected(row))
            }
            .buttonStyle(.plain)
        case .issue(let result):
            Button {
                open(result)
            } label: {
                IssueSearchResultRowView(result: result, isSelected: isSelected(row))
            }
            .buttonStyle(.plain)
        }
    }

    /// Whether the keyboard cursor is on a row.
    ///
    /// By identity rather than by index arithmetic, because the two sections can swap places
    /// between one keystroke and the next (a prose query moves the pull requests above the
    /// commands) and an index computed in the row would then be one section out of date.
    private func isSelected(_ row: PaletteRow) -> Bool {
        let rows = flatRows
        guard selectionIndex >= 0, selectionIndex < rows.count else { return false }
        return rows[selectionIndex].id == row.id
    }

    private func commandRow(_ row: MatchedCommand, isSelected: Bool) -> some View {
        Button {
            row.command.run()
            close()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: row.command.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 15)
                Text(FuzzyMatch.highlighted(row.command.title, indices: row.indices))
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.textStrong : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let hint = row.command.keyHint {
                    KeyCapView(keys: hint)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                isSelected ? Theme.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .opacity(row.isMatch ? 1 : 0.42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            ShortcutHintView(keys: ["↑", "↓"], label: String(localized: "select"))
            ShortcutHintView(keys: ["⏎"], label: String(localized: "run"))
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                ShepherdMark(size: 12)
                Text(String(localized: "Shepherd"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Theme.panel)
    }

    // MARK: - Command list

    /// A command plus its match state for the current query.
    struct MatchedCommand: Identifiable {
        /// The command.
        let command: PaletteCommand
        /// The matched character offsets.
        let indices: [Int]
        /// Whether the query matched at all (non-matching rows are dimmed, not hidden).
        let isMatch: Bool

        var id: String { command.id }
    }

    /// One selectable row of the palette.
    ///
    /// The palette gained a second *kind* of answer with ADR 0019, and the keyboard is the reason
    /// this is one enum rather than two lists: arrows, ⏎ and the scroll-to-selection all work on
    /// a single ordered list, and a second list would mean a second cursor and a rule for moving
    /// between them.
    enum PaletteRow: Identifiable {
        /// A command, matched by the fuzzy filter.
        case command(MatchedCommand)
        /// A pull request, ranked by ``ShepherdCore/SearchRanker``.
        case pullRequest(PullRequestSearchResult)
        /// An issue, ranked by ``ShepherdCore/IssueSearchRanker`` (ADR 0032).
        ///
        /// A third case rather than a second list, for the reason the second one is a case: the
        /// arrows, ⏎ and the scroll-to-selection all work on one ordered list, and a third list
        /// would mean a third cursor and two rules for moving between them.
        case issue(IssueSearchMatch)

        /// A stable identifier, namespaced so a command, a pull request and an issue cannot
        /// collide.
        var id: String {
            switch self {
            case .command(let matched): return "command:\(matched.command.id)"
            case .pullRequest(let result): return "pr:\(result.id)"
            case .issue(let result): return "issue:\(result.id)"
            }
        }
    }

    /// A titled group of rows.
    struct PaletteSection: Identifiable {
        /// The section header.
        let title: String
        /// Its rows, in order.
        let rows: [PaletteRow]

        var id: String { title }
    }

    /// How many search rows the palette has room for beside the commands.
    ///
    /// A budget across *both* kinds rather than one each (ADR 0032): the coordinator ranks both
    /// corpora to this limit, merges them by score and slices once, so six strong pull requests
    /// are six rows and a quota cannot push one of them out for a weak issue.
    static let searchResultLimit = 6

    private var commands: [PaletteCommand] {
        var result: [PaletteCommand] = []
        let inbox = String(localized: "Inbox")

        result.append(
            PaletteCommand(
                id: "sync",
                section: inbox,
                title: String(localized: "Sync all repositories now"),
                systemImage: "arrow.clockwise",
                keyHint: "⌘R"
            ) {
                Task { await environment.syncNow() }
            }
        )
        result.append(
            PaletteCommand(
                id: "watch-repo",
                section: inbox,
                title: String(localized: "Watch a repository"),
                systemImage: "binoculars",
                keyHint: "⇧⌘A"
            ) {
                environment.isAddingWatchedRepository = true
            }
        )
        result.append(
            PaletteCommand(
                id: "add-local-repo",
                section: inbox,
                title: String(localized: "Add a local repository…"),
                systemImage: "laptopcomputer"
            ) {
                environment.addLocalRepository()
            }
        )
        // One command per linked clone, because the palette has no "current repository" to act
        // on from the inbox, and typing the repository's name is exactly how a reader looks for
        // it here (ADR 0011's 2026-09-23 amendment). Only repositories with a checkout: without
        // one there is nowhere for the worktree to come from.
        let delegation = String(localized: "Delegation")
        for repo in environment.settings.linkedRepositories {
            result.append(
                PaletteCommand(
                    id: "start-agent-\(repo.fullName.lowercased())",
                    section: delegation,
                    title: String(localized: "Start an agent on \(repo.fullName)…"),
                    systemImage: "terminal"
                ) {
                    environment.startRepositoryDelegation(repo)
                }
            )
        }
        // One command per task worth going back to, so a person with three agents working in one
        // repository can reach the second one by typing a word of what they asked it to do. The
        // command above always starts a new task; these are the only way back from ⌘K.
        for task in environment.delegation.repositoryTasks {
            result.append(
                PaletteCommand(
                    id: "agent-task-\(task.id)",
                    section: delegation,
                    title: task.taskPaletteTitle,
                    systemImage: "terminal.fill"
                ) {
                    environment.reopenRepositoryTask(task)
                }
            )
        }
        result.append(
            PaletteCommand(
                id: "group-agent",
                section: inbox,
                title: String(localized: "Group inbox by agent"),
                systemImage: "square.stack.3d.up",
                keyHint: "g a"
            ) {
                environment.settings.groupBy = .provenance
            }
        )
        result.append(
            PaletteCommand(
                id: "group-repo",
                section: inbox,
                title: String(localized: "Group inbox by repository"),
                systemImage: "folder",
                keyHint: "g r"
            ) {
                environment.settings.groupBy = .repository
            }
        )
        result.append(
            PaletteCommand(
                id: "group-review",
                section: inbox,
                title: String(localized: "Group inbox by review state"),
                systemImage: "checkmark.seal",
                keyHint: "g s"
            ) {
                environment.settings.groupBy = .reviewState
            }
        )
        // Outside the `if case .inbox` and `if case .review` blocks below, so it is offered from
        // both routes: the fleet is about the agents whose work fills either screen, and the
        // question "how has this one been doing" is asked at least as often *while reading a diff*
        // as from the list (ADR 0035). Its title spells out "agent" because the rail row it
        // duplicates is called Fleet, and between the two spellings a reviewer types one of them.
        result.append(
            PaletteCommand(
                id: "fleet",
                section: inbox,
                title: String(localized: "Show the agent fleet"),
                systemImage: "person.2.badge.gearshape"
            ) {
                environment.openFleet()
            }
        )
        result.append(
            PaletteCommand(
                id: "appearance",
                section: inbox,
                title: String(localized: "Toggle appearance: dark / light / system"),
                systemImage: "circle.lefthalf.filled"
            ) {
                let all = AppearanceSetting.allCases
                let index = all.firstIndex(of: environment.settings.appearance) ?? 0
                environment.settings.appearance = all[(index + 1) % all.count]
                environment.applyAppearance()
            }
        )
        if case .review = environment.route {
            result.append(
                PaletteCommand(
                    id: "back-to-inbox",
                    section: inbox,
                    title: String(localized: "Back to the inbox"),
                    systemImage: "chevron.left",
                    keyHint: "esc"
                ) {
                    environment.closeReview()
                }
            )
        }

        // Bulk triage only exists where the selection does: the inbox (ADR 0015).
        if case .inbox = environment.route {
            let triage = String(localized: "Triage")
            result.append(
                PaletteCommand(
                    id: "mark-green-agents",
                    section: triage,
                    title: String(localized: "Select all green agent pull requests"),
                    systemImage: "checklist"
                ) {
                    environment.request(.markGreenAgentPullRequests)
                }
            )
            for action in BulkTriageAction.allCases {
                result.append(
                    PaletteCommand(
                        id: "bulk-\(action.rawValue)",
                        section: triage,
                        title: action.commandTitle,
                        systemImage: action.systemImage
                    ) {
                        environment.request(.bulkTriage(action))
                    }
                )
            }
            result.append(
                PaletteCommand(
                    id: "merge-series",
                    section: triage,
                    title: MergeSeriesSheet.commandTitle,
                    systemImage: "list.number"
                ) {
                    environment.request(.mergeSeries)
                }
            )
            result.append(
                PaletteCommand(
                    id: "toggle-mark",
                    section: triage,
                    title: String(localized: "Select or deselect this pull request"),
                    systemImage: "checkmark.square",
                    keyHint: "x"
                ) {
                    environment.request(.toggleMark)
                }
            )
        }

        let review = String(localized: "Review")
        // First in its section: it is the one command that starts a *flow* rather than acting on
        // whatever happens to be selected.
        if environment.reviewSession == nil {
            result.append(
                PaletteCommand(
                    id: "start-review-session",
                    section: review,
                    title: String(localized: "Start review session"),
                    systemImage: "play.circle",
                    keyHint: "r f"
                ) {
                    environment.request(.startReviewSession)
                }
            )
        } else {
            result.append(
                PaletteCommand(
                    id: "end-review-session",
                    section: review,
                    title: String(localized: "End review session"),
                    systemImage: "stop.circle",
                    keyHint: "esc"
                ) {
                    environment.endReviewSession()
                }
            )
        }
        if let selectedRow {
            if selectedRow.verdictBlocker == nil {
                result.append(
                    PaletteCommand(
                        id: "approve",
                        section: review,
                        title: String(localized: "Approve pull request"),
                        systemImage: "checkmark.circle",
                        keyHint: "r a"
                    ) {
                        environment.request(.approve)
                    }
                )
                result.append(
                    PaletteCommand(
                        id: "request-changes",
                        section: review,
                        title: String(localized: "Request changes"),
                        systemImage: "exclamationmark.circle",
                        keyHint: "r x"
                    ) {
                        environment.request(.requestChanges)
                    }
                )
            }
            // Not gated by ``ReviewActionBlocker``: a plain `COMMENT` review is the one verdict
            // GitHub accepts on your own pull request, so this stays where an approve cannot.
            result.append(
                PaletteCommand(
                    id: "comment",
                    section: review,
                    title: String(localized: "Comment on pull request"),
                    systemImage: "bubble.left",
                    keyHint: "r c"
                ) {
                    environment.request(.comment)
                }
            )
            if selectedRow.mergeBlocker == nil {
                result.append(
                    PaletteCommand(
                        id: "merge",
                        section: review,
                        title: String(localized: "Merge pull request…"),
                        systemImage: "arrow.triangle.merge",
                        keyHint: "m"
                    ) {
                        environment.request(.merge)
                    }
                )
            }
            result.append(
                PaletteCommand(
                    id: "delegate",
                    section: review,
                    title: String(localized: "Delegate to agent"),
                    systemImage: "arrow.uturn.backward.badge.clock"
                ) {
                    environment.request(.delegate)
                }
            )
            result.append(
                PaletteCommand(
                    id: "open-selection",
                    section: review,
                    title: String(localized: "Open full review"),
                    systemImage: "arrow.right.circle",
                    keyHint: "⏎"
                ) {
                    environment.request(.openSelection)
                }
            )
        }
        return result
    }

    private var matchedCommands: [MatchedCommand] {
        let rows = commands.map { command -> MatchedCommand in
            if let indices = FuzzyMatch.match(query: query, in: command.title) {
                return MatchedCommand(command: command, indices: indices, isMatch: true)
            }
            return MatchedCommand(command: command, indices: [], isMatch: false)
        }
        guard !query.isEmpty else { return rows }
        // Matches first, non-matches dimmed at the bottom — nothing ever disappears entirely,
        // which is what makes the palette usable as a discovery surface.
        return rows.filter(\.isMatch) + rows.filter { !$0.isMatch }
    }

    private var commandSections: [PaletteSection] {
        var order: [String] = []
        var buckets: [String: [PaletteRow]] = [:]
        for row in matchedCommands {
            if buckets[row.command.section] == nil {
                order.append(row.command.section)
                buckets[row.command.section] = []
            }
            buckets[row.command.section]?.append(.command(row))
        }
        return order.compactMap { section in
            guard let rows = buckets[section] else { return nil }
            return PaletteSection(title: section, rows: rows)
        }
    }

    /// The palette's sections, in the order they are shown — and therefore in the order the
    /// arrow keys walk them.
    ///
    /// Where the pull requests go is the one layout decision the feature makes (ADR 0019). They
    /// sit **below** the commands for a short query, because a word or two is usually somebody
    /// reaching for a command name and the palette's first job is still to be a command palette.
    /// They move **above** them when the query reads like a search instead — two or more words,
    /// or an explicit `owner/repo#123` — and when no command matched at all, because in both of
    /// those cases the commands underneath are only ever the dimmed non-matches.
    private var sections: [PaletteSection] {
        let commandGroups = commandSections
        var searchGroups: [PaletteSection] = []
        if !pullRequestResults.isEmpty {
            searchGroups.append(
                PaletteSection(
                    title: String(localized: "Pull requests"),
                    rows: pullRequestResults.map { PaletteRow.pullRequest($0) }
                )
            )
        }
        // Issues come second when both kinds answered, which is the one place this feature makes
        // a layout decision: the pull-request inbox is what Shepherd is for, and the merge above
        // has already decided *how many* of each there are.
        if !issueResults.isEmpty {
            searchGroups.append(
                PaletteSection(
                    title: String(localized: "Issues"),
                    rows: issueResults.map { PaletteRow.issue($0) }
                )
            )
        }
        guard !searchGroups.isEmpty else { return commandGroups }
        let hasCommandMatch = matchedCommands.contains(where: \.isMatch)
        let leadsWithSearch = SearchQuery(text: query).looksLikeProse || !hasCommandMatch
        return leadsWithSearch ? searchGroups + commandGroups : commandGroups + searchGroups
    }

    private var flatRows: [PaletteRow] {
        sections.flatMap(\.rows)
    }

    // MARK: - Behaviour

    private func runSelected() {
        let rows = flatRows
        guard selectionIndex >= 0, selectionIndex < rows.count else { return }
        switch rows[selectionIndex] {
        case .command(let matched):
            matched.command.run()
            close()
        case .pullRequest(let result):
            open(result)
        case .issue(let result):
            open(result)
        }
    }

    /// Opens a pull request the same way every other surface does.
    ///
    /// ``AppEnvironment/openReview(prID:composing:)`` and nothing else — the argument the
    /// menu-bar quick inbox makes: a fifth way to open a review would be a fifth place for the
    /// focus session's "did the user leave the queue" rule to be forgotten.
    private func open(_ result: PullRequestSearchResult) {
        recordSearch(openedResult: true)
        environment.openReview(prID: result.summary.id)
        close()
    }

    /// Opens an issue the same way every other surface does (ADR 0032).
    ///
    /// ``AppEnvironment/openIssue(issueID:)`` and nothing else — the argument above, once more:
    /// selecting an issue here has to switch the content kind *and* reveal the row even when the
    /// rail's facets are hiding it, and a second implementation of that would be a second place
    /// for one of the two halves to be forgotten.
    private func open(_ result: IssueSearchMatch) {
        recordSearch(openedResult: true)
        environment.openIssue(issueID: result.summary.id)
        close()
    }

    private func move(by offset: Int) {
        let count = flatRows.count
        guard count > 0 else { return }
        selectionIndex = min(max(0, selectionIndex + offset), count - 1)
    }

    private func close() {
        // A palette dismissed without opening anything is still a search that happened, and
        // "people search and then find nothing" is exactly what this event is for. The guard in
        // `recordSearch` means the call above has already won when we arrive here through `open`.
        recordSearch(openedResult: false)
        environment.isCommandPaletteVisible = false
    }

    /// Counts one search (ADR 0036).
    ///
    /// Nothing is recorded for a palette that was opened and closed without a query: running a
    /// *command* is not a search, and counting it would inflate the number this event exists to
    /// answer.
    /// - Parameter openedResult: Whether the palette is closing because a result was opened.
    private func recordSearch(openedResult: Bool) {
        guard !didRecordSearch else { return }
        let parsed = SearchQuery(text: query)
        guard parsed.hasSearchTerms else { return }
        didRecordSearch = true
        environment.telemetry?.record(
            .searchUsed(kind: parsed.reference != nil ? .reference : .semantic, openedResult: openedResult)
        )
    }
}
