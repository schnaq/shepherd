import ShepherdCore
import SwiftUI

/// The reply field under a review thread, with its saved replies, and the thread's buttons —
/// *Resolve* / *Unresolve*, *Delegate…* and *Reply*.
///
/// One view for both places a thread is answered: the popover over the diff (``ThreadPopover``)
/// and the conversation tab's stream (``ConversationThreadView``, ADR 0043). It was the popover's
/// own bar and moved out whole, so the two cannot drift into two reply bars; only the typed text
/// stays with the caller.
struct ThreadReplyBar: View {
    @Environment(AppEnvironment.self) private var environment
    /// The thread being answered.
    let thread: ReviewThread
    /// The pull request the thread belongs to.
    let summary: PullRequestSummary
    /// The write actions.
    let actions: PullRequestActions
    /// What is typed in the field, held by the caller: the stream folds a thread away once it is
    /// resolved, which takes this bar off screen, and a reply being written must outlive that.
    @Binding var replyText: String
    /// Called after a reply, a resolve toggle or *Delegate…*: the popover closes on it. The stream
    /// passes nothing — the thread stays where it is, and what the write changed arrives with the
    /// app's re-read once GitHub has it (`AppEnvironment.rereadAfterConversationWrite(_:)`).
    var onDone: @MainActor () -> Void = {}

    /// The saved replies that fit this thread, best first, or empty for the plain menu.
    @State private var suggestedReplyIDs: [SavedReply.ID] = []
    /// Whether the embeddings for this thread have already been spent.
    @State private var hasRequestedSuggestions = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField(String(localized: "Reply…"), text: $replyText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.type(.callout))
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
                        await actions.setThread(on: summary, threadID: thread.id, resolved: !thread.isResolved)
                        onDone()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: thread.isResolved ? "arrow.uturn.backward" : "checkmark")
                            .font(Theme.type(.footnote, weight: .bold))
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
                    onDone()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal")
                            .font(Theme.type(.footnote, weight: .bold))
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
        // The popover keeps this view's state when the reviewer clicks a different comment card
        // while it is open, so the suggestions have to be told that the conversation under them
        // changed — otherwise the second thread would be offered the first thread's replies.
        .onChange(of: thread.id) {
            suggestedReplyIDs = []
            hasRequestedSuggestions = false
        }
    }

    private var replyTargetID: Int? {
        thread.comments.compactMap(\.databaseID).last
    }

    /// Whether this pull request already has a reply on its way to the outbox.
    private var isReplying: Bool { actions.activity.isRunning(summary.id, .reply) }

    /// Whether *this* thread is already being resolved or reopened. Keyed by the thread, so the
    /// bar under one conversation says nothing about another.
    private var isTogglingThread: Bool { actions.activity.isRunning(thread.id, .thread) }

    /// Spends the embeddings that fill the menu's "Suggested" section, at most once per thread.
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

    /// Queues the reply, and empties the field only once the row is on disk.
    ///
    /// The field used to be emptied before the write, which in the popover cost nothing — it
    /// closes either way — but under a thread in the stream it would lose a reply the database
    /// refused. So the text stays until the outbox has it, and stays after a refusal, unless the
    /// reviewer has typed something else in the meantime.
    private func sendReply() async {
        guard let target = replyTargetID else { return }
        let typed = replyText
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch await actions.reply(on: summary, commentDatabaseID: target, body: text) {
        case .sent?, .queued?, .parked?:
            if replyText == typed { replyText = "" }
        case .failed?, nil:
            break
        }
        onDone()
    }
}
