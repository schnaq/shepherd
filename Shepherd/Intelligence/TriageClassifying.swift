import Foundation
import ShepherdCore

/// Why the structured-triage classifier cannot answer, or that it can.
///
/// A value rather than a `Bool`, for ``EmbeddingAvailability``'s reason: "the inbox is showing
/// risk hints instead of verdicts on this Mac" is a sentence the Settings card has to be able to
/// finish, and a missing chip with no explanation reads as a bug.
enum TriageClassifierAvailability: Sendable, Equatable {
    /// The model is there and Apple Intelligence is on.
    case available
    /// It is not, with a reason to show the user — the model's own words where there are any.
    case unavailable(String)

    /// The reason, when there is one.
    var reason: String? {
        switch self {
        case .available: return nil
        case .unavailable(let reason): return reason
        }
    }
}

/// How one pull request becomes a ``ShepherdCore/TriageVerdict`` (plan §3.A).
///
/// The seam the whole feature is tested through — ``EmbeddingProviding`` / ``AutoMergeWriting``
/// once more. In the app it is ``OnDeviceTriageClassifier``; in `ShepherdTests` it is a stub that
/// returns verdicts a test wrote by hand, so the coordinator's rules — when a verdict is spent,
/// what invalidates one, what the disabled paths do — are asserted without Apple's model being
/// present or its answers being stable.
///
/// **There is deliberately no cloud implementation of this protocol, and there may not be one.**
/// Classification runs unattended, over every pull request in the inbox, in a background pass
/// nobody clicked a button for. ADR 0007's tier-3 argument is that a BYOK endpoint is acceptable
/// *because* a human asked for one pull request and can see the answer; a bulk pass is none of
/// that, and it would ship the whole inbox to a third party as a side effect of syncing. So this
/// is a rule of the design rather than a setting: nothing in the triage feature takes an
/// `IntelligenceRouter`, a base URL or a key, and when tier 2 cannot answer the inbox falls back
/// to the tier-1 risk hints (ADR 0023).
protocol TriageClassifying: Sendable {
    /// Identifies the model, so a verdict is never presented as a different model's opinion.
    ///
    /// Stored beside every verdict (``ShepherdCore/TriageVerdictEntry/modelIdentifier``).
    /// Changing this string invalidates every stored verdict by itself, which is what makes an
    /// OS model update a re-classification rather than a silent mixture.
    var modelIdentifier: String { get }

    /// Whether the model can answer, and why not when it cannot.
    func availability() async -> TriageClassifierAvailability

    /// Classifies one pull request.
    /// - Parameter input: The search document plus the tier-1 risk hints, already budgeted.
    /// - Returns: The verdict.
    /// - Throws: ``IntelligenceError`` when the model is unavailable, declined the content, or
    ///   the input did not fit the context window.
    func classify(_ input: TriageInput) async throws -> TriageVerdict
}
