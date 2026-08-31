import Foundation

/// A snapshot of GitHub's primary rate-limit counters, parsed from `x-ratelimit-*` headers.
///
/// GitHub keeps separate budgets for REST core, search and GraphQL (see
/// `docs/research/research-github-stack.md`); ``resource`` says which bucket the snapshot
/// describes.
public struct RateLimitSnapshot: Sendable, Hashable {
    /// The bucket name GitHub reported, e.g. `"core"`, `"search"`, `"graphql"`.
    public var resource: String?
    /// The bucket's total budget for the window.
    public var limit: Int?
    /// How many requests are left in the window.
    public var remaining: Int?
    /// How many requests the current request consumed.
    public var used: Int?
    /// When the window resets.
    public var resetAt: Date?
    /// When this snapshot was taken.
    public var observedAt: Date

    /// Creates a snapshot.
    public init(
        resource: String? = nil,
        limit: Int? = nil,
        remaining: Int? = nil,
        used: Int? = nil,
        resetAt: Date? = nil,
        observedAt: Date = Date()
    ) {
        self.resource = resource
        self.limit = limit
        self.remaining = remaining
        self.used = used
        self.resetAt = resetAt
        self.observedAt = observedAt
    }

    /// Parses the rate-limit headers of a response.
    /// - Parameters:
    ///   - response: The response to read headers from.
    ///   - observedAt: The observation time. Defaults to now.
    /// - Returns: A snapshot, or `nil` when the response carried no rate-limit headers.
    public static func parse(from response: HTTPResponse, observedAt: Date = Date()) -> RateLimitSnapshot? {
        let limit = response.header("x-ratelimit-limit").flatMap(Int.init)
        let remaining = response.header("x-ratelimit-remaining").flatMap(Int.init)
        let used = response.header("x-ratelimit-used").flatMap(Int.init)
        let resource = response.header("x-ratelimit-resource")
        let reset = response.header("x-ratelimit-reset")
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }
        if limit == nil, remaining == nil, used == nil, resource == nil, reset == nil {
            return nil
        }
        return RateLimitSnapshot(
            resource: resource,
            limit: limit,
            remaining: remaining,
            used: used,
            resetAt: reset,
            observedAt: observedAt
        )
    }

    /// Whether the bucket is exhausted.
    public var isExhausted: Bool { (remaining ?? 1) <= 0 }
}

/// Rate-limit related decisions taken from a response.
public enum RateLimitPolicy {
    /// How long to wait before retrying a `403`/`429`, if the response says so.
    ///
    /// Checks `retry-after` first (the secondary-limit signal), then falls back to
    /// `x-ratelimit-reset` when the primary budget is exhausted.
    /// - Parameters:
    ///   - response: The rejected response.
    ///   - now: The current time.
    /// - Returns: The number of seconds to wait, or `nil` when the response gives no hint.
    public static func retryDelay(for response: HTTPResponse, now: Date) -> TimeInterval? {
        if let retryAfter = response.header("retry-after") {
            // GitHub sends an integer number of seconds. The HTTP-date form is legal but
            // GitHub does not use it, so it is deliberately not parsed here.
            if let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)) {
                return max(0, seconds)
            }
        }
        guard let snapshot = RateLimitSnapshot.parse(from: response, observedAt: now),
              snapshot.isExhausted,
              let resetAt = snapshot.resetAt
        else { return nil }
        return max(0, resetAt.timeIntervalSince(now))
    }

    /// Whether a `403` should be read as a rate limit rather than a permission problem.
    /// - Parameter response: The rejected response.
    public static func isRateLimit(_ response: HTTPResponse) -> Bool {
        if response.statusCode == 429 { return true }
        guard response.statusCode == 403 else { return false }
        if response.header("retry-after") != nil { return true }
        if let remaining = response.header("x-ratelimit-remaining").flatMap(Int.init),
           remaining <= 0 {
            return true
        }
        let body = String(decoding: response.body, as: UTF8.self).lowercased()
        return body.contains("rate limit") || body.contains("secondary rate")
    }
}
