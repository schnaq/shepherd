import Foundation

/// A tiny, dependency-free glob matcher.
///
/// Only two wildcards are supported, deliberately:
///
/// - `*` matches any run of characters (including none)
/// - `?` matches exactly one character
///
/// Everything else — including `[` and `]` — is matched literally, which is what makes
/// patterns such as `claude[bot]` in the agent registry behave the way a reader expects.
public struct GlobPattern: Sendable, Hashable, Codable {
    /// The raw pattern this matcher was built from.
    public let pattern: String
    private let patternCharacters: [Character]

    /// Creates a matcher for a pattern.
    /// - Parameter pattern: A pattern using `*` and `?` as its only wildcards.
    public init(_ pattern: String) {
        self.pattern = pattern
        self.patternCharacters = Array(pattern)
    }

    // `patternCharacters` is a derived cache, so Codable conformance is hand-written
    // over the raw pattern string ([Character] is not itself Codable).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pattern)
    }

    public static func == (lhs: GlobPattern, rhs: GlobPattern) -> Bool {
        lhs.pattern == rhs.pattern
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pattern)
    }

    /// Whether the pattern matches a candidate string.
    /// - Parameters:
    ///   - candidate: The string to test.
    ///   - caseSensitive: Whether the comparison is case-sensitive. Defaults to `false`,
    ///     which is what GitHub logins and branch names call for.
    /// - Returns: `true` when the whole candidate is matched by the whole pattern.
    public func matches(_ candidate: String, caseSensitive: Bool = false) -> Bool {
        let text: [Character]
        let patternToUse: [Character]
        if caseSensitive {
            text = Array(candidate)
            patternToUse = patternCharacters
        } else {
            text = Array(candidate.lowercased())
            patternToUse = Array(pattern.lowercased())
        }
        return GlobPattern.match(pattern: patternToUse, text: text)
    }

    /// Iterative wildcard match with backtracking — linear in the common case, never recursive.
    private static func match(pattern: [Character], text: [Character]) -> Bool {
        var patternIndex = 0
        var textIndex = 0
        var starIndex: Int? = nil
        var matchIndex = 0

        while textIndex < text.count {
            if patternIndex < pattern.count,
               pattern[patternIndex] == "?" || pattern[patternIndex] == text[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                matchIndex = textIndex
                patternIndex += 1
            } else if let star = starIndex {
                patternIndex = star + 1
                matchIndex += 1
                textIndex = matchIndex
            } else {
                return false
            }
        }

        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}
