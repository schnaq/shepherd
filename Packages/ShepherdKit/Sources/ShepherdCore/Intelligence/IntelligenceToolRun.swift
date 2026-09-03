import Foundation

/// A tool-calling answer: the value the model arrived at, plus how it got there.
///
/// The pair is the unit every provider returns from a tool loop, and it is a *pair* rather than
/// two return values because the two are only meaningful together: a diagnosis with no trace
/// cannot be checked ("which log did it read?"), and a trace with no diagnosis is a list of reads
/// nobody asked for. Keeping them in one value means the router, the outcome type and the card
/// each carry one thing.
///
/// Generic over the value so the two tool-calling features planned on this contract
/// (`docs/plans/apple-intelligence-v2.md` §3.F, and whatever follows it) do not each need their
/// own pair type. The constraints are what the layers above already demand: `Sendable` because a
/// provider answers from a background task, `Hashable` because
/// `IntelligenceOutcome`/`IntelligenceOutput` in the app target are, and `Codable` because a
/// generated value's whole point is that it round-trips through the JSON contract — an
/// unconditional constraint rather than a conditional conformance, since a run whose value cannot
/// be coded is a run no provider could have produced.
public struct IntelligenceToolRun<Value: Sendable & Hashable & Codable>: Sendable, Hashable, Codable {
    /// What the model answered, decoded into the twin the UI sees.
    public var value: Value
    /// Every tool hop the answer took, in order. Empty when the model answered without reading
    /// anything, which is a legitimate answer and not an error.
    public var trace: IntelligenceTrace

    /// Creates a run.
    /// - Parameters:
    ///   - value: The decoded answer.
    ///   - trace: The hops it took. Defaults to none.
    public init(value: Value, trace: IntelligenceTrace = IntelligenceTrace()) {
        self.value = value
        self.trace = trace
    }

    /// How many tools ran.
    public var hopCount: Int { trace.count }

    private enum CodingKeys: String, CodingKey {
        case value
        case trace
    }
}
