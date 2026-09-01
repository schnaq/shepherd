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
}

extension RepoRef: Comparable {
    /// Repositories sort alphabetically by their ``fullName`` (case-insensitively).
    public static func < (lhs: RepoRef, rhs: RepoRef) -> Bool {
        lhs.fullName.lowercased() < rhs.fullName.lowercased()
    }
}
