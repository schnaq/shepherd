import ClaudeForFoundationModels
import Foundation
import FoundationModels
import ShepherdCore

/// Claude as a ``LanguageModelBackend``: Anthropic's `ClaudeForFoundationModels` package conforms
/// its models to `LanguageModel`, so the same sessions, schemas, tools and streams that drive the
/// on-device model drive Claude (ADR 0007's tier 3, through ADR 0031's seam; ADR 0038, item 1).
///
/// **The key is the reviewer's own**, entered in Settings and kept in the Keychain, and it travels
/// as `AuthMode.apiKey` — the mode the package documents for a key that is not bundled with the
/// app. App Attest, the package's recommended mode for shipped apps, bills every request to the
/// developer's workspace, which is exactly what ADR 0011 and ADR 0031 rule out: Shepherd never
/// brokers a model account. The package refuses redirects that leave `api.anthropic.com`, so the
/// key is only ever sent there, which is the same promise ``CredentialSafeSession`` makes for the
/// requests Shepherd builds itself.
///
/// **`FoundationModels` and `ClaudeForFoundationModels` are imported here and nowhere else
/// outside the `OnDevice*.swift` files and `LanguageModelBackend.swift`.**
struct ClaudeBackend: LanguageModelBackend {
    /// The model every use case runs on: Claude has no separate tagging model, and prose and
    /// classification are the same request to it.
    let languageModel: ClaudeLanguageModel

    /// Creates the backend.
    /// - Parameters:
    ///   - apiKey: The reviewer's key.
    ///   - modelID: An API model id, e.g. `claude-haiku-4-5`.
    init(apiKey: String, modelID: String) {
        languageModel = ClaudeLanguageModel(
            name: ClaudeBackend.model(forID: modelID),
            auth: .apiKey(apiKey)
        )
    }

    var kind: IntelligenceKind { .anthropic }
    static let budget = TokenBudget.cloud
    static let caps = ResponseCaps.claude

    func model(for useCase: OnDeviceUseCase) -> ClaudeLanguageModel {
        languageModel
    }

    /// Always `nil`: a key is checked for at construction by the router, which builds no cloud
    /// provider without one, and the first request is what tells whether the key is any good.
    func unavailabilityReason(of model: ClaudeLanguageModel) -> String? { nil }

    /// Every compiled-in Claude model carries a 200,000-token window. The package does not say
    /// so — `ClaudeModel.Capabilities` has no context field — so this is Anthropic's documented
    /// figure, and a future model with a different window would not be caught by the compiler.
    static let modelContextSize = 200_000

    /// The window the pre-flight measures against: **the tier budget, not the model's window.**
    ///
    /// `TokenBudget.limited(toContextSize:reservedForResponse:)` replaces a budget with the window
    /// it is given, which is right for the on-device model — its window *is* the limit, and the
    /// estimate-based budget only ever stood in for it. For Claude the window is two hundred
    /// thousand tokens and the reviewer's money is the limit, so the pre-flight is told the same
    /// 100,000 the digest builders cap at (plus the answer's reserve, which `limited` takes back
    /// off), and a prompt nothing truncated cannot sail through at twice the tier's ceiling.
    static let contextSize = min(modelContextSize, budget.maxTokens + caps.reserved)

    /// There is no tokenizer to ask on this side of the network, so the closure declines and the
    /// budget measures by its estimate — honest at this scale, where a few percent of error on a
    /// hundred-thousand-token cap is smaller than the room to the real window.
    func context(
        of model: ClaudeLanguageModel,
        measuring text: String
    ) async -> (measure: (String) -> Int?, contextSize: Int) {
        ({ _ in nil }, ClaudeBackend.contextSize)
    }

    /// The framework's failures first, then the package's own, in Shepherd's words.
    ///
    /// A missing credential is the one a reviewer can fix, so it names the field. The two
    /// attestation cases cannot happen under `AuthMode.apiKey` and are named anyway rather than
    /// swallowed: if a future mode lets them through, the sentence will still be true.
    func mapped(_ error: any Error) -> any Error {
        let error = LanguageModelErrors.mapped(error)
        guard let failure = error as? ClaudeError else { return error }
        switch failure {
        case .missingCredential:
            return IntelligenceError.notConfigured(String(localized: "Anthropic API key"))
        case .attestationUnsupported, .attestationFailed:
            return IntelligenceError.unavailable(
                String(localized: "Claude could not verify this app. Check the Anthropic settings.")
            )
        }
    }

    // MARK: - Model ids

    /// The compiled-in models the package knows the capabilities of, by API id.
    ///
    /// A table rather than a `switch`, so that whoever wants to offer the ids — Settings does not
    /// yet; its field is free text — reads the same list the mapping uses.
    static let knownModels: [ClaudeModel] = [
        .haiku4_5, .sonnet4_6, .sonnet5,
        .opus4_6, .opus4_7, .opus4_8, .opus5, .opus5_5,
        .fable5, .fable5_1,
    ]

    /// The model for an id the reviewer typed.
    ///
    /// A known id gets the package's capability matrix; an empty one gets the default. An unknown
    /// one — a model newer than the pinned package, or a typo — is sent as typed with guided
    /// generation declared and nothing else: every request here relies on it, tool calling the
    /// bridge grants every model regardless, and sending a sampling parameter a model rejects is a
    /// hard error where declaring nothing sends none. If the id is wrong the API says so on the
    /// first request, in the Settings connection test.
    /// - Parameter id: An API model id.
    static func model(forID id: String) -> ClaudeModel {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return model(forID: ClaudeProvider.defaultModelID) }
        if let known = knownModels.first(where: { $0.id == trimmed }) { return known }
        return ClaudeModel(id: trimmed, capabilities: .init(structuredOutput: true))
    }
}

/// Tier 3 on Claude.
typealias ClaudeProvider = SessionProvider<ClaudeBackend>

extension SessionProvider where Backend == ClaudeBackend {
    /// The model used when the reviewer has not named one: the smallest current one, because a
    /// review digest is short work and the key is the reviewer's money.
    static let defaultModelID = "claude-haiku-4-5"

    /// Creates a provider on the reviewer's key.
    /// - Parameters:
    ///   - apiKey: The reviewer's key.
    ///   - modelID: An API model id; empty means ``defaultModelID``.
    init(apiKey: String, modelID: String) {
        self.init(backend: ClaudeBackend(apiKey: apiKey, modelID: modelID))
    }
}
