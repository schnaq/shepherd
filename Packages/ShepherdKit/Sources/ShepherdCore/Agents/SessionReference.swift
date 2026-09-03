import Foundation

/// The return address of the coding session that wrote a pull request's code (ADR 0030).
///
/// Claude Code writes a `Claude-Session:` trailer into every commit it makes, so an agent pull
/// request already carries the way back to the conversation that produced it — no new read, no
/// new host, nothing to store. Parsing it is pure, and deliberately strict: a trailer Shepherd
/// does not understand is skipped rather than guessed at, because the value ends up in a command
/// line the *user's own* CLI runs.
///
/// Two shapes exist, and they are not interchangeable:
/// - ``Kind/local`` — a session on this Mac, addressable by id (`session_…`, or `local:<id>`);
/// - ``Kind/remote`` — a session behind a URL (`https://claude.ai/code/session_…`), which the
///   installed CLI may or may not be able to address at all. What Shepherd does with that is a
///   settings question (an empty template means "offer the link instead"), never a credential
///   question: Shepherd holds no Anthropic credentials of any kind (ADR 0011).
public struct SessionReference: Sendable, Codable, Hashable, Identifiable {
    /// Where the session lives.
    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        /// A session on this machine, addressed by its id.
        case local
        /// A session behind a URL.
        case remote
    }

    /// The session id, e.g. `session_01KcEgovTAxjdwUVJZMQSd6q`.
    public let id: String
    /// The URL the trailer carried, when it carried one. `nil` for a bare or `local:` id.
    public let url: URL?
    /// The URL's host, when there was a URL. `nil` for a local reference.
    public let host: String?
    /// Whether the session is local or remote.
    public let kind: Kind

    /// Creates a reference.
    /// - Parameters:
    ///   - id: The session id.
    ///   - url: The URL the trailer carried, if any.
    ///   - host: The URL's host, if any.
    ///   - kind: Where the session lives.
    public init(id: String, url: URL? = nil, host: String? = nil, kind: Kind) {
        self.id = id
        self.url = url
        self.host = host
        self.kind = kind
    }

    /// The trailer key Shepherd reads, compared case-insensitively.
    public static let trailerKey = "Claude-Session"

    /// The prefix a session id carries in both shapes Claude Code writes.
    public static let idPrefix = "session_"

    /// The prefix that names a local session explicitly.
    public static let localPrefix = "local:"

    /// Every session reference in a list of commit trailers, in the order they appear.
    ///
    /// A line that is not a `Claude-Session:` trailer, or whose value is not one of the three
    /// understood shapes, is skipped: a malformed return address must produce no reference at
    /// all rather than a reference to nothing.
    /// - Parameter trailers: Trailer lines as ``CommitInfo/trailers`` produces them.
    /// - Returns: The references found, order preserved.
    public static func parse(trailers: [String]) -> [SessionReference] {
        trailers.compactMap { line -> SessionReference? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare(trailerKey) == .orderedSame else { return nil }
            let value = line[line.index(after: colon)...]
            return reference(forTrailerValue: String(value))
        }
    }

    /// One reference from one trailer's value.
    ///
    /// Public because it is the whole grammar in one place, and a caller that already has the
    /// value (a test, a settings field) should not have to rebuild the `Key: value` line.
    /// - Parameter value: Everything after the colon.
    /// - Returns: The reference, or `nil` when the value is not one Shepherd understands.
    public static func reference(forTrailerValue value: String) -> SessionReference? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            guard let url = URL(string: trimmed),
                  let host = url.host,
                  !host.isEmpty,
                  // The last path component, computed from `path` rather than `pathComponents`,
                  // so a trailing slash and a query string behave the same on every platform.
                  let identifier = url.path.split(separator: "/").last.map(String.init),
                  isSessionID(identifier)
            else { return nil }
            return SessionReference(id: identifier, url: url, host: host, kind: .remote)
        }

        if lowered.hasPrefix(localPrefix) {
            let identifier = String(trimmed.dropFirst(localPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard isIdentifier(identifier) else { return nil }
            return SessionReference(id: identifier, kind: .local)
        }

        guard isSessionID(trimmed) else { return nil }
        return SessionReference(id: trimmed, kind: .local)
    }

    /// The reference a pull request should be answered at, or `nil` when it has none.
    ///
    /// The **last** commit's reference wins, and within one commit the last trailer wins: a fix
    /// round pushed from a second session must be answered at that second session, not at the
    /// one that opened the pull request.
    /// - Parameter commits: The head branch's commits, oldest first, as
    ///   ``PullRequestDetail/commits`` holds them.
    /// - Returns: The most recent reference.
    public static func mostRecent(in commits: [CommitInfo]) -> SessionReference? {
        for commit in commits.reversed() {
            if let last = parse(trailers: commit.trailers).last { return last }
        }
        return nil
    }

    /// Whether a string is a session id of the shape Claude Code writes.
    private static func isSessionID(_ candidate: String) -> Bool {
        guard candidate.count > idPrefix.count,
              candidate.lowercased().hasPrefix(idPrefix)
        else { return false }
        return isIdentifier(candidate)
    }

    /// Whether a string is safe to carry as an id: non-empty, and letters, digits, `_`, `-`, `.`.
    ///
    /// Not a security boundary — the id becomes one element of an argv array and never reaches a
    /// shell — but a value that cannot be an id at all should not become a command argument.
    private static func isIdentifier(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        return candidate.allSatisfy { character in
            character.isLetter || character.isNumber
                || character == "_" || character == "-" || character == "."
        }
    }
}
