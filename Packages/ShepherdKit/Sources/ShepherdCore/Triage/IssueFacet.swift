import Foundation

/// One row of the issues rail's LABELS facet (ADR 0032).
///
/// The pull-request rail has no label facet, so this is new rather than mirrored — but the
/// *shape* is ``TriageRiskFacet``'s, and it is here for that type's reason: "how many issues carry
/// this label" is a number a user reads off the rail and acts on, so it is counted by a pure
/// function that a Linux test can pin rather than by an expression inside a `body`.
public struct IssueLabelFacet: Sendable, Hashable, Identifiable {
    /// The label name, exactly as GitHub spells it.
    public var name: String
    /// How many issues carry it.
    public var count: Int

    /// `IssueLabelFacet` is identified by its label.
    public var id: String { name }

    /// Creates a facet row.
    /// - Parameters:
    ///   - name: The label name.
    ///   - count: How many issues carry it.
    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// The LABELS facet as the rail draws it: the rows that fit, and how many did not (ADR 0032).
///
/// A value rather than a bare array because the cap has to be *visible*. Labels are unbounded —
/// a repository may perfectly well have sixty — and a rail that silently showed the top eight
/// would make the ninth undiscoverable, which is the failure the REPOSITORIES facet already
/// answers with a "+3 more…" line. Counting the overflow here rather than in the view keeps the
/// number and the list from being derived from two different sorts.
public struct IssueLabelFacets: Sendable, Hashable {
    /// The rows to draw, most-used first.
    public var facets: [IssueLabelFacet]
    /// How many labels the cap left out.
    public var hiddenCount: Int

    /// Creates a facet list.
    /// - Parameters:
    ///   - facets: The rows to draw.
    ///   - hiddenCount: How many labels were left out.
    public init(facets: [IssueLabelFacet], hiddenCount: Int) {
        self.facets = facets
        self.hiddenCount = hiddenCount
    }

    /// Whether the rail has a LABELS section to draw at all.
    public var isEmpty: Bool { facets.isEmpty }
}

/// One row of the issues rail's AGE facet (ADR 0032).
public struct IssueAgeFacet: Sendable, Hashable, Identifiable {
    /// The bucket this row filters by.
    public var bucket: IssueAgeBucket
    /// How many issues were opened inside it.
    public var count: Int

    /// `IssueAgeFacet` is identified by its bucket.
    public var id: String { bucket.rawValue }

    /// Creates a facet row.
    /// - Parameters:
    ///   - bucket: The bucket.
    ///   - count: How many issues.
    public init(bucket: IssueAgeBucket, count: Int) {
        self.bucket = bucket
        self.count = count
    }
}

/// The two halves of the "has an agent pull request" facet (ADR 0032).
///
/// Two cases and no "unknown", which is the one thing worth saying about it: unlike the
/// pull-request rail's RISK facet, there is nothing to be uncertain about here. Every issue
/// either has a machine-authored pull request among the ones the sweep saw or it does not, and
/// ``IssueRowSummary/hasAgentPullRequest`` is the single definition both halves read.
public enum IssueAgentPullRequestFilter: String, Sendable, Codable, Hashable, CaseIterable {
    /// Issues a machine has already opened a pull request for.
    case hasAgentPullRequest
    /// Issues nothing has been handed to a machine for yet.
    case hasNone

    /// Whether one row belongs to this half.
    /// - Parameter summary: The issue row.
    public func matches(_ summary: IssueRowSummary) -> Bool {
        switch self {
        case .hasAgentPullRequest: return summary.hasAgentPullRequest
        case .hasNone: return !summary.hasAgentPullRequest
        }
    }

    /// The value ``IssueFilter/hasLinkedAgentPullRequest`` takes for this half.
    ///
    /// The store's filter and the rail's facet answer the same question, so the rail hands the
    /// store its own `Bool` rather than re-deriving one.
    public var storeValue: Bool {
        switch self {
        case .hasAgentPullRequest: return true
        case .hasNone: return false
        }
    }

    /// A stable display order: the rows a triage pass acts on first are at the top.
    ///
    /// "Has none" leads, because that is the half somebody opening this facet is looking for —
    /// the issues nobody has started on. Not derived from `allCases`, for
    /// ``TriageVerdict/Risk/facetSortIndex``'s reason: the case order spells the vocabulary,
    /// the facet order spells the question.
    public var facetSortIndex: Int {
        switch self {
        case .hasNone: return 0
        case .hasAgentPullRequest: return 1
        }
    }
}

/// One row of the issues rail's agent-pull-request facet (ADR 0032).
public struct IssueAgentPullRequestFacet: Sendable, Hashable, Identifiable {
    /// The half this row filters by.
    public var filter: IssueAgentPullRequestFilter
    /// How many issues are in it.
    public var count: Int

    /// `IssueAgentPullRequestFacet` is identified by its half.
    public var id: String { filter.rawValue }

    /// Creates a facet row.
    /// - Parameters:
    ///   - filter: The half.
    ///   - count: How many issues.
    public init(filter: IssueAgentPullRequestFilter, count: Int) {
        self.filter = filter
        self.count = count
    }
}

/// Counting the issues rail's facets — pure, so the numbers in the sidebar are unit-tested on
/// Linux (ADR 0032).
///
/// ``TriageFacets``' twin, and the same rule runs through all three functions: **a level nobody
/// is at is omitted rather than shown as zero**. A rail row that filters to an empty list is a
/// dead end the user has to discover by clicking it, which is what the AGENTS and REPOSITORIES
/// facets already avoid by only listing what is in the current data.
public enum IssueFacets {
    /// How many label rows the rail has room for.
    ///
    /// Eight rather than the REPOSITORIES facet's six, because a label is usually one short word
    /// where a repository is `owner/name`, and because a repository set is small while a label
    /// set is not — the overflow line is the honest part either way.
    public static let labelFacetLimit = 8

    /// Counts issues per label, most-used first.
    ///
    /// Ties break on the label name, case-insensitively and then exactly, so two labels with the
    /// same count keep the same order between two sweeps — the property that stops the rail
    /// reshuffling itself while nothing changed.
    /// - Parameters:
    ///   - rows: The issues to count over. The caller decides which ones: the rail counts over
    ///     the *unfiltered* section, exactly as the pull-request rail's facets do, because a
    ///     facet whose counts changed when you selected one of its own rows could not be used to
    ///     compare them.
    ///   - limit: How many rows to return.
    /// - Returns: The rows that fit, and how many labels did not.
    public static func labelFacets(
        _ rows: [IssueRowSummary],
        limit: Int = labelFacetLimit
    ) -> IssueLabelFacets {
        var counts: [String: Int] = [:]
        for row in rows {
            // A label repeated on one issue — which GitHub does not do, but a tolerant mapper
            // cannot promise — must not count twice.
            for label in Set(row.labels) {
                counts[label, default: 0] += 1
            }
        }
        let sorted = counts
            .map { IssueLabelFacet(name: $0.key, count: $0.value) }
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                let lowered = left.name.lowercased()
                let otherLowered = right.name.lowercased()
                if lowered != otherLowered { return lowered < otherLowered }
                return left.name < right.name
            }
        let cap = max(0, limit)
        guard sorted.count > cap else {
            return IssueLabelFacets(facets: sorted, hiddenCount: 0)
        }
        return IssueLabelFacets(
            facets: Array(sorted.prefix(cap)),
            hiddenCount: sorted.count - cap
        )
    }

    /// Counts issues per age bucket, newest bucket first.
    ///
    /// The bucketing is ``IssueAgeBucket/bucket(createdAt:now:)`` and nothing else, so the rail's
    /// count and the store's filter cannot disagree about what "this week" means.
    /// - Parameters:
    ///   - rows: The issues to count over.
    ///   - now: The moment to measure against. Stated by the caller rather than read from the
    ///     clock, for ``IssueFilter/now``'s reason: a facet that consulted `Date()` would produce
    ///     a different list every time a view redrew.
    /// - Returns: The non-empty buckets, in rail order.
    public static func ageFacets(_ rows: [IssueRowSummary], now: Date) -> [IssueAgeFacet] {
        var counts: [IssueAgeBucket: Int] = [:]
        for row in rows {
            let bucket = IssueAgeBucket.bucket(createdAt: row.createdAt, now: now)
            counts[bucket, default: 0] += 1
        }
        return counts
            .map { IssueAgeFacet(bucket: $0.key, count: $0.value) }
            .sorted { $0.bucket.facetSortIndex < $1.bucket.facetSortIndex }
    }

    /// Counts the two halves of the agent-pull-request facet, "has none" first.
    ///
    /// Both halves are returned only when both are populated. One populated half means the facet
    /// would either filter to nothing or filter to everything, and the rail draws nothing rather
    /// than a row that cannot narrow anything — the rule the LANES facet already follows with its
    /// `facets.count > 1` gate.
    /// - Parameter rows: The issues to count over.
    /// - Returns: The populated halves, in rail order.
    public static func agentPullRequestFacets(
        _ rows: [IssueRowSummary]
    ) -> [IssueAgentPullRequestFacet] {
        var withAgent = 0
        var without = 0
        for row in rows {
            if row.hasAgentPullRequest {
                withAgent += 1
            } else {
                without += 1
            }
        }
        var result: [IssueAgentPullRequestFacet] = []
        if without > 0 {
            result.append(IssueAgentPullRequestFacet(filter: .hasNone, count: without))
        }
        if withAgent > 0 {
            result.append(
                IssueAgentPullRequestFacet(filter: .hasAgentPullRequest, count: withAgent)
            )
        }
        return result
    }
}
