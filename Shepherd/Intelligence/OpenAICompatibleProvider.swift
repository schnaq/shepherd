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

    /// The same list, with whatever else the endpoint published about each entry (plan §3.K).
    ///
    /// A second requirement with a **default implementation** rather than a widened return type
    /// on the first, because the extra material is optional by construction: the documented
    /// OpenAI shape carries an id and nothing else, and every conformance that has only ids —
    /// a stub in a test, a local server — should not have to say so. The default therefore maps
    /// ``availableModels()`` into id-only entries, which is exactly what the picker showed
    /// before this existed.
    /// - Returns: The offered entries, never empty, in the endpoint's own order.
    /// - Throws: ``IntelligenceError`` when the list cannot be obtained.
    func availableModelEntries() async throws -> [OpenAIModelsResponse.Model]
}

extension ModelListing {
    func availableModelEntries() async throws -> [OpenAIModelsResponse.Model] {
        try await availableModels().map { OpenAIModelsResponse.Model(id: $0) }
    }
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
    /// ISO 3166-1 alpha-2 countries the request may be served from, or empty for no constraint.
    ///
    /// The user's optional sovereignty policy (plan §3.K). It is **request-body content**, not a
    /// per-endpoint feature flag: it reaches the wire as `provider.countries` and only when it is
    /// non-empty, because a gateway that understands the field refuses an empty object and a
    /// gateway that does not understand it refuses the field at all. Nothing here branches on a
    /// base URL, so no preset gains a code path (ADR 0007's 2026-09-03 amendment).
    var sovereigntyCountries: [String] = []
    /// Whether only an operator that stores neither prompt nor completion may serve the request.
    ///
    /// Sent as `provider.zero_retention` and only when `true`: `false` and absent mean the same
    /// thing to the field's own definition, so sending `false` would be a constraint that is not
    /// one, on an endpoint that may reject the key it arrived under.
    var requiresZeroRetention: Bool = false
    /// Where a non-streaming request goes. `URLSession` outside tests.
    let transport: any IntelligenceTransport
    /// Where this request's response headers and usage counts are recorded, when somebody is
    /// listening. `nil` for a call nobody asked about — a connection test, a settings probe.
    var report: IntelligenceEndpointReport?

    var kind: IntelligenceKind { .openAICompatible }

    var isAvailable: Bool {
        get async { OpenAICompatibleProvider.completionsURL(base: baseURL) != nil && !model.isEmpty }
    }

    /// Creates a provider.
    /// - Parameters:
    ///   - baseURL: The endpoint's base URL.
    ///   - model: The model name.
    ///   - apiKey: The bearer token.
    ///   - sovereigntyCountries: The optional country allow-list. Empty sends no policy.
    ///   - requiresZeroRetention: Whether to require a zero-retention operator. `false` sends
    ///     no policy.
    ///   - transport: Where requests go. Defaults to `URLSession`; a test substitutes a script.
    ///   - report: Where to record who served the request and what it cost. `nil` records
    ///     nothing.
    init(
        baseURL: String,
        model: String,
        apiKey: String,
        sovereigntyCountries: [String] = [],
        requiresZeroRetention: Bool = false,
        transport: any IntelligenceTransport = IntelligenceURLSessionTransport(),
        report: IntelligenceEndpointReport? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.sovereigntyCountries = sovereigntyCountries
        self.requiresZeroRetention = requiresZeroRetention
        self.transport = transport
        self.report = report
    }

    /// A copy of this provider that records who served its requests into `report`.
    ///
    /// The generic hook's provider half (plan §3.K). It is a *copy* rather than a mutation
    /// because the provider is a `Sendable` value the router rebuilds per request; handing the
    /// report in through the initialiser would mean every caller that does not care about it
    /// naming it anyway.
    /// - Parameter report: Where to record the response headers and the usage chunk.
    /// - Returns: The same configuration, reporting into `report`.
    func reporting(to report: IntelligenceEndpointReport) -> any IntelligenceProvider {
        var copy = self
        copy.report = report
        return copy
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

    /// Explains a selection (plan §3.D).
    ///
    /// The same streamed plain-text path as the two drafts, carrying the same excerpt
    /// ``InlineCommentDraftBuilder`` cut for an inline draft — so a reviewer who has read
    /// `CONTRIBUTING.md`'s sentence about what a drafted comment sends to their own endpoint
    /// already knows what an explanation sends.
    func streamExplanation(
        _ request: ExplainSelectionRequest
    ) -> AsyncThrowingStream<String, Error> {
        streamDraft(
            system: request.instructions + "\n" + IntelligencePrompt.draftPlainTextContract,
            user: IntelligencePrompt.body(for: request)
        )
    }

    /// One streamed drafting request.
    ///
    /// The finished answer still goes through ``IntelligenceJSON/draft(from:)``: this tier is
    /// "whatever speaks the chat-completions shape", so it is exactly the tier where a model
    /// ignores the plain-text instruction and sends the JSON envelope anyway.
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
        try await availableModelEntries().compactMap(\.id)
    }

    /// Asks the endpoint which models it offers, keeping what it published about each.
    ///
    /// The same one request ``availableModels()`` makes — that method is written in terms of this
    /// one, so there is no way for the picker's ids and the picker's badges to come from two
    /// different fetches. What a plain OpenAI endpoint publishes is an id and nothing else, which
    /// decodes to an entry whose optional blocks are `nil`; a gateway that publishes sovereignty
    /// and pricing beside it has both kept (plan §3.K).
    /// - Returns: The offered entries, in the endpoint's own order.
    /// - Throws: ``IntelligenceError`` when the endpoint is unreachable, refuses the key, or
    ///   answers with something other than the documented list shape.
    func availableModelEntries() async throws -> [OpenAIModelsResponse.Model] {
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
        return try OpenAIModelsResponse.models(in: data)
    }

    /// The JSON body one chat-completions request sends.
    ///
    /// Extracted for the same reason ``ModelListing`` exists: the shape that has to be right —
    /// the `max_tokens` key, the system message first and the user message second — is then
    /// unit-testable without a network, and the drafting prompts (ADR 0007 amendment) can be
    /// asserted on the wire rather than only in the string constants.
    /// Two further keys are conditional, and both are absent by default (plan §3.K):
    /// `stream_options: {"include_usage": true}` on a streamed request, so the endpoint's own
    /// token count arrives in a final chunk; and `provider: {…}` when — and only when — the user
    /// set a sovereignty policy. The second one is why "only when" matters: a gateway that
    /// understands the field rejects an unrecognised key inside it and rejects an empty object,
    /// and a gateway that does not understand it rejects the key outright, so an always-sent
    /// `provider: {}` would break every endpoint that is not the one it was written for.
    /// - Parameters:
    ///   - system: The system message.
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
                messages: [
                    RequestBody.Message(role: "system", content: system),
                    RequestBody.Message(role: "user", content: user),
                ],
                // Absent rather than `false` when not streaming: a local server that has never
                // heard of the key is likelier to accept a body without it than to ignore it.
                stream: streaming ? true : nil,
                streamOptions: streaming
                    ? RequestBody.StreamOptions(includeUsage: true)
                    : nil,
                provider: sovereigntyPolicy
            )
        )
    }

    /// The `provider` object to send, or `nil` when the user set no policy.
    ///
    /// Blank country codes are dropped and the rest are uppercased, because the field is defined
    /// as ISO 3166-1 alpha-2 and a gateway matching `de` against `DE` is not something to rely
    /// on. Everything empty means `nil`, which means the key is not in the body at all.
    private var sovereigntyPolicy: RequestBody.ProviderPolicy? {
        let countries = sovereigntyCountries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        guard !countries.isEmpty || requiresZeroRetention else { return nil }
        return RequestBody.ProviderPolicy(
            countries: countries.isEmpty ? nil : countries,
            zeroRetention: requiresZeroRetention ? true : nil
        )
    }

    /// Sends one **streaming** chat-completions request, yielding the answer as it grows.
    ///
    /// Every element is the whole answer so far. The deltas (`choices[].delta.content`) and the
    /// `[DONE]` sentinel are read by the pure ``ShepherdCore/OpenAICompatibleStreamDecoder``,
    /// which is deliberately tolerant: the servers behind this tier disagree about the role-only
    /// first frame, about `null` contents and about whether the sentinel is sent at all, and none
    /// of those disagreements may reach the reviewer's field as an error.
    ///
    /// Three things happen around the frames rather than in them (plan §3.K), and all three are
    /// optional extensions any endpoint may fill:
    ///
    /// - the **served-by headers** are read from the initial response, *before* the first
    ///   `data:` line, which is what lets the router settle the caption before the reviewer sees
    ///   a character;
    /// - a **`429` with a usable `Retry-After`** is waited out once and the request made once
    ///   more — never twice, and a cancellation during the wait aborts rather than resuming;
    /// - the **final usage chunk** (asked for by `stream_options`) is recorded. It carries an
    ///   empty `choices` array, which the delta decoder already reads as "no text in this frame",
    ///   so it cannot truncate a draft and the `[DONE]` sentinel still ends the stream.
    /// - Parameters:
    ///   - system: The system message.
    ///   - user: The user message.
    /// - Returns: A stream of ever-longer answers.
    func streamComplete(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        // One captured copy rather than property access inside an escaping closure; the provider
        // is a `Sendable` struct.
        let provider = self
        return IntelligenceStreaming.stream { continuation in
            guard let url = OpenAICompatibleProvider.completionsURL(base: provider.baseURL) else {
                throw IntelligenceError.notConfigured("base URL")
            }
            guard !provider.model.isEmpty else {
                throw IntelligenceError.notConfigured("model name")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
            if !provider.apiKey.isEmpty {
                request.setValue(
                    "Bearer \(provider.apiKey)",
                    forHTTPHeaderField: "authorization"
                )
            }
            request.httpBody = try provider.completionRequestBody(
                system: system,
                user: user,
                streaming: true
            )

            var (bytes, response) = try await URLSession.shared.bytes(for: request)
            var http = response as? HTTPURLResponse
            if http?.statusCode == 429,
               let delay = IntelligenceRetryAfter.delay(
                   headers: IntelligenceURLSessionTransport.fields(of: http)
               ) {
                // The refused body is drained first: leaving it unread would keep the connection
                // alive with nobody on this end, and the second request is a new one anyway.
                _ = await IntelligenceStreaming.failureBody(bytes)
                try await Task.sleep(for: .seconds(delay))
                (bytes, response) = try await URLSession.shared.bytes(for: request)
                http = response as? HTTPURLResponse
            }
            let status = http?.statusCode ?? 0
            let headers = IntelligenceURLSessionTransport.fields(of: http)
            if let report = provider.report {
                await report.record(servedBy: ServedBy.parse(headers: headers))
            }
            guard (200..<300).contains(status) else {
                throw IntelligenceError.http(
                    status: status,
                    message: OpenAICompatibleProvider.errorMessage(
                        in: await IntelligenceStreaming.failureBody(bytes)
                    )
                )
            }

            var parser = ServerSentEventParser()
            var answer = ""
            var usage: StreamUsage?
            for try await line in bytes.lines {
                guard let event = parser.consume(line) else { continue }
                if OpenAICompatibleStreamDecoder.isDone(event) { break }
                if let message = OpenAICompatibleStreamDecoder.errorMessage(in: event) {
                    throw IntelligenceError.http(status: status, message: message)
                }
                if let reported = OpenAICompatibleStreamDecoder.usage(in: event) {
                    usage = reported
                }
                guard let delta = OpenAICompatibleStreamDecoder.textDelta(in: event) else {
                    continue
                }
                answer += delta
                continuation.yield(answer)
            }
            _ = parser.finish()
            if let report = provider.report {
                await report.record(usage: usage)
            }
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IntelligenceError.malformedResponse
            }
        }
    }

    /// Sends one non-streaming chat-completions request.
    ///
    /// It goes through ``IntelligenceTransport`` rather than straight to `URLSession` — which is
    /// what it used to do — for two reasons that arrived together (plan §3.K): the response
    /// **headers** have to be readable (who served the answer), and the one piece of control flow
    /// this call now has, the single `Retry-After` wait, is a decision that must be assertable in
    /// a test rather than only on a user's Mac with a rate-limited key.
    /// - Parameters:
    ///   - system: The system message.
    ///   - user: The user message.
    /// - Returns: The answer text.
    func complete(system: String, user: String) async throws -> String {
        guard let url = OpenAICompatibleProvider.completionsURL(base: baseURL) else {
            throw IntelligenceError.notConfigured("base URL")
        }
        guard !model.isEmpty else { throw IntelligenceError.notConfigured("model name") }

        var headers = ["content-type": "application/json"]
        if !apiKey.isEmpty { headers["authorization"] = "Bearer \(apiKey)" }
        let body = try completionRequestBody(system: system, user: user)

        var response = try await transport.send(url: url, headers: headers, body: body)
        // Once, and only when the endpoint named a delay a person will sit through. The retry is
        // this one expression rather than a loop, so there is no counter to get wrong and no way
        // for a gateway to keep Shepherd talking to it (``IntelligenceRetryAfter``).
        if response.status == 429,
           let delay = IntelligenceRetryAfter.delay(headers: response.headers) {
            try await Task.sleep(for: .seconds(delay))
            response = try await transport.send(url: url, headers: headers, body: body)
        }
        if let report {
            await report.record(servedBy: ServedBy.parse(headers: response.headers))
        }
        guard (200..<300).contains(response.status) else {
            throw IntelligenceError.http(
                status: response.status,
                message: OpenAICompatibleProvider.errorMessage(in: response.data)
            )
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: response.data),
              let text = decoded.choices.first?.message?.content?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw IntelligenceError.malformedResponse
        }
        return text
    }

    // MARK: - The tool loop (plan §3.F)

    /// Diagnoses a red pull request through `tool_calls` and `role: "tool"` messages.
    ///
    /// The chat-completions shape for this is a message list Shepherd keeps: the request carries
    /// `tools`, a choice whose `finish_reason` is `tool_calls` carries the calls on its assistant
    /// message, and the way to answer them is to append that assistant message **including its
    /// `tool_calls`** and then one `role: "tool"` message per call, each keyed by its
    /// `tool_call_id`. Servers reject a `tool` message whose id they never issued, so the ids are
    /// echoed rather than regenerated.
    ///
    /// Non-streaming, deliberately. A streamed tool call arrives as `arguments` split across
    /// frames, reassembled differently by every server behind this tier — and there is nothing to
    /// show the reviewer while it happens anyway: the visible progress of this feature is the
    /// trace, one finished hop at a time.
    ///
    /// The loop is tolerant in one place: a server that fills `tool_calls` but forgets
    /// `finish_reason` is still asking for a tool. This tier is "whatever speaks the shape", and
    /// treating a present, non-empty call list as the request it obviously is costs nothing.
    ///
    /// It is not tolerant about the cap, which counts **attempted** calls rather than recorded
    /// hops. The trace only takes a step for a tool the registry knows — an invented name is
    /// refused rather than run, so there is nothing typed to record — and counting the trace
    /// therefore capped nothing for the model that most needs capping: one that keeps asking for
    /// a tool nobody declared, reads the refusal, and asks again. A call the model got wrong
    /// still cost a round trip, so it still costs a hop.
    /// - Parameters:
    ///   - request: What is red and what may be read.
    ///   - tools: The reads, already bound to this pull request.
    /// - Returns: The diagnosis and its hops.
    func diagnoseFailingChecks(
        _ request: CIDiagnosisRequest,
        tools: any IntelligenceToolExecuting
    ) async throws -> IntelligenceToolRun<CIDiagnosis> {
        guard let url = OpenAICompatibleProvider.completionsURL(base: baseURL) else {
            throw IntelligenceError.notConfigured("base URL")
        }
        guard !model.isEmpty else { throw IntelligenceError.notConfigured("model name") }

        var headers = ["content-type": "application/json"]
        if !apiKey.isEmpty { headers["authorization"] = "Bearer \(apiKey)" }
        var messages: [ToolMessage] = [
            ToolMessage(
                role: "system",
                content: IntelligencePrompt.ciDiagnosisInstructions + "\n"
                    + IntelligencePrompt.ciDiagnosisJSONContract
            ),
            ToolMessage(role: "user", content: IntelligencePrompt.body(for: request)),
        ]
        var trace = IntelligenceTrace()
        // Every call the model asked for, valid or not. Local to the loop, because it is the
        // *turn* that is capped and a turn is exactly what this loop is.
        var attemptedHops = 0
        var answer = ""

        while true {
            let (data, status) = try await transport.post(
                url: url,
                headers: headers,
                body: try toolRequestBody(messages: messages)
            )
            guard (200..<300).contains(status) else {
                throw OpenAICompatibleProvider.toolFailure(
                    status: status,
                    message: OpenAICompatibleProvider.errorMessage(in: data)
                )
            }
            guard let decoded = try? JSONDecoder().decode(ToolResponseBody.self, from: data),
                  let choice = decoded.choices.first
            else {
                throw IntelligenceError.malformedResponse
            }
            answer = choice.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let calls = choice.message?.toolCalls ?? []
            guard !calls.isEmpty, choice.finishReason == "tool_calls" || choice.finishReason == nil
            else { break }
            attemptedHops += calls.count
            guard attemptedHops <= IntelligenceToolLoop.maximumHops else {
                throw IntelligenceError.toolLoopExceeded
            }

            messages.append(
                ToolMessage(role: "assistant", content: choice.message?.content, toolCalls: calls)
            )
            for wireCall in calls {
                let call = IntelligenceToolCall(
                    id: wireCall.id,
                    toolName: wireCall.function.name,
                    arguments: OpenAICompatibleProvider.arguments(in: wireCall.function.arguments)
                )
                let started = Date()
                let result = try await tools.execute(call)
                if let name = IntelligenceToolName(rawValue: call.toolName) {
                    trace.append(
                        tool: name,
                        call: call,
                        result: result,
                        duration: Date().timeIntervalSince(started)
                    )
                }
                messages.append(
                    ToolMessage(role: "tool", content: result.content, toolCallID: wireCall.id)
                )
            }
        }

        return IntelligenceToolRun(
            value: try IntelligenceJSON.diagnosis(from: answer),
            trace: trace
        )
    }

    /// The JSON body one tool-calling request sends.
    ///
    /// Exposed for the same reason ``completionRequestBody(system:user:streaming:)`` is: the tool
    /// schemas have to reach the wire, and an endpoint that dislikes them answers `400` on the
    /// user's Mac otherwise.
    ///
    /// No `temperature` and no `tool_choice`: this tier is the one that is *least* likely to
    /// accept a key it has never heard of, and neither is needed — the descriptors say what the
    /// tools do and the JSON contract says what the answer looks like.
    /// - Parameter messages: The transcript so far, oldest first.
    /// - Returns: The encoded request body.
    func toolRequestBody(messages: [ToolMessage]) throws -> Data {
        try JSONEncoder().encode(
            ToolRequestBody(
                model: model,
                maxTokens: maxTokens,
                messages: messages,
                tools: OpenAIToolSchema.all
            )
        )
    }

    /// Parses a `tool_calls[].function.arguments` JSON *string* into the contract's argument map.
    ///
    /// This shape's one real difference from the other: the arguments arrive as a string holding
    /// JSON, not as JSON. A string that does not parse — an unterminated object, a model that
    /// wrote prose there — yields no arguments at all, which the registry then refuses by name
    /// with a sentence the model can act on. That is the same outcome an argument this contract
    /// cannot hold gets, and better than ending the turn over a malformed field.
    /// - Parameter json: The `arguments` string.
    /// - Returns: The arguments, or an empty map.
    static func arguments(in json: String) -> [String: IntelligenceToolArgument] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        return (try? JSONDecoder().decode(
            [String: IntelligenceToolArgument].self,
            from: Data(trimmed.utf8)
        )) ?? [:]
    }

    /// Maps a failed tool-calling request onto the error the UI can act on.
    ///
    /// The case this exists for is the konduit/Ollama-class endpoint that answers `400` with
    /// "this model does not support tools": there is no status code for it, so the message is
    /// what there is, and ``IntelligenceError/toolsUnsupported`` is what the reviewer can act on.
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

        /// `stream_options`, sent only on a streamed request.
        struct StreamOptions: Encodable {
            /// Whether the endpoint should send the final usage chunk.
            var includeUsage: Bool

            enum CodingKeys: String, CodingKey {
                case includeUsage = "include_usage"
            }
        }

        /// The user's sovereignty policy, sent only when they set one.
        ///
        /// Both fields are optional and both are omitted when they carry no constraint, because
        /// the object is validated as a whole by the endpoints that understand it: an
        /// unrecognised key inside it is refused rather than ignored, and `zero_retention: false`
        /// means "no constraint" — which is what leaving the key out already means.
        struct ProviderPolicy: Encodable {
            /// ISO 3166-1 alpha-2 hosting countries a deployment may run in — any of them.
            var countries: [String]?
            /// Whether the operator must store neither prompt nor completion.
            var zeroRetention: Bool?

            enum CodingKeys: String, CodingKey {
                case countries
                case zeroRetention = "zero_retention"
            }
        }

        var model: String
        var maxTokens: Int
        var messages: [Message]
        var stream: Bool?
        var streamOptions: StreamOptions?
        var provider: ProviderPolicy?

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case messages
            case stream
            case streamOptions = "stream_options"
            case provider
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

    // MARK: - Tool-calling wire types

    /// One entry of `tool_calls`, in the shape that goes both ways.
    ///
    /// `arguments` is a `String` and stays one: that is what the API puts on the wire, and
    /// echoing the model's own text back in the assistant message — rather than re-encoding a
    /// parsed map — is what keeps the transcript byte-identical to what the server issued.
    /// Parsing happens once, beside the call, through
    /// ``OpenAICompatibleProvider/arguments(in:)``.
    struct WireToolCall: Codable, Sendable {
        /// One function call.
        struct Function: Codable, Sendable {
            /// The tool name the model asked for.
            var name: String
            /// The arguments, as a JSON string.
            var arguments: String

            /// Creates a function call.
            /// - Parameters:
            ///   - name: The tool name.
            ///   - arguments: The arguments, as a JSON string.
            init(name: String, arguments: String) {
                self.name = name
                self.arguments = arguments
            }

            /// Decodes a function call, tolerating an absent `arguments`.
            ///
            /// A tool that takes none — `failingChecks` — is sent by some servers with the key
            /// missing rather than as `"{}"`, and refusing to decode that would refuse the one
            /// call the model is most likely to start with.
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
                arguments = try container.decodeIfPresent(String.self, forKey: .arguments) ?? ""
            }

            enum CodingKeys: String, CodingKey {
                case name
                case arguments
            }
        }

        /// The call's id, echoed on the `tool` message that answers it.
        var id: String
        /// Always `"function"`.
        var type: String
        /// What to call.
        var function: Function

        /// Creates a call.
        /// - Parameters:
        ///   - id: The call id.
        ///   - type: The call type. Defaults to `"function"`.
        ///   - function: What to call.
        init(id: String, type: String = "function", function: Function) {
            self.id = id
            self.type = type
            self.function = function
        }

        /// Decodes a call, defaulting the two fields a permissive server may omit.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "function"
            function = try container.decode(Function.self, forKey: .function)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case function
        }
    }

    /// One message of a tool-calling transcript.
    ///
    /// Four roles ride on this one shape — `system`, `user`, the `assistant` message that carries
    /// `tool_calls`, and the `tool` message that answers one — because that is how the API models
    /// them: the same object with different fields filled in. The absent ones are omitted by the
    /// encoder, so a `user` message does not carry a null `tool_call_id`.
    struct ToolMessage: Codable, Sendable {
        /// `system`, `user`, `assistant` or `tool`.
        var role: String
        /// The message text. Absent on an assistant message that only asked for tools.
        var content: String?
        /// The calls the assistant asked for.
        var toolCalls: [WireToolCall]?
        /// Which call a `tool` message answers.
        var toolCallID: String?

        /// Creates a message.
        /// - Parameters:
        ///   - role: The role.
        ///   - content: The text, if any.
        ///   - toolCalls: The calls, for an assistant message.
        ///   - toolCallID: The call answered, for a `tool` message.
        init(
            role: String,
            content: String? = nil,
            toolCalls: [WireToolCall]? = nil,
            toolCallID: String? = nil
        ) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
        }

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }
    }

    private struct ToolRequestBody: Encodable {
        var model: String
        var maxTokens: Int
        var messages: [ToolMessage]
        var tools: [OpenAIToolSchema]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case messages
            case tools
        }
    }

    private struct ToolResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
                var toolCalls: [WireToolCall]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case toolCalls = "tool_calls"
                }
            }
            var message: Message?
            var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        var choices: [Choice]
    }

    // MARK: - Delegation brief (plan §3.E)

    /// Drafts the task for a coding agent, streamed as cumulative Markdown (plan §3.E).
    ///
    /// The same streamed plain-text path the two drafting calls use, with the brief's own
    /// instructions and its Markdown contract — including the finished-answer pass through
    /// ``IntelligenceJSON/draft(from:)``, which on this tier is worth keeping for the reason it
    /// was added: "whatever speaks the chat-completions shape" is exactly the population that
    /// wraps an answer in a JSON envelope it was asked not to send. Markdown that merely
    /// *contains* braces is left alone, because the envelope has to decode and carry a `draft`
    /// key before it is believed.
    ///
    /// A request marked ``AgentBriefRequest/onDeviceOnly`` never reaches this method: the router
    /// refuses the cloud rung for it (ADR 0020's reasoning).
    func streamAgentBrief(_ request: AgentBriefRequest) -> AsyncThrowingStream<String, Error> {
        streamDraft(
            system: IntelligencePrompt.agentBriefInstructions + "\n"
                + IntelligencePrompt.agentBriefMarkdownContract,
            user: IntelligencePrompt.body(for: request)
        )
    }
}
