import ShepherdCore
import SwiftUI

/// The comment field at the bottom of the conversation tab — GitHub's comment box (ADR 0043).
///
/// The same field and the same two writes as the *Comment…* sheet (``PullRequestCommentSheet``):
/// *Post comment*, and *Comment and close* / *Close without a comment* while the pull request is
/// open. A view of its own because the draft it binds is read here and nowhere else, so a
/// keystroke redraws this card rather than the stream above it.
struct ConversationComposer: View {
    @Environment(AppEnvironment.self) private var environment
    /// The review model, which holds the draft and the focus requests *Quote reply* makes.
    @Bindable var model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions
    /// The pull request.
    let summary: PullRequestSummary

    var body: some View {
        // Once per body rather than per use: it runs a pattern over the whole draft, and the
        // body is evaluated on every keystroke.
        let canSend = PastedImage.isSendable(model.conversationDraft)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "ADD A COMMENT"))
                ComposerTextEditor(
                    text: $model.conversationDraft,
                    height: 96,
                    imageUpload: ImageUploadTarget(repo: summary.repo, actions: actions),
                    focusRequest: model.composerFocusRequest,
                    onFocusChange: { model.isConversationComposerFocused = $0 }
                )
                // The card's title is a heading the field does not carry; VoiceOver reads this.
                .accessibilityLabel(String(localized: "Add a comment"))
                HStack(spacing: 8) {
                    SavedReplyMenu(
                        replies: environment.settings.usableSavedReplies,
                        onInsert: { snippet in
                            model.conversationDraft = SavedReply.inserting(snippet, into: model.conversationDraft)
                        },
                        height: 30
                    )
                    Spacer()
                    // Not on a pull request GitHub has already merged or closed: there is nothing
                    // left to close, and a comment is still worth posting there.
                    if !model.hasEndedOnGitHub {
                        Button {
                            close()
                        } label: {
                            Text(
                                canSend
                                    ? String(localized: "Comment and close")
                                    : String(localized: "Close without a comment")
                            )
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(PastedImage.containsPendingUpload(model.conversationDraft))
                        .help(String(localized: "Closes the pull request. Nothing is merged."))
                    }
                    Button {
                        Task { await post() }
                    } label: {
                        Text(String(localized: "Post comment"))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    // ⌘⏎ is the toolbar's *Review* everywhere else on this screen; it is this
                    // button's only while the field has the keyboard, so one key never means two
                    // things at once.
                    .keyboardShortcut(
                        model.isConversationComposerFocused
                            ? KeyboardShortcut(.return, modifiers: .command)
                            : nil
                    )
                    .disabled(!canSend)
                    .busy(actions.activity.isRunning(summary.id, .comment))
                    .help(String(localized: "Post the comment (⌘⏎ while you type)"))
                }
            }
        }
        // The field can leave the screen with the keyboard in it — a switch to the Files tab — and
        // then reports no focus change of its own; ⌘⏎ has to go back to *Review* regardless.
        .onDisappear { model.isConversationComposerFocused = false }
    }

    /// Posts the draft, and empties the field only once the outbox has it.
    ///
    /// A comment GitHub refused keeps its text, so it can be fixed and sent again; so does one
    /// that was never written. Words typed while the write ran are not thrown away with it. What
    /// puts the posted comment into the stream is the app's re-read once GitHub has it
    /// (`AppEnvironment.rereadAfterConversationWrite(_:)`), not this field.
    private func post() async {
        let text = model.conversationDraft
        guard let outcome = await actions.comment(on: summary, body: text) else { return }
        if case .failed = outcome { return }
        if model.conversationDraft == text { model.conversationDraft = "" }
    }

    /// Hands the draft to the close the way the sheet does: taken, emptied, queued.
    private func close() {
        let text = model.conversationDraft
        model.conversationDraft = ""
        Task { await actions.close(summary, comment: text) }
    }
}
