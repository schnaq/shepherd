import Foundation

/// How many bytes of an issue may enter its search document (ADR 0032).
///
/// One number, where ``SearchDocumentBudget`` has four: an issue has no diff, no changed paths
/// and no branch, so the body is the only part of it without an upper bound. The ceiling exists
/// for ADR 0019's reason — the in-memory corpus must grow with the *number* of rows and not with
/// the largest issue in the inbox, and a lexical ranker whose term counts are dominated by one
/// twelve-page bug report is a ranker with a favourite.
public struct IssueSearchDocumentBudget: Sendable, Hashable {
    /// How many bytes of the issue body are indexed.
    public var bodyBytes: Int

    /// Creates a budget.
    /// - Parameter bodyBytes: Body bytes.
    public init(bodyBytes: Int = 2_000) {
        self.bodyBytes = bodyBytes
    }

    /// The budget the app indexes with.
    public static let standard = IssueSearchDocumentBudget()
}

/// Everything the local database holds about one issue that is worth searching (ADR 0032).
///
/// ``SearchIndexSource``'s twin, minus the two collections an issue does not have. The split is
/// the same one ADR 0019 makes: the *reading* is `ShepherdPersistence`'s (one query), the
/// *deciding* is here, where it can be unit-tested on Linux without a database — and nothing in
/// this type comes from GitHub at search time, which is the rule that keeps typing in the palette
/// from producing a request.
public struct IssueSearchIndexSource: Sendable, Hashable {
    /// The inbox row — title, labels, repository, number, state.
    public var summary: IssueRowSummary
    /// The issue body, or `""` when no detail has been fetched yet.
    public var bodyMarkdown: String
    /// When the detail fetch that produced ``bodyMarkdown`` ran, if it ever did.
    ///
    /// The cheap half of the staleness question, exactly as it is for a pull request: an issue
    /// whose detail has not been re-fetched cannot have new body text, whatever else changed.
    public var detailFetchedAt: Date?

    /// Creates a source record.
    /// - Parameters:
    ///   - summary: The inbox row.
    ///   - bodyMarkdown: The body, or empty.
    ///   - detailFetchedAt: When the detail was fetched.
    public init(
        summary: IssueRowSummary,
        bodyMarkdown: String = "",
        detailFetchedAt: Date? = nil
    ) {
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
        self.detailFetchedAt = detailFetchedAt
    }
}

/// One issue, as ⌘K search sees it (ADR 0032).
///
/// A **sibling** of ``SearchDocument`` rather than a generalisation of it, and that is the
/// decision this type exists to record. ADR 0019 pins `SearchDocument` by name and by field list;
/// widening it to carry issue-shaped rows would mean either eight fields of which three are
/// permanently `nil` for one of the two kinds, or a protocol earning its abstraction over two
/// call sites that will keep diverging — an issue gains no diff, ever. The codebase already
/// answers "alike but not the same thing" this way (`ClosedPullRequestReading` beside
/// `PullRequestFetching`, `OutcomeCapture` beside `SyncStoring`).
///
/// It has the same three jobs its twin has: it is what an embedder reads
/// (``embeddingText``), what the lexical ranker scores (``terms``, ``length``, pre-computed
/// because search runs on every keystroke), and what decides whether an embedding has to be spent
/// again (``documentHash``) or the source re-read at all (``sourceFingerprint``).
public struct IssueSearchDocument: Sendable, Hashable, Identifiable {
    /// Which fields the document is composed of, and how heavily each one counts.
    ///
    /// Four, against the pull request's eight, and the weights of those four are its weights
    /// unchanged: a title and a label are written to be read, a body is prose somebody typed
    /// once. There is no `author` field — the pull-request document has one because a reviewer
    /// looks for "the agent's pull requests", while the issues rail answers that with a
    /// provenance facet and an issue's author is almost always a person on the team.
    public enum Field: String, Sendable, Hashable, CaseIterable {
        /// The issue title.
        case title
        /// `owner/name`, the number, and the `owner/name#number` slug.
        case identity
        /// Label names.
        case labels
        /// The issue body, capped.
        case body

        /// How much a term found in this field counts.
        public var weight: Double {
            switch self {
            case .title: return 3
            case .identity: return 3
            case .labels: return 2.5
            case .body: return 1
            }
        }
    }

    /// The version of the composition rules.
    ///
    /// Part of both hashes, so changing what goes into a document invalidates every stored vector
    /// by construction instead of leaving an index that was built by two different Shepherds.
    /// Numbered independently of ``SearchDocument/schemaVersion``: the two documents are never
    /// compared with each other, and one shared number would mean a change to the pull-request
    /// document re-embedding every issue.
    public static let schemaVersion = 1

    /// The issue's GraphQL node id.
    public let issueID: String
    /// `owner/name#number`.
    public let slug: String
    /// `owner/name`.
    public let repoFullName: String
    /// The issue number.
    public let number: Int
    /// The title, verbatim.
    public let title: String
    /// Label names, as GitHub returned them.
    public let labels: [String]
    /// The body, capped to the budget.
    public let bodyExcerpt: String
    /// Whether a detail fetch has ever filled in the body.
    ///
    /// Not a degraded state: an issue nobody has opened is indexed on its title, labels and
    /// identity, and that is everything Shepherd knows about it.
    public let hasDetail: Bool

    /// Weighted term frequencies, keyed by token.
    public let terms: [String: Double]
    /// The sum of every weighted term frequency — the document length BM25 normalises against.
    public let length: Double
    /// Which fields each token was found in, for the "why it matched" line.
    public let fieldsByTerm: [String: Set<Field>]

    /// A hash of everything an embedder will see — the re-embed gate.
    public let documentHash: String
    /// A hash of the cheap half: identity, title, labels, state, `updatedAt`, and when the detail
    /// was last fetched. The re-*read* gate, one level before ``documentHash``.
    public let sourceFingerprint: String

    /// `IssueSearchDocument` shares the issue's identity.
    public var id: String { issueID }

    /// The one string an embedder sees.
    ///
    /// A fixed field order with plain `Field: value` lines, for ``SearchDocument``'s reason: the
    /// embedding is a function of the text, so two documents that differ only in dictionary
    /// iteration order must not produce two different vectors.
    public var embeddingText: String {
        var lines: [String] = [title]
        lines.append("Repository: \(repoFullName) #\(number)")
        if !labels.isEmpty { lines.append("Labels: \(labels.joined(separator: ", "))") }
        if !bodyExcerpt.isEmpty { lines.append(bodyExcerpt) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Building

    /// Composes the document for one issue.
    /// - Parameters:
    ///   - source: What the database holds.
    ///   - budget: The byte ceiling on the body.
    /// - Returns: The document.
    public static func make(
        source: IssueSearchIndexSource,
        budget: IssueSearchDocumentBudget = .standard
    ) -> IssueSearchDocument {
        let summary = source.summary
        let bodyExcerpt = SearchText.clamped(
            source.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines),
            toBytes: budget.bodyBytes
        )

        // An explicit list of `(field, values)` pairs rather than one expression, for
        // ``SearchDocument/make(source:budget:)``'s reason: the weighting loop needs the field
        // beside its text, and a mixed array literal is what makes the type-checker slow.
        var fields: [(field: Field, values: [String])] = []
        fields.append((.title, [summary.title]))
        fields.append((
            .identity,
            [summary.repo.owner, summary.repo.name, "\(summary.number)", summary.slug]
        ))
        fields.append((.labels, summary.labels))
        fields.append((.body, [bodyExcerpt]))

        var terms: [String: Double] = [:]
        var fieldsByTerm: [String: Set<Field>] = [:]
        var length: Double = 0
        for (field, values) in fields {
            let weight = field.weight
            for value in values {
                for token in SearchText.tokens(in: value) {
                    terms[token, default: 0] += weight
                    fieldsByTerm[token, default: []].insert(field)
                    length += weight
                }
            }
        }

        let document = IssueSearchDocument(
            issueID: summary.id,
            slug: summary.slug,
            repoFullName: summary.repo.fullName,
            number: summary.number,
            title: summary.title,
            labels: summary.labels,
            bodyExcerpt: bodyExcerpt,
            hasDetail: source.detailFetchedAt != nil,
            terms: terms,
            length: length,
            fieldsByTerm: fieldsByTerm,
            documentHash: "",
            sourceFingerprint: fingerprint(for: source)
        )
        // Two passes rather than one: the hash is over `embeddingText`, which is a property of
        // the composed value, so hashing inside the composition would be the same work twice.
        return document.withDocumentHash(
            SearchContentHash.hex([
                "v\(schemaVersion)",
                document.embeddingText,
            ])
        )
    }

    /// The cheap staleness key: what can change without the body being re-fetched.
    ///
    /// `detailFetchedAt` is in it, which is what makes the gate correct rather than merely cheap:
    /// opening an issue stores its body and moves that timestamp, so the very next pass reads the
    /// source again and the document grows from "title and labels" to the whole report. `state`
    /// is in it because closing an issue is the one change that does not have to move
    /// `updatedAt`.
    /// - Parameter source: What the database holds.
    /// - Returns: A hex hash.
    public static func fingerprint(for source: IssueSearchIndexSource) -> String {
        let summary = source.summary
        return SearchContentHash.hex([
            "v\(schemaVersion)",
            summary.id,
            summary.repo.fullName,
            "\(summary.number)",
            summary.title,
            summary.labels.joined(separator: "\u{1}"),
            summary.state.rawValue,
            "\(summary.updatedAt.timeIntervalSince1970)",
            source.detailFetchedAt.map { "\($0.timeIntervalSince1970)" } ?? "",
        ])
    }

    /// Creates a document. Public so that a test can build one directly; the app uses
    /// ``make(source:budget:)``.
    public init(
        issueID: String,
        slug: String,
        repoFullName: String,
        number: Int,
        title: String,
        labels: [String],
        bodyExcerpt: String,
        hasDetail: Bool,
        terms: [String: Double],
        length: Double,
        fieldsByTerm: [String: Set<Field>],
        documentHash: String,
        sourceFingerprint: String
    ) {
        self.issueID = issueID
        self.slug = slug
        self.repoFullName = repoFullName
        self.number = number
        self.title = title
        self.labels = labels
        self.bodyExcerpt = bodyExcerpt
        self.hasDetail = hasDetail
        self.terms = terms
        self.length = length
        self.fieldsByTerm = fieldsByTerm
        self.documentHash = documentHash
        self.sourceFingerprint = sourceFingerprint
    }

    private func withDocumentHash(_ hash: String) -> IssueSearchDocument {
        IssueSearchDocument(
            issueID: issueID,
            slug: slug,
            repoFullName: repoFullName,
            number: number,
            title: title,
            labels: labels,
            bodyExcerpt: bodyExcerpt,
            hasDetail: hasDetail,
            terms: terms,
            length: length,
            fieldsByTerm: fieldsByTerm,
            documentHash: hash,
            sourceFingerprint: sourceFingerprint
        )
    }
}

/// One row of the local issue search index: a document hash, its vector, and what produced it
/// (ADR 0032).
///
/// ``SearchIndexEntry``'s twin, keyed by the issue's node id. A `ShepherdCore` value even though
/// only `ShepherdPersistence` stores it, for that type's reason: the table is a place to put the
/// value, not the definition of it, and the coordinator in the app target compares entries without
/// importing GRDB.
public struct IssueSearchIndexEntry: Sendable, Hashable, Identifiable {
    /// The issue's GraphQL node id.
    public var issueID: String
    /// ``IssueSearchDocument/documentHash`` at the time the vector was made — the re-embed gate.
    ///
    /// The only staleness key that is persisted; ``IssueSearchDocument/sourceFingerprint``
    /// deliberately is not, because it guards an in-memory corpus that is rebuilt at launch
    /// anyway.
    public var documentHash: String
    /// Which embedding model produced ``vector``.
    ///
    /// Stored beside the vector rather than assumed: vectors from two models are not comparable,
    /// so a macOS update that changes the sentence embedding must invalidate the index instead of
    /// silently ranking against a mixture.
    public var modelIdentifier: String
    /// The document's embedding, or `nil` when the document was indexed lexically only.
    ///
    /// `nil` is a normal state: it is what a Mac without the embedding model has for every row,
    /// and the palette still ranks those documents with the lexical half.
    public var vector: SearchVector?
    /// When this row was written.
    public var indexedAt: Date

    /// `IssueSearchIndexEntry` shares the issue's identity.
    public var id: String { issueID }

    /// Creates an entry.
    /// - Parameters:
    ///   - issueID: The issue's node id.
    ///   - documentHash: The document hash the vector belongs to.
    ///   - modelIdentifier: What produced the vector.
    ///   - vector: The embedding, if there is one.
    ///   - indexedAt: When the row was written.
    public init(
        issueID: String,
        documentHash: String,
        modelIdentifier: String,
        vector: SearchVector?,
        indexedAt: Date
    ) {
        self.issueID = issueID
        self.documentHash = documentHash
        self.modelIdentifier = modelIdentifier
        self.vector = vector
        self.indexedAt = indexedAt
    }

    /// Whether this entry's vector can be reused for a freshly composed document.
    ///
    /// Both halves have to match: the same text *and* the same model. Either one differing means
    /// the stored vector describes something else.
    /// - Parameters:
    ///   - document: The freshly composed document.
    ///   - modelIdentifier: The model that would embed it now.
    public func isUsable(for document: IssueSearchDocument, modelIdentifier: String) -> Bool {
        vector != nil
            && self.documentHash == document.documentHash
            && self.modelIdentifier == modelIdentifier
    }
}
