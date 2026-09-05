import Foundation

/// One thing the fleet says about an agent without being asked.
///
/// Values only. Every case carries counts, denominators and the repository it is about, and no
/// wording at all — for two reasons rather than one. The sentence is a user-visible string and
/// belongs in the app target where it can be localised (ADR 0022); ShepherdCore has no such strings
/// by decision. And a notice has to be *checkable*: each of these is derivable from the
/// per-repository grid drawn underneath it, so a reader who doubts the sentence can count the row
/// themselves. A case that carried a finished sentence could quietly stop matching that grid.
///
/// Percentages are not here either. Each rate comes back as the two counts it was computed from, so
/// the screen can say "45 % (9 of 20)" and never a number nothing on the page adds up to.
///
/// Nothing here is a verdict, and nothing here can act: a notice is a sentence, it names no pull
/// request to fix, and there is no code path from one to a write (ADR 0027's rule, ADR 0029's
/// shape).
public enum FleetNotice: Sendable, Hashable {
    /// One side of ``revertShareGap(repo:higher:lower:)``: one agent's merges in one repository,
    /// and how many of them were taken back out again.
    ///
    /// A small struct rather than a tuple because the notice is ``Hashable`` and a tuple is not —
    /// and because the two sides of that sentence are the same three facts in the same order,
    /// which a type says and a pair of tuples only implies.
    public struct RevertShare: Sendable, Hashable {
        /// The agent's display name, spelled the way its most recently closed pull request spells
        /// it — never a login, for ``FleetAgent``'s reason.
        public var agent: String
        /// How many of ``merged`` were later reverted.
        public var reverted: Int
        /// How many pull requests the agent merged in the repository inside the window.
        ///
        /// The denominator of the share, and a reverted pull request is one of these: it *was*
        /// merged, and the revert is the second fact rather than a correction of the first
        /// (ADR 0027).
        public var merged: Int

        /// Creates one side of the comparison.
        /// - Parameters:
        ///   - agent: The agent's display name.
        ///   - reverted: How many of its merges were reverted.
        ///   - merged: How many pull requests it merged in the repository.
        public init(agent: String, reverted: Int, merged: Int) {
            self.agent = agent
            self.reverted = reverted
            self.merged = merged
        }
    }

    /// The agent's last few pull requests in one repository all needed at least one round of
    /// requested changes.
    ///
    /// The streak is counted from the most recent close backwards and stops at the first pull
    /// request that needed none, so it is a statement about *now* rather than about the window as
    /// a whole.
    case reworkStreak(agent: String, repo: RepoRef, streak: Int)

    /// The agent's first push is green far less — or far more — often in one repository than in the
    /// others it works in.
    ///
    /// Both sides are counts: `greenHere` of `totalHere` in this repository, `greenElsewhere` of
    /// `totalElsewhere` across `otherRepositoryCount` others. The denominators count only the pull
    /// requests that said something about their first push, because "nothing is known" must not be
    /// counted as "it was red" (``PullRequestOutcome/firstPushCIGreen``).
    case greenRateGap(
        agent: String,
        repo: RepoRef,
        greenHere: Int,
        totalHere: Int,
        greenElsewhere: Int,
        totalElsewhere: Int,
        otherRepositoryCount: Int
    )

    /// In one repository, one agent's merges were reverted markedly more often than another's.
    ///
    /// The only sentence in the fleet that mentions two agents at once, and it is a **pair**: two
    /// names, four counts, one repository, and no third agent, no ordinal and no total. It is
    /// assembled from the repository's rows alone, so the same pair in the same roles is produced
    /// for whichever of the two agents' pages asked for it — the reader sees one statement, not two
    /// that might disagree.
    case revertShareGap(repo: RepoRef, higher: RevertShare, lower: RevertShare)
}

/// The three sentences the fleet states unprompted, and the thresholds that let it.
///
/// Pure functions over the outcomes ADR 0027 already stores: no model, no request, no setting, and
/// nothing that could reach one. ``RecurringFindingDetector`` is the precedent and the shape is the
/// same — a rule per sentence, a named constant per number so it has one home and a test on both
/// sides of it, and an empty answer as the ordinary case.
///
/// The numbers are all of the same kind: they are the point below which a count is not evidence of
/// anything. Shepherd is about to say something about somebody's agent without being asked, so each
/// of them is deliberately conservative, and each one is documented with where it came from rather
/// than only with what it is.
public enum FleetNotices {
    /// How many pull requests in a row must have needed changes before that is worth saying: three.
    ///
    /// ADR 0029's number, arrived at for the same reason and borrowed on purpose:
    /// ``RecurringFindingDetector/minimumCount`` is 3 because twice is a coincidence. Written out
    /// here rather than referring to that constant, because the two rules only *agree*: retuning
    /// how often a reviewer must repeat themselves before a card appears is not a decision about
    /// when an agent's rework is worth a sentence, and a shared symbol would make it one.
    public static let minimumReworkStreak = 3

    /// How many pull requests must have said something about their first push, on **each** side of
    /// the comparison, before the two rates may be compared at all: five.
    ///
    /// Two rates over four pull requests each move by 25 % as soon as one of them goes the other
    /// way, so a gap between them is noise wearing a percent sign. Five is the smallest denominator
    /// at which one pull request moves a rate by no more than a fifth — and it is also the number
    /// ADR 0027 already treats as "enough to mean something", where a settled record needs at least
    /// five merges before the provenance chip may turn green.
    public static let minimumFirstPushDenominator = 5

    /// How far apart the two first-push rates must be: thirty points.
    ///
    /// Large enough that the gap survives the next pull request. At the smallest denominator this
    /// rule accepts one of them moves a rate by twenty points, so thirty still leaves ten standing
    /// afterwards. A smaller threshold would state a difference that the next merge could erase,
    /// which is the failure mode that makes an unprompted claim untrustworthy rather than merely
    /// wrong.
    public static let minimumFirstPushGap = 0.30

    /// How many merges an agent must have in a repository before its revert share may be compared
    /// with another agent's: ten.
    ///
    /// This is the one sentence that names two agents, so it carries the highest bar in the
    /// file. At ten merges a single revert is ten points of share, which is already most of
    /// ``minimumRevertShareGap``; below that, the arithmetic is about one pull request rather than
    /// about a pattern, and the sentence would be comparing two accidents.
    public static let minimumMergesForRevertShare = 10

    /// How far apart the two revert shares must be: fifteen points.
    ///
    /// Chosen against ``minimumMergesForRevertShare``: at ten merges a side one revert is ten
    /// points, so fifteen cannot be reached by a single pull request on either side. The gap has to
    /// be something that two reverts made and one cannot unmake.
    public static let minimumRevertShareGap = 0.15

    /// How many reverts the higher side must actually have: two.
    ///
    /// "One of its merges was taken back out" is an incident, not a tendency — the same "twice is
    /// a coincidence" that ``minimumReworkStreak`` rests on, applied to a numerator instead of to
    /// a streak.
    ///
    /// At the other two thresholds this one cannot fire on its own: a share of fifteen points over
    /// at least ten merges already needs two reverts, so nothing reaches this guard that the gap
    /// has not already refused. It is written down anyway, because that is only true *while* the
    /// other two numbers are what they are — and loosening either of them without it would let a
    /// single revert produce a sentence comparing two agents.
    public static let minimumRevertsOnTheHigherSide = 2

    // MARK: - Detection

    /// The notices for one agent's page: at most three, streak first.
    ///
    /// At most three because there are three rules and each yields at most one sentence — the cap
    /// is the shape of the function rather than a number it applies at the end. The order is fixed:
    /// the rework streak, then the first-push gap, then the pairwise revert share, which is the
    /// order of how *actionable* they are and never the order of how bad they sound. Every notice
    /// names a repository, so each one can be checked against the per-repository grid below it.
    ///
    /// `outcomes` is the **whole** window, every agent's rows and not just this agent's, because
    /// ``FleetNotice/revertShareGap(repo:higher:lower:)`` compares two agents in one repository and
    /// cannot be computed from one agent's rows. The function does the filtering itself, on both
    /// axes: `since` for the window and ``TrackRecordSubject/matches(_:)`` for the agent, so it is
    /// correct whatever a caller has or has not already narrowed.
    ///
    /// The pairwise notice is produced only when `agent` is one of the two it names. An agent's
    /// page never carries a sentence about two *other* agents: that would be a table of everybody
    /// with a rate in it, arrived at one page at a time.
    ///
    /// Pure and total. An empty answer is the normal one and "the page states nothing" is what it
    /// means.
    ///
    /// - Parameters:
    ///   - agent: The display name of the agent whose page is asking, matched case-insensitively.
    ///   - outcomes: Every agent's stored outcomes, in any order.
    ///   - since: The oldest `closedAt` to count; the app passes ninety days ago (ADR 0027).
    /// - Returns: The notices, at most three, in rule order.
    public static func detect(
        for agent: String,
        outcomes: [PullRequestOutcome],
        since: Date
    ) -> [FleetNotice] {
        let counted = outcomes.filter { $0.closedAt >= since && $0.agentName != nil }
        let subject = TrackRecordSubject.agent(name: agent)
        let mine = counted.filter { subject.matches($0) }

        var mineByRepo: [String: [PullRequestOutcome]] = [:]
        for outcome in mine {
            mineByRepo[repositoryKey(outcome.repo), default: []].append(outcome)
        }

        var notices: [FleetNotice] = []
        if let streak = reworkStreak(in: mineByRepo) { notices.append(streak) }
        if let gap = greenRateGap(mine: mine, mineByRepo: mineByRepo) { notices.append(gap) }
        if let share = revertShareGap(for: agent, counted: counted, since: since) {
            notices.append(share)
        }
        return notices
    }

    /// The rework streak, or `nil` when no repository has one long enough to mention.
    ///
    /// The rows of one repository, most recent first; the streak is the run of leading pull
    /// requests that needed at least one round of changes and it ends at the first one that did
    /// not. Several repositories qualifying is broken by the longest streak, then by the most
    /// recent close, then by the repository's name — a total order, so the sentence a page shows
    /// does not depend on the order the database returned its rows in.
    /// - Parameter mineByRepo: The agent's counted outcomes, bucketed by repository.
    /// - Returns: The notice, or `nil`.
    private static func reworkStreak(
        in mineByRepo: [String: [PullRequestOutcome]]
    ) -> FleetNotice? {
        var candidates: [(streak: Int, lastClosedAt: Date, key: String, notice: FleetNotice)] = []
        for (key, repoOutcomes) in mineByRepo {
            let ordered = repoOutcomes.sorted { left, right in
                if left.closedAt != right.closedAt { return left.closedAt > right.closedAt }
                return left.prID < right.prID
            }
            var streak = 0
            for outcome in ordered {
                guard outcome.reviewRounds >= 1 else { break }
                streak += 1
            }
            guard streak >= minimumReworkStreak else { continue }
            guard let head = FleetRoster.mostRecentlyClosed(repoOutcomes),
                let name = head.agentName
            else { continue }
            candidates.append((
                streak: streak,
                lastClosedAt: head.closedAt,
                key: key,
                notice: .reworkStreak(agent: name, repo: head.repo, streak: streak)
            ))
        }
        candidates.sort { left, right in
            if left.streak != right.streak { return left.streak > right.streak }
            if left.lastClosedAt != right.lastClosedAt {
                return left.lastClosedAt > right.lastClosedAt
            }
            return left.key < right.key
        }
        return candidates.first?.notice
    }

    /// The first-push gap between one repository and the agent's others, or `nil` when there is
    /// none worth stating.
    ///
    /// The counts are made here rather than read off ``TrackRecord``, which carries the finished
    /// rate and not the two numbers behind it — and the notice owes the screen those two numbers,
    /// because a percentage nobody can check against the grid is exactly what this file is trying
    /// not to produce. The rule they are made by is ADR 0027's, unchanged: an unknown first push is
    /// in neither the numerator nor the denominator.
    ///
    /// `otherRepositoryCount` counts the repositories that actually contributed to the second
    /// denominator. A repository whose pull requests all say nothing about their first push adds
    /// nothing to that rate, and counting it would make the sentence claim a wider base than it
    /// has.
    /// - Parameters:
    ///   - mine: The agent's counted outcomes across every repository.
    ///   - mineByRepo: The same rows, bucketed by repository.
    /// - Returns: The notice, or `nil`.
    private static func greenRateGap(
        mine: [PullRequestOutcome],
        mineByRepo: [String: [PullRequestOutcome]]
    ) -> FleetNotice? {
        var candidates: [(gap: Double, totalHere: Int, key: String, notice: FleetNotice)] = []
        for (key, repoOutcomes) in mineByRepo {
            let here = repoOutcomes.compactMap(\.firstPushCIGreen)
            guard here.count >= minimumFirstPushDenominator else { continue }

            let elsewhere = mine.filter { repositoryKey($0.repo) != key }
            let elsewhereKnown = elsewhere.filter { $0.firstPushCIGreen != nil }
            guard elsewhereKnown.count >= minimumFirstPushDenominator else { continue }

            let greenHere = here.filter { $0 }.count
            let greenElsewhere = elsewhereKnown.filter { $0.firstPushCIGreen == true }.count
            let hereRate = Double(greenHere) / Double(here.count)
            let elsewhereRate = Double(greenElsewhere) / Double(elsewhereKnown.count)
            guard abs(hereRate - elsewhereRate) >= minimumFirstPushGap else { continue }

            guard let head = FleetRoster.mostRecentlyClosed(repoOutcomes),
                let name = head.agentName
            else { continue }
            candidates.append((
                gap: abs(hereRate - elsewhereRate),
                totalHere: here.count,
                key: key,
                notice: .greenRateGap(
                    agent: name,
                    repo: head.repo,
                    greenHere: greenHere,
                    totalHere: here.count,
                    greenElsewhere: greenElsewhere,
                    totalElsewhere: elsewhereKnown.count,
                    otherRepositoryCount: Set(elsewhereKnown.map { repositoryKey($0.repo) }).count
                )
            ))
        }
        // The widest gap, then the one standing on more pull requests, then the name. The second
        // key is the repository's own denominator: of two equally wide gaps, the sentence to state
        // is the one whose subject — this repository — is the better attested of the two.
        candidates.sort { left, right in
            if left.gap != right.gap { return left.gap > right.gap }
            if left.totalHere != right.totalHere { return left.totalHere > right.totalHere }
            return left.key < right.key
        }
        return candidates.first?.notice
    }

    /// The pairwise revert-share notice, or `nil` when no repository has a pair worth stating.
    ///
    /// The counting is ``TrackRecord/compute(outcomes:subject:repo:since:)``, once per agent per
    /// repository, and no merges or reverts are counted anywhere in this file besides that call:
    /// a sentence comparing two agents must be made of the same numbers their two grids show, or
    /// the page argues with itself.
    ///
    /// Everything about the pair is derived from the repository's rows and nothing from `agent`,
    /// which is what makes the sentence identical on both of the pages it appears on. `agent` is
    /// read exactly once, at the end, to answer a different question: whether this page is one of
    /// the two the sentence is about.
    /// - Parameters:
    ///   - agent: The display name of the agent whose page is asking.
    ///   - counted: Every agent's outcomes inside the window.
    ///   - since: The oldest `closedAt` to count, passed on to the counting.
    /// - Returns: The notice, or `nil`.
    private static func revertShareGap(
        for agent: String,
        counted: [PullRequestOutcome],
        since: Date
    ) -> FleetNotice? {
        var byRepo: [String: [PullRequestOutcome]] = [:]
        for outcome in counted { byRepo[repositoryKey(outcome.repo), default: []].append(outcome) }

        var candidates: [(gap: Double, key: String, notice: FleetNotice)] = []
        for (key, repoOutcomes) in byRepo {
            guard let repo = FleetRoster.mostRecentlyClosed(repoOutcomes)?.repo else { continue }
            var byAgent: [String: [PullRequestOutcome]] = [:]
            for outcome in repoOutcomes {
                guard let name = outcome.agentName else { continue }
                byAgent[name.lowercased(), default: []].append(outcome)
            }

            var shares: [(share: Double, side: FleetNotice.RevertShare)] = []
            for agentOutcomes in byAgent.values {
                guard let name = FleetRoster.mostRecentlyClosed(agentOutcomes)?.agentName else {
                    continue
                }
                let record = TrackRecord.compute(
                    outcomes: agentOutcomes,
                    subject: .agent(name: name),
                    repo: repo,
                    since: since
                )
                guard record.merged >= minimumMergesForRevertShare else { continue }
                shares.append((
                    share: Double(record.reverted) / Double(record.merged),
                    side: FleetNotice.RevertShare(
                        agent: name,
                        reverted: record.reverted,
                        merged: record.merged
                    )
                ))
            }
            // Two sides, or there is no comparison to make: one agent in a repository is a fact
            // about that agent and the grid above already says it.
            guard shares.count >= 2 else { continue }
            shares.sort { left, right in
                if left.share != right.share { return left.share > right.share }
                return left.side.agent.lowercased() < right.side.agent.lowercased()
            }
            guard let higher = shares.first, let lower = shares.last else { continue }
            guard higher.side.reverted >= minimumRevertsOnTheHigherSide else { continue }
            let gap = higher.share - lower.share
            guard gap >= minimumRevertShareGap else { continue }
            guard higher.side.agent.caseInsensitiveCompare(agent) == .orderedSame
                || lower.side.agent.caseInsensitiveCompare(agent) == .orderedSame
            else { continue }
            candidates.append((
                gap: gap,
                key: key,
                notice: .revertShareGap(repo: repo, higher: higher.side, lower: lower.side)
            ))
        }
        candidates.sort { left, right in
            if left.gap != right.gap { return left.gap > right.gap }
            return left.key < right.key
        }
        return candidates.first?.notice
    }

    /// The key one repository's rows are bucketed under.
    ///
    /// The lower-cased full name, which is ``RepoRef/isSameRepository(as:)``'s comparison written
    /// as a dictionary key: two spellings of one repository must not become two rows in a sentence
    /// that claims to be about a repository.
    /// - Parameter repo: The repository.
    /// - Returns: Its bucket key.
    private static func repositoryKey(_ repo: RepoRef) -> String { repo.fullName.lowercased() }
}
