import ShepherdCore
import SwiftUI

/// One published review thread in a sheet — what the conversation's *Reply* opens, and a finding's
/// jump (``ReviewModel/activeThreadID``), presented by ``PhonePullRequestScreen``.
///
/// The card is the conversation's own (``PhoneThreadView``) — comments, reactions, edits, reply and
/// *Resolve* — so a thread reads and answers the same in the stream and in the sheet. No *Show in
/// diff*: the thread is already the one the reader asked for.
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
        .toastHost()
    }
}
