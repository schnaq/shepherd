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

/// Where a router gets its tiers from.
///
/// A seam, for the same reason ``ModelListing`` is one: the degradation ladder — cloud first, then
/// on-device, then a reason the user can read — is the part of the intelligence layer with real
/// behaviour in it, and verifying it must not require an API key, a network, or a Mac with Apple
/// Intelligence switched on. Production uses ``live``; the tests substitute stubs.
struct IntelligenceTiers: Sendable {
    /// Builds the cloud tier from the configuration, or `nil` when none is configured.
    var cloud: @Sendable (IntelligenceConfiguration) -> (any IntelligenceProvider)?
    /// Builds the on-device tier.
    var onDevice: @Sendable () -> any IntelligenceProvider
    /// Why the on-device tier cannot answer right now, or `nil` when it can.
    var onDeviceUnavailabilityReason: @Sendable () -> String?

    /// The real tiers.
    static let live = IntelligenceTiers(
        cloud: { IntelligenceRouter.liveCloudProvider(for: $0) },
        onDevice: { OnDeviceProvider() },
        onDeviceUnavailabilityReason: { OnDeviceProvider.unavailabilityReason() }
    )
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
    /// Where the tiers come from — ``IntelligenceTiers/live`` outside tests.
    private let tiers: IntelligenceTiers

    /// Creates a router.
    /// - Parameters:
    ///   - configuration: The settings snapshot.
    ///   - tiers: Where to get the providers from. Defaults to the real ones.
    init(configuration: IntelligenceConfiguration, tiers: IntelligenceTiers = .live) {
        self.configuration = configuration
        self.tiers = tiers
    }

    /// A router with everything switched off.
    static let disabled = IntelligenceRouter(configuration: .disabled)

    /// Whether any tier could answer at all.
    var isEnabled: Bool { configuration.mode != .off }

    /// The cloud provider, when the user configured one.
    var cloudProvider: (any IntelligenceProvider)? { tiers.cloud(configuration) }

    /// Whether a tier could take a request right now, as far as is knowable synchronously.
    ///
    /// The drafting buttons need an answer *before* the click, so they can be absent rather than
    /// present and then failing (ADR 0007: no feature may hard-depend on an LLM). On-device
    /// availability happens to be a synchronous property of `SystemLanguageModel`, so this is an
    /// honest answer rather than an optimistic one — but it is still only "could take it", not
    /// "will succeed": a wrong key or an unreachable endpoint is found out on the request itself,
    /// and shows up as ``IntelligenceOutcome/failed(_:)``.
    var canDraft: Bool {
        guard isEnabled else { return false }
        if cloudProvider != nil { return true }
        return tiers.onDeviceUnavailabilityReason() == nil
    }

    /// The cloud provider the configuration asks for, or `nil` when it does not ask for one.
    /// - Parameter configuration: The settings snapshot.
    static func liveCloudProvider(
        for configuration: IntelligenceConfiguration
    ) -> (any IntelligenceProvider)? {
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

    /// Drafts the body of a review, as a suggestion the reviewer edits and submits themselves.
    ///
    /// Same ladder and the same ``IntelligenceOutcome`` semantics as the hint calls above, so the
    /// UI shows the failure the same way it shows a missing summary card: one line of plain text
    /// saying which tier said what. Nothing here submits anything.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - pendingComments: The inline comments already in the local draft, quoted (and capped)
    ///     so the draft can refer to what the reviewer found.
    /// - Returns: The drafted text, or why there is none.
    func draftReviewSummary(
        for detail: PullRequestDetail,
        pendingComments: [DraftComment] = []
    ) async -> IntelligenceOutcome<String> {
        await run { provider, budget in
            try await provider.draftReviewSummary(
                ReviewSummaryDraftRequest.build(
                    detail: detail,
                    pendingComments: pendingComments,
                    budget: budget
                )
            )
        }
    }

    /// Drafts one inline comment, as a suggestion the reviewer edits and saves themselves.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - anchor: The line the comment hangs off.
    /// - Returns: The drafted text, or why there is none.
    func draftInlineComment(
        for detail: PullRequestDetail,
        anchor: InlineCommentAnchor
    ) async -> IntelligenceOutcome<String> {
        guard isEnabled else { return .disabled }
        // Settled before a tier is picked, because the answer is the same for all of them: with
        // no patch there is no excerpt, and a comment drafted from a file name alone would be
        // invention. GitHub sends no patch for binaries and for diffs it truncated.
        guard detail.files.first(where: { $0.path == anchor.path })?.hasPatch == true else {
            return .unavailable(
                String(
                    localized: "GitHub sent no diff for this file, so there is nothing to draft a comment from."
                )
            )
        }
        return await run { provider, budget in
            try await provider.draftInlineComment(
                InlineCommentDraftBuilder.build(detail: detail, anchor: anchor, budget: budget)
            )
        }
    }

    /// Runs an operation that needs a digest, building one per tier's budget.
    private func run<Value: Sendable & Hashable>(
        detail: PullRequestDetail,
        operation: @Sendable (any IntelligenceProvider, PullRequestDigest) async throws -> Value
    ) async -> IntelligenceOutcome<Value> {
        await run { provider, budget in
            try await operation(provider, PullRequestDigestBuilder.build(from: detail, budget: budget))
        }
    }

    /// The degradation ladder itself: cloud, then on-device, then a reason.
    ///
    /// The operation is handed the tier's token budget rather than a finished prompt, because that
    /// is the one thing that genuinely differs between the tiers — the cloud tier sees a large
    /// context, the on-device tier a small one, and every request type caps itself against the
    /// budget it is given.
    private func run<Value: Sendable & Hashable>(
        operation: @Sendable (any IntelligenceProvider, TokenBudget) async throws -> Value
    ) async -> IntelligenceOutcome<Value> {
        guard isEnabled else { return .disabled }

        var lastFailure: String?

        if let cloud = cloudProvider {
            do {
                return .value(
                    IntelligenceOutput(
                        kind: cloud.kind,
                        value: try await operation(cloud, AnthropicProvider.budget)
                    )
                )
            } catch {
                lastFailure = describe(error)
            }
        }

        let unavailabilityReason = tiers.onDeviceUnavailabilityReason()
        if unavailabilityReason == nil {
            let onDevice = tiers.onDevice()
            do {
                return .value(
                    IntelligenceOutput(
                        kind: onDevice.kind,
                        value: try await operation(onDevice, OnDeviceProvider.budget)
                    )
                )
            } catch {
                lastFailure = describe(error)
            }
        } else if lastFailure == nil {
            return .unavailable(
                unavailabilityReason
                    ?? String(localized: "No intelligence provider is available.")
            )
        }

        return .failed(lastFailure ?? String(localized: "No intelligence provider is available."))
    }

    private func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
