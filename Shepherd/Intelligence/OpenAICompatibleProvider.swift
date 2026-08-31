import Foundation
import ShepherdCore

/// Tier 3b: any endpoint that speaks the OpenAI chat-completions shape (ADR 0007).
///
/// This is the escape hatch for data residency and local models: EU-hosted providers, an
/// on-prem gateway, Ollama or LM Studio on `localhost`. Shepherd only needs a base URL, a
/// model name and a key.
struct OpenAICompatibleProvider: IntelligenceProvider {
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

    /// Builds `{base}/chat/completions`, tolerating a trailing slash.
    /// - Parameter base: The configured base URL.
    /// - Returns: The endpoint URL, or `nil` when the base is not a usable absolute URL.
    static func completionsURL(base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://"),
              let url = URL(string: trimmed + "/chat/completions")
        else { return nil }
        return url
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
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: model,
                maxTokens: maxTokens,
                messages: [
                    RequestBody.Message(role: "system", content: system),
                    RequestBody.Message(role: "user", content: user),
                ]
            )
        )

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
