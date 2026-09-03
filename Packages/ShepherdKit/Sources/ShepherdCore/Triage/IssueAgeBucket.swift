import Foundation

/// How old an issue is, in the four buckets the issues rail offers as a facet.
///
/// A pure type in `Triage/` beside the pull-request facets, for the reason every faceting rule in
/// this folder is here: the bucketing is a decision that has to behave identically in the rail,
/// in ``IssueFilter`` and in a Linux test, and none of those three is allowed to have its own
/// idea of what "this week" means.
///
/// It buckets ``IssueRowSummary/createdAt`` rather than `updatedAt`, and that is the whole
/// distinction the facet is for: an issue that somebody commented on this morning has not become
/// a new issue, and "what has been sitting here since last month" is the question a triage pass
/// asks.
///
/// The boundaries are **elapsed spans**, not calendar edges. A calendar week would make the same
/// issue jump buckets at midnight on Sunday for reasons the reader cannot see, and would need a
/// locale to decide which day a week starts on; a span needs nothing but two dates and gives the
/// same answer on both of a user's Macs.
public enum IssueAgeBucket: String, Sendable, Codable, Hashable, CaseIterable {
    /// Opened within the last twenty-four hours.
    case today
    /// Opened within the last seven days, but not today.
    case thisWeek
    /// Opened within the last thirty days, but not this week.
    case thisMonth
    /// Opened more than thirty days ago.
    case older

    /// One day, in seconds — the unit the three boundaries are expressed in.
    static let day: TimeInterval = 24 * 60 * 60

    /// The bucket an issue opened at `createdAt` falls into.
    ///
    /// A `createdAt` in the *future* — a clock skew between GitHub and this Mac, which is real
    /// and is measured in seconds — lands in ``today`` rather than in an unreachable fifth case.
    /// - Parameters:
    ///   - createdAt: When the issue was opened.
    ///   - now: The moment to measure against.
    /// - Returns: The bucket.
    public static func bucket(createdAt: Date, now: Date) -> IssueAgeBucket {
        let age = now.timeIntervalSince(createdAt)
        if age < day { return .today }
        if age < 7 * day { return .thisWeek }
        if age < 30 * day { return .thisMonth }
        return .older
    }

    /// Whether an issue opened at `createdAt` is in this bucket.
    /// - Parameters:
    ///   - createdAt: When the issue was opened.
    ///   - now: The moment to measure against.
    public func contains(createdAt: Date, now: Date) -> Bool {
        IssueAgeBucket.bucket(createdAt: createdAt, now: now) == self
    }

    /// A stable display order for the rail: newest bucket first, which is the order a triage
    /// pass reads them in.
    public var facetSortIndex: Int {
        switch self {
        case .today: return 0
        case .thisWeek: return 1
        case .thisMonth: return 2
        case .older: return 3
        }
    }
}
