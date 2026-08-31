import Foundation
import ShepherdCore

/// A non-secret snapshot of the intelligence settings, plus the key read from the Keychain.
///
/// A value type so the router can be handed to background work without touching
/// `@MainActor` state; it is rebuilt whenever Settings change.
struct IntelligenceConfiguration: Sendable, Hashable {
    /// Which tiers are on.
    var mode: IntelligenceMode = .off
    /// Which cloud shape tier 3 uses.
    var cloudKind: CloudProviderKind = .anthropic
    /// The Anthropic model id.
    var anthropicModel: String = AnthropicProvider.defaultModel
    /// The OpenAI-compatible base URL.
    var openAIBaseURL: String = ""
    /// The OpenAI-compatible model name.
    var openAIModel: String = ""
    /// The API key for whichever cloud provider is selected.
    var cloudAPIKey: String = ""

    /// Everything off — the state the app must remain fully usable in.
    static let disabled = IntelligenceConfiguration()
}

/// A produced hint together with the tier that produced it.
struct IntelligenceOutput<Value: Sendable & Hashable>: Sendable, Hashable {
    /// Which tier answered.
    var kind: IntelligenceKind
    /// The answer.
    var value: Value
}

/// What asking a tier produced.
enum IntelligenceOutcome<Value: Sendable & Hashable>: Sendable, Hashable {
    /// Intelligence is switched off; no card is shown at all.
    case disabled
    /// Nothing could answer, with a user-readable reason.
    case unavailable(String)
    /// Every configured tier failed, with the last error's description.
    case failed(String)
    /// An answer.
    case value(IntelligenceOutput<Value>)

    /// The answer, when there is one.
    var output: IntelligenceOutput<Value>? {
        if case .value(let output) = self { return output }
        return nil
    }

    /// A message explaining why there is no answer, when there is none.
    var message: String? {
        switch self {
        case .disabled, .value: return nil
        case .unavailable(let reason): return reason
        case .failed(let reason): return reason
        }
    }
}

/// Picks the provider for a request and degrades gracefully to the tier below (ADR 0007).
///
/// The order is deliberate: the cloud tier sees a large digest and answers best, so it is
/// tried first when the user configured a key; on any failure the on-device tier gets a small
/// digest; if that is unavailable too, the caller is told why and the UI simply shows the
/// deterministic heuristics on their own.
struct IntelligenceRouter: Sendable {
    /// The configuration this router was built from.
    let configuration: IntelligenceConfiguration

    /// Creates a router.
    /// - Parameter configuration: The settings snapshot.
    init(configuration: IntelligenceConfiguration) {
        self.configuration = configuration
    }

    /// A router with everything switched off.
    static let disabled = IntelligenceRouter(configuration: .disabled)

    /// Whether any tier could answer at all.
    var isEnabled: Bool { configuration.mode != .off }

    /// The cloud provider, when the user configured one.
    var cloudProvider: (any IntelligenceProvider)? {
        guard configuration.mode == .onDeviceAndCloud else { return nil }
        switch configuration.cloudKind {
        case .anthropic:
            guard !configuration.cloudAPIKey.isEmpty else { return nil }
            return AnthropicProvider(
                apiKey: configuration.cloudAPIKey,
                model: configuration.anthropicModel
            )
        case .openAICompatible:
            guard !configuration.openAIModel.isEmpty,
                  OpenAICompatibleProvider.completionsURL(base: configuration.openAIBaseURL) != nil
            else { return nil }
            return OpenAICompatibleProvider(
                baseURL: configuration.openAIBaseURL,
                model: configuration.openAIModel,
                apiKey: configuration.cloudAPIKey
            )
        }
    }

    /// Summarises a pull request.
    /// - Parameter detail: The fetched pull request.
    func summary(for detail: PullRequestDetail) async -> IntelligenceOutcome<PRSummary> {
        await run(detail: detail) { provider, digest in
            try await provider.summarizePullRequest(digest)
        }
    }

    /// Suggests where to look first.
    /// - Parameter detail: The fetched pull request.
    func focusHints(for detail: PullRequestDetail) async -> IntelligenceOutcome<[FocusHint]> {
        await run(detail: detail) { provider, digest in
            try await provider.suggestReviewFocus(digest)
        }
    }

    private func run<Value: Sendable & Hashable>(
        detail: PullRequestDetail,
        operation: @Sendable (any IntelligenceProvider, PullRequestDigest) async throws -> Value
    ) async -> IntelligenceOutcome<Value> {
        guard isEnabled else { return .disabled }

        var lastFailure: String?

        if let cloud = cloudProvider {
            let digest = PullRequestDigestBuilder.build(
                from: detail,
                budget: AnthropicProvider.budget
            )
            do {
                return .value(IntelligenceOutput(kind: cloud.kind, value: try await operation(cloud, digest)))
            } catch {
                lastFailure = describe(error)
            }
        }

        let onDevice = OnDeviceProvider()
        if await onDevice.isAvailable {
            let digest = PullRequestDigestBuilder.build(
                from: detail,
                budget: OnDeviceProvider.budget
            )
            do {
                return .value(
                    IntelligenceOutput(kind: onDevice.kind, value: try await operation(onDevice, digest))
                )
            } catch {
                lastFailure = describe(error)
            }
        } else if lastFailure == nil {
            return .unavailable(
                OnDeviceProvider.unavailabilityReason()
                    ?? String(localized: "No intelligence provider is available.")
            )
        }

        return .failed(lastFailure ?? String(localized: "No intelligence provider is available."))
    }

    private func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
