import ShepherdCore
import SwiftUI

/// The inline comment composer on the phone (ADR 0044): one diff line or range, a field, and
/// GitHub's pair — the Mac's `InlineCommentComposer`, minus the AI drafting and the session send.
///
/// Opened for a ``ReviewModel/ComposerRequest`` — the diff raises one through
/// ``ReviewModel/handle(_:)``, the submit sheet for a pending comment — and presented by
/// ``PhonePullRequestScreen``, which owns `composerRequest` for every screen of the pull request.
/// The writes are the model's: ``ReviewModel/saveDraftComment(_:body:)`` keeps the comment in the
/// pending review, ``PullRequestActions/addReviewComment(_:on:)`` posts it on its own, and both
/// check the anchor first (``ReviewModel/validateAnchor(of:)``) so a padding line is refused here,
/// with the reason in the sheet, rather than by GitHub dropping the whole review.
///
/// The sheet stops at a fraction of the screen and leaves the diff behind it interactive, so the
/// lines being commented on stay in view.
struct PhoneCommentComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PhoneEnvironment.self) private var environment
    /// The review model.
    let model: ReviewModel
    /// Where the comment is anchored.
    let request: ReviewModel.ComposerRequest

    @State private var text = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(anchorDescription)
                    .font(Theme.mono(.footnote))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                TextField(String(localized: "Leave a comment"), text: $text, axis: .vertical)
                    .font(Theme.type(.body))
                    .lineLimit(4...)
                    .focused($isFocused)
                    .padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .phoneInputField()
                HStack(spacing: 12) {
                    if request.side == .right {
                        Button {
                            insertSuggestion()
                        } label: {
                            Label(String(localized: "Add a suggestion"), systemImage: "plus.forwardslash.minus")
                        }
                        .labelStyle(.iconOnly)
                    }
                    PhoneSavedReplyMenu(replies: model.settings.usableSavedReplies) { snippet in
                        text = SavedReply.inserting(snippet, into: text)
                    }
                    .labelStyle(.iconOnly)
                    Spacer(minLength: 0)
                    if let existing = existingComment {
                        Button(String(localized: "Delete"), role: .destructive) {
                            Task { await delete(existing) }
                        }
                        .buttonStyle(.bordered)
                    } else if startsReview {
                        // GitHub's *Comment*: published at once and not taken back.
                        Button(String(localized: "Comment")) {
                            Task { await postSingleComment() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving || isBlank)
                    }
                }
                Text(startsReview
                    ? String(localized: "Comment posts it now. Start a review keeps it with your other comments until you submit.")
                    : String(localized: "Saved to your pending review — nothing is sent until you submit."))
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.type(.footnote))
                        .foregroundStyle(Theme.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        Text(saveTitle)
                            .busyLabel(isBusy: isSaving)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(isBlank)
                }
            }
        }
        .presentationDetents([.fraction(0.45), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
        .onAppear {
            text = existingComment?.body ?? ""
            isFocused = true
        }
    }

    // MARK: - Derived

    private var existingComment: DraftComment? {
        model.draft?.comments.first {
            $0.path == request.path && $0.line == request.line && $0.side == request.side
                && $0.startLine == request.startLine
        }
    }

    /// Whether this comment would start the review — GitHub then offers *Comment* beside it.
    private var startsReview: Bool {
        existingComment == nil && (model.draft?.comments.isEmpty ?? true)
    }

    private var saveTitle: String {
        if existingComment != nil { return String(localized: "Update comment") }
        return startsReview ? String(localized: "Start a review") : String(localized: "Add review comment")
    }

    private var title: String {
        if let start = request.startLine, start != request.line {
            return String(localized: "Comment on lines \(start)–\(request.line)")
        }
        return String(localized: "Comment on line \(request.line)")
    }

    private var anchorDescription: String {
        let side = request.side == .left ? String(localized: "base") : String(localized: "head")
        if let start = request.startLine, start != request.line {
            return "\(request.path) · \(side) \(start)–\(request.line)"
        }
        return "\(request.path) · \(side)"
    }

    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The pending comment is a local row, not an outbox write, but it is marked on the same
    /// tracker so a double tap cannot write it twice (the Mac composer's rule).
    private var isSaving: Bool { environment.activity.isRunning(model.prID, .reply) }

    // MARK: - Actions

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
                dismiss()
            } catch {
                errorMessage = error.userFacingDescription
            }
        }
    }

    /// Posts the comment on its own, pinned to the head being read, after the same anchor check.
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
        dismiss()
    }

    private func delete(_ comment: DraftComment) async {
        do {
            try await model.deleteDraftComment(localID: comment.localID)
            dismiss()
        } catch {
            errorMessage = String(localized: "Could not delete the comment: \(error.userFacingDescription)")
        }
    }
}

/// One published review thread in a sheet — what the diff opens when a thread's marker is tapped
/// (``ReviewModel/activeThreadID``), presented by ``PhonePullRequestScreen``.
///
/// The card is the conversation's own (``PhoneThreadView``) — comments, reactions, edits, reply and
/// *Resolve* — so a thread reads and answers the same in the stream and over the diff. No *Show in
/// diff*: the diff is what is behind the sheet.
struct PhoneThreadSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ReviewModel
    let actions: PullRequestActions
    let summary: PullRequestSummary
    let thread: ReviewThread

    var body: some View {
        NavigationStack {
            ScrollView {
                PhoneThreadView(model: model, actions: actions, summary: summary, thread: thread, isAlwaysExpanded: true)
                    .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(String(localized: "Conversation"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                if let url = thread.comments.first?.url {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Open on GitHub"), systemImage: "safari") { PlatformServices.open(url) }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
