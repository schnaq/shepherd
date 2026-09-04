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
/// It carries the request in pieces rather than as a `URLRequest`, and answers with the body, the
/// status code and (through ``send(url:headers:body:)``) the response headers rather than with a
/// `URLResponse`: everything crossing the boundary is then a plain value, which keeps the protocol
/// `Sendable` without a single claim about Foundation's class types. It also models exactly one
/// thing — a POST with a JSON body — because that is what the callers need. The **streamed**
/// drafting paths deliberately do not go through it: they need a byte stream, and a seam that had
/// to model both would be a small `URLSession` re-implementation rather than a test double.
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

    /// The same round trip, with the response's **headers** as well.
    ///
    /// The seam grew this rather than changing ``post(url:headers:body:)``'s return type, and the
    /// reason is what the extra field is for. Two things a request can only learn from a response
    /// header are now read (plan §3.K): who actually served the answer, and how long a `429`
    /// asked Shepherd to wait. Neither is required — an endpoint that sends neither header
    /// behaves exactly as before — so a doubles-only concern (every test transport would have to
    /// grow a field it does not use) is answered by a default implementation that forwards to
    /// `post` and reports no headers. A transport that means to expose them overrides this;
    /// ``IntelligenceURLSessionTransport`` does.
    /// - Parameters:
    ///   - url: Where to post.
    ///   - headers: The request headers, keyed by field name.
    ///   - body: The JSON body.
    /// - Returns: The response body, its status code, and its headers keyed by field name.
    /// - Throws: Whatever the transport failed with; a non-2xx status is not an error here.
    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> IntelligenceHTTPResponse
}

/// One finished HTTP round trip, as plain values.
///
/// A struct rather than a third tuple element, because the third element is the one a caller
/// usually ignores and a three-wide tuple at every call site reads worse than a named field.
/// Everything in it is `Sendable`, so nothing about `URLResponse`'s class types crosses the seam.
struct IntelligenceHTTPResponse: Sendable {
    /// The response body.
    var data: Data
    /// The HTTP status code, or `0` for a response that was not HTTP.
    var status: Int
    /// The response headers, keyed by field name in whatever spelling the server used. Read
    /// case-insensitively (``ServedBy/parse(headers:)``,
    /// ``IntelligenceRetryAfter/delay(headers:now:)``), because RFC 9110 says field names are.
    var headers: [String: String]

    /// Creates a response.
    /// - Parameters:
    ///   - data: The body.
    ///   - status: The status code.
    ///   - headers: The response headers.
    init(data: Data, status: Int, headers: [String: String] = [:]) {
        self.data = data
        self.status = status
        self.headers = headers
    }
}

extension IntelligenceTransport {
    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> IntelligenceHTTPResponse {
        let (data, status) = try await post(url: url, headers: headers, body: body)
        return IntelligenceHTTPResponse(data: data, status: status)
    }
}

/// The real transport: ``CredentialSafeSession``, which is what every call in this layer that
/// carries the user's own key uses — a session whose redirects cannot take that key to a host the
/// user never named (ADR 0024's `RedirectPolicy`).
struct IntelligenceURLSessionTransport: IntelligenceTransport {
    /// Creates the transport.
    init() {}

    func post(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> (data: Data, status: Int) {
        let response = try await send(url: url, headers: headers, body: body)
        return (response.data, response.status)
    }

    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> IntelligenceHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        let (data, response) = try await CredentialSafeSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        // Zero rather than a throw for a response that is not HTTP, matching what the
        // non-streaming calls in both cloud providers already do with the same expression: the
        // caller's status check then fails with the endpoint's own body as the message.
        return IntelligenceHTTPResponse(
            data: data,
            status: http?.statusCode ?? 0,
            headers: IntelligenceURLSessionTransport.fields(of: http)
        )
    }

    /// A response's headers as a plain dictionary.
    ///
    /// `allHeaderFields` is `[AnyHashable: Any]`, which is neither `Sendable` nor safe to hand
    /// across the seam, so it is flattened to `[String: String]` here — the one place that knows
    /// about `HTTPURLResponse` at all.
    /// - Parameter response: The response, when it was an HTTP one.
    /// - Returns: The header fields, keyed as the server spelled them.
    static func fields(of response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            fields[name] = String(describing: value)
        }
        return fields
    }
}
