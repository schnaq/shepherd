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
    /// Explains the lines a reviewer selected, as a stream of **cumulative** text (plan §3.D).
    ///
    /// The third surface built on the drafting contract and the one that is not a draft: the
    /// answer is prose the reviewer *reads* rather than text they send, so it is asked for as
    /// plain text (``IntelligencePrompt/draftPlainTextContract``) and nothing about it is written
    /// into a field unless the reviewer presses "Turn into a comment" — which then goes through
    /// ``AIDraftFieldState`` exactly like any other draft.
    ///
    /// Streamed only, with no awaited twin. An explanation is read as it arrives — that is what
    /// makes a three-sentence answer from a small local model feel instant — and a second,
    /// non-streaming entry point would be a code path with no caller.
    /// - Parameter request: The selection, its excerpt and the language to answer in.
    /// - Returns: A stream of ever-longer explanations.
    func streamExplanation(
        _ request: ExplainSelectionRequest
    ) -> AsyncThrowingStream<String, Error>
    /// Diagnoses a red pull request by **reading** it, one tool call at a time (plan §3.F).
    ///
    /// The first method on this protocol where the model does not simply answer a prompt: it is
    /// handed three read-only tools and decides which of them to call, and the provider's job is
    /// the loop around that — offer the tools in the tier's own wire shape, run each call the
    /// model asks for through `tools`, hand back the result, repeat until the model answers or
    /// until ``IntelligenceToolLoop/maximumHops`` reads have happened.
    ///
    /// Three rules the implementations share, and none of them is negotiable per tier:
    ///
    /// - **Every call is validated before it runs.** The executor does it, so a tool cannot be
    ///   reached with a path this pull request does not contain.
    /// - **The hop cap is a hard stop**, not a hint in the prompt: a model that keeps asking gets
    ///   ``IntelligenceError/toolLoopExceeded``, because a loop that does not converge spends a
    ///   reviewer's battery or their money and produces nothing either way.
    /// - **The trace is part of the answer.** A diagnosis nobody can check is a guess with a
    ///   confidence label on it, so the hops come back with the value.
    ///
    /// It stays a **hint**: the answer is a card, and handing it on to a coding agent is a
    /// separate click by the person reading it (ADR 0007).
    /// - Parameters:
    ///   - request: Which pull request, which checks are red, which files exist, and the tier's
    ///     budget.
    ///   - tools: The reads the model may perform.
    /// - Returns: The diagnosis and every hop it took.
    /// - Throws: ``IntelligenceError/toolsUnsupported`` when the tier cannot call tools at all,
    ///   ``IntelligenceError/toolLoopExceeded`` when the model exceeded the hop cap, and the
    ///   tier's own failures otherwise.
    func diagnoseFailingChecks(
        _ request: CIDiagnosisRequest,
        tools: any IntelligenceToolExecuting
    ) async throws -> IntelligenceToolRun<CIDiagnosis>

    // MARK: - Delegation brief (plan §3.E)

    /// Drafts the task for a coding agent as a stream of **cumulative** Markdown (plan §3.E).
    ///
    /// Same streaming contract as ``streamReviewSummaryDraft(_:)`` — every element is the whole
    /// brief so far, never a delta — and the same product rule: the Markdown lands in the
    /// delegation sheet's task field, the reviewer edits it, and **Run is still their click**.
    /// There is no path from here to a started agent, and the auto-delegation rules never see a
    /// drafted brief at all (ADR 0011 amendment, ADR 0016).
    ///
    /// Markdown rather than prose because the brief has a shape an agent reads better than a
    /// paragraph: goal, constraints, acceptance — the three headings
    /// ``ShepherdCore/AgentBrief`` names.
    /// - Parameter request: The delegation's own material plus the digest, already inside the
    ///   tier's token budget.
    /// - Returns: A stream of ever-longer briefs. It throws the tier's own error when the tier
    ///   cannot answer, and cancelling the consuming task ends the request.
    func streamAgentBrief(_ request: AgentBriefRequest) -> AsyncThrowingStream<String, Error>
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

    /// Explaining, for tiers that have not implemented it.
    ///
    /// Unlike the two drafting streams above there is nothing to fall back *to*: an explanation
    /// has no awaited twin on this protocol, so a tier that has not written the method has no
    /// non-streaming path to be wrapped. Refusing is therefore what the default has to do, and
    /// the same reasoning as ``diagnoseFailingChecks(_:tools:)``'s default applies to why that is
    /// right rather than merely unavoidable: an explanation the reviewer cannot tell apart from a
    /// real one is worse than a sentence saying this tier does not do it, and the router's ladder
    /// already knows how to step down to a tier that does.
    ///
    /// Every tier Shepherd ships implements the method; this exists for the ones a test or a
    /// later plan adds.
    func streamExplanation(
        _ request: ExplainSelectionRequest
    ) -> AsyncThrowingStream<String, Error> {
        IntelligenceStreaming.failing(
            IntelligenceError.unavailable(
                String(localized: "This provider cannot explain a selection.")
            )
        )
    }

    /// Tool calling, for tiers that cannot call tools.
    ///
    /// Refusing in the default implementation rather than requiring every conformance to write
    /// the same `throw` is what keeps a tier added later — a stub in a test, a local model with no
    /// tool head — from silently answering a diagnosis *without having read anything*, which is
    /// the one failure mode this feature must not have: an unread guess reads exactly like a read
    /// one on the card. A tier that means to support tools implements the method; a tier that
    /// does not says so, and the router shows the reason.
    func diagnoseFailingChecks(
        _ request: CIDiagnosisRequest,
        tools: any IntelligenceToolExecuting
    ) async throws -> IntelligenceToolRun<CIDiagnosis> {
        throw IntelligenceError.toolsUnsupported
    }

    // MARK: - Delegation brief (plan §3.E)

    /// Drafting an agent brief, for a tier that has no brief-shaped call.
    ///
    /// It declines, for the reason ``diagnoseFailingChecks(_:tools:)``'s default declines rather
    /// than improvising: a brief is text a reviewer hands to an agent that will change their
    /// code, and a tier that answered it out of the *review-summary* prompt would produce six
    /// sentences of review prose that look exactly like a brief in the field. One stated sentence
    /// the reviewer can read beats a plausible answer to a question that was not asked. A tier
    /// that means to draft briefs implements the method; the router shows this reason for one
    /// that does not, exactly as it shows every other tier failure.
    func streamAgentBrief(_ request: AgentBriefRequest) -> AsyncThrowingStream<String, Error> {
        IntelligenceStreaming.stream { (_: AsyncThrowingStream<String, Error>.Continuation) -> Void in
            throw IntelligenceError.unavailable(
                String(localized: "This tier cannot draft a brief for a coding agent.")
            )
        }
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

    /// A stream that produces nothing and finishes with one error.
    ///
    /// Spelled out rather than written as a `singleValue` closure that only throws, because a
    /// refusal is not a value the caller nearly got: the ladder in ``IntelligenceRouter`` reads
    /// "finished before the first element" as "this tier did not answer", which is exactly what a
    /// tier that cannot serve a request wants to say.
    /// - Parameter error: Why this tier cannot answer.
    /// - Returns: A stream that immediately finishes throwing.
    static func failing(_ error: any Error) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
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
    /// The tier cannot call tools, so it cannot answer a request that is built out of reads.
    ///
    /// Its own case because it is a property of the *endpoint*, not of this request: tier 3b is
    /// "whatever speaks the chat-completions shape", and a good part of that population — Ollama
    /// with a model that has no tool head, a small self-hosted gateway — rejects a request
    /// carrying `tools` outright. Told apart from a generic ``http(status:message:)`` so the UI
    /// can say "this endpoint cannot do this" instead of showing the user a 400 they cannot act
    /// on, and never retried: the answer will not change.
    case toolsUnsupported
    /// The model asked for more reads than one diagnosis is allowed.
    ///
    /// The hop cap firing (``IntelligenceToolLoop/maximumHops``). It is a failure rather than
    /// "answer with what you have", because a model still asking for its seventh read has not
    /// converged, and a diagnosis assembled from a turn that was cut off mid-thought would carry
    /// a confidence the reviewer has no way to discount.
    case toolLoopExceeded
    /// The request was cancelled — the reviewer pressed Stop, or the task it ran in was cancelled.
    ///
    /// Its own case because the degradation ladder has to be able to tell a *cancellation* apart
    /// from a tier that failed: stepping down to the on-device tier because the cloud call was
    /// cancelled would start a second request nobody asked for, on a Mac whose owner has just
    /// said stop. It is an ``IntelligenceError`` rather than a fifth ``IntelligenceOutcome`` case
    /// so that every call site stays unchanged — "no answer, and here is the one line why" is
    /// what every AI surface in the app already knows how to show, and a cancelled request is
    /// exactly that, with the reviewer's own decision as the reason.
    ///
    /// Never mapped back onto a retry: the ladder stops, and pressing the button again is the
    /// reviewer's to press.
    case cancelled

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
        case .toolsUnsupported:
            return String(localized: "This endpoint cannot call tools, so it cannot look up why CI is red.")
        case .toolLoopExceeded:
            return String(localized: "The model asked to read more than Shepherd allows for one diagnosis.")
        case .cancelled:
            return String(localized: "Cancelled.")
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

    /// The system/instructions text for explaining a selection (plan §3.D).
    ///
    /// The one instruction in this enum that asks for *understanding* rather than for review
    /// prose, and the wording is where that difference lives. It must not drift into a review:
    /// a reviewer who asked "what do these lines do?" and got "consider adding a test" has been
    /// answered by a different feature, and the two are one keystroke apart on the same popover.
    /// Hence the explicit "this explains, it does not judge" — and hence the sentence range,
    /// because an explanation with no length bound is where a small model starts restating the
    /// diff line by line, which the reviewer can already read for themselves.
    ///
    /// The language sentence is appended per request (``ExplainSelectionRequest/instructions``),
    /// not written here, because it is the only part that changes per reviewer.
    static let explainSelectionInstructions = """
        You explain code changes to a senior engineer who is reading a pull request. Explain what \
        the marked lines change and what they touch — the callers, the data or the behaviour a \
        reader would want to know about — in three to six sentences of plain language. Use only \
        what the excerpt shows: say which context you would need instead of guessing, and never \
        invent files, APIs, behaviour or test results. No greeting, no sign-off, no line-by-line \
        restatement of the code. This explains, it does not judge: no verdict, no praise, no \
        suggestion to approve, reject or change anything.
        """

    /// The system/instructions text for "why is CI red?" (plan §3.F).
    ///
    /// Short on purpose. This is the one request where the *tools* carry the instructions — each
    /// descriptor says what it reads and what it takes — so a long prompt here would only repeat
    /// them in worse words and spend the on-device tier's shared window doing it. What is left is
    /// the four things the descriptors cannot say: that everything available is a read, what the
    /// answer's five fields are, that a field the tools did not show is left unknown rather than
    /// filled, and that the answer is a hint for a person rather than a verdict.
    static let ciDiagnosisInstructions = """
        You work out why a pull request's CI is failing, for a senior engineer looking at the \
        pull request. You can only read: the failing checks, one job log, the diff of one \
        changed file. Read what you need, then answer with the failing test, the file, the line, \
        a one-sentence hypothesis and how sure you are. Name only tests, files and lines the \
        tools showed you; leave a field empty rather than guessing at it, and say plainly when \
        the evidence is thin. This is a hint for a human, not a verdict: you never fix, comment, \
        approve, merge or re-run anything.
        """

    /// The JSON shape the cloud providers are asked for (a CI diagnosis).
    ///
    /// `null` is spelled out for the three locating fields because that is the answer a thin log
    /// deserves, and a model told only that the field is a string will invent a plausible file
    /// rather than leave it out.
    static let ciDiagnosisJSONContract = """
        When you have read enough, answer with JSON only, no prose and no code fence: \
        {"failingTest": string or null, "file": string or null, "line": integer or null, \
        "hypothesis": string, "confidence": "low" or "medium" or "high"}
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

    /// Renders an inline-comment-draft request — and, with the two labels changed, an
    /// explain-a-selection request (plan §3.D).
    ///
    /// One renderer for both surfaces because they carry the *same* excerpt, cut by the same
    /// builder against the same budget: a second copy of this function would be a second place
    /// for the anchor marker's explanation to drift away from
    /// ``InlineCommentDraftBuilder/anchorMarker``, and a marker the model does not understand is
    /// an answer about the wrong lines. Only the two nouns differ, and they matter enough to be
    /// parameters: a prompt that tells the model the lines are "being commented on" is a prompt
    /// nudging it towards writing a comment, which is the one thing an explanation must not do.
    /// Both defaults reproduce the drafting prompt byte for byte.
    /// - Parameters:
    ///   - request: The request.
    ///   - anchorLabel: How the header names the anchored lines.
    ///   - markerLabel: How the excerpt's preamble describes them.
    static func body(
        for request: InlineCommentDraftRequest,
        anchorLabel: String = "Commented line",
        markerLabel: String = "being commented on"
    ) -> String {
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
        text += "\n\(anchorLabel): \(side) side, line \(lines)"
        if request.excerpt.isEmpty {
            // Said plainly rather than left out: a model given a file name and no diff should ask
            // for the code, not improvise a review of it.
            text += "\n\nNo diff excerpt is available for this file."
            return text
        }
        text += "\n\nDiff excerpt."
            + " The line or lines \(markerLabel) are prefixed with"
            + " \"\(InlineCommentDraftBuilder.anchorMarker.trimmingCharacters(in: .whitespaces))\";"
            + " every other line is context:\n"
            + request.excerpt
        if request.excerptWasTruncated {
            text += "\n\n(Note: the excerpt is a window into a longer diff.)"
        }
        return text
    }

    /// Renders an explain-a-selection request (plan §3.D).
    ///
    /// The drafting body with two nouns swapped — see ``body(for:anchorLabel:markerLabel:)``. The
    /// language is not in here: it belongs with the instructions, where the model reads it once
    /// rather than after the excerpt it is meant to shape.
    /// - Parameter request: The request.
    static func body(for request: ExplainSelectionRequest) -> String {
        body(
            for: request.selection,
            anchorLabel: "Selected line",
            markerLabel: "the reader selected"
        )
    }

    /// Renders a CI-diagnosis request: which pull request, what is red, what may be read.
    ///
    /// The file list is the reason this prompt exists at all: `fileDiff` only accepts a path from
    /// it, so a model that has not seen the list can only guess and be refused. It is capped — a
    /// pull request with four hundred files would otherwise spend the whole window on a file tree
    /// — and says how many it left out, because a truncated list a model believes is complete is
    /// a list that makes it stop looking.
    /// - Parameter request: The request.
    static func body(for request: CIDiagnosisRequest) -> String {
        var text = """
            Repository: \(request.repoFullName)
            Pull request: #\(request.number) — \(request.pullRequestTitle)
            """
        if request.failingChecks.isEmpty {
            text += "\n\nNo check is reported as failing."
        } else {
            text += "\n\nFailing checks:"
            for check in request.failingChecks {
                text += "\n- \(check.name) [\(check.conclusion)]"
                if let summary = check.summary {
                    text += " — \(summary)"
                }
            }
        }
        if request.changedFilePaths.isEmpty {
            text += "\n\nThis pull request's changed files are not available, so no file can be read."
            return text
        }
        text += "\n\nChanged files. Only these paths can be read:"
        for path in request.changedFilePaths.prefix(CIDiagnosisRequest.maximumListedPaths) {
            text += "\n- \(path)"
        }
        let overflow = request.changedFilePaths.count - CIDiagnosisRequest.maximumListedPaths
        if overflow > 0 {
            text += "\n- (and \(overflow) more files, not listed here)"
        }
        return text
    }

    // MARK: - Delegation brief (plan §3.E)

    /// The English name of the language the reviewer reads, for a prompt to ask the answer in.
    ///
    /// `Locale.current` rather than a setting: it is the language the app's own UI is in, so it
    /// is also the language the reviewer is going to *edit* the brief in. Named in English
    /// (`en_US`) rather than in itself, because "Deutsch" is a word a model has to recognise
    /// while "German" is the word it was trained to follow. Falls back to the language code, and
    /// then to English, so this can never produce an empty instruction.
    static var answerLanguageName: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    /// The system/instructions text for a drafted agent brief (plan §3.E).
    ///
    /// The wording carries the product rule the way ``draftSummaryInstructions`` does: the model
    /// is writing a *task* for a reviewer who edits it and presses Run themselves, so it never
    /// says the work is done and never widens the scope. "Keep to what the review asks for" is
    /// the sentence that matters most — an agent handed a brief that invites refactoring produces
    /// a diff nobody wants to read, and ADR 0011's guardrails are about the *worktree*, not about
    /// the size of the change.
    ///
    /// Computed rather than stored, because one sentence of it depends on the machine: a German
    /// reviewer's brief should be German, and the language is read from ``answerLanguageName``
    /// rather than guessed from the input, which is usually an English diff either way.
    static var agentBriefInstructions: String {
        """
        You write the task brief a senior engineer hands to a coding agent that works in a \
        detached git worktree of one pull request. The engineer reads your text, edits it and \
        starts the agent themselves — you never start anything and nothing you write is sent \
        anywhere on its own. Say what has to change and why, name only files the input names, \
        and keep the scope to what the review actually asks for: no refactoring, no reformatting, \
        no rewrites the input does not ask for. Use only what the input states; write that \
        something is unclear rather than guessing at intent, and never claim anything was built, \
        run or tested. Write in \(answerLanguageName).
        """
    }

    /// The Markdown shape a streamed brief is asked for.
    ///
    /// Markdown rather than the JSON envelope the non-streamed drafts use, for the reason
    /// ``draftPlainTextContract`` exists: half of `{"goal": "Fix the retry` is not text anybody
    /// can read, and this one grows in a field the reviewer is watching. The three headings are
    /// interpolated from ``ShepherdCore/AgentBrief`` so the prompt and the renderer cannot drift
    /// onto two spellings of the same section.
    static var agentBriefMarkdownContract: String {
        """
        Answer with Markdown and nothing else — no JSON, no code fence, no preamble, no closing \
        remark — in exactly these three sections, in this order: \
        \(AgentBrief.goalHeading) with one or two sentences, \
        \(AgentBrief.constraintsHeading) with short bullets, and \
        \(AgentBrief.acceptanceHeading) with short bullets naming what the engineer should be \
        able to see when the work is done.
        """
    }

    /// Renders an agent-brief request: which delegation this is, then the digest.
    ///
    /// The delegation's own facts come first and the digest after them, the other way round from
    /// ``body(for:)`` for a summary draft. That is deliberate: the brief's subject is the *task*,
    /// and a model that reads forty files of statistics before it is told what it is being asked
    /// for writes a description of the pull request instead of a brief.
    /// - Parameter request: The request.
    static func body(for request: AgentBriefRequest) -> String {
        var text = """
            Pull request: \(request.slug) — \(request.pullRequestTitle)
            Worktree: branch \(request.headRefName), checked out at commit \(request.headRefOid)
            """
        if let path = request.findingPath {
            if let line = request.findingLine {
                text += "\nStarted from a review finding in \(path), line \(line)."
            } else {
                text += "\nStarted from a review finding in \(path)."
            }
        } else {
            text += "\nStarted from the pull request as a whole, not from one finding."
        }
        if !request.focusReasons.isEmpty {
            text += "\n\nShepherd ranked these files as the riskiest:"
            for reason in request.focusReasons {
                text += "\n- \(reason)"
            }
        }
        if request.findings.isEmpty {
            // Said plainly rather than left out: with no finding to act on, the brief is written
            // from the diff and the ranking, and a model should know that is all it has.
            text += "\n\nNo review comment is attached to this delegation."
        } else {
            text += "\n\nThe review comments this delegation is about."
                + " They are the task; quote what they ask for, do not repeat them word for word:"
            for finding in request.findings {
                if let author = finding.author {
                    text += "\n- \(author): \(finding.body)"
                } else {
                    text += "\n- \(finding.body)"
                }
            }
        }
        text += "\n\n" + body(for: request.digest)
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

    /// Parses a CI diagnosis out of a cloud tier's final answer.
    ///
    /// The tolerances live in ``ShepherdCore/CIDiagnosis``'s own decoder — an empty `file` is
    /// `nil`, a quoted line number is still a line number, an absent confidence reads as `low` —
    /// so all this adds is the two things that are about the *answer* rather than the value: the
    /// JSON has to be found inside whatever prose the model wrapped it in, and a diagnosis with
    /// no hypothesis is not a diagnosis. There is deliberately no fallback to "treat the whole
    /// answer as the hypothesis" the way ``draft(from:)`` has one: a drafted comment is text a
    /// reviewer edits, while this fills five fields on a card, and a card whose hypothesis is a
    /// paragraph of the model thinking out loud is worse than a stated failure.
    /// - Parameter text: The raw answer.
    /// - Returns: The diagnosis.
    /// - Throws: ``IntelligenceError/malformedResponse`` when nothing usable came back.
    static func diagnosis(from text: String) throws -> CIDiagnosis {
        guard let object = extractObject(from: text),
              let value = try? JSONDecoder().decode(CIDiagnosis.self, from: Data(object.utf8)),
              !value.hypothesis.isEmpty
        else { throw IntelligenceError.malformedResponse }
        return value
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
