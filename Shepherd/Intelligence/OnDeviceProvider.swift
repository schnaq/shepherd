import Foundation
import FoundationModels
import ShepherdCore

// MARK: - Guided-generation types
//
// These live at file scope (not nested) so the `@Generable` macro expands in the simplest
// possible context. Only `String` and `[String]`-shaped fields are used: the on-device model
// is good at short summarisation and tagging and explicitly not recommended for code
// reasoning (ADR 0007), so the schema asks for nothing clever.

/// The shape the on-device model fills in for a pull-request summary.
@Generable
struct OnDeviceSummary {
    /// Two or three factual sentences about the change.
    @Guide(description: "Two or three sentences describing what this pull request changes.")
    var overview: String

    /// Short risk notes; may be empty.
    var riskNotes: [String]
}

/// One focus hint produced by the on-device model.
@Generable
struct OnDeviceFocusHint {
    /// A file path copied verbatim from the prompt.
    @Guide(description: "A file path copied exactly from the list in the prompt.")
    var file: String

    /// Why that file deserves a close read.
    @Guide(description: "One short sentence on why this file deserves a close read.")
    var reason: String
}

/// The shape the on-device model fills in for review focus.
@Generable
struct OnDeviceFocus {
    /// At most a handful of hints.
    var hints: [OnDeviceFocusHint]
}

/// The shape the on-device model fills in for every prose request: a drafted review summary, a
/// drafted inline comment, or an explanation of a selection.
///
/// One `String` field, which is all guided generation is needed for here: the value of the schema
/// is that the answer arrives without a preamble the reviewer would have to delete. It is also
/// what makes streaming usable — a partially generated snapshot of this type is a partial answer
/// and nothing else, whereas a partially generated *prose* answer can still be halfway through a
/// preamble the reviewer never wanted to watch being typed.
///
/// The guide is deliberately about the answer's *shape* rather than about which of the three
/// requests is being answered: the instructions say what to write, and a schema that called this
/// "the review text" would be quietly asking an explanation to be a review.
@Generable
struct OnDeviceReviewDraft {
    /// The generated text, ready to be read or edited by the reviewer.
    @Guide(description: "The requested text itself, with no preamble and no sign-off.")
    var draft: String
}

// MARK: - Which model, with which knobs

/// Which of Apple's system models a request wants (plan §0.1).
///
/// Two, because Apple ships two that matter to Shepherd: the general model writes prose, and the
/// content-tagging model is trained for exactly the "put this in one of these buckets" work that
/// structured triage will need. Both are the same size and the same privacy story; the difference
/// is what they were tuned for, and picking the wrong one costs quality rather than correctness.
///
/// The enum exists *before* the first classification feature on purpose: it is the seam that
/// keeps "which model" out of the four call sites below, so adding a classifier later is a case
/// here plus a call, not a change to how every request is built. Availability is asked of the
/// chosen model rather than of `SystemLanguageModel.default`, because the assets are downloaded
/// per model — the tagging model can be ready while the general one is not, and vice versa.
enum OnDeviceUseCase: Sendable, Hashable {
    /// Prose: summaries, focus hints, drafted review text.
    case prose
    /// Classification and tagging.
    case tagging

    /// The model this use case runs on.
    func model() -> SystemLanguageModel {
        switch self {
        case .prose:
            return SystemLanguageModel.default
        case .tagging:
            return SystemLanguageModel(useCase: .contentTagging)
        }
    }
}

/// Every generation number Shepherd sends to the on-device model, in one place (plan §0.1).
///
/// One enum rather than literals at the call sites, because these numbers are a policy and not a
/// detail: they decide how much of the shared 8K window a runaway answer may eat, and they are
/// the first thing to change when a request type starts producing answers that are too long or
/// too creative. Each one says why it is what it is.
enum OnDeviceGeneration {
    /// Temperature for the two *structured* requests (summary, focus hints).
    ///
    /// Low, not zero: those answers are read as facts about a diff, and a warmer model starts
    /// inventing the risk note it thinks the reviewer wants. Zero is avoided because the
    /// framework's guided decoding still has to pick between equally valid phrasings, and a
    /// fully greedy sampler makes short lists collapse into repetition.
    static let structuredTemperature = 0.2

    /// How many tokens a summary answer may use — two or three sentences plus three short risk
    /// notes, with room to finish the last one.
    static let summaryResponseTokens = 400

    /// How many tokens a focus-hint answer may use — at most four files with one line each.
    static let focusResponseTokens = 320

    /// How many tokens a drafted review may use.
    ///
    /// The prompt asks for at most six sentences; this is roughly twice that, so a model that
    /// runs long is cut off in a place the reviewer can still edit rather than mid-word.
    static let draftResponseTokens = 600

    /// What every budget calculation leaves for the answer.
    ///
    /// The prompt and the response share one context window, so the largest cap above has to be
    /// subtracted from the window before the prompt is measured against it — plus a margin for
    /// the instructions and the schema the framework injects, which are part of the same window
    /// and are not part of anything Shepherd measures.
    static let reservedResponseTokens = 1_000

    /// Options for a summary request.
    /// - Parameter caps: The backend's answer lengths.
    static func summary(_ caps: ResponseCaps) -> GenerationOptions {
        GenerationOptions(temperature: structuredTemperature, maximumResponseTokens: caps.summary)
    }

    /// Options for a focus-hint request.
    /// - Parameter caps: The backend's answer lengths.
    static func focus(_ caps: ResponseCaps) -> GenerationOptions {
        GenerationOptions(temperature: structuredTemperature, maximumResponseTokens: caps.focus)
    }

    /// How many tokens a CI diagnosis may use.
    ///
    /// Small, because the answer is five short fields and the tool results have to share the
    /// same window with them: a diagnosis that ran away would be a hypothesis paragraph in a
    /// field the card draws as one line.
    static let diagnosisResponseTokens = 320

    /// Options for a drafting request.
    ///
    /// No temperature: a draft is prose a person will rewrite, and the framework's default is
    /// tuned for exactly that. Naming a lower one here would make every draft read like the
    /// same three sentences about "consider adding a test".
    /// - Parameter caps: The backend's answer lengths.
    static func draft(_ caps: ResponseCaps) -> GenerationOptions {
        GenerationOptions(maximumResponseTokens: caps.draft)
    }

    /// Options for a CI diagnosis.
    ///
    /// The structured temperature, for the reason it exists: this answer is read as a fact about
    /// a log, and a warmer model invents the failing test it expects to find rather than the one
    /// the tools showed it. (Claude models from Sonnet 5 and Opus 4.7 on take no sampling
    /// parameters at all; the bridge drops the temperature for them rather than failing, so those
    /// answers run at the API's default.)
    /// - Parameter caps: The backend's answer lengths.
    static func diagnosis(_ caps: ResponseCaps) -> GenerationOptions {
        GenerationOptions(temperature: structuredTemperature, maximumResponseTokens: caps.diagnosis)
    }
}

// MARK: - The provider

/// A provider that drives one `LanguageModelSession` per request, on whichever model its
/// ``LanguageModelBackend`` hands it (ADR 0007, ADR 0031 §One).
///
/// One struct for tier 2 and for Claude, because the protocol whose whole purpose is a swappable
/// backend is worth adopting exactly to the extent that nothing above it has to know which backend
/// answered: the guided-generation shapes, the read-only tools, the streamed cumulative drafts and
/// the pre-flight are written once here. ``OnDeviceProvider`` and ``ClaudeProvider`` are this type
/// with a backend chosen.
///
/// **`FoundationModels` is imported only by the `OnDevice*.swift` files in this folder,
/// `LanguageModelBackend.swift` and `ClaudeProvider.swift`.** Everything the rest of the app sees
/// is ``IntelligenceProvider``, so a change in that framework can only break those files.
///
/// The model is guarded twice: the backend must report it available, and the prompt must fit the
/// token budget — ADR 0007 makes the context ceiling a hard error rather than a silent truncation.
struct SessionProvider<Backend: LanguageModelBackend>: IntelligenceProvider {
    /// What the sessions are built on.
    let backend: Backend

    /// The token budget digests are built with for this tier — the backend's, spelled where the
    /// router and the digest builders have always read it.
    static var budget: TokenBudget { Backend.budget }

    var kind: IntelligenceKind { backend.kind }

    var isAvailable: Bool {
        get async { backend.unavailabilityReason(of: backend.model(for: .prose)) == nil }
    }

    /// Creates a provider on a backend.
    /// - Parameter backend: What the sessions are built on.
    init(backend: Backend) {
        self.backend = backend
    }

    /// Why one use case's model cannot be used, or `nil` when it can.
    /// - Parameter useCase: Which model to ask about.
    func unavailabilityReason(for useCase: OnDeviceUseCase) -> String? {
        backend.unavailabilityReason(of: backend.model(for: useCase))
    }

    // MARK: - Requests

    func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary {
        let prompt = IntelligencePrompt.body(for: digest)
        let session = try await preflight(
            useCase: .prose,
            instructions: IntelligencePrompt.summaryInstructions,
            prompt: prompt,
        )
        let generated: OnDeviceSummary
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceSummary.self,
                options: OnDeviceGeneration.summary(Backend.caps)
            ).content
        } catch {
            throw mapped(error)
        }
        return PRSummary(
            overview: generated.overview.trimmingCharacters(in: .whitespacesAndNewlines),
            riskNotes: generated.riskNotes
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint] {
        let prompt = IntelligencePrompt.body(for: digest)
        let knownPaths = Set(digest.files.map(\.path))
        let session = try await preflight(
            useCase: .prose,
            instructions: IntelligencePrompt.focusInstructions,
            prompt: prompt,
        )
        let generated: OnDeviceFocus
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceFocus.self,
                options: OnDeviceGeneration.focus(Backend.caps)
            ).content
        } catch {
            throw mapped(error)
        }
        return generated.hints
            .compactMap { hint -> FocusHint? in
                let file = hint.file.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = hint.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                // Drop hallucinated paths: a hint about a file that is not in the pull request
                // is worse than no hint at all.
                guard knownPaths.contains(file), !reason.isEmpty else { return nil }
                return FocusHint(file: file, reason: reason)
            }
    }

    func draftReviewSummary(_ request: ReviewSummaryDraftRequest) async throws -> String {
        try await draft(
            instructions: IntelligencePrompt.draftSummaryInstructions,
            prompt: IntelligencePrompt.body(for: request),
        )
    }

    func draftInlineComment(_ request: InlineCommentDraftRequest) async throws -> String {
        try await draft(
            instructions: IntelligencePrompt.draftInlineCommentInstructions,
            prompt: IntelligencePrompt.body(for: request),
        )
    }

    func streamReviewSummaryDraft(
        _ request: ReviewSummaryDraftRequest
    ) -> AsyncThrowingStream<String, Error> {
        streamedDraft(
            instructions: IntelligencePrompt.draftSummaryInstructions,
            prompt: IntelligencePrompt.body(for: request),
        )
    }

    func streamInlineCommentDraft(
        _ request: InlineCommentDraftRequest
    ) -> AsyncThrowingStream<String, Error> {
        streamedDraft(
            instructions: IntelligencePrompt.draftInlineCommentInstructions,
            prompt: IntelligencePrompt.body(for: request),
        )
    }

    /// Explains a selection (plan §3.D).
    ///
    /// The `.prose` model and ``OnDeviceGeneration/draft`` — the same knobs a drafted comment
    /// uses, because it is the same kind of work: a few sentences of prose from a windowed diff
    /// excerpt, with the framework's default temperature because naming a colder one makes every
    /// answer read like the same paragraph. Guided generation is what keeps the streamed
    /// snapshots readable (see ``streamedDraft(instructions:prompt:)``): the reviewer
    /// watches sentences arrive, never half a JSON object.
    func streamExplanation(
        _ request: ExplainSelectionRequest
    ) -> AsyncThrowingStream<String, Error> {
        streamedDraft(
            instructions: request.instructions,
            prompt: IntelligencePrompt.body(for: request),
        )
    }

    /// The brief for a coding agent, streamed as Markdown through the same plain-text path as
    /// the drafts: the instructions ask for the three sections, the contract keeps the answer
    /// to Markdown, and the request has already reserved room for the finding comments.
    func streamAgentBrief(_ request: AgentBriefRequest) -> AsyncThrowingStream<String, Error> {
        streamedDraft(
            instructions: IntelligencePrompt.agentBriefInstructions
                + "\n" + IntelligencePrompt.agentBriefMarkdownContract,
            prompt: IntelligencePrompt.body(for: request),
        )
    }

    /// Diagnoses a red pull request by letting the model call the read-only tools (plan §3.F).
    ///
    /// The one request where Shepherd does not drive the turn: the session is created *with* the
    /// tools, and the framework decides which of them to call and when. So there is no loop here
    /// — the loop is inside `respond(to:generating:)` — and the two things Shepherd still owns
    /// are pushed to the edges: the hop cap lives in the tool wrappers, which are the only code
    /// that runs per call, and the trace is collected by the ``ToolTraceRecorder`` they share and
    /// read back once the answer exists.
    ///
    /// The pre-flight measures the opening prompt only, which is the honest thing it can do: the
    /// tool results are not written yet, and the framework's own accounting of the transcript is
    /// what will notice if they do not fit — arriving here as
    /// ``IntelligenceError/contextExceeded``, which is exactly the failure the router is allowed
    /// to offer the next tier for.
    func diagnoseFailingChecks(
        _ request: CIDiagnosisRequest,
        tools: any IntelligenceToolExecuting
    ) async throws -> IntelligenceToolRun<CIDiagnosis> {
        let prompt = IntelligencePrompt.body(for: request)
        let recorder = ToolTraceRecorder()
        let session = try await preflight(
            useCase: .prose,
            instructions: IntelligencePrompt.ciDiagnosisInstructions,
            prompt: prompt,
            tools: OnDeviceToolBridge.tools(executor: tools, recorder: recorder)
        )
        let generated: OnDeviceCIDiagnosis
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceCIDiagnosis.self,
                options: OnDeviceGeneration.diagnosis(Backend.caps)
            ).content
        } catch {
            throw mapped(error)
        }
        let diagnosis = CIDiagnosis(generated)
        guard !diagnosis.hypothesis.isEmpty else { throw IntelligenceError.malformedResponse }
        return IntelligenceToolRun(value: diagnosis, trace: await recorder.current)
    }

    /// One plain-text turn, for the connection test in Settings: no schema, no tools, the
    /// answer as the model wrote it.
    /// - Parameters:
    ///   - system: The session's instructions.
    ///   - user: The prompt.
    /// - Returns: The model's answer, trimmed.
    func complete(system: String, user: String) async throws -> String {
        let session = try await preflight(useCase: .prose, instructions: system, prompt: user)
        do {
            return try await session.respond(to: user).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw mapped(error)
        }
    }

    /// One drafting request, awaited to the end.
    private func draft(instructions: String, prompt: String) async throws -> String {
        let session = try await preflight(
            useCase: .prose,
            instructions: instructions,
            prompt: prompt,
        )
        let generated: OnDeviceReviewDraft
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceReviewDraft.self,
                options: OnDeviceGeneration.draft(Backend.caps)
            ).content
        } catch {
            throw mapped(error)
        }
        return try SessionProvider.usableDraft(in: generated.draft)
    }

    /// One drafting request, as a stream of cumulative drafts (plan §0.2).
    ///
    /// Guided generation is what makes this honest: the framework yields *partially generated*
    /// snapshots of ``OnDeviceReviewDraft``, each one holding the draft as far as it has been
    /// decoded, so there is nothing to accumulate and no way for the field to show half a JSON
    /// object. Snapshots that repeat the previous text are dropped rather than forwarded, because
    /// every element the UI sees is a write into a text field the reviewer may be looking at.
    private func streamedDraft(
        instructions: String,
        prompt: String
    ) -> AsyncThrowingStream<String, Error> {
        IntelligenceStreaming.stream { continuation in
            let session = try await preflight(
                useCase: .prose,
                instructions: instructions,
                prompt: prompt,
            )
            var latest = ""
            do {
                let responses = session.streamResponse(
                    to: prompt,
                    generating: OnDeviceReviewDraft.self,
                    options: OnDeviceGeneration.draft(Backend.caps)
                )
                for try await partial in responses {
                    let text = SessionProvider.draftText(in: partial.content)
                    guard !text.isEmpty, text != latest else { continue }
                    latest = text
                    continuation.yield(text)
                }
            } catch {
                throw mapped(error)
            }
            // The trim happens once, at the end: trimming every snapshot would make the field
            // jitter as trailing whitespace arrives and is taken away again.
            let finished = try SessionProvider.usableDraft(in: latest)
            if finished != latest { continuation.yield(finished) }
        }
    }

    // MARK: - The framework's spelling, in as few lines as possible

    /// The draft inside one partially generated snapshot.
    ///
    /// A `PartiallyGenerated` snapshot has every field optional, and `nil` here means "the model
    /// has not started that field yet", not "the field is empty".
    private static func draftText(in partial: OnDeviceReviewDraft.PartiallyGenerated) -> String {
        partial.draft ?? ""
    }

    /// The framework's failures and the backend's own, in Shepherd's words.
    private func mapped(_ error: any Error) -> any Error {
        backend.mapped(error)
    }

    // MARK: - Pre-flight

    /// Availability, budget and session — everything that must be true before a prompt is sent.
    ///
    /// One function because the three are one decision: ADR 0007 makes the context ceiling a hard
    /// error rather than a silent truncation, so nothing may create a session it is not already
    /// sure it can use.
    /// - Parameters:
    ///   - useCase: Which model the request wants.
    ///   - instructions: The session's instructions. Part of the same context window as the
    ///     prompt, which is why they are measured together.
    ///   - prompt: The prompt.
    ///   - tools: The tools the session may call. Empty for every request that only answers a
    ///     prompt, and the empty case keeps the exact initialiser those requests have always
    ///     used.
    /// - Returns: A session on the chosen model.
    /// - Throws: ``IntelligenceError/unavailable(_:)`` or ``IntelligenceError/digestTooLarge(tokens:limit:)``.
    private func preflight(
        useCase: OnDeviceUseCase,
        instructions: String,
        prompt: String,
        tools: [any Tool] = []
    ) async throws -> LanguageModelSession {
        let model = backend.model(for: useCase)
        if let reason = backend.unavailabilityReason(of: model) {
            throw IntelligenceError.unavailable(reason)
        }

        // The instructions share the window with the prompt, so they are measured with it. Both
        // halves of the comparison come from the same backend, or this would be a real token
        // count against a limit that was only ever a guess about the window.
        let text = instructions + "\n" + prompt
        let context = await backend.context(of: model, measuring: text)
        let budget = Backend.budget.limited(
            toContextSize: context.contextSize,
            reservedForResponse: Backend.caps.reserved
        )
        let tokens = budget.measured(text, using: context.measure)
        guard tokens <= budget.maxTokens else {
            throw IntelligenceError.digestTooLarge(tokens: tokens, limit: budget.maxTokens)
        }

        guard !tools.isEmpty else {
            return LanguageModelSession(model: model, instructions: instructions)
        }
        return LanguageModelSession(model: model, tools: tools, instructions: instructions)
    }

    /// Trims a generated draft and refuses an empty one.
    ///
    /// An empty field with a spinner that stopped looks like a bug; a red line saying the model
    /// returned nothing is at least true.
    static func usableDraft(in text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntelligenceError.malformedResponse }
        return trimmed
    }
}

// MARK: - Tier 2: Apple's system model

/// Apple's on-device Foundation Model as a ``LanguageModelBackend`` (ADR 0007's tier 2).
///
/// The model is asked per use case — prose or tagging — because the assets are downloaded per
/// model: the tagging model can be ready while the general one is not, and vice versa. The prompt
/// is measured against the real tokenizer; the floor is macOS 27, so the OS can always measure
/// (ADR 0038).
struct OnDeviceBackend: LanguageModelBackend {
    var kind: IntelligenceKind { .onDevice }
    static let budget = TokenBudget.onDevice
    static let caps = ResponseCaps.onDevice

    func model(for useCase: OnDeviceUseCase) -> SystemLanguageModel {
        useCase.model()
    }

    /// Why one use case's model cannot be used, or `nil` when it can — the static spelling the
    /// three on-device classifiers and Settings ask, since the answer needs no instance.
    /// - Parameter useCase: Which model to ask about.
    static func unavailabilityReason(for useCase: OnDeviceUseCase) -> String? {
        OnDeviceBackend().unavailabilityReason(of: useCase.model())
    }

    /// Why a model cannot be used, or `nil` when it can.
    ///
    /// Surfaced verbatim in Settings so a user who turned Apple Intelligence off knows why the
    /// summary card is missing. The case patterns are exactly the ones Apple documents for this
    /// enum; naming the nested `UnavailableReason` type is avoided on purpose so this file
    /// depends on as little of the framework's spelling as possible.
    func unavailabilityReason(of model: SystemLanguageModel) -> String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return String(localized: "This Mac does not support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Apple Intelligence is turned off in System Settings.")
        case .unavailable(.modelNotReady):
            return String(localized: "The on-device model is still downloading. Try again later.")
        case .unavailable:
            return String(localized: "The on-device model is unavailable right now.")
        }
    }

    /// **This function is the whole surface of the measurement API.** `contextSize` and
    /// `tokenCount(for:)` are the two members of `SystemLanguageModel` the budget rests on;
    /// isolating them means a rename costs these two lines and nothing else.
    func context(
        of model: SystemLanguageModel,
        measuring text: String
    ) async -> (measure: (String) -> Int?, contextSize: Int) {
        // The count is taken once, here, because the framework tokenises asynchronously and
        // ``ShepherdCore/TokenBudget/measured(_:using:)`` wants a synchronous closure; the
        // closure then answers for that one string and declines for any other.
        let count = try? await model.tokenCount(for: text)
        return ({ candidate in candidate == text ? count : nil }, model.contextSize)
    }
}

/// Tier 2, as the rest of the app has always named it.
typealias OnDeviceProvider = SessionProvider<OnDeviceBackend>

extension SessionProvider where Backend == OnDeviceBackend {
    /// Creates the on-device provider.
    init() {
        self.init(backend: OnDeviceBackend())
    }

    /// Why the on-device model cannot be used, or `nil` when it can.
    static func unavailabilityReason() -> String? {
        OnDeviceBackend.unavailabilityReason(for: .prose)
    }

    /// Why one use case's model cannot be used, or `nil` when it can.
    /// - Parameter useCase: Which model to ask about.
    static func unavailabilityReason(for useCase: OnDeviceUseCase) -> String? {
        OnDeviceBackend.unavailabilityReason(for: useCase)
    }
}
