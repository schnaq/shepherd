import ShepherdCore
import SwiftUI

/// The composer behind the issue panel's *Comment…* button (ADR 0032's Sprint 4a amendment).
///
/// A sheet rather than a field in the panel, and the reason is the panel's width: it is 320 to
/// 480 points wide and already carries the body, the labels and the linked pull requests, while
/// a comment is prose somebody writes in whole sentences. That is the same argument
/// ``MergeSheet`` makes for not being one more button in a row.
///
/// It queues and nothing else. The button hands the text back and the model writes an outbox row
/// (ADR 0006), so a comment written offline is still posted when the network comes back — and a
/// comment written against an issue that has since moved on is parked rather than sent, which is
/// the precondition every issue write in this sprint carries.
struct IssueCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The issue being commented on.
    let row: IssueRowSummary
    /// The composed text, held by the panel so a dismissed sheet does not lose it.
    ///
    /// Named `text` rather than `body`, which is the one name a `View` cannot use for anything
    /// else.
    @Binding var text: String
    /// Called with the trimmed text when the user queues it.
    var onQueue: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Comment on \(row.slug)"))
                    .font(Theme.type(.title3, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                Text(row.title)
                    .font(Theme.type(.callout))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The same field the review composer uses, so Writing Tools work here too (ADR 0020).
            ComposerTextEditor(text: $text, height: 160)

            Text(String(localized: "Queued locally and posted in the background. Markdown, as on GitHub."))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    onQueue(text)
                    text = ""
                    dismiss()
                } label: {
                    Text(String(localized: "Queue comment"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.panel)
    }
}
