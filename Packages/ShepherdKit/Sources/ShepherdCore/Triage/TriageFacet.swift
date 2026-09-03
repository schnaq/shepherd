import Foundation

extension TriageVerdict.Risk {
    /// A stable display order: the risk that matters most is at the top of the rail.
    ///
    /// Not derived from `allCases`, because the case order in the twin follows the model's
    /// vocabulary (low → high) while a facet reads the other way round: a reviewer opening the
    /// rail is looking for what can hurt, not for what cannot.
    public var facetSortIndex: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

/// One inbox row's risk, as the facet sees it (plan §3.A).
///
/// The `isClassified` flag is the reason this is a value and not just a
/// ``TriageVerdict/Risk``: the facet counts two kinds of row — one the on-device model gave a
/// verdict, and one only the tier-1 heuristics could speak about — and the rail has to be able to
/// say which, because "12 high" built entirely out of heuristics is a different claim from "12
/// high" the model made.
public struct TriageRowRisk: Sendable, Hashable {
    /// The risk level.
    public var risk: TriageVerdict.Risk
    /// Whether it came from the model's verdict (`true`) or from the tier-1 hints (`false`).
    public var isClassified: Bool

    /// Creates a row risk.
    /// - Parameters:
    ///   - risk: The risk level.
    ///   - isClassified: Whether a verdict produced it.
    public init(risk: TriageVerdict.Risk, isClassified: Bool) {
        self.risk = risk
        self.isClassified = isClassified
    }
}

/// One section row of the rail's RISK facet.
public struct TriageRiskFacet: Sendable, Hashable, Identifiable {
    /// The risk level this row filters by.
    public var risk: TriageVerdict.Risk
    /// How many pull requests are at that risk.
    public var count: Int
    /// How many of those got there through a verdict rather than through the tier-1 hints.
    public var classifiedCount: Int

    /// `TriageRiskFacet` is identified by its level.
    public var id: String { risk.rawValue }

    /// Creates a facet row.
    /// - Parameters:
    ///   - risk: The level.
    ///   - count: How many rows.
    ///   - classifiedCount: How many of them from a verdict.
    public init(risk: TriageVerdict.Risk, count: Int, classifiedCount: Int) {
        self.risk = risk
        self.count = count
        self.classifiedCount = classifiedCount
    }
}

/// Counting the rail's risk facet — pure, so the numbers in the sidebar are unit-tested on Linux.
public enum TriageFacets {
    /// Counts rows per risk level, highest risk first.
    ///
    /// Levels nobody is at are **omitted** rather than shown as zero, exactly as the agents and
    /// repositories facets omit what is not in the current data: a rail row that filters to an
    /// empty list is a dead end the user has to discover by clicking it.
    /// - Parameter risks: One entry per pull request that has a risk at all. Rows with neither a
    ///   verdict nor a tier-1 hint are simply not in the list — a pull request nobody has opened
    ///   has no diff to judge, and counting it as "low" would be inventing a verdict.
    /// - Returns: The facet rows, high → medium → low, without empty levels.
    public static func riskFacets(_ risks: [TriageRowRisk]) -> [TriageRiskFacet] {
        var counts: [TriageVerdict.Risk: (total: Int, classified: Int)] = [:]
        for entry in risks {
            let existing = counts[entry.risk] ?? (0, 0)
            counts[entry.risk] = (
                existing.total + 1,
                existing.classified + (entry.isClassified ? 1 : 0)
            )
        }
        return counts
            .map { TriageRiskFacet(risk: $0.key, count: $0.value.total, classifiedCount: $0.value.classified) }
            .sorted { $0.risk.facetSortIndex < $1.risk.facetSortIndex }
    }
}

/// The `risk:` and `kind:` tokens ⌘K understands, parsed out of a query (plan §3.A).
///
/// A value rather than two sets passed around, because three things read the same answer: which
/// documents may appear at all, whether the query is "a search" for the palette's ordering
/// decision, and whether the query has any words left to rank or embed.
///
/// Two rules, and they are the ones a user expects from a search box rather than from a grammar:
///
/// - **Within an axis the values are OR'd, across axes they are AND'd.** `risk:high risk:medium`
///   means "either", `risk:high kind:dependency` means "both".
/// - **A token that names nothing stays a search word.** `risk:urgent` is not a level, so it
///   ranks as text instead of quietly filtering everything away — a filter nobody asked for that
///   empties the palette is indistinguishable from a broken search box.
public struct TriageFilter: Sendable, Hashable {
    /// The kinds the query asked for, or empty for "any kind".
    public var kinds: Set<TriageVerdict.Kind>
    /// The risk levels the query asked for, or empty for "any risk".
    public var risks: Set<TriageVerdict.Risk>

    /// Creates a filter.
    /// - Parameters:
    ///   - kinds: The kinds, or empty for any.
    ///   - risks: The levels, or empty for any.
    public init(kinds: Set<TriageVerdict.Kind> = [], risks: Set<TriageVerdict.Risk> = []) {
        self.kinds = kinds
        self.risks = risks
    }

    /// Whether the query named any token at all.
    public var isActive: Bool { !kinds.isEmpty || !risks.isEmpty }

    /// Whether one pull request's verdict passes the filter.
    ///
    /// A pull request with **no** verdict fails an active filter, and that is deliberate: the
    /// tokens name what the model said, so a row it never classified is not an answer to
    /// `kind:dependency`. The rail's facet is the surface that also counts the tier-1 heuristics
    /// (``TriageRowRisk``), because a rail row is a count and a ⌘K token is a claim.
    /// - Parameter verdict: The stored verdict, or `nil` when there is none.
    /// - Returns: `true` when the row may appear.
    public func matches(_ verdict: TriageVerdict?) -> Bool {
        guard isActive else { return true }
        guard let verdict else { return false }
        if !kinds.isEmpty, !kinds.contains(verdict.kind) { return false }
        if !risks.isEmpty, !risks.contains(verdict.risk) { return false }
        return true
    }

    /// Splits a query into its filter tokens and the words that are left.
    ///
    /// The remainder is what gets tokenised, ranked and embedded, so `risk:high login` searches
    /// for *login* among the high-risk pull requests rather than for the literal word "risk".
    /// - Parameter text: The query, verbatim.
    /// - Returns: The filter and the query with its filter tokens removed.
    public static func extract(from text: String) -> (filter: TriageFilter, remainder: String) {
        var kinds: Set<TriageVerdict.Kind> = []
        var risks: Set<TriageVerdict.Risk> = []
        var kept: [String] = []
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let colon = word.firstIndex(of: ":") else {
                kept.append(String(word))
                continue
            }
            let field = word[word.startIndex..<colon].lowercased()
            let value = String(word[word.index(after: colon)...])
            if field == "risk", let risk = TriageFilter.risk(forToken: value) {
                risks.insert(risk)
                continue
            }
            if field == "kind", let kind = TriageFilter.kind(forToken: value) {
                kinds.insert(kind)
                continue
            }
            kept.append(String(word))
        }
        return (TriageFilter(kinds: kinds, risks: risks), kept.joined(separator: " "))
    }

    /// The risk level a `risk:` token names, or `nil`.
    /// - Parameter token: What followed the colon.
    public static func risk(forToken token: String) -> TriageVerdict.Risk? {
        IntelligenceEnumDecoding.match(token)
    }

    /// The kind a `kind:` token names, or `nil`.
    ///
    /// `dependency` is spelled out here rather than left to the lenient matcher: the case is
    /// ``TriageVerdict/Kind/dependencyBump``, and nobody types "dependencyBump" into a search
    /// box. The plural and the usual abbreviation are accepted for the same reason.
    /// - Parameter token: What followed the colon.
    public static func kind(forToken token: String) -> TriageVerdict.Kind? {
        let normalized = token.lowercased().filter { $0.isLetter || $0.isNumber }
        if ["dependency", "dependencies", "deps", "dep"].contains(normalized) {
            return .dependencyBump
        }
        return IntelligenceEnumDecoding.match(normalized)
    }
}
