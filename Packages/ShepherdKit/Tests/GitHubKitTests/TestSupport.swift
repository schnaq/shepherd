import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

/// Loads the recorded API payloads in `Tests/GitHubKitTests/Fixtures`.
///
/// Every parsing test in this target runs against these files rather than against the
/// network: the shapes come from GitHub's documentation and are the contract this client is
/// written to.
enum Fixture {
    enum LoadError: Error {
        case missing(String)
    }

    static func data(_ name: String) throws -> Data {
        if let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) {
            return try Data(contentsOf: url)
        }
        // Fallback for toolchains that do not expose the copied resource directory.
        let sourceRelative = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: sourceRelative.path) else {
            throw LoadError.missing(name)
        }
        return try Data(contentsOf: sourceRelative)
    }

    static func response(
        _ name: String,
        status: Int = 200,
        headers: [String: String] = [:]
    ) throws -> HTTPResponse {
        let body = try data(name)
        return HTTPResponse(statusCode: status, headers: headers, body: body)
    }

    static func response(
        json: String,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))
    }

    static func empty(status: Int, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: Data())
    }
}

/// A scripted ``HTTPTransport``.
///
/// Responses can be matched by a fragment of the request URL or of the request body (which is
/// how GraphQL operations are told apart, since they all POST to the same URL), or simply
/// dequeued in order.
actor MockTransport: HTTPTransport {
    private struct Route {
        let fragment: String
        var responses: [HTTPResponse]
    }

    private var routes: [Route] = []
    private var queue: [HTTPResponse] = []
    private var thrownError: GitHubError?
    private var throwCount = 0

    /// Every request the client made, in order.
    private(set) var requests: [HTTPRequest] = []

    init() {}

    /// Adds a response returned for requests whose URL or body contains `fragment`.
    ///
    /// Repeated calls with the same fragment queue up: the first matching request gets the
    /// first response, and the last response repeats once the queue is drained.
    func route(_ fragment: String, _ response: HTTPResponse) {
        if let index = routes.firstIndex(where: { $0.fragment == fragment }) {
            routes[index].responses.append(response)
        } else {
            routes.append(Route(fragment: fragment, responses: [response]))
        }
    }

    /// Adds a response returned when nothing else matches, in order.
    func enqueue(_ response: HTTPResponse) {
        queue.append(response)
    }

    /// Makes the next `count` requests fail at the connection level.
    func failNext(_ count: Int, with error: GitHubError) {
        thrownError = error
        throwCount = count
    }

    func data(for request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)

        if throwCount > 0, let thrownError {
            throwCount -= 1
            throw thrownError
        }

        let bodyText = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let urlText = request.url.absoluteString
        for index in routes.indices {
            let fragment = routes[index].fragment
            guard urlText.contains(fragment) || bodyText.contains(fragment) else { continue }
            if routes[index].responses.count > 1 {
                return routes[index].responses.removeFirst()
            }
            return routes[index].responses[0]
        }

        if !queue.isEmpty {
            return queue.removeFirst()
        }
        return HTTPResponse(
            statusCode: 501,
            headers: [:],
            body: Data("{\"message\":\"MockTransport had no response for \(urlText)\"}".utf8)
        )
    }

    /// The single request made so far, or a test failure.
    func onlyRequest(file: StaticString = #filePath, line: UInt = #line) -> HTTPRequest? {
        guard requests.count == 1 else {
            XCTFail("expected exactly one request, got \(requests.count)", file: file, line: line)
            return nil
        }
        return requests[0]
    }

    /// The first recorded request whose URL contains `fragment`.
    func firstRequest(containing fragment: String) -> HTTPRequest? {
        requests.first { $0.url.absoluteString.contains(fragment) }
    }
}

extension GitHubClient {
    /// Builds a client wired to a mock transport, with a detector that knows Claude Code and
    /// Dependabot and a sleeper that never actually waits.
    static func makeForTesting(
        transport: MockTransport,
        configuration: GitHubConfiguration = GitHubConfiguration(),
        cache: any ConditionalCache = InMemoryConditionalCache(),
        sleeper: any Sleeping = RecordingSleeper()
    ) -> GitHubClient {
        GitHubClient(
            configuration: configuration,
            transport: transport,
            tokenProvider: StaticTokenProvider("ghu_test-token"),
            agentDetector: AgentDetector(registry: TestRegistry.registry),
            cache: cache,
            sleeper: sleeper,
            now: { Date(timeIntervalSince1970: 1_756_600_000) }
        )
    }
}

enum TestRegistry {
    static let registry = AgentRegistry(agents: [
        AgentRegistryEntry(
            id: "claude-code",
            displayName: "Claude Code",
            loginPatterns: ["claude[bot]", "claude-code[bot]"],
            branchPrefixes: ["claude/"],
            commitTrailers: ["Co-Authored-By: Claude"]
        ),
        AgentRegistryEntry(
            id: "dependabot",
            displayName: "Dependabot",
            loginPatterns: ["dependabot[bot]"],
            branchPrefixes: ["dependabot/"],
            commitTrailers: []
        ),
    ])

    static let detector = AgentDetector(registry: registry)
}
