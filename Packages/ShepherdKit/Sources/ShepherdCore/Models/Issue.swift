import Foundation

/// How the signed-in user relates to an issue.
///
/// Derived from which facet search query returned the issue, exactly as ``Relation`` is for pull
/// requests (ADR 0005): the sweep learns *why* a row is in the inbox for free, so several
/// relations can apply to the same issue and none of them costs a round trip.
///
/// Three cases and no catch-all, because the inbox offers three facets — assigned to you, opened
/// by you, mentioning you — and a relation nothing can produce would be a case every `switch`
/// has to handle for nothing.
public enum IssueRelation: String, Sendable, Codable, Hashable, CaseIterable {
    /// The issue is assigned to the user.
    case assigned
    /// The user opened the issue.
    case authored
    /// The issue mentions the user.
    case mentioned
}

/// A pull request that GitHub says will close an issue.
///
/// The cheap half of the "Development panel": what the issue sweep can see about a linked pull
/// request in one nested selection, and nothing more. It is deliberately *not* a
/// ``PullRequestSummary`` — the linked pull request may not be in the local inbox at all (someone
/// else's, or never detail-fetched), so this carries the handful of fields the row and the detail
/// panel show and stores them by value.
public struct LinkedPullRequestReference: Sendable, Codable, Hashable, Identifiable {
    /// The repository the pull request lives in.
    ///
    /// Stored rather than inherited from the issue: a fix may perfectly well arrive from a fork
    /// or from a sibling repository, and the reference is about what the sweep saw.
    public var repo: RepoRef
    /// The pull request number within its repository.
    public var number: Int
    /// The pull request title.
    public var title: String
    /// GitHub's own pull-request state — `OPEN`, `CLOSED` or `MERGED` — kept raw and tolerant.
    ///
    /// The same treatment ``PullRequestOutcomeSource`` gets: nothing branches on an unfamiliar
    /// word, the chip prints what it was given, and a vocabulary GitHub grows does not cost a
    /// row.
    public var state: String
    /// The author, with detected provenance (ADR 0008).
    public var author: Actor

    /// Creates a reference.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The pull request number.
    ///   - title: The pull request title.
    ///   - state: GitHub's raw state string.
    ///   - author: The author, with detected provenance.
    public init(repo: RepoRef, number: Int, title: String, state: String, author: Actor) {
        self.repo = repo
        self.number = number
        self.title = title
        self.state = state
        self.author = author
    }

    /// A reference is identified by its repository and number.
    public var id: String { "\(repo.fullName)#\(number)" }

    /// `owner/name#number`, the shorthand used in rows and logs.
    public var slug: String { id }
}

/// One row of the issues inbox.
///
/// The issue-side twin of ``PullRequestSummary``: everything the list view needs comes from a
/// single GraphQL search sweep, and nothing here requires a per-issue round trip.
///
/// Deliberately **not** ``IssueSummary``, which answers a different question. That type
/// (ADR 0026's amendment) exists so the claims card can read the acceptance bullets of a
/// `fixes #N` reference while the card is open: it has no id, no author and no timestamps because
/// nothing about it is persisted. Bolting an inbox row's shape onto it would mean persisting a
/// type whose whole point is that it is not persisted, so the two live side by side and the
/// open/closed vocabulary — ``IssueSummary/State`` — is the one thing they share.
public struct IssueRowSummary: Sendable, Codable, Hashable, Identifiable {
    /// The GraphQL node id of the issue — the primary key everywhere in Shepherd.
    public let id: String
    /// The repository the issue belongs to.
    public var repo: RepoRef
    /// The issue number within its repository.
    public var number: Int
    /// The issue title.
    public var title: String
    /// The author, with detected provenance (ADR 0008).
    public var author: Actor
    /// When the issue was opened. The age facet's input.
    public var createdAt: Date
    /// When the issue was last updated (the delta-detection key, as it is for pull requests).
    public var updatedAt: Date
    /// When the issue was closed, when it is.
    public var closedAt: Date?
    /// Whether the issue is open or closed — ADR 0026's amendment's enum, reused.
    public var state: IssueSummary.State
    /// GitHub's raw `stateReason` (`COMPLETED`, `NOT_PLANNED`, `REOPENED`, …).
    ///
    /// Raw and tolerant, like ``LinkedPullRequestReference/state`` and
    /// ``PullRequestOutcomeSource``: it is shown, never branched on, so a word this build does
    /// not know costs nothing.
    public var stateReason: String?
    /// Label names, in the order GitHub returned them.
    public var labels: [String]
    /// How the signed-in user relates to this issue.
    public var myRelation: Set<IssueRelation>
    /// How many comments the issue has. A count only — there is no issue conversation view.
    public var commentCount: Int
    /// The pull requests GitHub says will close this issue.
    ///
    /// What the sweep saw, capped by the query's own `first:` — the full list, when a longer one
    /// exists, is the detail panel's problem and not the row's.
    public var linkedPullRequests: [LinkedPullRequestReference]

    /// Creates an inbox row.
    /// - Parameters:
    ///   - id: The GraphQL node id.
    ///   - repo: The repository.
    ///   - number: The issue number.
    ///   - title: The issue title.
    ///   - author: The author, with detected provenance.
    ///   - createdAt: When the issue was opened.
    ///   - updatedAt: When the issue was last updated.
    ///   - closedAt: When the issue was closed, if it is.
    ///   - state: Whether it is open or closed.
    ///   - stateReason: GitHub's raw state reason.
    ///   - labels: Label names.
    ///   - myRelation: How the user relates to the issue.
    ///   - commentCount: How many comments it has.
    ///   - linkedPullRequests: The pull requests that will close it.
    public init(
        id: String,
        repo: RepoRef,
        number: Int,
        title: String,
        author: Actor,
        createdAt: Date,
        updatedAt: Date,
        closedAt: Date? = nil,
        state: IssueSummary.State = .open,
        stateReason: String? = nil,
        labels: [String] = [],
        myRelation: Set<IssueRelation> = [],
        commentCount: Int = 0,
        linkedPullRequests: [LinkedPullRequestReference] = []
    ) {
        self.id = id
        self.repo = repo
        self.number = number
        self.title = title
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.state = state
        self.stateReason = stateReason
        self.labels = labels
        self.myRelation = myRelation
        self.commentCount = commentCount
        self.linkedPullRequests = linkedPullRequests
    }

    /// `owner/name#number`, the shorthand used in rows, logs and search.
    public var slug: String { "\(repo.fullName)#\(number)" }

    /// Whether a machine wrote any of the pull requests that will close this issue.
    ///
    /// The single definition of the "has an agent pull request" facet, derived from the linked
    /// references' own provenance rather than stored as a second opinion — which is what makes
    /// the facet, the chip and the denormalised column in `issues` unable to disagree.
    /// ``ActorKind/isMachine`` rather than ``ActorKind/agentIdentity``, because an unrecognised
    /// bot is still not a person and the facet's question is "did somebody hand this to a
    /// machine".
    public var hasAgentPullRequest: Bool {
        linkedPullRequests.contains { $0.author.kind.isMachine }
    }
}

/// Everything Shepherd knows about one issue after a detail fetch.
///
/// The minimum ``PullRequestDetail`` mirror: a row plus the body. Comments and the timeline are
/// deliberately out of scope — the detail panel shows title, body, labels and linked pull
/// requests, and an issue conversation view is nobody's requirement, so there is no
/// ``PullRequestDetail/timeline`` twin to keep in step with a table.
public struct IssueDetail: Sendable, Codable, Hashable, Identifiable {
    /// The inbox row this detail belongs to.
    public var summary: IssueRowSummary
    /// The issue body, as Markdown source. Empty when the issue has none.
    public var bodyMarkdown: String

    /// Creates a detail record.
    /// - Parameters:
    ///   - summary: The inbox row.
    ///   - bodyMarkdown: The body as Markdown source.
    public init(summary: IssueRowSummary, bodyMarkdown: String = "") {
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
    }

    /// `IssueDetail` shares the identity of its ``summary``.
    public var id: String { summary.id }

    /// The repository the issue belongs to.
    public var repo: RepoRef { summary.repo }

    /// The issue number.
    public var number: Int { summary.number }
}
