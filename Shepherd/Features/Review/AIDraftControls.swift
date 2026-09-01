import SwiftUI

/// The "draft this text with AI" button that sits next to the summary and comment fields
/// (ADR 0007 amendment).
///
/// Placed beside the field it writes into, exactly like ``SavedReplyMenu`` and for the same
/// reason: a text-inserting control must never have to guess which field it is inserting into.
/// The button is only rendered when a tier could take the request (``IntelligenceRouter/canDraft``)
/// — an always-present button that always fails would be worse than no button.
struct AIDraftButton: View {
    /// Whether a request is in flight.
    let isDrafting: Bool
    /// The control's height, so it lines up with the controls beside it.
    var height: CGFloat = 24
    /// Starts a request. Nothing happens without this click — there is no automatic drafting.
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if isDrafting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accentText)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDrafting)
        .fixedSize()
        .frame(height: height)
        .help(String(localized: "Draft with AI — a suggestion you review before anything is sent"))
        .accessibilityLabel(String(localized: "Draft with AI"))
    }
}

/// Everything a drafting attempt has to say, under the field it belongs to.
///
/// One view for all four phases so the two composers cannot drift apart: the caption that marks
/// generated text, the replace-or-append question for a field that already had text in it, and the
/// tier's own reason when nothing came back.
struct AIDraftStatusView: View {
    /// The field's drafting state.
    let state: AIDraftFieldState
    /// The question asked when the field was not empty, e.g. "Replace current summary?".
    let confirmationTitle: String
    /// Replaces the field's contents with the draft.
    var onReplace: () -> Void
    /// Appends the draft after what is already there.
    var onAppend: () -> Void
    /// Throws the draft away.
    var onDiscard: () -> Void

    var body: some View {
        switch state.phase {
        case .idle, .drafting:
            EmptyView()
        case .confirming(let pending):
            confirmation(pending)
        case .drafted(let kind):
            caption(kind)
        case .failed(let message):
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.failure)
        }
    }

    /// The line that marks the field's current contents as generated.
    ///
    /// Shown until the reviewer's first keystroke: after that it is their text, and the label
    /// would be untrue.
    private func caption(_ kind: IntelligenceKind) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
            Text(String(localized: "AI draft (\(kind.badge)) — review before submitting."))
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.accentText)
    }

    /// The replace-or-append question, with the draft itself shown above it.
    ///
    /// The draft is *not* written into the field until one of these is clicked — that is the whole
    /// point of asking — so it is previewed here instead.
    private func confirmation(_ pending: AIDraftFieldState.PendingDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text(confirmationTitle)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text(pending.kind.badge)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
            }
            .foregroundStyle(Theme.accentText)

            ScrollView {
                Text(pending.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 96)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(String(localized: "Discard")) { onDiscard() }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
                Button(String(localized: "Append")) { onAppend() }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
                    .help(String(localized: "Add the draft after what you already wrote"))
                Button(String(localized: "Replace")) { onReplace() }
                    .buttonStyle(SecondaryButtonStyle(height: 26, tint: Theme.accentText))
                    .help(String(localized: "Overwrite the field with the draft"))
            }
        }
        .padding(10)
        .background(
            Theme.accent.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.accent.opacity(0.22), lineWidth: 1)
        )
    }
}
