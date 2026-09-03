import Foundation
import Observation
import ShepherdCore
import ShepherdPersistence

/// Which kind of thing the inbox is showing (ADR 0032).
///
/// A picker at the top of the rail, not a second top-level route, and that is the decision the
/// type records. `j`/`k`, ⌘K, the focus session and the menu-bar item all already address "the
/// model that owns the selection" rather than a screen, so a second route would duplicate the
/// whole chrome — toolbar, digest card, Settings sheet, palette overlay — for one segmented
/// control's worth of difference.
enum ContentKind: String, CaseIterable, Identifiable, Sendable {
    /// The review inbox: `pull_requests`, `InboxModel`.
    case pullRequests
    /// The issues inbox: `issues`, ``IssueInboxModel``.
    case issues

    var id: String { rawValue }

    /// The segmented control's label.
    var title: String {
        switch self {
        case .pullRequests: return String(localized: "Pull requests")
        case .issues: return String(localized: "Issues")
        }
    }

    /// The SF Symbol shown beside the label.
    var systemImage: String {
        switch self {
        case .pullRequests: return "arrow.triangle.pull"
        case .issues: return "smallcircle.circle"
        }
    }
}

/// Drives the issues section of the inbox — the issue-side twin of ``InboxModel`` (ADR 0032).
///
/// Everything it renders comes from the database via `ValueObservation` (ADR 0006): the second
/// sweep of the cycle writes, GRDB notices, this model re-publishes. Nothing here calls GitHub to
/// *read* the list; the one request it can make is the body of the issue the panel has open, and
/// only when the cache has no fresher copy.
///
/// Two things about its shape are decisions rather than mechanics:
///
/// - **It is built from a database and an issue reader, not from a ``SignedInSession``.**
///   `InboxModel` takes the session because it needs four things off it; this needs two, and the
///   narrower dependency is what makes `IssueInboxModelTests` possible without a Keychain, a
///   token or a network — the argument ``ClaimsEvidenceModel`` already makes for the same
///   `IssueFetching` seam. The seam's one production conformance is `GitHubClient`, whose
///   `issue(repo:number:)` carries the ETag cache and the error mapping.
/// - **The observation is as wide as the section, and the facets narrow it in Swift.** That is
///   ``InboxModel/filteredRows``' arrangement, and here it also settles ``IssueFilter/now``:
///   the filter *is* the observation's key (Sprint 1's own doc comment), so a predicate that read
///   the clock inside itself would make two otherwise identical observations unequal and would
///   re-bucket rows underneath the view with no write having happened. The model states one
///   moment — ``referenceDate`` — and the age facet, the only thing that moment feeds, is applied
///   here rather than in SQL.
@MainActor
@Observable
final class IssueInboxModel {
    /// The local source of truth.
    let database: DatabaseManager
    /// How the panel reads an issue body, or `nil` when there is nobody to ask.
    ///
    /// Optional because "no fetcher" is a state and not a failure: without one the panel shows
    /// whatever body the cache holds, which is exactly what it shows while offline.
    let issues: (any IssueFetching)?

    /// Every issue row the database holds, most-recently-updated first.
    private(set) var allRows: [IssueRowSummary] = []
    /// Whether the first observation value has arrived.
    private(set) var hasLoaded = false
    /// The moment the age facet and the age filter measure against.
    ///
    /// Refreshed whenever the observation speaks, so "today" tracks along with the sweeps instead
    /// of freezing at the moment the window opened — and never read from the clock inside a
    /// predicate, which is the whole point of ``IssueFilter/now``.
    private(set) var referenceDate: Date

    /// The selected repository facet, if any.
    var repoFilter: RepoRef? {
        didSet { clampSelection() }
    }
    /// The selected label facet, if any.
    var labelFilter: String? {
        didSet { clampSelection() }
    }
    /// The selected age facet, if any.
    var ageFilter: IssueAgeBucket? {
        didSet { clampSelection() }
    }
    /// The selected half of the agent-pull-request facet, if any.
    var agentPullRequestFilter: IssueAgentPullRequestFilter? {
        didSet { clampSelection() }
    }
    /// The selected row's issue id — the keyboard cursor, always at most one row.
    private(set) var selectedID: String?

    /// The detail of the selected row: the row plus its body.
    private(set) var detail: IssueDetail?
    /// Whether a body fetch is in flight.
    private(set) var isFetchingBody = false

    private let now: @MainActor () -> Date
    private var observationTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    /// Creates the model.
    /// - Parameters:
    ///   - database: The local database.
    ///   - issues: How to read an issue body. `nil` leaves the panel on the cached body.
    ///   - now: The clock, injectable so the age facet is assertable.
    init(
        database: DatabaseManager,
        issues: (any IssueFetching)?,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.database = database
        self.issues = issues
        self.now = now
        self.referenceDate = now()
    }

    // MARK: - Observation

    /// Starts observing the `issues` table. Safe to call more than once.
    func startObserving() {
        guard observationTask == nil else { return }
        // Stated here, once, rather than defaulted inside the filter: see the type's own note.
        let stream = database.observeIssues(filter: IssueFilter(now: now()))
        observationTask = Task { [weak self] in
            for await rows in stream {
                guard let self else { return }
                self.allRows = rows
                self.referenceDate = self.now()
                self.hasLoaded = true
                self.clampSelection()
            }
        }
    }

    /// Stops observing.
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        detailTask?.cancel()
        detailTask = nil
    }

    // MARK: - Derived state

    /// The rows the centre list shows, after every rail facet.
    ///
    /// The order is the store's — most recently updated first — and there is deliberately no
    /// grouping or sort picker on this side: nothing in the brief asks for one, and a second sort
    /// vocabulary beside ``InboxSortOrder`` would be a decision nobody has made.
    var filteredRows: [IssueRowSummary] {
        allRows.filter { row in
            // Case-insensitive, exactly as the pull-request rail's repository facet is: the rail
            // always sets this from a row it is showing, but a link may carry any casing.
            if let repoFilter, !row.repo.isSameRepository(as: repoFilter) { return false }
            if let labelFilter, !row.labels.contains(labelFilter) { return false }
            if let ageFilter,
               !ageFilter.contains(createdAt: row.createdAt, now: referenceDate) {
                return false
            }
            if let agentPullRequestFilter, !agentPullRequestFilter.matches(row) { return false }
            return true
        }
    }

    /// Every visible row in display order — the order `j`/`k` walks.
    var visibleRows: [IssueRowSummary] { filteredRows }

    /// The selected row, if it is still visible.
    var selectedRow: IssueRowSummary? {
        guard let selectedID else { return nil }
        return visibleRows.first { $0.id == selectedID }
    }

    /// Whether any facet is narrowing the list, which is what tells the two empty states apart.
    var hasActiveFacet: Bool {
        repoFilter != nil || labelFilter != nil || ageFilter != nil
            || agentPullRequestFilter != nil
    }

    /// Clears every facet — the header's ✕ and Escape.
    func clearFacets() {
        repoFilter = nil
        labelFilter = nil
        ageFilter = nil
        agentPullRequestFilter = nil
    }

    // MARK: - Facets

    /// The repositories present in the section, with counts.
    ///
    /// Counted over every row rather than over the filtered list, exactly as the pull-request
    /// rail's facets are: a facet whose counts changed when you selected one of its own rows
    /// could not be used to compare them. The same goes for the three below.
    var repositoryFacets: [(repo: RepoRef, count: Int)] {
        var counts: [RepoRef: Int] = [:]
        for row in allRows {
            counts[row.repo, default: 0] += 1
        }
        return counts
            .map { (repo: $0.key, count: $0.value) }
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                return left.repo < right.repo
            }
    }

    /// The labels present in the section, with counts and the cap's overflow (ADR 0032).
    var labelFacets: IssueLabelFacets {
        IssueFacets.labelFacets(allRows)
    }

    /// The age buckets present in the section, with counts.
    var ageFacets: [IssueAgeFacet] {
        IssueFacets.ageFacets(allRows, now: referenceDate)
    }

    /// The two halves of the agent-pull-request facet, when both are populated.
    var agentPullRequestFacets: [IssueAgentPullRequestFacet] {
        IssueFacets.agentPullRequestFacets(allRows)
    }

    // MARK: - Selection

    /// Moves the selection by one row, wrapping at neither end.
    /// - Parameter offset: `+1` for `j`, `-1` for `k`.
    func moveSelection(by offset: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        guard let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) else {
            select(rows[0].id)
            return
        }
        let next = min(max(0, index + offset), rows.count - 1)
        select(rows[next].id)
    }

    /// Selects a row and loads its detail.
    /// - Parameter id: The issue's node id.
    func select(_ id: String?) {
        guard selectedID != id else { return }
        selectedID = id
        detail = nil
        loadDetail()
    }

    /// Selects one issue by node id, widening the facets if they hide it (ADR 0032).
    ///
    /// The one entry point a `shepherd://issue/…` link and a ⌘K row use, so "reveal this issue"
    /// has one implementation. A row the rail's facets are hiding is *shown* rather than silently
    /// not selected — an empty panel after clicking a search result reads as a broken link, which
    /// is the argument ``InboxRailSelection`` makes for widening the smart view.
    /// - Parameter id: The issue's node id.
    func reveal(issueID id: String) {
        if !allRows.contains(where: { $0.id == id }) {
            // Not cached yet: remember the ask, and let the next observation value honour it.
            pendingReveal = id
            return
        }
        // Selected first, then widened: `clearFacets()` sets four properties whose `didSet`
        // clamps the selection, and clamping before the cursor has moved would pick the first row
        // of the widened list and load its body for nothing.
        select(id)
        if !visibleRows.contains(where: { $0.id == id }) { clearFacets() }
    }

    /// An issue a link asked for before the observation had it.
    private var pendingReveal: String?

    private func clampSelection() {
        if let pendingReveal, allRows.contains(where: { $0.id == pendingReveal }) {
            self.pendingReveal = nil
            reveal(issueID: pendingReveal)
            return
        }
        let rows = visibleRows
        if let selectedID, rows.contains(where: { $0.id == selectedID }) { return }
        select(rows.first?.id)
    }

    // MARK: - Detail

    /// Loads the selected issue's body: the cache first, then one fetch when it is not fresh.
    ///
    /// The staleness rule is the same two-level gate the search index uses, and it is the reason
    /// the panel does not spend a request per selection: a stored body whose `detailFetchedAt` is
    /// at or after the row's `updatedAt` cannot be out of date, because anything that changes an
    /// issue moves `updatedAt`. Everything else — no body at all, a body from before the last
    /// edit — is one `GET /repos/…/issues/{n}`, ETag-cached in `GitHubClient` (ADR 0026's
    /// amendment), on the host that is already on `CONTRIBUTING.md`'s list.
    func loadDetail() {
        detailTask?.cancel()
        guard let selectedID, let row = allRows.first(where: { $0.id == selectedID }) else {
            detail = nil
            return
        }
        let database = self.database
        detailTask = Task { [weak self] in
            let cached = try? await database.fetchIssueDetail(id: selectedID)
            let stamps = (try? await database.issueDetailFetchTimestamps()) ?? [:]
            guard let self, !Task.isCancelled, self.selectedID == selectedID else { return }
            if let cached { self.detail = cached }
            guard IssueInboxModel.needsBodyFetch(
                row: row,
                cached: cached,
                fetchedAt: stamps[selectedID]
            ) else { return }
            guard let issues = self.issues else { return }
            self.isFetchingBody = true
            defer { self.isFetchingBody = false }
            do {
                let fresh = try await issues.issue(repo: row.repo, number: row.number)
                let detail = IssueDetail(summary: row, bodyMarkdown: fresh.bodyMarkdown)
                try? await database.saveIssueDetail(detail)
                guard !Task.isCancelled, self.selectedID == selectedID else { return }
                self.detail = detail
            } catch {
                // Offline is a normal state: the cached copy above is what the user reads, and
                // the panel says the body has not been fetched when there is none.
            }
        }
    }

    /// Whether the panel has to spend a request on this issue's body.
    ///
    /// Pure and `static` so the "fetch once" rule is assertable without a clock or a network.
    /// - Parameters:
    ///   - row: The inbox row.
    ///   - cached: What the database holds, if anything.
    ///   - fetchedAt: When the stored body was fetched, if it ever was.
    /// - Returns: `true` when a fetch is warranted.
    nonisolated static func needsBodyFetch(
        row: IssueRowSummary,
        cached: IssueDetail?,
        fetchedAt: Date?
    ) -> Bool {
        // Never fetched: the row may perfectly well have an empty body, but the only way to find
        // that out is to ask once.
        guard let fetchedAt else { return true }
        guard cached != nil else { return true }
        // A fetch at or after the row's own `updatedAt` cannot be describing an older body.
        return fetchedAt < row.updatedAt
    }
}
