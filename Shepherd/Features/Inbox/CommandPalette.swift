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

    @State private var query = ""
    @State private var selectionIndex = 0
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
            KeyCapView(keys: "esc")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .onAppear { isFieldFocused = true }
    }

    @ViewBuilder
    private var results: some View {
        let groups = groupedCommands
        if groups.isEmpty {
            Text(String(localized: "No command matches “\(query)”."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(groups, id: \.section) { group in
                            Text(group.section.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .kerning(0.7)
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(group.rows) { row in
                                paletteRow(row)
                                    .id(row.command.id)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 330)
                .onChange(of: selectionIndex) { _, index in
                    guard index < flatRows.count else { return }
                    proxy.scrollTo(flatRows[index].command.id, anchor: .center)
                }
            }
        }
    }

    private func paletteRow(_ row: MatchedCommand) -> some View {
        let isSelected = flatRows.firstIndex(where: { $0.command.id == row.command.id })
            == selectionIndex
        return Button {
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
        return result
    }

    private var flatRows: [MatchedCommand] {
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

    private var groupedCommands: [(section: String, rows: [MatchedCommand])] {
        var order: [String] = []
        var buckets: [String: [MatchedCommand]] = [:]
        for row in flatRows {
            if buckets[row.command.section] == nil {
                order.append(row.command.section)
                buckets[row.command.section] = []
            }
            buckets[row.command.section]?.append(row)
        }
        return order.compactMap { section in
            guard let rows = buckets[section] else { return nil }
            return (section, rows)
        }
    }

    // MARK: - Behaviour

    private func runSelected() {
        let rows = flatRows
        guard selectionIndex >= 0, selectionIndex < rows.count else { return }
        rows[selectionIndex].command.run()
        close()
    }

    private func move(by offset: Int) {
        let count = flatRows.count
        guard count > 0 else { return }
        selectionIndex = min(max(0, selectionIndex + offset), count - 1)
    }

    private func close() {
        environment.isCommandPaletteVisible = false
    }
}
