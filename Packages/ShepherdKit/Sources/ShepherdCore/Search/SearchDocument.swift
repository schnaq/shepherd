import Foundation

/// How many bytes of each part of a pull request may enter its search document (ADR 0019).
///
/// The budget exists because the index is built from whatever the sweep and the review screen
/// already stored, and *that* has no upper bound: one generated client can carry a megabyte of
/// diff. Three things would go wrong without an explicit ceiling — the in-memory corpus would
/// grow with the largest pull request in the inbox rather than with their number, an embedding
/// would be spent on a hundred chunks of vendored JSON, and the lexical ranker's term counts
/// would be dominated by whichever pull request happens to be the biggest.
///
/// The numbers are deliberately small and deliberately *explicit*: a search document is a
/// description of a change, not a copy of it. Roughly 6 KB of text per pull request means a
/// four-hundred-row inbox costs a couple of megabytes of corpus, which is the size of one
/// screenshot.
public struct SearchDocumentBudget: Sendable, Hashable {
    /// How many bytes of the pull-request description are indexed.
    public var bodyBytes: Int
    /// How many bytes of changed-file paths are indexed, in priority order (the sweep's order).
    public var filePathBytes: Int
    /// How many bytes of added diff lines are indexed.
    public var addedLineBytes: Int
    /// How long a single added line may be before it is cut.
    ///
    /// A minified bundle is one "line" of 200 KB. Cutting per line as well as per document keeps
    /// one such line from consuming the whole diff budget on its own.
    public var maximumAddedLineLength: Int

    /// Creates a budget.
    /// - Parameters:
    ///   - bodyBytes: Description bytes.
    ///   - filePathBytes: File-path bytes.
    ///   - addedLineBytes: Added-diff-line bytes.
    ///   - maximumAddedLineLength: Per-line cut.
    public init(
        bodyBytes: Int = 2_000,
        filePathBytes: Int = 1_000,
        addedLineBytes: Int = 3_000,
        maximumAddedLineLength: Int = 200
    ) {
        self.bodyBytes = bodyBytes
        self.filePathBytes = filePathBytes
        self.addedLineBytes = addedLineBytes
        self.maximumAddedLineLength = maximumAddedLineLength
    }

    /// The budget the app indexes with.
    public static let standard = SearchDocumentBudget()
}

/// Everything the local database holds about one pull request that is worth searching.
///
/// The raw material, not the document: ``SearchDocument/make(source:budget:)`` does the
/// composition. Split that way because the two halves belong to different modules — the *reading*
/// is `ShepherdPersistence`'s (one query for the rows, one for the changed files), the *deciding*
/// is here, where it can be unit-tested on Linux without a database.
///
/// Nothing in this type comes from GitHub at search time. That is ADR 0019's hard rule: the index
/// is built from what the sweep and the review screen already stored, so typing in the palette
/// can never produce a network request.
public struct SearchIndexSource: Sendable, Hashable {
    /// The inbox row — title, author, labels, branch, repository, number.
    public var summary: PullRequestSummary
    /// The pull-request description, or `""` when no detail has been fetched yet.
    public var bodyMarkdown: String
    /// The changed files, in the order the detail fetch stored them. Empty until a detail fetch
    /// happened; `patch` is `nil` for binary and truncated files.
    public var files: [ChangedFile]
    /// When the detail fetch that produced ``bodyMarkdown`` and ``files`` ran, if it ever did.
    ///
    /// Part of the source rather than derived from it because it is the cheap half of the
    /// staleness question: a pull request whose detail has not been re-fetched cannot have new
    /// diff text, whatever else changed about it.
    public var detailFetchedAt: Date?

    /// Creates a source record.
    /// - Parameters:
    ///   - summary: The inbox row.
    ///   - bodyMarkdown: The description, or empty.
    ///   - files: The changed files, or empty.
    ///   - detailFetchedAt: When the detail was fetched.
    public init(
        summary: PullRequestSummary,
        bodyMarkdown: String = "",
        files: [ChangedFile] = [],
        detailFetchedAt: Date? = nil
    ) {
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
        self.files = files
        self.detailFetchedAt = detailFetchedAt
    }
}

/// One pull request, as ⌘K search sees it (ADR 0019).
///
/// A value with three jobs, which is why it carries both text and pre-computed counts:
///
/// 1. It is what the **embedder** reads (``embeddingText``) — one string, in a fixed field order,
///    so the same pull request always produces the same vector.
/// 2. It is what the **lexical ranker** scores, and it carries its own weighted term counts
///    (``terms``, ``length``) rather than being re-tokenised on every keystroke. Search runs on
///    every character typed over the whole inbox; tokenising a couple of megabytes per keystroke
///    is exactly the cost this avoids.
/// 3. It is what decides whether an embedding has to be **spent again** (``documentHash``), and
///    whether the source has to be read out of SQLite again at all (``sourceFingerprint``).
///
/// The hashes are FNV-1a rather than `Hasher`: `Hasher` is seeded per process, so a stored hash
/// would differ after every relaunch and the index would re-embed the whole inbox every time the
/// app started.
public struct SearchDocument: Sendable, Hashable, Identifiable {
    /// Which fields the document is composed of, and how heavily each one counts.
    ///
    /// A cheap stand-in for BM25F: the weights below are applied to the term *frequency* of the
    /// field a term was found in, so "a word in the title" outranks "a word somewhere in a diff"
    /// without the ranker needing to know that fields exist. They are ordered by how deliberately
    /// a human chose the words in them — a title and a label are written to be read, a diff line
    /// is not.
    public enum Field: String, Sendable, Hashable, CaseIterable {
        /// The pull-request title.
        case title
        /// `owner/name`, the number, and the `owner/name#number` slug.
        case identity
        /// Label names.
        case labels
        /// The author's login and, for an agent, its display name (ADR 0008).
        case author
        /// The head branch name.
        case branch
        /// The pull-request description, capped.
        case body
        /// Changed-file paths, capped.
        case paths
        /// Added lines of the unified diff, capped.
        case added

        /// How much a term found in this field counts.
        public var weight: Double {
            switch self {
            case .title: return 3
            case .identity: return 3
            case .labels: return 2.5
            case .author: return 2
            case .branch: return 2
            case .body: return 1
            case .paths: return 1.5
            case .added: return 0.6
            }
        }
    }

    /// The version of the composition rules.
    ///
    /// Part of both hashes, so changing what goes into a document — a new field, a different
    /// budget, a different tokeniser — invalidates every stored vector by construction instead of
    /// leaving an index that was built by two different Shepherds.
    public static let schemaVersion = 1

    /// The pull request's GraphQL node id.
    public let prID: String
    /// `owner/name#number`.
    public let slug: String
    /// `owner/name`.
    public let repoFullName: String
    /// The pull-request number.
    public let number: Int
    /// The title, verbatim.
    public let title: String
    /// The author's login.
    public let authorLogin: String
    /// The detected agent's display name, when an agent wrote it (ADR 0008).
    public let agentDisplayName: String?
    /// Label names, as GitHub returned them.
    public let labels: [String]
    /// The head branch name.
    public let headRefName: String
    /// The description, capped to the budget.
    public let bodyExcerpt: String
    /// Changed-file paths, capped to the budget.
    public let filePaths: [String]
    /// Added diff lines, capped to the budget.
    public let addedLines: [String]
    /// Whether a detail fetch has ever filled in the body, the paths and the diff.
    ///
    /// Kept so the settings card and the ADR's promise can be checked: a pull request nobody has
    /// opened is indexed on its title, labels, branch and author alone, and that is not a
    /// degraded state — it is everything Shepherd knows about it.
    public let hasDetail: Bool

    /// Weighted term frequencies, keyed by token.
    public let terms: [String: Double]
    /// The sum of every weighted term frequency — the document length BM25 normalises against.
    public let length: Double
    /// Which fields each token was found in, for the "why it matched" line.
    public let fieldsByTerm: [String: Set<Field>]

    /// A hash of everything the embedder will see.
    ///
    /// The re-embed gate: a document whose hash equals the stored one keeps its stored vector,
    /// however many sweeps have run in between.
    public let documentHash: String
    /// A hash of the *cheap* half — title, identity, author, labels, branch, head commit,
    /// `updatedAt`, and when the detail was last fetched.
    ///
    /// The re-*read* gate, one level before ``documentHash``. Without it every inbox write would
    /// mean reading every stored diff back out of SQLite just to discover that nothing changed,
    /// and the inbox is written every two minutes. With it, a pass over an unchanged inbox reads
    /// one small column and stops.
    public let sourceFingerprint: String

    /// `SearchDocument` shares the pull request's identity.
    public var id: String { prID }

    /// The one string the embedder sees.
    ///
    /// A fixed field order with plain `Field: value` lines, because the sentence embedding is a
    /// function of the text: two documents that differ only in dictionary iteration order must
    /// not produce two different vectors.
    public var embeddingText: String {
        var lines: [String] = ["\(title)"]
        lines.append("Repository: \(repoFullName) #\(number)")
        if let agentDisplayName {
            lines.append("Author: \(authorLogin) (\(agentDisplayName))")
        } else {
            lines.append("Author: \(authorLogin)")
        }
        if !labels.isEmpty { lines.append("Labels: \(labels.joined(separator: ", "))") }
        lines.append("Branch: \(headRefName)")
        if !bodyExcerpt.isEmpty { lines.append(bodyExcerpt) }
        if !filePaths.isEmpty { lines.append("Files: \(filePaths.joined(separator: ", "))") }
        if !addedLines.isEmpty { lines.append(addedLines.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Building

    /// Composes the document for one pull request.
    ///
    /// Every cap is applied here rather than by the caller, so "what is indexed" has exactly one
    /// answer and the ADR can state it. The order of the capped lists is the order the sweep and
    /// the detail fetch stored them in — GitHub's own — because it is stable across fetches; an
    /// order derived from, say, churn would reshuffle the tail of the diff budget on every push
    /// and cost an embedding for no change in meaning.
    /// - Parameters:
    ///   - source: What the database holds.
    ///   - budget: The byte ceilings.
    /// - Returns: The document.
    public static func make(
        source: SearchIndexSource,
        budget: SearchDocumentBudget = .standard
    ) -> SearchDocument {
        let summary = source.summary
        let bodyExcerpt = SearchText.clamped(
            source.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines),
            toBytes: budget.bodyBytes
        )
        let paths = SearchText.clampedList(
            source.files.map(\.path),
            toBytes: budget.filePathBytes,
            maximumEntryLength: nil
        )
        let added = SearchText.clampedList(
            source.files.flatMap { addedLines(inPatch: $0.patch) },
            toBytes: budget.addedLineBytes,
            maximumEntryLength: budget.maximumAddedLineLength
        )
        let agentDisplayName = summary.author.kind.agentIdentity?.displayName

        // Built as an explicit list of `(field, values)` pairs rather than as one expression: the
        // weighting loop below needs the field beside its text, and an array literal mixing
        // `String` and `String?` is the kind of thing that costs the type-checker minutes.
        var authorValues = [summary.author.login]
        if let agentDisplayName { authorValues.append(agentDisplayName) }
        var fields: [(field: Field, values: [String])] = []
        fields.append((.title, [summary.title]))
        fields.append((
            .identity,
            [summary.repo.owner, summary.repo.name, "\(summary.number)", summary.slug]
        ))
        fields.append((.labels, summary.labels))
        fields.append((.author, authorValues))
        fields.append((.branch, [summary.headRefName]))
        fields.append((.body, [bodyExcerpt]))
        fields.append((.paths, paths))
        fields.append((.added, added))

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

        let document = SearchDocument(
            prID: summary.id,
            slug: summary.slug,
            repoFullName: summary.repo.fullName,
            number: summary.number,
            title: summary.title,
            authorLogin: summary.author.login,
            agentDisplayName: agentDisplayName,
            labels: summary.labels,
            headRefName: summary.headRefName,
            bodyExcerpt: bodyExcerpt,
            filePaths: paths,
            addedLines: added,
            hasDetail: source.detailFetchedAt != nil,
            terms: terms,
            length: length,
            fieldsByTerm: fieldsByTerm,
            documentHash: "",
            sourceFingerprint: fingerprint(for: source)
        )
        // Two passes rather than one: the hash is over `embeddingText`, which is a property of the
        // composed value. Recomputing the composition inside a hash function would be the same
        // work written twice.
        return document.withDocumentHash(
            SearchContentHash.hex([
                "v\(schemaVersion)",
                document.embeddingText,
            ])
        )
    }

    /// The cheap staleness key: what can change without any diff being re-fetched.
    ///
    /// `detailFetchedAt` is in it, which is what makes the gate correct rather than merely cheap:
    /// opening a pull request stores its body and its diff and moves that timestamp, so the very
    /// next pass reads the source again and the document grows from "title and labels" to the
    /// full change. Nothing has to notify anything.
    /// - Parameter source: What the database holds.
    /// - Returns: A hex hash.
    public static func fingerprint(for source: SearchIndexSource) -> String {
        let summary = source.summary
        return SearchContentHash.hex([
            "v\(schemaVersion)",
            summary.id,
            summary.repo.fullName,
            "\(summary.number)",
            summary.title,
            summary.author.login,
            summary.author.kind.agentIdentity?.displayName ?? "",
            summary.labels.joined(separator: "\u{1}"),
            summary.headRefName,
            summary.headRefOid,
            "\(summary.updatedAt.timeIntervalSince1970)",
            source.detailFetchedAt.map { "\($0.timeIntervalSince1970)" } ?? "",
        ])
    }

    /// The added lines of one unified-diff patch, trimmed and without the diff marker.
    ///
    /// Added lines only, and that is a decision: the question ⌘K answers is "which pull request
    /// is about X", and what a change is *about* is what it introduces. Removed lines describe
    /// the state the repository is leaving, and indexing them makes a deletion of `login` rank as
    /// highly for "login" as an addition of it. Hunk headers (`@@`), file markers (`+++`) and
    /// context lines carry no new words at all.
    /// - Parameter patch: The unified diff, or `nil` for a binary or truncated file.
    /// - Returns: The added lines, in patch order, without empty ones.
    public static func addedLines(inPatch patch: String?) -> [String] {
        guard let patch, !patch.isEmpty else { return [] }
        var result: [String] = []
        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            guard rawLine.first == "+" else { continue }
            if rawLine.hasPrefix("+++") { continue }
            let text = rawLine.dropFirst().trimmingCharacters(in: .whitespaces)
            // Two characters of punctuation — a lone `}` or `);` — is the most common added line
            // in any diff and contains no searchable word.
            guard text.count > 2 else { continue }
            result.append(text)
        }
        return result
    }

    /// Creates a document. Public so that a test can build one directly; the app uses
    /// ``make(source:budget:)``.
    public init(
        prID: String,
        slug: String,
        repoFullName: String,
        number: Int,
        title: String,
        authorLogin: String,
        agentDisplayName: String?,
        labels: [String],
        headRefName: String,
        bodyExcerpt: String,
        filePaths: [String],
        addedLines: [String],
        hasDetail: Bool,
        terms: [String: Double],
        length: Double,
        fieldsByTerm: [String: Set<Field>],
        documentHash: String,
        sourceFingerprint: String
    ) {
        self.prID = prID
        self.slug = slug
        self.repoFullName = repoFullName
        self.number = number
        self.title = title
        self.authorLogin = authorLogin
        self.agentDisplayName = agentDisplayName
        self.labels = labels
        self.headRefName = headRefName
        self.bodyExcerpt = bodyExcerpt
        self.filePaths = filePaths
        self.addedLines = addedLines
        self.hasDetail = hasDetail
        self.terms = terms
        self.length = length
        self.fieldsByTerm = fieldsByTerm
        self.documentHash = documentHash
        self.sourceFingerprint = sourceFingerprint
    }

    private func withDocumentHash(_ hash: String) -> SearchDocument {
        SearchDocument(
            prID: prID,
            slug: slug,
            repoFullName: repoFullName,
            number: number,
            title: title,
            authorLogin: authorLogin,
            agentDisplayName: agentDisplayName,
            labels: labels,
            headRefName: headRefName,
            bodyExcerpt: bodyExcerpt,
            filePaths: filePaths,
            addedLines: addedLines,
            hasDetail: hasDetail,
            terms: terms,
            length: length,
            fieldsByTerm: fieldsByTerm,
            documentHash: hash,
            sourceFingerprint: sourceFingerprint
        )
    }
}

// MARK: - Text handling

/// Tokenising, clamping and the one hash the search index persists.
///
/// Deliberately tiny and deliberately not `NaturalLanguage`: the tokeniser has to produce the
/// same tokens in `ShepherdCoreTests` on the Linux runner as it does in the app, so it may only
/// use Foundation (ADR 0019, and the module rule in `docs/ARCHITECTURE.md`).
public enum SearchText {
    /// Splits text into lower-cased search tokens.
    ///
    /// Runs of letters and digits, everything else a separator — which is what makes
    /// `Sources/Auth/token-store.swift`, `auth_token` and `AUTH-TOKEN` all yield `auth` and
    /// `token`. Camel case is deliberately *not* split, so `authToken` is the single token
    /// `authtoken`. Single characters are dropped (a query of `a` matching everything is noise);
    /// digits are kept whatever their length, because `#128` and `2026` are exactly the kind of
    /// thing a user types.
    /// - Parameter text: Any string.
    /// - Returns: The tokens, in order, with duplicates kept (frequency is the ranker's input).
    public static func tokens(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var currentIsDigits = true
        func flush() {
            if current.count > 1 || (currentIsDigits && !current.isEmpty) {
                tokens.append(current)
            }
            current = ""
            currentIsDigits = true
        }
        // Lower-cased once for the whole field rather than per character: `Character`'s own
        // lower-case mapping can be more than one character (`İ`), which is not something a
        // character-by-character loop can append without losing it.
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                // Camel-case is *not* split: `TokenStore` yields `tokenstore`, and the path and
                // branch fields carry the separated spellings anyway. Splitting it would double
                // every identifier in the corpus for a gain the path field already provides.
                current.append(character)
                if !character.isNumber { currentIsDigits = false }
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Cuts a string to a UTF-8 byte ceiling without splitting a character.
    /// - Parameters:
    ///   - text: The string.
    ///   - limit: The ceiling in bytes.
    /// - Returns: `text`, or its longest prefix that fits.
    public static func clamped(_ text: String, toBytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.utf8.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > limit { break }
            result.append(character)
            used += size
        }
        return result
    }

    /// Takes entries from a list until a byte ceiling is reached.
    ///
    /// Whole entries, never a partial one: half a file path is not a file path, and half an added
    /// line tokenises into a word that is not in the diff.
    /// - Parameters:
    ///   - entries: The candidates, in priority order.
    ///   - limit: The ceiling in bytes across all entries.
    ///   - maximumEntryLength: A per-entry character cut applied before the ceiling, or `nil`.
    /// - Returns: The entries that fit, in the given order.
    public static func clampedList(
        _ entries: [String],
        toBytes limit: Int,
        maximumEntryLength: Int?
    ) -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []
        var used = 0
        for entry in entries {
            var value = entry
            if let maximumEntryLength, value.count > maximumEntryLength {
                value = String(value.prefix(maximumEntryLength))
            }
            let size = value.utf8.count
            if used + size > limit { break }
            result.append(value)
            used += size
        }
        return result
    }
}

/// The 64-bit FNV-1a hash the search index stores.
///
/// Not `Hasher`, and the reason is the whole point of the type: `Hasher` is seeded per process, so
/// a hash written to SQLite today would not match the same document's hash after a relaunch and
/// every launch would re-embed the entire inbox. Not CryptoKit either — `Packages/ShepherdKit`
/// must build on Linux. FNV-1a is eight lines, has no dependencies, and is a *change detector*:
/// nothing here is a security boundary, so collision resistance is not the property being bought.
enum SearchContentHash {
    /// Hashes a list of fields.
    /// - Parameter fields: The fields, joined with a separator that cannot appear in them, so
    ///   `["ab", "c"]` and `["a", "bc"]` hash differently.
    /// - Returns: A lower-case hex string.
    static func hex(_ fields: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x100_0000_01b3
        for (index, field) in fields.enumerated() {
            if index > 0 {
                hash = (hash ^ 0x1f) &* prime
            }
            for byte in field.utf8 {
                hash = (hash ^ UInt64(byte)) &* prime
            }
        }
        return String(hash, radix: 16)
    }
}
