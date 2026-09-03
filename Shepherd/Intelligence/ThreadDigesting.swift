import Foundation
import ShepherdCore

/// Why a review thread cannot be summarised on this Mac, or that it can.
///
/// A value rather than a `Bool`, for ``TriageClassifierAvailability``'s reason: the answer decides
/// whether a *button* exists, and when the answer is no there has to be a sentence available for
/// anyone who asks why. The button itself is simply absent — a disabled *Summarise* with a
/// tooltip would be a control that promises a feature this Mac does not have.
enum ThreadDigesterAvailability: Sendable, Equatable {
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

/// How one review thread becomes a ``ShepherdCore/ThreadDigest`` (plan §3.G).
///
/// The seam the whole feature is tested through — ``TriageClassifying`` / ``EmbeddingProviding``
/// once more. In the app it is ``OnDeviceThreadDigester``; in `ShepherdTests` it is a fake that
/// returns digests a test wrote by hand, so the coordinator's rules — what invalidates a cached
/// digest, what two overlapping clicks cost, what the failure line says — are asserted without
/// Apple's model being present or its answers being stable.
///
/// **There is deliberately no cloud implementation of this protocol, and there may not be one.**
/// The input is *colleagues' comments*. ADR 0007's tier-3 argument is that a BYOK endpoint is
/// acceptable because the user chose it and can see what they asked for; the people in a review
/// thread chose none of that, and there is no version of "your colleague's sentence reached the
/// endpoint you configured" that is an informed choice by the person who wrote the sentence. That
/// is ADR 0020's argument about translation, and it applies here word for word — which is why
/// this is a rule of the design rather than a setting: nothing in the digest feature takes an
/// `IntelligenceRouter`, a base URL or a key, no request type for it exists on
/// ``IntelligenceProvider``, and when tier 2 cannot answer the button is not drawn.
protocol ThreadDigesting: Sendable {
    /// Whether a thread can be summarised, and why not when it cannot.
    ///
    /// Asked once per app run by the coordinator: whether this Mac has the model is a property of
    /// the Mac, not of the thread.
    func availability() async -> ThreadDigesterAvailability

    /// Summarises one thread.
    /// - Parameter request: The thread's comments, already budgeted and already counted.
    /// - Returns: The digest together with how much of the thread it covers.
    /// - Throws: ``IntelligenceError`` when the model is unavailable, declined the content, or
    ///   the comments did not fit the context window.
    func digest(_ request: ThreadDigestRequest) async throws -> ThreadDigestResult
}
