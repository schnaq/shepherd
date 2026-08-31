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

/// Tier 2: Apple's on-device Foundation Model (ADR 0007).
///
/// **This is the only file in the app that imports `FoundationModels`.** Everything the rest
/// of the app sees is ``IntelligenceProvider``, so a change in that framework can only break
/// this file.
///
/// The model is guarded twice: `SystemLanguageModel.default.availability` must report
/// `.available` (Apple Intelligence can be off, the device can be ineligible, the assets can
/// still be downloading), and the digest must fit the small token budget — ADR 0007 makes the
/// context ceiling a hard error rather than a silent truncation.
struct OnDeviceProvider: IntelligenceProvider {
    /// The token budget digests are built with for this tier.
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
        // The case patterns below are exactly the ones Apple documents for this enum; naming
        // the nested `UnavailableReason` type is avoided on purpose so this file depends on as
        // little of the framework's spelling as possible.
        switch SystemLanguageModel.default.availability {
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

    func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary {
        try OnDeviceProvider.preflight(digest)
        let session = LanguageModelSession(instructions: IntelligencePrompt.summaryInstructions)
        let prompt = IntelligencePrompt.body(for: digest)
        let response = try await session.respond(to: prompt, generating: OnDeviceSummary.self)
        let generated = response.content
        return PRSummary(
            overview: generated.overview.trimmingCharacters(in: .whitespacesAndNewlines),
            riskNotes: generated.riskNotes
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint] {
        try OnDeviceProvider.preflight(digest)
        let knownPaths = Set(digest.files.map(\.path))
        let session = LanguageModelSession(instructions: IntelligencePrompt.focusInstructions)
        let prompt = IntelligencePrompt.body(for: digest)
        let response = try await session.respond(to: prompt, generating: OnDeviceFocus.self)
        return response.content.hints
            .compactMap { hint -> FocusHint? in
                let file = hint.file.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = hint.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                // Drop hallucinated paths: a hint about a file that is not in the pull request
                // is worse than no hint at all.
                guard knownPaths.contains(file), !reason.isEmpty else { return nil }
                return FocusHint(file: file, reason: reason)
            }
    }

    /// Availability + budget check, run before any session is created.
    private static func preflight(_ digest: PullRequestDigest) throws {
        if let reason = unavailabilityReason() {
            throw IntelligenceError.unavailable(reason)
        }
        guard digest.approximateTokenCount <= budget.maxTokens else {
            throw IntelligenceError.digestTooLarge(
                tokens: digest.approximateTokenCount,
                limit: budget.maxTokens
            )
        }
    }
}
