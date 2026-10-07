import SwiftUI

/// Every keyboard shortcut on one sheet, opened with ⌘/ from the Help menu, the inbox's hint bar
/// and ⌘K.
///
/// The hint bar shows eight keys and ⌘K shows one per command, but neither answers "what does
/// the review screen understand?" — the diff's keys, the session's `d` and `n` — without leaving
/// the screen. The list is written out rather than derived from ``ShortcutAction``, because most
/// of it (the diff, the file list, the sheets) is handled by keystrokes that enum never sees.
/// The user guide's keyboard page (`site/content/docs/keyboard-shortcuts.mdx`) carries the same
/// list; change both together.
struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Shortcut: Identifiable {
        let keys: [String]
        let label: String
        var id: String { keys.joined() + label }
    }

    private struct Group: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    private static let columns: [[Group]] = [
        [
            Group(title: String(localized: "Everywhere"), shortcuts: [
                Shortcut(keys: ["⌘K"], label: String(localized: "Command Palette")),
                Shortcut(keys: ["⌘R"], label: String(localized: "Sync now")),
                Shortcut(keys: ["⇧⌘A"], label: String(localized: "Watch a repository")),
                Shortcut(keys: ["⇧⌘⏎"], label: String(localized: "Start a review session")),
                Shortcut(keys: ["⌘,"], label: String(localized: "Settings")),
                Shortcut(keys: ["⌘W"], label: String(localized: "Close Window")),
                Shortcut(keys: ["⌘/"], label: String(localized: "This overview")),
            ]),
            Group(title: String(localized: "Inbox"), shortcuts: [
                Shortcut(keys: ["j", "k"], label: String(localized: "Next / previous pull request")),
                Shortcut(keys: ["⏎"], label: String(localized: "Open the review")),
                Shortcut(keys: ["x"], label: String(localized: "Select for a bulk action")),
                Shortcut(keys: ["esc"], label: String(localized: "Clear the selection")),
                Shortcut(keys: ["r a"], label: String(localized: "Approve")),
                Shortcut(keys: ["r x"], label: String(localized: "Request changes")),
                Shortcut(keys: ["r c"], label: String(localized: "Comment")),
                Shortcut(keys: ["r f"], label: String(localized: "Start a review session")),
                Shortcut(keys: ["m"], label: String(localized: "Merge, or merge the selection")),
                Shortcut(keys: ["g a"], label: String(localized: "Group by agent")),
                Shortcut(keys: ["g r"], label: String(localized: "Group by repository")),
                Shortcut(keys: ["g s"], label: String(localized: "Group by review state")),
            ]),
        ],
        [
            Group(title: String(localized: "Review: file list"), shortcuts: [
                Shortcut(keys: ["j", "k"], label: String(localized: "Next / previous file")),
                Shortcut(keys: ["a"], label: String(localized: "Viewed, then next unviewed")),
                Shortcut(keys: ["v"], label: String(localized: "Toggle viewed")),
                Shortcut(keys: ["t"], label: String(localized: "Files / Conversation")),
                Shortcut(keys: ["u"], label: String(localized: "Load an update from GitHub")),
                Shortcut(keys: ["c"], label: String(localized: "Into the diff")),
                Shortcut(keys: ["r a", "m"], label: String(localized: "Review and merge keys, as in the inbox")),
                Shortcut(keys: ["esc"], label: String(localized: "Back to the inbox")),
            ]),
            Group(title: String(localized: "Review: diff"), shortcuts: [
                Shortcut(keys: ["j", "k"], label: String(localized: "Next / previous line")),
                Shortcut(keys: ["c"], label: String(localized: "Comment on the line")),
                Shortcut(keys: ["⏎"], label: String(localized: "Open the line's thread")),
                Shortcut(keys: ["[", "]"], label: String(localized: "Left / right side, side by side")),
                Shortcut(keys: ["esc"], label: String(localized: "Back to the file list")),
            ]),
            Group(title: String(localized: "Writing and merging"), shortcuts: [
                Shortcut(keys: ["⌘⏎"], label: String(localized: "Open the submit sheet; Merge in its dialog")),
                Shortcut(keys: ["⇧⌘⏎"], label: String(localized: "Merge when checks pass, in the merge dialog")),
                Shortcut(keys: ["⇧⌘D"], label: String(localized: "Draft with AI")),
                Shortcut(keys: ["⌥E"], label: String(localized: "Explain the selected lines")),
                Shortcut(keys: ["⇧⌘I"], label: String(localized: "Open the first closing issue")),
            ]),
            Group(title: String(localized: "During a review session"), shortcuts: [
                Shortcut(keys: ["d"], label: String(localized: "Done & next")),
                Shortcut(keys: ["n"], label: String(localized: "Next, deal with this one later")),
            ]),
        ],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Keyboard Shortcuts"))
                    .font(Theme.type(.headline))
                    .foregroundStyle(Theme.textStrong)
                Text(String(localized: "Two-key commands are typed one after the other. Every command is also in ⌘K."))
                    .font(Theme.type(.caption))
                    .foregroundStyle(Theme.textMuted)
            }
            ScrollView {
                HStack(alignment: .top, spacing: 32) {
                    ForEach(Self.columns.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Self.columns[index]) { group in
                                groupView(group)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 780, height: 700)
        .background(Theme.panel)
    }

    private func groupView(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title.uppercased())
                .font(Theme.type(.caption, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            ForEach(group.shortcuts) { shortcut in
                HStack(spacing: 4) {
                    ForEach(shortcut.keys, id: \.self) { KeyCapView(keys: $0) }
                    Text(shortcut.label)
                        .font(Theme.type(.callout))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 4)
                }
            }
        }
    }
}
