import Foundation
import ShepherdCore

/// Which tier produced a piece of intelligence (ADR 0007).
enum IntelligenceKind: String, Sendable, Hashable, Codable {
    /// Apple's on-device Foundation Model.
    case onDevice
    /// The Anthropic API, with the user's own key.
    case anthropic
    /// A user-configured OpenAI-compatible endpoint.
    case openAICompatible

    /// The badge shown on hint cards, so the user always knows where a hint came from.
    var badge: String {
        switch self {
        case .onDevice: return String(localized: "on-device")
        case .anthropic: return String(localized: "Anthropic")
        case .openAICompatible: return String(localized: "custom endpoint")
        }
    }
}

/// A short, human-readable summary of a pull request.
struct PRSummary: Sendable, Hashable, Codable {
    /// Two or three sentences describing what the pull request does.
    var overview: String
    /// Short risk notes, each a single sentence.
    var riskNotes: [String]

    /// Creates a summary.
    init(overview: String, riskNotes: [String] = []) {
        self.overview = overview
        self.riskNotes = riskNotes
    }
}

/// A suggestion about where to look first.
///
/// Hints are always *additional* to the deterministic ``ShepherdCore/FilePrioritizer`` output
/// and are never auto-applied (ADR 0007).
struct FocusHint: Sendable, Hashable, Codable, Identifiable {
    /// The file the hint is about.
    var file: String
    /// Why it deserves attention.
    var reason: String

    /// `FocusHint` is identified by the pair it carries.
    var id: String { "\(file)|\(reason)" }

    /// Creates a hint.
    init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

/// The abstraction over intelligence tiers 2 and 3 (`docs/ARCHITECTURE.md`).
protocol IntelligenceProvider: Sendable {
    /// Which tier this is.
    var kind: IntelligenceKind { get }
    /// Whether the provider can serve a request right now.
    var isAvailable: Bool { get async }
    /// Summarises a pull request from a pre-digested view of it.
    func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary
    /// Suggests where a reviewer should look first.
    func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint]
    /// Drafts the body of a review as a **suggestion** for a human reviewer.
    ///
    /// The returned text is put in the summary field for the reviewer to edit; it is never
    /// submitted by anything (ADR 0007 non-goal: auto-submitting AI reviews).
    /// - Parameter request: The context, already inside the tier's token budget.
    /// - Returns: The drafted text, trimmed and never empty.
    /// - Throws: ``IntelligenceError`` when the tier cannot answer.
    func draftReviewSummary(_ request: ReviewSummaryDraftRequest) async throws -> String
    /// Drafts one inline comment as a **suggestion** for a human reviewer.
    ///
    /// Same contract as ``draftReviewSummary(_:)``: the text lands in the composer, and saving it
    /// to the pending review is a separate click by the person reading it.
    /// - Parameter request: The anchor and the diff excerpt around it.
    /// - Returns: The drafted text, trimmed and never empty.
    /// - Throws: ``IntelligenceError`` when the tier cannot answer.
    func draftInlineComment(_ request: InlineCommentDraftRequest) async throws -> String
    /// Drafts a review summary as a stream of **cumulative** text.
    ///
    /// The contract that matters is in that word: every element is the whole draft so far, not
    /// the piece that just arrived. A reviewer's text field is not a terminal — it holds a value,
    /// the reviewer may be about to type into it, and a caller that had to concatenate deltas
    /// itself would be one dropped element away from writing a draft with a hole in it. Cumulative
    /// snapshots also happen to be what the on-device model produces natively, so the two cloud
    /// tiers do the accumulating where the wire shape is known rather than in the UI.
    ///
    /// Same product rule as ``draftReviewSummary(_:)``: this fills a field, nothing else.
    /// - Parameter request: The context, already inside the tier's token budget.
    /// - Returns: A stream of ever-longer drafts, finishing after the last one. It throws
    ///   ``IntelligenceError`` (or the tier's own error) when the tier cannot answer, and
    ///   cancelling the consuming task ends the request.
    func streamReviewSummaryDraft(
        _ request: ReviewSummaryDraftRequest
    ) -> AsyncThrowingStream<String, Error>
    /// Drafts one inline comment as a stream of **cumulative** text.
    ///
    /// Same contract as ``streamReviewSummaryDraft(_:)``.
    /// - Parameter request: The anchor and the diff excerpt around it.
    /// - Returns: A stream of ever-longer drafts.
    func streamInlineCommentDraft(
        _ request: InlineCommentDraftRequest
    ) -> AsyncThrowingStream<String, Error>
}

/// Streaming, for tiers that do not stream.
///
/// A provider is allowed not to support streaming — a local endpoint that rejects `stream: true`,
/// a stub in a test, a tier added later — and the drafting UI must not have to care: it asks for a
/// stream and gets one, which in the worst case has exactly one element in it. That is what keeps
/// "prefer the streaming path" from meaning "some tiers lose their button".
extension IntelligenceProvider {
    func streamReviewSummaryDraft(
        _ request: ReviewSummaryDraftRequest
    ) -> AsyncThrowingStream<String, Error> {
        IntelligenceStreaming.singleValue { try await self.draftReviewSummary(request) }
    }

    func streamInlineCommentDraft(
        _ request: InlineCommentDraftRequest
    ) -> AsyncThrowingStream<String, Error> {
        IntelligenceStreaming.singleValue { try await self.draftInlineComment(request) }
    }
}

/// The plumbing shared by every provider's streaming methods.
enum IntelligenceStreaming {
    /// Wraps one awaited answer as a stream with a single element.
    ///
    /// The element is the finished draft, so a caller that renders every element as "the draft so
    /// far" renders exactly the same thing it would have rendered without streaming.
    /// - Parameter produce: The non-streaming call.
    /// - Returns: A stream that yields the answer and finishes, or finishes throwing.
    static func singleValue(
        _ produce: @escaping @Sendable () async throws -> String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await produce())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drains a failed streaming response's body, best-effort, so the error names the cause.
    ///
    /// A streaming request finds out about a 401 or a 429 the same way a plain one does — from the
    /// status line — but its body arrives as a stream nobody is going to consume. Reading a
    /// bounded prefix of it turns "the endpoint returned 429" into the endpoint's own sentence
    /// about why. Failing to read it is not a second failure worth reporting: the status code is
    /// already the error.
    /// - Parameter bytes: The response body of a request that failed.
    /// - Returns: At most a couple of kilobytes of it.
    static func failureBody(_ bytes: URLSession.AsyncBytes) async -> Data {
        var text = ""
        do {
            for try await line in bytes.lines {
                text += line
                if text.count > 2_000 { break }
            }
        } catch {
            // Nothing to add: the caller already has the status code.
        }
        return Data(text.utf8)
    }

    /// Wraps a producing closure that yields into a continuation itself.
    ///
    /// The same three lines every streaming implementation needs — a task, cancellation wired to
    /// the consumer going away, and a `finish` that happens exactly once — written once so a
    /// provider only has to say what it puts into the stream.
    /// - Parameter produce: Yields cumulative drafts into the continuation. Returning normally
    ///   finishes the stream; throwing finishes it with the error.
    /// - Returns: The stream.
    static func stream(
        _ produce: @escaping @Sendable (AsyncThrowingStream<String, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await produce(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Failures the intelligence layer can produce.
///
/// Every one of them degrades to "no hint card" in the UI — the app is fully usable with
/// intelligence off.
enum IntelligenceError: Error, LocalizedError, Equatable {
    /// The selected provider is not available on this machine or not configured.
    case unavailable(String)
    /// The endpoint is missing a base URL, model or key.
    case notConfigured(String)
    /// The endpoint answered with an error.
    case http(status: Int, message: String)
    /// The answer could not be understood.
    case malformedResponse
    /// The endpoint's model list was well-formed but empty.
    case noModelsListed
    /// The digest did not fit the provider's context window.
    case digestTooLarge(tokens: Int, limit: Int)
    /// The on-device model's safety guardrails refused the prompt or the answer.
    ///
    /// Its own case rather than a ``failed`` string, because it is the one failure that is not a
    /// malfunction: review prose is full of words about deleting, breaking, killing processes and
    /// attacking a problem, and the guardrails trip on technical content often enough that this
    /// has to read as "not this text" rather than as a bug. Never retried — a retry of the same
    /// content trips the same guardrail and only spends battery (plan §0.1).
    case guardrailDeclined
    /// The prompt and the answer together outgrew the model's context window.
    ///
    /// Distinct from ``digestTooLarge(tokens:limit:)``, which is Shepherd's own pre-flight
    /// arithmetic refusing to start: this one is the model saying the real tokenizer disagreed
    /// with the estimate, which can only be found out from inside a session.
    case contextExceeded

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return String(localized: "Intelligence unavailable: \(reason)")
        case .notConfigured(let field):
            return String(localized: "Missing configuration: \(field)")
        case .http(let status, let message):
            return String(localized: "The model endpoint returned \(status): \(message)")
        case .malformedResponse:
            return String(localized: "The model returned something Shepherd could not read.")
        case .noModelsListed:
            return String(localized: "The endpoint did not list any models. Type the model name instead.")
        case .digestTooLarge(let tokens, let limit):
            return String(localized: "This pull request needs ~\(tokens) tokens, over the \(limit) token budget.")
        case .guardrailDeclined:
            return String(localized: "Apple Intelligence declined this content.")
        case .contextExceeded:
            return String(localized: "This content is larger than the on-device model's context window. A cloud provider has room for it.")
        }
    }
}

// MARK: - The shared prompt contract

/// Builds the prompts every provider sends, so the three tiers stay comparable.
enum IntelligencePrompt {
    /// The system/instructions text for summarisation.
    static let summaryInstructions = """
        You review pull requests for a senior engineer. Summarise the change factually in \
        two or three sentences, then list at most three short risk notes. Never invent files, \
        APIs or behaviour that the input does not mention. If the input is too thin to judge, \
        say so plainly.
        """

    /// The system/instructions text for focus hints.
    static let focusInstructions = """
        You triage pull requests for a senior engineer. Name at most four files from the input \
        that deserve the closest reading and give a one-line reason for each. Only use file \
        paths that appear verbatim in the input.
        """

    /// The system/instructions text for a drafted review summary.
    ///
    /// The wording carries the product rule, not just the format: the model is writing a
    /// *suggestion* for a reviewer who will edit it, so it neither approves nor rejects, and it
    /// says "unclear from the diff" instead of filling a gap with something plausible. No
    /// greeting and no praise, because a drafted comment that opens with "Great work!" is a
    /// comment the reviewer has to delete before they can use it.
    static let draftSummaryInstructions = """
        You draft the body of a pull-request review for a senior engineer, who edits it and \
        decides whether to send it. Write at most six sentences: what the change does, then what \
        you would want confirmed or looked at more closely. Short bullets are fine. No greeting, \
        no sign-off, no praise, no restating of the diff line by line. Use only what the input \
        states; never invent files, APIs, behaviour or test results, and write that something is \
        unclear from the diff rather than guessing. This is a suggestion, not a verdict: do not \
        approve, do not reject, and do not claim anything was run or tested.
        """

    /// The system/instructions text for a drafted inline comment.
    static let draftInlineCommentInstructions = """
        You draft one inline review comment for a senior engineer, who edits it and decides \
        whether to send it. Write at most three sentences about the marked line or lines: what \
        looks wrong or worth confirming, and what you would ask the author. No greeting, no \
        sign-off, no praise, no restating of the code. Use only what the excerpt shows; if it is \
        not enough to judge, say which context you would need instead of guessing. This is a \
        suggestion for a human reviewer, not a verdict.
        """

    /// The JSON shape the cloud providers are asked for (summaries).
    static let summaryJSONContract = """
        Answer with JSON only, no prose and no code fence: \
        {"overview": string, "riskNotes": [string]}
        """

    /// The JSON shape the cloud providers are asked for (focus hints).
    static let focusJSONContract = """
        Answer with JSON only, no prose and no code fence: \
        {"hints": [{"file": string, "reason": string}]}
        """

    /// What the cloud providers are asked for instead of JSON when the answer is *streamed*.
    ///
    /// A streamed draft is written into the reviewer's field as it grows, and half of
    /// `{"draft": "The retry bo` is not text anybody can read. So the JSON envelope — which
    /// exists only to keep a preamble out of the field — is replaced by saying the same thing in
    /// words. The parser still runs on the finished answer, so a model that sends the envelope
    /// anyway ends up with the same clean draft as the non-streaming path; it is only the
    /// intermediate frames that would have looked like machinery.
    static let draftPlainTextContract = """
        Answer with the review text itself and nothing else: no JSON, no code fence, no \
        preamble, no closing remark.
        """

    /// The JSON shape the cloud providers are asked for (drafted text).
    ///
    /// One field rather than raw prose: models like to introduce themselves ("Here is a draft
    /// review:"), and a preamble that lands in the reviewer's summary field is a preamble they
    /// have to delete. The parser falls back to the whole answer anyway, so a model that ignores
    /// this still produces something usable.
    static let draftJSONContract = """
        Answer with JSON only, no prose and no code fence: \
        {"draft": string}
        """

    /// Renders a digest as the plain-text body of a prompt.
    /// - Parameter digest: The tier-1 digest.
    static func body(for digest: PullRequestDigest) -> String {
        var text = """
            Repository: \(digest.repoFullName)
            Pull request: #\(digest.number) — \(digest.title)
            Author: \(digest.authorLogin) (\(digest.authorProvenance))
            Base branch: \(digest.baseRefName)
            Size: \(digest.changedFileCount) files, +\(digest.totalAdditions) −\(digest.totalDeletions)
            """
        if !digest.bodyExcerpt.isEmpty {
            text += "\n\nDescription:\n\(digest.bodyExcerpt)"
        }
        if !digest.files.isEmpty {
            text += "\n\nFiles (highest review priority first):"
            for file in digest.files {
                let reasons = file.reasons.isEmpty ? "" : " — \(file.reasons.joined(separator: ", "))"
                text += "\n- \(file.path) [\(file.status.rawValue), \(file.bucket.rawValue)]"
                    + " +\(file.additions) −\(file.deletions)\(reasons)"
            }
        }
        if !digest.topHunks.isEmpty {
            text += "\n\nDiff excerpts:"
            for hunk in digest.topHunks {
                text += "\n\n--- \(hunk.path)\(hunk.truncated ? " (truncated)" : "")\n\(hunk.text)"
            }
        }
        if digest.wasTruncated {
            text += "\n\n(Note: this digest was truncated to fit the token budget.)"
        }
        return text
    }

    /// Renders a summary-draft request: the digest, plus what the reviewer has already written.
    /// - Parameter request: The request.
    static func body(for request: ReviewSummaryDraftRequest) -> String {
        var text = body(for: request.digest)
        if !request.notes.isEmpty {
            text += "\n\nInline comments the reviewer has already written on this pull request."
                + " Refer to them, do not repeat them word for word:"
            for note in request.notes {
                text += "\n- \(note.path):\(note.line) — \(note.body)"
            }
        }
        return text
    }

    /// Renders an inline-comment-draft request.
    /// - Parameter request: The request.
    static func body(for request: InlineCommentDraftRequest) -> String {
        let side = request.anchor.side == .left ? "base" : "head"
        let lines = request.anchor.lineRange.lowerBound == request.anchor.lineRange.upperBound
            ? "\(request.anchor.line)"
            : "\(request.anchor.lineRange.lowerBound)–\(request.anchor.lineRange.upperBound)"
        var text = """
            Repository: \(request.repoFullName)
            Pull request: #\(request.number) — \(request.pullRequestTitle)
            File: \(request.path)
            """
        if let status = request.fileStatus {
            text += " [\(status.rawValue)]"
        }
        text += "\nCommented line: \(side) side, line \(lines)"
        if request.excerpt.isEmpty {
            // Said plainly rather than left out: a model given a file name and no diff should ask
            // for the code, not improvise a review of it.
            text += "\n\nNo diff excerpt is available for this file."
            return text
        }
        text += "\n\nDiff excerpt."
            + " The line or lines being commented on are prefixed with"
            + " \"\(InlineCommentDraftBuilder.anchorMarker.trimmingCharacters(in: .whitespaces))\";"
            + " every other line is context:\n"
            + request.excerpt
        if request.excerptWasTruncated {
            text += "\n\n(Note: the excerpt is a window into a longer diff.)"
        }
        return text
    }
}

// MARK: - Lenient JSON parsing

/// Parses the JSON the cloud providers are asked for, tolerating the ways models get it wrong.
enum IntelligenceJSON {
    private struct SummaryPayload: Decodable {
        var overview: String?
        var riskNotes: [String]?
    }

    private struct DraftPayload: Decodable {
        var draft: String?
    }

    private struct HintsPayload: Decodable {
        struct Hint: Decodable {
            var file: String?
            var reason: String?
        }
        var hints: [Hint]?
    }

    /// Extracts the outermost `{…}` from a model answer that may be wrapped in prose or a fence.
    /// - Parameter text: The raw answer.
    /// - Returns: The JSON substring, or `nil` when there is no brace pair.
    static func extractObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end
        else { return nil }
        return String(text[start...end])
    }

    /// Parses a summary answer, falling back to treating the whole text as the overview.
    /// - Parameter text: The raw answer.
    static func summary(from text: String) -> PRSummary {
        if let object = extractObject(from: text),
           let payload = try? JSONDecoder().decode(SummaryPayload.self, from: Data(object.utf8)),
           let overview = payload.overview, !overview.isEmpty {
            return PRSummary(
                overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
                riskNotes: (payload.riskNotes ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        return PRSummary(overview: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Parses a drafted-text answer.
    ///
    /// Falls back to the whole trimmed answer when the JSON contract was ignored: a model that
    /// simply wrote the draft has still done the job, and dropping it because it was not wrapped
    /// in braces would be the parser being pedantic at the reviewer's expense. An empty answer is
    /// an error, though — an empty field is worse than a red line saying why.
    /// - Parameter text: The raw answer.
    /// - Returns: The drafted text, trimmed.
    /// - Throws: ``IntelligenceError/malformedResponse`` when nothing usable came back.
    static func draft(from text: String) throws -> String {
        if let object = extractObject(from: text),
           let payload = try? JSONDecoder().decode(DraftPayload.self, from: Data(object.utf8)),
           let draft = payload.draft {
            // The contract was honoured, so it is honoured back: an explicitly empty draft is a
            // failure rather than an excuse to hand the reviewer the raw JSON as their comment.
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw IntelligenceError.malformedResponse }
            return trimmed
        }
        let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty else { throw IntelligenceError.malformedResponse }
        return fallback
    }

    /// Parses a focus-hint answer.
    /// - Parameter text: The raw answer.
    /// - Returns: The hints, or an empty array when nothing usable came back.
    static func hints(from text: String) -> [FocusHint] {
        guard let object = extractObject(from: text),
              let payload = try? JSONDecoder().decode(HintsPayload.self, from: Data(object.utf8))
        else { return [] }
        return (payload.hints ?? []).compactMap { hint in
            guard let file = hint.file?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !file.isEmpty,
                  let reason = hint.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reason.isEmpty
            else { return nil }
            return FocusHint(file: file, reason: reason)
        }
    }
}
