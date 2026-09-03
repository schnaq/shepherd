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
///
/// **Two optional blocks are kept rather than ignored** (plan §3.K). A gateway in front of
/// several operators can say, per model, where it runs and what it costs — and those are the two
/// facts a reviewer picking a model for data-residency reasons is actually choosing between. They
/// are decoded as optionals with every field inside them optional too, so the documented OpenAI
/// shape (four fields, none of these) decodes to exactly what it decoded to before: `nil`. Nothing
/// in here names an endpoint, so no preset gains a code path.
struct OpenAIModelsResponse: Sendable, Hashable, Decodable {
    /// What a gateway publishes about where a model runs and who runs it.
    ///
    /// Every field is optional, including the ones the gateway documents as required. This is the
    /// tier whose premise is "whatever speaks the shape": a half-filled block is worth showing
    /// (a country alone is already an answer) and refusing to decode one would take the whole
    /// model list down over a badge.
    struct Sovereignty: Sendable, Hashable, Decodable {
        /// One published attestation about the operator.
        struct Certification: Sendable, Hashable, Decodable {
            /// The certification type, e.g. `iso27001`.
            var type: String?
            /// What it covers.
            var scope: String?
            /// Where the evidence is published.
            var evidenceURL: String?

            private enum CodingKeys: String, CodingKey {
                case type
                case scope
                case evidenceURL = "evidence_url"
            }
        }

        /// ISO 3166-1 alpha-2 country the deployment runs in.
        var hostingCountry: String?
        /// Where the operating company is owned.
        var ownership: String?
        /// Whether the operator stores neither prompt nor completion.
        var zeroRetention: Bool?
        /// The gateway's own sovereignty tier label.
        var tier: String?
        /// A free-text caveat the gateway attaches.
        var note: String?
        /// The attestations the operator published. Empty when it published none.
        var certifications: [Certification]?

        private enum CodingKeys: String, CodingKey {
            case hostingCountry = "hosting_country"
            case ownership
            case zeroRetention = "zero_retention"
            case tier
            case note
            case certifications
        }

        /// Whether the block said anything at all.
        ///
        /// A gateway that sends `"sovereignty": {}` has published nothing, and a badge with
        /// nothing in it is worse than no badge.
        var isEmpty: Bool {
            hostingCountry == nil && ownership == nil && zeroRetention == nil
                && tier == nil && note == nil && (certifications ?? []).isEmpty
        }

        /// The certification types the operator published, trimmed and with blanks dropped.
        var certificationTypes: [String] {
            (certifications ?? []).compactMap { certification in
                let type = (certification.type ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return type.isEmpty ? nil : type
            }
        }

        /// The short line a picker shows beside a model name, e.g. `FR · zero retention · eu`.
        ///
        /// Three facts at most and in this order, because that is the order they are asked in:
        /// *where does this run*, *does it keep my prompt*, *what does the gateway call that*.
        /// The note and the certifications are deliberately not in it — a picker row is one
        /// glance, and a paragraph in it would be unreadable.
        /// - Returns: The badge text, or `nil` when the block published nothing to show.
        var badge: String? {
            var parts: [String] = []
            if let country = hostingCountry?.trimmingCharacters(in: .whitespacesAndNewlines),
               !country.isEmpty {
                parts.append(country.uppercased())
            }
            if zeroRetention == true { parts.append(String(localized: "zero retention")) }
            if let tier = tier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty {
                parts.append(tier)
            }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: " · ")
        }
    }

    /// What a gateway charges for a model, in the unit it states.
    ///
    /// The unit travels with the number on purpose: a client that assumed a currency per token
    /// would be wrong by orders of magnitude, so the numbers are only ever shown beside the
    /// gateway's own `unit` string, and Shepherd does no arithmetic on them at all.
    struct Pricing: Sendable, Hashable, Decodable {
        /// The currency the numbers are in.
        var currency: String?
        /// What one number counts, e.g. `micro_eur_per_million_tokens`.
        var unit: String?
        /// The input price in that unit.
        var input: Int?
        /// The output price in that unit, when the model produces completion tokens.
        var output: Int?
    }

    /// One entry of the `data` array.
    struct Model: Sendable, Hashable, Decodable {
        /// The id to send as `model` in a completion request; `nil` when the entry omitted it.
        var id: String?
        /// The gateway's own display name, when it published one.
        var displayName: String?
        /// Where this model runs and who runs it, when the gateway published it.
        var sovereignty: Sovereignty?
        /// What the gateway charges, when it published it.
        var pricing: Pricing?

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case sovereignty
            case pricing
        }

        /// Creates an entry.
        ///
        /// Spelled out rather than left to the memberwise synthesis because the id-only form is
        /// a real case with a real caller: ``ModelListing/availableModelEntries()``'s default
        /// implementation lifts a plain `[String]` into entries, and every other field being
        /// absent is precisely what "the endpoint published nothing else" means.
        /// - Parameters:
        ///   - id: The model id.
        ///   - displayName: The gateway's display name, when there is one.
        ///   - sovereignty: Where it runs, when the gateway published it.
        ///   - pricing: What it costs, when the gateway published it.
        init(
            id: String?,
            displayName: String? = nil,
            sovereignty: Sovereignty? = nil,
            pricing: Pricing? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.sovereignty = sovereignty
            self.pricing = pricing
        }

        /// Decodes an entry, letting a malformed *extra* cost only that extra.
        ///
        /// Every field is read through `try?`, which is the same tolerance the sync document's
        /// decoder applies for the same reason: this is the tier whose premise is "whatever
        /// speaks the shape", and a gateway that publishes `"sovereignty": "eu"` — a string where
        /// an object was documented — must cost the *badge*, not the model list. Without this,
        /// one bad entry would fail the array, the array would fail the response, and Settings
        /// would fall back to the free-text field over a decoration.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil
            displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
            sovereignty = (
                try? container.decodeIfPresent(Sovereignty.self, forKey: .sovereignty)
            ) ?? nil
            pricing = (try? container.decodeIfPresent(Pricing.self, forKey: .pricing)) ?? nil
        }

        /// The trimmed id, or `nil` when the entry carries none.
        var usableID: String? {
            let id = (self.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        }

        /// The badge to show beside this model, or `nil` when there is nothing to show.
        var sovereigntyBadge: String? {
            guard let sovereignty, !sovereignty.isEmpty else { return nil }
            return sovereignty.badge
        }
    }

    /// The listed models, in the order the endpoint returned them.
    var data: [Model]

    /// The usable entries: blanks dropped, duplicates removed, order preserved.
    ///
    /// The endpoint's own order is kept — gateways tend to list their recommended models first,
    /// and re-sorting would throw that away.
    var models: [Model] {
        var seen = Set<String>()
        var entries: [Model] = []
        for model in data {
            guard let id = model.usableID, seen.insert(id).inserted else { continue }
            var entry = model
            entry.id = id
            entries.append(entry)
        }
        return entries
    }

    /// The usable model ids: trimmed, blanks dropped, duplicates removed, order preserved.
    var modelIDs: [String] { models.compactMap(\.id) }

    /// Parses a response body into the entries it offers.
    ///
    /// The entry point ``modelIDs(in:)`` is written in terms of, so the tolerance rules —
    /// what counts as usable, what order things come back in — exist exactly once.
    /// - Parameter data: The raw response body.
    /// - Returns: The offered entries, never empty.
    /// - Throws: ``IntelligenceError/malformedResponse`` when the body is not the documented
    ///   shape, ``IntelligenceError/noModelsListed`` when it is but lists nothing usable.
    static func models(in data: Data) throws -> [Model] {
        guard let decoded = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data) else {
            throw IntelligenceError.malformedResponse
        }
        let models = decoded.models
        guard !models.isEmpty else { throw IntelligenceError.noModelsListed }
        return models
    }

    /// Parses a response body into the model ids it offers.
    /// - Parameter data: The raw response body.
    /// - Returns: The offered model ids, never empty.
    /// - Throws: ``IntelligenceError/malformedResponse`` when the body is not the documented
    ///   shape, ``IntelligenceError/noModelsListed`` when it is but lists nothing usable.
    static func modelIDs(in data: Data) throws -> [String] {
        try models(in: data).compactMap(\.id)
    }
}
