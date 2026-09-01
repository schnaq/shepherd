import ShepherdCore
import SwiftUI

/// The bar under the diff: pending-comment count and the three review verdicts.
struct ReviewComposerBar: View {
    /// The review model.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11))
                Text(pendingText)
            }
            .font(.system(size: 12))
            .foregroundStyle(model.pendingCommentCount > 0 ? Theme.accentText : Theme.textMuted)

            if model.isFullyReviewed {
                ChipView(text: String(localized: "All files viewed"), color: Theme.success, size: 10.5)
            }

            Spacer(minLength: 8)

            Button {
                start(.comment)
            } label: {
                Text(String(localized: "Comment"))
            }
            .buttonStyle(SecondaryButtonStyle(height: 30))
            .help(String(localized: "Comment (r c)"))

            Button {
                start(.requestChanges)
            } label: {
                Text(String(localized: "Request changes"))
            }
            .buttonStyle(SecondaryButtonStyle(height: 30, tint: Theme.failure))
            .help(String(localized: "Request changes (r x)"))

            Button {
                start(.approve)
            } label: {
                HStack(spacing: 6) {
                    Text(String(localized: "Submit review"))
                    KeyCapView(keys: "⌘⏎")
                }
            }
            .buttonStyle(SuccessButtonStyle(height: 30))
            .keyboardShortcut(.return, modifiers: .command)
            .help(String(localized: "Submit review (⌘⏎)"))
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Theme.panel)
    }

    private var pendingText: String {
        let count = model.pendingCommentCount
        if count == 0 { return String(localized: "No pending comments") }
        return String(localized: "\(count) pending comments in this review")
    }

    private func start(_ verdict: ReviewVerdict) {
        model.pendingVerdict = verdict
        model.isSubmitSheetPresented = true
    }
}

/// The submit sheet: summary text plus the verdict picker.
struct SubmitReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The review model.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions

    /// The summary field's AI-drafting state (ADR 0007 amendment).
    @State private var aiDraft = AIDraftFieldState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Submit review"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textStrong)

            if let summary = model.summary {
                Text(summary.slug)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    CardTitle(String(localized: "SUMMARY"))
                    Spacer(minLength: 4)
                    if model.canDraftWithAI {
                        AIDraftButton(isDrafting: aiDraft.isDrafting) {
                            Task { await requestSummaryDraft() }
                        }
                    }
                    SavedReplyMenu(replies: model.settings.usableSavedReplies) { snippet in
                        model.summaryText = SavedReply.inserting(snippet, into: model.summaryText)
                    }
                }
                ComposerTextEditor(text: summaryBinding, height: 130)
                AIDraftStatusView(
                    state: aiDraft,
                    confirmationTitle: String(localized: "Replace current summary?"),
                    onReplace: { apply(aiDraft.replaceWithPendingDraft()) },
                    onAppend: { apply(aiDraft.appendPendingDraft(to: model.summaryText)) },
                    onDiscard: { aiDraft.discardPendingDraft() }
                )
            }

            Picker(String(localized: "Verdict"), selection: verdictBinding) {
                Text(String(localized: "Comment")).tag(ReviewVerdict.comment)
                Text(String(localized: "Approve")).tag(ReviewVerdict.approve)
                Text(String(localized: "Request changes")).tag(ReviewVerdict.requestChanges)
            }
            .pickerStyle(.radioGroup)

            if model.pendingCommentCount > 0 {
                Text(String(
                    localized: "\(model.pendingCommentCount) inline comments will be sent with this review."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            }

            if needsSummary {
                Text(String(
                    localized: "GitHub requires a summary for this verdict — only an approval may be submitted without one."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.pending)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(String(
                localized: "The review is queued in the local outbox and sent by the sync engine, so it survives a crash or a lost connection."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await model.submit(verdict: model.pendingVerdict, actions: actions)
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if model.isSubmitting { ProgressView().controlSize(.small) }
                        Text(String(localized: "Submit"))
                    }
                }
                .buttonStyle(SuccessButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSubmitting || needsSummary)
                .help(needsSummary
                    ? String(localized: "Write a summary first — GitHub rejects a “request changes” or “comment” review without one.")
                    : String(localized: "Queue the review"))
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
        .onChange(of: model.summaryText) { _, text in
            aiDraft.fieldChanged(to: text)
        }
    }

    // MARK: - AI drafting

    /// Asks the intelligence layer for a summary suggestion.
    ///
    /// Started only by the button's click, and its only effect is on the text field: the verdict
    /// picker and the Submit button are untouched (ADR 0007 non-goal — nothing auto-submits).
    private func requestSummaryDraft() async {
        aiDraft.begin()
        let outcome = await model.draftReviewSummary()
        apply(aiDraft.finish(outcome, existingText: model.summaryText))
    }

    /// Writes text the drafting state produced into the field, when it produced any.
    private func apply(_ text: String?) {
        guard let text else { return }
        model.summaryText = text
    }

    /// Whether the verdict needs a summary the user has not written.
    ///
    /// `POST /pulls/{n}/reviews` documents `body` as required for `REQUEST_CHANGES` and
    /// `COMMENT`; submitting without one is a 422, which is not retryable, so the outbox row
    /// is parked failed and the review is lost. Only `APPROVE` may go out bare.
    private var needsSummary: Bool {
        model.pendingVerdict != .approve
            && model.summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var summaryBinding: Binding<String> {
        Binding(get: { model.summaryText }, set: { model.summaryText = $0 })
    }

    private var verdictBinding: Binding<ReviewVerdict> {
        Binding(get: { model.pendingVerdict }, set: { model.pendingVerdict = $0 })
    }
}

/// The native composer that opens when the user clicks a gutter “+”.
///
/// Text entry never happens inside the webview — that is the bridge's rule.
struct InlineCommentComposer: View {
    @Environment(\.dismiss) private var dismiss
    /// The review model.
    let model: ReviewModel
    /// Where the comment is anchored.
    let request: ReviewModel.ComposerRequest

    @State private var commentText = ""
    @State private var errorMessage: String?
    /// The comment field's AI-drafting state (ADR 0007 amendment).
    @State private var aiDraft = AIDraftFieldState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Comment on line \(request.line)"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                    Text(anchorDescription)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if model.canDraftWithAI {
                    AIDraftButton(isDrafting: aiDraft.isDrafting) {
                        Task { await requestCommentDraft() }
                    }
                }
                SavedReplyMenu(replies: model.settings.usableSavedReplies) { snippet in
                    commentText = SavedReply.inserting(snippet, into: commentText)
                }
            }

            ComposerTextEditor(text: $commentText, height: 120)

            AIDraftStatusView(
                state: aiDraft,
                confirmationTitle: String(localized: "Replace this comment?"),
                onReplace: { apply(aiDraft.replaceWithPendingDraft()) },
                onAppend: { apply(aiDraft.appendPendingDraft(to: commentText)) },
                onDiscard: { aiDraft.discardPendingDraft() }
            )

            Text(String(localized: "Saved to your pending review — nothing is sent until you submit."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure)
            }

            HStack {
                if existingComment != nil {
                    Button(String(localized: "Delete")) {
                        Task {
                            if let existing = existingComment {
                                try? await model.deleteDraftComment(localID: existing.localID)
                            }
                            dismiss()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.failure))
                }
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add comment")) {
                    Task { await save() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.panel)
        .onAppear {
            commentText = existingComment?.body ?? ""
        }
        .onChange(of: commentText) { _, text in
            aiDraft.fieldChanged(to: text)
        }
    }

    // MARK: - AI drafting

    /// Asks the intelligence layer for a comment suggestion about this line.
    ///
    /// The context is the file path and the diff around the anchored line, capped by
    /// ``InlineCommentDraftBuilder`` — and it goes only to the provider the user configured
    /// themselves (`CONTRIBUTING.md`, "the complete list of hosts Shepherd may contact").
    private func requestCommentDraft() async {
        aiDraft.begin()
        let outcome = await model.draftInlineComment(for: request)
        apply(aiDraft.finish(outcome, existingText: commentText))
    }

    /// Writes text the drafting state produced into the field, when it produced any.
    private func apply(_ text: String?) {
        guard let text else { return }
        commentText = text
    }

    private var existingComment: DraftComment? {
        model.draft?.comments.first {
            $0.path == request.path && $0.line == request.line && $0.side == request.side
        }
    }

    private var anchorDescription: String {
        let side = request.side == .left
            ? String(localized: "base")
            : String(localized: "head")
        if let start = request.startLine, start != request.line {
            return "\(request.path) · \(side) \(start)–\(request.line)"
        }
        return "\(request.path) · \(side)"
    }

    private func save() async {
        do {
            try await model.saveDraftComment(request, body: commentText)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

/// The native thread panel opened by clicking a comment card in the diff.
struct ThreadPopover: View {
    @Environment(AppEnvironment.self) private var environment
    /// The thread being shown.
    let thread: ReviewThread
    /// The pull request the thread belongs to.
    let summary: PullRequestSummary
    /// The write actions.
    let actions: PullRequestActions
    /// Closes the popover.
    var onClose: () -> Void

    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(thread.comments) { comment in
                        ThreadCommentView(comment: comment)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 260)
            Divider().overlay(Theme.border)
            replyBar
        }
        .frame(width: 380)
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(thread.path ?? String(localized: "Pull request conversation"))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.head)
            if let line = thread.line {
                Text(String(localized: "line \(line)"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 4)
            if thread.isOutdated {
                ChipView(text: String(localized: "outdated"), color: Theme.pending, size: 10)
            }
            if thread.isResolved {
                ChipView(text: String(localized: "resolved"), color: Theme.success, size: 10)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var replyBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField(String(localized: "Reply…"), text: $replyText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...4)
                    .padding(8)
                    .background(
                        Theme.control,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                SavedReplyMenu(
                    replies: environment.settings.usableSavedReplies,
                    onInsert: { snippet in
                        replyText = SavedReply.inserting(snippet, into: replyText)
                    },
                    height: 30
                )
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        await actions.setThread(
                            on: summary,
                            threadID: thread.id,
                            resolved: !thread.isResolved
                        )
                        onClose()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: thread.isResolved ? "arrow.uturn.backward" : "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text(thread.isResolved
                            ? String(localized: "Unresolve")
                            : String(localized: "Resolve"))
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: 28))

                Button {
                    environment.startDelegation(
                        .reviewFinding(summary, thread: thread)
                    )
                    onClose()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward.badge.clock")
                            .font(.system(size: 10, weight: .bold))
                        Text(String(localized: "Delegate…"))
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: 28, tint: Theme.agent))
                .help(String(localized: "Hand this finding to your local coding agent"))

                Spacer()

                Button(String(localized: "Reply")) {
                    Task { await sendReply() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || replyTargetID == nil)
                .help(replyTargetID == nil
                    ? String(localized: "GitHub did not send a database id for this thread, so Shepherd cannot reply to it here.")
                    : String(localized: "Queue a reply"))
            }
        }
        .padding(12)
    }

    private var replyTargetID: Int? {
        thread.comments.compactMap(\.databaseID).last
    }

    private func sendReply() async {
        guard let target = replyTargetID else { return }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyText = ""
        await actions.reply(on: summary, commentDatabaseID: target, body: text)
        onClose()
    }
}

/// One comment inside the thread panel.
struct ThreadCommentView: View {
    /// The comment.
    let comment: ReviewComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(actor: comment.author, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(comment.author.bestName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                    if let identity = comment.author.kind.agentIdentity {
                        ChipView(text: identity.displayName, color: Theme.agent, size: 10)
                    }
                    RelativeDateText(date: comment.createdAt, style: .long)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                MarkdownText(markdown: comment.bodyMarkdown)
            }
        }
    }
}

/// Renders Markdown natively with `AttributedString`, for text that never leaves the app.
struct MarkdownText: View {
    /// The Markdown source.
    let markdown: String
    /// The font size.
    var size: CGFloat = 12.5

    var body: some View {
        Text(attributed)
            .font(.system(size: size))
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(markdown)
    }
}
