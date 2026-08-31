import Foundation

/// The endpoints Shepherd talks to, and the `User-Agent` it identifies itself with.
///
/// The values are computed with a non-trapping fallback rather than `URL(string:)!` — this
/// package contains no force-unwraps and no `fatalError`. The literals below are valid URLs,
/// so the fallback is unreachable; it exists so that the type system, not a crash, carries
/// the guarantee.
public enum GitHubDefaultURL {
    private static func url(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }

    /// `https://api.github.com` — the REST base.
    public static var api: URL { url("https://api.github.com") }
    /// `https://api.github.com/graphql` — the GraphQL endpoint.
    public static var graphQL: URL { url("https://api.github.com/graphql") }
    /// `https://github.com` — where the device flow and token endpoints live.
    public static var web: URL { url("https://github.com") }
    /// The `User-Agent` Shepherd sends. GitHub requires a non-empty one.
    public static var userAgent: String { "Shepherd (+https://github.com/schnaq/review)" }
}

/// Tunables for ``GitHubClient``.
public struct GitHubConfiguration: Sendable {
    /// The REST base URL. Override for GitHub Enterprise Server.
    public var apiBaseURL: URL
    /// The GraphQL endpoint URL.
    public var graphQLURL: URL
    /// The `User-Agent` header value.
    public var userAgent: String
    /// How many pull-request detail fetches may be in flight at once (ADR 0005 recommends
    /// about five to stay clear of the secondary rate limit).
    public var maxConcurrentDetailFetches: Int
    /// How many times a request is retried after a rate-limit or transport failure before
    /// the error is surfaced.
    public var maxRetries: Int
    /// The longest a single rate-limit backoff will wait before the error is surfaced
    /// instead. Prevents a one-hour primary-limit reset from stalling a sweep.
    public var maxBackoff: TimeInterval
    /// How many items a paginated REST listing requests per page (GitHub caps this at 100).
    public var pageSize: Int
    /// A hook that sees every request/response pair, for the in-app request log.
    public var requestLogger: (@Sendable (GitHubRequestLogEntry) -> Void)?

    /// Creates a configuration.
    public init(
        apiBaseURL: URL = GitHubDefaultURL.api,
        graphQLURL: URL = GitHubDefaultURL.graphQL,
        userAgent: String = GitHubDefaultURL.userAgent,
        maxConcurrentDetailFetches: Int = 5,
        maxRetries: Int = 2,
        maxBackoff: TimeInterval = 120,
        pageSize: Int = 100,
        requestLogger: (@Sendable (GitHubRequestLogEntry) -> Void)? = nil
    ) {
        self.apiBaseURL = apiBaseURL
        self.graphQLURL = graphQLURL
        self.userAgent = userAgent
        self.maxConcurrentDetailFetches = max(1, maxConcurrentDetailFetches)
        self.maxRetries = max(0, maxRetries)
        self.maxBackoff = max(0, maxBackoff)
        self.pageSize = min(100, max(1, pageSize))
        self.requestLogger = requestLogger
    }
}

/// One entry of the request log: what Shepherd asked GitHub and what came back.
///
/// Deliberately carries no request or response *bodies* — the log is shown in Settings and
/// must never leak a token or the contents of a private diff.
public struct GitHubRequestLogEntry: Sendable, Hashable {
    /// The HTTP method.
    public var method: String
    /// The request URL.
    public var url: URL
    /// The response status code, or `nil` when the request never got an answer.
    public var statusCode: Int?
    /// How long the request took.
    public var duration: TimeInterval
    /// Whether the answer was served from the conditional cache after a `304`.
    public var wasNotModified: Bool
    /// The rate-limit counters the response reported, if any.
    public var rateLimit: RateLimitSnapshot?
    /// When the request started.
    public var startedAt: Date

    /// Creates a log entry.
    public init(
        method: String,
        url: URL,
        statusCode: Int?,
        duration: TimeInterval,
        wasNotModified: Bool,
        rateLimit: RateLimitSnapshot?,
        startedAt: Date
    ) {
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.duration = duration
        self.wasNotModified = wasNotModified
        self.rateLimit = rateLimit
        self.startedAt = startedAt
    }
}
