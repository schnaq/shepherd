import Foundation

/// What a revert points at, as far as its own text says (ADR 0027).
///
/// Two shapes, because GitHub's own "Revert" button writes both and people write one or the
/// other by hand: a title of the form `Revert "the original title"`, and a body line
/// `This reverts commit <sha>.` A pull request can carry either, both, or a `#123` reference.
public struct RevertReference: Sendable, Codable, Hashable {
    /// The original title, unquoted, from a `Revert "…"` title.
    public var revertedTitle: String?
    /// The commit SHA from a `This reverts commit …` body line, lowercased.
    public var revertedCommitOid: String?
    /// The pull-request number a `Reverts #123` / `Revert of #123` phrase names.
    public var revertedNumber: Int?

    /// Creates a reference.
    public init(
        revertedTitle: String? = nil,
        revertedCommitOid: String? = nil,
        revertedNumber: Int? = nil
    ) {
        self.revertedTitle = revertedTitle
        self.revertedCommitOid = revertedCommitOid
        self.revertedNumber = revertedNumber
    }

    /// Whether the reference says anything at all.
    public var isEmpty: Bool {
        revertedTitle == nil && revertedCommitOid == nil && revertedNumber == nil
    }
}

/// Reads "this undoes that" out of a pull request's own text, and links the pairs.
///
/// Deterministic and text-only. It never asks GitHub what a commit belongs to: the whole feature
/// is a count on a badge, and a revert Shepherd cannot see in the text is a revert it simply does
/// not count — which is honest, whereas a per-commit lookup would be a request per closed pull
/// request for a number nobody acts on.
public enum RevertDetector {
    /// The characters a lowercased commit SHA may be made of.
    private static let shaCharacters = Set("0123456789abcdef")
    /// The shortest abbreviation worth believing is a SHA, and the longest one GitHub prints.
    private static let shaLengths = 7...40

    /// Parses one pull request's title and body.
    /// - Parameters:
    ///   - title: The pull request title.
    ///   - body: The description, as Markdown source. May be empty.
    /// - Returns: What the text says this pull request reverts. ``RevertReference/isEmpty`` when
    ///   it says nothing.
    public static func revertedTarget(title: String, body: String) -> RevertReference {
        RevertReference(
            revertedTitle: quotedTitle(in: title),
            revertedCommitOid: revertedCommit(in: body),
            revertedNumber: revertedNumber(in: title) ?? revertedNumber(in: body)
        )
    }

    /// The title a `Revert "…"` title quotes.
    ///
    /// Case-insensitive on the keyword and tolerant of the shapes people actually type —
    /// `Revert "x"`, `revert: "x"`, `Revert “x”` with typographic quotes, and a
    /// `Revert "Revert "x""` double revert, whose *outer* quotes are the ones taken.
    static func quotedTitle(in title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("revert") else { return nil }
        var rest = Substring(trimmed).dropFirst("revert".count)
        while let first = rest.first, first == ":" || first == " " || first == "\t" {
            rest = rest.dropFirst()
        }
        let openers: [Character: Character] = ["\"": "\"", "“": "”", "'": "'"]
        guard let opener = rest.first, let closer = openers[opener] else { return nil }
        let inner = rest.dropFirst()
        guard let closingIndex = inner.lastIndex(of: closer) else { return nil }
        let quoted = String(inner[inner.startIndex..<closingIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return quoted.isEmpty ? nil : quoted
    }

    /// The SHA a `This reverts commit <sha>` line names, lowercased.
    ///
    /// The first such line wins: a revert-of-a-revert body carries two, and the first is the
    /// commit *this* pull request undoes.
    static func revertedCommit(in body: String) -> String? {
        let needle = "this reverts commit"
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            // Searched *and* sliced in the lowercased copy: an index from one string is not an
            // index into another, and a SHA is lower case anyway.
            let lowered = rawLine.lowercased()
            guard let start = lowered.range(of: needle) else { continue }
            let token = lowered[start.upperBound...]
                .drop(while: { $0 == " " || $0 == "\t" })
                .prefix(while: { !$0.isWhitespace })
            let sha = String(token)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}"))
            guard shaLengths.contains(sha.count),
                  sha.allSatisfy({ shaCharacters.contains($0) })
            else { continue }
            return sha
        }
        return nil
    }

    /// Whether a pull request presents itself as a revert at all.
    ///
    /// The gate ``links(candidates:known:)`` applies before it believes a `#123` reference: a
    /// description that merely mentions "we may have to revert #12 one day" is not a revert, and
    /// counting it would put a revert on somebody's badge for a sentence.
    /// - Parameters:
    ///   - title: The pull request title.
    ///   - body: The description.
    /// - Returns: `true` for a `Revert "…"`-shaped title or a `This reverts commit …` body.
    public static func isRevertShaped(title: String, body: String) -> Bool {
        let loweredTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if loweredTitle.hasPrefix("revert") { return true }
        return body.lowercased().contains("this reverts commit")
    }

    /// The pull-request number a `Reverts #123` / `Revert of #123` phrase names.
    static func revertedNumber(in text: String) -> Int? {
        let lowered = text.lowercased()
        for phrase in ["reverts #", "revert of #", "reverting #", "revert #"] {
            guard let range = lowered.range(of: phrase) else { continue }
            let digits = lowered[range.upperBound...].prefix(while: { $0.isNumber })
            if let number = Int(digits), number > 0 { return number }
        }
        return nil
    }

    /// Links reverting pull requests onto the merged ones they undo.
    ///
    /// Three ways in, in this order — a SHA is unambiguous, a number is nearly so, a title is a
    /// guess that is right almost always and is the only signal GitHub's own button leaves in a
    /// squash-merged repository:
    ///
    /// 1. `This reverts commit <sha>` against the target's merge commit;
    /// 2. `Reverts #123` against the target's number;
    /// 3. `Revert "…"` against the target's exact title.
    ///
    /// Only **merged** pull requests can be reverted, only within the same repository, and only
    /// by a pull request that closed *after* them. A title that two merged pull requests share
    /// links to the most recent of them, because that is the one a revert opened today is
    /// undoing.
    /// - Parameters:
    ///   - candidates: The closed pull requests to search, in any order.
    ///   - known: Pull requests already stored, so a revert in today's page can find the pull
    ///     request last week's page imported. Keyed by node id.
    /// - Returns: The reverting pull request's node id, keyed by the node id of the pull request
    ///   it reverts. Pull requests nobody reverted are absent.
    public static func links(
        candidates: [ClosedPullRequest],
        known: [ClosedPullRequest] = []
    ) -> [String: String] {
        let targets = (known + candidates).filter { $0.outcome.merged }
        guard !targets.isEmpty else { return [:] }

        var byCommit: [String: ClosedPullRequest] = [:]
        var byNumber: [String: ClosedPullRequest] = [:]
        var byTitle: [String: ClosedPullRequest] = [:]
        for target in targets.sorted(by: { $0.outcome.closedAt < $1.outcome.closedAt }) {
            if let oid = target.mergeCommitOid?.lowercased(), !oid.isEmpty {
                byCommit[oid] = target
            }
            byNumber["\(target.outcome.repo.fullName.lowercased())#\(target.number)"] = target
            let title = normalized(target.title)
            if !title.isEmpty { byTitle[key(repo: target.outcome.repo, title: title)] = target }
        }

        var result: [String: String] = [:]
        for candidate in candidates {
            guard isRevertShaped(title: candidate.title, body: candidate.bodyMarkdown) else {
                continue
            }
            let reference = revertedTarget(
                title: candidate.title,
                body: candidate.bodyMarkdown
            )
            guard !reference.isEmpty else { continue }
            var match: ClosedPullRequest?
            if let oid = reference.revertedCommitOid {
                match = byCommit[oid] ?? byCommit.first { $0.key.hasPrefix(oid) }?.value
            }
            if match == nil, let number = reference.revertedNumber {
                match = byNumber["\(candidate.outcome.repo.fullName.lowercased())#\(number)"]
            }
            if match == nil, let title = reference.revertedTitle {
                match = byTitle[key(repo: candidate.outcome.repo, title: normalized(title))]
            }
            guard let target = match,
                  target.outcome.prID != candidate.outcome.prID,
                  target.outcome.repo.isSameRepository(as: candidate.outcome.repo),
                  target.outcome.closedAt <= candidate.outcome.closedAt
            else { continue }
            result[target.outcome.prID] = candidate.outcome.prID
        }
        return result
    }

    private static func key(repo: RepoRef, title: String) -> String {
        "\(repo.fullName.lowercased())\u{1}\(title)"
    }

    private static func normalized(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
