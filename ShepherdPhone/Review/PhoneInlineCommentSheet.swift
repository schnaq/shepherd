import ShepherdCore
import SwiftUI

/// The sheet that writes an inline comment on the line or lines picked in ``PhoneDiffView``
/// (ADR 0044).
///
/// Presented from ``ReviewModel/composerRequest`` by the pull request screen, the one presenter for
/// every screen of the pull request. Only ``ReviewModel/handle(_:)`` sets the request — so it
/// opens for exactly the anchors the Mac's composer opens for — and it is saved through the model's
/// own ``ReviewModel/saveDraftComment(_:body:)``, with its anchor check, into the pending review.
/// The behaviour is the Mac `InlineCommentComposer`'s, in GitHub's words: *Start a review* or
/// *Add review comment* keeps the comment for the review, *Comment* posts it on its own at once,
/// and an existing pending comment opens for editing with *Delete* beside it. The buttons sit in a
/// bar at the bottom, above the keyboard, with the review's own button the prominent one. A head-side comment
/// can start a ```` ```suggestion ```` block of the commented lines, and the saved replies are a
/// menu beside it; the Mac's AI draft and session hand-off are not on the phone in v1.
///
/// Typed text is never lost by accident: a swipe down does not close the sheet while it holds
/// unsaved text, and Cancel asks first. The diff behind is not interactive — a long press there
/// would replace the request and reopen the sheet empty, and Back would take the sheet with it;
/// the commented lines are quoted at the top instead.
struct PhoneInlineCommentSheet: View {
    /// The review model.
    let model: ReviewModel
    /// Where the comment is anchored.
    let request: ReviewModel.ComposerRequest

    @Environment(PhoneEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var text = ""
    @State private var errorMessage: String?
    @State private var saved = 0
    @State private var isConfirmingDiscard = false
    @FocusState private var isEditorFocused: Bool

    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 12

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    quotedLines
                    TextField(
                        String(localized: "Leave a comment"),
                        text: $text,
                        axis: .vertical
                    )
                    .lineLimit(5...)
                    .font(Theme.type(.body))
                    .foregroundStyle(Theme.text)
                    .focused($isEditorFocused)
                    .padding(12)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isEditorFocused ? Theme.accent.opacity(0.6) : Theme.border)
                    )

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.type(.footnote))
                            .foregroundStyle(Theme.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 16) {
                        if request.side == .right {
                            Button {
                                insertSuggestion()
                            } label: {
                                // Its word as well as its glyph: "+/−" alone said nothing.
                                Label(String(localized: "Suggest"), systemImage: "plus.forwardslash.minus")
                            }
                            .accessibilityLabel(Text(String(localized: "Add a suggestion")))
                        }
                        PhoneSavedReplyMenu(replies: model.settings.usableSavedReplies) { snippet in
                            text = SavedReply.inserting(snippet, into: text)
                        }
                        .labelStyle(.iconOnly)
                        Spacer(minLength: 0)
                    }
                    .font(Theme.type(.subheadline, weight: .medium))
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.panel)
            .safeAreaBar(edge: .bottom) { actionBar }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        if hasUnsavedText { isConfirmingDiscard = true } else { dismiss() }
                    } label: {
                        Label(String(localized: "Cancel"), systemImage: "xmark")
                    }
                    .confirmationDialog(
                        String(localized: "Discard this comment?"),
                        isPresented: $isConfirmingDiscard,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Discard"), role: .destructive) { dismiss() }
                    }
                }
                // The title and the file by hand rather than as a navigation subtitle, which cannot
                // be cut in the middle: cut at the end it lost the extension ("…-outbox.m…").
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(title)
                            .font(Theme.type(.headline))
                            .foregroundStyle(Theme.textStrong)
                        Text(anchorDescription)
                            .font(Theme.type(.caption))
                            .foregroundStyle(Theme.textSecondary)
                            .truncationMode(.middle)
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .presentationDetents([.fraction(0.5), .large])
        .interactiveDismissDisabled(hasUnsavedText)
        .sensoryFeedback(.success, trigger: saved)
        .onAppear {
            text = existingComment?.body ?? ""
            isEditorFocused = true
        }
    }

    /// The sheet's buttons, side by side above the keyboard (stacked at the accessibility sizes):
    /// *Comment* — post it alone, now — and the review's own button, the prominent one; *Delete*
    /// in *Comment*'s place for a pending comment being edited.
    private var actionBar: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if startsReview {
                Button {
                    Task { await postSingleComment() }
                } label: {
                    Text(String(localized: "Comment"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(isBlank || isSaving)
            }
            if let existing = existingComment {
                Button(role: .destructive) {
                    Task { await delete(existing) }
                } label: {
                    Text(String(localized: "Delete"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .tint(Theme.failure)
            }
            Button {
                Task { await save() }
            } label: {
                Text(saveTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(isBlank || isSaving)
        }
        .font(Theme.type(.body, weight: .semibold))
        .lineLimit(1)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The lines being commented on, as they read in the diff — at most six, so a long range does
    /// not push the field off the small detent.
    @ViewBuilder
    private var quotedLines: some View {
        let lines = commentedLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.prefix(6).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.isEmpty ? " " : line)
                        .font(Theme.mono(codeSize))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if lines.count > 6 {
                    Text(String(localized: "+\(lines.count - 6) more lines"))
                        .font(Theme.type(.caption))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                    .fill(request.side == .left ? Theme.failure : Theme.accent)
                    .frame(width: 3)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Facts

    private var commentedLines: [String] {
        guard let content = model.selectedListContent, content.path == request.path else { return [] }
        let range = (request.startLine ?? request.line)...request.line
        return content.rows.compactMap { row in
            guard case .line(let line) = row else { return nil }
            let identity = DiffListContent.lineIdentity(of: line)
            return identity.side == request.side && range.contains(identity.line) ? line.text : nil
        }
    }

    private var existingComment: DraftComment? {
        model.draft?.comments.first {
            $0.path == request.path && $0.line == request.line && $0.side == request.side
                && $0.startLine == request.startLine
        }
    }

    /// GitHub's rule: the first comment of a review starts it.
    private var startsReview: Bool {
        existingComment == nil && (model.draft?.comments.isEmpty ?? true)
    }

    private var saveTitle: String {
        if existingComment != nil { return String(localized: "Update comment") }
        return startsReview ? String(localized: "Start a review") : String(localized: "Add review comment")
    }

    /// Short, because the bar also carries GitHub's button title beside it; the verb is the
    /// button's and the file is the subtitle.
    private var title: String {
        if let start = request.startLine, start != request.line {
            return String(localized: "Lines \(start)–\(request.line)")
        }
        return String(localized: "Line \(request.line)")
    }

    private var anchorDescription: String {
        let side = request.side == .left ? String(localized: "base") : String(localized: "head")
        return "\(PhoneFilesScreen.fileName(request.path)) · \(side)"
    }

    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Whether closing would lose writing: text in a new comment, or a change to a pending one.
    private var hasUnsavedText: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            != (existingComment?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Marked on the activity tracker like the Mac's, so a double tap cannot write it twice.
    private var isSaving: Bool { environment.activity.isRunning(model.prID, .reply) }

    // MARK: - Writes

    /// Appends a ```` ```suggestion ```` block holding the commented lines of the head side.
    private func insertSuggestion() {
        guard request.path == model.selectedPath,
              let document = model.currentReconstruction?.modified,
              let block = Self.suggestionBlock(document: document, startLine: request.startLine, line: request.line)
        else { return }
        text = text.isEmpty ? block : text + "\n" + block
    }

    /// GitHub's suggestion block over lines `startLine...line` of `document` (1-based), or `nil`
    /// when they are not in it — the Mac's `SuggestionBlock.make`, which lives in a Mac-only file.
    static func suggestionBlock(document: String, startLine: Int?, line: Int) -> String? {
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
        let start = startLine ?? line
        guard start >= 1, start <= line, line <= lines.count else { return nil }
        return "```suggestion\n" + lines[(start - 1)..<line].joined(separator: "\n") + "\n```"
    }

    private func save() async {
        await environment.activity.run(model.prID, .reply) {
            do {
                try await model.saveDraftComment(request, body: text)
                saved += 1
                dismiss()
            } catch {
                errorMessage = error.userFacingDescription
            }
        }
    }

    /// Posts the comment on its own, pinned to the head being read — the Mac's *Comment*, with
    /// the same anchor check, because GitHub refuses a padding line here too.
    private func postSingleComment() async {
        guard let summary = model.summary else { return }
        do {
            try model.validateAnchor(of: request)
        } catch {
            errorMessage = error.userFacingDescription
            return
        }
        let comment = DraftComment(
            path: request.path,
            line: request.line,
            side: request.side,
            startLine: request.startLine,
            body: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard await environment.actions(for: model.session).addReviewComment(comment, on: summary) else { return }
        saved += 1
        dismiss()
    }

    /// Deletes the pending comment and stays open with the reason when the database refuses —
    /// the Mac composer's rule, so a comment that was not deleted never looks deleted.
    private func delete(_ comment: DraftComment) async {
        do {
            try await model.deleteDraftComment(localID: comment.localID)
            dismiss()
        } catch {
            errorMessage = String(localized: "Could not delete the comment: \(error.userFacingDescription)")
        }
    }
}
