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
/// - **The observation is as wide as the section, and the facets narrow it in Swift.** Wide
///   enough since ADR 0032's 2026-09-04 amendment to carry the closed rows the sweep retained,
///   with ``stateFilter`` — defaulting to open — deciding what is on screen. That is
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
    /// The signed-in login, so *Assign to me* has somebody to assign.
    ///
    /// `nil` is a state and not a failure, exactly as ``issues`` is: the button is simply not
    /// drawn, which is what a window with no session shows anyway.
    let viewerLogin: String?
    /// How a queued write is pushed, when there is a sync engine to push it.
    ///
    /// A closure rather than the session, for the same reason the model takes a database and an
    /// issue reader rather than a `SignedInSession`: a test can assert that a write reached the
    /// outbox without a Keychain, a token or a network. `nil` leaves the row for the next drain,
    /// which is what an offline queue does anyway.
    @ObservationIgnored var drain: (@MainActor () async -> Void)?
    /// Which writes are in flight, so the panel's triage buttons can go quiet while one runs.
    ///
    /// Handed over by ``InboxScreen`` beside ``drain`` and optional for ``drain``'s reason: a
    /// test builds this model without an ``AppEnvironment``, and with no tracker every write
    /// simply runs — which is what it did before there was one. `@ObservationIgnored` because
    /// the *tracker* is observed by the views that read it; this reference never changes.
    @ObservationIgnored var activity: ActionActivity?

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
    /// The selected half of the state facet — open, closed, or `nil` for both.
    ///
    /// The only facet with a default, and that is the decision it records (ADR 0032's 2026-09-04
    /// amendment). The observation carries every retained closed row so that a ⌘K hit on one can
    /// land somewhere, but a triage section is a list of work still to do: a user who never asks
    /// for closed issues must see the list, the counts and the empty states exactly as they were.
    /// So the widening happens in the query and the narrowing happens here, and `nil` means
    /// "open and closed" precisely as it means "all" for the four facets above.
    var stateFilter: IssueStateFilter? = .open {
        didSet { clampSelection() }
    }
    /// The selected row's issue id — the keyboard cursor, always at most one row.
    private(set) var selectedID: String?

    /// The detail of the selected row: the row plus its body.
    private(set) var detail: IssueDetail?
    /// Whether a body fetch is in flight.
    private(set) var isFetchingBody = false
    /// The outbox rows that target the selected issue — queued, in flight, parked or failed
    /// (ADR 0006).
    ///
    /// Read after every enqueue and every drain rather than observed, because it is a panel
    /// detail rather than a source of truth: the standing counts in Settings → Sync and the title
    /// bar are the observed ones, and they already cover every row in the outbox whichever kind
    /// of node it targets.
    private(set) var pendingWrites: [OutboxItem] = []

    private let now: @MainActor () -> Date
    private var observationTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    /// Creates the model.
    /// - Parameters:
    ///   - database: The local database.
    ///   - issues: How to read an issue body. `nil` leaves the panel on the cached body.
    ///   - viewerLogin: The signed-in login, for *Assign to me*. `nil` hides that one button.
    ///   - now: The clock, injectable so the age facet is assertable.
    init(
        database: DatabaseManager,
        issues: (any IssueFetching)?,
        viewerLogin: String? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.database = database
        self.issues = issues
        self.viewerLogin = viewerLogin
        self.now = now
        self.referenceDate = now()
    }

    // MARK: - Observation

    /// Starts observing the `issues` table. Safe to call more than once.
    func startObserving() {
        guard observationTask == nil else { return }
        // Two things are stated here rather than left to the filter's defaults. `now` is stated
        // once, because the filter is the observation's key and a predicate that read the clock
        // would re-bucket rows underneath the view; `includeClosed` is stated because the section
        // is the place a ⌘K hit on a closed issue lands (ADR 0032's 2026-09-04 amendment), and a
        // row the observation never carries is a row ``reveal(issueID:)`` can only wait for. What
        // reaches the screen is ``stateFilter``'s business, and it starts at open.
        let stream = database.observeIssues(filter: IssueFilter(now: now(), includeClosed: true))
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
        stateScopedRows.filter { row in
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

    /// The rows the state facet has left, and the set the other four facets are counted over.
    ///
    /// A step of its own rather than one more line inside ``filteredRows``, because the counts
    /// read it too: with the default selection every number in the rail is the number it was
    /// before closed rows were observed at all, and with *Closed* selected the labels, ages and
    /// repositories describe the closed rows rather than a total nothing on screen adds up to.
    var stateScopedRows: [IssueRowSummary] {
        guard let stateFilter else { return allRows }
        return allRows.filter { stateFilter.matches($0) }
    }

    /// Every visible row in display order — the order `j`/`k` walks.
    var visibleRows: [IssueRowSummary] { filteredRows }

    /// The selected row, if it is still visible.
    var selectedRow: IssueRowSummary? {
        guard let selectedID else { return nil }
        return visibleRows.first { $0.id == selectedID }
    }

    /// Whether any facet is narrowing the list, which is what tells the two empty states apart.
    ///
    /// The state facet counts only when it is narrower than the section's own default: `.open`
    /// *is* that default, and `nil` widens the list rather than narrowing it, so neither is
    /// something a user has to be told to clear.
    var hasActiveFacet: Bool {
        if let stateFilter, stateFilter != .open { return true }
        return repoFilter != nil || labelFilter != nil || ageFilter != nil
            || agentPullRequestFilter != nil
    }

    /// Clears every facet — the header's ✕ and Escape.
    ///
    /// The state facet goes to `nil` rather than back to `.open`, which is what makes "clear the
    /// facets" mean *show me everything* on this side too: it is the widening step
    /// ``reveal(issueID:)`` relies on, and a ⌘K hit on a closed issue would otherwise clear four
    /// facets and still land on a row the fifth is hiding.
    func clearFacets() {
        // The state facet goes first, and the order is not cosmetic: each of these five
        // assignments clamps the selection, so clearing the widest axis last would run four
        // clamps against a list that still hides a closed row — and a clamp that lands on the
        // first row of the section loads that row's body for nobody.
        stateFilter = nil
        repoFilter = nil
        labelFilter = nil
        ageFilter = nil
        agentPullRequestFilter = nil
    }

    // MARK: - Facets

    /// The repositories present in the section, with counts.
    ///
    /// Counted over ``stateScopedRows`` rather than over the list the rail has finished
    /// narrowing, which is the pull-request rail's arrangement for its own reason: a facet whose
    /// counts changed when you selected one of its own rows could not be used to compare them.
    /// The state facet is the single exception to "the whole section", and it is why this is not
    /// simply ``allRows`` — these four describe whichever half of the section the state facet has
    /// chosen, so the default selection reproduces every count the rail showed before closed rows
    /// were observed and *Closed* describes the closed ones. The same goes for the three below;
    /// ``stateFacets`` is counted over everything, being its own axis.
    var repositoryFacets: [(repo: RepoRef, count: Int)] {
        var counts: [RepoRef: Int] = [:]
        for row in stateScopedRows {
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
        IssueFacets.labelFacets(stateScopedRows)
    }

    /// The age buckets present in the section, with counts.
    var ageFacets: [IssueAgeFacet] {
        IssueFacets.ageFacets(stateScopedRows, now: referenceDate)
    }

    /// The two halves of the agent-pull-request facet, when both are populated.
    var agentPullRequestFacets: [IssueAgentPullRequestFacet] {
        IssueFacets.agentPullRequestFacets(stateScopedRows)
    }

    /// The two halves of the state facet, with counts (ADR 0032's 2026-09-04 amendment).
    ///
    /// The one facet counted over ``allRows``, because it is its own axis: a *Closed* row that
    /// vanished the moment *Open* was selected would leave the retained issues reachable only
    /// through ⌘K, which is the dead end this amendment exists to close.
    var stateFacets: [IssueStateFacet] {
        IssueFacets.stateFacets(allRows)
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
        pendingWrites = []
        loadDetail()
        Task { await refreshPendingWrites() }
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
        // Selected first, then widened: `clearFacets()` sets five properties whose `didSet`
        // clamps the selection, and clamping before the cursor has moved would pick the first row
        // of the widened list and load its body for nothing. The fifth property is the state
        // facet, which is what lets a *closed* issue be revealed rather than waited for.
        select(id)
        guard !visibleRows.contains(where: { $0.id == id }) else { return }
        clearFacets()
        // And asked for once more, now that the rail is empty. Those five clamps happen one per
        // assignment, so a row two facets were hiding is still hidden while the first of them is
        // being cleared and the cursor can be moved off it on the way through. A cursor that
        // did survive makes this a no-op — ``select(_:)`` returns early when nothing changed —
        // so the body is never loaded twice.
        select(id)
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

    // MARK: - Triage writes (ADR 0006, ADR 0032's Sprint 4a amendment)

    /// The labels the section has seen in one repository, minus the ones the row already carries.
    ///
    /// What the picker offers, and it is deliberately built from rows the sweep already wrote
    /// rather than from `GET /repos/{o}/{r}/labels`: that would be a new request on every panel,
    /// for a list Shepherd is holding anyway. The price is honest and stated in the menu — a
    /// label no issue in the section carries cannot be offered, and github.com is one click away.
    /// - Parameter row: The issue the picker is for.
    /// - Returns: Label names, sorted case-insensitively so the menu order is stable.
    func availableLabels(for row: IssueRowSummary) -> [String] {
        let present = Set(row.labels)
        var seen: Set<String> = []
        for candidate in allRows where candidate.repo.isSameRepository(as: row.repo) {
            seen.formUnion(candidate.labels)
        }
        return seen.subtracting(present).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// The outbox rows targeting one issue.
    /// - Parameter row: The issue.
    func queuedWrites(for row: IssueRowSummary) -> [OutboxItem] {
        pendingWrites.filter { $0.prID == row.id }
    }

    /// How many writes are queued or in flight for one issue.
    /// - Parameter row: The issue.
    func queuedWriteCount(for row: IssueRowSummary) -> Int {
        queuedWrites(for: row).filter { $0.state == .pending || $0.state == .sending }.count
    }

    /// How many writes the drain parked for one issue because it moved on underneath them.
    /// - Parameter row: The issue.
    func parkedWriteCount(for row: IssueRowSummary) -> Int {
        queuedWrites(for: row).filter { $0.state == .conflicted }.count
    }

    /// How many writes for one issue were given up on.
    ///
    /// The third state a queued write can end in, and until now the invisible one: the drain fails
    /// an issue row **non-retriably** when there is no `IssueWriting` port wired up, and GitHub's
    /// own 4xx answers do the same. Such a row is neither waiting nor parked, so neither of the two
    /// counts above sees it — and it never goes away by itself, which is exactly why it has to be
    /// on screen rather than in a table nobody opens.
    /// - Parameter row: The issue.
    func failedWriteCount(for row: IssueRowSummary) -> Int {
        queuedWrites(for: row).filter { $0.state == .failed }.count
    }

    /// Re-reads the outbox. Cheap: one `SELECT` of a table that holds tens of rows at most.
    func refreshPendingWrites() async {
        // A read failure answers "nothing is queued", which is the same answer an empty outbox
        // gives — and the panel's pending line is a convenience, not the record.
        pendingWrites = (try? await database.allOutboxItems()) ?? []
    }

    /// Queues one issue write and asks for a drain.
    ///
    /// Every issue write in the app goes through here, exactly as every pull-request write goes
    /// through ``PullRequestActions``: ADR 0006's rule is that a mutation is written to SQLite
    /// first and executed by the sync engine, so a close queued in a tunnel is still closed when
    /// the train comes out. Nothing in this file calls `GitHubClient`.
    ///
    /// The row's three target fields carry the **issue's** node id, repository and number — see
    /// ``ShepherdCore/OutboxItem``'s own note — and the action carries the row's `updatedAt`, so
    /// the drain can refuse to send it against an issue that moved.
    /// - Parameters:
    ///   - action: What to do.
    ///   - row: The issue it targets.
    /// - Returns: `true` when the row reached the outbox.
    ///   A second call while the first is still running is `false` as well: nothing was written,
    ///   which is exactly what that answer means everywhere else here.
    @discardableResult
    func queue(_ action: OutboxAction, on row: IssueRowSummary) async -> Bool {
        // One key for every issue verb (``ActionActivity/Kind/issue``): a reviewer who has just
        // queued a close has no business queueing a label on the same issue half a second later,
        // and the panel's buttons all go quiet together as a result.
        guard let activity else { return await write(action, on: row) }
        return await activity.run(row.id, .issue) {
            await write(action, on: row)
        } ?? false
    }

    /// The body of ``queue(_:on:)``, without the in-flight bookkeeping.
    ///
    /// Split out so the tracker is optional: a model built without an ``ActionActivity`` — every
    /// test does — writes exactly as it did before there was one.
    private func write(_ action: OutboxAction, on row: IssueRowSummary) async -> Bool {
        do {
            try await database.enqueue(
                OutboxItem(prID: row.id, repo: row.repo, number: row.number, action: action)
            )
        } catch {
            return false
        }
        await refreshPendingWrites()
        await drain?()
        await refreshPendingWrites()
        return true
    }

    /// Queues a comment on the issue.
    /// - Parameters:
    ///   - body: The comment as Markdown source.
    ///   - row: The issue.
    /// - Returns: `true` when the row reached the outbox.
    @discardableResult
    func comment(_ body: String, on row: IssueRowSummary) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await queue(
            .addIssueComment(body: trimmed, basedOnUpdatedAt: row.updatedAt),
            on: row
        )
    }

    /// Queues one label.
    /// - Parameters:
    ///   - name: The label name, exactly as GitHub spells it.
    ///   - row: The issue.
    /// - Returns: `true` when the row reached the outbox.
    @discardableResult
    func addLabel(_ name: String, on row: IssueRowSummary) async -> Bool {
        await queue(.addIssueLabel(name: name, basedOnUpdatedAt: row.updatedAt), on: row)
    }

    /// Queues an assignment of the issue to the signed-in user.
    /// - Parameter row: The issue.
    /// - Returns: `true` when the row reached the outbox; `false` when nobody is signed in.
    @discardableResult
    func assignToMe(_ row: IssueRowSummary) async -> Bool {
        guard let viewerLogin, !viewerLogin.isEmpty else { return false }
        return await queue(
            .addIssueAssignee(login: viewerLogin, basedOnUpdatedAt: row.updatedAt),
            on: row
        )
    }

    /// Queues a close.
    /// - Parameters:
    ///   - reason: Completed, or not planned.
    ///   - row: The issue.
    /// - Returns: `true` when the row reached the outbox.
    @discardableResult
    func close(_ reason: IssueCloseReason, on row: IssueRowSummary) async -> Bool {
        await queue(.closeIssue(reason: reason, basedOnUpdatedAt: row.updatedAt), on: row)
    }

    /// Queues a reopen.
    /// - Parameter row: The issue.
    /// - Returns: `true` when the row reached the outbox.
    @discardableResult
    func reopen(_ row: IssueRowSummary) async -> Bool {
        await queue(.reopenIssue(basedOnUpdatedAt: row.updatedAt), on: row)
    }
}
