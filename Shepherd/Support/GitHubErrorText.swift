import Foundation
import GitHubKit
import ShepherdCore
import ShepherdSync

/// The German half of ``GitHubKit/GitHubError``: one localised sentence per case (ADR 0022, the
/// 2026-09-22 amendment).
///
/// The split ``ShepherdCore/EvidenceFact/Kind`` already makes, for the reason it makes it.
/// `GitHubKit` is Foundation-only, compiles and tests on Linux and has no bundle to look a catalog
/// up in, so its `errorDescription` can only ever be English — and that English reached a toast,
/// a settings card, the sync tooltip and the outbox list on a German Mac. The package keeps its
/// English sentence (tests assert on it, logs read it, and it is the fallback for a stored error a
/// newer build cannot decode); this is what the app shows.
///
/// Three properties of the translation are decisions rather than wording:
///
/// - **What GitHub said is interpolated verbatim.** A `message`, a device-flow `description`, a
///   resource name: GitHub's words or somebody's identifier, in whatever language GitHub wrote
///   them. The sentence around them is Shepherd's and is translated.
/// - **A date is formatted before it reaches a key**, so the catalog sees a `%@` and the reader
///   sees their own locale's time rather than `Date`'s debug description.
/// - **The review vocabulary stays English inside the German**: pull request, merge, commit,
///   token — ADR 0022's rule.
extension GitHubError {
    /// The error as one sentence in the user's language, ready to show.
    /// - Parameter bundle: Where to look the catalog up. `Bundle.main` in the app; a test passes
    ///   the compiled `de.lproj` so what it asserts cannot depend on the runner's language.
    /// - Returns: The sentence.
    func localizedMessage(bundle: Bundle = .main) -> String {
        switch self {
        case .invalidURL(let string):
            return String(localized: "Could not build a valid URL from “\(string)”.", bundle: bundle)
        case .transport(let message):
            return String(localized: "Could not reach GitHub: \(message)", bundle: bundle)
        case .unauthorized:
            return String(
                localized: "GitHub rejected the credentials. Sign in again.",
                bundle: bundle
            )
        case .forbidden(let message):
            return String(localized: "GitHub refused the request: \(message)", bundle: bundle)
        case .rateLimited(let retryAfter, let resetAt):
            if let retryAfter {
                return String(
                    localized: "Rate limited by GitHub. Retry in \(Int(retryAfter.rounded())) s.",
                    bundle: bundle
                )
            }
            if let resetAt {
                let time = resetAt.formatted(date: .omitted, time: .shortened)
                return String(localized: "Rate limited by GitHub until \(time).", bundle: bundle)
            }
            return String(localized: "Rate limited by GitHub.", bundle: bundle)
        case .notFound(let resource):
            return String(localized: "Not found: \(resource)", bundle: bundle)
        case .validationFailed(let message):
            return String(localized: "GitHub rejected the data: \(message)", bundle: bundle)
        case .notMergeable(let message):
            return String(
                localized: "This pull request cannot be merged: \(message)",
                bundle: bundle
            )
        case .staleHead(let expected, let actual):
            // Two keys rather than a translated "another commit" interpolated into one: the
            // fallback is part of the sentence, and German wants it in a different case.
            if let actual {
                return String(
                    localized: "The pull request moved on (expected \(expected), found \(actual)).",
                    bundle: bundle
                )
            }
            return String(
                localized: "The pull request moved on (expected \(expected), found another commit).",
                bundle: bundle
            )
        case .conflict(let message):
            return String(localized: "Conflict: \(message)", bundle: bundle)
        case .graphQL(let messages):
            let joined = messages.joined(separator: "; ")
            return String(localized: "GraphQL error: \(joined)", bundle: bundle)
        case .decoding(let message):
            return String(localized: "Unexpected response from GitHub: \(message)", bundle: bundle)
        case .responseTooLarge(let resource, let bytes, let limit):
            return String(
                localized: "\(resource) is \(Int(bytes / 1_048_576)) MB, more than the \(Int(limit / 1_048_576)) MB Shepherd reads.",
                bundle: bundle
            )
        case .server(let status, let message):
            return String(localized: "GitHub returned \(status): \(message)", bundle: bundle)
        case .deviceFlowDenied:
            return String(localized: "Authorisation was denied.", bundle: bundle)
        case .deviceFlowExpired:
            return String(localized: "The sign-in code expired. Start again.", bundle: bundle)
        case .deviceFlowError(let code, let description):
            // GitHub's own description when it sent one, as the English reading does.
            if let description { return description }
            return String(localized: "Sign-in failed (\(code)).", bundle: bundle)
        case .tokenRefreshFailed(let message):
            return String(
                localized: "Could not refresh the GitHub token: \(message)",
                bundle: bundle
            )
        case .missingToken(let login):
            if let login {
                return String(localized: "No stored token for \(login).", bundle: bundle)
            }
            return String(localized: "No stored GitHub token.", bundle: bundle)
        }
    }
}

extension SyncFailure {
    /// The failure as the title bar's tooltip says it, in the user's language.
    ///
    /// Re-composed from ``SyncFailure/error`` and ``SyncFailure/context`` rather than read off
    /// ``SyncFailure/message``, which is English by construction (ADR 0022, 2026-09-22
    /// amendment). A failure that was not a GitHub error — a database error, say — has no typed
    /// reading, and its English `message` is shown as it is: it is a technical description either
    /// way, and there is nothing to re-compose it from.
    /// - Parameter bundle: Where to look the catalog up.
    /// - Returns: The sentence.
    func localizedMessage(bundle: Bundle = .main) -> String {
        guard let error else { return message }
        let reason = error.localizedMessage(bundle: bundle)
        switch context {
        case .none:
            return reason
        case .pullRequestDetail(let slug):
            // The slug is an identifier, and the separator is punctuation: nothing to translate.
            return "\(slug): \(reason)"
        case .issueSweep:
            return String(localized: "Issue sweep: \(reason)", bundle: bundle)
        case .notificationsUnavailable:
            return String(
                localized: "This token cannot read GitHub notifications, so Shepherd keeps the inbox current with its regular sweep instead. (\(reason))",
                bundle: bundle
            )
        case .closedButCommentNotPosted(let slug):
            return String(
                localized: "\(slug) was closed, but the comment could not be posted: \(reason)",
                bundle: bundle
            )
        }
    }
}

extension OutboxItem {
    /// Why the row failed, in the user's language, or `nil` when nothing was recorded.
    ///
    /// The row keeps two readings of its last error (migration v8): ``OutboxItem/lastError``, the
    /// English sentence, and ``OutboxItem/lastErrorCode``, the ``GitHubKit/GitHubError`` it came
    /// from. The code is preferred whenever it decodes; a row written before v8, a failure that was
    /// not a GitHub error, or a code a newer build wrote falls back to the English text rather than
    /// to nothing.
    var localizedLastError: String? {
        if let code = lastErrorCode, let error = GitHubError(storageCode: code) {
            return error.localizedMessage()
        }
        return lastError
    }
}

extension TrackRecordBackfillFailure {
    /// What went wrong for this repository, in the user's language when it was a GitHub error.
    var localizedMessage: String {
        error?.localizedMessage() ?? message
    }
}
