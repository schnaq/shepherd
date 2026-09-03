import Foundation

/// What an author's closed pull requests in one repository add up to (ADR 0027).
///
/// Counting, and nothing more: every number here is a tally of things GitHub said, there is no
/// score, no grade and no threshold anywhere in the type. It colours the provenance chip and
/// orders rows *inside* a lane; it never decides a lane, and by ADR 0027's rule no automation
/// input can reach one.
public struct TrackRecord: Sendable, Codable, Hashable {
    /// How many of the counted pull requests were merged.
    public var merged: Int
    /// How many were closed without being merged.
    public var closedUnmerged: Int
    /// How many were merged and then reverted.
    public var reverted: Int
    /// The share of pull requests whose first push had green checks, `0...1`.
    ///
    /// `nil` when *no* counted pull request said anything about its first push — a backfill
    /// that found no check rollups, or an author whose pull requests all predate the window.
    /// A rate must not be invented from an empty denominator: the badge then leaves the clause
    /// out rather than printing "0 %".
    public var firstPushGreenRate: Double?
    /// The median number of change-requesting review rounds, `nil` when nothing was counted.
    public var medianReviewRounds: Double?

    /// The empty record: nothing counted, nothing claimed.
    public static let empty = TrackRecord()

    /// How far back a track record looks: ninety days (ADR 0027).
    ///
    /// The interview's number, and it is one number in one place because three surfaces quote it
    /// — the badge's popover says "last 90 days", the backfill's search query says
    /// `closed:>{90 days ago}`, and the counting's `since` cuts at exactly the same moment.
    public static let windowDays = 90

    /// The window as a duration.
    public static let window: TimeInterval = Double(TrackRecord.windowDays) * 24 * 60 * 60

    /// The oldest `closedAt` a record counts, relative to a moment.
    /// - Parameter now: The moment to measure back from.
    /// - Returns: `now` minus the window.
    public static func windowStart(from now: Date) -> Date {
        now.addingTimeInterval(-TrackRecord.window)
    }

    /// Creates a record.
    public init(
        merged: Int = 0,
        closedUnmerged: Int = 0,
        reverted: Int = 0,
        firstPushGreenRate: Double? = nil,
        medianReviewRounds: Double? = nil
    ) {
        self.merged = merged
        self.closedUnmerged = closedUnmerged
        self.reverted = reverted
        self.firstPushGreenRate = firstPushGreenRate
        self.medianReviewRounds = medianReviewRounds
    }

    /// How many pull requests the record counted.
    public var total: Int { merged + closedUnmerged }

    /// Whether there is anything to show. A row with no history gets no badge at all.
    public var isEmpty: Bool { total == 0 }

    /// The green-first-push share as whole percent, rounded, or `nil` when there is no rate.
    public var firstPushGreenPercent: Int? {
        firstPushGreenRate.map { Int(($0 * 100).rounded()) }
    }
}

/// Which author a record is about.
///
/// Agents are counted by their **display name** and humans by their login, because that is what
/// the two surfaces show: the badge sits beside "Claude Code", and a human's chip carries a
/// login. Both cases are one enum so the store's query and the badge's lookup cannot disagree
/// about what "this author" means.
public enum TrackRecordSubject: Sendable, Codable, Hashable {
    /// A recognised coding agent, by the display name the registry gives it.
    case agent(name: String)
    /// Anybody else, by login.
    case author(login: String)

    /// The subject of one inbox row.
    /// - Parameter actor: The pull request's author.
    public init(actor: Actor) {
        if let identity = actor.kind.agentIdentity {
            self = .agent(name: identity.displayName)
        } else {
            self = .author(login: actor.login)
        }
    }

    /// Whether one outcome belongs to this subject.
    /// - Parameter outcome: The stored outcome.
    public func matches(_ outcome: PullRequestOutcome) -> Bool {
        switch self {
        case .agent(let name):
            return outcome.agentName?.caseInsensitiveCompare(name) == .orderedSame
        case .author(let login):
            // An outcome that carries an agent name is that agent's, even when the pull request
            // was opened through a human's token: the badge beside "Claude Code" and the badge
            // beside a login must not both count the same pull request.
            return outcome.agentName == nil
                && outcome.authorLogin.caseInsensitiveCompare(login) == .orderedSame
        }
    }
}

extension TrackRecord {
    /// Counts the outcomes of one author in one repository since one date.
    ///
    /// Pure and total: an empty input is ``TrackRecord/empty``, and every optional is `nil`
    /// rather than a substituted zero when its denominator is empty. `since` is inclusive, and
    /// the app always passes ninety days ago (ADR 0027) — the parameter exists because the
    /// window is a decision the caller makes and a test has to be able to move.
    /// - Parameters:
    ///   - outcomes: The stored outcomes to count over, in any order.
    ///   - subject: Whose record this is.
    ///   - repo: The repository to count in, or `nil` for every repository.
    ///   - since: The oldest `closedAt` to count.
    /// - Returns: The record.
    public static func compute(
        outcomes: [PullRequestOutcome],
        subject: TrackRecordSubject,
        repo: RepoRef?,
        since: Date
    ) -> TrackRecord {
        var merged = 0
        var closedUnmerged = 0
        var reverted = 0
        var greenFirstPush = 0
        var knownFirstPush = 0
        var rounds: [Int] = []

        for outcome in outcomes {
            guard outcome.closedAt >= since else { continue }
            if let repo, !outcome.repo.isSameRepository(as: repo) { continue }
            guard subject.matches(outcome) else { continue }

            if outcome.merged {
                merged += 1
                if outcome.wasReverted { reverted += 1 }
            } else {
                closedUnmerged += 1
            }
            if let green = outcome.firstPushCIGreen {
                knownFirstPush += 1
                if green { greenFirstPush += 1 }
            }
            rounds.append(max(0, outcome.reviewRounds))
        }

        return TrackRecord(
            merged: merged,
            closedUnmerged: closedUnmerged,
            reverted: reverted,
            firstPushGreenRate: knownFirstPush == 0
                ? nil
                : Double(greenFirstPush) / Double(knownFirstPush),
            medianReviewRounds: median(of: rounds)
        )
    }

    /// Counts one agent's outcomes, by the display name its badge shows.
    ///
    /// The shorthand the badge uses; ``compute(outcomes:subject:repo:since:)`` is the same
    /// function with a human's login as the other case.
    /// - Parameters:
    ///   - outcomes: The stored outcomes to count over.
    ///   - agent: The agent's display name.
    ///   - repo: The repository to count in, or `nil` for every repository.
    ///   - since: The oldest `closedAt` to count.
    /// - Returns: The record.
    public static func compute(
        outcomes: [PullRequestOutcome],
        agent: String,
        repo: RepoRef?,
        since: Date
    ) -> TrackRecord {
        compute(outcomes: outcomes, subject: .agent(name: agent), repo: repo, since: since)
    }

    /// The median of a list of counts, `nil` for an empty one.
    ///
    /// The average of the two middle values for an even count, which is the ordinary definition
    /// and the reason the property is a `Double`: two pull requests, one clean and one that took
    /// a round, is 0.5 rounds — and rounding that to zero would read as "never needed a round".
    static func median(of values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return Double(sorted[middle]) }
        return (Double(sorted[middle - 1]) + Double(sorted[middle])) / 2
    }
}
