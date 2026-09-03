import ShepherdCore
import SwiftUI

/// The confirmation in front of every session send (ADR 0030).
///
/// It exists to make one promise keepable: **what this sheet shows is what is sent.** The text is
/// the composed message, verbatim and selectable, not a preview built for the sheet — so a
/// reviewer can read the last word of it before anything runs, and cancel with nothing having
/// happened.
struct SessionSendSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The session the message is addressed to.
    let session: SessionReference
    /// The message, exactly as it will be sent.
    let message: String
    /// One line about what else this press does, written by the composer that opens the sheet.
    let note: String
    /// The name of the CLI that will run, for the line that says whose installation it is.
    let agentName: String
    /// Called when the reviewer presses Send.
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Send to the session"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.agent)
                    Text(session.id)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if session.kind == .remote {
                        ChipView(
                            text: String(localized: "Remote session"),
                            color: Theme.accentText,
                            size: 10.5
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                CardTitle(String(localized: "THE MESSAGE"))
                ScrollView {
                    Text(message)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                }
                .frame(height: 190)
                .background(
                    Theme.control,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }

            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(
                localized: "Shepherd runs your own installed \(agentName) with the command from Settings → Delegation. It holds no account and no credentials for it, and it never pushes what the session changes."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Send")) {
                    onSend()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
    }
}
