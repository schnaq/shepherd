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
            .busy(isSubmittingVerdict)
            .disabled(model.hasEndedOnGitHub)
            .help(String(localized: "Comment (r c)"))

            Button {
                start(.requestChanges)
            } label: {
                Text(String(localized: "Request changes"))
            }
            .buttonStyle(SecondaryButtonStyle(height: 30, tint: Theme.failure))
            .busy(isSubmittingVerdict)
            .disabled(model.hasEndedOnGitHub || model.verdictBlocker != nil)
            .help(blockedHelp(otherwise: String(localized: "Request changes (r x)")))

            Button {
                start(preselectedVerdict)
            } label: {
                HStack(spacing: 6) {
                    Text(
                        preselectedVerdict == .approve
                            ? String(localized: "Approve…")
                            : String(localized: "Review…")
                    )
                    KeyCapView(keys: "⌘⏎", onFilledBackground: true)
                }
            }
            .buttonStyle(SuccessButtonStyle(height: 30))
            .keyboardShortcut(.return, modifiers: .command)
            // The three verdict buttons go dark together once GitHub has merged or closed the
            // pull request under them, because none of the three has anywhere to land any more
            // (``ReviewModel/hasEndedOnGitHub``). `.disabled` takes ⌘⏎ with it — and so does
            // ``busy``, which is what stops ⌘⏎ held down from opening a second sheet onto a
            // review that is already going out.
            .busy(isSubmittingVerdict)
            .disabled(model.hasEndedOnGitHub)
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

    /// Whether a verdict for this pull request is already on its way to the outbox.
    ///
    /// These three buttons only *open* the sheet, but they open it onto a review that is already
    /// being written — so they wait with it rather than with the click.
    private var isSubmittingVerdict: Bool {
        actions.activity.isRunning(model.prID, .review)
    }

    /// Which verdict the green button opens the sheet on.
    ///
    /// Approve, unless GitHub would answer 422 to one — on your own pull request the same button
    /// still opens the sheet, on a plain comment, because a comment is a review GitHub accepts
    /// from an author. The label follows, so the button never offers what it cannot do.
    private var preselectedVerdict: ReviewVerdict {
        model.verdictBlocker == nil ? .approve : .comment
    }

    /// A blocked button's tooltip: the sentence the write funnel would have toasted
    /// (``PullRequestActions/help(for:on:otherwise:)``).
    ///
    /// The guard is for the summary, not for the blocker: before the detail arrives there is no
    /// pull request to name, and a bar with nothing to act on shows the shortcut.
    /// - Parameter otherwise: The tooltip for a button that is live.
    /// - Returns: The tooltip text.
    private func blockedHelp(otherwise: String) -> String {
        guard let summary = model.summary else { return otherwise }
        return PullRequestActions.help(
            for: summary.verdictBlocker,
            on: summary,
            otherwise: otherwise
        )
    }

    private func start(_ verdict: ReviewVerdict) {
        model.pendingVerdict = verdict
        model.isSubmitSheetPresented = true
    }
}

/// The submit sheet: summary text plus the verdict picker.
struct SubmitReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The app-wide environment, for the session back-channel's delegation (ADR 0030).
    @Environment(AppEnvironment.self) private var environment
    /// The review model.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions

    /// The summary field's AI-drafting state (ADR 0007 amendment).
    @State private var aiDraft = AIDraftFieldState()
    /// The task producing the streamed draft, while one runs (plan §3.B).
    ///
    /// Held because a stream has three ways to end that are not "the model stopped talking": the
    /// stop button, Escape, and the reviewer typing. All three have to stop the *request* as well
    /// as the field's claim on it — cancelling this task drops the iteration, which cancels the
    /// router's relay, which cancels the provider's own task, which is what ends the on-device
    /// session or the SSE connection. Dropping the field's state alone would leave a model
    /// generating tokens nobody will ever read.
    @State private var draftTask: Task<Void, Never>?
    /// Whether the session-send confirmation is up (ADR 0030).
    @State private var isSessionSheetPresented = false

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
                        AIDraftButton(
                            isDrafting: aiDraft.isDrafting,
                            isStreaming: aiDraft.streamingDraft != nil
                        ) {
                            toggleSummaryDraft()
                        }
                    }
                    // No `suggestedIDs` here, and that is the rule rather than an omission: a
                    // review summary has no thread behind it, so there is nothing to rank the
                    // replies against. Ranking them against the pull request's diff instead would
                    // be a different feature with a different budget, and guessing from an empty
                    // context is exactly the "confidently wrong" answer ADR 0019 refuses to give.
                    SavedReplyMenu(
                        replies: model.settings.usableSavedReplies,
                        onInsert: { snippet in
                            model.summaryText = SavedReply.inserting(
                                snippet,
                                into: model.summaryText
                            )
                        }
                    )
                }
                ComposerTextEditor(
                    text: summaryBinding,
                    height: 130,
                    // The growing draft is drawn in the caption colour, so the reviewer can see
                    // which words are the model's while they are still arriving.
                    textColor: aiDraft.streamingDraft == nil ? Theme.text : Theme.accentText
                )
                AIDraftStatusView(
                    state: aiDraft,
                    confirmationTitle: String(localized: "Replace current summary?"),
                    onReplace: { resolve(.replace) },
                    onAppend: { resolve(.append) },
                    onDiscard: { aiDraft.discardPendingDraft() }
                )
            }

            Picker(String(localized: "Verdict"), selection: verdictBinding) {
                Text(String(localized: "Comment")).tag(ReviewVerdict.comment)
                Text(String(localized: "Approve"))
                    .disabled(model.verdictBlocker != nil)
                    .tag(ReviewVerdict.approve)
                Text(String(localized: "Request changes"))
                    .disabled(model.verdictBlocker != nil)
                    .tag(ReviewVerdict.requestChanges)
            }
            .pickerStyle(.radioGroup)

            // Under the picker rather than in a toast after the click: two of the three options
            // are dark and the reason is not guessable from a radio button.
            if let blocker = model.verdictBlocker, let summary = model.summary {
                Text(PullRequestActions.blockerMessage(blocker, slug: summary.slug))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.pending)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                // Escape while a draft is in flight stops the draft rather than throwing the
                // sheet away, and this is the one control `.cancelAction` sits on, so there is
                // nothing ambiguous about where the key goes. A reviewer who reaches for Escape
                // while text is growing in front of them means *that*; the sheet is one Escape
                // further along, with everything the draft produced still in the field.
                Button(aiDraft.isDrafting
                    ? String(localized: "Stop drafting")
                    : String(localized: "Cancel")
                ) {
                    if aiDraft.isDrafting {
                        stopSummaryDraft()
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                // The summary's own second button (ADR 0030). It sends the summary text to the
                // session and does *nothing else*: the review is still submitted by the button
                // beside it, because submitting is a review action and sending is not.
                if let action = sessionAction {
                    sessionButton(action)
                }
                Button {
                    Task {
                        // Only a review that was written closes the sheet. A refused verdict
                        // leaves it open beside the toast that explains why, with the summary
                        // still in the field and a verdict the picker will accept one click away.
                        if await model.submit(verdict: model.pendingVerdict, actions: actions) {
                            dismiss()
                        }
                    }
                } label: {
                    Text(String(localized: "Submit"))
                }
                .buttonStyle(SuccessButtonStyle())
                .keyboardShortcut(.defaultAction)
                .busy(isSubmitting)
                .disabled(needsSummary || model.hasEndedOnGitHub)
                .help(needsSummary
                    ? String(localized: "Write a summary first — GitHub rejects a “request changes” or “comment” review without one.")
                    : String(localized: "Queue the review"))
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
        .onChange(of: model.summaryText) { _, text in
            let wasStreaming = aiDraft.streamingDraft != nil
            aiDraft.fieldChanged(to: text)
            // The reviewer's keystroke won the field (``AIDraftFieldState/fieldChanged(to:)``
            // dropped the stream's claim on it), so the request has to stop too: snapshots that
            // would be refused anyway are tokens somebody's Mac is still generating.
            if wasStreaming, aiDraft.streamingDraft == nil {
                draftTask?.cancel()
                draftTask = nil
            }
        }
        // The sheet closing is a stop as well. There is no field left to write into, and an
        // on-device session that outlives its window is battery spent on nothing.
        .onDisappear {
            draftTask?.cancel()
            draftTask = nil
        }
    }

    // MARK: - AI drafting

    /// Asks the intelligence layer for a summary suggestion, streamed (plan §0.2).
    ///
    /// Started only by the button's click, and its only effect is on the text field: the verdict
    /// picker and the Submit button are untouched (ADR 0007 non-goal — nothing auto-submits).
    /// When the field already holds text, this only *asks* — the request is made by
    /// ``resolve(_:)`` once the reviewer has said replace or append, so a discarded question
    /// never sends anything to a provider.
    @MainActor
    private func requestSummaryDraft() {
        switch aiDraft.prepareStream(existingText: model.summaryText) {
        case .askFirst:
            break
        case .ready(let base):
            draftTask = Task { await runSummaryStream(base: base) }
        }
    }

    /// The sparkles button, and ⇧⌘D: start a draft, or stop the one that is running.
    ///
    /// One entry point for both directions so the button and the shortcut cannot disagree about
    /// what they do (plan §3.B).
    @MainActor
    private func toggleSummaryDraft() {
        if aiDraft.isDrafting {
            stopSummaryDraft()
        } else {
            requestSummaryDraft()
        }
    }

    /// Stops the running draft, keeping every word that arrived.
    ///
    /// The field is settled here rather than in the task, so a stop is *immediate*: the task ends
    /// on its own schedule (it has to be resumed by the runtime first), and a stop button that
    /// left the stop caption up for another beat would look like it had not worked. Everything it
    /// touches is idempotent, so the task doing the same thing again when it wakes is a no-op.
    @MainActor
    private func stopSummaryDraft() {
        draftTask?.cancel()
        draftTask = nil
        // Exactly one of these two does anything: the first before the first token has arrived,
        // the second once text is in the field.
        aiDraft.cancelDrafting()
        apply(aiDraft.cancelStream())
    }

    /// Applies the reviewer's answer to the replace-or-append question.
    @MainActor
    private func resolve(_ choice: AIDraftFieldState.Choice) {
        switch aiDraft.resolve(choice, existingText: model.summaryText) {
        case .write(let text):
            model.summaryText = text
        case .startStream(let base):
            draftTask = Task { await runSummaryStream(base: base) }
        case .nothing:
            break
        }
    }

    /// Runs one streamed summary draft into the field.
    ///
    /// Every element is the whole draft so far, so each one is simply written; the state decides
    /// whether it may be (it may not, once the reviewer has typed).
    /// - Parameter base: What the draft grows after — empty, or the reviewer's own text plus a
    ///   blank line when they chose *append*.
    @MainActor
    private func runSummaryStream(base: String) async {
        let outcome = await model.streamReviewSummaryDraft()
        // Stopped while the ladder was still choosing a tier: ``stopSummaryDraft()`` has already
        // put the field back, and reporting this outcome would answer a question nobody is
        // asking any more.
        guard !Task.isCancelled else { return }
        guard let stream = outcome.stream else {
            apply(aiDraft.finish(outcome.failure ?? .disabled, existingText: model.summaryText))
            return
        }
        aiDraft.streamStarted(kind: stream.kind, servedBy: stream.servedBy, base: base)
        do {
            for try await partial in stream.text {
                apply(aiDraft.streamed(partial))
            }
            // A cancelled task ends the iteration *without* an error — `AsyncThrowingStream`
            // finishes its iterator when the consuming task is cancelled — so a stop has to be
            // recognised here as well, or the last thing a stopped stream did would be to file
            // itself as one that ran to completion (which, with nothing yet arrived, would put a
            // failure line under the field the reviewer just stopped).
            if Task.isCancelled {
                apply(aiDraft.cancelStream())
            } else {
                apply(aiDraft.finishStream())
            }
        } catch is CancellationError {
            apply(aiDraft.cancelStream())
        } catch {
            apply(aiDraft.failStream(AIDraftFailure.describe(error)))
        }
    }

    /// Writes text the drafting state produced into the field, when it produced any.
    private func apply(_ text: String?) {
        guard let text else { return }
        model.summaryText = text
    }

    // MARK: - Send to the session (ADR 0030)

    /// What the second button offers, or `nil` when there is no session to answer.
    private var sessionAction: SessionBackChannel.Action? {
        SessionBackChannel.action(
            session: SessionReference.mostRecent(in: model.detail?.commits ?? []),
            configuration: model.settings.agentCLI
        )
    }

    /// The message and the delegation this press would produce.
    ///
    /// No path and no line: a summary is about the pull request, so the message carries the slug
    /// and the link and nothing that would claim a location it does not have.
    private func sessionPlan(_ session: SessionReference) -> SessionBackChannel.Plan? {
        guard let summary = model.summary else { return nil }
        return SessionBackChannel.plan(
            summary: summary,
            session: session,
            path: nil,
            line: nil,
            text: model.summaryText,
            round: model.round?.roundCount
        )
    }

    @ViewBuilder
    private func sessionButton(_ action: SessionBackChannel.Action) -> some View {
        switch action {
        case .send(let session):
            Button {
                isSessionSheetPresented = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 10, weight: .bold))
                    Text(String(localized: "Send to the session"))
                }
            }
            .buttonStyle(SecondaryButtonStyle(tint: Theme.agent))
            .disabled(model.summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(String(
                localized: "Send this summary to the session that wrote this code"
            ))
            .sheet(isPresented: $isSessionSheetPresented) {
                if let plan = sessionPlan(session) {
                    SessionSendSheet(
                        session: session,
                        message: plan.message,
                        note: String(
                            localized: "Your summary stays in the field: sending does not submit the review, does not approve and resolves nothing. This sheet closes so you can watch the run."
                        ),
                        agentName: model.settings.agentCLI.kind.displayName
                    ) {
                        // The submit sheet goes first, and the run is asked for after it: the
                        // delegation panel is presented at the window's root, and a sheet cannot
                        // open in front of another sheet. The summary itself is the model's, so
                        // it is still there when the reviewer comes back to submit.
                        dismiss()
                        _ = environment.sendToSession(plan.context, message: plan.message)
                    }
                }
            }
        case .open(_, let url):
            Link(destination: url) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .bold))
                    Text(String(localized: "Open the session"))
                }
            }
            .buttonStyle(SecondaryButtonStyle(tint: Theme.agent))
            .help(String(
                localized: "No command is configured for this kind of session, so this opens it in the browser instead"
            ))
        }
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

    /// Whether the review is being written.
    ///
    /// Both flags, because they cover different moments: ``ReviewModel/isSubmitting`` is set
    /// before the funnel is even reached (it wraps the draft read as well), and the funnel's key
    /// is what a verdict started from the bar behind this sheet — or by `r a` — is visible in.
    private var isSubmitting: Bool {
        model.isSubmitting || actions.activity.isRunning(model.prID, .review)
    }
}

/// The native composer that opens when the user clicks a gutter “+”.
///
/// Text entry never happens inside the webview — that is the bridge's rule.
struct InlineCommentComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    /// The review model.
    let model: ReviewModel
    /// Where the comment is anchored.
    let request: ReviewModel.ComposerRequest

    @State private var commentText = ""
    @State private var errorMessage: String?
    /// The comment field's AI-drafting state (ADR 0007 amendment).
    @State private var aiDraft = AIDraftFieldState()
    /// The task producing the streamed draft, while one runs (plan §3.B).
    ///
    /// Same reason as in ``SubmitReviewSheet``: the stop button, Escape and the reviewer typing
    /// all have to end the request itself, and cancelling this task is what walks back down
    /// through the router's relay to the provider and ends the on-device session.
    @State private var draftTask: Task<Void, Never>?
    /// The saved replies that fit the conversation already on this line, best first.
    @State private var suggestedReplyIDs: [SavedReply.ID] = []
    /// Whether the embeddings for this composer have already been spent.
    @State private var hasRequestedSuggestions = false
    /// Where the "Explain these lines" popover stands (plan §3.D).
    ///
    /// Its own state next to ``aiDraft`` rather than a mode of it: the two answer different
    /// questions about the same selection, and an explanation that shared the drafting phase
    /// would have to decide what a half-arrived explanation means for the *field*, which is
    /// exactly the coupling this feature does not need. The only thing that crosses between them
    /// is one string, on one click.
    @State private var explain = ExplainSelectionState()
    /// The task producing the streamed explanation, while one runs.
    @State private var explainTask: Task<Void, Never>?
    /// Whether the explanation popover is up.
    @State private var isExplainPresented = false
    /// Whether the session-send confirmation is up (ADR 0030).
    @State private var isSessionSheetPresented = false

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
                    // The gutter gesture opened this composer, so this is where the selection
                    // already is: "Explain" lives beside the field it can feed rather than in a
                    // second popover the reviewer would have to find (plan §3.D).
                    ExplainSelectionButton(isExplaining: explain.isExplaining) {
                        toggleExplanation()
                    }
                    .popover(isPresented: $isExplainPresented, arrowEdge: .bottom) {
                        ExplainSelectionPopover(
                            state: explain,
                            anchorDescription: anchorDescription,
                            onStop: { stopExplanation() },
                            onCancel: { cancelExplanation() },
                            onTurnIntoComment: { turnExplanationIntoComment() }
                        )
                    }
                    AIDraftButton(
                        isDrafting: aiDraft.isDrafting,
                        isStreaming: aiDraft.streamingDraft != nil
                    ) {
                        toggleCommentDraft()
                    }
                }
                SavedReplyMenu(
                    replies: model.settings.usableSavedReplies,
                    suggestedIDs: suggestedReplyIDs,
                    onInsert: { snippet in
                        commentText = SavedReply.inserting(snippet, into: commentText)
                    },
                    onWillOpen: { requestSavedReplySuggestions() }
                )
            }

            ComposerTextEditor(
                text: $commentText,
                height: 120,
                // The caption colour while the draft streams, the field's own colour after it.
                textColor: aiDraft.streamingDraft == nil ? Theme.text : Theme.accentText
            )

            AIDraftStatusView(
                state: aiDraft,
                confirmationTitle: String(localized: "Replace this comment?"),
                onReplace: { resolve(.replace) },
                onAppend: { resolve(.append) },
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
                if let existing = existingComment {
                    Button(String(localized: "Delete")) {
                        Task { await delete(existing) }
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.failure))
                }
                Spacer()
                // Escape stops a draft that is in flight before it closes the composer — the
                // same rule as the submit sheet, on the same single `.cancelAction` control, so
                // the key means one thing in both places.
                Button(aiDraft.isDrafting
                    ? String(localized: "Stop drafting")
                    : String(localized: "Cancel")
                ) {
                    if aiDraft.isDrafting {
                        stopCommentDraft()
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                // The second button, and only when the head commits carry a return address
                // (ADR 0030). It never replaces "Add comment": the comment is still what gets
                // posted, and the thread stays the record.
                if let action = sessionAction {
                    sessionButton(action)
                }
                Button {
                    Task { await save() }
                } label: {
                    Text(String(localized: "Add comment"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .busy(isSaving)
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
            let wasStreaming = aiDraft.streamingDraft != nil
            aiDraft.fieldChanged(to: text)
            // The keystroke wins the field, so the request stops with it.
            if wasStreaming, aiDraft.streamingDraft == nil {
                draftTask?.cancel()
                draftTask = nil
            }
        }
        .onDisappear {
            draftTask?.cancel()
            draftTask = nil
            explainTask?.cancel()
            explainTask = nil
        }
    }

    // MARK: - Saved-reply suggestions

    /// The conversation already anchored to this line, oldest comment first.
    ///
    /// The published threads at the same path and line, and nothing else. A brand-new comment on
    /// an untouched line therefore has no context at all — and gets the plain menu, which is the
    /// honest answer: the alternative would be ranking the reviewer's saved replies against a
    /// diff, which is a different feature with a different budget.
    ///
    /// The reviewer's own half-typed text is deliberately *not* in here. It changes on every
    /// keystroke, and a suggestion that reshuffled itself while somebody was writing would be
    /// competing with them for the same two lines of the menu.
    private var threadCommentBodies: [String] {
        guard let threads = model.detail?.threads else { return [] }
        return threads
            .filter { $0.path == request.path && $0.line == request.line }
            .flatMap { thread in thread.comments.map(\.bodyMarkdown) }
    }

    /// Spends the embeddings that fill the menu's "Suggested" section, at most once per composer.
    ///
    /// Called from the menu's hover, so nothing is embedded for a reviewer who never reaches for
    /// a saved reply. The guard is what makes a pointer crossing the button five times cost one
    /// thread vector: the thread cannot change while this sheet is open, so a second answer would
    /// be the first one again.
    private func requestSavedReplySuggestions() {
        // Read out of the view before the task, so the closure captures values rather than the
        // view: `Sendable` arrays of `Sendable` values and one `@MainActor` coordinator.
        let comments = threadCommentBodies
        guard !hasRequestedSuggestions, !comments.isEmpty else { return }
        hasRequestedSuggestions = true
        let replies = model.settings.usableSavedReplies
        let coordinator = environment.savedReplySuggestions
        Task {
            suggestedReplyIDs = await coordinator.suggestions(
                forThreadComments: comments,
                replies: replies
            )
        }
    }

    // MARK: - AI drafting

    /// Asks the intelligence layer for a comment suggestion about this line, streamed.
    ///
    /// The context is the file path and the diff around the anchored line, capped by
    /// ``InlineCommentDraftBuilder`` — and it goes only to the provider the user configured
    /// themselves (`CONTRIBUTING.md`, "the complete list of hosts Shepherd may contact"). With
    /// text already in the field the question comes first and the request second, so answering
    /// *discard* sends the excerpt nowhere.
    @MainActor
    private func requestCommentDraft() {
        switch aiDraft.prepareStream(existingText: commentText) {
        case .askFirst:
            break
        case .ready(let base):
            draftTask = Task { await runCommentStream(base: base) }
        }
    }

    /// The sparkles button, and ⇧⌘D: start a draft, or stop the one that is running.
    @MainActor
    private func toggleCommentDraft() {
        if aiDraft.isDrafting {
            stopCommentDraft()
        } else {
            requestCommentDraft()
        }
    }

    /// Stops the running draft, keeping every word that arrived.
    ///
    /// Settled here rather than in the task so the stop is immediate; both calls are no-ops in
    /// the phase the other one handles, and both are idempotent.
    @MainActor
    private func stopCommentDraft() {
        draftTask?.cancel()
        draftTask = nil
        aiDraft.cancelDrafting()
        apply(aiDraft.cancelStream())
    }

    /// Applies the reviewer's answer to the replace-or-append question.
    @MainActor
    private func resolve(_ choice: AIDraftFieldState.Choice) {
        switch aiDraft.resolve(choice, existingText: commentText) {
        case .write(let text):
            commentText = text
        case .startStream(let base):
            draftTask = Task { await runCommentStream(base: base) }
        case .nothing:
            break
        }
    }

    /// Runs one streamed comment draft into the field.
    /// - Parameter base: What the draft grows after.
    @MainActor
    private func runCommentStream(base: String) async {
        let outcome = await model.streamInlineCommentDraft(for: request)
        // Stopped before a tier answered: the field is already back where the reviewer left it.
        guard !Task.isCancelled else { return }
        guard let stream = outcome.stream else {
            apply(aiDraft.finish(outcome.failure ?? .disabled, existingText: commentText))
            return
        }
        aiDraft.streamStarted(kind: stream.kind, servedBy: stream.servedBy, base: base)
        do {
            for try await partial in stream.text {
                apply(aiDraft.streamed(partial))
            }
            // Cancellation ends the iteration without an error, so the stop is recognised here
            // too — see ``SubmitReviewSheet/runSummaryStream(base:)``.
            if Task.isCancelled {
                apply(aiDraft.cancelStream())
            } else {
                apply(aiDraft.finishStream())
            }
        } catch is CancellationError {
            apply(aiDraft.cancelStream())
        } catch {
            apply(aiDraft.failStream(AIDraftFailure.describe(error)))
        }
    }

    /// Writes text the drafting state produced into the field, when it produced any.
    private func apply(_ text: String?) {
        guard let text else { return }
        commentText = text
    }

    // MARK: - Explaining the selection (plan §3.D)

    /// ⌥E and the magnifier button: ask what these lines change, or stop the answer coming.
    @MainActor
    private func toggleExplanation() {
        if explain.isExplaining {
            stopExplanation()
            return
        }
        // Re-asked from scratch every time the button is pressed: the popover explains *this*
        // selection, and showing the previous answer while a new one is on its way would be two
        // explanations in one card with nothing saying which is which.
        explain.begin()
        isExplainPresented = true
        explainTask = Task { await runExplanationStream() }
    }

    /// Stops the running explanation, keeping every sentence that arrived.
    @MainActor
    private func stopExplanation() {
        explainTask?.cancel()
        explainTask = nil
        explain.stop()
    }

    /// Escape, and the Close button: the popover goes and the answer goes with it.
    @MainActor
    private func cancelExplanation() {
        explainTask?.cancel()
        explainTask = nil
        explain.reset()
        isExplainPresented = false
    }

    /// Runs one streamed explanation into the popover.
    ///
    /// The same sequence as ``runCommentStream(base:)``, including why the cancellation check
    /// after the loop is there: a cancelled `AsyncThrowingStream` ends its iteration *without*
    /// throwing, so a loop trusting only `CancellationError` would file a reviewer's stop as a
    /// stream that finished empty — which is a red line under a popover they closed themselves.
    @MainActor
    private func runExplanationStream() async {
        let outcome = await model.streamExplanation(for: request)
        // Stopped before a tier answered: the popover is already back where it was.
        guard !Task.isCancelled else { return }
        guard let stream = outcome.stream else {
            // `.disabled` has no message and cannot happen while the button is rendered; it would
            // mean the settings changed mid-request, and the honest response is to say nothing.
            if let message = outcome.failure?.message {
                explain.fail(message)
            } else {
                explain.reset()
            }
            return
        }
        explain.started(kind: stream.kind)
        do {
            for try await partial in stream.text {
                explain.streamed(partial)
            }
            if Task.isCancelled {
                explain.stop()
            } else {
                explain.finish()
            }
        } catch is CancellationError {
            explain.stop()
        } catch {
            explain.fail(AIDraftFailure.describe(error))
        }
    }

    /// Turns the explanation into the start of an inline comment.
    ///
    /// **Through ``AIDraftFieldState`` and nothing else**, which is the guardrail (ADR 0007's
    /// drafting amendment, third surface): into an empty field the text simply lands, labelled
    /// with the tier that wrote it and captioned until the reviewer's first keystroke; over text
    /// the reviewer has already typed it lands nowhere until they answer replace-or-append. That
    /// is why the explanation is handed over as an ``IntelligenceOutcome`` rather than assigned
    /// to `commentText` — the same value the drafting path produces, so it obeys the same rules
    /// rather than a second copy of them. Nothing is submitted: "Add comment" is still a click.
    @MainActor
    private func turnExplanationIntoComment() {
        guard let text = explain.explanation, let kind = explain.kind else { return }
        // Taking the field ends whatever else was writing into it — the same rule as the reviewer
        // typing during a stream (``AIDraftFieldState``): two generated texts must never
        // interleave in one comment. Whatever the draft had already written counts as the
        // reviewer's existing text below, so it is *asked* about rather than overwritten.
        draftTask?.cancel()
        draftTask = nil
        explainTask?.cancel()
        explainTask = nil
        isExplainPresented = false
        apply(
            aiDraft.finish(
                .value(IntelligenceOutput(kind: kind, value: text)),
                existingText: commentText
            )
        )
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

    /// Whether this composer's own write is running.
    ///
    /// The pending comment is a *local* row rather than an outbox write, so it does not pass
    /// through ``PullRequestActions``; it is marked on the same tracker anyway, because ⏎ held
    /// down on this sheet would otherwise write the comment twice, which is the bug the tracker
    /// exists for (``ActionActivity``).
    private var isSaving: Bool {
        environment.activity.isRunning(model.prID, .reply)
    }

    private func save() async {
        await environment.activity.run(model.prID, .reply) {
            do {
                try await model.saveDraftComment(request, body: commentText)
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Deletes the pending comment this composer opened on, and says so when it cannot.
    ///
    /// It used to be `try?` followed by an unconditional `dismiss()`: a delete the database
    /// refused closed the composer as though it had worked, and the comment was still in the
    /// review the reviewer then submitted. The composer now stays open with the reason in it —
    /// the same ``errorMessage`` line the save path writes to — because the comment is still
    /// there and *Delete* is still the thing to press.
    /// - Parameter comment: The pending comment.
    private func delete(_ comment: DraftComment) async {
        do {
            try await model.deleteDraftComment(localID: comment.localID)
            dismiss()
        } catch {
            errorMessage = String(
                localized: "Could not delete the comment: \(error.userFacingDescription)"
            )
        }
    }

    // MARK: - Send to the session (ADR 0030)

    /// What the second button offers, or `nil` when there is no session to answer.
    private var sessionAction: SessionBackChannel.Action? {
        SessionBackChannel.action(
            session: SessionReference.mostRecent(in: model.detail?.commits ?? []),
            configuration: model.settings.agentCLI
        )
    }

    /// The message and the delegation this press would produce, or `nil` before the pull
    /// request has loaded.
    private func sessionPlan(_ session: SessionReference) -> SessionBackChannel.Plan? {
        guard let summary = model.summary else { return nil }
        return SessionBackChannel.plan(
            summary: summary,
            session: session,
            path: request.path,
            line: request.line,
            text: commentText,
            round: model.round?.roundCount
        )
    }

    @ViewBuilder
    private func sessionButton(_ action: SessionBackChannel.Action) -> some View {
        switch action {
        case .send(let session):
            Button {
                isSessionSheetPresented = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 10, weight: .bold))
                    Text(String(localized: "Send to the session"))
                }
            }
            .buttonStyle(SecondaryButtonStyle(tint: Theme.agent))
            .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(String(
                localized: "Add the comment and send it to the session that wrote this code"
            ))
            .sheet(isPresented: $isSessionSheetPresented) {
                if let plan = sessionPlan(session) {
                    SessionSendSheet(
                        session: session,
                        message: plan.message,
                        note: String(
                            localized: "The comment is saved to your pending review exactly as “Add comment” saves it. Sending resolves nothing and submits nothing."
                        ),
                        agentName: model.settings.agentCLI.kind.displayName
                    ) {
                        Task { await sendToSession(plan) }
                    }
                }
            }
        case .open(_, let url):
            Link(destination: url) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .bold))
                    Text(String(localized: "Open the session"))
                }
            }
            .buttonStyle(SecondaryButtonStyle(tint: Theme.agent))
            .help(String(
                localized: "No command is configured for this kind of session, so this opens it in the browser instead"
            ))
        }
    }

    /// Saves the comment the way "Add comment" does, then opens the delegation that carries the
    /// message to the session.
    ///
    /// The order is deliberate: a comment that could not be saved sends nothing, because the
    /// thread is the record and a session answering a finding GitHub never received would be the
    /// one outcome nobody could reconstruct afterwards. The composer closes before the run is
    /// asked for, because the delegation panel is presented at the window's root and a sheet
    /// cannot open in front of another sheet.
    /// - Parameter plan: The message and the delegation, already confirmed.
    private func sendToSession(_ plan: SessionBackChannel.Plan) async {
        do {
            try await model.saveDraftComment(request, body: commentText)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }
        dismiss()
        environment.sendToSession(plan.context, message: plan.message)
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
    /// The popover's own translation cache (ADR 0020), so a translated comment stays translated
    /// while the reviewer scrolls the thread — and is gone when the popover is.
    @State private var translations = TranslationCoordinator()
    /// The saved replies that fit this thread, best first, or empty for the plain menu.
    @State private var suggestedReplyIDs: [SavedReply.ID] = []
    /// Whether the embeddings for this thread have already been spent.
    @State private var hasRequestedSuggestions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Above the conversation, because it is a way *into* the conversation
                    // (plan §3.G). It scrolls with the comments rather than pinning itself to the
                    // header: a card that ate a third of a 260-point panel permanently would cost
                    // the reviewer the thread it summarises.
                    if let digest = digestState {
                        ThreadDigestCard(state: digest)
                    }
                    ForEach(thread.comments) { comment in
                        ThreadCommentView(comment: comment, translations: translations)
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
        // Asked once per app run and cached, so the button below is drawn only where pressing it
        // would do something (plan §3.G, ADR 0007).
        .task { await environment.threadDigests.prepare() }
        // The popover's content keeps its `@State` when the reviewer clicks a different comment
        // card while it is open, so the suggestions have to be told that the conversation under
        // them changed — otherwise the second thread would be offered the first thread's replies.
        .onChange(of: thread.id) { previous, _ in
            suggestedReplyIDs = []
            hasRequestedSuggestions = false
            // And a digest still being written for the thread the reviewer just left is a digest
            // nobody will read, so it is stopped rather than left running on the battery.
            environment.threadDigests.cancel(for: previous)
        }
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
            if canSummarise {
                Button {
                    requestThreadDigest()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 10, weight: .bold))
                        Text(String(localized: "Summarise"))
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: 24))
                .help(String(localized: "Summarise this thread on this Mac"))
            }
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
                    // A growing field, so the full Writing Tools panel has somewhere to put its
                    // result: this is review prose like any other composer (ADR 0020).
                    .writingToolsBehavior(.complete)
                    .lineLimit(1...4)
                    .padding(8)
                    .background(
                        Theme.control,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                SavedReplyMenu(
                    replies: environment.settings.usableSavedReplies,
                    suggestedIDs: suggestedReplyIDs,
                    onInsert: { snippet in
                        replyText = SavedReply.inserting(snippet, into: replyText)
                    },
                    onWillOpen: { requestSavedReplySuggestions() },
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
                .busy(isTogglingThread)

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

                Button {
                    Task { await sendReply() }
                } label: {
                    Text(String(localized: "Reply"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .busy(isReplying)
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

    /// Whether this pull request already has a reply on its way to the outbox.
    private var isReplying: Bool { actions.activity.isRunning(summary.id, .reply) }

    /// Whether *this* thread is already being resolved or reopened. Keyed by the thread, so the
    /// popover for one conversation says nothing about another.
    private var isTogglingThread: Bool { actions.activity.isRunning(thread.id, .thread) }

    /// Spends the embeddings that fill the menu's "Suggested" section, at most once per popover.
    ///
    /// This is the surface the feature was designed for: a thread has a conversation in it, so
    /// there is something real to rank against. Called from the menu's hover, so a reviewer who
    /// only types a reply never pays for a vector, and guarded so that a pointer crossing the
    /// button repeatedly costs one.
    private func requestSavedReplySuggestions() {
        guard !hasRequestedSuggestions else { return }
        hasRequestedSuggestions = true
        // Read out of the view before the task, so the closure captures values rather than views.
        let comments = thread.comments.map(\.bodyMarkdown)
        let replies = environment.settings.usableSavedReplies
        let coordinator = environment.savedReplySuggestions
        Task {
            suggestedReplyIDs = await coordinator.suggestions(
                forThreadComments: comments,
                replies: replies
            )
        }
    }

    // MARK: - Thread digest

    /// The card's state for this thread, or `nil` when there is no card yet (plan §3.G).
    private var digestState: ThreadDigestState? {
        environment.threadDigests.state(for: thread.id, comments: thread.comments)
    }

    /// Whether *Summarise* is offered at all.
    ///
    /// Three conditions, and each one removes the button rather than disabling it. A short thread
    /// does not need a summary — the reviewer reads six comments faster than a summary of them
    /// plus the six. A Mac without the on-device model cannot produce one, and tier 2 is the only
    /// tier allowed to see somebody else's comments (ADR 0007's amendment). And once the card is
    /// on screen the button has nothing left to ask for — unless the attempt failed, in which
    /// case it stays, like every other drafting button, so the reviewer can try again.
    private var canSummarise: Bool {
        guard thread.comments.count >= ThreadDigestCoordinator.minimumCommentCount,
              environment.threadDigests.isAvailable else { return false }
        switch digestState {
        case nil, .failed: return true
        default: return false
        }
    }

    /// Spends the one on-device run behind the button.
    ///
    /// Values are read out of the view before the task, so the closure captures a `Sendable`
    /// thread id, a `Sendable` array of comments and the `@MainActor` coordinator rather than the
    /// view — the same shape ``requestSavedReplySuggestions()`` uses beside it.
    private func requestThreadDigest() {
        let threadID = thread.id
        let comments = thread.comments
        let isResolved = thread.isResolved
        let coordinator = environment.threadDigests
        Task {
            await coordinator.digest(for: threadID, comments: comments, isResolved: isResolved)
        }
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
///
/// The body goes through ``TranslatableMarkdownText``, so a comment written in a language the
/// reviewer does not read can be translated on this Mac, below the original (ADR 0020). Everything
/// around it — who wrote it, when, the agent chip — is Shepherd's own already-localized chrome and
/// has nothing to translate.
struct ThreadCommentView: View {
    /// The comment.
    let comment: ReviewComment
    /// The screen's translation cache.
    let translations: TranslationCoordinator

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
                TranslatableMarkdownText(
                    markdown: comment.bodyMarkdown,
                    translations: translations
                )
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
