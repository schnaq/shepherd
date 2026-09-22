import Foundation
import FoundationModels
import ShepherdCore
import Synchronization

// MARK: - Guided-generation types

@Generable
struct OnDeviceClaimNote {
    @Guide(description: "The path of the changed file, exactly as the list of changed files spells it.")
    var path: String

    @Guide(
        description: "One to three consecutive lines copied word for word from the diff the tool returned. Never rewrite or shorten them."
    )
    var excerpt: String

    @Guide(description: "One short sentence saying what these lines show about the claim.")
    var sentence: String
}

@Generable
struct OnDeviceClaimCheck {
    @Guide(description: "At most four places in the diff. An empty list is a correct answer.")
    var notes: [OnDeviceClaimNote]
}

// MARK: - The profile

/// How many tools the session has called, readable from the profile's synchronous `body`.
///
/// A `Mutex` rather than the ``ToolTraceRecorder`` actor, because the framework evaluates the
/// profile's body synchronously before each turn and an actor cannot be read from there.
final class ClaimCheckHopGate: Sendable {
    private let calls = Mutex(0)

    var count: Int { calls.withLock { $0 } }

    func record() { calls.withLock { $0 += 1 } }
}

/// The session's profile: the macOS 27 half of this feature (ADR 0038 item 2).
///
/// The tool-calling mode is a function of how many reads have happened, and that is the whole
/// point of a *dynamic* profile here. `.required` on the first turn makes "look at the diff before
/// answering" a guarantee rather than a request in the instructions. `.required` for the whole
/// session would never end — the spike on 2026-09-22 showed the model calling the tool again on
/// every turn — so after the first read the model may read up to ``maximumReads`` times and
/// then has to answer.
struct ClaimCheckProfile: LanguageModelSession.DynamicProfile {
    /// Reads before the model must answer. Below ``IntelligenceToolLoop/maximumHops``, so the
    /// recorder's own cap is never what ends a check.
    static let maximumReads = 3

    let model: SystemLanguageModel
    let tools: [any Tool]
    let gate: ClaimCheckHopGate
    let responseTokens: Int

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions(OnDeviceClaimChecker.instructions)
            tools
        }
        .model(model)
        .toolCallingMode(ClaimCheckProfile.mode(afterReads: gate.count))
        .temperature(OnDeviceGeneration.structuredTemperature)
        .maximumResponseTokens(responseTokens)
        .onToolCall { [gate] in gate.record() }
    }

    static func mode(afterReads reads: Int) -> GenerationOptions.ToolCallingMode {
        if reads == 0 { return .required }
        return reads < maximumReads ? .allowed : .disallowed
    }
}

// MARK: - The checker

struct OnDeviceClaimChecker: ClaimChecking {
    init() {}

    func availability() async -> OnDeviceAvailability {
        guard let reason = OnDeviceProvider.unavailabilityReason(for: .prose) else {
            return .available
        }
        return .unavailable(reason)
    }

    func check(
        _ line: ClaimsEvidenceReport.Line,
        in detail: PullRequestDetail
    ) async throws -> ClaimCheck {
        let prompt = OnDeviceClaimChecker.prompt(for: line, in: detail)
        let recorder = ToolTraceRecorder()
        let session = try await OnDeviceClaimChecker.preflight(
            prompt: prompt,
            detail: detail,
            recorder: recorder
        )
        let generated: OnDeviceClaimCheck
        do {
            generated = try await session.respond(
                to: prompt,
                generating: OnDeviceClaimCheck.self
            ).content
        } catch {
            throw LanguageModelErrors.mapped(error)
        }
        let notes = generated.notes.map {
            ClaimCheck.Note(path: $0.path, excerpt: $0.excerpt, sentence: $0.sentence)
        }
        return ClaimCheck(
            notes: ClaimCheck.verified(notes, in: detail.files),
            trace: await recorder.current
        )
    }

    // MARK: - Pre-flight

    /// Availability, budget and session in one decision, as ``OnDeviceClaimExtractor`` makes it.
    ///
    /// Measured, never estimated: the instructions share the window with the prompt, and the tool
    /// results are budgeted by `LocalToolExecutor` from the same limited budget.
    private static func preflight(
        prompt: String,
        detail: PullRequestDetail,
        recorder: ToolTraceRecorder
    ) async throws -> LanguageModelSession {
        let useCase = OnDeviceUseCase.prose
        if let reason = OnDeviceProvider.unavailabilityReason(for: useCase) {
            throw IntelligenceError.unavailable(reason)
        }
        let model = useCase.model()
        let text = instructions + "\n" + prompt
        let context = await measuredContext(of: model, measuring: text)
        let budget = OnDeviceProvider.budget.limited(
            toContextSize: context.contextSize,
            reservedForResponse: OnDeviceGeneration.reservedResponseTokens
        )
        let tokens = budget.measured(text, using: context.measure)
        guard tokens <= budget.maxTokens else {
            throw IntelligenceError.digestTooLarge(tokens: tokens, limit: budget.maxTokens)
        }
        let tools = OnDeviceToolBridge.tools(
            executor: LocalToolExecutor(detail: detail, budget: budget),
            recorder: recorder
        )
        return LanguageModelSession(profile: ClaimCheckProfile(
            model: model,
            tools: tools,
            gate: ClaimCheckHopGate(),
            responseTokens: responseTokens
        ))
    }

    private static func measuredContext(
        of model: SystemLanguageModel,
        measuring text: String
    ) async -> (measure: (String) -> Int?, contextSize: Int) {
        let count = try? await model.tokenCount(for: text)
        return ({ candidate in candidate == text ? count : nil }, model.contextSize)
    }

    // MARK: - Prompt

    static let responseTokens = 600

    static let instructions = """
        You help a reviewer check one claim a pull request description makes, by reading the \
        diff with the tools. Always read the diff of at least one relevant file before you \
        answer. Then list the places in the diff that bear on the claim: for each, the file \
        path, one to three consecutive lines copied exactly from the tool's output, and one \
        short sentence saying what those lines show. Point at code; do not say whether the \
        claim is true, do not judge the pull request, and do not tell the reviewer what to do. \
        If nothing in the diff bears on the claim, return an empty list.
        """

    /// The claim, Shepherd's own facts about it and the files the model may read.
    static func prompt(for line: ClaimsEvidenceReport.Line, in detail: PullRequestDetail) -> String {
        let facts = line.verdict.facts.map { "- " + $0.englishSentence }.joined(separator: "\n")
        let paths = IntelligenceToolRegistry.orderedPaths(in: detail.files)
            .prefix(IntelligenceToolRegistry.maximumListedPaths)
            .map { "- " + $0 }
            .joined(separator: "\n")
        return """
            Claim (\(line.claim.kind.englishLabel)):
            "\(line.claim.quote)"

            What Shepherd already found without a model:
            \(facts.isEmpty ? "- nothing" : facts)

            Changed files you can read with fileDiff:
            \(paths.isEmpty ? "- none" : paths)
            """
    }
}
