import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single HTTP request, expressed as plain values so that tests can assert on it and so
/// that `URLRequest` (which lives in a different module on Linux) never leaks into the API.
public struct HTTPRequest: Sendable, Hashable {
    /// The HTTP method, uppercase (`"GET"`, `"POST"`, `"PUT"`, `"PATCH"`, `"DELETE"`).
    public var method: String
    /// The absolute request URL.
    public var url: URL
    /// Request headers. Keys are used verbatim.
    public var headers: [String: String]
    /// The request body, if any.
    public var body: Data?

    /// Creates a request.
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - url: The absolute URL.
    ///   - headers: Request headers.
    ///   - body: The request body.
    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// A single HTTP response.
public struct HTTPResponse: Sendable, Hashable {
    /// The HTTP status code.
    public var statusCode: Int
    /// Response headers, with **lowercased** keys — HTTP header names are case-insensitive
    /// and GitHub is inconsistent about their casing across endpoints.
    public var headers: [String: String]
    /// The response body. Empty for `204` and `304`.
    public var body: Data

    /// Creates a response.
    /// - Parameters:
    ///   - statusCode: The HTTP status code.
    ///   - headers: Response headers; keys are lowercased on the way in.
    ///   - body: The response body.
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        var lowercased: [String: String] = [:]
        lowercased.reserveCapacity(headers.count)
        for (key, value) in headers {
            lowercased[key.lowercased()] = value
        }
        self.headers = lowercased
        self.body = body
    }

    /// Reads a header case-insensitively.
    /// - Parameter name: The header name.
    /// - Returns: The header value, if present.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Whether the status code is in the `2xx` range.
    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// The seam between `GitHubKit` and the network.
///
/// Exactly one implementation talks to the network (``URLSessionTransport``, which wraps the
/// single injected `URLSession`); tests substitute a scripted transport so that every parsing
/// and error-mapping path is exercised without a socket.
public protocol HTTPTransport: Sendable {
    /// Performs a request.
    /// - Parameter request: The request to perform.
    /// - Returns: The response, whatever its status code — non-`2xx` statuses are *not*
    ///   errors at this level; ``GitHubClient`` maps them to ``GitHubError``.
    /// - Throws: ``GitHubError/transport(message:)`` for connection-level failures.
    func data(for request: HTTPRequest) async throws -> HTTPResponse
}

/// The production ``HTTPTransport``: one `URLSession` for the whole app.
///
/// The class is `@unchecked Sendable` because `URLSession` is documented as safe to use from
/// multiple threads, but is not universally annotated `Sendable` across the platforms this
/// package builds on (notably swift-corelibs-foundation). The stored session is immutable and
/// never mutated after `init`.
public final class URLSessionTransport: @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates a transport.
    /// - Parameters:
    ///   - session: The session to use. Defaults to `URLSession.shared`.
    ///   - timeout: Per-request timeout in seconds. Defaults to 30.
    public init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }
}

extension URLSessionTransport: HTTPTransport {
    /// Performs a request with the injected `URLSession`.
    /// - Parameter request: The request to perform.
    /// - Returns: The response.
    /// - Throws: ``GitHubError/transport(message:)`` when the session reports an error or an
    ///   answer that is not an HTTP response.
    public func data(for request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = timeout
        // Shepherd manages conditional requests itself; the URL cache must not answer for us.
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        // The session task is cancelled when the surrounding Swift task is. Without this the
        // request runs to completion after `Task.cancel()`, which is how a sweep stopped by
        // "Sign out & erase" still managed to write pull-request data back to disk.
        let box = URLSessionTaskBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(
                            throwing: GitHubError.transport(message: String(describing: error))
                        )
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(
                            throwing: GitHubError.transport(message: "Response was not an HTTP response")
                        )
                        return
                    }
                    var headers: [String: String] = [:]
                    for (key, value) in http.allHeaderFields {
                        guard let name = key as? String else { continue }
                        if let string = value as? String {
                            headers[name] = string
                        } else {
                            headers[name] = String(describing: value)
                        }
                    }
                    continuation.resume(
                        returning: HTTPResponse(
                            statusCode: http.statusCode,
                            headers: headers,
                            body: data ?? Data()
                        )
                    )
                }
                box.adopt(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Hands the in-flight `URLSessionTask` to the cancellation handler, which runs on an
/// arbitrary thread and therefore needs the handoff to be synchronised.
private final class URLSessionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    /// Stores the task, cancelling it immediately if cancellation already arrived.
    func adopt(_ task: URLSessionTask) {
        lock.lock()
        let cancelNow = isCancelled
        if !cancelNow { self.task = task }
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    /// Cancels the task, or arranges for it to be cancelled as soon as it is adopted.
    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}
