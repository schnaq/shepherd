import Foundation

/// A reference to a GitHub repository, identified by its owner and name.
///
/// `RepoRef` is the smallest value that uniquely identifies a repository in Shepherd; it is
/// used as a dictionary key, a grouping facet and a persistence key (via ``fullName``).
public struct RepoRef: Sendable, Codable, Hashable, Identifiable {
    /// The account (user or organisation) that owns the repository, e.g. `"schnaq"`.
    public let owner: String
    /// The repository name without the owner, e.g. `"review"`.
    public let name: String

    /// Creates a repository reference.
    /// - Parameters:
    ///   - owner: The owning user or organisation login.
    ///   - name: The repository name without the owner prefix.
    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// The canonical `owner/name` string GitHub uses in URLs and search queries.
    public var fullName: String { "\(owner)/\(name)" }

    /// `RepoRef` is identified by its ``fullName``.
    public var id: String { fullName }

    /// Whether two references point at the same repository, ignoring case.
    ///
    /// GitHub treats owner and repository names case-insensitively while preserving the casing
    /// it was given, so `Schnaq/Review` and `schnaq/review` are one repository. ``Hashable``
    /// conformance stays exact — it is a persistence key — which is why comparing identity
    /// needs its own operation: a reference that came from outside the app (a `shepherd://`
    /// deep link, a URL the user pasted) carries whatever casing was typed.
    /// - Parameter other: The reference to compare with.
    public func isSameRepository(as other: RepoRef) -> Bool {
        owner.lowercased() == other.owner.lowercased()
            && name.lowercased() == other.name.lowercased()
    }

    /// Parses an `owner/name` string.
    /// - Parameter fullName: A string of the form `owner/name`.
    /// - Returns: The parsed reference, or `nil` if the string is not exactly two path components.
    public static func parse(fullName: String) -> RepoRef? {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return RepoRef(owner: String(parts[0]), name: String(parts[1]))
    }

    /// Reads a repository out of whatever a person typed or pasted.
    ///
    /// Tolerant about shape, strict about content. People have the repository's *page* in the
    /// clipboard far more often than its `owner/name`, and usually the page of a pull request
    /// inside it — so a browser URL, a clone URL, an SSH remote and a bare `owner/name` all
    /// arrive here and all mean the same repository.
    ///
    /// What it will not do is guess. The content rules stay
    /// ``DeepLinkValidation/repository(fullName:)``'s, the same ones the `shepherd://` grammar
    /// enforces: ASCII only, GitHub's length limits, no traversal-shaped name. That matters more
    /// than it looks, because the result goes straight into a GitHub search expression where a
    /// space would silently turn one qualifier into two.
    ///
    /// Two refusals are deliberate rather than incidental. Another host is refused outright,
    /// including one that merely *contains* `github.com` further down its path
    /// (`https://evil.com/github.com/a/b`), so the leading segment is the host or nothing. And a
    /// three-part path with no host at all — `a/b/c` — is a typo, not a repository: only a URL
    /// earns the right to carry segments past the name.
    /// - Parameter userInput: What the user wrote. Whitespace, scheme, host, `.git`, a deeper
    ///   path, a query and a fragment are all removed if present.
    /// - Returns: The repository, or `nil` if nothing valid could be read out of the text.
    public static func parse(userInput: String) -> RepoRef? {
        var text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }

        // `hadHost` is what licenses a path longer than two segments: with `github.com` in front
        // of it, `/pull/123` is noise to drop; without one, it is a third segment nobody can
        // account for.
        var hadHost = false
        if let rest = text.droppingPrefixIgnoringCase("git@github.com:") {
            text = rest
            hadHost = true
        } else {
            for scheme in ["https://", "http://", "ssh://", "git://"] {
                if let rest = text.droppingPrefixIgnoringCase(scheme) {
                    text = rest
                    break
                }
            }
            // `git@` survives `ssh://git@github.com/a/b`.
            if let rest = text.droppingPrefixIgnoringCase("git@") { text = rest }
            for host in ["www.github.com/", "github.com/"] {
                if let rest = text.droppingPrefixIgnoringCase(host) {
                    text = rest
                    hadHost = true
                    break
                }
            }
        }

        let segments = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2, hadHost || segments.count == 2 else { return nil }

        var name = segments[1]
        if let stem = name.droppingSuffixIgnoringCase(".git"), !stem.isEmpty { name = stem }
        return DeepLinkValidation.repository(fullName: "\(segments[0])/\(name)")
    }
}

private extension String {
    /// The string without `prefix`, or `nil` when it does not start with it.
    func droppingPrefixIgnoringCase(_ prefix: String) -> String? {
        guard lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(dropFirst(prefix.count))
    }

    /// The string without `suffix`, or `nil` when it does not end with it.
    func droppingSuffixIgnoringCase(_ suffix: String) -> String? {
        guard lowercased().hasSuffix(suffix.lowercased()) else { return nil }
        return String(dropLast(suffix.count))
    }
}

extension RepoRef: Comparable {
    /// Repositories sort alphabetically by their ``fullName`` (case-insensitively).
    public static func < (lhs: RepoRef, rhs: RepoRef) -> Bool {
        lhs.fullName.lowercased() < rhs.fullName.lowercased()
    }
}
