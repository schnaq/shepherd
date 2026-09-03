import Foundation
import ShepherdCore

/// Who actually ran the model for one answer, when the endpoint volunteered it.
///
/// **A generic hook, not an endpoint's feature.** Tier 3b is "whatever speaks the
/// chat-completions shape" (ADR 0007), and one thing a gateway in front of several operators can
/// say that a single-operator API cannot is *which* operator served this request and from which
/// deployment. Two response headers carry that, and Shepherd reads them the way it reads
/// everything else about this tier: as an optional extension any endpoint may fill in. An
/// endpoint that sends neither header produces `nil` and the caption is exactly what it was
/// before — there is no branch on a base URL anywhere in the parse, so no preset is a code path
/// (ADR 0007's 2026-09-03 amendment).
///
/// The value exists rather than a bare `String` because the two headers mean different things:
/// the operator is the *sovereignty* answer ("this ran at scaleway"), while the deployment id is
/// the *reproducibility* answer (sending it back as `model` pins this exact deployment). A caption
/// wants the first and may show the second; collapsing them into one string on arrival would
/// throw away which was which.
struct ServedBy: Sendable, Hashable {
    /// The header naming the operator that ran the weights.
    static let operatorHeader = "Konduit-Provider"
    /// The header naming the exact deployment.
    static let deploymentHeader = "Konduit-Deployment"

    /// The operator that ran the weights, e.g. `scaleway`. Never empty.
    var operatorName: String
    /// The exact deployment id, e.g. `scaleway/mistral-small-3.2@fp8`, when the endpoint said.
    var deployment: String?

    /// Creates a served-by value.
    /// - Parameters:
    ///   - operatorName: The operator that ran the weights.
    ///   - deployment: The deployment id, when there is one.
    init(operatorName: String, deployment: String? = nil) {
        self.operatorName = operatorName
        self.deployment = deployment
    }

    /// The one short phrase a caption appends, e.g. `konduit · scaleway`.
    ///
    /// The deployment id is deliberately **not** in it. It is long, it changes with a variant,
    /// and a caption under a reviewer's draft is read in one glance — the operator is the part of
    /// the answer that means something to a person, and the id is carried for the code that may
    /// later pin it.
    var caption: String { operatorName }

    /// Reads the two optional headers, tolerating everything about them but their names.
    ///
    /// Header field names are case-insensitive per RFC 9110 and `URLSession` does not promise a
    /// spelling, so the lookup is too. An operator that arrives blank is the same as an absent
    /// one: a caption reading "served by" with nothing after it would be worse than no caption.
    /// A deployment without an operator yields `nil` as well — the deployment id alone is not a
    /// sentence a reviewer can read, and inventing an operator name from it would be a guess.
    /// - Parameter headers: The response headers, keyed by field name in any spelling.
    /// - Returns: The value, or `nil` when the response said nothing about who served it.
    static func parse(headers: [String: String]) -> ServedBy? {
        guard let operatorName = ServedBy.value(of: operatorHeader, in: headers) else {
            return nil
        }
        return ServedBy(
            operatorName: operatorName,
            deployment: ServedBy.value(of: deploymentHeader, in: headers)
        )
    }

    /// One header's trimmed value, matched without regard to case, or `nil` when it is absent
    /// or blank.
    private static func value(of field: String, in headers: [String: String]) -> String? {
        for (key, value) in headers where key.caseInsensitiveCompare(field) == .orderedSame {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// What an endpoint said about one request beyond the answer itself.
///
/// A tiny actor rather than two more fields on a request type, because both facts it holds are
/// written by the code doing the HTTP and read by code that is already past it: the served-by
/// headers arrive **before** the first server-sent event (so the router can settle the caption
/// before the reviewer sees a character), and the usage chunk arrives **after** the last one (so
/// it can only ever be read once the stream finished). One `Sendable` box handed down and read
/// back keeps both out of the stream's element type, which stays cumulative `String` — the
/// contract every drafting surface is built on (ADR 0007's 2026-09-02 amendment).
///
/// Nothing is printed and nothing is persisted: this is per-request state that dies with the
/// request.
actor IntelligenceEndpointReport {
    /// Who ran the model, once the response headers were read.
    private(set) var servedBy: ServedBy?
    /// What the endpoint said the answer cost, once the stream finished.
    private(set) var usage: StreamUsage?

    /// Creates an empty report.
    init() {}

    /// Records who served the request. A `nil` is ignored rather than clearing what is there:
    /// a retried request whose second response omitted the headers has not un-served the answer.
    /// - Parameter servedBy: The parsed headers, when there were any.
    func record(servedBy: ServedBy?) {
        guard let servedBy else { return }
        self.servedBy = servedBy
    }

    /// Records what the endpoint said the answer cost.
    /// - Parameter usage: The final usage chunk's counts.
    func record(usage: StreamUsage?) {
        guard let usage else { return }
        self.usage = usage
    }
}
