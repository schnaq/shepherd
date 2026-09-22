import Foundation

/// One dispatched server-sent event: what a `data:` block said, and what it said it was.
///
/// The shape both streaming AI endpoints use is SSE, so this is the seam where a byte stream
/// stops being a network concern and becomes a value — which is the whole reason it lives here
/// and not in the app target: the frames of a streamed answer are the one part of streaming that
/// can be recorded, replayed and asserted on a Linux runner without a key, a socket or a model.
public struct ServerSentEvent: Sendable, Hashable, Codable {
    /// The `event:` field, when the stream named the event.
    public var event: String?
    /// The concatenated `data:` lines, joined with newlines exactly as the spec requires.
    public var data: String
    /// The `id:` field, when the stream sent one. Shepherd never resumes a stream, so this is
    /// carried for completeness rather than used.
    public var id: String?
    /// The `retry:` field in milliseconds, when the stream sent one.
    public var retry: Int?

    /// Creates an event.
    /// - Parameters:
    ///   - event: The event name.
    ///   - data: The data payload.
    ///   - id: The event id.
    ///   - retry: The reconnection delay in milliseconds.
    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// Turns the lines of a `text/event-stream` body into ``ServerSentEvent`` values.
///
/// Line-based on purpose: `URLSession.AsyncBytes.lines` already splits the stream, and taking
/// lines instead of bytes keeps this type free of anything that could not run on Linux — no
/// `URLSession`, no `Data`, no buffering of a socket. What is left is the part of SSE that is
/// easy to get subtly wrong and impossible to see going wrong in production:
///
/// - a line starting with `:` is a comment and is dropped (both providers send them as
///   keep-alives, and an endpoint that sends one every few seconds must not produce an event);
/// - `field: value` loses **one** optional leading space from the value, no more;
/// - several `data:` lines in one event are joined with `\n`, because a provider is allowed to
///   split a JSON payload across them and a parser that took only the last line would silently
///   truncate an answer;
/// - a blank line dispatches, and dispatches *nothing* when no `data:` arrived — that is what
///   makes a comment-only keep-alive frame free rather than an empty event the decoders would
///   have to filter;
/// - a field this app has no use for is ignored rather than refused, so a provider adding one
///   cannot break a stream mid-answer.
///
/// End of stream is **not** a dispatch: an unterminated frame is an incomplete frame, and the
/// half of a JSON object that arrived before a connection dropped is not an answer. Callers that
/// want the strict reading call ``finish()`` and get `nil` for it.
public struct ServerSentEventParser: Sendable {
    /// The `data:` lines of the frame being read.
    private var data: [String] = []
    /// The `event:` field of the frame being read.
    private var event: String?
    /// The `id:` field of the frame being read.
    private var id: String?
    /// The `retry:` field of the frame being read.
    private var retry: Int?

    /// Creates a parser positioned at the start of a stream.
    public init() {}

    /// Feeds one line of the stream.
    /// - Parameter line: The line, without its terminator.
    /// - Returns: The event the line completed, or `nil` when the frame is still being read.
    public mutating func consume(_ line: String) -> ServerSentEvent? {
        // A trailing carriage return survives `\r\n` splitting on `\n`, and a stray one at the
        // end of a value would end up inside the JSON the decoders parse.
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line

        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let (field, value) = ServerSentEventParser.split(line)
        switch field {
        case "data": data.append(value)
        case "event": event = value
        case "id": id = value
        case "retry": retry = Int(value)
        default: break
        }
        return nil
    }

    /// Ends the stream, discarding a frame that was never terminated by a blank line.
    /// - Returns: Always `nil`. It exists so a caller can say "the stream ended" in one place
    ///   and a future strict-mode change has somewhere to live.
    public mutating func finish() -> ServerSentEvent? {
        data.removeAll()
        event = nil
        id = nil
        retry = nil
        return nil
    }

    /// Parses a whole recorded body.
    ///
    /// The fixture entry point: a recorded response is one string, and a test that has to feed it
    /// line by line is a test about this method rather than about the frames.
    /// - Parameter body: The complete `text/event-stream` body.
    /// - Returns: The events it dispatched, in order.
    public static func events(in body: String) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let event = parser.consume(String(line)) { events.append(event) }
        }
        _ = parser.finish()
        return events
    }

    /// Dispatches the frame that has been read, if it carried any data.
    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            data.removeAll()
            event = nil
            id = nil
            retry = nil
        }
        guard !data.isEmpty else { return nil }
        return ServerSentEvent(
            event: event,
            data: data.joined(separator: "\n"),
            id: id,
            retry: retry
        )
    }

    /// Splits `field: value`, dropping one optional space after the colon.
    private static func split(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[line.startIndex..<colon])
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (field, String(value))
    }
}

/// The token counts an endpoint reports for one streamed answer.
///
/// The cloud twin of the measured on-device budget (ADR 0007's 2026-09-02 amendment): the
/// estimate Shepherd cuts a prompt against is arithmetic, and this is what the endpoint actually
/// billed. It is decoded and carried, not shown — a number that appeared under a reviewer's
/// draft would be noise — so that a later feature comparing the two has the measurement rather
/// than having to add the wire field first.
///
/// Both fields are optional because the shape is: a gateway may relay a usage object with only
/// `total_tokens` in it, and a chunk that carries usage beside content may carry `usage: null`.
public struct StreamUsage: Sendable, Hashable, Codable {
    /// Tokens the answer itself cost, when the endpoint said.
    public var completionTokens: Int?
    /// Prompt plus answer, when the endpoint said.
    public var totalTokens: Int?

    /// Creates a usage report.
    /// - Parameters:
    ///   - completionTokens: Tokens the answer cost.
    ///   - totalTokens: Prompt plus answer.
    public init(completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    /// Whether the endpoint reported any number at all.
    public var isEmpty: Bool { completionTokens == nil && totalTokens == nil }
}

/// Reads the text out of the OpenAI-compatible streaming shape.
///
/// The tolerance here is not politeness, it is the tier's premise: tier 3b is "whatever speaks
/// the chat-completions shape", which in practice means a local server, a gateway and a hosted
/// endpoint that each disagree in small ways — a first frame that carries only `role`, a
/// `finish_reason` frame with a `null` content, a `[DONE]` sentinel that some servers omit
/// entirely. Every one of those has to mean "no text in this frame", never "the answer is over"
/// and never a thrown error.
public enum OpenAICompatibleStreamDecoder {
    /// The sentinel some servers send instead of just closing the stream.
    public static let doneSentinel = "[DONE]"

    /// Whether this frame is the end-of-stream sentinel.
    /// - Parameter event: A dispatched frame.
    public static func isDone(_ event: ServerSentEvent) -> Bool {
        event.data.trimmingCharacters(in: .whitespaces) == doneSentinel
    }

    /// The text this frame adds to the answer.
    /// - Parameter event: A dispatched frame.
    /// - Returns: The delta's content, or `nil` when the frame carries none.
    public static func textDelta(in event: ServerSentEvent) -> String? {
        guard !isDone(event) else { return nil }
        struct Frame: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    var role: String?
                    var content: String?
                }
                var delta: Delta?
            }
            var choices: [Choice]?
        }
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(event.data.utf8))
        else { return nil }
        // Several choices is legal and Shepherd asked for one answer: the first is the answer,
        // and concatenating the others would interleave two drafts into one field.
        guard let text = frame.choices?.first?.delta?.content, !text.isEmpty else { return nil }
        return text
    }

    /// The message an error frame carries, when the stream failed after the headers.
    /// - Parameter event: A dispatched frame.
    /// - Returns: The error message, or `nil` when this frame is not an error.
    public static func errorMessage(in event: ServerSentEvent) -> String? {
        guard !isDone(event) else { return nil }
        struct Frame: Decodable {
            struct Payload: Decodable {
                var message: String?
                var type: String?
            }
            var error: Payload?
        }
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(event.data.utf8)),
              let error = frame.error
        else { return nil }
        let message = error.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty { return message }
        return error.type
    }

    /// The token counts a final usage chunk carries, when this frame is one.
    ///
    /// A request that asked for `stream_options: {"include_usage": true}` gets one extra frame
    /// before the sentinel whose `choices` array is **empty** and whose `usage` object holds the
    /// counts. Two properties of that frame decide how this is written:
    ///
    /// - it must not look like the end of the answer, which it does not: ``textDelta(in:)`` reads
    ///   `choices.first` and an empty array has none, so a usage chunk already contributes no text
    ///   and cannot truncate a draft;
    /// - `usage` may be explicitly `null` on a chunk that also carries content (a gateway that
    ///   cannot withhold the field relays it nulled), and a usage report with no number in it is
    ///   not a report — hence the ``StreamUsage/isEmpty`` guard rather than a non-nil check.
    /// - Parameter event: A dispatched frame.
    /// - Returns: The counts, or `nil` when this frame carries none.
    public static func usage(in event: ServerSentEvent) -> StreamUsage? {
        guard !isDone(event) else { return nil }
        struct Frame: Decodable {
            struct Usage: Decodable {
                var completionTokens: Int?
                var totalTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case completionTokens = "completion_tokens"
                    case totalTokens = "total_tokens"
                }
            }
            var usage: Usage?
        }
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(event.data.utf8)),
              let reported = frame.usage
        else { return nil }
        let value = StreamUsage(
            completionTokens: reported.completionTokens,
            totalTokens: reported.totalTokens
        )
        return value.isEmpty ? nil : value
    }

    /// The counts a whole recorded body ends with, when it carries a usage chunk.
    ///
    /// The last one wins: a stream is allowed to report cumulative usage more than once, and the
    /// answer to "what did this cost" is the final statement, not the first.
    /// - Parameter body: The complete `text/event-stream` body.
    /// - Returns: The counts, or `nil` when the stream reported none.
    public static func usage(in body: String) -> StreamUsage? {
        var latest: StreamUsage?
        for event in ServerSentEventParser.events(in: body) {
            if isDone(event) { break }
            if let reported = usage(in: event) { latest = reported }
        }
        return latest
    }

    /// Accumulates a whole recorded body into the answer it represents.
    /// - Parameter body: The complete `text/event-stream` body.
    /// - Returns: The concatenated content deltas, stopping at the `[DONE]` sentinel.
    public static func text(in body: String) -> String {
        var answer = ""
        for event in ServerSentEventParser.events(in: body) {
            if isDone(event) { break }
            if let delta = textDelta(in: event) { answer += delta }
        }
        return answer
    }
}
