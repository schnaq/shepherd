import Foundation

/// The dimension the inbox is sectioned by.
public enum InboxFacet: String, Sendable, Codable, Hashable, CaseIterable {
    /// Who or what authored the pull request: agent, bot or human (ADR 0008).
    case provenance
    /// The repository the pull request belongs to.
    case repository
    /// GitHub's aggregate review decision.
    case reviewState
}

/// One section of the grouped inbox.
public struct InboxSection: Sendable, Hashable, Identifiable {
    /// A stable identifier, unique within a grouping run.
    public let id: String
    /// The section header text.
    public let title: String
    /// Which facet produced this section.
    public let facet: InboxFacet
    /// The rows of the section, already sorted.
    public let items: [PullRequestSummary]

    /// Creates a section.
    public init(id: String, title: String, facet: InboxFacet, items: [PullRequestSummary]) {
        self.id = id
        self.title = title
        self.facet = facet
        self.items = items
    }

    /// The number of rows in the section.
    public var count: Int { items.count }
}

/// Groups and sorts inbox rows.
///
/// Both the section order and the row order inside a section are fully deterministic: the
/// inbox must not reshuffle itself between two sweeps that returned the same data.
public enum InboxGrouper {
    /// Sorts rows most-recently-updated first, breaking ties on repository and number so the
    /// order never depends on dictionary iteration or network ordering.
    /// - Parameter items: The rows to sort.
    /// - Returns: The sorted rows.
    public static func sorted(_ items: [PullRequestSummary]) -> [PullRequestSummary] {
        items.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            if lhs.repo != rhs.repo { return lhs.repo < rhs.repo }
            if lhs.number != rhs.number { return lhs.number > rhs.number }
            return lhs.id < rhs.id
        }
    }

    /// Groups rows into sections.
    /// - Parameters:
    ///   - items: The rows to group.
    ///   - facet: The dimension to group by.
    /// - Returns: Sections in a stable display order, each with its rows sorted by
    ///   ``sorted(_:)``. Empty sections are never produced.
    public static func group(
        _ items: [PullRequestSummary],
        by facet: InboxFacet
    ) -> [InboxSection] {
        switch facet {
        case .provenance: return groupByProvenance(items)
        case .repository: return groupByRepository(items)
        case .reviewState: return groupByReviewState(items)
        }
    }

    // MARK: - Facets

    private static func groupByProvenance(_ items: [PullRequestSummary]) -> [InboxSection] {
        var buckets: [String: (title: String, sortKey: String, items: [PullRequestSummary])] = [:]
        for item in items {
            let kind = item.author.kind
            let key: String
            switch kind {
            case .agent(let identity): key = "agent:\(identity.id)"
            case .bot: key = "bot"
            case .human: key = "human"
            }
            var bucket = buckets[key]
                ?? (title: kind.provenanceLabel, sortKey: kind.provenanceSortKey, items: [])
            bucket.items.append(item)
            buckets[key] = bucket
        }
        return buckets
            .map { key, value in
                (key: key, sortKey: value.sortKey, section: InboxSection(
                    id: key,
                    title: value.title,
                    facet: .provenance,
                    items: sorted(value.items)
                ))
            }
            .sorted { lhs, rhs in
                if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
                return lhs.key < rhs.key
            }
            .map(\.section)
    }

    private static func groupByRepository(_ items: [PullRequestSummary]) -> [InboxSection] {
        var buckets: [RepoRef: [PullRequestSummary]] = [:]
        for item in items {
            buckets[item.repo, default: []].append(item)
        }
        return buckets
            .map { repo, rows in
                InboxSection(
                    id: repo.fullName,
                    title: repo.fullName,
                    facet: .repository,
                    items: sorted(rows)
                )
            }
            .sorted { $0.id.lowercased() < $1.id.lowercased() }
    }

    /// Fixed display order for review-state sections: what blocks the user comes first.
    private static let reviewStateOrder: [(key: String, title: String, decision: ReviewDecision?)] = [
        ("review-required", "Review required", .reviewRequired),
        ("changes-requested", "Changes requested", .changesRequested),
        ("approved", "Approved", .approved),
        ("no-decision", "No review decision", nil),
    ]

    private static func groupByReviewState(_ items: [PullRequestSummary]) -> [InboxSection] {
        var buckets: [String: [PullRequestSummary]] = [:]
        for item in items {
            let key = reviewStateOrder.first { $0.decision == item.reviewDecision }?.key
                ?? "no-decision"
            buckets[key, default: []].append(item)
        }
        return reviewStateOrder.compactMap { entry in
            guard let rows = buckets[entry.key], !rows.isEmpty else { return nil }
            return InboxSection(
                id: entry.key,
                title: entry.title,
                facet: .reviewState,
                items: sorted(rows)
            )
        }
    }
}
