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
    /// Where a non-streaming request goes. `URLSession` outside tests.
    let transport: any IntelligenceTransport

    var kind: IntelligenceKind { .anthropic }

    var isAvailable: Bool {
        get async { !apiKey.isEmpty && !model.isEmpty }
    }

    /// Creates a provider.
    /// - Parameters:
    ///   - apiKey: The user's Anthropic key.
    ///   - model: The model id.
    ///   - transport: Where requests go. Defaults to `URLSession`; a test substitutes a script.
    init(
        apiKey: String,
        model: String = AnthropicProvider.defaultModel,
        transport: any IntelligenceTransport = IntelligenceURLSessionTransport()
    ) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? AnthropicProvider.defaultModel : model
        self.transport = transport
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

    // MARK: - The tool loop (plan §3.F)

    /// Diagnoses a red pull request through `tool_use`/`tool_result` blocks.
    ///
    /// The Messages API's shape for this is a conversation Shepherd keeps: the request carries
    /// `tools`, an answer whose `stop_reason` is `tool_use` holds one or more `tool_use` blocks,
    /// and the way to answer them is to append the assistant's content **verbatim** and then a
    /// `user` message of `tool_result` blocks — one per call, keyed by `tool_use_id`. Dropping any
    /// part of the assistant's content, or answering the calls out of order, makes the endpoint
    /// reject the next request, so the blocks are round-tripped through one typed value rather
    /// than rebuilt.
    ///
    /// The loop ends in exactly three ways: the model stops asking (its text is the answer), the
    /// hop cap fires, or the endpoint fails. There is no "answer with what you have" fallback —
    /// see ``IntelligenceError/toolLoopExceeded``.
    /// - Parameters:
    ///   - request: What is red and what may be read.
    ///   - tools: The reads, already bound to this pull request.
    /// - Returns: The diagnosis and its hops.
    func diagnoseFailingChecks(
        _ request: CIDiagnosisRequest,
        tools: any IntelligenceToolExecuting
    ) async throws -> IntelligenceToolRun<CIDiagnosis> {
        guard !apiKey.isEmpty else { throw IntelligenceError.notConfigured("API key") }
        guard let url = URL(string: AnthropicProvider.messagesURL) else {
            throw IntelligenceError.notConfigured("endpoint")
        }

        let system = IntelligencePrompt.ciDiagnosisInstructions + "\n"
            + IntelligencePrompt.ciDiagnosisJSONContract
        var messages: [ToolMessage] = [
            ToolMessage(
                role: "user",
                content: [ContentBlock(text: IntelligencePrompt.body(for: request))]
            ),
        ]
        var trace = IntelligenceTrace()
        var answer = ""

        while true {
            let (data, status) = try await transport.post(
                url: url,
                headers: [
                    "x-api-key": apiKey,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                ],
                body: try toolRequestBody(system: system, messages: messages)
            )
            guard (200..<300).contains(status) else {
                throw AnthropicProvider.toolFailure(
                    status: status,
                    message: AnthropicProvider.errorMessage(in: data)
                )
            }
            guard let decoded = try? JSONDecoder().decode(ToolResponseBody.self, from: data) else {
                throw IntelligenceError.malformedResponse
            }
            answer = decoded.text
            let calls = decoded.toolUseBlocks
            guard decoded.stopReason == "tool_use", !calls.isEmpty else { break }
            guard trace.count + calls.count <= IntelligenceToolLoop.maximumHops else {
                throw IntelligenceError.toolLoopExceeded
            }

            // Verbatim, including any text block the model wrote alongside the call: the
            // transcript the endpoint validates the next request against is its own.
            messages.append(ToolMessage(role: "assistant", content: decoded.content))
            var results: [ContentBlock] = []
            for block in calls {
                let call = IntelligenceToolCall(
                    id: block.id ?? "",
                    toolName: block.name ?? "",
                    arguments: block.input ?? [:]
                )
                let started = Date()
                let result = try await tools.execute(call)
                if let name = IntelligenceToolName(rawValue: call.toolName) {
                    // Only a known tool becomes a step: the trace is typed, and a name the model
                    // invented was refused rather than run, which the model reads in the result.
                    trace.append(
                        tool: name,
                        call: call,
                        result: result,
                        duration: Date().timeIntervalSince(started)
                    )
                }
                results.append(ContentBlock(toolUseID: call.id, content: result.content))
            }
            messages.append(ToolMessage(role: "user", content: results))
        }

        return IntelligenceToolRun(
            value: try IntelligenceJSON.diagnosis(from: answer),
            trace: trace
        )
    }

    /// The JSON body one tool-calling request sends.
    ///
    /// Its own encoder rather than a flag on ``completionRequestBody(system:user:streaming:)``,
    /// because the two bodies are genuinely different shapes: that one carries a single string
    /// message and no `tools`, this one carries a growing transcript of content blocks. Exposed
    /// so a test can assert that the tool schemas reach the wire — a schema an endpoint dislikes
    /// otherwise fails on the user's machine.
    ///
    /// No `temperature`: the tool descriptors and the JSON contract are what constrain this
    /// answer, and a key the request does not need is one more thing a proxy in front of the API
    /// can disagree about.
    /// - Parameters:
    ///   - system: The system prompt.
    ///   - messages: The transcript so far, oldest first.
    /// - Returns: The encoded request body.
    func toolRequestBody(system: String, messages: [ToolMessage]) throws -> Data {
        try JSONEncoder().encode(
            ToolRequestBody(
                model: model,
                maxTokens: maxTokens,
                system: system,
                messages: messages,
                tools: AnthropicToolSchema.all
            )
        )
    }

    /// Maps a failed tool-calling request onto the error the UI can act on.
    ///
    /// A `400` that mentions tools is an endpoint that cannot do this at all — a proxy in front
    /// of the Messages API that strips the parameter, most often — and saying so is more useful
    /// than showing the reviewer a status code. Every other status keeps its own message: a `401`
    /// is a wrong key and a `429` is a rate limit whatever the request carried.
    /// - Parameters:
    ///   - status: The HTTP status.
    ///   - message: The endpoint's own message.
    /// - Returns: The error to throw.
    static func toolFailure(status: Int, message: String) -> IntelligenceError {
        guard status == 400, IntelligenceToolLoop.mentionsTools(message) else {
            return .http(status: status, message: message)
        }
        return .toolsUnsupported
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

    // MARK: - Tool-calling wire types

    /// One content block of a tool-calling turn, in all four shapes the loop deals with.
    ///
    /// Flat rather than an enum with four cases, because this type has to *round-trip*: the
    /// assistant's blocks are decoded and sent straight back, and an enum would have to be
    /// exhaustive about a shape the API may extend. Every field is optional and the encoder omits
    /// the absent ones, so a `text` block encodes as `{"type":"text","text":…}` and nothing else.
    ///
    /// `input` is `[String: IntelligenceToolArgument]` — the contract's own flat, typed argument
    /// map — which is what makes the round trip lossless *and* checked: an argument that is not a
    /// string or an integer cannot be represented, and a model that sent one ends up with an
    /// empty argument map that the registry then refuses by name. That is the right outcome; the
    /// three tools take a check name, a path and a line number, and nothing nested.
    struct ContentBlock: Codable, Sendable {
        /// `text`, `tool_use` or `tool_result`.
        var type: String
        /// The assistant's prose, for a `text` block.
        var text: String?
        /// The call's id, for a `tool_use` block.
        var id: String?
        /// The tool's name, for a `tool_use` block.
        var name: String?
        /// The arguments, for a `tool_use` block.
        var input: [String: IntelligenceToolArgument]?
        /// Which call this answers, for a `tool_result` block.
        var toolUseID: String?
        /// The tool's budgeted text, for a `tool_result` block.
        var content: String?

        /// A `text` block.
        /// - Parameter text: The prose.
        init(text: String) {
            self.type = "text"
            self.text = text
        }

        /// A `tool_result` block.
        /// - Parameters:
        ///   - toolUseID: The call this answers.
        ///   - content: The tool's budgeted text.
        init(toolUseID: String, content: String) {
            self.type = "tool_result"
            self.toolUseID = toolUseID
            self.content = content
        }

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case id
            case name
            case input
            case toolUseID = "tool_use_id"
            case content
        }

        /// Decodes a block, tolerating an `input` this contract cannot hold.
        ///
        /// `try?` on that one field only: a nested or array-valued argument is a call that would
        /// have been refused anyway, and losing the arguments turns it into a refusal the model
        /// can read instead of a decoding failure that ends the turn. The double-optional dance is
        /// `try?` over `decodeIfPresent` — "absent" and "unreadable" collapse to the same `nil`.
        ///
        /// A `tool_use` block that lost its arguments keeps an *empty* map rather than none,
        /// because this block is sent back in the next request and the API requires the key to be
        /// there. An empty map is also exactly what makes the registry refuse the call by name.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
            text = try container.decodeIfPresent(String.self, forKey: .text)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            let decodedInput = (try? container.decodeIfPresent(
                [String: IntelligenceToolArgument].self,
                forKey: .input
            )) ?? nil
            input = type == "tool_use" ? (decodedInput ?? [:]) : decodedInput
            toolUseID = try container.decodeIfPresent(String.self, forKey: .toolUseID)
            content = try container.decodeIfPresent(String.self, forKey: .content)
        }
    }

    /// One message of a tool-calling transcript.
    struct ToolMessage: Codable, Sendable {
        /// `user` or `assistant`.
        var role: String
        /// The message's content blocks.
        var content: [ContentBlock]

        /// Creates a message.
        /// - Parameters:
        ///   - role: `user` or `assistant`.
        ///   - content: The blocks.
        init(role: String, content: [ContentBlock]) {
            self.role = role
            self.content = content
        }
    }

    private struct ToolRequestBody: Encodable {
        var model: String
        var maxTokens: Int
        var system: String
        var messages: [ToolMessage]
        var tools: [AnthropicToolSchema]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
            case tools
        }
    }

    private struct ToolResponseBody: Decodable {
        var content: [ContentBlock]
        var stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }

        /// Every `tool_use` block, in the order the model asked for them.
        var toolUseBlocks: [ContentBlock] {
            content.filter { $0.type == "tool_use" }
        }

        /// The answer's prose, which on the last turn is the JSON contract's payload.
        var text: String {
            content
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
