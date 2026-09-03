import SwiftUI

/// The state behind "Explain these lines" (plan §3.D).
///
/// A pure value for the same reason ``AIDraftFieldState`` is one: what is worth getting right here
/// is a small set of rules about *what the reviewer did*, and none of them is visual.
///
/// - **Stop keeps what arrived.** A reviewer who has read enough presses stop, and the sentences
///   already on screen stay — and stay attributed to the tier that wrote them, because they are
///   still not the reviewer's words. What is left is a finished explanation as far as it got.
/// - **Escape is not stop.** Closing the popover throws the answer away (``reset()``) rather than
///   keeping it: a popover the reviewer dismissed is a question they withdrew, and re-opening it
///   showing yesterday's half explanation would be a stale answer to a new selection.
/// - **A failure mid-answer keeps the partial *and* says why.** The opposite of the drafting
///   field's rule, deliberately: there, a red line under text sitting in an editable field would
///   suggest the text is not the reviewer's to keep, whereas this popover is read-only and has
///   room for both, and half an explanation with no reason is the misleading half.
/// - **Nothing here writes anywhere.** The only thing this type produces is a string
///   (``explanation``); putting it into the comment field is a separate click that goes through
///   ``AIDraftFieldState``, so the replace-or-append rule and the draft caption apply to an
///   explanation exactly as they do to a draft. There is no path from here to the outbox
///   (ADR 0007's non-goal).
struct ExplainSelectionState: Equatable, Sendable {
    /// Where an explanation stands.
    enum Phase: Equatable, Sendable {
        /// Nothing asked, nothing to show.
        case idle
        /// A request is out; no tier has answered yet.
        case requesting
        /// Text is arriving. `partial` is the whole explanation so far, never a delta.
        case streaming(kind: IntelligenceKind, partial: String)
        /// A complete explanation — or as complete as the reviewer let it become.
        case explained(kind: IntelligenceKind, text: String)
        /// The stream failed after some text had arrived: both are shown.
        case interrupted(kind: IntelligenceKind, text: String, message: String)
        /// Nothing arrived, and this is the tier's own reason.
        case failed(String)
    }

    /// The current phase.
    private(set) var phase: Phase = .idle

    /// Creates an idle state.
    init() {}

    /// Whether a request is out: waiting for a tier, or streaming.
    var isExplaining: Bool {
        switch phase {
        case .requesting, .streaming: return true
        default: return false
        }
    }

    /// Whether text is arriving right now — the stop button with something to stop.
    var isStreaming: Bool {
        if case .streaming = phase { return true }
        return false
    }

    /// The explanation as it should be rendered right now, growing while it streams.
    var text: String {
        switch phase {
        case .idle, .requesting, .failed: return ""
        case .streaming(_, let partial): return partial
        case .explained(_, let text): return text
        case .interrupted(_, let text, _): return text
        }
    }

    /// The tier that is answering, or answered.
    var kind: IntelligenceKind? {
        switch phase {
        case .streaming(let kind, _): return kind
        case .explained(let kind, _): return kind
        case .interrupted(let kind, _, _): return kind
        case .idle, .requesting, .failed: return nil
        }
    }

    /// The finished text that may be turned into a comment, when there is any.
    ///
    /// Deliberately `nil` while the answer is still arriving: a reviewer who clicks "Turn into a
    /// comment" mid-sentence would get a comment ending mid-sentence, and the honest fix is that
    /// the button is not there yet rather than that it silently waits.
    var explanation: String? {
        switch phase {
        case .explained(_, let text): return text
        case .interrupted(_, let text, _): return text
        default: return nil
        }
    }

    /// The failure to show, when there is one.
    var failureMessage: String? {
        switch phase {
        case .failed(let message): return message
        case .interrupted(_, _, let message): return message
        default: return nil
        }
    }

    /// Marks a request as started.
    mutating func begin() {
        phase = .requesting
    }

    /// Records that a tier has started answering.
    ///
    /// The tier is known before the first character, because the router hands it out with the
    /// stream — which is what lets the caption say "Explaining on-device…" while the reviewer is
    /// still deciding whether to read it.
    /// - Parameter kind: The tier that answered.
    mutating func started(kind: IntelligenceKind) {
        phase = .streaming(kind: kind, partial: "")
    }

    /// Takes one cumulative snapshot.
    /// - Parameter partial: The whole explanation so far — not the piece that just arrived.
    mutating func streamed(_ partial: String) {
        guard case .streaming(let kind, let previous) = phase, previous != partial else { return }
        phase = .streaming(kind: kind, partial: partial)
    }

    /// Ends a stream that ran to completion.
    ///
    /// The trim happens once, here, for the same reason the drafting field trims once: a body of
    /// text that loses and regains its last newline as it arrives is a body of text that flickers.
    mutating func finish() {
        guard case .streaming(let kind, let partial) = phase else { return }
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed(String(localized: "The model returned an empty explanation."))
            return
        }
        phase = .explained(kind: kind, text: trimmed)
    }

    /// Ends a stream the reviewer stopped, keeping every sentence that arrived.
    ///
    /// A stop before the first character leaves no trace of any kind: nothing was shown and
    /// nothing failed, and telling the reviewer that they stopped something would be noise.
    /// Cancelling the *task* is the caller's half of this; a value type cannot cancel anything.
    mutating func stop() {
        switch phase {
        case .requesting:
            phase = .idle
        case .streaming(let kind, let partial):
            let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = trimmed.isEmpty ? .idle : .explained(kind: kind, text: trimmed)
        default:
            break
        }
    }

    /// Ends a stream that failed.
    ///
    /// Text that already arrived is kept beside the reason rather than instead of it — see the
    /// type's rules for why this differs from the drafting field.
    /// - Parameter message: The tier's own reason.
    mutating func fail(_ message: String) {
        if case .streaming(let kind, let partial) = phase {
            let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                phase = .interrupted(kind: kind, text: trimmed, message: message)
                return
            }
        }
        phase = .failed(message)
    }

    /// Forgets everything: the popover closed, or the reviewer pressed Escape.
    mutating func reset() {
        phase = .idle
    }
}

// MARK: - The button that opens it

/// The control that asks for an explanation of the selected lines (plan §3.D).
///
/// Beside the sparkles button and shaped like it, because the two are the same kind of thing from
/// the reviewer's side — one click, one answer from a tier, nothing sent anywhere — and the
/// difference is only which question is being asked. It is rendered under the same condition
/// (``IntelligenceRouter/canDraft``): a button that is always there and always fails would be
/// worse than no button.
///
/// ⌥E rather than a second sparkles: the shortcut has to be reachable while the selection is
/// still fresh, and ⇧⌘D already means "write something for me" in both composers.
struct ExplainSelectionButton: View {
    /// Whether a request is out, so the control is a stop button.
    let isExplaining: Bool
    /// The control's height, so it lines up with the controls beside it.
    var height: CGFloat = 24
    /// Asks for an explanation, or stops the one that is running.
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isExplaining ? "stop.circle" : "text.magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accentText)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .frame(height: height)
        .keyboardShortcut("e", modifiers: [.option])
        .help(isExplaining
            ? String(localized: "Stop explaining — what has already arrived stays")
            : String(localized: "Explain these lines — plain language, in your language"))
        .accessibilityLabel(isExplaining
            ? String(localized: "Stop explaining")
            : String(localized: "Explain these lines"))
        .accessibilityHint(Text(isExplaining
            ? String(localized: "Keeps the sentences that have already arrived.")
            : String(localized: "Explains what the selected lines change. Nothing is sent and nothing is saved.")))
    }
}

// MARK: - The popover

/// The native popover that explains the selected lines (plan §3.D).
///
/// Native SwiftUI rather than rendered inside the diff webview, and that is a rule rather than a
/// convenience: the webview never handles text (ADR 0003), so an explanation drawn in it would be
/// the first piece of Shepherd's own prose living behind the bridge — untranslatable, unselectable
/// by the system's own text services, and impossible to hand to the comment field without a new
/// message in both directions.
///
/// Presentation only. Every decision — start, stop, cancel, keep — is
/// ``ExplainSelectionState``'s, and the one *product* rule is the button at the bottom: it hands
/// the finished text to the caller, which writes it through ``AIDraftFieldState`` so an
/// explanation cannot overwrite a comment the reviewer had already started typing.
struct ExplainSelectionPopover: View {
    /// Where the explanation stands.
    let state: ExplainSelectionState
    /// The file, side and lines being explained, as the composer already renders them.
    let anchorDescription: String
    /// Stops the request, keeping what arrived.
    var onStop: () -> Void
    /// Closes the popover and throws the answer away — the Escape path.
    var onCancel: () -> Void
    /// Puts the explanation into the comment field, through the drafting rules.
    var onTurnIntoComment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(Theme.border)
            content
            if let kind = state.kind, state.explanation != nil {
                caption(kind)
            }
            if let message = state.failureMessage {
                failure(message)
            }
            Text(String(
                localized: "An explanation, not a review. Nothing is saved until you add a comment yourself."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(16)
        .frame(width: 380)
        .background(Theme.panel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(localized: "What these lines change"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text(anchorDescription)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// The answer, or the line that says it is on its way.
    ///
    /// The text is drawn in the secondary colour while it streams and in the body colour once it
    /// is finished — the same signal the composer's field carries during a draft (plan §3.B), so
    /// "this is still growing, do not start reading the last sentence yet" looks the same in both
    /// places.
    @ViewBuilder
    private var content: some View {
        if !state.text.isEmpty {
            ScrollView {
                Text(state.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(state.isStreaming ? Theme.textSecondary : Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 220)
        } else if state.isExplaining {
            // Only while something is actually on its way. A failure with no text has the failure
            // line below to carry it, and "Reading the selected lines…" over a red sentence would
            // be the popover contradicting itself.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(pendingLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accentText)
            }
            .frame(minHeight: 44, alignment: .leading)
        }
    }

    /// What to say before the first sentence arrives.
    ///
    /// Two states, and they are worth telling apart: until a tier has answered nobody can say
    /// where the answer will come from, and the moment one has, the caption says so — which is
    /// the whole reason the router hands out the tier together with the stream.
    private var pendingLine: String {
        guard let kind = state.kind else {
            return String(localized: "Reading the selected lines…")
        }
        return ExplainSelectionPopover.explainingLine(kind)
    }

    /// The line that names the tier the explanation came from.
    private func caption(_ kind: IntelligenceKind) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
            Text(ExplainSelectionPopover.tierLine(kind))
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.accentText)
    }

    private func failure(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.failure)
    }

    /// Stop or close on the left of the row, and the one thing this popover produces on the right.
    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            // One `.cancelAction` control: while text is arriving Escape stops the request, and
            // afterwards it closes the popover — the same two meanings the composer's own Cancel
            // button carries, so the key does not mean a third thing here.
            Button(state.isExplaining
                ? String(localized: "Stop explaining")
                : String(localized: "Close")
            ) {
                if state.isExplaining {
                    onStop()
                } else {
                    onCancel()
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 28))
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "Turn into a comment")) { onTurnIntoComment() }
                .buttonStyle(SecondaryButtonStyle(height: 28, tint: Theme.accentText))
                .disabled(state.explanation == nil)
                .help(String(
                    localized: "Puts the explanation into the comment field as a draft you edit"
                ))
        }
    }

    /// "Explaining on-device…" or "Explaining with <provider>…".
    ///
    /// Two sentences rather than one interpolation of ``IntelligenceKind/badge``, for the reason
    /// ``AIDraftStatusView/draftingLine(_:)`` gives: the badges are not all nouns that can follow
    /// "with", and a translator handed one key could not fix that either.
    /// - Parameter kind: The tier that is answering.
    /// - Returns: The already-localized line.
    static func explainingLine(_ kind: IntelligenceKind) -> String {
        switch kind {
        case .onDevice:
            return String(localized: "Explaining on-device…")
        case .anthropic, .openAICompatible:
            return String(localized: "Explaining with \(kind.badge)…")
        }
    }

    /// "Explained on-device" or "Explained by <provider>".
    ///
    /// The caption the plan asks for, and the honest answer to "did these lines leave my Mac?" —
    /// which is why it names the tier rather than saying "AI" and why it is present the whole
    /// time the text is, not only after it finished arriving.
    /// - Parameter kind: The tier that answered.
    /// - Returns: The already-localized line.
    static func tierLine(_ kind: IntelligenceKind) -> String {
        switch kind {
        case .onDevice:
            return String(localized: "Explained on-device")
        case .anthropic, .openAICompatible:
            return String(localized: "Explained by \(kind.badge)")
        }
    }
}
