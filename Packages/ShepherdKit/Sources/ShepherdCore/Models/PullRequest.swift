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

/// Why GitHub would or would not merge the pull request right now, in more detail than
/// ``Mergeable``.
///
/// GitHub's `mergeStateStatus` (GraphQL) and `mergeable_state` (REST), mapped by GitHubKit. The
/// merge series (ADR 0041) reads only ``behind``, to know when to bring a branch up to date; the
/// other cases are stored so the row says what GitHub said, not a guess. Absent (`nil`) means the
/// server did not send the field, or sent a value this build does not know.
public enum MergeStateStatus: String, Sendable, Codable, Hashable, CaseIterable {
    /// The head branch is behind its base and the repository requires it to be up to date.
    case behind
    /// Merging is blocked, for example by a missing required review.
    case blocked
    /// Mergeable, and every commit status passed.
    case clean
    /// The merge commit cannot be created cleanly, usually because of a conflict.
    case dirty
    /// The pull request is a draft.
    case draft
    /// Mergeable with passing statuses, and pre-receive hooks exist.
    case hasHooks
    /// Mergeable, but a non-required status failed.
    case unstable
    /// GitHub has not computed the state yet.
    case unknown
}

/// A pull request's place in a GitHub stack (ADR 0042).
///
/// A stack is an ordered series of pull requests in one repository: the bottom one targets the
/// trunk, and each one above targets the branch of the one below. Merging one merges every pull
/// request below it too, and only through GitHub's asynchronous merge, which is why the outbox
/// drain reads this before it picks an endpoint.
///
/// GitHubKit builds it from GraphQL's `stack` and `stackEntry` (the sweep) and REST's `stack`
/// object (the detail fetch). It exists only when every field arrived: half a stack is not a
/// place in one.
public struct PullRequestStack: Sendable, Codable, Hashable {
    /// GitHub's number for the stack, unique within its repository (not a pull request number).
    public var number: Int
    /// How many pull requests the stack holds.
    public var size: Int
    /// This pull request's place in the stack, **1-based** and counted from the bottom.
    ///
    /// GitHub's GraphQL reference: "This entry's position in the stack, where 1 is the closest
    /// to the base branch, 2 is stacked on top of 1, etc." The REST reference does not say; its
    /// example (`position: 2` of `size: 3`) fits the same numbering, and GitHubKit stores both
    /// as given, so a row can show `position`/`size` directly ("Stack 2/3").
    public var position: Int
    /// The branch the stack's bottom pull request targets, its trunk (GraphQL `baseRefName`,
    /// REST `base.ref`).
    public var baseRefName: String

    /// Creates a stack membership.
    public init(number: Int, size: Int, position: Int, baseRefName: String) {
        self.number = number
        self.size = size
        self.position = position
        self.baseRefName = baseRefName
    }
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
    /// The user is involved in some way the four facets above do not name — most often they
    /// commented on it once.
    ///
    /// The `involves:@me` catch-all used to imply nothing at all, which was fine while it was the
    /// only facet that could leave a row unmarked. ``watched`` is a second one, and "no relation"
    /// would then mean two different things at once.
    case involved
    /// Nobody involved the user; the pull request is in one of the repositories they watch
    /// (ADR 0005's 2026-09-16 amendment).
    ///
    /// The one relation that is not *about* the user. It says where the row came from, so the
    /// rail can keep watched repositories out of "Involved" — and so that nothing which reads a
    /// relation as a mandate mistakes it for one: ``AutoDelegationPolicy/isOwn(_:)`` asks for
    /// ``author`` or ``assigned``, and a watched row carries neither.
    case watched
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
    /// GitHub's finer-grained merge state, if the server sent one (ADR 0041).
    ///
    /// Optional, and decoded with `decodeIfPresent` by the synthesised `Codable`, so a summary
    /// cached before the field existed still decodes.
    public var mergeStateStatus: MergeStateStatus?
    /// The pull request's place in a GitHub stack, or `nil` when it is not in one (ADR 0042).
    ///
    /// Optional for ``mergeStateStatus``'s reason: a summary cached before the field existed
    /// still decodes.
    public var stack: PullRequestStack?

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
        mergeable: Mergeable? = nil,
        mergeStateStatus: MergeStateStatus? = nil,
        stack: PullRequestStack? = nil
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
        self.mergeStateStatus = mergeStateStatus
        self.stack = stack
    }

    /// `owner/name#number`, the shorthand used in logs and notifications.
    public var slug: String { "\(repo.fullName)#\(number)" }

    /// Total churn (added plus deleted lines).
    public var churn: Int { additions + deletions }

    /// Whether this row is one somebody is waiting on the signed-in user for.
    ///
    /// The single definition of "needs my review", used by the inbox rail's *Needs my review*
    /// smart view, by the count on the menu-bar item, by the focus session's queue, and by the
    /// morning digest (``DigestReport``). It lives on the model rather than in any one of those
    /// four so they cannot drift apart — a digest that disagreed with the badge about how many
    /// pull requests are waiting would undermine both.
    ///
    /// An approval already recorded takes the row out: GitHub keeps the review request on the pull
    /// request afterwards, and a queue that still listed pull requests the user has approved would
    /// never empty.
    public var needsMyReview: Bool {
        myRelation.contains(.reviewRequested) && reviewDecision != .approved
    }
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
    /// The issues GitHub says merging this pull request will close (ADR 0032, Sprint 3).
    ///
    /// `closingIssuesReferences`, capped at ten, read as one more field on the same detail fetch
    /// the review threads come from. Empty means one of two things and the screen treats them
    /// alike, because a reader cannot act on the difference: the pull request closes nothing, or
    /// that one field of the fetch failed and was tolerated
    /// (`GitHubClient.pullRequestDetail(repo:number:)`) — the "Closes" section is simply not
    /// drawn either way.
    public var closingIssues: [LinkedIssueReference]

    /// Creates a detail record.
    public init(
        summary: PullRequestSummary,
        bodyMarkdown: String = "",
        commits: [CommitInfo] = [],
        files: [ChangedFile] = [],
        threads: [ReviewThread] = [],
        timeline: [TimelineEvent] = [],
        checks: [CheckRun] = [],
        closingIssues: [LinkedIssueReference] = []
    ) {
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
        self.commits = commits
        self.files = files
        self.threads = threads
        self.timeline = timeline
        self.checks = checks
        self.closingIssues = closingIssues
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case bodyMarkdown
        case commits
        case files
        case threads
        case timeline
        case checks
        case closingIssues
    }

    /// Decodes a detail record, tolerating every list being absent.
    ///
    /// ``Claim/init(from:)``'s rule applied to a bigger type: the ``summary`` *is* the pull
    /// request and is required, and every list is a list of things a fetch may not have learned
    /// anything about — so an absent one decodes as empty rather than failing the whole record.
    /// ``closingIssues`` is the reason the initialiser exists at all: a value encoded before that
    /// field existed carries no key for it, and a synthesised initialiser would refuse it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(PullRequestSummary.self, forKey: .summary)
        bodyMarkdown = try container.decodeIfPresent(String.self, forKey: .bodyMarkdown) ?? ""
        commits = try container.decodeIfPresent([CommitInfo].self, forKey: .commits) ?? []
        files = try container.decodeIfPresent([ChangedFile].self, forKey: .files) ?? []
        threads = try container.decodeIfPresent([ReviewThread].self, forKey: .threads) ?? []
        timeline = try container.decodeIfPresent([TimelineEvent].self, forKey: .timeline) ?? []
        checks = try container.decodeIfPresent([CheckRun].self, forKey: .checks) ?? []
        closingIssues = try container.decodeIfPresent(
            [LinkedIssueReference].self,
            forKey: .closingIssues
        ) ?? []
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
