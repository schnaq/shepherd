import Foundation

/// GitHub's aggregate review decision for a pull request.
public enum ReviewDecision: String, Sendable, Codable, Hashable, CaseIterable {
    /// At least one approval and no outstanding change requests.
    case approved
    /// A reviewer requested changes.
    case changesRequested
    /// Review is required and not yet given.
    case reviewRequired
}

/// Whether GitHub thinks the pull request can be merged.
public enum Mergeable: String, Sendable, Codable, Hashable, CaseIterable {
    /// No conflicts with the base branch.
    case mergeable
    /// The branch conflicts with its base.
    case conflicting
    /// GitHub has not computed mergeability yet.
    case unknown
}

/// The rolled-up CI state of a pull request's head commit, plus per-state counts.
///
/// The GraphQL inbox sweep only carries the rolled-up `state` and the total number of
/// contexts cheaply; the per-state counts are filled in by the detail fetch from the REST
/// check-runs endpoint (see ADR 0005).
public struct CheckRollup: Sendable, Codable, Hashable {
    /// The rolled-up state of all checks on the head commit.
    public enum State: String, Sendable, Codable, Hashable, CaseIterable {
        /// Every check succeeded (or was neutral/skipped).
        case success
        /// At least one check failed, errored, was cancelled or timed out.
        case failure
        /// At least one check is still queued or running, and none failed.
        case pending
        /// No checks are configured for this commit.
        case none
    }

    /// The rolled-up state.
    public var state: State
    /// Total number of check contexts reported for the head commit.
    public var total: Int
    /// Number of successful checks (0 when only the rollup state is known).
    public var successCount: Int
    /// Number of failing checks (0 when only the rollup state is known).
    public var failureCount: Int
    /// Number of queued or running checks (0 when only the rollup state is known).
    public var pendingCount: Int

    /// Creates a rollup.
    public init(
        state: State,
        total: Int = 0,
        successCount: Int = 0,
        failureCount: Int = 0,
        pendingCount: Int = 0
    ) {
        self.state = state
        self.total = total
        self.successCount = successCount
        self.failureCount = failureCount
        self.pendingCount = pendingCount
    }

    /// Derives a rollup from a fully fetched list of check runs.
    /// - Parameter runs: The check runs of the head commit.
    public init(runs: [CheckRun]) {
        var success = 0
        var failure = 0
        var pending = 0
        for run in runs {
            switch run.rollupContribution {
            case .success: success += 1
            case .failure: failure += 1
            case .pending: pending += 1
            }
        }
        let state: State
        if runs.isEmpty {
            state = .none
        } else if failure > 0 {
            state = .failure
        } else if pending > 0 {
            state = .pending
        } else {
            state = .success
        }
        self.init(
            state: state,
            total: runs.count,
            successCount: success,
            failureCount: failure,
            pendingCount: pending
        )
    }
}

/// How the signed-in user relates to a pull request.
///
/// Derived from which facet search query returned the pull request (ADR 0005), so several
/// relations can apply to the same row.
public enum Relation: String, Sendable, Codable, Hashable, CaseIterable {
    /// The user's review was explicitly requested.
    case reviewRequested
    /// The user opened the pull request.
    case author
    /// The user was mentioned.
    case mentioned
    /// The user is assigned.
    case assigned
}

/// One row of the review inbox.
///
/// Everything the list view needs comes from a single GraphQL search sweep; nothing here
/// requires a per-pull-request round trip (ADR 0005).
public struct PullRequestSummary: Sendable, Codable, Hashable, Identifiable {
    /// The GraphQL node id of the pull request — the primary key everywhere in Shepherd.
    public let id: String
    /// The repository the pull request belongs to.
    public var repo: RepoRef
    /// The pull request number within its repository.
    public var number: Int
    /// The pull request title.
    public var title: String
    /// The author, with detected provenance.
    public var author: Actor
    /// When the pull request was last updated (the delta-detection key, ADR 0005).
    public var updatedAt: Date
    /// When the pull request was opened.
    public var createdAt: Date
    /// Whether the pull request is a draft.
    public var isDraft: Bool
    /// Total added lines.
    public var additions: Int
    /// Total deleted lines.
    public var deletions: Int
    /// Number of changed files.
    public var changedFiles: Int
    /// The head branch name, e.g. `"claude/fix-login"`.
    public var headRefName: String
    /// The head commit SHA (the second delta-detection key).
    public var headRefOid: String
    /// The base branch name, e.g. `"main"`.
    public var baseRefName: String
    /// GitHub's aggregate review decision, if any.
    public var reviewDecision: ReviewDecision?
    /// The rolled-up CI state, if the head commit has any checks.
    public var checkRollup: CheckRollup?
    /// How the signed-in user relates to this pull request.
    public var myRelation: Set<Relation>
    /// Label names, in the order GitHub returned them.
    public var labels: [String]
    /// Whether GitHub considers the pull request mergeable.
    public var mergeable: Mergeable?

    /// Creates an inbox row.
    public init(
        id: String,
        repo: RepoRef,
        number: Int,
        title: String,
        author: Actor,
        updatedAt: Date,
        createdAt: Date,
        isDraft: Bool = false,
        additions: Int = 0,
        deletions: Int = 0,
        changedFiles: Int = 0,
        headRefName: String,
        headRefOid: String,
        baseRefName: String,
        reviewDecision: ReviewDecision? = nil,
        checkRollup: CheckRollup? = nil,
        myRelation: Set<Relation> = [],
        labels: [String] = [],
        mergeable: Mergeable? = nil
    ) {
        self.id = id
        self.repo = repo
        self.number = number
        self.title = title
        self.author = author
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.isDraft = isDraft
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.baseRefName = baseRefName
        self.reviewDecision = reviewDecision
        self.checkRollup = checkRollup
        self.myRelation = myRelation
        self.labels = labels
        self.mergeable = mergeable
    }

    /// `owner/name#number`, the shorthand used in logs and notifications.
    public var slug: String { "\(repo.fullName)#\(number)" }

    /// Total churn (added plus deleted lines).
    public var churn: Int { additions + deletions }
}

/// Everything Shepherd knows about one pull request after a detail fetch.
public struct PullRequestDetail: Sendable, Codable, Hashable, Identifiable {
    /// The inbox row this detail belongs to.
    public var summary: PullRequestSummary
    /// The pull request description, as Markdown source.
    public var bodyMarkdown: String
    /// Commits on the head branch, oldest first.
    public var commits: [CommitInfo]
    /// Changed files with their unified-diff patches where available.
    public var files: [ChangedFile]
    /// Review threads, including resolved and outdated ones.
    public var threads: [ReviewThread]
    /// A condensed activity timeline, oldest first.
    public var timeline: [TimelineEvent]
    /// Check runs of the head commit.
    public var checks: [CheckRun]

    /// Creates a detail record.
    public init(
        summary: PullRequestSummary,
        bodyMarkdown: String = "",
        commits: [CommitInfo] = [],
        files: [ChangedFile] = [],
        threads: [ReviewThread] = [],
        timeline: [TimelineEvent] = [],
        checks: [CheckRun] = []
    ) {
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
        self.commits = commits
        self.files = files
        self.threads = threads
        self.timeline = timeline
        self.checks = checks
    }

    /// `PullRequestDetail` shares the identity of its ``summary``.
    public var id: String { summary.id }

    /// The repository the pull request belongs to.
    public var repo: RepoRef { summary.repo }

    /// The pull request number.
    public var number: Int { summary.number }

    /// All commit message trailers found on the head branch, used by ``AgentDetector``.
    public var commitTrailers: [String] { commits.flatMap(\.trailers) }
}
