import Foundation

/// A referenced GitHub issue — as much of one as the claims card needs (ADR 0026's amendment).
///
/// Deliberately *not* a second `PullRequestSummary`. The only question Shepherd asks an issue is
/// "what does it ask for, and is it even an issue": the body, so
/// ``AcceptanceCriteria/bullets(from:)`` can look for a checklist in it; the title and state, so
/// the card can name what it read; and ``isPullRequest``, because GitHub's issue endpoint answers
/// for pull requests too and a pull request has no acceptance criteria to check. Nothing here is
/// persisted (ADR 0026's amendment: the body is needed only while the card is open), so there is
/// no id, no author and no timestamps to keep in step with a table.
public struct IssueSummary: Sendable, Codable, Hashable, Identifiable {
    /// Whether the issue is still open.
    public enum State: String, Sendable, Codable, Hashable, CaseIterable {
        /// The issue is open.
        case open
        /// The issue is closed.
        case closed
        /// GitHub reported a state Shepherd does not model.
        case unknown

        /// Maps GitHub's `state` string onto a state.
        /// - Parameter raw: The raw state string, e.g. `"open"`.
        public static func fromAPI(_ raw: String) -> State {
            switch raw.lowercased() {
            case "open": return .open
            case "closed": return .closed
            default: return .unknown
            }
        }
    }

    /// The repository the issue belongs to.
    ///
    /// Always the pull request's own repository: a `fixes #N` reference is repository-local, and
    /// Shepherd never resolves a cross-repository reference — see
    /// ``EvidenceChecker/check(_:in:issue:matches:failure:)``.
    public var repo: RepoRef
    /// The issue number.
    public var number: Int
    /// The issue title.
    public var title: String
    /// The issue body, as Markdown source. Empty when the issue has none.
    public var bodyMarkdown: String
    /// Whether the issue is open or closed.
    public var state: State
    /// Whether GitHub answered with a *pull request* rather than an issue.
    ///
    /// `GET /repos/{o}/{r}/issues/{n}` serves both, and a pull request carries a `pull_request`
    /// object where an issue carries none. `#142` in a description can perfectly well point at a
    /// pull request, and the honest answer for that line is "there are no acceptance criteria
    /// here" rather than an empty checklist.
    public var isPullRequest: Bool
    /// The issue's page on GitHub, when the response carried one.
    public var url: URL?

    /// Creates an issue summary.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - number: The issue number.
    ///   - title: The issue title.
    ///   - bodyMarkdown: The body as Markdown source.
    ///   - state: Whether it is open or closed.
    ///   - isPullRequest: Whether GitHub answered with a pull request.
    ///   - url: The issue's page on GitHub.
    public init(
        repo: RepoRef,
        number: Int,
        title: String = "",
        bodyMarkdown: String = "",
        state: State = .unknown,
        isPullRequest: Bool = false,
        url: URL? = nil
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.state = state
        self.isPullRequest = isPullRequest
        self.url = url
    }

    /// An issue is identified by its repository and number.
    public var id: String { "\(repo.fullName)#\(number)" }
}
