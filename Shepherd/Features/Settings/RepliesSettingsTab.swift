import ShepherdCore
import SwiftUI

/// Settings → Replies: the reusable review text — saved replies and per-repository templates.
///
/// A tab of its own rather than a section on an existing one, for two reasons. It is the only place in
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
            repliesSection
            templatesSection
            recurringFindingsSection
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

    private var repliesSection: some View {
        Section {
            if environment.settings.savedReplies.isEmpty {
                Text(String(localized: "None yet."))
                    .foregroundStyle(.secondary)
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

            addRow(String(localized: "Add a saved reply")) {
                editingReply = SavedReply(name: "", body: "")
            }
        } header: {
            Text(String(localized: "Saved replies"))
        } footer: {
            SettingsNote(String(
                localized: "Markdown for any comment field. The insert menu lists them in this order."
            ))
        }
    }

    // MARK: - Review templates

    private var templatesSection: some View {
        Section {
            if environment.settings.reviewTemplates.isEmpty {
                Text(String(localized: "None yet."))
                    .foregroundStyle(.secondary)
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

            addRow(String(localized: "Add a template")) {
                editingTemplate = ReviewTemplate(pattern: "", body: "")
            }
        } header: {
            HStack(spacing: 4) {
                Text(String(localized: "Review templates"))
                InfoButton(String(
                    localized: "Match one repository with schnaq/review or a whole owner with schnaq/* — * and ? are the wildcards. An exact pattern wins over a wildcard, a longer wildcard over a shorter one; on a tie, the one listed first wins."
                ))
            }
        } footer: {
            SettingsNote(String(
                localized: "The summary a new review starts from. A review you already started is never touched."
            ))
        }
    }

    // MARK: - Recurring findings

    /// What Shepherd has noticed the reviewer keeps writing, per repository (ADR 0029).
    ///
    /// It belongs on this tab rather than on Delegation or Intelligence for the reason the tab
    /// exists at all: these are the reviewer's own review sentences, which is what every other
    /// section here is about. It is a *list*, not a setting — there is nothing to configure, the
    /// thresholds are documented constants in `ShepherdCore`, and the only control is the one that
    /// undoes a dismissal.
    ///
    /// Read-only otherwise, and deliberately: the button that turns a finding into a rule lives on
    /// the review screen, where the pull request that becomes the agent's worktree is on screen.
    /// Settings has no pull request, so a *Draft a rule* here would have nothing to delegate
    /// against.
    private var recurringFindingsSection: some View {
        Section {
            let findings = environment.recurringFindings.everyFinding
            if findings.isEmpty {
                Text(String(localized: "Nothing yet."))
                    .foregroundStyle(.secondary)
            }

            ForEach(findings) { finding in
                findingRow(finding)
            }
        } header: {
            HStack(spacing: 4) {
                Text(String(localized: "Recurring findings"))
                InfoButton(String(
                    localized: "A comment you wrote at least three times in thirty days, on at least two pull requests of the same repository. On the review screen each one offers to draft a rule for that repository's agent instructions."
                ))
            }
        } footer: {
            SettingsNote(String(
                localized: "Found on this Mac from your own comments; never sent anywhere."
            ))
        }
    }

    /// One finding: the repository, the exemplar, how often, and whether it is hidden.
    @ViewBuilder
    private func findingRow(_ finding: RecurringFinding) -> some View {
        let isDismissed = environment.recurringFindings.isDismissed(finding)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.repo.fullName)
                        .font(Theme.mono(.callout))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Not localised: a count and a multiplication sign read the same in every
                    // language Shepherd speaks, and a plural rule for "3×" would be inventing a
                    // problem.
                    ChipView(
                        text: "\(finding.count)×",
                        color: Theme.prioritySecondary,
                        size: 10
                    )
                    if isDismissed {
                        ChipView(
                            text: String(localized: "hidden"),
                            color: Theme.textMuted,
                            size: 10
                        )
                    }
                }
                // The reviewer's own sentence, so the non-localising `Text` overload.
                Text(finding.exemplar)
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if isDismissed {
                Button(String(localized: "Show again")) {
                    environment.recurringFindings.showAgain(finding)
                }
                .buttonStyle(.borderless)
            } else {
                Button(String(localized: "Hide")) {
                    environment.recurringFindings.dismiss(finding)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Shared rows

    /// One list row: name, a one-line preview, reorder, edit, remove.
    ///
    /// Reordering is two arrow buttons rather than drag-and-drop: the rows are a `ForEach` in a
    /// grouped `Form`, not in a `List`, so `onMove` has nothing to hang off — and a
    /// keyboard-reachable button pair is the cheaper *and* the more accessible of the two.
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
                        .font(isTitleMonospaced ? Theme.mono(.body) : Theme.type(.body))
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
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Button(action: onUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(String(localized: "Move up"))
            Button(action: onDown) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(String(localized: "Move down"))
            Button(String(localized: "Edit"), action: onEdit)
                .buttonStyle(.borderless)
            Button(String(localized: "Remove"), action: onRemove)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.failure)
        }
    }

    /// The last row of a list section: the button that opens the editor on a fresh item.
    private func addRow(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(title, action: action)
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
///
/// A grouped `Form` like the pane it opens from, so ``LabeledField`` — a form row — shows its
/// label, and the Cancel/Save bar sits under it outside the scrolling area.
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
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledField(
                        label: String(localized: "Name"),
                        placeholder: String(localized: "Needs a test"),
                        text: $name
                    )
                    // A saved reply's name is one line the user has to recognise in a menu, so
                    // Writing Tools is `.limited` here: proofreading yes, a rewrite panel over a
                    // three-word label no (ADR 0020). The body below is the prose, and it is a
                    // `ComposerTextEditor`, which is where `.complete` lives.
                    .writingToolsBehavior(.limited)
                } header: {
                    Text(String(localized: "Saved reply"))
                }

                Section {
                    ComposerTextEditor(text: $text, height: 180)
                } header: {
                    Text(String(localized: "Body"))
                } footer: {
                    SettingsNote(String(
                        localized: "Markdown, appended to the comment field after a blank line."
                    ))
                }
            }
            .formStyle(.grouped)

            EditorButtonBar(canSave: canSave) {
                onSave(SavedReply(id: reply.id, name: name, body: text))
                dismiss()
            }
        }
        .frame(width: 480, height: 440)
    }

    /// A reply needs both halves: a name to recognise in the menu and something to insert.
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The sheet that edits one review template: an `owner/name` pattern and a Markdown summary.
///
/// A grouped `Form` for the reason ``SavedReplyEditor`` is one.
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
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledField(
                        label: String(localized: "Repos"),
                        placeholder: "schnaq/*",
                        text: $pattern
                    )
                    // `owner/name` with `*`/`?` wildcards is not language, and a proofreader that
                    // "corrected" it would break the match rule that decides which template a
                    // repository gets. Writing Tools is off here on purpose (ADR 0020).
                    .writingToolsBehavior(.disabled)

                    if !patternLooksLikeARepository {
                        Text(String(
                            localized: "Patterns are matched against owner/name, so a pattern without a “/” never matches anything."
                        ))
                        .font(Theme.type(.caption))
                        .foregroundStyle(Theme.pending)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(String(localized: "Review template"))
                }

                Section {
                    ComposerTextEditor(text: $text, height: 180)
                } header: {
                    Text(String(localized: "Summary"))
                } footer: {
                    SettingsNote(String(
                        localized: "Starts a new review on a matching repository. A draft is never overwritten."
                    ))
                }
            }
            .formStyle(.grouped)

            EditorButtonBar(canSave: canSave) {
                onSave(
                    ReviewTemplate(
                        id: template.id,
                        pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines),
                        body: text
                    )
                )
                dismiss()
            }
        }
        .frame(width: 480, height: 500)
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

/// Cancel and Save under an editor sheet's form, as a native sheet puts them: trailing, with
/// Return and Escape bound.
private struct EditorButtonBar: View {
    @Environment(\.dismiss) private var dismiss
    /// Whether Save is enabled.
    let canSave: Bool
    /// Runs on Save; the caller stores the edit and dismisses.
    let onSave: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Save"), action: onSave)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
