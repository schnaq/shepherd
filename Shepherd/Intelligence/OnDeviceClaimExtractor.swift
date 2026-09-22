import Foundation
import FoundationModels
import ShepherdCore

// MARK: - Guided-generation types
//
// At file scope, not nested, so the `@Generable` macro expands in the simplest possible context —
// the arrangement every other `OnDevice*.swift` file uses. The kind is a `@Generable` *enum* for
// ``OnDeviceTriageClassifier``'s reason: the answer is a choice from a closed vocabulary, and
// letting the framework's guided decoding enforce that is what makes "the model invented a fifth
// claim shape" impossible rather than merely unlikely.

/// The claim shapes the on-device model may choose from — the mirror of
/// ``ShepherdCore/Claim/Kind`` with its payloads left off.
///
/// Spelled out here as well as in the twin, and that duplication is the point of ADR 0007's rule:
/// this enum is Apple-only and lives in the app target, while `Claim.Kind` and its flat
/// `Claim.Kind.Name` vocabulary are pure and live in `ShepherdCore`, where the card's four lines,
/// the dedup key and the merge are tested on Linux. The mapping between them is one switch at the
/// bottom of this file, which is the only place the two spellings meet.
///
/// The four cases are a *closed* set for the reason `Claim.Kind` gives: each one exists because
/// `EvidenceChecker` has a deterministic way to look for evidence of it, and a fifth shape would
/// be a line on the card that could only ever say "?". So tier 2 finds more *sentences*, never
/// more kinds.
@Generable
enum OnDeviceClaimKind {
    /// "Tests added", "all tests pass", "ran the suite".
    case testsAdded
    /// "Only the parser changed", "just `Sources/Uploader/`".
    case scopeLimited
    /// "No breaking changes", "backwards compatible".
    case noBreakingChanges
    /// "Fixes #142", "closes #7".
    case fixesIssue
}

/// One claim the on-device model read out of a description (plan §2.A).
///
/// Four fields: the shape, the sentence it came from, and the two values two of the shapes need.
///
/// The two value fields are **not** optional, and that is the same deliberate difference from the
/// twin that ``OnDeviceCIDiagnosis`` documents: every `@Generable` type in this app is a flat
/// struct of `String`/`Int`/`[…]`, because the on-device model is good at short structured
/// answers and the schema should ask for nothing clever (ADR 0007). An empty string and a zero
/// are how a model says "this shape does not need one", and the conversion at the bottom of this
/// file is where that convention is applied — once, and in the same place that drops a claim whose
/// shape *did* need one.
///
/// The quote's guide is the load-bearing one. The card shows the author's own sentence beside the
/// evidence, so a paraphrase would be Shepherd putting words in a colleague's mouth and linking
/// them to a diff; the instructions say the same thing again, because it is the one instruction
/// this feature cannot afford the model to round off.
@Generable
struct OnDeviceClaim {
    /// Which of the four shapes this is.
    @Guide(description: "Which of the four claim shapes this sentence makes.")
    var kind: OnDeviceClaimKind

    /// The sentence, copied verbatim.
    @Guide(
        description: "The exact sentence from the description that makes this claim, copied word for word. Never rewrite, shorten or summarise it."
    )
    var quote: String

    /// The module a scope claim names, or empty for every other shape.
    @Guide(
        description: "For a scopeLimited claim only: the file, path or module the sentence names, copied exactly. An empty string for every other kind, and for a sentence that limits the scope without naming anything."
    )
    var module: String

    /// The issue a `fixesIssue` claim references, or zero for every other shape.
    @Guide(
        description: "For a fixesIssue claim only: the issue number the sentence references, without the #. Zero for every other kind."
    )
    var issueNumber: Int
}

/// The shape the on-device model fills in for one description (plan §2.A).
///
/// One field, a list, and nothing else — no count, no confidence and no opinion of the pull
/// request. ADR 0026 forbids an aggregate on this card, and a "how sure are you" field would be
/// the first number on it; the reviewer reads the quote next to the evidence, exactly as they do
/// for a claim the patterns found.
///
/// No `@Guide` on the array: the other on-device schemas' array fields carry none either, and the
/// instructions already say what one entry is. An **empty list is the right answer** for a
/// description whose claims the patterns already caught, which is the common case, and a guide
/// that pushed for entries would invent one.
@Generable
struct OnDeviceClaimList {
    /// The claims, in whatever order the model read them.
    var claims: [OnDeviceClaim]
}

// MARK: - The extractor

/// Tier 2 for the claims card: the on-device model reads the description for claim shapes the
/// patterns missed, when the reviewer opens the card (plan §2.A, ADR 0026's amendment).
///
/// The fifth file in the app that imports `FoundationModels`, and it imports nothing else of
/// Apple's. Like ``OnDeviceTriageClassifier`` and ``OnDeviceThreadDigester`` it is deliberately
/// **not** a method on ``IntelligenceProvider``: that protocol is the tier ladder, and a ladder is
/// exactly what this must not have. The input is the description a colleague wrote, which never
/// travels to a BYOK endpoint (``ClaimExtracting`` argues it; ADR 0026 decides it), so there is
/// one tier here and when it cannot answer the card is the tier-1 card it has always been.
///
/// Everything else is the provider's discipline, re-applied rather than reinvented:
///
/// - **The tagging model, not the general one.** `OnDeviceUseCase.tagging` is the
///   `.contentTagging` system model, tuned for precisely this "which of these buckets is this
///   sentence in" work, and its availability is asked separately because the assets download per
///   model (plan §0.1).
/// - **Measured pre-flight, and the ceiling is a hard error.** The prompt is measured against the
///   real tokenizer — the floor is macOS 27, so the OS can always measure (ADR 0038); over budget
///   throws ``IntelligenceError/digestTooLarge(tokens:limit:)`` rather than
///   truncating a description and reading a claim out of half a sentence. The **body alone** is
///   what travels — it is already in the digest budget, and there is nothing else this question
///   needs — so in practice the ceiling is reached only by a description that is a pasted log.
/// - **Low temperature.** A claim is read as a report of what the description says, and a warmer
///   model starts writing the sentence it thinks the reviewer wants to have found.
/// - **A guardrail refusal is one line, never a retry.** Descriptions are full of deleting,
///   breaking and killing things; a retry would trip the same guardrail on the same words and
///   spend battery doing it.
///
/// **What it may not do**, and the instructions say so as well: interpret, weigh, judge or
/// recommend. It adds quoted sentences to a card that has no score on it, every one of them goes
/// through the same ``ShepherdCore/EvidenceChecker`` a pattern claim goes through, and there is no
/// code path from here to a comment, to the outbox or to a merge.
struct OnDeviceClaimExtractor: ClaimExtracting {
    /// Creates an extractor. Nothing is loaded here — the model is reached on first use.
    init() {}

    func availability() async -> ClaimExtractorAvailability {
        // Asked of the tagging model specifically, which is the whole reason
        // `OnDeviceProvider.unavailabilityReason(for:)` takes a use case: the tagging model can
        // be ready while the general one is not, and vice versa.
        guard let reason = OnDeviceProvider.unavailabilityReason(for: .tagging) else {
            return .available
        }
        return .unavailable(reason)
    }

    func extract(from body: String) async throws -> ClaimList {
        let prompt = OnDeviceClaimExtractor.prompt(for: body)
        let session = try await OnDeviceClaimExtractor.preflight(prompt: prompt)
        let generated: OnDeviceClaimList
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceClaimList.self,
                options: OnDeviceClaimExtractor.options
            ).content
        } catch {
            throw OnDeviceClaimExtractor.mapped(error)
        }
        // An empty list is a *successful* answer and never an error: the patterns having caught
        // everything is the common case, and the failure line the card would show for it would be
        // reporting a problem that did not happen. A claim whose quote is not in the description
        // is dropped here, at the one place that has both the answer and the text it was read
        // from: the instructions ask for the sentence verbatim, and `quoted(in:)` is what makes
        // that a rule instead of a request.
        return ClaimList(generated).quoted(in: body)
    }

    // MARK: - Prompt and knobs

    /// The session's instructions.
    ///
    /// They carry the product rule as well as the format, and four sentences of it are
    /// load-bearing. The model is told to copy the sentence **verbatim**, because the card shows
    /// the author's own words next to a diff and a paraphrase there would be an accusation
    /// Shepherd wrote itself. It is told to use only the description, because the description is
    /// all it is given — it cannot see the diff, and "the tests look thin" is a thing it cannot
    /// know. It is told that a sentence which makes none of the four claims is not a claim, since
    /// a model asked for a list will otherwise fill one. And it is told the answer is put beside
    /// evidence for a human to read, because a model that believes it is judging the pull request
    /// starts writing judgements (ADR 0026's rule, in the prompt as well as in the types).
    static let instructions = """
        You read one pull request description and list the sentences in it that claim something \
        checkable about the change itself. There are exactly four kinds of claim: tests were \
        added or run, the change is limited to a named file or module, nothing breaking changed, \
        and an issue is fixed by this change. For each one, copy the sentence it is made in word \
        for word — never rewrite, shorten, translate or summarise it — and name the kind. Use \
        only what the description says: never invent a sentence, a file, a number or a claim, and \
        if a sentence makes none of the four claims, leave it out. An empty list is a correct \
        answer. Each claim you list is shown to a reviewer beside what the diff and the test \
        results actually say, so describe what the description claims — do not judge the pull \
        request, do not say whether the claim is true, and do not tell the reviewer what to do.
        """

    /// The prompt: the description, and nothing else.
    ///
    /// One label in front of it so the model is not asked to guess what it is reading, and no
    /// digest, no file list and no diff — this question is about the *text*, and everything else
    /// in the window would be context the answer must not be drawn from (the instructions say
    /// exactly that).
    /// - Parameter body: The pull request's description, as Markdown source.
    /// - Returns: The prompt text.
    static func prompt(for body: String) -> String {
        "Pull request description:\n\n" + body
    }

    /// How many tokens a claim list may use.
    ///
    /// At most four claims, each a quoted sentence plus a short value. Roughly twice what that
    /// needs, so a model that runs long is cut off after a claim rather than in the middle of a
    /// quote — a half-copied sentence is the one answer shape this card must never draw.
    static let responseTokens = 500

    /// The generation options for a claim list.
    ///
    /// The temperature is ``OnDeviceGeneration/structuredTemperature`` — the same number every
    /// other structured request uses, because it is a policy about structured answers and not a
    /// per-feature preference. The response cap is this request's own business.
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
    /// so a rename or a signature change has to cost these two lines in each file that names them
    /// and nothing else — widening the provider's `private` to save the copy would trade a
    /// two-line duplication for a wider surface. The measurement is handed back as a closure that
    /// may decline, so ``ShepherdCore/TokenBudget/measured(_:using:)`` — pure, and tested on
    /// Linux — stays the thing that decides what a token count is.
    /// - Parameters:
    ///   - model: The model that will read the prompt.
    ///   - text: The string the count is taken for; the closure declines for any other.
    /// - Returns: The measurement closure and the model's context window in tokens.
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
    /// The two cases are the provider's, and they mean the same thing here: a guardrail refusal is
    /// "not this description", not a malfunction, and an exceeded context window is the real
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
    /// - Parameter prompt: The prompt.
    /// - Returns: A session on the tagging model.
    /// - Throws: ``IntelligenceError/unavailable(_:)`` or
    ///   ``IntelligenceError/digestTooLarge(tokens:limit:)``.
    private static func preflight(prompt: String) async throws -> LanguageModelSession {
        let useCase = OnDeviceUseCase.tagging
        if let reason = OnDeviceProvider.unavailabilityReason(for: useCase) {
            throw IntelligenceError.unavailable(reason)
        }
        let model = useCase.model()

        // The instructions share the window with the prompt, so they are measured with it.
        let text = instructions + "\n" + prompt
        // Both halves of the comparison come from the same measurement, or this would be a
        // real token count against a limit that was only ever a guess about the window. The
        // floor is macOS 27 (ADR 0038), so the OS can always measure; the chars-÷-4 estimate
        // that used to stand in below 26.4 is gone with the `#available` that guarded it.
        let context = await measuredContext(of: model, measuring: text)
        let budget = OnDeviceProvider.budget.limited(
            toContextSize: context.contextSize,
            reservedForResponse: OnDeviceGeneration.reservedResponseTokens
        )
        let tokens = budget.measured(text, using: context.measure)
        guard tokens <= budget.maxTokens else {
            throw IntelligenceError.digestTooLarge(tokens: tokens, limit: budget.maxTokens)
        }

        return LanguageModelSession(model: model, instructions: instructions)
    }
}

// MARK: - Generated to twin

extension ClaimList {
    /// The twin of one generated list (plan §0.4).
    ///
    /// The one-line conversion every `@Generable` type gets: the card, the merge and the evidence
    /// check only ever see the pure `ShepherdCore` values, so nothing outside this file has to
    /// know that a second spelling of these four shapes exists. Malformed entries are dropped
    /// here rather than rendered — a scope claim that named no module, an issue claim with no
    /// number, a claim with nothing quoted — and a list that loses one entry keeps the others,
    /// for the reason the twin's own decoder gives.
    /// - Parameter generated: What the model filled in.
    init(_ generated: OnDeviceClaimList) {
        self.init(claims: generated.claims.compactMap { ExtractedClaim($0) })
    }
}

extension ExtractedClaim {
    /// The twin of one generated claim, or `nil` when the model produced a shape it did not
    /// finish.
    ///
    /// The convention `OnDeviceClaim` documents, applied: blank means "this shape needs no
    /// module", zero means "this shape references no issue", and
    /// ``ShepherdCore/Claim/Kind/init(name:module:issueNumber:)`` — shared with the twin's
    /// decoder, so the rule is written once — is what decides that a `scopeLimited` without a
    /// module and a `fixesIssue` without a number are not claims at all.
    /// - Parameter generated: What the model filled in for one claim.
    init?(_ generated: OnDeviceClaim) {
        guard let quote = ExtractedClaim.trimmed(generated.quote) else { return nil }
        guard let kind = Claim.Kind(
            name: Claim.Kind.Name(generated.kind),
            module: ExtractedClaim.trimmed(generated.module),
            issueNumber: generated.issueNumber > 0 ? generated.issueNumber : nil
        ) else { return nil }
        self.init(kind: kind, quote: quote)
    }

    /// A generated string, or `nil` when the model left it blank.
    ///
    /// The app-target copy of the twin's own `intelligenceTrimmedOrNil`, which is internal to
    /// `ShepherdCore`; the same two lines ``ShepherdCore/CIDiagnosis`` keeps here for the same
    /// reason.
    /// - Parameter text: What the model wrote.
    private static func trimmed(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Claim.Kind.Name {
    /// Maps the generated kind onto the twin's flat vocabulary.
    /// - Parameter generated: The generated case.
    init(_ generated: OnDeviceClaimKind) {
        switch generated {
        case .testsAdded: self = .testsAdded
        case .scopeLimited: self = .scopeLimited
        case .noBreakingChanges: self = .noBreakingChanges
        case .fixesIssue: self = .fixesIssue
        }
    }
}
