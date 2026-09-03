import Foundation
import ShepherdCore

/// Why the description cannot be read by the model on this Mac, or that it can.
///
/// A value rather than a `Bool`, for ``ThreadDigesterAvailability``'s reason: the answer decides
/// whether a *caption* appears under the claims card, and when the answer is no there has to be a
/// sentence available for anyone who asks why. The card itself simply shows nothing extra — a
/// "the model could not read this" line on a card that is already complete without one would be
/// an apology for a feature the reviewer never asked for (ADR 0026: tier 1 is complete at tier 1).
enum ClaimExtractorAvailability: Sendable, Equatable {
    /// The model is there and Apple Intelligence is on.
    case available
    /// It is not, with the model's own words for why.
    case unavailable(String)

    /// The reason, when there is one.
    var reason: String? {
        switch self {
        case .available: return nil
        case .unavailable(let reason): return reason
        }
    }
}

/// How a pull-request description becomes a ``ShepherdCore/ClaimList`` (ADR 0026's tier-2
/// amendment, plan §2.A).
///
/// The seam the whole tier-2 half of the claims card is tested through — ``ThreadDigesting`` /
/// ``TriageClassifying`` once more. In the app it is ``OnDeviceClaimExtractor``; in
/// `ShepherdTests` it is a fake that returns claim lists a test wrote by hand, so the rules that
/// matter — a model claim is added, a duplicate is dropped, an unavailable model changes nothing,
/// the pass is spent once per pull request — are asserted without Apple's model being present or
/// its answers being stable.
///
/// **There is deliberately no cloud implementation of this protocol, and there may not be one.**
/// The input is the *description a colleague wrote*, and the card it feeds opens on every pull
/// request the reviewer looks at. ADR 0007's tier-3 argument is that a BYOK endpoint is acceptable
/// because the user configured it and can see the one answer they asked for; the person who wrote
/// the description configured nothing. That is ADR 0020's argument about translating a comment and
/// ADR 0007's about summarising a thread, and ADR 0026 states it for this card in as many words.
/// So the rule is expressed as unreachability rather than as a setting: nothing in the claims
/// feature takes an `IntelligenceRouter`, a base URL or a key, and no request type for claim
/// extraction exists on ``IntelligenceProvider``.
///
/// **And the pass is attended.** It runs when the reviewer *expands* the card and never in a
/// sweep — the expansion is the click, which is what makes this tier 2 at all rather than a model
/// call on every pull request that scrolls past.
protocol ClaimExtracting: Sendable {
    /// Whether the description can be read by the model on this Mac, and why not when it cannot.
    ///
    /// Asked once per app run by the caller: whether this Mac has the model is a property of the
    /// Mac, not of the pull request.
    func availability() async -> ClaimExtractorAvailability

    /// Reads the claims the patterns may have missed out of one description.
    /// - Parameter body: The pull request's description, as Markdown source.
    /// - Returns: What the model read, which may be empty — "the patterns already had
    ///   everything" is a real answer.
    /// - Throws: ``IntelligenceError`` when the model is unavailable, declined the content, or
    ///   the description did not fit the context window.
    func extract(from body: String) async throws -> ClaimList
}
