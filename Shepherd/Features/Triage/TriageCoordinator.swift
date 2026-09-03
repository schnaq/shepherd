import Foundation
import Observation
import ShepherdCore
import ShepherdPersistence

/// What the Intelligence settings card says about structured triage.
struct TriageStatus: Equatable, Sendable {
    /// Whether the user has the switch on.
    var isEnabled = true
    /// Whether a pass is classifying right now.
    var isClassifying = false
    /// How many pull requests are in the inbox the pass last saw.
    var rowCount = 0
    /// How many of those carry a verdict.
    var classifiedCount = 0
    /// Why nothing is being classified, when nothing is — the tiers being off, or the tagging
    /// model's own words about why it cannot answer.
    var unavailabilityReason: String?
}

/// What one inbox row knows about its own triage state.
///
/// Both halves are here on purpose, and the row renders whichever it has: a verdict is the
/// model's answer, and ``heuristicRisk``/``riskHints`` are what ``ShepherdCore/FilePrioritizer``
/// worked out with no model at all. A Mac with Apple Intelligence off therefore keeps a risk
/// column and a "why?" popover — with tier-1 sentences in it — instead of losing the feature
/// (ADR 0023's degradation rule).
struct TriageRowSummary: Equatable, Sendable {
    /// The model's verdict, when there is one.
    var verdict: TriageVerdict?
    /// The tier-1 risk level, when Shepherd has a diff to judge.
    var heuristicRisk: TriageVerdict.Risk?
    /// The tier-1 hint sentences, in priority order.
    var riskHints: [String] = []

    /// The risk to show: the model's when it spoke, the heuristics' otherwise.
    var risk: TriageVerdict.Risk? { verdict?.risk ?? heuristicRisk }

    /// Whether ``risk`` came from a verdict.
    var isClassified: Bool { verdict != nil }

    /// Whether there is anything at all to render for this row.
    var isEmpty: Bool { verdict == nil && heuristicRisk == nil }

    /// The row's risk as the facet counts it, or `nil` when there is nothing to count.
    var rowRisk: TriageRowRisk? {
        guard let risk else { return nil }
        return TriageRowRisk(risk: risk, isClassified: isClassified)
    }
}

/// Gives every pull request in the inbox a verdict, unattended and on-device (ADR 0023).
///
/// The fifth coordinator of this shape — ``SearchIndexCoordinator`` is the one it is modelled on
/// most closely — and the division of labour is the same: every decision is a pure value in
/// `ShepherdCore` (``ShepherdCore/TriageInput``, ``ShepherdCore/TriageRiskHints``,
/// ``ShepherdCore/TriageVerdictEntry``), and this type supplies the inputs, spends the model and
/// holds the answers.
///
/// Six things about *when* and *how* it runs are decisions rather than mechanics:
///
/// - **The trigger is the rows a sweep wrote** — the same `onInboxRows` callback automatic
///   merging (ADR 0018), the Spotlight export (ADR 0021) and the search index (ADR 0019) already
///   share. It is deliberately **not** hung off the end of the search index's pass, even though
///   that pass has already composed the very documents this one needs. Two reasons, and the
///   second is the decisive one: a hook there would make one setting depend on another — with
///   *semantic search* switched off the index composes documents from inbox rows alone, so
///   structured triage would quietly start classifying titles without its own switch having
///   changed — and it would put an ordering dependency between two features that today share
///   nothing but a data source. The cost of independence is one `detailFetchTimestamps()` read
///   and a second `SearchDocument.make` for the rows that changed; the cost of coupling would be
///   a feature whose quality silently depends on another feature's toggle.
/// - **Two gates, and they are ADR 0019's.** The cheap one is
///   ``ShepherdCore/SearchDocument/fingerprint(for:)``, so a sweep that changed nothing reads one
///   small column and stops; the persisted one is the document hash beside every verdict, so a
///   pull request whose *text* did not change keeps the verdict it has however many sweeps have
///   run. A verdict is expensive in exactly the way an embedding is, and it is invalidated by
///   exactly the same rule.
/// - **One pull request at a time, at `.utility` priority.** The tagging model is fast, but a
///   two-hundred-row inbox is still two hundred sequential generations; running them one behind
///   the other keeps the model out of the way of anything the user asked for, and makes
///   cancellation cheap — at most one verdict is thrown away.
/// - **It skips entirely when it cannot help.** The switch off, the tiers off, or the tagging
///   model unavailable: no classification is attempted and the reason is put where Settings can
///   read it. With the switch off nothing is computed *and* the table is emptied; with only the
///   model missing the tier-1 half still runs, which is what makes the risk facet degrade to
///   heuristics instead of vanishing.
/// - **Rows arriving mid-pass merge rather than replace**, keyed by pull request, exactly as
///   ``SearchIndexCoordinator/pendingRows`` does: a full inbox snapshot and a single announced
///   row are callers of different scope, and a one-row call may not discard a whole snapshot
///   waiting beside it.
/// - **Nothing here can reach GitHub or a cloud endpoint.** There is no client, no URL and no
///   key in this folder, and ``TriageClassifying`` has exactly one implementation. An unattended
///   pass over the whole inbox is the one thing ADR 0007's tier-3 argument does not cover.
@MainActor
@Observable
final class TriageCoordinator {
    /// How many pull requests have their sources read per batch.
    ///
    /// Twenty, ``SearchIndexCoordinator/batchSize``'s number for its reason: a batch's stored
    /// diffs are in memory at once and a diff has no size ceiling. It also bounds how much work
    /// a cancelled pass throws away.
    static let batchSize = 20

    private let settings: AppSettings
    private let classifier: any TriageClassifying
    private let budget: SearchDocumentBudget
    private let now: @MainActor () -> Date

    /// What Settings shows.
    private(set) var status = TriageStatus()

    /// What every row knows about itself, keyed by pull-request node id.
    private var rows: [String: TriageRowSummary] = [:]
    /// The cheap staleness key per pull request — in memory only, like the search corpus's.
    private var fingerprints: [String: String] = [:]
    /// What the database already holds, read once per session.
    private var storedEntries: [String: TriageVerdictEntry] = [:]
    /// The inbox rows the last pass saw, so the switch and the table can be reconciled later.
    private var summaries: [String: PullRequestSummary] = [:]
    private var hasReadStoredEntries = false
    private var hasCheckedAvailability = false
    /// The tagging model's own reason, asked once per session (asking is what loads the model).
    private var modelUnavailabilityReason: String?

    /// The pass that is running, if one is.
    ///
    /// `private(set)` rather than private so `ShepherdTests` can *await* a pass instead of
    /// polling for its effects — ``SearchIndexCoordinator/passTask``'s seam. Nothing in the app
    /// reads it.
    private(set) var passTask: Task<Void, Never>?
    /// Rows that arrived while a pass was running, merged per pull request.
    private var pendingRows: [String: PullRequestSummary] = [:]

    /// Creates a coordinator.
    /// - Parameters:
    ///   - settings: Where the switch and the tier setting live.
    ///   - classifier: The classification seam. The default is the on-device tagging model.
    ///   - budget: What may enter a search document, and therefore an input.
    ///   - now: The clock, injectable so a `classifiedAt` is assertable.
    init(
        settings: AppSettings,
        classifier: any TriageClassifying = OnDeviceTriageClassifier(),
        budget: SearchDocumentBudget = .standard,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.settings = settings
        self.classifier = classifier
        self.budget = budget
        self.now = now
        self.status.isEnabled = settings.structuredTriageEnabled
    }

    // MARK: - Reading

    /// The verdict for one pull request, or `nil` when there is none.
    /// - Parameter prID: The pull request's node id.
    func verdict(for prID: String) -> TriageVerdict? {
        rows[prID]?.verdict
    }

    /// What one inbox row should render, or `nil` when there is nothing to render.
    /// - Parameter prID: The pull request's node id.
    func row(for prID: String) -> TriageRowSummary? {
        guard let summary = rows[prID], !summary.isEmpty else { return nil }
        return summary
    }

    /// The risk one row is filtered by — the verdict's, or the tier-1 heuristics'.
    /// - Parameter prID: The pull request's node id.
    func risk(for prID: String) -> TriageVerdict.Risk? {
        rows[prID]?.risk
    }

    /// Every verdict, keyed by node id — what ⌘K's `risk:`/`kind:` tokens filter against.
    ///
    /// Handed over as a dictionary rather than as a reference to this coordinator, so
    /// ``SearchIndexCoordinator`` keeps knowing nothing about triage: the palette reads both and
    /// passes one into the other.
    var verdicts: [String: TriageVerdict] {
        rows.compactMapValues { $0.verdict }
    }

    /// The rail's RISK facet for a set of rows, highest risk first.
    /// - Parameter prIDs: The pull requests the rail is counting, in any order.
    /// - Returns: One entry per risk level that anything is at.
    func riskFacets(for prIDs: [String]) -> [TriageRiskFacet] {
        TriageFacets.riskFacets(prIDs.compactMap { rows[$0]?.rowRisk })
    }

    // MARK: - Classifying

    /// Considers the rows a sweep just wrote.
    ///
    /// Wired to ``SignedInSession/start(settings:notifications:onEvent:onInboxRows:)`` beside the
    /// search index, so both features see the same rows at the same moment.
    /// - Parameters:
    ///   - rows: Every inbox row the local database now holds.
    ///   - database: Where the sources and the verdicts live.
    func considerClassifying(rows: [PullRequestSummary], database: DatabaseManager) {
        summaries = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        // A pull request that left the inbox leaves this coordinator in the same breath. Its
        // *row* is already gone from SQLite — the foreign key took it with the pull request (v4
        // migration) — so there is nothing to delete here.
        let present = Set(rows.map(\.id))
        self.rows = self.rows.filter { present.contains($0.key) }
        fingerprints = fingerprints.filter { present.contains($0.key) }
        storedEntries = storedEntries.filter { present.contains($0.key) }
        status.isEnabled = settings.structuredTriageEnabled
        status.rowCount = rows.count

        guard settings.structuredTriageEnabled else {
            // Not merely "do not classify": the switch is off, so there is nothing to show and
            // nothing to remember. ``disable(database:)`` is what empties the table; this is the
            // path a pass takes when the flag was already off when the sweep landed.
            cancelAndForget()
            status.classifiedCount = 0
            status.unavailabilityReason = nil
            return
        }
        schedulePass(rows: rows, database: database)
    }

    /// Re-classifies one pull request now, because its diff has just been stored.
    ///
    /// The review screen's hook, and ADR 0019's promptness argument applies unchanged: the moved
    /// `detailFetchedAt` makes the next ordinary pass pick the pull request up anyway, so this
    /// only decides whether the chip changes now or after the next sweep. It matters more here
    /// than it does for the search index, because a stored diff is the difference between a
    /// verdict made from a title and one made from the change itself.
    ///
    /// Deliberately *not* a snapshot: it upserts one row into whatever is waiting, which is the
    /// whole reason ``pendingRows`` merges instead of replacing.
    /// - Parameters:
    ///   - prID: The pull request whose detail arrived.
    ///   - database: Where the sources and the verdicts live.
    func classifyAfterDetailLoad(prID: String, database: DatabaseManager) {
        guard settings.structuredTriageEnabled, let summary = summaries[prID] else { return }
        schedulePass(rows: [summary], database: database)
    }

    /// Switches structured triage off: cancels the pass, forgets the verdicts, empties the table.
    ///
    /// Called from the toggle and from an applied settings document (ADR 0014), both through
    /// ``AppEnvironment/applyStructuredTriageSetting()`` — the one route, exactly as the search
    /// index and the diagnostics opt-in have one.
    ///
    /// The table is emptied rather than kept warm, for the search index's reason: "Structured
    /// triage: off" that left a verdict per pull request on disk, ready to reappear, would be a
    /// lie about the switch. Re-enabling costs one local pass, which is CPU and the on-device
    /// model and nothing else.
    /// - Parameter database: Where the verdicts live, when there is a session.
    func disable(database: DatabaseManager?) async {
        cancelAndForget()
        status.isEnabled = false
        status.classifiedCount = 0
        status.unavailabilityReason = nil
        guard let database else { return }
        // Read then delete, rather than a `DELETE FROM`: the four repository methods are the
        // whole surface this feature needs, and the foreign key guarantees the table holds rows
        // only for pull requests that are in the inbox.
        let stored = (try? await database.triageVerdicts()) ?? []
        try? await database.deleteTriageVerdicts(prIDs: stored.map(\.prID))
    }

    /// Drops everything. Called from "Sign out & erase local data".
    ///
    /// The verdicts in memory go here; the table goes with `eraseAllData()`, because it is local
    /// cache in exactly the sense ADR 0006 means — and because it names the previous account's
    /// pull requests, which is the argument the auto-merge audit log makes.
    func reset() {
        cancelAndForget()
        summaries = [:]
        status = TriageStatus(isEnabled: settings.structuredTriageEnabled)
    }

    // MARK: - Passes

    private func cancelAndForget() {
        passTask?.cancel()
        passTask = nil
        pendingRows = [:]
        rows = [:]
        fingerprints = [:]
        storedEntries = [:]
        hasReadStoredEntries = false
        hasCheckedAvailability = false
        modelUnavailabilityReason = nil
        status.isClassifying = false
    }

    private func schedulePass(rows: [PullRequestSummary], database: DatabaseManager) {
        guard passTask == nil else {
            for row in rows { pendingRows[row.id] = row }
            return
        }
        passTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            var next: [PullRequestSummary]? = rows
            while let current = next {
                await self.runPass(rows: current, database: database)
                if Task.isCancelled { break }
                next = self.takePendingRows()
            }
            self.status.isClassifying = false
            self.passTask = nil
        }
    }

    private func takePendingRows() -> [PullRequestSummary]? {
        defer { pendingRows = [:] }
        return pendingRows.isEmpty ? nil : Array(pendingRows.values)
    }

    private func runPass(rows: [PullRequestSummary], database: DatabaseManager) async {
        if !hasReadStoredEntries {
            let entries = (try? await database.triageVerdicts()) ?? []
            storedEntries = Dictionary(
                entries.map { ($0.prID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            hasReadStoredEntries = true
        }
        let canClassify = await resolveClassifiability()

        let timestamps = (try? await database.detailFetchTimestamps()) ?? [:]
        let stale = rows
            .filter { row in
                let fingerprint = SearchDocument.fingerprint(
                    for: SearchIndexSource(summary: row, detailFetchedAt: timestamps[row.id])
                )
                return fingerprints[row.id] != fingerprint
            }
            .map(\.id)
        guard !stale.isEmpty else {
            refreshCounts()
            return
        }
        status.isClassifying = canClassify

        var index = 0
        while index < stale.count {
            guard !Task.isCancelled else { return }
            let batch = Array(stale[index..<min(index + Self.batchSize, stale.count)])
            index += Self.batchSize
            guard let sources = try? await database.searchIndexSources(prIDs: batch) else {
                continue
            }
            // Composing a document tokenises and hashes as much as a few hundred kilobytes of
            // diff, and prioritising the files walks every path — real CPU work, so it happens
            // off the main actor. `Task.detached` rather than a plain `nonisolated` call, because
            // the latter's isolation depends on a language-mode flag while this does not.
            let prepared = await Task.detached(priority: .utility) { [budget] in
                sources.map { TriagePreparedRow(source: $0, budget: budget) }
            }.value
            guard !Task.isCancelled else { return }

            var writes: [TriageVerdictEntry] = []
            for row in prepared {
                if let entry = await classify(row, canClassify: canClassify) {
                    writes.append(entry)
                }
                guard !Task.isCancelled else { return }
            }
            // One transaction per batch, and *after* the batch: a crash costs the batch, which is
            // work the next pass redoes from the same local rows. Nothing here is unrecoverable.
            try? await database.saveTriageVerdicts(writes)
            refreshCounts()
            await Task.yield()
        }
        status.isClassifying = false
        refreshCounts()
    }

    /// Whether this pass may ask the model anything, and what Settings is told when it may not.
    ///
    /// The tier setting is re-read every pass because it can change between two sweeps; the
    /// *model's* answer is asked once per session, because it is a property of the Mac and the
    /// first ask is what loads the model — ``SearchIndexCoordinator``'s arrangement for the
    /// embedder, and the same trade: a model that becomes available mid-session is picked up at
    /// the next launch rather than being polled for.
    private func resolveClassifiability() async -> Bool {
        let reason: String?
        if settings.intelligenceMode == .off {
            reason = String(
                localized: "Turn on Apple Intelligence above to classify pull requests. Until then the inbox shows the risk hints it works out without a model."
            )
        } else {
            if !hasCheckedAvailability {
                hasCheckedAvailability = true
                modelUnavailabilityReason = await classifier.availability().reason
            }
            reason = modelUnavailabilityReason
        }
        status.unavailabilityReason = reason
        return reason == nil
    }

    /// Records one prepared row's tier-1 half and, when there is a model, its verdict.
    ///
    /// Sequential by construction — the caller awaits one row before preparing the next — which
    /// is what "one at a time" means for a pass that may run over two hundred pull requests.
    /// - Parameters:
    ///   - row: The prepared input, hints and heuristic risk.
    ///   - canClassify: Whether the model may be asked at all.
    /// - Returns: The row to persist, or `nil` when nothing new was computed.
    private func classify(_ row: TriagePreparedRow, canClassify: Bool) async -> TriageVerdictEntry? {
        let prID = row.input.prID
        // Recorded before the model is asked, so a pass stops re-reading this pull request's
        // diff on every sweep. It is taken back in two places: when a classification *failed*,
        // and when the model could not be asked at all — a row seen while the tier was off must
        // be looked at again on the first sweep after the tier comes back.
        fingerprints[prID] = row.fingerprint
        var summary = rows[prID] ?? TriageRowSummary()
        summary.heuristicRisk = row.heuristicRisk
        summary.riskHints = row.riskHints

        if let stored = storedEntries[prID],
           stored.isUsable(for: row.input, modelIdentifier: classifier.modelIdentifier) {
            summary.verdict = stored.verdict
            rows[prID] = summary
            return nil
        }
        // The text changed, so the stored verdict is about something else. Dropped before the new
        // one is asked for: a chip that keeps describing the previous commit is worse than none.
        summary.verdict = nil
        rows[prID] = summary
        guard canClassify else {
            fingerprints[prID] = nil
            return nil
        }

        do {
            let verdict = try await classifier.classify(row.input)
            summary.verdict = verdict
            rows[prID] = summary
            let entry = TriageVerdictEntry(
                prID: prID,
                documentHash: row.input.documentHash,
                verdict: verdict,
                modelIdentifier: classifier.modelIdentifier,
                classifiedAt: now()
            )
            storedEntries[prID] = entry
            return entry
        } catch {
            // Silent by design, and the only failure handling this pass has: a verdict is a
            // convenience nobody asked for, so a toast about one pull request the model declined
            // would be noise about work the user did not start. Forgetting the fingerprint is
            // what makes the next pass try again — a guardrail refusal will refuse again, and a
            // transient failure will not.
            fingerprints[prID] = nil
            return nil
        }
    }

    /// Re-reads what the settings card shows.
    private func refreshCounts() {
        status.rowCount = summaries.count
        status.classifiedCount = rows.values.filter { $0.verdict != nil }.count
    }
}

/// One pull request, prepared for classification off the main actor.
///
/// A file-scope value rather than a nested type so that it is unambiguously `Sendable` and can be
/// returned from the detached task that composes it. It holds only what the pass needs
/// afterwards: the two tier-1 answers, the input, and the fingerprint that says which version of
/// the pull request they describe.
private struct TriagePreparedRow: Sendable {
    /// ``ShepherdCore/SearchDocument/sourceFingerprint`` — the cheap staleness key.
    let fingerprint: String
    /// What the model is shown.
    let input: TriageInput
    /// The tier-1 risk level, or `nil` when there is no diff to judge.
    let heuristicRisk: TriageVerdict.Risk?
    /// The tier-1 hint sentences.
    let riskHints: [String]

    /// Prepares one pull request.
    /// - Parameters:
    ///   - source: What the database holds for it.
    ///   - budget: What may enter the document.
    init(source: SearchIndexSource, budget: SearchDocumentBudget) {
        let document = SearchDocument.make(source: source, budget: budget)
        let hints = TriageRiskHints.hints(for: source.files)
        self.fingerprint = document.sourceFingerprint
        self.input = TriageInput.make(document: document, riskHints: hints)
        self.heuristicRisk = TriageRiskHints.heuristicRisk(for: source.files)
        self.riskHints = hints
    }
}
