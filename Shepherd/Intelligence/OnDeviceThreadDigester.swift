import Foundation
import FoundationModels
import ShepherdCore

// MARK: - Guided-generation types
//
// At file scope, not nested, so the `@Generable` macro expands in the simplest possible context —
// the arrangement every other `OnDevice*.swift` file uses. The state is a `@Generable` *enum* for
// ``OnDeviceTriageClassifier``'s reason: the answer is a choice from a closed vocabulary, and
// letting the framework's guided decoding enforce that is what makes "the model invented a state"
// impossible rather than merely unlikely.

/// Where the model may say a thread stands — the mirror of ``ShepherdCore/ThreadDigest/State``.
///
/// Spelled out here as well as in the twin, and that duplication is the point of ADR 0007's rule:
/// this enum is Apple-only and lives in the app target, the twin is pure and lives in
/// `ShepherdCore` where the card's states can be tested on Linux. The mapping between them is one
/// switch at the bottom of this file, which is the only place the two spellings meet.
@Generable
enum OnDeviceThreadState {
    /// The participants agreed on what happens next.
    case agreed
    /// The discussion is still going.
    case open
    /// Somebody is waiting on somebody else.
    case blocked
}

/// The shape the on-device model fills in for one review thread (plan §3.G).
///
/// Three fields, which are the three lines the feature promises: where the thread stands, one
/// paragraph of what was agreed and who is waiting on whom, and the questions nobody has
/// answered. The summary is guided to *one paragraph* because it is rendered in a card above a
/// thread inside a 380-point popover: an essay there would be an essay nobody reads, and a
/// clipped essay would be worse than a paragraph that fits.
@Generable
struct OnDeviceThreadDigest {
    /// Where the thread stands.
    @Guide(description: "Where this thread stands right now.")
    var state: OnDeviceThreadState

    /// What was agreed, what is still open, who is waiting on whom.
    @Guide(
        description: "One short paragraph, at most three sentences: what the thread agreed on, what is still open, and who is waiting on whom. No preamble and no advice."
    )
    var summary: String

    /// The questions nobody has answered yet, one per entry.
    ///
    /// No `@Guide`: the array fields of the other on-device schemas carry none either, and the
    /// instructions already say what one entry is. An empty list is the right answer for a thread
    /// that is settled, and a guide that pushed for entries would invent one.
    var openQuestions: [String]
}

// MARK: - The digester

/// Tier 2 for thread digests: the on-device model summarises a long review thread when a reviewer
/// asks it to (plan §3.G, ADR 0007 amendment).
///
/// The fourth file in the app that imports `FoundationModels`, and it imports nothing else of
/// Apple's. Like ``OnDeviceTriageClassifier`` it is deliberately **not** a method on
/// ``IntelligenceProvider``: that protocol is the tier ladder, and a ladder is exactly what this
/// must not have. The input is colleagues' comments, which never travel to a BYOK endpoint
/// (``ThreadDigesting`` argues it; ADR 0007's amendment decides it), so there is one tier here
/// and when it cannot answer there is no button.
///
/// Everything else is the provider's discipline, re-applied rather than reinvented:
///
/// - **The prose model.** `OnDeviceUseCase.prose` is `SystemLanguageModel.default`, which is what
///   Apple tunes for short summarisation — the one thing ADR 0007's research says the on-device
///   model is actually good at. Availability is asked of that model specifically, because the
///   assets download per model (plan §0.1).
/// - **Measured pre-flight, and the ceiling is a hard error.** The prompt is measured against the
///   real tokenizer where the OS can do that and estimated at four characters per token where it
///   cannot; over budget throws ``IntelligenceError/digestTooLarge(tokens:limit:)`` rather than
///   silently truncating a conversation into a wrong summary. The *thread* is trimmed one layer
///   up, by ``ShepherdCore/ThreadDigestRequest``, which also records what it gave up so the card
///   can say so.
/// - **Low temperature.** A digest is read as a report on what people wrote, and a warmer model
///   starts writing the agreement it thinks the reviewer is hoping for.
/// - **A guardrail refusal is one line, never a retry.** Review threads are full of deleting,
///   breaking and killing things; a retry would trip the same guardrail on the same words and
///   spend battery doing it.
struct OnDeviceThreadDigester: ThreadDigesting {
    /// Creates a digester. Nothing is loaded here — the model is reached on first use.
    init() {}

    func availability() async -> ThreadDigesterAvailability {
        // Asked of the prose model specifically, which is why
        // `OnDeviceProvider.unavailabilityReason(for:)` takes a use case at all: the tagging
        // model can be ready while the general one is not, and vice versa.
        guard let reason = OnDeviceProvider.unavailabilityReason(for: .prose) else {
            return .available
        }
        return .unavailable(reason)
    }

    func digest(_ request: ThreadDigestRequest) async throws -> ThreadDigestResult {
        let prompt = request.promptText
        let session = try await OnDeviceThreadDigester.preflight(
            prompt: prompt,
            estimate: request.approximateTokenCount
        )
        let generated: OnDeviceThreadDigest
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceThreadDigest.self,
                options: OnDeviceThreadDigester.options
            ).content
        } catch {
            throw OnDeviceThreadDigester.mapped(error)
        }
        let digest = ThreadDigest(generated)
        // An empty summary with a state chip beside it would be a card claiming to know where a
        // thread stands and refusing to say why; a line saying the model returned nothing is at
        // least true. Same rule as `OnDeviceProvider.usableDraft(in:)`.
        guard !digest.summary.isEmpty else { throw IntelligenceError.malformedResponse }
        return ThreadDigestResult(
            digest: digest,
            coveredCount: request.coveredCount,
            totalCount: request.totalCount
        )
    }

    // MARK: - Prompt and knobs

    /// The session's instructions.
    ///
    /// They carry the product rule as well as the format, and three sentences of it are
    /// load-bearing. The model is told to use only what the comments say, because the comments
    /// are a *budgeted* document and "the author never replied" is a thing it cannot know when
    /// the older half of the thread was evicted. It is told the answer is a reading aid, because
    /// a model that believes it is reviewing the code writes about the code instead of about the
    /// conversation. And it is told never to suggest resolving, replying, approving or merging —
    /// the guardrail this feature is designed around (plan §3.G): "Resolve thread" is the
    /// reviewer's own button two lines below the card, and a digest that recommended pressing it
    /// would be a verdict wearing a summary's clothes.
    static let instructions = """
        You summarise one review thread on a pull request for the reviewer who is reading it. Say \
        where the thread stands — agreed, still open, or blocked on somebody — then write one \
        short paragraph covering what was agreed, what is still open and who is waiting on whom, \
        and list the questions nobody has answered yet, one entry each. Use only what the \
        comments say: never invent a decision, a file, a name or an answer, and where older \
        comments are not shown, do not describe how the thread began. This is a reading aid for a \
        human, not a verdict — describe the conversation, do not review the code, do not tell the \
        reviewer what to do, and never suggest resolving, replying to, approving or merging \
        anything.
        """

    /// How many tokens a digest may use.
    ///
    /// A state, a paragraph and a handful of one-line questions. Roughly twice what that needs,
    /// so a model that runs long is cut off after the paragraph rather than in the middle of it.
    static let responseTokens = 500

    /// The generation options for a digest.
    ///
    /// Defined here rather than in ``OnDeviceGeneration`` because the temperature is the only
    /// part of it that is a *policy*: ``OnDeviceGeneration/structuredTemperature`` is the number
    /// every structured request shares, and the response cap is this request's own business.
    static var options: GenerationOptions {
        GenerationOptions(
            temperature: OnDeviceGeneration.structuredTemperature,
            maximumResponseTokens: responseTokens
        )
    }

    // MARK: - The framework's spelling, in as few lines as possible

    /// How to measure a prompt against a model, and how much room that model has (macOS 26.4+).
    ///
    /// The same two lines ``OnDeviceProvider`` isolates, deliberately copied rather than shared:
    /// `contextSize` and `tokenCount(for:)` arrived after the SDK this code was written against,
    /// so a rename or a signature change has to cost these two lines in each file that names
    /// them and nothing else — widening the provider's `private` to save the copy would trade a
    /// two-line duplication for a wider surface. The measurement is handed back as a closure that
    /// may decline, so ``ShepherdCore/TokenBudget/measured(_:using:)`` — pure, and tested on
    /// Linux — stays the thing that decides what a token count is.
    /// - Parameters:
    ///   - model: The model that will read the prompt.
    ///   - text: The string the count is taken for; the closure declines for any other.
    /// - Returns: The measurement closure and the model's context window in tokens.
    @available(macOS 26.4, *)
    private static func measuredContext(
        of model: SystemLanguageModel,
        measuring text: String
    ) async -> (measure: (String) -> Int?, contextSize: Int) {
        let count = try? await model.tokenCount(for: text)
        return ({ candidate in candidate == text ? count : nil }, model.contextSize)
    }

    /// Turns the framework's generation failures into ``IntelligenceError`` where Shepherd has
    /// something better to say, and passes everything else through untouched.
    ///
    /// The two cases are the provider's, and they mean the same thing here: a guardrail refusal
    /// is "not this thread", not a malfunction, and an exceeded context window is the real
    /// tokenizer disagreeing with the pre-flight estimate. Neither is ever retried.
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
    /// One function because the three are one decision, exactly as they are for every other
    /// on-device request: ADR 0007 makes tier 2's context ceiling a hard error rather than a
    /// silent truncation, so nothing may create a session it is not already sure it can use.
    /// - Parameters:
    ///   - prompt: The prompt.
    ///   - estimate: The request's own chars-÷-4 estimate, used when the OS cannot measure.
    /// - Returns: A session on the prose model.
    /// - Throws: ``IntelligenceError/unavailable(_:)`` or
    ///   ``IntelligenceError/digestTooLarge(tokens:limit:)``.
    private static func preflight(
        prompt: String,
        estimate: Int
    ) async throws -> LanguageModelSession {
        let useCase = OnDeviceUseCase.prose
        if let reason = OnDeviceProvider.unavailabilityReason(for: useCase) {
            throw IntelligenceError.unavailable(reason)
        }
        let model = useCase.model()

        // The instructions share the window with the prompt, so they are measured with it.
        let text = instructions + "\n" + prompt
        var budget = OnDeviceProvider.budget
        var tokens = estimate
        if #available(macOS 26.4, *) {
            // Both halves of the comparison come from the same measurement, or this would be a
            // real token count against a limit that was only ever a guess about the window.
            let context = await measuredContext(of: model, measuring: text)
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
}

// MARK: - Generated to twin

extension ThreadDigest {
    /// The twin of one generated digest (plan §0.4).
    ///
    /// The one-line conversion every `@Generable` type gets: the card only ever sees the pure
    /// `ShepherdCore` value, so nothing outside this file has to know that a second spelling of
    /// this enum exists. Blank questions are dropped here rather than rendered, because `[""]`
    /// would draw an empty bullet.
    /// - Parameter generated: What the model filled in.
    init(_ generated: OnDeviceThreadDigest) {
        self.init(
            state: ThreadDigest.State(generated.state),
            summary: generated.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            openQuestions: generated.openQuestions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

extension ThreadDigest.State {
    /// Maps the generated state onto the twin's.
    /// - Parameter generated: The generated case.
    init(_ generated: OnDeviceThreadState) {
        switch generated {
        case .agreed: self = .agreed
        case .open: self = .open
        case .blocked: self = .blocked
        }
    }
}
