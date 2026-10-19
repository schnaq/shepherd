import ShepherdCore
import SwiftUI

/// The submit sheet on the phone (ADR 0044): the verdict, the summary, the pending comments, and
/// *Submit* — the Mac's `SubmitReviewSheet` over the same model state.
///
/// What it reads and writes is all ``ReviewModel``'s: ``ReviewModel/pendingVerdict``,
/// ``ReviewModel/summaryText``, the draft's comments, ``ReviewModel/verdictBlocker`` and
/// ``ReviewModel/submit(verdict:actions:)``, which goes through the write funnel's refusal rules.
/// Under a blocker (your own pull request) the verdict is Comment and the reason is said where the
/// picker would be: a segmented control cannot disable one segment. *Submit* closes the sheet only
/// for a review that was written, so a refused one leaves the summary in the field.
struct PhoneSubmitReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ReviewModel
    let actions: PullRequestActions
    /// Called once the review is in the outbox, for the presenting screen's haptic.
    var onSubmitted: () -> Void = {}

    @State private var detent: PresentationDetent = .medium
    /// The pending comment being edited, through ``PhoneCommentComposer``.
    @State private var editing: ReviewModel.ComposerRequest?
    @State private var isConfirmingDiscard = false

    var body: some View {
        NavigationStack {
            Form {
                verdictSection
                summarySection
                if let comments = model.draft?.comments, !comments.isEmpty {
                    pendingSection(comments)
                }
                Section {
                    if model.draft != nil {
                        Button(String(localized: "Discard pending review"), role: .destructive) {
                            isConfirmingDiscard = true
                        }
                    }
                } footer: {
                    Text(String(localized: "The review is queued in the local outbox and sent by the sync engine, so it survives a crash or a lost connection."))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(String(localized: "Submit review"))
            .navigationSubtitle(model.summary?.slug ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        submit()
                    } label: {
                        Text(String(localized: "Submit"))
                            .busyLabel(isBusy: model.isSubmitting)
                    }
                    // Accent, not green: green is Merge's (ADR 0040's 2026-09-23 amendment).
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(needsSummary || model.hasEndedOnGitHub || model.summary == nil)
                }
            }
            .confirmationDialog(
                String(localized: "Discard pending review"),
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Discard pending review"), role: .destructive) { discard() }
                Button(String(localized: "Cancel"), role: .cancel) {}
            }
            .sheet(item: $editing) { request in
                PhoneCommentComposer(model: model, request: request)
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .onAppear {
            // GitHub refuses either verdict on your own pull request; Comment is what is left.
            if model.verdictBlocker != nil { model.pendingVerdict = .comment }
            // A change request needs words, so it opens with room for them.
            if model.pendingVerdict == .requestChanges { detent = .large }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var verdictSection: some View {
        Section {
            if model.verdictBlocker == nil {
                Picker(String(localized: "Verdict"), selection: $model.pendingVerdict) {
                    Text(String(localized: "Comment")).tag(ReviewVerdict.comment)
                    Text(String(localized: "Approve")).tag(ReviewVerdict.approve)
                    Text(String(localized: "Request changes")).tag(ReviewVerdict.requestChanges)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } else {
                LabeledContent(String(localized: "Verdict"), value: String(localized: "Comment"))
            }
        } footer: {
            if let blocker = model.verdictBlocker, let summary = model.summary {
                Text(PullRequestActions.blockerMessage(blocker, slug: summary.slug))
                    .foregroundStyle(Theme.pending)
            }
        }
    }

    private var summarySection: some View {
        Section {
            TextField(String(localized: "Summary"), text: $model.summaryText, axis: .vertical)
                .font(Theme.type(.body))
                .lineLimit(5...12)
            PhoneSavedReplyMenu(replies: model.settings.usableSavedReplies) { snippet in
                model.summaryText = SavedReply.inserting(snippet, into: model.summaryText)
            }
        } header: {
            Text(String(localized: "Summary"))
        } footer: {
            if needsSummary {
                Text(String(localized: "GitHub requires a summary for this verdict — only an approval may be submitted without one."))
                    .foregroundStyle(Theme.pending)
            }
        }
    }

    private func pendingSection(_ comments: [DraftComment]) -> some View {
        Section {
            ForEach(comments, id: \.localID) { comment in
                Button {
                    editing = ReviewModel.ComposerRequest(
                        path: comment.path,
                        line: comment.line,
                        side: comment.side,
                        startLine: comment.startLine
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "\(comment.path):\(comment.line)")
                            .font(Theme.mono(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(comment.body.split(separator: "\n").first.map(String.init) ?? "")
                            .font(Theme.type(.subheadline))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                    }
                }
                .swipeActions {
                    Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                        Task { await delete(comment) }
                    }
                }
            }
        } header: {
            Text(String(localized: "Pending comments (\(comments.count))"))
        }
    }

    // MARK: - Actions

    /// The Mac sheet's rule: anything but an approval needs words.
    private var needsSummary: Bool {
        model.pendingVerdict != .approve
            && model.summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard !model.isSubmitting else { return }
        Task {
            // Only a review that was written closes the sheet.
            if await model.submit(verdict: model.pendingVerdict, actions: actions) {
                onSubmitted()
                dismiss()
            }
        }
    }

    private func delete(_ comment: DraftComment) async {
        do {
            try await model.deleteDraftComment(localID: comment.localID)
        } catch {
            actions.toasts.failure(error, context: String(localized: "Could not delete the comment"))
        }
    }

    private func discard() {
        Task {
            do {
                try await model.discardDraft()
                dismiss()
            } catch {
                actions.toasts.failure(error, context: String(localized: "Could not discard the review"))
            }
        }
    }
}
