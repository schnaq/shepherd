import Foundation
import FoundationModels
import ShepherdCore

// MARK: - Guided-generation types
//
// At file scope, not nested, so the `@Generable` macro expands in the simplest possible context
// — the arrangement `OnDeviceProvider`'s four shapes already use. Unlike those, this schema uses
// `@Generable` *enums*: the answer is a choice from a closed vocabulary, and letting the
// framework's guided decoding enforce that is what makes "the model invented a kind" impossible
// rather than merely unlikely.

/// The kinds the on-device model may choose from — the mirror of ``ShepherdCore/TriageVerdict/Kind``.
///
/// Spelled out here as well as in the twin, and that duplication is the point of ADR 0007's rule:
/// this enum is Apple-only and lives in the app target, the twin is pure and lives in
/// `ShepherdCore` where the storage, the facet and the ⌘K filter can be tested on Linux. The
/// mapping between them is one switch below, which is the only place the two spellings meet.
@Generable
enum OnDeviceTriageKind {
    /// New behaviour.
    case feature
    /// A correction to existing behaviour.
    case fix
    /// Housekeeping: CI, tooling, formatting, generated files.
    case chore
    /// A dependency version change, lockfile included.
    case dependencyBump
    /// Documentation only.
    case docs
    /// Behaviour-preserving restructuring.
    case refactor
}

/// The risk levels the on-device model may choose from — the mirror of
/// ``ShepherdCore/TriageVerdict/Risk``.
@Generable
enum OnDeviceTriageRisk {
    /// Mechanical, contained, or fully covered by tests.
    case low
    /// Touches behaviour a reviewer should read carefully.
    case medium
    /// Touches something that hurts when it is wrong.
    case high
}

/// The shape the on-device model fills in for one pull request (plan §3.A).
///
/// Three fields and nothing else. The reason is guided to *one sentence* because it is rendered
/// in a popover beside a chip on an inbox row: a paragraph would be a paragraph nobody reads, and
/// a truncated paragraph would be worse than a sentence that fits.
@Generable
struct OnDeviceTriageVerdict {
    /// What kind of change this is.
    @Guide(description: "What kind of change this pull request is.")
    var kind: OnDeviceTriageKind

    /// How much it can hurt.
    @Guide(description: "How much damage this change can do if it is wrong.")
    var risk: OnDeviceTriageRisk

    /// Why, in one sentence.
    @Guide(
        description: "One short sentence naming the concrete thing that decided the risk, such as a file or a deleted test. No preamble."
    )
    var reason: String
}

// MARK: - The classifier

/// Tier 2 for structured triage: the content-tagging model gives every pull request a verdict
/// (plan §3.A, ADR 0023).
///
/// The second file in the app that imports `FoundationModels`, and it imports nothing else of
/// Apple's. It is deliberately *not* a method on ``IntelligenceProvider``: that protocol is the
/// tier ladder, and a ladder is exactly what this must not have — an unattended bulk pass may
/// never fall through to a cloud endpoint (``TriageClassifying`` argues it, ADR 0023 decides it).
/// There is one tier here, and when it cannot answer the inbox shows tier-1 risk hints.
///
/// Everything else is the provider's discipline, re-applied rather than reinvented:
///
/// - **The tagging model, not the general one.** `OnDeviceUseCase.tagging` is the
///   `.contentTagging` system model, which is tuned for precisely this "put it in one of these
///   buckets" work, and its availability is asked separately because the assets download per
///   model (plan §0.1).
/// - **Measured pre-flight, and the ceiling is a hard error.** The prompt is measured against the
///   real tokenizer where the OS can do that and estimated at four characters per token where it
///   cannot; over budget throws ``IntelligenceError/digestTooLarge(tokens:limit:)`` instead of
///   silently truncating a pull request into a wrong verdict (ADR 0007).
/// - **Low temperature.** A verdict is read as a fact about a diff, and a warmer model starts
///   writing the reason it thinks the reviewer wants to hear.
/// - **A guardrail refusal is one line, never a retry.** Review material is full of deleting,
///   breaking and killing things; a retry would trip the same guardrail on the same words and
///   spend battery doing it.
struct OnDeviceTriageClassifier: TriageClassifying {
    /// The model that produced a verdict, stored beside it.
    ///
    /// Names the *use case* rather than a version, because that is what Shepherd chooses: Apple
    /// ships the weights with the OS and does not expose a build number. The trailing number is
    /// Shepherd's own — bumping it is how a prompt or schema change invalidates every stored
    /// verdict, the same lever ``ShepherdCore/SearchDocument/schemaVersion`` is for the index.
    let modelIdentifier = "apple.ondevice.contenttagging.1"

    /// Creates a classifier. Nothing is loaded here — the model is reached on first use.
    init() {}

    func availability() async -> TriageClassifierAvailability {
        // Asked of the tagging model specifically, which is the whole reason
        // `OnDeviceProvider.unavailabilityReason(for:)` takes a use case: the tagging model can
        // be ready while the general one is not, and vice versa.
        guard let reason = OnDeviceProvider.unavailabilityReason(for: .tagging) else {
            return .available
        }
        return .unavailable(reason)
    }

    func classify(_ input: TriageInput) async throws -> TriageVerdict {
        let prompt = input.promptText
        let session = try OnDeviceTriageClassifier.preflight(
            prompt: prompt,
            estimate: input.approximateTokenCount
        )
        let generated: OnDeviceTriageVerdict
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceTriageVerdict.self,
                options: OnDeviceTriageClassifier.options
            ).content
        } catch {
            throw OnDeviceTriageClassifier.mapped(error)
        }
        return TriageVerdict(generated)
    }

    // MARK: - Prompt and knobs

    /// The session's instructions.
    ///
    /// They carry the product rule as well as the format. Two sentences of it are load-bearing:
    /// the model is told to use only what the input states — the input is a budgeted document, so
    /// "the tests look thin" is a thing it cannot know — and it is told that the verdict sorts an
    /// inbox rather than deciding anything, because a model that believes it is gating a merge
    /// writes differently (ADR 0023's rule, in the prompt as well as in the types).
    static let instructions = """
        You classify pull requests for a senior engineer's inbox. Choose the kind of change and \
        how much it can hurt, then give one short sentence naming the concrete thing that \
        decided the risk. Use only what the input states; never invent files, tests, APIs or \
        behaviour, and prefer the lower risk when the input is too thin to judge. The risk hints \
        in the input were computed from the diff and are facts, not guesses. Your answer sorts \
        and filters a list — it approves nothing, merges nothing and starts nothing — so write a \
        description, not a recommendation, and do not tell the reviewer what to do.
        """

    /// How many tokens a verdict may use.
    ///
    /// A kind, a risk and one sentence. Roughly twice what that needs, so a model that runs long
    /// is cut off after the sentence rather than in the middle of it.
    static let responseTokens = 200

    /// The generation options for a verdict.
    ///
    /// The temperature is ``OnDeviceGeneration/structuredTemperature`` — the same number the two
    /// other structured requests use, because it is a policy about structured answers and not a
    /// per-feature preference.
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
    /// so a rename or a signature change has to cost these two lines and nothing else. The
    /// measurement is handed back as a closure that may decline, so
    /// ``ShepherdCore/TokenBudget/measured(_:using:)`` — pure, and tested on Linux — stays the
    /// thing that decides what a token count is.
    /// - Parameter model: The model that will read the prompt.
    /// - Returns: The measurement closure and the model's context window in tokens.
    @available(macOS 26.4, *)
    private static func measuredContext(
        of model: SystemLanguageModel
    ) -> (measure: (String) -> Int?, contextSize: Int) {
        ({ text in try? model.tokenCount(for: text) }, model.contextSize)
    }

    /// Turns the framework's generation failures into ``IntelligenceError`` where Shepherd has
    /// something better to say, and passes everything else through untouched.
    ///
    /// The two cases are the provider's, and they mean the same thing here: a guardrail refusal
    /// is "not this pull request", not a malfunction, and an exceeded context window is the real
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
    ///   - estimate: The input's own chars-÷-4 estimate, used when the OS cannot measure.
    /// - Returns: A session on the tagging model.
    /// - Throws: ``IntelligenceError/unavailable(_:)`` or
    ///   ``IntelligenceError/digestTooLarge(tokens:limit:)``.
    private static func preflight(
        prompt: String,
        estimate: Int
    ) throws -> LanguageModelSession {
        let useCase = OnDeviceUseCase.tagging
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
}

// MARK: - Generated to twin

extension TriageVerdict {
    /// The twin of one generated verdict (plan §0.4).
    ///
    /// The one-line conversion every `@Generable` type gets: the UI, the facet and the database
    /// only ever see the pure `ShepherdCore` value, so nothing outside this file has to know that
    /// a second spelling of these enums exists.
    /// - Parameter generated: What the model filled in.
    init(_ generated: OnDeviceTriageVerdict) {
        self.init(
            kind: TriageVerdict.Kind(generated.kind),
            risk: TriageVerdict.Risk(generated.risk),
            // Trimmed here rather than in the twin's initialiser: a model that answers with a
            // leading newline has still produced the sentence, and the popover renders whatever
            // is stored verbatim.
            reason: generated.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

extension TriageVerdict.Kind {
    /// Maps the generated kind onto the twin's.
    /// - Parameter generated: The generated case.
    init(_ generated: OnDeviceTriageKind) {
        switch generated {
        case .feature: self = .feature
        case .fix: self = .fix
        case .chore: self = .chore
        case .dependencyBump: self = .dependencyBump
        case .docs: self = .docs
        case .refactor: self = .refactor
        }
    }
}

extension TriageVerdict.Risk {
    /// Maps the generated risk onto the twin's.
    /// - Parameter generated: The generated case.
    init(_ generated: OnDeviceTriageRisk) {
        switch generated {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }
}
