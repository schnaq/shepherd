import ShepherdCore
import SwiftUI

/// The comment sheet of the pull request screen — *Comment…* in the ⋯ menu and *Quote reply* on a
/// post (ADR 0044).
///
/// The Mac draws this field at the bottom of its conversation tab (`ConversationComposer`); on the
/// phone a field there would fight the bottom bar and the keyboard, so it is a sheet with detents.
/// The draft is the model's (``ReviewModel/conversationDraft``), so it survives the sheet closing
/// and *Quote reply* appends to it. The two writes are the Mac's: *Post comment*, and *Comment and
/// close* / *Close without a comment* while the pull request is open.
struct PhoneConversationComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ReviewModel
    let actions: PullRequestActions
    let summary: PullRequestSummary
    /// Called once the comment is on its way, for the screen's haptic.
    var onPosted: () -> Void = {}

    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField(String(localized: "Add a comment"), text: $model.conversationDraft, axis: .vertical)
                    .font(Theme.type(.body))
                    .lineLimit(6...)
                    .focused($isFocused)
                    .padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .phoneInputField()
                    .accessibilityLabel(String(localized: "Add a comment"))
                HStack(spacing: 12) {
                    PhoneSavedReplyMenu(replies: model.settings.usableSavedReplies) { snippet in
                        model.conversationDraft = SavedReply.inserting(snippet, into: model.conversationDraft)
                    }
                    .labelStyle(.iconOnly)
                    Spacer(minLength: 0)
                    // Not on a pull request GitHub already ended: nothing left to close, and a
                    // comment is still worth posting there.
                    if !model.hasEndedOnGitHub {
                        Button(canSend
                            ? String(localized: "Comment and close")
                            : String(localized: "Close without a comment"), role: .destructive) {
                            close()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(16)
            .background(Theme.background)
            .navigationTitle(String(localized: "Comment"))
            .navigationSubtitle(summary.slug)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard !isPosting else { return }
                        Task { await post() }
                    } label: {
                        Label(String(localized: "Post comment"), systemImage: "arrow.up")
                            .busyLabel(isBusy: isPosting)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(!canSend)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { isFocused = true }
    }

    private var canSend: Bool {
        !model.conversationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isPosting: Bool { actions.activity.isRunning(summary.id, .comment) }

    /// Posts the draft, and empties the field only once the outbox has it — the Mac composer's
    /// `post()`: a refused or unwritten comment keeps its text, and words typed meanwhile stay.
    private func post() async {
        let text = model.conversationDraft
        guard let outcome = await actions.comment(on: summary, body: text) else { return }
        if case .failed = outcome { return }
        if model.conversationDraft == text { model.conversationDraft = "" }
        onPosted()
        dismiss()
    }

    /// Hands the draft to the close the way the Mac does: taken, emptied, queued.
    private func close() {
        let text = model.conversationDraft
        model.conversationDraft = ""
        Task { await actions.close(summary, comment: text) }
        dismiss()
    }
}
