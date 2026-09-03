import Foundation
import Observation
import ShepherdCore
import ShepherdPersistence

/// One ranked pull request, ready for a palette row.
///
/// The summary is carried rather than looked up by the view: the palette is an overlay with no
/// database of its own, and a row that had to fetch its own title would flicker as the user types.
struct PullRequestSearchResult: Identifiable, Equatable, Sendable {
    /// The pull request, as the local inbox knows it.
    var summary: PullRequestSummary
    /// The blended score, kept so the row order is explainable in a test.
    var score: Double
    /// Why it matched, when there is something worth saying.
    var reason: SearchMatchReason?

    /// `PullRequestSearchResult` shares the pull request's identity.
    var id: String { summary.id }
}

/// One ranked issue, ready for a palette row (ADR 0032).
///
/// ``PullRequestSearchResult``'s twin, carrying its own summary for that type's reason: the
/// palette is an overlay with no database, and a row that fetched its own title would flicker as
/// the user types.
///
/// It is called *Match* rather than *Result* only because `ShepherdCore` already has an
/// `IssueSearchResult` — the ranker's output, which has no title on it. Two types with one name
/// for one feature would be worse than one name that differs.
struct IssueSearchMatch: Identifiable, Equatable, Sendable {
    /// The issue, as the local issues inbox knows it.
    var summary: IssueRowSummary
    /// The blended score, kept so the merge order is explainable in a test.
    var score: Double
    /// Why it matched, when there is something worth saying.
    var reason: IssueSearchMatchReason?

    /// `IssueSearchMatch` shares the issue's identity.
    var id: String { summary.id }
}

/// One row of the merge that produces ``PaletteSearchResults`` (ADR 0032).
///
/// A private sum type rather than two sorted lists interleaved by hand: the merge has to be a
/// *total* order over rows of two different types, and a comparison written twice is a comparison
/// that can disagree with itself.
private enum MergedSearchRow {
    case pullRequest(PullRequestSearchResult)
    case issue(IssueSearchMatch)

    /// The blended score the merge orders by.
    var score: Double {
        switch self {
        case .pullRequest(let value): return value.score
        case .issue(let value): return value.score
        }
    }

    /// The tie-break: pull requests first, then node id. Prefixed so the two id spaces cannot
    /// collide, and stable so two sweeps of the same data produce the same palette.
    var sortKey: String {
        switch self {
        case .pullRequest(let value): return "0-\(value.id)"
        case .issue(let value): return "1-\(value.id)"
        }
    }
}

/// The palette's whole answer to one query: the best rows of both kinds (ADR 0032).
///
/// The two corpora are ranked separately — they have different documents, different weights and
/// different reasons — and then **merged by score and sliced once**, which is the property ADR
/// 0019's "the keyboard does not notice" rule needs: the palette has room for a fixed number of
/// rows, and giving each kind its own quota would let a weak issue push out a strong pull request.
/// The caller groups them under two headers afterwards; the cursor walks one flat list either way.
struct PaletteSearchResults: Equatable, Sendable {
    /// The pull requests that survived the merge, best first.
    var pullRequests: [PullRequestSearchResult] = []
    /// The issues that survived the merge, best first.
    var issues: [IssueSearchMatch] = []

    /// Whether the query matched nothing at all.
    var isEmpty: Bool { pullRequests.isEmpty && issues.isEmpty }
}

/// What the Intelligence settings card says about the index.
struct SearchIndexStatus: Equatable, Sendable {
    /// Whether the user has the index switched on.
    var isEnabled = true
    /// Whether a pass is running right now.
    var isIndexing = false
    /// How many pull requests are in the searchable corpus.
    var documentCount = 0
    /// How many of those have an embedding.
    var embeddedCount = 0
    /// How many issues are in the second searchable corpus (ADR 0032).
    ///
    /// Counted apart from ``documentCount`` rather than added to it, because the card's sentence
    /// names the two kinds: "412 of 412 pull requests and 96 of 96 issues indexed" is a claim a
    /// reader can check, while one merged number would hide a corpus that never got built.
    var issueDocumentCount = 0
    /// How many issues have an embedding.
    var issueEmbeddedCount = 0
    /// How many bytes of vector are on disk.
    var vectorByteCount = 0
    /// When the newest index row was written.
    var lastIndexedAt: Date?
    /// Why the on-device model is not being used, when it is not.
    var embeddingUnavailabilityReason: String?
}

/// Keeps the local ⌘K search index current, and answers the palette's queries (ADR 0019).
///
/// The third coordinator of this shape — ``AutoMergeCoordinator`` and ``DigestCoordinator`` are
/// the others — and the division of labour is theirs: every decision is a pure value in
/// `ShepherdCore` (``ShepherdCore/SearchDocument``, ``ShepherdCore/SearchRanker``), and this type
/// supplies the inputs, spends the embeddings and holds the corpus.
///
/// Five things about *when* and *how* it runs are decisions rather than mechanics:
///
/// - **The trigger is the rows a sweep wrote**, through the same `onInboxRows` callback automatic
///   merging uses (ADR 0018). Indexing is about the content of the inbox, and the inbox
///   observation is the one place that reports a change to it — including the change nothing else
///   announces, a detail fetch storing a diff, which arrives as a moved `detailFetchedAt`.
/// - **Nothing here can reach GitHub.** There is no client, no URL and no fetch in this folder:
///   the index is composed from rows the sweep and the review screen already stored. Typing in
///   the palette therefore cannot produce a request, which is the promise ADR 0019 makes.
/// - **A pass is cheap when nothing changed.** The in-memory corpus carries each document's
///   ``ShepherdCore/SearchDocument/sourceFingerprint``, so a sweep that changed nothing reads one
///   small column and stops. Only rows whose fingerprint moved have their body and diff read back
///   out of SQLite, in batches, and only documents whose *text* changed cost an embedding.
/// - **It never blocks the UI.** The pass runs in a low-priority `Task`, the composition (which
///   tokenises and hashes) is handed to a detached task, and each batch yields. The palette
///   ranks whatever the corpus holds at that moment — a half-built index answers with the half
///   it has rather than with a spinner.
/// - **With the toggle off it still answers.** The corpus is then built from the inbox rows
///   alone — title, repository, number, labels, branch, author — with no database read, no
///   embedding and nothing written. Search keeps working on titles, which is what makes the
///   toggle a genuine "off" rather than a broken palette.
@MainActor
@Observable
final class SearchIndexCoordinator {
    /// How many pull requests have their sources read and embedded per batch.
    ///
    /// Twenty, because a batch's stored diffs are in memory at once and a diff has no size
    /// ceiling (`ShepherdPersistence/SearchIndexStore.swift` makes the same point). It also
    /// bounds how much work is thrown away when a pass is cancelled at sign-out.
    static let batchSize = 20

    private let settings: AppSettings
    private let embedder: any EmbeddingProviding
    private let budget: SearchDocumentBudget
    private let now: @MainActor () -> Date

    /// What Settings shows.
    private(set) var status = SearchIndexStatus()

    /// The searchable corpus, keyed by pull-request node id.
    private var documents: [String: SearchDocument] = [:]
    /// The vectors the ranker blends in. A missing entry means "lexical only for this row".
    private var vectors: [String: SearchVector] = [:]
    /// The inbox rows, so a result can carry its own summary.
    private var summaries: [String: PullRequestSummary] = [:]
    /// What the database already holds, read once per session.
    private var storedEntries: [String: SearchIndexEntry] = [:]
    private var hasReadStoredEntries = false
    private var hasCheckedAvailability = false

    /// The second corpus: one document per issue in the local issues inbox (ADR 0032).
    ///
    /// Four parallel dictionaries rather than one keyed by a sum type, because the documents,
    /// the vectors and the summaries are all *different types* — an issue document has four
    /// fields where a pull request's has eight (ADR 0032 argues why it is a sibling and not a
    /// widening), and a shared container would mean unwrapping at every use.
    private var issueDocuments: [String: IssueSearchDocument] = [:]
    private var issueVectors: [String: SearchVector] = [:]
    private var issueSummaries: [String: IssueRowSummary] = [:]
    private var storedIssueEntries: [String: IssueSearchIndexEntry] = [:]
    private var hasReadStoredIssueEntries = false

    /// The pass that is running, if one is.
    ///
    /// `private(set)` rather than private so `ShepherdTests` can *await* a pass instead of polling
    /// for its effects — the same kind of seam ``AutoMergeCoordinator/run(rows:existingOutbox:write:)``
    /// gives by returning its writes. Nothing in the app reads it.
    private(set) var passTask: Task<Void, Never>?
    /// Rows that arrived while a pass was running, keyed by pull request so that callers of
    /// different scope merge instead of overwriting each other: a full inbox snapshot from the
    /// sweep upserts every row, a single row from ``indexAfterDetailLoad(prID:database:)`` upserts
    /// one. Last write per pull request wins — an intermediate state of *that* pull request is of
    /// no interest once a newer one is known — but a one-row announcement can no longer discard a
    /// whole snapshot that was waiting alongside it.
    private var pendingRows: [String: PullRequestSummary] = [:]
    /// The issues pass that is running, if one is.
    ///
    /// A task of its own rather than one pass over both corpora, and the reason is the trigger:
    /// the two observations speak independently — a sweep writes pull requests and issues in the
    /// same cycle but in two transactions — so a single task would make an issue write wait for
    /// a pull-request pass that is embedding a three-hundred-kilobyte diff. `private(set)` for
    /// ``passTask``'s reason: `ShepherdTests` awaits a pass instead of polling for its effects.
    private(set) var issuePassTask: Task<Void, Never>?
    /// Issue rows that arrived while a pass was running, keyed by issue.
    private var pendingIssueRows: [String: IssueRowSummary] = [:]

    /// Creates a coordinator.
    /// - Parameters:
    ///   - settings: Where the toggle lives.
    ///   - embedder: The embedding seam. The default is the on-device model.
    ///   - budget: What may enter a document.
    ///   - now: The clock, injectable so an `indexedAt` is assertable.
    init(
        settings: AppSettings,
        embedder: any EmbeddingProviding = NaturalLanguageEmbedder(),
        budget: SearchDocumentBudget = .standard,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.settings = settings
        self.embedder = embedder
        self.budget = budget
        self.now = now
        self.status.isEnabled = settings.semanticSearchEnabled
    }

    // MARK: - Searching

    /// Ranks the local inbox against what the user typed.
    ///
    /// Called from the palette's `.task(id: query)`, so a keystroke cancels the previous run: the
    /// cancellation is the debounce, and it is free because everything this does is local.
    /// - Parameters:
    ///   - query: What the user typed.
    ///   - limit: How many rows the palette has room for.
    ///   - verdicts: The structured-triage verdicts the `risk:`/`kind:` tokens filter against,
    ///     keyed by node id (ADR 0023). A dictionary rather than a coordinator, so this folder
    ///     keeps knowing nothing about triage: the palette reads both and passes one into the
    ///     other. Empty — the default — means a query with those tokens matches nothing, which is
    ///     the honest answer on a Mac that has classified nothing.
    /// - Returns: The best matches, best first. Empty for an empty query and for a query nothing
    ///   matches — a palette that answered every query with its six least-unrelated pull requests
    ///   would be worse than one that answered nothing.
    func results(
        for query: String,
        limit: Int = 6,
        verdicts: [String: TriageVerdict] = [:]
    ) async -> [PullRequestSearchResult] {
        let parsed = SearchQuery(text: query)
        guard !parsed.isEmpty, !documents.isEmpty else { return [] }
        var corpus = Array(documents.values)
        if parsed.triage.isActive {
            // Narrowing, before anything is scored or embedded: `risk:high login` is a search for
            // *login* inside the high-risk pull requests, not a search over everything with the
            // filter applied to the six that came back.
            corpus = corpus.filter { parsed.triage.matches(verdicts[$0.prID]) }
            guard !corpus.isEmpty else { return [] }
        }

        var searchVectors: SearchVectors?
        // An exact `owner/repo#n` is not a ranking question, so it does not spend an embedding —
        // and neither is a query that has no words left after its filter tokens came out.
        if !vectors.isEmpty, parsed.reference == nil, parsed.hasSearchTerms,
           let queryVector = await embedder.vector(for: parsed.normalizedText) {
            searchVectors = SearchVectors(query: queryVector, documents: vectors)
        }
        guard !Task.isCancelled else { return [] }

        let ranked = SearchRanker.rank(
            query: parsed,
            documents: corpus,
            vectors: searchVectors,
            options: SearchRankingOptions(limit: limit)
        )
        return ranked.compactMap { result in
            guard let summary = summaries[result.prID] else { return nil }
            return PullRequestSearchResult(
                summary: summary,
                score: result.score,
                reason: result.reason
            )
        }
    }

    /// Ranks both corpora against what the user typed and merges them into one ordered answer.
    ///
    /// The palette's one call (ADR 0032). Both sets are ranked to the *same* limit and then
    /// merged by score and sliced once, so the rows the palette has room for are the best of
    /// both kinds rather than a fixed quota each — and the caller still gets them grouped, which
    /// is what a reader scans.
    ///
    /// Ties break pull requests first and then on node id, so the order is total: two sweeps of
    /// the same data can never reshuffle the palette (the property ``ShepherdCore/SearchRanker``
    /// pins for one corpus, extended to the merge of two).
    /// - Parameters:
    ///   - query: What the user typed.
    ///   - limit: How many rows the palette has room for, across both kinds.
    ///   - verdicts: The structured-triage verdicts the `risk:`/`kind:` tokens filter pull
    ///     requests against (ADR 0023). They do not reach the issue ranking, and cannot: a
    ///     verdict is a statement about a pull request, so `IssueSearchRanker` answers a
    ///     triage-only query with nothing rather than with a listing (ADR 0032).
    /// - Returns: The best matches of both kinds, best first within each.
    func paletteResults(
        for query: String,
        limit: Int = 6,
        verdicts: [String: TriageVerdict] = [:]
    ) async -> PaletteSearchResults {
        let pullRequests = await results(for: query, limit: limit, verdicts: verdicts)
        let issues = await issueResults(for: query, limit: limit)
        guard !Task.isCancelled else { return PaletteSearchResults() }
        guard !issues.isEmpty else {
            return PaletteSearchResults(pullRequests: pullRequests, issues: [])
        }
        guard !pullRequests.isEmpty else {
            return PaletteSearchResults(
                pullRequests: [],
                issues: Array(issues.prefix(max(0, limit)))
            )
        }
        // One ordered list, sliced once, then partitioned back — which is the whole point: the
        // slice is what a quota per kind would get wrong.
        let merged = (pullRequests.map(MergedSearchRow.pullRequest)
            + issues.map(MergedSearchRow.issue))
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                return left.sortKey < right.sortKey
            }
            .prefix(max(0, limit))
        var result = PaletteSearchResults()
        for entry in merged {
            switch entry {
            case .pullRequest(let value): result.pullRequests.append(value)
            case .issue(let value): result.issues.append(value)
            }
        }
        return result
    }

    /// Ranks the local issues inbox against what the user typed (ADR 0032).
    ///
    /// ``results(for:limit:verdicts:)``'s twin with one difference, and it is a decision rather
    /// than an omission: a query that is nothing but a `risk:`/`kind:` token is answered with
    /// **nothing**. `IssueSearchRanker.rank` returns `[]` for it — there is no issue the filter
    /// could have narrowed, and listing every issue in the inbox in answer would be an opinion
    /// nobody asked for — and the guard below spares the embedding as well.
    /// - Parameters:
    ///   - query: What the user typed.
    ///   - limit: How many rows to rank.
    /// - Returns: The best matches, best first.
    func issueResults(for query: String, limit: Int = 6) async -> [IssueSearchMatch] {
        let parsed = SearchQuery(text: query)
        guard !parsed.isEmpty, !issueDocuments.isEmpty, parsed.hasSearchTerms else { return [] }

        var searchVectors: IssueSearchVectors?
        // An exact `owner/repo#n` is not a ranking question, so it does not spend an embedding —
        // the same rule the pull-request half follows, and the same query text, so the two
        // rankings cannot be scored on two different curves.
        if !issueVectors.isEmpty, parsed.reference == nil,
           let queryVector = await embedder.vector(for: parsed.normalizedText) {
            searchVectors = IssueSearchVectors(query: queryVector, documents: issueVectors)
        }
        guard !Task.isCancelled else { return [] }

        let ranked = IssueSearchRanker.rank(
            query: parsed,
            documents: Array(issueDocuments.values),
            vectors: searchVectors,
            options: SearchRankingOptions(limit: limit)
        )
        return ranked.compactMap { result in
            guard let summary = issueSummaries[result.issueID] else { return nil }
            return IssueSearchMatch(
                summary: summary,
                score: result.score,
                reason: result.reason
            )
        }
    }

    // MARK: - Indexing

    /// Considers the rows a sweep just wrote.
    ///
    /// Wired to ``SignedInSession/start(settings:notifications:onEvent:onInboxRows:)`` beside
    /// automatic merging, so both features see the same rows at the same moment (ADR 0018's
    /// callback, re-used rather than duplicated).
    /// - Parameters:
    ///   - rows: Every inbox row the local database now holds.
    ///   - database: Where the sources and the index live.
    func considerIndexing(rows: [PullRequestSummary], database: DatabaseManager) {
        summaries = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        // A pull request that left the inbox leaves the corpus in the same breath. Its *row* is
        // already gone from SQLite — the foreign key took it with the pull request (v3 migration),
        // so there is nothing to delete here.
        let present = Set(rows.map(\.id))
        documents = documents.filter { present.contains($0.key) }
        vectors = vectors.filter { present.contains($0.key) }
        storedEntries = storedEntries.filter { present.contains($0.key) }

        status.isEnabled = settings.semanticSearchEnabled
        guard settings.semanticSearchEnabled else {
            passTask?.cancel()
            passTask = nil
            pendingRows = [:]
            indexFromRowsOnly(rows)
            return
        }
        schedulePass(rows: rows, database: database)
    }

    /// Considers the issue rows the second sweep just wrote (ADR 0032).
    ///
    /// ``considerIndexing(rows:database:)``'s twin, wired to
    /// ``SignedInSession/start(settings:notifications:onEvent:onInboxRows:onIssueRows:)``'s issue
    /// callback — the only announcement the issues sweep makes, deliberately, since it emits no
    /// `SyncEvent` of its own. Everything the pull-request pass promises holds here too: no
    /// client in this folder, so typing in the palette cannot produce a request; two hashes, so
    /// an unchanged sweep reads one small column and stops; and with the toggle off the corpus is
    /// still built from the rows alone, so ⌘K keeps finding issues by title and label.
    /// - Parameters:
    ///   - rows: Every issue row the local database now holds.
    ///   - database: Where the sources and the index live.
    func considerIndexingIssues(rows: [IssueRowSummary], database: DatabaseManager) {
        issueSummaries = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        // An issue the sweep pruned leaves the corpus in the same breath. Its index row is
        // already gone — the v7 migration's `ON DELETE CASCADE` took it with the issue.
        let present = Set(rows.map(\.id))
        issueDocuments = issueDocuments.filter { present.contains($0.key) }
        issueVectors = issueVectors.filter { present.contains($0.key) }
        storedIssueEntries = storedIssueEntries.filter { present.contains($0.key) }

        guard settings.semanticSearchEnabled else {
            issuePassTask?.cancel()
            issuePassTask = nil
            pendingIssueRows = [:]
            indexIssuesFromRowsOnly(rows)
            return
        }
        scheduleIssuePass(rows: rows, database: database)
    }

    /// Re-indexes one pull request now, because its diff has just been stored.
    ///
    /// The review screen calls this after a detail fetch lands. It is a *promptness* measure, not
    /// a correctness one: the moved `detailFetchedAt` makes the next ordinary pass pick the pull
    /// request up anyway, and that is deliberate — a feature that only worked because a screen
    /// remembered to announce something would quietly rot.
    /// - Parameters:
    ///   - prID: The pull request whose detail arrived.
    ///   - database: Where the sources and the index live.
    func indexAfterDetailLoad(prID: String, database: DatabaseManager) {
        guard settings.semanticSearchEnabled, let summary = summaries[prID] else { return }
        schedulePass(rows: [summary], database: database)
    }

    /// Throws the index away and builds it again from scratch.
    ///
    /// The *Rebuild index* button. It exists for the one case the hashes cannot detect: a model
    /// that changed what it answers without changing its identifier, or a user who simply does
    /// not believe the results any more. Everything it needs is local, so it costs CPU and
    /// nothing else.
    /// - Parameter database: Where the index lives.
    func rebuild(database: DatabaseManager) async {
        passTask?.cancel()
        passTask = nil
        pendingRows = [:]
        documents = [:]
        vectors = [:]
        storedEntries = [:]
        // Nothing is stored after the clear below, so there is nothing to read back.
        hasReadStoredEntries = true
        hasCheckedAvailability = false
        issuePassTask?.cancel()
        issuePassTask = nil
        pendingIssueRows = [:]
        issueDocuments = [:]
        issueVectors = [:]
        storedIssueEntries = [:]
        hasReadStoredIssueEntries = true
        try? await database.clearSearchIndex()
        // Both tables, because *Rebuild index* is one button and one promise: an index the user
        // does not believe any more is both corpora (ADR 0032).
        try? await database.clearIssueSearchIndex()
        // `async` rather than fire-and-forget so the caller — and a test — can tell when the
        // table is actually empty; the *pass* it hands over to stays asynchronous.
        let rows = Array(summaries.values)
        let issueRows = Array(issueSummaries.values)
        guard settings.semanticSearchEnabled else {
            indexFromRowsOnly(rows)
            indexIssuesFromRowsOnly(issueRows)
            return
        }
        schedulePass(rows: rows, database: database)
        scheduleIssuePass(rows: issueRows, database: database)
    }

    /// Switches the index off: cancels the pass, drops the vectors and empties the table.
    ///
    /// Called from the toggle and from an applied settings document (ADR 0014), both through
    /// ``AppEnvironment/applySemanticSearchSetting()`` — the one route, exactly as the
    /// diagnostics opt-in has one (ADR 0017).
    ///
    /// The table is emptied rather than kept warm, because "Semantic search index: off" that left
    /// a megabyte of vectors on disk and a size line reading 412 would be a lie about the one
    /// thing the toggle is named after. Re-enabling costs one indexing pass, which is local, CPU
    /// only and interruptible.
    /// - Parameter database: Where the index lives, when there is a session.
    func disable(database: DatabaseManager?) async {
        passTask?.cancel()
        passTask = nil
        pendingRows = [:]
        vectors = [:]
        storedEntries = [:]
        hasReadStoredEntries = false
        hasCheckedAvailability = false
        indexFromRowsOnly(Array(summaries.values))
        issuePassTask?.cancel()
        issuePassTask = nil
        pendingIssueRows = [:]
        issueVectors = [:]
        storedIssueEntries = [:]
        hasReadStoredIssueEntries = false
        indexIssuesFromRowsOnly(Array(issueSummaries.values))
        status.isEnabled = false
        status.embeddingUnavailabilityReason = nil
        guard let database else { return }
        try? await database.clearSearchIndex()
        try? await database.clearIssueSearchIndex()
    }

    /// Drops everything. Called from "Sign out & erase local data".
    ///
    /// The corpus is memory and goes here; the table goes with `eraseAllData()`, because the index
    /// is local cache in exactly the sense ADR 0006 means (and it names the previous account's
    /// pull requests, which is the argument the auto-merge audit log makes).
    func reset() {
        passTask?.cancel()
        passTask = nil
        pendingRows = [:]
        documents = [:]
        vectors = [:]
        summaries = [:]
        storedEntries = [:]
        hasReadStoredEntries = false
        hasCheckedAvailability = false
        issuePassTask?.cancel()
        issuePassTask = nil
        pendingIssueRows = [:]
        issueDocuments = [:]
        issueVectors = [:]
        issueSummaries = [:]
        storedIssueEntries = [:]
        hasReadStoredIssueEntries = false
        status = SearchIndexStatus(isEnabled: settings.semanticSearchEnabled)
    }

    // MARK: - Passes

    private func schedulePass(rows: [PullRequestSummary], database: DatabaseManager) {
        guard passTask == nil else {
            for row in rows { pendingRows[row.id] = row }
            return
        }
        passTask = Task(priority: .low) { [weak self] in
            guard let self else { return }
            var next: [PullRequestSummary]? = rows
            while let current = next {
                await self.runPass(rows: current, database: database)
                if Task.isCancelled { break }
                next = self.takePendingRows()
            }
            self.status.isIndexing = false
            self.passTask = nil
        }
    }

    private func takePendingRows() -> [PullRequestSummary]? {
        defer { pendingRows = [:] }
        return pendingRows.isEmpty ? nil : Array(pendingRows.values)
    }

    private func runPass(rows: [PullRequestSummary], database: DatabaseManager) async {
        let model = embedder.modelIdentifier
        if !hasReadStoredEntries {
            let entries = (try? await database.searchIndexEntries()) ?? []
            storedEntries = Dictionary(
                entries.map { ($0.prID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            hasReadStoredEntries = true
        }
        if !hasCheckedAvailability {
            hasCheckedAvailability = true
            // Asked once per session, and only on the path that is about to embed something:
            // the answer is a property of the Mac, and the first ask is what loads the model.
            status.embeddingUnavailabilityReason = await embedder.availability().reason
        }

        let timestamps = (try? await database.detailFetchTimestamps()) ?? [:]
        let stale = rows
            .filter { row in
                let fingerprint = SearchDocument.fingerprint(
                    for: SearchIndexSource(summary: row, detailFetchedAt: timestamps[row.id])
                )
                return documents[row.id]?.sourceFingerprint != fingerprint
            }
            .map(\.id)
        guard !stale.isEmpty else {
            await refreshCounts(database: database)
            return
        }
        status.isIndexing = true

        var index = 0
        while index < stale.count {
            guard !Task.isCancelled else { return }
            let batch = Array(stale[index..<min(index + Self.batchSize, stale.count)])
            index += Self.batchSize
            guard let sources = try? await database.searchIndexSources(prIDs: batch) else {
                continue
            }
            // Composition tokenises and hashes every document in the batch, which is real CPU
            // work over as much as a few hundred kilobytes of diff — so it happens off the main
            // actor. `Task.detached` rather than a plain `nonisolated` call, because the latter's
            // isolation depends on a language-mode flag while this does not.
            let composed = await Task.detached(priority: .low) { [budget] in
                sources.map { SearchDocument.make(source: $0, budget: budget) }
            }.value
            guard !Task.isCancelled else { return }

            var writes: [SearchIndexEntry] = []
            for document in composed {
                documents[document.prID] = document
                if let stored = storedEntries[document.prID],
                   stored.isUsable(for: document, modelIdentifier: model) {
                    vectors[document.prID] = stored.vector
                    continue
                }
                let vector = await embedder.vector(for: document.embeddingText)
                guard !Task.isCancelled else { return }
                vectors[document.prID] = vector
                let entry = SearchIndexEntry(
                    prID: document.prID,
                    documentHash: document.documentHash,
                    modelIdentifier: model,
                    vector: vector,
                    indexedAt: now()
                )
                storedEntries[document.prID] = entry
                writes.append(entry)
            }
            // One transaction per batch, and *after* the batch: a crash costs the batch, which is
            // work that the next pass redoes from the same local rows. There is nothing here that
            // could not be recomputed.
            try? await database.saveSearchIndexEntries(writes)
            await Task.yield()
        }
        status.isIndexing = false
        await refreshCounts(database: database)
    }

    private func scheduleIssuePass(rows: [IssueRowSummary], database: DatabaseManager) {
        guard issuePassTask == nil else {
            for row in rows { pendingIssueRows[row.id] = row }
            return
        }
        issuePassTask = Task(priority: .low) { [weak self] in
            guard let self else { return }
            var next: [IssueRowSummary]? = rows
            while let current = next {
                await self.runIssuePass(rows: current, database: database)
                if Task.isCancelled { break }
                next = self.takePendingIssueRows()
            }
            self.issuePassTask = nil
        }
    }

    private func takePendingIssueRows() -> [IssueRowSummary]? {
        defer { pendingIssueRows = [:] }
        return pendingIssueRows.isEmpty ? nil : Array(pendingIssueRows.values)
    }

    /// One pass over the issues corpus (ADR 0032).
    ///
    /// ``runPass(rows:database:)`` with the issue types substituted and the two staleness gates
    /// unchanged: the `sourceFingerprint` decides whether a row's body is read back out of
    /// SQLite at all, and only then does the `documentHash` decide whether an embedding is spent.
    /// The `detailFetchedAt` column is what makes the first gate correct rather than merely
    /// cheap — opening an issue stores its body and moves that timestamp, so the very next pass
    /// grows the document from "title and labels" to the whole report.
    ///
    /// It does **not** ask ``EmbeddingProviding/availability()``: the pull-request pass asks once
    /// per session and the answer is a property of the Mac, so asking again here would load the
    /// model a second time to learn the same thing.
    private func runIssuePass(rows: [IssueRowSummary], database: DatabaseManager) async {
        let model = embedder.modelIdentifier
        if !hasReadStoredIssueEntries {
            let entries = (try? await database.issueSearchIndexEntries()) ?? []
            storedIssueEntries = Dictionary(
                entries.map { ($0.issueID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            hasReadStoredIssueEntries = true
        }

        let timestamps = (try? await database.issueDetailFetchTimestamps()) ?? [:]
        let stale = rows
            .filter { row in
                let fingerprint = IssueSearchDocument.fingerprint(
                    for: IssueSearchIndexSource(
                        summary: row,
                        detailFetchedAt: timestamps[row.id]
                    )
                )
                return issueDocuments[row.id]?.sourceFingerprint != fingerprint
            }
            .map(\.id)
        guard !stale.isEmpty else {
            await refreshCounts(database: database)
            return
        }
        status.isIndexing = true

        var index = 0
        while index < stale.count {
            guard !Task.isCancelled else { return }
            let batch = Array(stale[index..<min(index + Self.batchSize, stale.count)])
            index += Self.batchSize
            guard let sources = try? await database.issueSearchIndexSources(issueIDs: batch) else {
                continue
            }
            // Off the main actor for ``runPass(rows:database:)``'s reason, even though an issue
            // body is capped by what a human typed rather than by a generated diff: composing
            // tokenises and hashes, and the shape is kept identical so the two passes cannot
            // drift apart.
            let composed = await Task.detached(priority: .low) {
                sources.map { IssueSearchDocument.make(source: $0) }
            }.value
            guard !Task.isCancelled else { return }

            var writes: [IssueSearchIndexEntry] = []
            for document in composed {
                issueDocuments[document.issueID] = document
                if let stored = storedIssueEntries[document.issueID],
                   stored.isUsable(for: document, modelIdentifier: model) {
                    issueVectors[document.issueID] = stored.vector
                    continue
                }
                let vector = await embedder.vector(for: document.embeddingText)
                guard !Task.isCancelled else { return }
                issueVectors[document.issueID] = vector
                let entry = IssueSearchIndexEntry(
                    issueID: document.issueID,
                    documentHash: document.documentHash,
                    modelIdentifier: model,
                    vector: vector,
                    indexedAt: now()
                )
                storedIssueEntries[document.issueID] = entry
                writes.append(entry)
            }
            try? await database.saveIssueSearchIndexEntries(writes)
            await Task.yield()
        }
        status.isIndexing = false
        await refreshCounts(database: database)
    }

    /// Builds the issues corpus from the rows alone: no source read, no embedding, no write.
    ///
    /// The switched-off state, and the honest state between the first sweep and the first pass.
    /// The same ``ShepherdCore/IssueSearchDocument`` with the body left out, so the ranker, the
    /// palette and the reasons need no second code path.
    private func indexIssuesFromRowsOnly(_ rows: [IssueRowSummary]) {
        issueDocuments = [:]
        for row in rows {
            issueDocuments[row.id] = IssueSearchDocument.make(
                source: IssueSearchIndexSource(summary: row)
            )
        }
        issueVectors = [:]
        status.issueDocumentCount = issueDocuments.count
        status.issueEmbeddedCount = 0
    }

    /// Builds the corpus from the inbox rows alone: no source read, no embedding, no write.
    ///
    /// The switched-off state, and also the honest state for a fresh install between the first
    /// sweep and the first pass. It is the *same* ``ShepherdCore/SearchDocument`` type with fewer
    /// fields filled in, so the ranker, the palette and the reasons need no second code path.
    private func indexFromRowsOnly(_ rows: [PullRequestSummary]) {
        documents = [:]
        for row in rows {
            let document = SearchDocument.make(
                source: SearchIndexSource(summary: row),
                budget: budget
            )
            documents[row.id] = document
        }
        vectors = [:]
        status.isIndexing = false
        status.documentCount = documents.count
        status.embeddedCount = 0
        status.vectorByteCount = 0
        status.lastIndexedAt = nil
    }

    /// Re-reads what the settings card shows.
    ///
    /// Awaited inside the pass rather than fired off as its own task: a stray task could land
    /// after a sign-out and put the previous account's numbers back on screen, and the pass is
    /// already the thing that knows when they changed.
    private func refreshCounts(database: DatabaseManager) async {
        status.documentCount = documents.count
        status.embeddedCount = vectors.count
        status.issueDocumentCount = issueDocuments.count
        status.issueEmbeddedCount = issueVectors.count
        guard let statistics = try? await database.searchIndexStatistics() else { return }
        // The two indexes are added up, because the question Settings asks is "how much of my
        // disk is this" and the answer is one number (ADR 0032: the statistics *type* is shared
        // for exactly this reason). The newest write of either is the newest write.
        let issueStatistics =
            (try? await database.issueSearchIndexStatistics()) ?? SearchIndexStatistics()
        status.vectorByteCount = statistics.vectorByteCount + issueStatistics.vectorByteCount
        status.lastIndexedAt = [statistics.lastIndexedAt, issueStatistics.lastIndexedAt]
            .compactMap { $0 }
            .max()
    }
}
