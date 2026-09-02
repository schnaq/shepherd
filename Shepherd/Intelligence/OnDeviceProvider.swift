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

/// The shape the on-device model fills in for a drafted review summary or inline comment.
///
/// One `String` field, which is all guided generation is needed for here: the value of the schema
/// is that the answer arrives without a preamble the reviewer would have to delete. It is also
/// what makes streaming usable — a partially generated snapshot of this type is a partial draft
/// and nothing else, whereas a partially generated *prose* answer can still be halfway through a
/// preamble the reviewer never wanted to watch being typed.
@Generable
struct OnDeviceReviewDraft {
    /// The drafted text, ready to be edited by the reviewer.
    @Guide(description: "The review text itself, with no preamble and no sign-off.")
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
    static var summary: GenerationOptions {
        GenerationOptions(
            temperature: structuredTemperature,
            maximumResponseTokens: summaryResponseTokens
        )
    }

    /// Options for a focus-hint request.
    static var focus: GenerationOptions {
        GenerationOptions(
            temperature: structuredTemperature,
            maximumResponseTokens: focusResponseTokens
        )
    }

    /// Options for a drafting request.
    ///
    /// No temperature: a draft is prose a person will rewrite, and the framework's default is
    /// tuned for exactly that. Naming a lower one here would make every draft read like the
    /// same three sentences about "consider adding a test".
    static var draft: GenerationOptions {
        GenerationOptions(maximumResponseTokens: draftResponseTokens)
    }
}

// MARK: - The provider

/// Tier 2: Apple's on-device Foundation Model (ADR 0007).
///
/// **This is the only file in the app that imports `FoundationModels`.** Everything the rest
/// of the app sees is ``IntelligenceProvider``, so a change in that framework can only break
/// this file.
///
/// The model is guarded twice: the chosen model's `availability` must report `.available` (Apple
/// Intelligence can be off, the device can be ineligible, the assets can still be downloading),
/// and the prompt must fit the token budget — ADR 0007 makes the context ceiling a hard error
/// rather than a silent truncation. The budget is measured against the real tokenizer where the
/// OS can do that and estimated at four characters per token where it cannot (plan §0.1).
struct OnDeviceProvider: IntelligenceProvider {
    /// The token budget digests are built with for this tier.
    ///
    /// Still the conservative estimate-based number, because a digest is built *before* a model
    /// exists to ask: measuring happens in ``preflight(useCase:instructions:prompt:estimate:)``,
    /// where it can only ever let more through than this.
    static let budget = TokenBudget.onDevice

    var kind: IntelligenceKind { .onDevice }

    var isAvailable: Bool {
        get async { OnDeviceProvider.unavailabilityReason() == nil }
    }

    /// Creates a provider.
    init() {}

    /// Why the on-device model cannot be used, or `nil` when it can.
    ///
    /// Surfaced verbatim in Settings so a user who turned Apple Intelligence off knows why the
    /// summary card is missing.
    static func unavailabilityReason() -> String? {
        unavailabilityReason(for: .prose)
    }

    /// Why one use case's model cannot be used, or `nil` when it can.
    /// - Parameter useCase: Which model to ask about.
    static func unavailabilityReason(for useCase: OnDeviceUseCase) -> String? {
        unavailabilityReason(of: useCase.model())
    }

    // MARK: - Requests

    func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary {
        let prompt = IntelligencePrompt.body(for: digest)
        let session = try OnDeviceProvider.preflight(
            useCase: .prose,
            instructions: IntelligencePrompt.summaryInstructions,
            prompt: prompt,
            estimate: digest.approximateTokenCount
        )
        let generated: OnDeviceSummary
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceSummary.self,
                options: OnDeviceGeneration.summary
            ).content
        } catch {
            throw OnDeviceProvider.mapped(error)
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
        let session = try OnDeviceProvider.preflight(
            useCase: .prose,
            instructions: IntelligencePrompt.focusInstructions,
            prompt: prompt,
            estimate: digest.approximateTokenCount
        )
        let generated: OnDeviceFocus
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceFocus.self,
                options: OnDeviceGeneration.focus
            ).content
        } catch {
            throw OnDeviceProvider.mapped(error)
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
            estimate: request.approximateTokenCount
        )
    }

    func draftInlineComment(_ request: InlineCommentDraftRequest) async throws -> String {
        try await draft(
            instructions: IntelligencePrompt.draftInlineCommentInstructions,
            prompt: IntelligencePrompt.body(for: request),
            estimate: request.approximateTokenCount
        )
    }

    func streamReviewSummaryDraft(
        _ request: ReviewSummaryDraftRequest
    ) -> AsyncThrowingStream<String, Error> {
        streamedDraft(
            instructions: IntelligencePrompt.draftSummaryInstructions,
            prompt: IntelligencePrompt.body(for: request),
            estimate: request.approximateTokenCount
        )
    }

    func streamInlineCommentDraft(
        _ request: InlineCommentDraftRequest
    ) -> AsyncThrowingStream<String, Error> {
        streamedDraft(
            instructions: IntelligencePrompt.draftInlineCommentInstructions,
            prompt: IntelligencePrompt.body(for: request),
            estimate: request.approximateTokenCount
        )
    }

    /// One drafting request, awaited to the end.
    private func draft(instructions: String, prompt: String, estimate: Int) async throws -> String {
        let session = try OnDeviceProvider.preflight(
            useCase: .prose,
            instructions: instructions,
            prompt: prompt,
            estimate: estimate
        )
        let generated: OnDeviceReviewDraft
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceReviewDraft.self,
                options: OnDeviceGeneration.draft
            ).content
        } catch {
            throw OnDeviceProvider.mapped(error)
        }
        return try OnDeviceProvider.usableDraft(in: generated.draft)
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
        prompt: String,
        estimate: Int
    ) -> AsyncThrowingStream<String, Error> {
        IntelligenceStreaming.stream { continuation in
            let session = try OnDeviceProvider.preflight(
                useCase: .prose,
                instructions: instructions,
                prompt: prompt,
                estimate: estimate
            )
            var latest = ""
            do {
                let responses = session.streamResponse(
                    to: prompt,
                    generating: OnDeviceReviewDraft.self,
                    options: OnDeviceGeneration.draft
                )
                for try await partial in responses {
                    let text = OnDeviceProvider.draftText(in: partial)
                    guard !text.isEmpty, text != latest else { continue }
                    latest = text
                    continuation.yield(text)
                }
            } catch {
                throw OnDeviceProvider.mapped(error)
            }
            // The trim happens once, at the end: trimming every snapshot would make the field
            // jitter as trailing whitespace arrives and is taken away again.
            let finished = try OnDeviceProvider.usableDraft(in: latest)
            if finished != latest { continuation.yield(finished) }
        }
    }

    // MARK: - The framework's spelling, in as few lines as possible

    /// How to measure a prompt against a model, and how much room that model has (macOS 26.4+).
    ///
    /// **This function is the whole surface of the 26.4-only measurement API.** `contextSize` and
    /// `tokenCount(for:)` arrived after the SDK this code was written against, so their exact
    /// spelling cannot be verified here; isolating them means a rename or a signature change
    /// costs these two lines and nothing else — everything above and below deals in a closure
    /// that may decline and an `Int`.
    ///
    /// The measurement is handed back as a closure rather than a number so
    /// ``ShepherdCore/TokenBudget/measured(_:using:)`` — pure, and tested on Linux — stays the
    /// thing that decides what a token count *is*; a closure that returns `nil` (the OS could not
    /// tokenize this particular string) falls back to the estimate there. It is deliberately not
    /// `@Sendable`: it captures the model, it is consumed immediately, and requiring the model to
    /// be `Sendable` would be a claim about the framework this file cannot make.
    /// - Parameter model: The model that will read the prompt.
    /// - Returns: The measurement closure and the model's context window in tokens.
    @available(macOS 26.4, *)
    private static func measuredContext(
        of model: SystemLanguageModel
    ) -> (measure: (String) -> Int?, contextSize: Int) {
        ({ text in try? model.tokenCount(for: text) }, model.contextSize)
    }

    /// The draft inside one partially generated snapshot.
    ///
    /// The second and last place that names a shape only the framework defines: a
    /// `PartiallyGenerated` snapshot has every field optional, and `nil` here means "the model
    /// has not started that field yet", not "the field is empty".
    private static func draftText(in partial: OnDeviceReviewDraft.PartiallyGenerated) -> String {
        partial.draft ?? ""
    }

    /// Why a model cannot be used, or `nil` when it can.
    private static func unavailabilityReason(of model: SystemLanguageModel) -> String? {
        // The case patterns below are exactly the ones Apple documents for this enum; naming
        // the nested `UnavailableReason` type is avoided on purpose so this file depends on as
        // little of the framework's spelling as possible.
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

    /// Turns the framework's generation failures into ``IntelligenceError`` where Shepherd has
    /// something better to say, and passes everything else through untouched.
    ///
    /// Two of them are worth naming (plan §0.1). A guardrail violation is not a malfunction:
    /// review prose is full of deleting, breaking and killing things, the guardrails over-fire on
    /// technical content, and the honest answer is one sentence saying the model declined —
    /// **never** an automatic retry, which would trip the same guardrail on the same words and
    /// spend battery to do it. An exceeded context window is the real tokenizer disagreeing with
    /// the pre-flight estimate, which is worth its own sentence because the fix ("smaller
    /// selection, or the cloud tier") is different from every other failure's.
    private static func mapped(_ error: any Error) -> any Error {
        guard let generation = error as? LanguageModelSession.GenerationError else { return error }
        switch generation {
        case .guardrailViolation:
            return IntelligenceError.guardrailDeclined
        case .exceededContextWindowSize:
            return IntelligenceError.contextExceeded
        default:
            return error
        }
    }

    // MARK: - Pre-flight

    /// Availability, budget and session — everything that must be true before a prompt is sent.
    ///
    /// One function because the three are one decision: ADR 0007 makes tier 2's context ceiling a
    /// hard error rather than a silent truncation, so nothing may create a session it is not
    /// already sure it can use.
    /// - Parameters:
    ///   - useCase: Which model the request wants.
    ///   - instructions: The session's instructions. Part of the same context window as the
    ///     prompt, which is why they are measured together.
    ///   - prompt: The prompt.
    ///   - estimate: The request's own chars-÷-4 estimate, used when the OS cannot measure.
    /// - Returns: A session on the chosen model.
    /// - Throws: ``IntelligenceError/unavailable(_:)`` or ``IntelligenceError/digestTooLarge(tokens:limit:)``.
    private static func preflight(
        useCase: OnDeviceUseCase,
        instructions: String,
        prompt: String,
        estimate: Int
    ) throws -> LanguageModelSession {
        let model = useCase.model()
        if let reason = unavailabilityReason(of: model) {
            throw IntelligenceError.unavailable(reason)
        }

        // The instructions share the window with the prompt, so they are measured with it.
        let text = instructions + "\n" + prompt
        var budget = OnDeviceProvider.budget
        var tokens = estimate
        if #available(macOS 26.4, *) {
            // Both halves of the comparison come from the same measurement, or this would be a
            // real token count against a limit that was only ever a guess about the window.
            let context = measuredContext(of: model)
            budget = budget.limited(
                toContextSize: context.contextSize,
                reservedForResponse: OnDeviceGeneration.reservedResponseTokens
            )
            tokens = budget.measured(text, using: context.measure)
        }
        guard tokens <= budget.maxTokens else {
            throw IntelligenceError.digestTooLarge(tokens: tokens, limit: budget.maxTokens)
        }

        return LanguageModelSession(model: model, instructions: instructions)
    }

    /// Trims a generated draft and refuses an empty one.
    ///
    /// An empty field with a spinner that stopped looks like a bug; a red line saying the model
    /// returned nothing is at least true.
    private static func usableDraft(in text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntelligenceError.malformedResponse }
        return trimmed
    }
}
