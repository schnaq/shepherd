import Foundation

/// An explicit token budget for a digest.
///
/// ADR 0007 requires prompting code to budget tokens explicitly rather than hoping a prompt
/// fits. Shepherd approximates tokens as `characters / charactersPerToken`, which is close
/// enough for English prose and code and — crucially — is deterministic and free.
public struct TokenBudget: Sendable, Codable, Hashable {
    /// The maximum number of approximate tokens the digest may occupy.
    public var maxTokens: Int
    /// How many characters one token is assumed to be worth.
    public var charactersPerToken: Int

    /// Creates a budget.
    /// - Parameters:
    ///   - maxTokens: The maximum number of approximate tokens.
    ///   - charactersPerToken: Characters per token. Defaults to 4.
    public init(maxTokens: Int, charactersPerToken: Int = 4) {
        self.maxTokens = max(0, maxTokens)
        self.charactersPerToken = max(1, charactersPerToken)
    }

    /// The budget for Apple's on-device model (8K context, leaving room for the response).
    public static let onDevice = TokenBudget(maxTokens: 6_000)
    /// The budget for a cloud model with a large context window.
    public static let cloud = TokenBudget(maxTokens: 100_000)

    /// The budget expressed in characters.
    public var maxCharacters: Int { maxTokens * charactersPerToken }

    /// Approximates the token count of a string.
    /// - Parameter text: The text to measure.
    /// - Returns: The approximate number of tokens, rounded up.
    public func approximateTokens(of text: String) -> Int {
        approximateTokens(characterCount: text.count)
    }

    /// Approximates the token count of a character count.
    /// - Parameter characterCount: The number of characters.
    /// - Returns: The approximate number of tokens, rounded up.
    public func approximateTokens(characterCount: Int) -> Int {
        guard characterCount > 0 else { return 0 }
        return (characterCount + charactersPerToken - 1) / charactersPerToken
    }
}

/// A compact, token-budgeted description of a pull request, produced by tier-1 heuristics and
/// consumed by the app's `IntelligenceProvider` implementations (ADR 0007).
///
/// The digest never contains a raw diff: it contains per-file statistics plus the highest
/// priority hunks, truncated to fit ``budget``.
public struct PullRequestDigest: Sendable, Codable, Hashable {
    /// Per-file statistics carried by a digest.
    public struct FileStat: Sendable, Codable, Hashable, Identifiable {
        /// The file path.
        public var path: String
        /// What happened to the file.
        public var status: FileChangeStatus
        /// Added lines.
        public var additions: Int
        /// Deleted lines.
        public var deletions: Int
        /// The heuristic bucket the file landed in.
        public var bucket: PriorityBucket
        /// The heuristic category of the file.
        public var category: FileCategory
        /// Human-readable reasons behind the ranking.
        public var reasons: [String]

        /// Creates a file statistic.
        public init(
            path: String,
            status: FileChangeStatus,
            additions: Int,
            deletions: Int,
            bucket: PriorityBucket,
            category: FileCategory,
            reasons: [String]
        ) {
            self.path = path
            self.status = status
            self.additions = additions
            self.deletions = deletions
            self.bucket = bucket
            self.category = category
            self.reasons = reasons
        }

        /// `FileStat` is identified by its path.
        public var id: String { path }
    }

    /// A diff excerpt included in the digest.
    public struct Hunk: Sendable, Codable, Hashable, Identifiable {
        /// The file the excerpt came from.
        public var path: String
        /// The excerpt itself, already truncated to fit the budget.
        public var text: String
        /// Whether the excerpt was cut short.
        public var truncated: Bool

        /// Creates a hunk excerpt.
        public init(path: String, text: String, truncated: Bool) {
            self.path = path
            self.text = text
            self.truncated = truncated
        }

        /// `Hunk` is identified by its path.
        public var id: String { path }
    }

    /// `owner/name` of the repository.
    public var repoFullName: String
    /// The pull request number.
    public var number: Int
    /// The pull request title.
    public var title: String
    /// The pull request description, truncated to the description share of the budget.
    public var bodyExcerpt: String
    /// The author's login.
    public var authorLogin: String
    /// A short provenance label, e.g. `"Claude Code"` or `"People"`.
    public var authorProvenance: String
    /// The base branch name.
    public var baseRefName: String
    /// Total added lines across the pull request.
    public var totalAdditions: Int
    /// Total deleted lines across the pull request.
    public var totalDeletions: Int
    /// Number of changed files.
    public var changedFileCount: Int
    /// Per-file statistics in review-priority order.
    public var files: [FileStat]
    /// Diff excerpts for the highest priority files, in the same order.
    public var topHunks: [Hunk]
    /// The budget this digest was built for.
    public var budget: TokenBudget
    /// The approximate number of tokens the digest occupies.
    public var approximateTokenCount: Int
    /// Whether some files or hunks were left out to stay inside the budget.
    public var wasTruncated: Bool

    /// Creates a digest. Prefer ``PullRequestDigestBuilder`` over calling this directly.
    public init(
        repoFullName: String,
        number: Int,
        title: String,
        bodyExcerpt: String,
        authorLogin: String,
        authorProvenance: String,
        baseRefName: String,
        totalAdditions: Int,
        totalDeletions: Int,
        changedFileCount: Int,
        files: [FileStat],
        topHunks: [Hunk],
        budget: TokenBudget,
        approximateTokenCount: Int,
        wasTruncated: Bool
    ) {
        self.repoFullName = repoFullName
        self.number = number
        self.title = title
        self.bodyExcerpt = bodyExcerpt
        self.authorLogin = authorLogin
        self.authorProvenance = authorProvenance
        self.baseRefName = baseRefName
        self.totalAdditions = totalAdditions
        self.totalDeletions = totalDeletions
        self.changedFileCount = changedFileCount
        self.files = files
        self.topHunks = topHunks
        self.budget = budget
        self.approximateTokenCount = approximateTokenCount
        self.wasTruncated = wasTruncated
    }
}

/// Builds a ``PullRequestDigest`` from a fetched pull request, honouring an explicit token
/// budget (ADR 0007, tier 1).
public enum PullRequestDigestBuilder {
    /// How the character budget is split between the parts of a digest.
    private enum Share {
        /// Fraction of the budget the pull request body may use.
        static let body = 0.15
        /// Fraction of the budget the per-file statistics may use.
        static let fileStats = 0.25
        /// The remainder goes to diff excerpts.
    }

    /// Builds a digest.
    ///
    /// Files are ranked with ``FilePrioritizer`` first, so the excerpts that survive
    /// truncation are the ones a reviewer would read first. Generated and vendored files
    /// never contribute excerpts.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - budget: The token budget the digest must fit into.
    /// - Returns: A digest whose ``PullRequestDigest/approximateTokenCount`` is at most
    ///   ``TokenBudget/maxTokens``.
    public static func build(
        from detail: PullRequestDetail,
        budget: TokenBudget
    ) -> PullRequestDigest {
        let summary = detail.summary
        let priorities = FilePrioritizer.prioritize(
            detail.files,
            context: PrioritizationContext(totalChangedLines: summary.churn)
        )

        var truncated = false

        // 1. Body excerpt.
        let bodyLimit = Int(Double(budget.maxCharacters) * Share.body)
        let (bodyExcerpt, bodyWasCut) = truncate(detail.bodyMarkdown, to: bodyLimit)
        truncated = truncated || bodyWasCut

        // 2. Per-file statistics, highest priority first, until the stats share is used up.
        let statsLimit = Int(Double(budget.maxCharacters) * Share.fileStats)
        var statsUsed = 0
        var files: [PullRequestDigest.FileStat] = []
        for priority in priorities {
            let stat = PullRequestDigest.FileStat(
                path: priority.file.path,
                status: priority.file.status,
                additions: priority.file.additions,
                deletions: priority.file.deletions,
                bucket: priority.bucket,
                category: priority.category,
                reasons: priority.reasons
            )
            let cost = stat.path.count + stat.reasons.reduce(0) { $0 + $1.count } + 24
            if statsUsed + cost > statsLimit, !files.isEmpty {
                truncated = true
                break
            }
            statsUsed += cost
            files.append(stat)
        }

        // 3. Diff excerpts for the remaining budget.
        var hunkBudget = budget.maxCharacters - bodyExcerpt.count - statsUsed
            - summary.title.count - summary.repo.fullName.count - 64
        // `statsUsed` may overshoot `statsLimit` by one entry (the first file is always
        // listed); the subtraction above absorbs that, so `hunkBudget` can legitimately be
        // negative here and the guard below stops immediately.
        var hunks: [PullRequestDigest.Hunk] = []
        for priority in priorities where priority.bucket != .generated {
            guard hunkBudget > 200 else {
                truncated = true
                break
            }
            guard let patch = priority.file.patch, !patch.isEmpty else { continue }
            let perHunkLimit = min(hunkBudget, max(400, hunkBudget / 2))
            let (text, wasCut) = truncate(patch, to: perHunkLimit)
            guard !text.isEmpty else { continue }
            hunks.append(
                PullRequestDigest.Hunk(path: priority.file.path, text: text, truncated: wasCut)
            )
            truncated = truncated || wasCut
            // The path travels with the excerpt, so it has to come out of the same budget.
            hunkBudget -= text.count + priority.file.path.count
        }
        if hunks.count < priorities.filter({ $0.bucket != .generated && $0.file.hasPatch }).count {
            truncated = true
        }

        let characterCount = bodyExcerpt.count
            + statsUsed
            + hunks.reduce(0) { $0 + $1.text.count + $1.path.count }
            + summary.title.count
            + summary.repo.fullName.count

        return PullRequestDigest(
            repoFullName: summary.repo.fullName,
            number: summary.number,
            title: summary.title,
            bodyExcerpt: bodyExcerpt,
            authorLogin: summary.author.login,
            authorProvenance: summary.author.kind.provenanceLabel,
            baseRefName: summary.baseRefName,
            totalAdditions: summary.additions,
            totalDeletions: summary.deletions,
            changedFileCount: max(summary.changedFiles, detail.files.count),
            files: files,
            topHunks: hunks,
            budget: budget,
            approximateTokenCount: budget.approximateTokens(characterCount: characterCount),
            wasTruncated: truncated
        )
    }

    /// Truncates a string to a character limit on a line boundary where possible.
    /// - Parameters:
    ///   - text: The text to truncate.
    ///   - limit: The maximum number of characters.
    /// - Returns: The truncated text and whether anything was removed.
    private static func truncate(_ text: String, to limit: Int) -> (String, Bool) {
        guard limit > 0 else { return ("", !text.isEmpty) }
        guard text.count > limit else { return (text, false) }
        let cut = String(text.prefix(limit))
        if let lastNewline = cut.lastIndex(of: "\n"), cut.distance(from: cut.startIndex, to: lastNewline) > limit / 2 {
            return (String(cut[cut.startIndex..<lastNewline]), true)
        }
        return (cut, true)
    }
}
