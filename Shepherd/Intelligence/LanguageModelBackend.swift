import Foundation
import FoundationModels
import ShepherdCore

/// What a ``SessionProvider`` needs to know about the model it drives (ADR 0031 §One, built for
/// ADR 0038's programme).
///
/// `LanguageModelSession` takes *a* model, any conformer of `LanguageModel`, and everything above
/// the session — guided generation, the read-only tools, the streamed cumulative drafts — does not
/// care which one answered. What *does* differ between backends is small and is exactly this
/// protocol: which tier the answer is badged as, which digest budget requests are built with, how
/// a model is picked for a use case, why it might be unavailable, how the prompt is measured
/// against its window, and which errors of its own it can name. Two conformers exist:
/// ``OnDeviceBackend`` for Apple's system model and ``ClaudeBackend`` for Claude through
/// Anthropic's `ClaudeForFoundationModels` package.
///
/// **`FoundationModels` is imported only by the `OnDevice*.swift` files in this folder, this
/// file and `ClaudeProvider.swift`.** Everything the rest of the app sees is
/// ``IntelligenceProvider``.
protocol LanguageModelBackend: Sendable {
    /// The model type the sessions are built on.
    associatedtype Model: LanguageModel

    /// Which tier this backend is, for the badge on every card.
    var kind: IntelligenceKind { get }

    /// The token budget digests are built with for this tier — the estimate-based number, because
    /// a digest is built *before* a model exists to ask. The pre-flight then measures against
    /// ``context(of:measuring:)``, which for the on-device model is the real window and for Claude
    /// is this same budget again (the reviewer's money, not the window, is what binds there).
    static var budget: TokenBudget { get }

    /// How long each kind of answer may be, and how much of the window is kept for it.
    static var caps: ResponseCaps { get }

    /// The model a use case runs on.
    /// - Parameter useCase: What the request is for.
    func model(for useCase: OnDeviceUseCase) -> Model

    /// Why the model cannot be used right now, or `nil` when it can.
    ///
    /// Surfaced verbatim in Settings and on the card, so the sentence has to be one a reader can
    /// act on.
    /// - Parameter model: The model to ask about.
    func unavailabilityReason(of model: Model) -> String?

    /// How to measure a prompt against a model, and how much room that model has.
    ///
    /// The measurement is handed back as a closure rather than a number so
    /// ``ShepherdCore/TokenBudget/measured(_:using:)`` — pure, and tested on Linux — stays the
    /// thing that decides what a token count *is*; a closure that returns `nil` falls back to the
    /// estimate there.
    /// - Parameters:
    ///   - model: The model that will read the prompt.
    ///   - text: The string the count is taken for; the closure may decline for any other.
    /// - Returns: The measurement closure and the model's context window in tokens.
    func context(of model: Model, measuring text: String) async -> (measure: (String) -> Int?, contextSize: Int)

    /// An error the session threw, in Shepherd's words.
    ///
    /// The default is ``LanguageModelErrors/mapped(_:)``, the framework's failures; a backend with
    /// failures of its own runs that first and names its own afterwards.
    /// - Parameter error: An error the session threw.
    func mapped(_ error: any Error) -> any Error
}

extension LanguageModelBackend {
    func mapped(_ error: any Error) -> any Error { LanguageModelErrors.mapped(error) }
}

/// How long each kind of answer may be, per backend.
///
/// The on-device numbers were tuned for a model with a window of a few thousand tokens, where a
/// runaway answer eats the prompt's room; Claude has a window two orders of magnitude larger and
/// writes a fuller diagnosis when allowed to, so it gets caps of its own rather than inheriting
/// numbers chosen for a different constraint. `reserved` is what every pre-flight leaves for the
/// answer, and it has to cover the largest cap plus the instructions and the schema the framework
/// injects into the same window.
struct ResponseCaps: Sendable, Hashable {
    /// A summary: two or three sentences plus short risk notes.
    var summary: Int
    /// Focus hints: at most a handful of files with one line each.
    var focus: Int
    /// A drafted review, comment, explanation or brief.
    var draft: Int
    /// A CI diagnosis: five short fields.
    var diagnosis: Int
    /// What the pre-flight leaves for the answer.
    var reserved: Int

    /// Apple's on-device model (plan §0.1's numbers).
    static let onDevice = ResponseCaps(
        summary: OnDeviceGeneration.summaryResponseTokens,
        focus: OnDeviceGeneration.focusResponseTokens,
        draft: OnDeviceGeneration.draftResponseTokens,
        diagnosis: OnDeviceGeneration.diagnosisResponseTokens,
        reserved: OnDeviceGeneration.reservedResponseTokens
    )

    /// Claude. Roughly double the on-device caps, and the draft at the 1,024 the HTTP provider
    /// this replaced always sent; the reserve covers the largest of them with room for the schema.
    static let claude = ResponseCaps(summary: 800, focus: 600, draft: 1_024, diagnosis: 800, reserved: 2_000)
}

/// The framework's failures, in Shepherd's words — shared by every session-based provider and by
/// the three on-device classifiers.
enum LanguageModelErrors {
    /// Turns `LanguageModelError` into ``IntelligenceError`` where Shepherd has something better
    /// to say, and passes everything else through untouched.
    ///
    /// Three are worth naming (plan §0.1). A guardrail violation, and a refusal, are not
    /// malfunctions: review prose is full of deleting, breaking and killing things, guardrails
    /// over-fire on technical content, and the honest answer is one sentence saying the model
    /// declined — **never** an automatic retry, which would trip the same guardrail on the same
    /// words. An exceeded context window is the real tokenizer disagreeing with the pre-flight,
    /// which is worth its own sentence because the fix ("smaller selection, or the cloud tier")
    /// is different from every other failure's. An unsupported capability is a property of the
    /// *model* — it was built without tool calling or guided generation — which is what
    /// ``IntelligenceError/toolsUnsupported`` already means for an endpoint, and the router steps
    /// down on it the same way.
    ///
    /// A rate limit becomes the HTTP shape the cloud tiers already report, with the reset time in
    /// the message when the model named one. A failure that came out of a *tool* is unwrapped
    /// first: the framework reports one as its own error wrapping the tool's, so a hop cap that
    /// fired inside a wrapper would otherwise reach the router as a framework type nobody can
    /// read.
    /// - Parameter error: An error a `LanguageModelSession` threw.
    /// - Returns: An ``IntelligenceError``, or the error as it was.
    static func mapped(_ error: any Error) -> any Error {
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return mapped(toolError.underlyingError)
        }
        guard let failure = error as? LanguageModelError else { return error }
        switch failure {
        case .guardrailViolation, .refusal:
            return IntelligenceError.guardrailDeclined
        case .contextSizeExceeded:
            return IntelligenceError.contextExceeded
        case .unsupportedCapability:
            return IntelligenceError.toolsUnsupported
        case .rateLimited(let details):
            if let reset = details.resetDate {
                return IntelligenceError.http(
                    status: 429,
                    message: String(localized: "Rate limited until \(reset.formatted(date: .omitted, time: .shortened)).")
                )
            }
            return IntelligenceError.http(status: 429, message: String(localized: "Rate limited. Try again in a moment."))
        default:
            return error
        }
    }
}
