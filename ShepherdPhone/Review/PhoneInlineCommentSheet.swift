import ShepherdCore
import SwiftUI

/// The sheet that writes an inline comment on the line or lines picked in ``PhoneDiffView``
/// (ADR 0044).
///
/// Presented from ``ReviewModel/composerRequest``, which only ``ReviewModel/handle(_:)`` sets — so
/// it opens for exactly the anchors the Mac's composer opens for — and saved through the model's
/// own ``ReviewModel/saveDraftComment(_:body:)``, with its anchor check, into the pending review.
/// The behaviour is the Mac `InlineCommentComposer`'s, in GitHub's words: *Start a review* or
/// *Add review comment* keeps the comment for the review, *Comment* posts it on its own at once,
/// and an existing pending comment opens for editing with *Delete* beside it. The Mac's AI draft,
/// saved replies and session hand-off are not on the phone in v1.
///
/// At its small detent the diff stays live behind it, so the lines being commented on stay in
/// view while the comment is written.
struct PhoneInlineCommentSheet: View {
    /// The review model.
    let model: ReviewModel
    /// Where the comment is anchored.
    let request: ReviewModel.ComposerRequest

    @Environment(PhoneEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?
    @State private var saved = 0
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

                    Text(startsReview
                        ? String(localized: "Comment posts it now. Start a review keeps it with your other comments until you submit.")
                        : String(localized: "Saved to your pending review — nothing is sent until you submit."))
                        .font(Theme.type(.footnote))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.type(.footnote))
                            .foregroundStyle(Theme.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 12) {
                        if startsReview {
                            Button(String(localized: "Comment")) {
                                Task { await postSingleComment() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isBlank || isSaving)
                        }
                        if let existing = existingComment {
                            Button(String(localized: "Delete"), role: .destructive) {
                                Task { await delete(existing) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.large)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.panel)
            .navigationTitle(title)
            .navigationSubtitle(anchorDescription)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    } label: {
                        Label(String(localized: "Cancel"), systemImage: "xmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        Task { await save() }
                    } label: {
                        Text(saveTitle)
                    }
                    .disabled(isBlank || isSaving)
                }
            }
        }
        .presentationDetents([.fraction(0.5), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
        .sensoryFeedback(.success, trigger: saved)
        .onAppear {
            text = existingComment?.body ?? ""
            isEditorFocused = true
        }
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

    /// Marked on the activity tracker like the Mac's, so a double tap cannot write it twice.
    private var isSaving: Bool { environment.activity.isRunning(model.prID, .reply) }

    // MARK: - Writes

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
