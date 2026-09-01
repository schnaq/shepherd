import Foundation

/// The state behind one "Draft with AI" button and the text field it writes into
/// (ADR 0007 amendment).
///
/// A pure value, deliberately, because the rules worth getting right here are not visual:
///
/// - **A draft never silently overwrites what the reviewer wrote.** An arriving draft goes into an
///   empty field directly; into a field that already has text it goes nowhere until the reviewer
///   picks *replace* or *append*. That is the difference between a tool and a surprise.
/// - **The "AI draft" caption disappears on the first edit.** The label exists so nobody submits
///   generated text believing they wrote it; once they have started editing, it is their text and
///   the caption would be a lie. Distinguishing "the reviewer typed" from "this type wrote" is why
///   ``writtenText`` is kept.
/// - **Every failure is a sentence, not a missing draft.** The reason comes from
///   ``IntelligenceOutcome`` and is shown verbatim.
///
/// Nothing here can submit anything: the only thing this type produces is text for a field
/// (`ROADMAP.md` non-goal — auto-submitting AI reviews).
struct AIDraftFieldState: Equatable, Sendable {
    /// A draft that arrived while the field already had text in it.
    struct PendingDraft: Equatable, Sendable {
        /// The drafted text, trimmed.
        var text: String
        /// Which tier produced it, for the badge on the confirmation.
        var kind: IntelligenceKind
    }

    /// Where the button and its field stand.
    enum Phase: Equatable, Sendable {
        /// Nothing in flight, nothing to say.
        case idle
        /// A request is running.
        case drafting
        /// A draft is waiting for the reviewer to choose replace or append.
        case confirming(PendingDraft)
        /// The field holds an AI draft the reviewer has not edited yet.
        case drafted(IntelligenceKind)
        /// The last attempt failed, with the tier's own reason.
        case failed(String)
    }

    /// The current phase.
    private(set) var phase: Phase = .idle

    /// The exact text this type last wrote into the field.
    ///
    /// Needed because SwiftUI reports *any* change to the binding, this type's own writes
    /// included; without it, writing a draft would immediately look like the reviewer editing it
    /// and the caption would never appear.
    private var writtenText: String?

    /// Creates an idle state.
    init() {}

    /// Whether a request is in flight — the spinner, and the disabled button.
    var isDrafting: Bool {
        if case .drafting = phase { return true }
        return false
    }

    /// The draft waiting for a replace-or-append decision, if any.
    var pendingDraft: PendingDraft? {
        if case .confirming(let pending) = phase { return pending }
        return nil
    }

    /// The tier whose unedited draft is currently in the field, if any.
    var draftedKind: IntelligenceKind? {
        if case .drafted(let kind) = phase { return kind }
        return nil
    }

    /// The failure to show, if the last attempt failed.
    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Marks a request as started.
    mutating func begin() {
        phase = .drafting
    }

    /// Applies the outcome of a request.
    /// - Parameters:
    ///   - outcome: What the router answered.
    ///   - existingText: What is in the field right now.
    /// - Returns: The text the caller must write into the field, or `nil` when the field must be
    ///   left exactly as it is — which is the case for every failure *and* for a draft that is
    ///   waiting for the reviewer to decide what to do with it.
    mutating func finish(
        _ outcome: IntelligenceOutcome<String>,
        existingText: String
    ) -> String? {
        switch outcome {
        case .disabled:
            // The button is not offered in this state; arriving here means the settings changed
            // mid-request, and the honest response is to say nothing at all.
            phase = .idle
            return nil
        case .unavailable(let reason), .failed(let reason):
            phase = .failed(reason)
            return nil
        case .value(let output):
            let draft = output.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.isEmpty else {
                phase = .failed(String(localized: "The model returned an empty draft."))
                return nil
            }
            guard existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                phase = .confirming(PendingDraft(text: draft, kind: output.kind))
                return nil
            }
            return write(draft, kind: output.kind)
        }
    }

    /// Replaces the field's contents with the waiting draft.
    /// - Returns: The text to write, or `nil` when nothing is waiting.
    mutating func replaceWithPendingDraft() -> String? {
        guard let pending = pendingDraft else { return nil }
        return write(pending.text, kind: pending.kind)
    }

    /// Appends the waiting draft after what the reviewer already wrote.
    ///
    /// A blank line between the two, like ``ShepherdCore/SavedReply/inserting(_:into:)``: the
    /// field is Markdown, and two paragraphs run together otherwise.
    /// - Parameter existingText: What is in the field right now.
    /// - Returns: The text to write, or `nil` when nothing is waiting.
    mutating func appendPendingDraft(to existingText: String) -> String? {
        guard let pending = pendingDraft else { return nil }
        let trimmed = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return write(pending.text, kind: pending.kind) }
        return write(trimmed + "\n\n" + pending.text, kind: pending.kind)
    }

    /// Throws the waiting draft away. The field is untouched, because it never was touched.
    mutating func discardPendingDraft() {
        guard pendingDraft != nil else { return }
        phase = .idle
    }

    /// Called with the field's new text on every change.
    ///
    /// A failure line is deliberately *not* cleared here: it explains why the field is still
    /// empty, and it should stay readable while the reviewer types their own text instead. It
    /// goes on the next attempt.
    /// - Parameter text: The field's new contents.
    mutating func fieldChanged(to text: String) {
        if let writtenText, writtenText == text { return }
        writtenText = nil
        if case .drafted = phase { phase = .idle }
    }

    private mutating func write(_ text: String, kind: IntelligenceKind) -> String {
        writtenText = text
        phase = .drafted(kind)
        return text
    }
}
