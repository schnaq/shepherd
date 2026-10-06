import ShepherdCore
import SwiftUI

/// The composer behind the inbox panel's *Comment…* button — GitHub's two conversation buttons,
/// in one sheet.
///
/// A sheet rather than a field in the panel, for ``IssueCommentSheet``'s reason: the panel is 320
/// to 480 points wide and already carries the description, the checks and the files, while a
/// comment is prose somebody writes in whole sentences.
///
/// Two buttons, because GitHub has two and they are genuinely different acts: *Comment* leaves
/// the pull request open and says something about it, *Comment and close* ends it. The second
/// stays enabled with an empty field — closing without a word is a thing people do — and says so
/// on its own label, so nobody has to discover that the primary button is the one that needs text.
///
/// It queues and nothing else. The text goes to ``PullRequestActions``, which writes an outbox
/// row (ADR 0006): a comment written offline is posted when the network comes back, and a close
/// written offline closes then.
struct PullRequestCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The pull request being commented on.
    let summary: PullRequestSummary
    /// The outbox-backed write actions.
    let actions: PullRequestActions
    /// The composed text, held by the screen so a dismissed sheet does not lose it.
    ///
    /// Named `text` rather than `body`, which is the one name a `View` cannot use for anything
    /// else.
    @Binding var text: String

    /// Whether the text is worth sending.
    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Hands the composed text to one of the two writes and closes the sheet.
    ///
    /// Both buttons do the same four things in the same order — take the text, empty the field,
    /// dismiss, queue — and differ only in which write receives it. Written once so a change to
    /// the order cannot be made to one button and forgotten on the other.
    /// - Parameter queue: The write to hand the text to.
    private func hand(to queue: @escaping (String) async -> Void) {
        let composed = text
        text = ""
        dismiss()
        Task { await queue(composed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Comment on \(summary.slug)"))
                    .font(Theme.type(.title3, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                Text(summary.title)
                    .font(Theme.type(.callout))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The same field the review composer uses, so Writing Tools work here too (ADR 0020).
            ComposerTextEditor(text: $text, height: 160)

            Text(String(
                localized: "Goes on the conversation, not on the diff — this is not a review verdict. Queued locally and posted in the background."
            ))
            .font(Theme.type(.subheadline))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    hand { await actions.close(summary, comment: $0) }
                } label: {
                    Text(
                        hasText
                            ? String(localized: "Comment and close")
                            : String(localized: "Close without a comment")
                    )
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(String(localized: "Closes the pull request. Nothing is merged."))

                Spacer()

                Button(String(localized: "Cancel")) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)

                Button {
                    hand { await actions.comment(on: summary, body: $0) }
                } label: {
                    // Its own string rather than the review composer's "Comment", which is one
                    // of GitHub's three verdicts and stays in GitHub's English beside "Approve"
                    // and "Request changes". This button is the other thing entirely, and a
                    // sheet that argues the two apart must not label itself with the word for
                    // the one it is not.
                    Text(String(localized: "Post comment"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!hasText)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
    }
}

extension View {
    /// Presents ``PullRequestCommentSheet`` on `summary` while `isPresented` is true.
    ///
    /// The composed text lives in the modifier, not in the view it hangs on: the sheet keeps what
    /// was typed when it is dismissed, and a keystroke re-evaluates only the modifier — hung on
    /// the review screen, state one level up would redraw the diff and the toolbar on every
    /// character. The counterpart of ``SwiftUI/View/closePullRequestConfirmation(_:actions:)``.
    /// - Parameters:
    ///   - isPresented: Whether the sheet is up.
    ///   - summary: The pull request; no sheet while it is `nil`.
    ///   - actions: The outbox-backed write actions.
    func pullRequestCommentSheet(
        isPresented: Binding<Bool>,
        summary: PullRequestSummary?,
        actions: PullRequestActions
    ) -> some View {
        modifier(PullRequestCommentSheetModifier(isPresented: isPresented, summary: summary, actions: actions))
    }
}

private struct PullRequestCommentSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let summary: PullRequestSummary?
    let actions: PullRequestActions
    @State private var text = ""

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let summary {
                PullRequestCommentSheet(summary: summary, actions: actions, text: $text)
            }
        }
        // The inbox panel outlives its selection, and words written for one pull request must not
        // be posted on the next one.
        .onChange(of: summary?.id) { text = "" }
    }
}
