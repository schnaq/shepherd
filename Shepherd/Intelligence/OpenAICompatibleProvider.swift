import Foundation
import ShepherdCore

/// An endpoint that can name the models it serves.
///
/// The seam exists so the Settings flow around model discovery — gate, preselection, fallback to
/// the free-text field — is unit-testable without a network; the only production conformance is
/// ``OpenAICompatibleProvider``.
protocol ModelListing: Sendable {
    /// The model ids the endpoint offers, in its own order.
    /// - Returns: The offered model ids, never empty.
    /// - Throws: ``IntelligenceError`` when the list cannot be obtained.
    func availableModels() async throws -> [String]
}

/// Tier 3b: any endpoint that speaks the OpenAI chat-completions shape (ADR 0007).
///
/// This is the escape hatch for data residency and local models: EU-hosted providers, an
/// on-prem gateway, Ollama or LM Studio on `localhost`. Shepherd only needs a base URL, a
/// model name and a key.
struct OpenAICompatibleProvider: IntelligenceProvider, ModelListing {
    /// The token budget digests are built with for this tier.
    static let budget = TokenBudget.cloud

    /// The base URL, e.g. `https://api.example.eu/v1`.
    let baseURL: String
    /// The model name to send.
    let model: String
    /// The bearer token. May be empty for a local server that does not check it.
    let apiKey: String
    /// How many tokens the answer may use.
    var maxTokens: Int = 1_024

    var kind: IntelligenceKind { .openAICompatible }

    var isAvailable: Bool {
        get async { OpenAICompatibleProvider.completionsURL(base: baseURL) != nil && !model.isEmpty }
    }

    /// Creates a provider.
    /// - Parameters:
    ///   - baseURL: The endpoint's base URL.
    ///   - model: The model name.
    ///   - apiKey: The bearer token.
    init(baseURL: String, model: String, apiKey: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary {
        let text = try await complete(
            system: IntelligencePrompt.summaryInstructions + "\n" + IntelligencePrompt.summaryJSONContract,
            user: IntelligencePrompt.body(for: digest)
        )
        return IntelligenceJSON.summary(from: text)
    }

    func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint] {
        let text = try await complete(
            system: IntelligencePrompt.focusInstructions + "\n" + IntelligencePrompt.focusJSONContract,
            user: IntelligencePrompt.body(for: digest)
        )
        let knownPaths = Set(digest.files.map(\.path))
        return IntelligenceJSON.hints(from: text).filter { knownPaths.contains($0.file) }
    }

    func draftReviewSummary(_ request: ReviewSummaryDraftRequest) async throws -> String {
        let text = try await complete(
            system: IntelligencePrompt.draftSummaryInstructions + "\n"
                + IntelligencePrompt.draftJSONContract,
            user: IntelligencePrompt.body(for: request)
        )
        return try IntelligenceJSON.draft(from: text)
    }

    func draftInlineComment(_ request: InlineCommentDraftRequest) async throws -> String {
        let text = try await complete(
            system: IntelligencePrompt.draftInlineCommentInstructions + "\n"
                + IntelligencePrompt.draftJSONContract,
            user: IntelligencePrompt.body(for: request)
        )
        return try IntelligenceJSON.draft(from: text)
    }

    /// Cleans up a configured base URL: surrounding whitespace and trailing slashes go, and
    /// anything that is not an absolute `http(s)` URL is rejected.
    ///
    /// One place, because both the completions and the models endpoint are built from it and a
    /// base URL that is good enough for one must be good enough for the other.
    /// - Parameter base: The configured base URL, as stored or typed.
    /// - Returns: The normalised base, or `nil` when it is not usable.
    static func normalizedBase(_ base: String) -> String? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://")
        else { return nil }
        return trimmed
    }

    /// Builds `{base}/chat/completions`, tolerating a trailing slash.
    /// - Parameter base: The configured base URL.
    /// - Returns: The endpoint URL, or `nil` when the base is not a usable absolute URL.
    static func completionsURL(base: String) -> URL? {
        guard let normalized = normalizedBase(base),
              let url = URL(string: normalized + "/chat/completions")
        else { return nil }
        return url
    }

    /// Builds `{base}/models`, the OpenAI-shaped model list.
    /// - Parameter base: The configured base URL.
    /// - Returns: The endpoint URL, or `nil` when the base is not a usable absolute URL.
    static func modelsURL(base: String) -> URL? {
        guard let normalized = normalizedBase(base),
              let url = URL(string: normalized + "/models")
        else { return nil }
        return url
    }

    /// Asks the endpoint which models it offers.
    ///
    /// Discovery is best-effort and never required: Settings falls back to the free-text model
    /// field whenever this throws, so an endpoint without a `/models` route stays usable.
    /// - Returns: The offered model ids, in the endpoint's own order.
    /// - Throws: ``IntelligenceError`` when the endpoint is unreachable, refuses the key, or
    ///   answers with something other than the documented list shape.
    func availableModels() async throws -> [String] {
        guard let url = OpenAICompatibleProvider.modelsURL(base: baseURL) else {
            throw IntelligenceError.notConfigured("base URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw IntelligenceError.http(
                status: status,
                message: OpenAICompatibleProvider.errorMessage(in: data)
            )
        }
        return try OpenAIModelsResponse.modelIDs(in: data)
    }

    /// The JSON body one chat-completions request sends.
    ///
    /// Extracted for the same reason ``ModelListing`` exists: the shape that has to be right —
    /// the `max_tokens` key, the system message first and the user message second — is then
    /// unit-testable without a network, and the drafting prompts (ADR 0007 amendment) can be
    /// asserted on the wire rather than only in the string constants.
    /// - Parameters:
    ///   - system: The system message.
    ///   - user: The user message.
    /// - Returns: The encoded request body.
    func completionRequestBody(system: String, user: String) throws -> Data {
        try JSONEncoder().encode(
            RequestBody(
                model: model,
                maxTokens: maxTokens,
                messages: [
                    RequestBody.Message(role: "system", content: system),
                    RequestBody.Message(role: "user", content: user),
                ]
            )
        )
    }

    /// Sends one non-streaming chat-completions request.
    /// - Parameters:
    ///   - system: The system message.
    ///   - user: The user message.
    /// - Returns: The answer text.
    func complete(system: String, user: String) async throws -> String {
        guard let url = OpenAICompatibleProvider.completionsURL(base: baseURL) else {
            throw IntelligenceError.notConfigured("base URL")
        }
        guard !model.isEmpty else { throw IntelligenceError.notConfigured("model name") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try completionRequestBody(system: system, user: user)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw IntelligenceError.http(
                status: status,
                message: OpenAICompatibleProvider.errorMessage(in: data)
            )
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let text = decoded.choices.first?.message?.content?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw IntelligenceError.malformedResponse
        }
        return text
    }

    /// Best-effort extraction of the `{"error": {"message": …}}` shape most servers use.
    static func errorMessage(in data: Data) -> String {
        struct Envelope: Decodable {
            struct Payload: Decodable { var message: String? }
            var error: Payload?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           let message = envelope.error?.message, !message.isEmpty {
            return message
        }
        let raw = String(decoding: data, as: UTF8.self)
        return raw.isEmpty ? String(localized: "no details") : String(raw.prefix(240))
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }
        var model: String
        var maxTokens: Int
        var messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case messages
        }
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var role: String?
                var content: String?
            }
            var message: Message?
        }
        var choices: [Choice]
    }
}
