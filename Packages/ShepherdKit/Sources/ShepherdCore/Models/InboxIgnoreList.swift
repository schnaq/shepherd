import Foundation

/// One pull request the user has put away.
///
/// It carries a copy of the row rather than a reference to it, because the row does not last:
/// the sweep prunes anything its searches stop returning, and the `involves:@me` facet is the
/// one that most often stops returning something. Settings still has to be able to list what is
/// hidden and offer it back, and a list of bare node ids would render as a column of opaque
/// base64.
public struct IgnoredPullRequest: Sendable, Codable, Hashable, Identifiable {
    /// The GraphQL node id — the same primary key ``PullRequestSummary/id`` is.
    public let id: String
    /// The repository the pull request belongs to.
    public var repo: RepoRef
    /// The pull request number within its repository.
    public var number: Int
    /// The title, as it read when it was put away.
    public var title: String
    /// When the user put it away.
    public var ignoredAt: Date

    /// Creates an entry.
    /// - Parameters:
    ///   - id: The GraphQL node id.
    ///   - repo: The repository.
    ///   - number: The pull request number.
    ///   - title: The title.
    ///   - ignoredAt: When it was put away.
    public init(id: String, repo: RepoRef, number: Int, title: String, ignoredAt: Date) {
        self.id = id
        self.repo = repo
        self.number = number
        self.title = title
        self.ignoredAt = ignoredAt
    }
}

/// The pull requests the user has asked the inbox to stop showing.
///
/// The `involves:@me` facet is a catch-all (ADR 0005), so a comment left on somebody else's pull
/// request years ago keeps that pull request in the inbox for as long as it stays open — with no
/// way to influence it and no reason to look at it again. This is the per-row answer to that: not
/// a rule about age or about repositories, but a list of individual pull requests the user has
/// decided are none of their business.
///
/// **A review request overrules it.** ``hides(_:)`` checks
/// ``PullRequestSummary/needsMyReview`` and gives up when it is true, so a pull request that was
/// put away and is later handed to the user comes back by itself. Hiding is a judgement about a
/// row as it stood; being asked for a review is new information about it, and the newer one wins.
/// That is also what makes the list safe to keep forever: the one state it must never suppress is
/// the one state that ignores it.
///
/// Device-local, deliberately. It is not part of ``/Shepherd/SettingsSync`` — the settings
/// document (ADR 0014) enumerates its fields one by one, and "which pull requests I have
/// dismissed on this Mac" is closer to the auto-delegation ledger than to a preference.
public struct InboxIgnoreList: Sendable, Codable, Hashable {
    /// What is hidden, newest first — the order Settings lists it in.
    public private(set) var entries: [IgnoredPullRequest]

    private var ids: Set<String> { Set(entries.map(\.id)) }

    /// Creates a list.
    /// - Parameter entries: The entries, in any order; they are sorted newest first.
    public init(entries: [IgnoredPullRequest] = []) {
        self.entries = entries.sorted { $0.ignoredAt > $1.ignoredAt }
    }

    /// Puts a pull request away.
    ///
    /// Ignoring something already on the list refreshes its timestamp rather than adding a second
    /// entry, which is what a row that came back through a review request and was dismissed again
    /// does.
    /// - Parameters:
    ///   - row: The row to hide.
    ///   - date: When this happened.
    public mutating func ignore(_ row: PullRequestSummary, at date: Date) {
        entries.removeAll { $0.id == row.id }
        entries.append(
            IgnoredPullRequest(
                id: row.id,
                repo: row.repo,
                number: row.number,
                title: row.title,
                ignoredAt: date
            )
        )
        entries.sort { $0.ignoredAt > $1.ignoredAt }
    }

    /// Shows a pull request again.
    /// - Parameter id: The node id to forget.
    public mutating func show(id: String) {
        entries.removeAll { $0.id == id }
    }

    /// Shows everything again.
    public mutating func showAll() {
        entries.removeAll()
    }

    /// Whether the inbox should leave a row out.
    /// - Parameter row: The row.
    /// - Returns: `true` when it is on the list and nobody is waiting on the user for it.
    public func hides(_ row: PullRequestSummary) -> Bool {
        guard ids.contains(row.id) else { return false }
        return !row.needsMyReview
    }

    /// Drops the hidden rows from a list of rows.
    /// - Parameter rows: The rows the sweep produced.
    /// - Returns: The rows the inbox shows.
    public func filter(_ rows: [PullRequestSummary]) -> [PullRequestSummary] {
        guard !entries.isEmpty else { return rows }
        let hidden = ids
        return rows.filter { !hidden.contains($0.id) || $0.needsMyReview }
    }
}
