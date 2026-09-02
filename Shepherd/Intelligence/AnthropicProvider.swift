import Foundation
import ShepherdCore

/// Tier 3a: the Anthropic Messages API with the user's own key (ADR 0007).
///
/// The request goes straight from the app to `api.anthropic.com` — no proxy, no middleman —
/// and the key comes from the Keychain, never from `UserDefaults` or the database.
struct AnthropicProvider: IntelligenceProvider {
    /// The token budget digests are built with for this tier.
    static let budget = TokenBudget.cloud

    /// The one endpoint this tier talks to (`CONTRIBUTING.md`'s host list).
    ///
    /// Named once so the streaming and the non-streaming path cannot drift onto two hosts.
    static let messagesURL = "https://api.anthropic.com/v1/messages"

    /// The default model: cheap, fast, and big enough for a whole pull request.
    static let defaultModel = "claude-haiku-4-5"

    /// The user's API key.
    let apiKey: String
    /// The model id to call.
    let model: String
    /// How many tokens the answer may use.
    var maxTokens: Int = 1_024

    var kind: IntelligenceKind { .anthropic }

    var isAvailable: Bool {
        get async { !apiKey.isEmpty && !model.isEmpty }
    }

    /// Creates a provider.
    /// - Parameters:
    ///   - apiKey: The user's Anthropic key.
    ///   - model: The model id.
    init(apiKey: String, model: String = AnthropicProvider.defaultModel) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? AnthropicProvider.defaultModel : model
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

    func streamReviewSummaryDraft(
        _ request: ReviewSummaryDraftRequest
    ) -> AsyncThrowingStream<String, Error> {
        streamDraft(
            system: IntelligencePrompt.draftSummaryInstructions + "\n"
                + IntelligencePrompt.draftPlainTextContract,
            user: IntelligencePrompt.body(for: request)
        )
    }

    func streamInlineCommentDraft(
        _ request: InlineCommentDraftRequest
    ) -> AsyncThrowingStream<String, Error> {
        streamDraft(
            system: IntelligencePrompt.draftInlineCommentInstructions + "\n"
                + IntelligencePrompt.draftPlainTextContract,
            user: IntelligencePrompt.body(for: request)
        )
    }

    /// One streamed drafting request.
    ///
    /// The last element is put through ``IntelligenceJSON/draft(from:)`` even though the prompt
    /// asked for plain text, for the same reason the non-streaming path is lenient: a model that
    /// wrapped the answer in the JSON envelope anyway has still done the work, and the reviewer
    /// should end up with the draft rather than with the machinery around it.
    private func streamDraft(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        let source = streamComplete(system: system, user: user)
        return IntelligenceStreaming.stream { continuation in
            var answer = ""
            for try await text in source {
                answer = text
                continuation.yield(text)
            }
            let finished = try IntelligenceJSON.draft(from: answer)
            if finished != answer { continuation.yield(finished) }
        }
    }

    /// The JSON body one completion request sends.
    ///
    /// Extracted so the encoding — the `max_tokens` key, the system prompt sent as its own field
    /// rather than as a message — is unit-testable without a network, the same way
    /// ``ModelListing`` makes model discovery testable.
    /// - Parameters:
    ///   - system: The system prompt.
    ///   - user: The user message.
    ///   - streaming: Whether to ask the endpoint for a streamed answer. The key is omitted
    ///     entirely when this is `false`.
    /// - Returns: The encoded request body.
    func completionRequestBody(
        system: String,
        user: String,
        streaming: Bool = false
    ) throws -> Data {
        try JSONEncoder().encode(
            RequestBody(
                model: model,
                maxTokens: maxTokens,
                system: system,
                messages: [RequestBody.Message(role: "user", content: user)],
                // Absent rather than `false` on the non-streaming path: the key is only
                // meaningful when it is `true`, and an endpoint proxy that copies the body
                // should not have to reason about a flag Shepherd did not need to send.
                stream: streaming ? true : nil
            )
        )
    }

    /// Sends one **streaming** completion request, yielding the answer as it grows.
    ///
    /// Every element is the whole answer so far: the wire carries `content_block_delta` deltas
    /// (parsed by the pure ``ShepherdCore/AnthropicStreamDecoder``) and the accumulation happens
    /// here, where the wire shape is known, rather than in the UI where it would have to be
    /// reimplemented per provider.
    /// - Parameters:
    ///   - system: The system prompt.
    ///   - user: The user message.
    /// - Returns: A stream of ever-longer answers.
    func streamComplete(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        // Captured as one value rather than reaching for properties inside an escaping closure:
        // the provider is a `Sendable` struct, so this is a copy and there is nothing to race on.
        let provider = self
        return IntelligenceStreaming.stream { continuation in
            guard !provider.apiKey.isEmpty else {
                throw IntelligenceError.notConfigured("API key")
            }
            guard let url = URL(string: AnthropicProvider.messagesURL) else {
                throw IntelligenceError.notConfigured("endpoint")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
            request.httpBody = try provider.completionRequestBody(
                system: system,
                user: user,
                streaming: true
            )

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw IntelligenceError.http(
                    status: status,
                    message: AnthropicProvider.errorMessage(
                        in: await IntelligenceStreaming.failureBody(bytes)
                    )
                )
            }

            var parser = ServerSentEventParser()
            var answer = ""
            for try await line in bytes.lines {
                guard let event = parser.consume(line) else { continue }
                // A streamed request can answer 200 and then fail, which is the one failure a
                // status check cannot see.
                if let message = AnthropicStreamDecoder.errorMessage(in: event) {
                    throw IntelligenceError.http(status: status, message: message)
                }
                guard let delta = AnthropicStreamDecoder.textDelta(in: event) else { continue }
                answer += delta
                continuation.yield(answer)
            }
            _ = parser.finish()
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IntelligenceError.malformedResponse
            }
        }
    }

    /// Sends one non-streaming completion request.
    /// - Parameters:
    ///   - system: The system prompt.
    ///   - user: The user message.
    /// - Returns: The concatenated text blocks of the answer.
    func complete(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw IntelligenceError.notConfigured("API key") }
        guard let url = URL(string: AnthropicProvider.messagesURL) else {
            throw IntelligenceError.notConfigured("endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try completionRequestBody(system: system, user: user)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw IntelligenceError.http(
                status: status,
                message: AnthropicProvider.errorMessage(in: data)
            )
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw IntelligenceError.malformedResponse
        }
        let text = decoded.content
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntelligenceError.malformedResponse }
        return text
    }

    /// Best-effort extraction of Anthropic's `{"error": {"message": …}}` shape.
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
        var system: String
        var messages: [Message]
        var stream: Bool?

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
            case stream
        }
    }

    private struct ResponseBody: Decodable {
        struct Block: Decodable {
            var type: String?
            var text: String?
        }
        var content: [Block]
    }
}
