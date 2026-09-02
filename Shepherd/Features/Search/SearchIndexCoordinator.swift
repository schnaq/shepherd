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

    /// The pass that is running, if one is.
    ///
    /// `private(set)` rather than private so `ShepherdTests` can *await* a pass instead of polling
    /// for its effects — the same kind of seam ``AutoMergeCoordinator/run(rows:existingOutbox:write:)``
    /// gives by returning its writes. Nothing in the app reads it.
    private(set) var passTask: Task<Void, Never>?
    /// Rows that arrived while a pass was running. One slot, last write wins — an intermediate
    /// state of the inbox is of no interest once a newer one is known.
    private var pendingRows: [PullRequestSummary]?

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
    /// - Returns: The best matches, best first. Empty for an empty query and for a query nothing
    ///   matches — a palette that answered every query with its six least-unrelated pull requests
    ///   would be worse than one that answered nothing.
    func results(for query: String, limit: Int = 6) async -> [PullRequestSearchResult] {
        let parsed = SearchQuery(text: query)
        guard !parsed.isEmpty, !documents.isEmpty else { return [] }
        let corpus = Array(documents.values)

        var searchVectors: SearchVectors?
        // An exact `owner/repo#n` is not a ranking question, so it does not spend an embedding.
        if !vectors.isEmpty, parsed.reference == nil,
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
            pendingRows = nil
            indexFromRowsOnly(rows)
            return
        }
        schedulePass(rows: rows, database: database)
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
        pendingRows = nil
        documents = [:]
        vectors = [:]
        storedEntries = [:]
        // Nothing is stored after the clear below, so there is nothing to read back.
        hasReadStoredEntries = true
        hasCheckedAvailability = false
        try? await database.clearSearchIndex()
        // `async` rather than fire-and-forget so the caller — and a test — can tell when the
        // table is actually empty; the *pass* it hands over to stays asynchronous.
        let rows = Array(summaries.values)
        guard settings.semanticSearchEnabled else {
            indexFromRowsOnly(rows)
            return
        }
        schedulePass(rows: rows, database: database)
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
        pendingRows = nil
        vectors = [:]
        storedEntries = [:]
        hasReadStoredEntries = false
        hasCheckedAvailability = false
        indexFromRowsOnly(Array(summaries.values))
        status.isEnabled = false
        status.embeddingUnavailabilityReason = nil
        guard let database else { return }
        try? await database.clearSearchIndex()
    }

    /// Drops everything. Called from "Sign out & erase local data".
    ///
    /// The corpus is memory and goes here; the table goes with `eraseAllData()`, because the index
    /// is local cache in exactly the sense ADR 0006 means (and it names the previous account's
    /// pull requests, which is the argument the auto-merge audit log makes).
    func reset() {
        passTask?.cancel()
        passTask = nil
        pendingRows = nil
        documents = [:]
        vectors = [:]
        summaries = [:]
        storedEntries = [:]
        hasReadStoredEntries = false
        hasCheckedAvailability = false
        status = SearchIndexStatus(isEnabled: settings.semanticSearchEnabled)
    }

    // MARK: - Passes

    private func schedulePass(rows: [PullRequestSummary], database: DatabaseManager) {
        guard passTask == nil else {
            pendingRows = rows
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
        defer { pendingRows = nil }
        return pendingRows
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
        guard let statistics = try? await database.searchIndexStatistics() else { return }
        status.vectorByteCount = statistics.vectorByteCount
        status.lastIndexedAt = statistics.lastIndexedAt
    }
}
