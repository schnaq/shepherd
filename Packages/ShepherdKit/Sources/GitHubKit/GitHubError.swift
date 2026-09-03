import Foundation

/// Every failure `GitHubKit` can produce, as a typed value.
///
/// The cases carry only `Sendable`, `Equatable` payloads so that callers (and tests) can
/// switch on them and compare them without reaching for `NSError` bridging.
public enum GitHubError: Error, Sendable, Equatable, Hashable {
    /// A URL could not be built from the given components.
    case invalidURL(String)
    /// A connection-level failure: DNS, TLS, timeout, offline.
    case transport(message: String)
    /// `401` — the token is missing, expired or revoked.
    case unauthorized
    /// `403` that is not a rate limit — for example a token without the needed permission.
    case forbidden(message: String)
    /// A primary or secondary rate limit was hit.
    /// - Parameters:
    ///   - retryAfter: The `Retry-After` value in seconds, when the server sent one.
    ///   - resetAt: When the primary limit resets, from `x-ratelimit-reset`.
    case rateLimited(retryAfter: TimeInterval?, resetAt: Date?)
    /// `404` — the resource does not exist, or the token cannot see it.
    case notFound(resource: String)
    /// `422` — GitHub rejected the request body.
    case validationFailed(message: String)
    /// `405` on merge — the pull request is not in a mergeable state.
    case notMergeable(message: String)
    /// `409` on merge — the head moved since the SHA precondition was computed.
    case staleHead(expected: String, actual: String?)
    /// `409` that is not a merge SHA mismatch.
    case conflict(message: String)
    /// The GraphQL endpoint answered `200` with an `errors` array.
    case graphQL(messages: [String])
    /// A response body did not match the expected shape.
    case decoding(message: String)
    /// A response was larger than the caller is willing to hold in memory.
    ///
    /// Only the job-log read produces one (``GitHubClient/jobLog(repo:jobID:)``): a log is the
    /// one GitHub response with no useful upper bound, and refusing is honest where a silent
    /// prefix would be a digest of the wrong part of the run.
    case responseTooLarge(resource: String, bytes: Int, limit: Int)
    /// Any other non-success status code.
    case server(status: Int, message: String)
    /// The user rejected the device-flow authorisation request.
    case deviceFlowDenied
    /// The device code expired before the user approved it.
    case deviceFlowExpired
    /// The device-flow endpoint returned an error code Shepherd does not model.
    case deviceFlowError(code: String, description: String?)
    /// Refreshing an expired access token failed; the user must sign in again.
    case tokenRefreshFailed(message: String)
    /// No token is available for the requested account.
    case missingToken(login: String?)

    /// Whether retrying the same request later could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .transport, .rateLimited, .server:
            return true
        case .invalidURL, .unauthorized, .forbidden, .notFound, .validationFailed,
             .notMergeable, .staleHead, .conflict, .graphQL, .decoding, .responseTooLarge,
             .deviceFlowDenied, .deviceFlowExpired, .deviceFlowError, .tokenRefreshFailed,
             .missingToken:
            // `responseTooLarge` is not retryable for the reason it exists: the same request
            // would answer with the same oversized body.
            return false
        }
    }
}

extension GitHubError: LocalizedError {
    /// A human-readable description, suitable for surfacing in the UI.
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let string):
            return "Could not build a valid URL from “\(string)”."
        case .transport(let message):
            return "Could not reach GitHub: \(message)"
        case .unauthorized:
            return "GitHub rejected the credentials. Sign in again."
        case .forbidden(let message):
            return "GitHub refused the request: \(message)"
        case .rateLimited(let retryAfter, let resetAt):
            if let retryAfter {
                return "Rate limited by GitHub. Retry in \(Int(retryAfter.rounded())) s."
            }
            if let resetAt {
                return "Rate limited by GitHub until \(resetAt)."
            }
            return "Rate limited by GitHub."
        case .notFound(let resource):
            return "Not found: \(resource)"
        case .validationFailed(let message):
            return "GitHub rejected the data: \(message)"
        case .notMergeable(let message):
            return "This pull request cannot be merged: \(message)"
        case .staleHead(let expected, let actual):
            return "The pull request moved on (expected \(expected), found \(actual ?? "another commit"))."
        case .conflict(let message):
            return "Conflict: \(message)"
        case .graphQL(let messages):
            return "GraphQL error: \(messages.joined(separator: "; "))"
        case .decoding(let message):
            return "Unexpected response from GitHub: \(message)"
        case .responseTooLarge(let resource, let bytes, let limit):
            return "\(resource) is \(bytes / 1_048_576) MB, more than the \(limit / 1_048_576) MB Shepherd reads."
        case .server(let status, let message):
            return "GitHub returned \(status): \(message)"
        case .deviceFlowDenied:
            return "Authorisation was denied."
        case .deviceFlowExpired:
            return "The sign-in code expired. Start again."
        case .deviceFlowError(let code, let description):
            return description ?? "Sign-in failed (\(code))."
        case .tokenRefreshFailed(let message):
            return "Could not refresh the GitHub token: \(message)"
        case .missingToken(let login):
            if let login {
                return "No stored token for \(login)."
            }
            return "No stored GitHub token."
        }
    }
}
