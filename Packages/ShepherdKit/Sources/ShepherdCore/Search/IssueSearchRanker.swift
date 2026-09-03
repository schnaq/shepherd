import Foundation

extension SearchReference {
    /// Whether an issue document is the row this reference names.
    ///
    /// The same two spellings a user types — `owner/name#128` and `#128` — mean the same thing on
    /// either side of the palette, so ``SearchQuery``'s parser is reused rather than copied; only
    /// the *matching* needs a second implementation, because the two documents are unrelated
    /// value types. ``SearchReference/pullRequest(repo:number:)`` therefore also matches an issue
    /// with that number: `schnaq/review#128` is one number in one repository, and GitHub itself
    /// draws issues and pull requests from a single sequence, so the two rankings cannot both be
    /// asked and only one of them come back with an exact hit.
    /// - Parameter document: The candidate.
    public func matches(_ document: IssueSearchDocument) -> Bool {
        switch self {
        case .pullRequest(let repo, let number):
            return document.number == number
                && document.repoFullName.lowercased() == repo.fullName.lowercased()
        case .number(let number):
            return document.number == number
        }
    }
}

/// Why an issue came up, in the words the row can show (ADR 0032).
///
/// Four cases against the pull request's nine, for ``SearchMatchReason``'s own reason: only a
/// match the reader *cannot already see* earns a line. A title match is not one — the title is
/// the biggest thing on the row — and an issue has no branch, no path and no diff line to name.
public enum IssueSearchMatchReason: Sendable, Hashable {
    /// The query named this issue outright.
    case exactReference
    /// A label matched.
    case label(String)
    /// The body matched.
    case body
    /// Nothing matched literally: the embedding did.
    case semantic
}

/// One ranked issue.
public struct IssueSearchResult: Sendable, Hashable, Identifiable {
    /// The issue's GraphQL node id.
    public let issueID: String
    /// The blended score the ordering uses.
    public let score: Double
    /// The lexical half, normalised to `0...1` across the candidate set.
    public let lexicalScore: Double
    /// The cosine similarity, when both the query and the document were embedded.
    public let similarity: Double?
    /// Whether the query named this issue outright.
    public let isExactReference: Bool
    /// Why it came up.
    public let reason: IssueSearchMatchReason?

    /// `IssueSearchResult` shares the issue's identity.
    public var id: String { issueID }

    /// Creates a result.
    public init(
        issueID: String,
        score: Double,
        lexicalScore: Double,
        similarity: Double?,
        isExactReference: Bool,
        reason: IssueSearchMatchReason?
    ) {
        self.issueID = issueID
        self.score = score
        self.lexicalScore = lexicalScore
        self.similarity = similarity
        self.isExactReference = isExactReference
        self.reason = reason
    }
}

/// The embeddings an issue ranking run has to work with.
///
/// ``SearchVectors``' twin, keyed by issue node id. A type of its own rather than the same one,
/// because the distinction it exists to make — "can this query be compared at all" — has to be
/// answerable for one corpus at a time: the palette computes both rankings and merges them, and a
/// Mac can perfectly well have embedded every issue and no pull request or the other way round.
public struct IssueSearchVectors: Sendable, Hashable {
    /// The query's own embedding.
    public let query: SearchVector
    /// One embedding per issue node id. Missing entries are normal — a document indexed while the
    /// model was unavailable has none, and it is ranked lexically.
    public let documents: [String: SearchVector]

    /// Creates a vector set.
    /// - Parameters:
    ///   - query: The query's embedding.
    ///   - documents: The document embeddings, keyed by node id.
    public init(query: SearchVector, documents: [String: SearchVector]) {
        self.query = query
        self.documents = documents
    }

    /// The cosine between the query and one document, or `nil` when that document has no vector.
    /// - Parameter issueID: The issue's node id.
    public func similarity(forDocument issueID: String) -> Double? {
        guard let vector = documents[issueID] else { return nil }
        return query.cosineSimilarity(to: vector)
    }
}

/// Ranks issues against a query — the whole of the issues half of ⌘K search's judgement, as a
/// pure function (ADR 0032).
///
/// ``SearchRanker``'s BM25 loop, duplicated rather than shared, and the duplication is the
/// decision: the arithmetic is eleven lines, the two corpora will keep diverging (an issue gains
/// no diff, ever), and a shared generic would buy an abstraction over two call sites at the price
/// of a protocol standing between the ranker and the fields it reads. The constants are the same
/// two standard ones, so a query cannot be scored on two different curves depending on which
/// section of the palette answers it.
///
/// The same three properties are load-bearing here as there:
///
/// - **It works without embeddings.** `vectors` empty leaves a deterministic BM25-shaped lexical
///   ranking, which is what a Mac without the on-device model gets — permanently.
/// - **An exact reference always wins.** `owner/name#128` and `#128` put that issue first
///   regardless of every score, because it is not a ranking question.
/// - **The order is total.** Score descending, then node id ascending, so two sweeps of the same
///   data can never reshuffle the palette.
public enum IssueSearchRanker {
    /// BM25's term-frequency saturation. The standard 1.2, and ``SearchRanker/k1``'s value.
    static let k1 = 1.2
    /// BM25's length normalisation. The standard 0.75, and ``SearchRanker/b``'s value.
    static let b = 0.75

    /// Ranks documents against a query.
    ///
    /// A query with no words to score — one that is nothing but a `risk:`/`kind:` token — returns
    /// **nothing** rather than a listing, which is where this deliberately parts company with its
    /// twin: a structured-triage verdict is a statement about a pull request (ADR 0023), there is
    /// no issue the filter could have narrowed, and listing every issue in the inbox in answer to
    /// `risk:high` would be an opinion nobody asked for.
    /// - Parameters:
    ///   - query: The parsed query, as ``SearchQuery`` reads it. An empty one ranks nothing.
    ///   - documents: The corpus — one document per issue in the local inbox. Order is
    ///     irrelevant; the result's order is total.
    ///   - vectors: The query's own embedding plus one per document, or `nil` for "no embeddings
    ///     are available", which is what a lexical-only Mac passes.
    ///   - options: Weights, floor and limit — ``SearchRankingOptions``, unchanged, because the
    ///     two halves of one palette must not blend their scores differently.
    /// - Returns: The best matches, best first, at most `options.limit` of them.
    public static func rank(
        query: SearchQuery,
        documents: [IssueSearchDocument],
        vectors: IssueSearchVectors? = nil,
        options: SearchRankingOptions = .standard
    ) -> [IssueSearchResult] {
        guard query.hasSearchTerms, !documents.isEmpty else { return [] }

        // Document frequency over the *candidate* set, which is the whole local issues inbox. A
        // corpus this small has no room for a global IDF table and needs none: the inbox is the
        // corpus.
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for token in query.distinctTokens where document.terms[token] != nil {
                documentFrequency[token, default: 0] += 1
            }
        }
        let count = Double(documents.count)
        let averageLength = documents.reduce(0.0) { $0 + $1.length } / count

        var raw: [(document: IssueSearchDocument, lexical: Double, similarity: Double?)] = []
        raw.reserveCapacity(documents.count)
        var maximumLexical = 0.0
        for document in documents {
            var lexical = 0.0
            for token in query.distinctTokens {
                guard let frequency = document.terms[token] else { continue }
                let df = Double(documentFrequency[token] ?? 0)
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let normalisedLength = averageLength > 0 ? document.length / averageLength : 1
                let denominator = frequency + k1 * (1 - b + b * normalisedLength)
                lexical += idf * (frequency * (k1 + 1)) / denominator
            }
            maximumLexical = max(maximumLexical, lexical)
            raw.append(
                (
                    document: document,
                    lexical: lexical,
                    similarity: vectors?.similarity(forDocument: document.issueID)
                )
            )
        }

        var results: [IssueSearchResult] = []
        for entry in raw {
            let isExact = query.reference?.matches(entry.document) ?? false
            let normalisedLexical = maximumLexical > 0 ? entry.lexical / maximumLexical : 0
            // Negative cosines are clamped rather than kept: "pointing the other way" and
            // "unrelated" are the same answer for ranking, and a negative term would let one
            // strongly-opposite dimension push a document below one with no vector at all.
            let clampedSimilarity = max(0, entry.similarity ?? 0)
            let score: Double
            if vectors == nil {
                score = normalisedLexical
            } else {
                score = options.lexicalWeight * normalisedLexical
                    + options.semanticWeight * clampedSimilarity
            }
            let hasLiteralMatch = entry.lexical > 0
            let isSemanticHit = clampedSimilarity >= options.minimumSimilarity
            guard isExact || hasLiteralMatch || isSemanticHit else { continue }
            results.append(
                IssueSearchResult(
                    issueID: entry.document.issueID,
                    score: isExact ? 1 : score,
                    lexicalScore: normalisedLexical,
                    similarity: entry.similarity,
                    isExactReference: isExact,
                    reason: reason(
                        for: entry.document,
                        query: query,
                        isExact: isExact,
                        hasLiteralMatch: hasLiteralMatch
                    )
                )
            )
        }

        results.sort { left, right in
            if left.isExactReference != right.isExactReference { return left.isExactReference }
            if left.score != right.score { return left.score > right.score }
            return left.issueID < right.issueID
        }
        return Array(results.prefix(max(0, options.limit)))
    }

    /// Picks the one thing worth telling the user about the match.
    ///
    /// A fixed order, so the line never depends on dictionary iteration: the reference, then the
    /// label the query hit, then the body, then "the embedding did it". The first matching query
    /// token wins within a field, so a two-word query reports the word that is actually in the
    /// label rather than whichever one hashes first.
    private static func reason(
        for document: IssueSearchDocument,
        query: SearchQuery,
        isExact: Bool,
        hasLiteralMatch: Bool
    ) -> IssueSearchMatchReason? {
        if isExact { return .exactReference }
        guard hasLiteralMatch else { return .semantic }
        for token in query.distinctTokens {
            guard let fields = document.fieldsByTerm[token], fields.contains(.labels) else {
                continue
            }
            if let label = document.labels.first(where: { contains(token, in: $0) }) {
                return .label(label)
            }
        }
        for token in query.distinctTokens {
            if document.fieldsByTerm[token]?.contains(.body) == true { return .body }
        }
        return nil
    }

    /// Whether a token is one of a value's own tokens.
    ///
    /// Token-level rather than `contains`: a substring test would report the label `sourcing` as
    /// the match for a query of `our`.
    private static func contains(_ token: String, in value: String) -> Bool {
        SearchText.tokens(in: value).contains(token)
    }
}
