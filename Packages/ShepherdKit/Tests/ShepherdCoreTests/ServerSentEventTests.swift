import XCTest
@testable import ShepherdCore

/// The pure half of streamed AI drafts (ADR 0007 amendment, plan §0.2).
///
/// Everything a streamed answer can do wrong to a reviewer's text field happens in the frames:
/// a keep-alive comment, a payload split across two `data:` lines, a first frame that carries a
/// role and no text, a `[DONE]` sentinel, an error announced after a 200. None of that needs a
/// key or a socket to reproduce, so the fixtures below are recorded shapes of both providers and
/// the assertions are on the text the reviewer would have seen.
final class ServerSentEventTests: XCTestCase {
    // MARK: - The line parser

    func testABlankLineDispatchesTheFrameAndAcommentDoesNot() {
        var parser = ServerSentEventParser()
        XCTAssertNil(parser.consume(": keep-alive"))
        XCTAssertNil(parser.consume(""), "a comment-only frame carries no data, so nothing is sent")
        XCTAssertNil(parser.consume("event: message"))
        XCTAssertNil(parser.consume("data: hello"))
        let event = parser.consume("")
        XCTAssertEqual(event?.event, "message")
        XCTAssertEqual(event?.data, "hello")
    }

    func testOnlyOneSpaceAfterTheColonIsDropped() {
        var parser = ServerSentEventParser()
        _ = parser.consume("data:  two spaces")
        XCTAssertEqual(parser.consume("")?.data, " two spaces")
    }

    func testSeveralDataLinesAreJoinedWithNewlines() {
        var parser = ServerSentEventParser()
        _ = parser.consume("data: {\"a\":")
        _ = parser.consume("data: 1}")
        XCTAssertEqual(parser.consume("")?.data, "{\"a\":\n1}")
    }

    func testIdAndRetryAreCarriedAndUnknownFieldsIgnored() {
        var parser = ServerSentEventParser()
        _ = parser.consume("id: 7")
        _ = parser.consume("retry: 2500")
        _ = parser.consume("something-new: whatever")
        _ = parser.consume("data: x")
        let event = parser.consume("")
        XCTAssertEqual(event?.id, "7")
        XCTAssertEqual(event?.retry, 2_500)
        XCTAssertEqual(event?.data, "x")
    }

    func testCarriageReturnsFromCRLFDoNotEndUpInTheData() {
        var parser = ServerSentEventParser()
        _ = parser.consume("data: hello\r")
        XCTAssertEqual(parser.consume("\r")?.data, "hello")
    }

    func testAnUnterminatedFrameIsNotDispatchedAtEndOfStream() {
        var parser = ServerSentEventParser()
        _ = parser.consume("data: half an object")
        XCTAssertNil(parser.finish(), "half a frame is not an answer")
    }

    func testEventsInBodyParsesAWholeRecordedResponse() {
        let body = """
            : ping

            event: a
            data: one

            event: b
            data: two

            """
        let events = ServerSentEventParser.events(in: body)
        XCTAssertEqual(events.map(\.event), ["a", "b"])
        XCTAssertEqual(events.map(\.data), ["one", "two"])
    }

    // MARK: - Anthropic frames

    /// A recorded `stream: true` response: the message envelope, two text deltas, the stops.
    // MARK: - OpenAI-compatible frames

    /// A recorded `stream: true` response: a role-only first frame, two content deltas, a
    /// `finish_reason` frame with a null content, then the sentinel.
    private let openAIBody = """
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1756800000,\
        "model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":""},\
        "finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1756800000,\
        "model":"test-model","choices":[{"index":0,"delta":{"content":"{\\"draft\\": \\"Confirm the"},\
        "finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1756800000,\
        "model":"test-model","choices":[{"index":0,"delta":{"content":" timeout is bounded.\\"}"},\
        "finish_reason":null}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1756800000,\
        "model":"test-model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """

    func testOpenAIDeltasAccumulateAndTheEmptyOnesAreSkipped() {
        XCTAssertEqual(
            OpenAICompatibleStreamDecoder.text(in: openAIBody),
            "{\"draft\": \"Confirm the timeout is bounded.\"}"
        )
    }

    func testOpenAIDoneSentinelIsRecognisedAndCarriesNoText() {
        let events = ServerSentEventParser.events(in: openAIBody)
        XCTAssertEqual(events.count, 5)
        XCTAssertTrue(OpenAICompatibleStreamDecoder.isDone(events[4]))
        XCTAssertNil(OpenAICompatibleStreamDecoder.textDelta(in: events[4]))
        XCTAssertFalse(OpenAICompatibleStreamDecoder.isDone(events[0]))
        XCTAssertNil(
            OpenAICompatibleStreamDecoder.textDelta(in: events[0]),
            "the role-only frame is not text"
        )
    }

    func testTextAfterTheDoneSentinelIsNotPartOfTheAnswer() {
        let body = """
            data: {"choices":[{"delta":{"content":"kept"}}]}

            data: [DONE]

            data: {"choices":[{"delta":{"content":" dropped"}}]}

            """
        XCTAssertEqual(OpenAICompatibleStreamDecoder.text(in: body), "kept")
    }

    func testOpenAIErrorFrameIsReadable() {
        let event = ServerSentEvent(data: "{\"error\":{\"message\":\"context length exceeded\"}}")
        XCTAssertEqual(
            OpenAICompatibleStreamDecoder.errorMessage(in: event),
            "context length exceeded"
        )
        XCTAssertNil(OpenAICompatibleStreamDecoder.textDelta(in: event))
    }

    func testAServerThatOmitsTheSentinelStillProducesTheWholeAnswer() {
        let body = """
            data: {"choices":[{"delta":{"content":"a"}}]}

            data: {"choices":[{"delta":{"content":"b"}}]}

            """
        XCTAssertEqual(OpenAICompatibleStreamDecoder.text(in: body), "ab")
    }

    // MARK: - The final usage chunk (plan §3.K)

    /// The same recorded response as ``openAIBody``, with the extra frame a request that sent
    /// `stream_options: {"include_usage": true}` gets: empty `choices`, and the counts.
    private let openAIBodyWithUsage = """
        data: {"id":"chatcmpl-1","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk",\
        "choices":[{"index":0,"delta":{"content":"Confirm the timeout."}}]}

        data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],\
        "usage":{"prompt_tokens":1200,"completion_tokens":48,"total_tokens":1248}}

        data: [DONE]

        """

    func testAUsageChunkCarriesNoTextAndDoesNotEndTheAnswer() {
        XCTAssertEqual(
            OpenAICompatibleStreamDecoder.text(in: openAIBodyWithUsage),
            "Confirm the timeout.",
            "an empty choices array contributes nothing and truncates nothing"
        )
        let events = ServerSentEventParser.events(in: openAIBodyWithUsage)
        XCTAssertEqual(events.count, 4)
        XCTAssertNil(OpenAICompatibleStreamDecoder.textDelta(in: events[2]))
        XCTAssertFalse(OpenAICompatibleStreamDecoder.isDone(events[2]))
        XCTAssertNil(OpenAICompatibleStreamDecoder.errorMessage(in: events[2]))
        // The sentinel still ends the stream, and it is not a usage chunk.
        XCTAssertTrue(OpenAICompatibleStreamDecoder.isDone(events[3]))
        XCTAssertNil(OpenAICompatibleStreamDecoder.usage(in: events[3]))
    }

    func testTheFinalUsageChunkIsReadWhenItIsThere() {
        let usage = OpenAICompatibleStreamDecoder.usage(in: openAIBodyWithUsage)
        XCTAssertEqual(usage, StreamUsage(completionTokens: 48, totalTokens: 1248))
        // A stream nobody asked for usage on reports none, and that is not a failure.
        XCTAssertNil(OpenAICompatibleStreamDecoder.usage(in: openAIBody))
    }

    func testAPartialOrNulledUsageObjectIsToleratedRatherThanBelieved() {
        let onlyTotal = ServerSentEvent(data: "{\"choices\":[],\"usage\":{\"total_tokens\":9}}")
        XCTAssertEqual(
            OpenAICompatibleStreamDecoder.usage(in: onlyTotal),
            StreamUsage(totalTokens: 9)
        )
        // A gateway that cannot withhold the field nulls it on a content chunk; a report with no
        // number in it is not a report.
        let nulled = ServerSentEvent(
            data: "{\"choices\":[{\"delta\":{\"content\":\"a\"}}],\"usage\":null}"
        )
        XCTAssertNil(OpenAICompatibleStreamDecoder.usage(in: nulled))
        XCTAssertEqual(OpenAICompatibleStreamDecoder.textDelta(in: nulled), "a")
        let empty = ServerSentEvent(data: "{\"choices\":[],\"usage\":{}}")
        XCTAssertNil(OpenAICompatibleStreamDecoder.usage(in: empty))
    }

    func testTheLastUsageStatementWins() {
        let body = """
            data: {"choices":[],"usage":{"total_tokens":1}}

            data: {"choices":[],"usage":{"total_tokens":2}}

            data: [DONE]

            data: {"choices":[],"usage":{"total_tokens":99}}

            """
        XCTAssertEqual(
            OpenAICompatibleStreamDecoder.usage(in: body),
            StreamUsage(totalTokens: 2),
            "and nothing after the sentinel counts"
        )
    }

    func testGarbageFramesAreIgnoredRatherThanThrown() {
        let event = ServerSentEvent(data: "not json at all")
        XCTAssertNil(OpenAICompatibleStreamDecoder.textDelta(in: event))
        XCTAssertNil(OpenAICompatibleStreamDecoder.errorMessage(in: event))
    }
}
