import ShepherdCore
import SwiftUI

/// Settings → Replies: the reusable review text — saved replies and per-repository templates.
///
/// A tab of its own rather than a card on an existing one, for two reasons. It is the only place in
/// Settings where the user *authors* something instead of configuring it, so it needs list rows,
/// an editor sheet and room to type; and it belongs to the review path, which the other tabs do not
/// cover — Sync is about staying in step with GitHub, Agents/Intelligence/Delegation are the AI
/// cluster, Automation points outward, Appearance is chrome. It sits directly after Sync, before
/// that cluster, so the review-writing preferences are next to the inbox ones.
struct RepliesSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment

    /// The saved reply the editor sheet is open on, if any. A row being edited *or* a fresh one.
    @State private var editingReply: SavedReply?
    /// The template the editor sheet is open on, if any.
    @State private var editingTemplate: ReviewTemplate?

    var body: some View {
        SettingsPage {
            repliesCard
            templatesCard
        }
        .sheet(item: $editingReply) { reply in
            SavedReplyEditor(reply: reply) { edited in
                environment.settings.upsert(savedReply: edited)
            }
        }
        .sheet(item: $editingTemplate) { template in
            ReviewTemplateEditor(template: template) { edited in
                environment.settings.upsert(reviewTemplate: edited)
            }
        }
    }

    // MARK: - Saved replies

    private var repliesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "SAVED REPLIES"))
                Text(String(
                    localized: "Named pieces of Markdown you can drop into any comment field: the inline comment composer, the review summary, and a thread reply. The insert button next to each field lists them in this order, so put the ones you use most at the top."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

                if environment.settings.savedReplies.isEmpty {
                    Text(String(localized: "None yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }

                ForEach(environment.settings.savedReplies) { reply in
                    row(
                        title: reply.trimmedName.isEmpty
                            ? String(localized: "Unnamed reply")
                            : reply.trimmedName,
                        detail: preview(of: reply.body),
                        isUsable: reply.isUsable,
                        onUp: { environment.settings.moveSavedReply(id: reply.id, by: -1) },
                        onDown: { environment.settings.moveSavedReply(id: reply.id, by: 1) },
                        onEdit: { editingReply = reply },
                        onRemove: { environment.settings.deleteSavedReply(id: reply.id) }
                    )
                }

                Divider().overlay(Theme.hairline)

                Button(String(localized: "Add a saved reply")) {
                    editingReply = SavedReply(name: "", body: "")
                }
                .buttonStyle(SecondaryButtonStyle(height: 28))
            }
        }
    }

    // MARK: - Review templates

    private var templatesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "REVIEW TEMPLATES"))
                Text(String(
                    localized: "A summary a new review starts from, per repository. Match one repository with schnaq/review or a whole owner with schnaq/* — * and ? are the wildcards. An exact pattern wins over a wildcard, a longer wildcard wins over a shorter one, and if two are equally specific the one listed first wins."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                Text(String(
                    localized: "A template only ever fills an empty review. A pull request you have already written a comment, a summary or a verdict for is never touched."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

                if environment.settings.reviewTemplates.isEmpty {
                    Text(String(localized: "None yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }

                ForEach(environment.settings.reviewTemplates) { template in
                    row(
                        title: template.trimmedPattern.isEmpty
                            ? String(localized: "No pattern")
                            : template.trimmedPattern,
                        detail: preview(of: template.body),
                        isUsable: template.isUsable,
                        isTitleMonospaced: true,
                        onUp: { environment.settings.moveReviewTemplate(id: template.id, by: -1) },
                        onDown: { environment.settings.moveReviewTemplate(id: template.id, by: 1) },
                        onEdit: { editingTemplate = template },
                        onRemove: { environment.settings.deleteReviewTemplate(id: template.id) }
                    )
                }

                Divider().overlay(Theme.hairline)

                Button(String(localized: "Add a template")) {
                    editingTemplate = ReviewTemplate(pattern: "", body: "")
                }
                .buttonStyle(SecondaryButtonStyle(height: 28))
            }
        }
    }

    // MARK: - Shared row

    /// One list row: name, a one-line preview, reorder, edit, remove.
    ///
    /// Reordering is two arrow buttons rather than drag-and-drop: the rows live in a `Card` inside a
    /// `ScrollView`, not in a `List`, so `onMove` has nothing to hang off — and a keyboard-reachable
    /// button pair is the cheaper *and* the more accessible of the two.
    @ViewBuilder
    private func row(
        title: String,
        detail: String,
        isUsable: Bool,
        isTitleMonospaced: Bool = false,
        onUp: @escaping () -> Void,
        onDown: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(isTitleMonospaced ? Theme.mono(12) : .system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !isUsable {
                        ChipView(
                            text: String(localized: "incomplete"),
                            color: Theme.pending,
                            size: 10
                        )
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Button(action: onUp) {
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help(String(localized: "Move up"))
            Button(action: onDown) {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help(String(localized: "Move down"))
            Button(String(localized: "Edit"), action: onEdit)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accentText)
            Button(String(localized: "Remove"), action: onRemove)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.failure)
        }
    }

    /// The first non-empty line of a body, for the row's second line.
    private func preview(of body: String) -> String {
        let line = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line, !line.isEmpty else { return String(localized: "Empty") }
        return line
    }
}

// MARK: - Editors

/// The sheet that edits one saved reply: a name and a Markdown body.
struct SavedReplyEditor: View {
    @Environment(\.dismiss) private var dismiss
    /// The reply being edited — an existing row, or a fresh one that is only stored on save.
    let reply: SavedReply
    /// Called with the edited reply when the user saves.
    var onSave: (SavedReply) -> Void

    @State private var name: String
    /// The reply body. Named `text` rather than `body` because `body` is `View`'s own requirement.
    @State private var text: String

    /// Creates the editor.
    /// - Parameters:
    ///   - reply: The reply to edit.
    ///   - onSave: Called with the edited reply when the user saves.
    init(reply: SavedReply, onSave: @escaping (SavedReply) -> Void) {
        self.reply = reply
        self.onSave = onSave
        _name = State(initialValue: reply.name)
        _text = State(initialValue: reply.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Saved reply"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textStrong)

            LabeledField(
                label: String(localized: "Name"),
                placeholder: String(localized: "Needs a test"),
                text: $name
            )
            // A saved reply's name is one line the user has to recognise in a menu, so Writing
            // Tools is `.limited` here: proofreading yes, a rewrite panel over a three-word label
            // no (ADR 0020). The body below is the prose, and it is a `ComposerTextEditor`, which
            // is where `.complete` lives.
            .writingToolsBehavior(.limited)

            VStack(alignment: .leading, spacing: 6) {
                CardTitle(String(localized: "BODY"))
                ComposerTextEditor(text: $text, height: 200)
            }

            Text(String(
                localized: "Markdown, inserted exactly as typed. It is appended to whatever the comment field already holds, after a blank line."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) {
                    onSave(SavedReply(id: reply.id, name: name, body: text))
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
    }

    /// A reply needs both halves: a name to recognise in the menu and something to insert.
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The sheet that edits one review template: an `owner/name` pattern and a Markdown summary.
struct ReviewTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    /// The template being edited — an existing row, or a fresh one that is only stored on save.
    let template: ReviewTemplate
    /// Called with the edited template when the user saves.
    var onSave: (ReviewTemplate) -> Void

    @State private var pattern: String
    @State private var text: String

    /// Creates the editor.
    /// - Parameters:
    ///   - template: The template to edit.
    ///   - onSave: Called with the edited template when the user saves.
    init(template: ReviewTemplate, onSave: @escaping (ReviewTemplate) -> Void) {
        self.template = template
        self.onSave = onSave
        _pattern = State(initialValue: template.pattern)
        _text = State(initialValue: template.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Review template"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textStrong)

            LabeledField(
                label: String(localized: "Repos"),
                placeholder: "schnaq/*",
                text: $pattern
            )
            // `owner/name` with `*`/`?` wildcards is not language, and a proofreader that
            // "corrected" it would break the match rule that decides which template a repository
            // gets. Writing Tools is off here on purpose (ADR 0020).
            .writingToolsBehavior(.disabled)

            if !patternLooksLikeARepository {
                Text(String(
                    localized: "Patterns are matched against owner/name, so a pattern without a “/” never matches anything."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.pending)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                CardTitle(String(localized: "SUMMARY"))
                ComposerTextEditor(text: $text, height: 200)
            }

            Text(String(
                localized: "Used as the summary of a new review on a matching repository. An existing draft — a comment, a summary, a verdict — is never overwritten."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) {
                    onSave(
                        ReviewTemplate(
                            id: template.id,
                            pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines),
                            body: text
                        )
                    )
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
    }

    private var canSave: Bool {
        !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var patternLooksLikeARepository: Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("/") || trimmed == "*"
    }
}
