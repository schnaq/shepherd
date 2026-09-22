import Foundation

/// The state behind one "Draft with AI" button and the text field it writes into
/// (ADR 0007 amendment).
///
/// A pure value, deliberately, because the rules worth getting right here are not visual:
///
/// - **A draft never silently overwrites what the reviewer wrote.** An arriving draft goes into an
///   empty field directly; into a field that already has text it goes nowhere until the reviewer
///   picks *replace* or *append*. That is the difference between a tool and a surprise. For a
///   *streamed* draft the same question is asked **before the request starts** — see
///   ``prepareStream(existingText:)`` — because a stream that had to stop and ask halfway would
///   either freeze mid-sentence or write first and ask afterwards.
/// - **The "AI draft" caption disappears on the first edit.** The label exists so nobody submits
///   generated text believing they wrote it; once they have started editing, it is their text and
///   the caption would be a lie. Distinguishing "the reviewer typed" from "this type wrote" is why
///   ``writtenText`` is kept.
/// - **A keystroke wins over a stream.** If the reviewer starts typing while text is still
///   arriving, the stream loses the field: later snapshots are dropped instead of overwriting
///   what was just typed. The rule above has no exception for "but the draft was not finished".
/// - **What arrived stays, and stays labelled.** A cancelled or interrupted stream leaves the
///   partial draft in the field with its caption — the reviewer asked for text, some text came,
///   and deleting it would be the surprise.
/// - **Every failure is a sentence, not a missing draft.** The reason comes from
///   ``IntelligenceOutcome`` / ``IntelligenceStreamOutcome`` and is shown verbatim.
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
        /// Who actually ran the model, when the endpoint volunteered it (plan §3.K). `nil` for
        /// every tier that says nothing about it, which leaves the caption as it was.
        var servedBy: String? = nil
    }

    /// A stream in flight, and everything needed to render the field while it runs.
    struct StreamingDraft: Equatable, Sendable {
        /// Which tier is producing the text, known before the first token arrived.
        var kind: IntelligenceKind
        /// Who actually ran the model, settled with ``kind`` from the response headers.
        var servedBy: String? = nil
        /// What the reviewer had written before the stream started, plus the blank line that
        /// separates it. Empty when the draft replaces the field's contents.
        var base: String
        /// The last cumulative draft that arrived. Never a delta.
        var partial: String

        /// What the field holds right now.
        var text: String { base + partial }
    }

    /// The reviewer's answer to the replace-or-append question.
    enum Choice: Equatable, Sendable {
        /// The draft takes the field.
        case replace
        /// The draft goes after what is already there.
        case append
    }

    /// What has to happen before a stream may write into the field.
    enum StreamPreparation: Equatable, Sendable {
        /// Start the request; the draft grows after `base`.
        case ready(base: String)
        /// The field is not empty: nothing has been requested, and nothing will be until the
        /// reviewer answers through ``AIDraftFieldState/resolve(_:existingText:)``.
        case askFirst
    }

    /// What answering the replace-or-append question asks the caller to do.
    enum Resolution: Equatable, Sendable {
        /// Write this text into the field.
        case write(String)
        /// Start the streaming request; the draft grows after `base`.
        case startStream(base: String)
        /// Nothing was waiting.
        case nothing
    }

    /// Where the button and its field stand.
    enum Phase: Equatable, Sendable {
        /// Nothing in flight, nothing to say.
        case idle
        /// A request is running.
        case drafting
        /// A draft is waiting for the reviewer to choose replace or append.
        case confirming(PendingDraft)
        /// A *stream* is waiting for the same choice — asked before the request is made, so the
        /// tier is not known yet and there is nothing to preview.
        case confirmingStream
        /// Text is arriving.
        case streaming(StreamingDraft)
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

    /// Who ran the model for the finished draft now in the field, when the endpoint said.
    ///
    /// Stored rather than carried on ``Phase/drafted(_:)`` so that the phase enum — which four
    /// files switch over exhaustively — keeps its shape, and cleared wherever the caption goes:
    /// on a new request, and on the reviewer's first keystroke.
    private var draftedServedBy: String?

    /// Creates an idle state.
    init() {}

    /// Whether a request is in flight — the spinner, and the disabled button.
    ///
    /// A running stream counts: text is arriving into this field, and a second request into the
    /// same field would interleave two drafts.
    var isDrafting: Bool {
        switch phase {
        case .drafting, .streaming: return true
        default: return false
        }
    }

    /// The draft waiting for a replace-or-append decision, if any.
    var pendingDraft: PendingDraft? {
        if case .confirming(let pending) = phase { return pending }
        return nil
    }

    /// Whether a stream is waiting for the replace-or-append answer.
    var isConfirmingStream: Bool {
        if case .confirmingStream = phase { return true }
        return false
    }

    /// The stream in flight, if any.
    var streamingDraft: StreamingDraft? {
        if case .streaming(let streaming) = phase { return streaming }
        return nil
    }

    /// The tier whose unedited draft is currently in the field, if any.
    var draftedKind: IntelligenceKind? {
        if case .drafted(let kind) = phase { return kind }
        return nil
    }

    /// The tier the field's current contents should be labelled with, if any.
    ///
    /// The caption is the same during a stream and after it: the text is generated either way,
    /// and a label that only appeared once the stream finished would be missing exactly while the
    /// reviewer is reading the text for the first time.
    var labelledKind: IntelligenceKind? {
        switch phase {
        case .drafted(let kind): return kind
        case .streaming(let streaming): return streaming.kind
        default: return nil
        }
    }

    /// Who actually ran the model for the text the caption is about, when the endpoint said so.
    ///
    /// The generic served-by hook's last hop (plan §3.K): present only for a tier whose endpoint
    /// volunteered it, and read alongside ``labelledKind`` so the caption is one line either way
    /// — "AI draft (custom endpoint)" or "AI draft (custom endpoint · scaleway)".
    var labelledServedBy: String? {
        switch phase {
        case .drafted: return draftedServedBy
        case .streaming(let streaming): return streaming.servedBy
        default: return nil
        }
    }

    /// The failure to show, if the last attempt failed.
    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Marks a request as started.
    mutating func begin() {
        phase = .drafting
        draftedServedBy = nil
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
                phase = .confirming(
                    PendingDraft(text: draft, kind: output.kind, servedBy: output.servedBy)
                )
                return nil
            }
            return write(draft, kind: output.kind, servedBy: output.servedBy)
        }
    }

    /// Replaces the field's contents with the waiting draft.
    /// - Returns: The text to write, or `nil` when nothing is waiting.
    mutating func replaceWithPendingDraft() -> String? {
        guard let pending = pendingDraft else { return nil }
        return write(pending.text, kind: pending.kind, servedBy: pending.servedBy)
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
        guard !trimmed.isEmpty else {
            return write(pending.text, kind: pending.kind, servedBy: pending.servedBy)
        }
        return write(
            trimmed + "\n\n" + pending.text,
            kind: pending.kind,
            servedBy: pending.servedBy
        )
    }

    /// Throws the waiting draft away. The field is untouched, because it never was touched.
    ///
    /// Also the answer to the streamed question: discarding there means the request is never
    /// made, so nothing is generated, nothing is sent to a provider and nothing is spent.
    mutating func discardPendingDraft() {
        switch phase {
        case .confirming, .confirmingStream: phase = .idle
        default: break
        }
    }

    // MARK: - Streaming (plan §0.2)

    /// Asks the one question a stream cannot ask later.
    ///
    /// The replace-or-append decision has to be settled **before** the first token, and this is
    /// the earliest possible moment: before the request exists. That ordering is not only about
    /// the field — a reviewer who answers "discard" here has sent nothing to any provider at all,
    /// whereas asking after the answer arrived would mean the text was generated (and, for tier
    /// 3, transmitted) to be thrown away.
    /// - Parameter existingText: What is in the field right now.
    /// - Returns: Whether the caller may start the request, and what the draft grows after.
    mutating func prepareStream(existingText: String) -> StreamPreparation {
        guard existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .confirmingStream
            return .askFirst
        }
        phase = .drafting
        return .ready(base: "")
    }

    /// Applies the reviewer's answer to the replace-or-append question.
    ///
    /// One entry point for both kinds of draft, so the two composers have one code path: a
    /// waiting *value* is written into the field, a waiting *stream* is started.
    /// - Parameters:
    ///   - choice: What the reviewer picked.
    ///   - existingText: What is in the field right now.
    /// - Returns: What the caller must do.
    mutating func resolve(_ choice: Choice, existingText: String) -> Resolution {
        switch phase {
        case .confirming:
            let text = choice == .replace
                ? replaceWithPendingDraft()
                : appendPendingDraft(to: existingText)
            guard let text else { return .nothing }
            return .write(text)
        case .confirmingStream:
            phase = .drafting
            guard choice == .append else { return .startStream(base: "") }
            let trimmed = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .startStream(base: "") }
            // The blank line is part of the base rather than of the first snapshot, so the
            // reviewer's own paragraph never moves while the draft grows under it.
            return .startStream(base: trimmed + "\n\n")
        default:
            return .nothing
        }
    }

    /// Records that a tier has started answering.
    ///
    /// Nothing is written yet: the first snapshot does that. What this settles is the caption,
    /// which is why the router hands out the tier with the stream rather than after it.
    /// - Parameters:
    ///   - kind: The tier that answered.
    ///   - servedBy: Who actually ran the model, when the endpoint's response headers said
    ///     (``IntelligenceStream/servedBy``). Defaulted, because almost every tier says nothing.
    ///   - base: What the draft grows after, from ``prepareStream(existingText:)`` or
    ///     ``resolve(_:existingText:)``.
    mutating func streamStarted(
        kind: IntelligenceKind,
        servedBy: String? = nil,
        base: String
    ) {
        phase = .streaming(
            StreamingDraft(kind: kind, servedBy: servedBy, base: base, partial: "")
        )
    }

    /// Takes one cumulative snapshot of the draft.
    /// - Parameter partial: The whole draft so far — not the piece that just arrived.
    /// - Returns: The text to write into the field, or `nil` when nothing should be written:
    ///   the snapshot changed nothing, or the reviewer has taken the field over by typing.
    mutating func streamed(_ partial: String) -> String? {
        guard var streaming = streamingDraft else { return nil }
        guard streaming.partial != partial else { return nil }
        streaming.partial = partial
        phase = .streaming(streaming)
        let text = streaming.text
        writtenText = text
        return text
    }

    /// Ends a stream that ran to completion.
    ///
    /// The trailing trim happens once, here, for the same reason the provider does not trim every
    /// snapshot: a field that loses and regains its last newline as text arrives is a field that
    /// flickers.
    /// - Returns: The trimmed draft to write, or `nil` when no stream was running and when the
    ///   stream produced nothing at all — which becomes a failure line, not an empty caption.
    mutating func finishStream() -> String? {
        guard let streaming = streamingDraft else { return nil }
        let trimmed = streaming.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed(String(localized: "The model returned an empty draft."))
            return nil
        }
        return write(
            streaming.base + trimmed,
            kind: streaming.kind,
            servedBy: streaming.servedBy
        )
    }

    /// Stops a request that has not produced a single character yet.
    ///
    /// The counterpart of ``cancelStream()`` for the window between the click and the first
    /// snapshot — a warm-up that is usually short and occasionally is not. Without it the stop
    /// button would be a button that does nothing exactly while the reviewer most wants it: the
    /// spinner is up, no text has arrived, and the only way out would be to wait for a draft they
    /// have decided against. It leaves no trace of any kind, because nothing was written and
    /// nothing failed — the reviewer stopped it themselves, and telling them so would be noise.
    ///
    /// Stopping the *task* is the caller's half of this (the composers own it); this half is the
    /// field's, and the two are separate because a value type cannot cancel anything.
    mutating func cancelDrafting() {
        if case .drafting = phase { phase = .idle }
    }

    /// Ends a stream the reviewer stopped, or that stopped with the window.
    ///
    /// What arrived stays, and stays labelled — see the type's rules. An empty stop leaves no
    /// trace at all: no caption, no error, because nothing happened that the reviewer did not do.
    /// - Returns: The trimmed draft to write, or `nil` when there was nothing to keep.
    mutating func cancelStream() -> String? {
        guard let streaming = streamingDraft else { return nil }
        let trimmed = streaming.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .idle
            return nil
        }
        return write(
            streaming.base + trimmed,
            kind: streaming.kind,
            servedBy: streaming.servedBy
        )
    }

    /// Ends a stream that failed part-way.
    ///
    /// Text that already arrived wins over the error line: the reviewer can see the half draft in
    /// front of them, and a red sentence under it would suggest the text is not theirs to keep.
    /// When nothing arrived, the sentence is all there is.
    /// - Parameter message: The tier's own reason.
    /// - Returns: The trimmed draft to write, or `nil` when nothing had arrived.
    mutating func failStream(_ message: String) -> String? {
        guard let streaming = streamingDraft else {
            phase = .failed(message)
            return nil
        }
        let trimmed = streaming.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed(message)
            return nil
        }
        return write(
            streaming.base + trimmed,
            kind: streaming.kind,
            servedBy: streaming.servedBy
        )
    }

    /// Called with the field's new text on every change.
    ///
    /// A failure line is deliberately *not* cleared here: it explains why the field is still
    /// empty, and it should stay readable while the reviewer types their own text instead. It
    /// goes on the next attempt.
    ///
    /// A keystroke during a stream ends the stream's claim on the field: the phase drops to idle,
    /// later snapshots are refused by ``streamed(_:)``, and the caption goes because the text is
    /// no longer only the model's.
    /// - Parameter text: The field's new contents.
    mutating func fieldChanged(to text: String) {
        if let writtenText, writtenText == text { return }
        writtenText = nil
        switch phase {
        case .drafted, .streaming:
            phase = .idle
            // The served-by phrase is part of the caption, so it goes with it: after the first
            // keystroke the text is the reviewer's, and who ran the model that suggested it is no
            // longer a statement about what is in the field.
            draftedServedBy = nil
        default: break
        }
    }

    private mutating func write(
        _ text: String,
        kind: IntelligenceKind,
        servedBy: String? = nil
    ) -> String {
        writtenText = text
        draftedServedBy = servedBy
        phase = .drafted(kind)
        return text
    }
}

/// How a failure that arrives *after* a stream started becomes the one line the field shows.
///
/// A stream that fails mid-answer has no ``IntelligenceOutcome`` left to carry its reason — the
/// ladder committed to a tier when the first element arrived — so the composers turn the thrown
/// error into exactly the sentence the router would have produced for it. Same rule as everywhere
/// else in this layer: the tier's own words, shown verbatim, never printed anywhere.
enum AIDraftFailure {
    /// The sentence to show for a thrown error.
    /// - Parameter error: What the stream threw.
    /// - Returns: The error's own description.
    static func describe(_ error: any Error) -> String {
        error.userFacingDescription
    }
}
