import SwiftUI

/// The "draft this text with AI" button that sits next to the summary and comment fields
/// (ADR 0007 amendment), and the stop button it becomes while a draft streams (plan §3.B).
///
/// Placed beside the field it writes into, exactly like ``SavedReplyMenu`` and for the same
/// reason: a text-inserting control must never have to guess which field it is inserting into.
/// The button is only rendered when a tier could take the request (``IntelligenceRouter/canDraft``)
/// — an always-present button that always fails would be worse than no button.
///
/// **One control, one shortcut, both directions.** Starting and stopping share this button and
/// ⇧⌘D rather than growing a second control: while text is arriving, the only thing a reviewer
/// wants from the sparkles button is to make it stop, and a stop that lives somewhere else is a
/// stop nobody finds in the second it is useful. That is also why the button is no longer
/// disabled while a request is in flight — a disabled button in that second would be the bug.
struct AIDraftButton: View {
    /// Whether a request is in flight: waiting for its first token, or streaming.
    let isDrafting: Bool
    /// Whether text is arriving right now, so the control is a stop button with something to stop.
    ///
    /// Split from ``isDrafting`` only for the icon: before the first token there is nothing to
    /// show but a spinner, and swapping the spinner for a stop glyph the moment the first
    /// character lands is what tells the reviewer that the field is now moving.
    var isStreaming: Bool = false
    /// The control's height, so it lines up with the controls beside it.
    var height: CGFloat = 24
    /// Starts a request, or stops the one that is running. Nothing happens without this click —
    /// there is no automatic drafting.
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if isStreaming {
                Image(systemName: "stop.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accentText)
            } else if isDrafting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accentText)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .frame(height: height)
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .help(isDrafting
            ? String(localized: "Stop drafting — what has already arrived stays in the field")
            : String(localized: "Draft with AI — a suggestion you review before anything is sent"))
        .accessibilityLabel(isDrafting
            ? String(localized: "Stop drafting")
            : String(localized: "Draft with AI"))
        .accessibilityHint(isDrafting
            ? String(localized: "Keeps the text that has already arrived, still labelled as a draft.")
            : String(localized: "Drafts a suggestion into the field beside this button. Nothing is sent."))
    }
}

/// Everything a drafting attempt has to say, under the field it belongs to.
///
/// One view for every phase so the two composers cannot drift apart: the replace-or-append
/// question for a field that already had text in it, the "Drafting on-device…" line while the
/// text arrives, the caption that marks the arrived text as generated, and the tier's own reason
/// when nothing came back. All of them are one short line in the same place, so a draft that
/// streams, is stopped and then fails does not make the sheet jump.
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
            // The draft exists but is not in the field, so it is previewed inside the question.
            question(badge: pending.kind.badge, preview: pending.text)
        case .confirmingStream:
            // A streamed draft is asked about *before* the request is made, so there is nothing
            // to preview and no tier to name yet — and a discarded question sends nothing at all.
            question(badge: nil, preview: nil)
        case .streaming(let streaming):
            streamingCaption(streaming.kind)
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

    /// The line shown while text is still arriving, naming the tier producing it.
    ///
    /// A different sentence from ``caption(_:)`` on purpose. While the stream runs, the fact the
    /// reviewer needs is that *more is coming* — a field that is growing under the cursor is not
    /// a field to start editing — and afterwards the fact they need is that what they are reading
    /// was generated. The tier is in both, and it is in this one because
    /// ``IntelligenceStream`` settles it before the first character: "Drafting on-device…" is
    /// also the honest answer to "did this just leave my Mac?", which is worth reading while the
    /// text arrives rather than after.
    /// - Parameter kind: The tier that is answering.
    private func streamingCaption(_ kind: IntelligenceKind) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
            Text(AIDraftStatusView.draftingLine(kind))
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.accentText)
    }

    /// "Drafting on-device…" or "Drafting with <provider>…".
    ///
    /// Two sentences rather than one interpolation of ``IntelligenceKind/badge``, because the
    /// badges are not all nouns you can put after "with": "Drafting with on-device…" is not a
    /// sentence, and a translator handed one key here could not fix that either.
    /// - Parameter kind: The tier that is answering.
    /// - Returns: The already-localized line.
    static func draftingLine(_ kind: IntelligenceKind) -> String {
        switch kind {
        case .onDevice:
            return String(localized: "Drafting on-device…")
        case .anthropic, .openAICompatible:
            return String(localized: "Drafting with \(kind.badge)…")
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

    /// The replace-or-append question.
    ///
    /// Nothing is written into the field until one of these is clicked — that is the whole point
    /// of asking. A draft that already exists is previewed inside the question; a streamed one
    /// has not been requested yet, so there is neither a preview nor a tier badge.
    /// - Parameters:
    ///   - badge: The tier that produced the waiting draft, when there is one.
    ///   - preview: The waiting draft, when there is one.
    private func question(badge: String?, preview: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text(confirmationTitle)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .foregroundStyle(Theme.accentText)

            if let preview {
                ScrollView {
                    Text(preview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 96)
            }

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
