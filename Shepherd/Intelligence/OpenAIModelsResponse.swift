import Foundation

/// The body of `GET {base}/models` on an OpenAI-compatible endpoint.
///
/// A pure value type with no networking in it: the part that actually varies between gateways
/// is the payload, so it is parsed here and unit-tested against fixtures, while
/// ``OpenAICompatibleProvider/availableModels()`` stays a thin request around it.
///
/// Parsing is deliberately lenient in the same way ``IntelligenceJSON`` is: unknown fields
/// (`object`, `created`, `owned_by`, per-gateway extras) are ignored and a single entry without
/// an `id` is dropped rather than failing the whole list.
struct OpenAIModelsResponse: Sendable, Hashable, Decodable {
    /// One entry of the `data` array.
    struct Model: Sendable, Hashable, Decodable {
        /// The id to send as `model` in a completion request; `nil` when the entry omitted it.
        var id: String?
    }

    /// The listed models, in the order the endpoint returned them.
    var data: [Model]

    /// The usable model ids: trimmed, blanks dropped, duplicates removed, order preserved.
    ///
    /// The endpoint's own order is kept — gateways tend to list their recommended models first,
    /// and re-sorting would throw that away.
    var modelIDs: [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for model in data {
            let id = (model.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    /// Parses a response body into the model ids it offers.
    /// - Parameter data: The raw response body.
    /// - Returns: The offered model ids, never empty.
    /// - Throws: ``IntelligenceError/malformedResponse`` when the body is not the documented
    ///   shape, ``IntelligenceError/noModelsListed`` when it is but lists nothing usable.
    static func modelIDs(in data: Data) throws -> [String] {
        guard let decoded = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data) else {
            throw IntelligenceError.malformedResponse
        }
        let ids = decoded.modelIDs
        guard !ids.isEmpty else { throw IntelligenceError.noModelsListed }
        return ids
    }
}
