import Foundation

/// One HTTP round trip, so a provider's *logic* can be tested without a network.
///
/// The seam exists for one reason and is shaped by it. A tool loop is the first thing in this
/// layer with real control flow in it — send, read the stop reason, run the calls, append the
/// results, send again, cap the whole thing at six reads — and every one of those decisions is a
/// bug that would only ever show up on a user's Mac, with their key, against a live endpoint.
/// With this in front of `URLSession`, the loop is driven by a scripted list of recorded answers
/// in a test instead (`ShepherdTests/IntelligenceToolLoopTests.swift`), which is the same trade
/// ``ModelListing`` and ``IntelligenceTiers`` already make.
///
/// It carries the request in pieces rather than as a `URLRequest`, and answers with the body and
/// the status code rather than with a `URLResponse`: everything crossing the boundary is then a
/// plain value, which keeps the protocol `Sendable` without a single claim about Foundation's
/// class types. It also models exactly one thing — a POST with a JSON body — because that is
/// what the tool loop needs. The streamed drafting paths deliberately do **not** go through it:
/// they need a byte stream, and a seam that had to model both would be a small `URLSession`
/// re-implementation rather than a test double.
protocol IntelligenceTransport: Sendable {
    /// Sends one request and waits for the whole answer.
    /// - Parameters:
    ///   - url: Where to post.
    ///   - headers: The request headers, keyed by field name.
    ///   - body: The JSON body.
    /// - Returns: The response body and its HTTP status code.
    /// - Throws: Whatever the transport failed with; a non-2xx status is *not* an error here, it
    ///   is a status code the caller interprets (a `400` about tools means something specific).
    func post(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> (data: Data, status: Int)
}

/// The real transport: `URLSession.shared`, which is what every other call in this layer uses.
struct IntelligenceURLSessionTransport: IntelligenceTransport {
    /// Creates the transport.
    init() {}

    func post(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        // Zero rather than a throw for a response that is not HTTP, matching what the
        // non-streaming calls in both cloud providers already do with the same expression: the
        // caller's status check then fails with the endpoint's own body as the message.
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
