import Foundation

/// A reference to one specific pull request, recognised inside a search query.
///
/// The reason ⌘K search can be trusted with an exact identifier: a user who types
/// `schnaq/review#128` has not asked to be ranked, they have asked for a row. Both spellings the
/// user actually types are recognised, and nothing else — a bare number is *not* one of them,
/// because `2026` and `500` are ordinary search words far more often than they are pull-request
/// numbers.
public enum SearchReference: Sendable, Hashable {
    /// `owner/name#number` — one pull request in one repository.
    case pullRequest(repo: RepoRef, number: Int)
    /// `#number` — that number in any repository the inbox holds.
    case number(Int)

    /// Whether a document is the pull request this reference names.
    /// - Parameter document: The candidate.
    public func matches(_ document: SearchDocument) -> Bool {
        switch self {
        case .pullRequest(let repo, let number):
            return document.number == number
                && document.repoFullName.lowercased() == repo.fullName.lowercased()
        case .number(let number):
            return document.number == number
        }
    }
}

/// What the user typed, parsed once (ADR 0019).
///
/// A value rather than a string passed around, because three different decisions are made from
/// one query and each of them would otherwise re-derive its own answer: which documents to rank,
/// whether an exact row was named, and whether the pull-request section belongs *above* the
/// commands (a prose query is a search; a one-word query is usually the start of a command name).
public struct SearchQuery: Sendable, Hashable {
    /// What the user typed, verbatim.
    public let text: String
    /// The trimmed query — what the embedder is asked about.
    public let normalizedText: String
    /// The lower-cased tokens, in order.
    public let tokens: [String]
    /// The distinct tokens, which is what scoring iterates.
    public let distinctTokens: [String]
    /// An explicit pull-request reference, when the query is one.
    public let reference: SearchReference?

    /// Whether there is nothing to search for.
    public var isEmpty: Bool { tokens.isEmpty && reference == nil }

    /// Whether the query reads like a sentence rather than the beginning of a command.
    ///
    /// Two tokens is the threshold, and it is the whole heuristic: "sync" is somebody reaching
    /// for *Sync all repositories now*, "flaky login test" is nobody's command name. An explicit
    /// reference counts as prose too — `#128` is unambiguously about a pull request.
    public var looksLikeProse: Bool { reference != nil || tokens.count >= 2 }

    /// Parses a query.
    /// - Parameter text: What the user typed.
    public init(text: String) {
        self.text = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalizedText = trimmed
        self.tokens = SearchText.tokens(in: trimmed)
        var seen = Set<String>()
        self.distinctTokens = tokens.filter { seen.insert($0).inserted }
        self.reference = SearchQuery.parseReference(trimmed)
    }

    /// Recognises `owner/name#number` and `#number`, and nothing else.
    private static func parseReference(_ text: String) -> SearchReference? {
        guard text.contains("#") else { return nil }
        let parts = text.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, let number = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              number > 0
        else { return nil }
        let head = parts[0].trimmingCharacters(in: .whitespaces)
        if head.isEmpty { return .number(number) }
        guard let repo = RepoRef.parse(fullName: head) else { return nil }
        return .pullRequest(repo: repo, number: number)
    }
}

/// Why a pull request came up, in the words the row can show.
///
/// Only reasons that are *cheap and specific* are modelled. A title match is deliberately absent:
/// the title is already the biggest thing on the row, and "matched: the title" is a sentence that
/// tells the reader what they can see. What earns a line is the match they cannot see — a label, a
/// file path, a branch, a line of the diff.
public enum SearchMatchReason: Sendable, Hashable {
    /// The query named this pull request outright.
    case exactReference
    /// A label matched.
    case label(String)
    /// A changed file's path matched.
    case filePath(String)
    /// An added line of the diff matched.
    case addedLine(String)
    /// The head branch name matched.
    case branch(String)
    /// The author (or the agent's name) matched.
    case author(String)
    /// The description matched.
    case body
    /// Nothing matched literally: the embedding did.
    case semantic
}

/// One ranked pull request.
public struct SearchResult: Sendable, Hashable, Identifiable {
    /// The pull request's GraphQL node id.
    public let prID: String
    /// The blended score the ordering uses.
    public let score: Double
    /// The lexical half, normalised to `0...1` across the candidate set.
    public let lexicalScore: Double
    /// The cosine similarity, when both the query and the document were embedded.
    public let similarity: Double?
    /// Whether the query named this pull request outright.
    public let isExactReference: Bool
    /// Why it came up.
    public let reason: SearchMatchReason?

    /// `SearchResult` shares the pull request's identity.
    public var id: String { prID }

    /// Creates a result.
    public init(
        prID: String,
        score: Double,
        lexicalScore: Double,
        similarity: Double?,
        isExactReference: Bool,
        reason: SearchMatchReason?
    ) {
        self.prID = prID
        self.score = score
        self.lexicalScore = lexicalScore
        self.similarity = similarity
        self.isExactReference = isExactReference
        self.reason = reason
    }
}

/// How the two halves of the score are combined (ADR 0019).
public struct SearchRankingOptions: Sendable, Hashable {
    /// How many results to return.
    public var limit: Int
    /// The weight of the normalised lexical score.
    public var lexicalWeight: Double
    /// The weight of the clamped cosine similarity.
    public var semanticWeight: Double
    /// How similar a document with **no** literal match has to be to appear at all.
    ///
    /// The one guard against the failure mode that makes semantic search feel broken: a cosine
    /// exists for every document in the corpus, so without a floor the palette would answer every
    /// query with the six least-unrelated pull requests in the inbox. With it, a query that
    /// matches nothing shows nothing, which is the honest answer.
    public var minimumSimilarity: Double

    /// Creates a set of options.
    /// - Parameters:
    ///   - limit: Result count.
    ///   - lexicalWeight: Weight of the lexical half.
    ///   - semanticWeight: Weight of the semantic half.
    ///   - minimumSimilarity: Floor for a purely semantic hit.
    public init(
        limit: Int = 6,
        lexicalWeight: Double = 0.5,
        semanticWeight: Double = 0.5,
        minimumSimilarity: Double = 0.35
    ) {
        self.limit = limit
        self.lexicalWeight = lexicalWeight
        self.semanticWeight = semanticWeight
        self.minimumSimilarity = minimumSimilarity
    }

    /// The options the palette ranks with.
    public static let standard = SearchRankingOptions()
}

/// Ranks pull requests against a query — the whole of ⌘K search's judgement, as a pure function
/// (ADR 0019).
///
/// Three properties are load-bearing and are what the unit tests pin:
///
/// - **It works without embeddings.** `vectors` empty (or a query the embedder could not answer)
///   leaves a deterministic BM25-shaped lexical ranking, which is the ranking a Mac without the
///   on-device model gets — permanently, and without a degraded mode anywhere else in the app.
/// - **An exact reference always wins.** `schnaq/review#128` and `#128` put that pull request
///   first regardless of every score, because it is not a ranking question.
/// - **The order is total.** Score descending, then node id ascending. Two sweeps of the same data
///   can never reshuffle the palette, which is the same promise `InboxModel.priorityScore` makes
///   about the list (`docs/ARCHITECTURE.md`).
public enum SearchRanker {
    /// BM25's term-frequency saturation. The standard 1.2: one more mention of a word the
    /// document already uses adds progressively less.
    static let k1 = 1.2
    /// BM25's length normalisation. The standard 0.75, which matters here more than usual: a
    /// document with a 3 KB diff excerpt would otherwise beat a one-line title match on churn
    /// alone.
    static let b = 0.75

    /// Ranks documents against a query.
    /// - Parameters:
    ///   - query: The parsed query. An empty one ranks nothing.
    ///   - documents: The corpus — one document per pull request in the local inbox. Order is
    ///     irrelevant; the result's order is total.
    ///   - vectors: The query's own embedding plus one per document, or `nil` for "no embeddings
    ///     are available", which is what a lexical-only Mac passes.
    ///   - options: Weights, floor and limit.
    /// - Returns: The best matches, best first, at most `options.limit` of them.
    public static func rank(
        query: SearchQuery,
        documents: [SearchDocument],
        vectors: SearchVectors? = nil,
        options: SearchRankingOptions = .standard
    ) -> [SearchResult] {
        guard !query.isEmpty, !documents.isEmpty else { return [] }

        // Document frequency over the *candidate* set, which is the whole local inbox. A corpus
        // this small has no room for a global IDF table and needs none: the inbox is the corpus.
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for token in query.distinctTokens where document.terms[token] != nil {
                documentFrequency[token, default: 0] += 1
            }
        }
        let count = Double(documents.count)
        let averageLength = documents.reduce(0.0) { $0 + $1.length } / count

        var raw: [(document: SearchDocument, lexical: Double, similarity: Double?)] = []
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
                    similarity: vectors?.similarity(forDocument: document.prID)
                )
            )
        }

        var results: [SearchResult] = []
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
                SearchResult(
                    prID: entry.document.prID,
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
            return left.prID < right.prID
        }
        return Array(results.prefix(max(0, options.limit)))
    }

    /// Picks the one thing worth telling the user about the match.
    ///
    /// A fixed order, so the line never depends on dictionary iteration: the reference, then the
    /// most specific *invisible* field the query hit (label, path, diff line, branch, author),
    /// then the description, then "the embedding did it". The first matching query token wins
    /// within a field, so a two-word query reports the word that is actually in the label rather
    /// than whichever one hashes first.
    private static func reason(
        for document: SearchDocument,
        query: SearchQuery,
        isExact: Bool,
        hasLiteralMatch: Bool
    ) -> SearchMatchReason? {
        if isExact { return .exactReference }
        guard hasLiteralMatch else { return .semantic }
        for token in query.distinctTokens {
            guard let fields = document.fieldsByTerm[token] else { continue }
            if fields.contains(.labels),
               let label = document.labels.first(where: { contains(token, in: $0) }) {
                return .label(label)
            }
            if fields.contains(.paths),
               let path = document.filePaths.first(where: { contains(token, in: $0) }) {
                return .filePath(path)
            }
            if fields.contains(.added),
               let line = document.addedLines.first(where: { contains(token, in: $0) }) {
                return .addedLine(line)
            }
            if fields.contains(.branch) { return .branch(document.headRefName) }
            if fields.contains(.author) {
                return .author(document.agentDisplayName ?? document.authorLogin)
            }
        }
        for token in query.distinctTokens {
            if document.fieldsByTerm[token]?.contains(.body) == true { return .body }
        }
        return nil
    }

    /// Whether a token is one of a value's own tokens.
    ///
    /// Token-level rather than `contains`: a substring test would report `Sources/Auth.swift` as
    /// the match for a query of `our`.
    private static func contains(_ token: String, in value: String) -> Bool {
        SearchText.tokens(in: value).contains(token)
    }
}

/// The embeddings a ranking run has to work with.
///
/// A type rather than two parameters because the distinction the ranker needs is not "are there
/// document vectors" but "can this query be compared at all": a query the embedder could not turn
/// into a vector has to fall back to the lexical half even when every document is embedded, and
/// vice versa. Bundling the query vector with the document vectors makes that one `nil` check.
public struct SearchVectors: Sendable, Hashable {
    /// The query's own embedding.
    public let query: SearchVector
    /// One embedding per pull-request node id. Missing entries are normal — a document indexed
    /// while the model was unavailable has none, and it is ranked lexically.
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
    /// - Parameter prID: The pull request's node id.
    public func similarity(forDocument prID: String) -> Double? {
        guard let vector = documents[prID] else { return nil }
        return query.cosineSimilarity(to: vector)
    }
}
