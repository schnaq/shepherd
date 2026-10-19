import ShepherdCore
import SwiftUI

/// The submit sheet on the phone (ADR 0044): the verdict, the summary, the pending comments, and
/// *Submit* — the Mac's `SubmitReviewSheet` over the same model state.
///
/// What it reads and writes is all ``ReviewModel``'s: ``ReviewModel/pendingVerdict``,
/// ``ReviewModel/summaryText``, the draft's comments, ``ReviewModel/verdictBlocker`` and
/// ``ReviewModel/submit(verdict:actions:)``, which goes through the write funnel's refusal rules.
/// The verdicts are three rows, each with its symbol and colour, rather than a segmented control:
/// "Änderungen anfordern" does not fit a third of a phone. Under a blocker (your own pull request)
/// the verdict is Comment and the reason is said where the rows would be. *Submit* closes the sheet only
/// for a review that was written, so a refused one leaves the summary in the field.
struct PhoneSubmitReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ReviewModel
    let actions: PullRequestActions
    /// Called once the review is in the outbox, for the presenting screen's haptic.
    var onSubmitted: () -> Void = {}

    @State private var detent: PresentationDetent = .medium
    /// The pending comment being edited, through ``PhoneInlineCommentSheet``.
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
            // The form's own top inset left a blank band under the bar at the medium detent.
            .contentMargins(.top, 8, for: .scrollContent)
            .background(Theme.background)
            .navigationTitle(String(localized: "Submit review"))
            // The number alone: the pull request screen under the sheet names the repository.
            .navigationSubtitle(model.summary.map { "#" + String($0.number) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The icon-only close every sheet of the app uses: a word here ("Abbrechen") pushed
                // the title off centre and cut it short.
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
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
                PhoneInlineCommentSheet(model: model, request: request)
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
                verdictRow(.comment, title: String(localized: "Comment"), symbol: "text.bubble", tint: Theme.accentText)
                verdictRow(.approve, title: String(localized: "Approve"), symbol: "checkmark.circle.fill", tint: Theme.success)
                verdictRow(
                    .requestChanges,
                    title: String(localized: "Request changes"),
                    symbol: "exclamationmark.circle.fill",
                    tint: Theme.failure
                )
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

    /// One verdict as a row: its symbol in its colour — the conversation's verdict colours — its
    /// name, and a check on the chosen one.
    private func verdictRow(_ verdict: ReviewVerdict, title: String, symbol: String, tint: Color) -> some View {
        let isSelected = model.pendingVerdict == verdict
        return Button {
            model.pendingVerdict = verdict
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(Theme.type(.body))
                    .foregroundStyle(tint)
                    .frame(minWidth: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.type(.body))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(Theme.type(.body, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected) { _, new in new }
    }

    private var summarySection: some View {
        Section {
            // The placeholder says whether words are needed, rather than repeating the header.
            TextField(
                model.pendingVerdict == .approve
                    ? String(localized: "Optional for an approval")
                    : String(localized: "What should the author know?"),
                text: $model.summaryText,
                axis: .vertical
            )
            .font(Theme.type(.body))
            .lineLimit(3...12)
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
