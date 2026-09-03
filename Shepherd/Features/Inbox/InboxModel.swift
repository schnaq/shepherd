import Foundation
import Observation
import ShepherdCore
import ShepherdPersistence
import SwiftUI

/// The smart views in the left rail.
enum SmartView: String, CaseIterable, Identifiable, Sendable {
    /// Pull requests that explicitly asked for the user's review.
    case needsMyReview
    /// Pull requests the user opened.
    case myPullRequests
    /// Everything the user is involved in.
    case involved
    /// Pull requests that already carry an approval.
    case approvedByMe

    var id: String { rawValue }

    /// The rail label.
    var title: String {
        switch self {
        case .needsMyReview: return String(localized: "Needs my review")
        case .myPullRequests: return String(localized: "My pull requests")
        case .involved: return String(localized: "Involved")
        case .approvedByMe: return String(localized: "Approved by me")
        }
    }

    /// The SF Symbol shown in front of the label.
    var systemImage: String {
        switch self {
        case .needsMyReview: return "tray.and.arrow.down"
        case .myPullRequests: return "point.3.connected.trianglepath.dotted"
        case .involved: return "clock"
        case .approvedByMe: return "checkmark"
        }
    }

    /// Whether a row belongs to this view.
    ///
    /// - Note: "Approved by me" is an approximation: GitHub's search facets do not expose
    ///   "I approved this", so Shepherd shows pull requests the user was asked to review that
    ///   now carry an approval. The heuristic is documented in the rail's tooltip.
    /// - Parameter row: The inbox row.
    func matches(_ row: PullRequestSummary) -> Bool {
        switch self {
        case .needsMyReview:
            // Delegated to the model, which is where the one definition of "needs my review"
            // lives: the menu-bar badge, the focus session's queue and the morning digest read the
            // same property, so none of the four can drift from the rail's count.
            return row.needsMyReview
        case .myPullRequests:
            return row.myRelation.contains(.author)
        case .involved:
            return true
        case .approvedByMe:
            return row.reviewDecision == .approved && !row.myRelation.contains(.author)
        }
    }
}

/// Which provenance facet the rail has selected.
enum ProvenanceFilter: Hashable, Sendable {
    /// One detected agent.
    case agent(id: String)
    /// Generic bot accounts.
    case bots
    /// Human authors.
    case humans

    /// Whether a row matches.
    func matches(_ row: PullRequestSummary) -> Bool {
        switch (self, row.author.kind) {
        case (.agent(let id), .agent(let identity)): return identity.id == id
        case (.bots, .bot): return true
        case (.humans, .human): return true
        default: return false
        }
    }
}

/// The rail state one `shepherd://inbox?filter=…` token asks for (ADR 0013).
///
/// A pure value so the mapping is testable without a session: the model only assigns it.
struct InboxRailSelection: Equatable {
    /// The smart view to select.
    var smartView: SmartView
    /// The provenance facet, if the token names one.
    var provenanceFilter: ProvenanceFilter?
    /// The repository facet, if the token names one.
    var repoFilter: RepoRef?

    /// Maps a deep-link filter onto rail state.
    ///
    /// A *view* token replaces the whole selection. A *facet* token (provenance or repository)
    /// additionally widens the smart view to "Involved", because `filter=agent:claude-code`
    /// means "everything that agent sent me" — keeping whichever smart view happened to be
    /// selected would answer a different question, and an empty list looks like a broken link.
    /// - Parameter filter: The filter from the link.
    init(_ filter: InboxDeepLinkFilter) {
        switch filter {
        case .needsMyReview:
            self.init(smartView: .needsMyReview)
        case .myPullRequests:
            self.init(smartView: .myPullRequests)
        case .involved:
            self.init(smartView: .involved)
        case .approvedByMe:
            self.init(smartView: .approvedByMe)
        case .humans:
            self.init(smartView: .involved, provenanceFilter: .humans)
        case .bots:
            self.init(smartView: .involved, provenanceFilter: .bots)
        case .agent(let id):
            self.init(smartView: .involved, provenanceFilter: .agent(id: id))
        case .repository(let repo):
            self.init(smartView: .involved, repoFilter: repo)
        }
    }

    /// Creates a selection.
    /// - Parameters:
    ///   - smartView: The smart view.
    ///   - provenanceFilter: The provenance facet, if any.
    ///   - repoFilter: The repository facet, if any.
    init(
        smartView: SmartView,
        provenanceFilter: ProvenanceFilter? = nil,
        repoFilter: RepoRef? = nil
    ) {
        self.smartView = smartView
        self.provenanceFilter = provenanceFilter
        self.repoFilter = repoFilter
    }
}

/// The inbox rows ticked for a bulk action (ADR 0015).
///
/// A pure value for the same reason ``KeySequenceState`` and ``InboxRailSelection`` are: the
/// interesting parts — range extension from the cursor, and pruning to what is on screen —
/// are exactly the parts that must not be discovered by hand in a window.
struct InboxMarkSelection: Equatable, Sendable {
    private(set) var ids: Set<String> = []

    /// Creates a selection.
    /// - Parameter ids: The initially ticked ids.
    init(ids: Set<String> = []) {
        self.ids = ids
    }

    /// Whether nothing is ticked.
    var isEmpty: Bool { ids.isEmpty }

    /// How many rows are ticked.
    var count: Int { ids.count }

    /// Whether one row is ticked.
    /// - Parameter id: The pull request's node id.
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Ticks or unticks one row.
    /// - Parameter id: The pull request's node id.
    mutating func toggle(_ id: String) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
    }

    /// Ticks every row between `anchor` and `id`, inclusive.
    ///
    /// Without a usable anchor this ticks the one row: a shift-click with no cursor is still a
    /// click, and doing nothing at all would read as a dead row.
    /// - Parameters:
    ///   - id: The row that was shift-clicked.
    ///   - anchor: The cursor row, if there is one.
    ///   - order: The rows in display order.
    mutating func extend(to id: String, from anchor: String?, in order: [String]) {
        guard let end = order.firstIndex(of: id) else { return }
        guard let anchor, let start = order.firstIndex(of: anchor) else {
            ids.insert(id)
            return
        }
        ids.formUnion(order[min(start, end)...max(start, end)])
    }

    /// Adds rows without removing anything — the "select all green agent PRs" preselect.
    /// - Parameter added: The ids to tick.
    mutating func insert(contentsOf added: [String]) {
        ids.formUnion(added)
    }

    /// Drops ticks on rows that are no longer on screen.
    ///
    /// Called whenever the list changes, so a bulk action can only ever act on rows the user can
    /// actually see — a merged pull request, or one filtered away by the rail, silently
    /// disappears from the selection instead of silently staying in it.
    /// - Parameter visible: The ids currently displayed.
    mutating func prune(to visible: [String]) {
        guard !ids.isEmpty else { return }
        ids.formIntersection(visible)
    }

    /// Unticks everything.
    mutating func removeAll() {
        ids.removeAll()
    }
}

/// Drives the three-pane inbox.
///
/// Everything it renders comes from the database via `ValueObservation` (ADR 0006); the sync
/// engine writes, GRDB notices, this model re-publishes. Nothing here calls GitHub to *read*
/// the list.
@MainActor
@Observable
final class InboxModel {
    /// The active session.
    let session: SignedInSession
    /// User preferences (grouping, sorting).
    let settings: AppSettings

    /// Every row the database holds.
    private(set) var allRows: [PullRequestSummary] = []
    /// Whether the first observation value has arrived.
    private(set) var hasLoaded = false

    /// The selected smart view.
    var smartView: SmartView = .needsMyReview {
        didSet { clampSelection() }
    }
    /// The selected provenance facet, if any.
    var provenanceFilter: ProvenanceFilter? {
        didSet { clampSelection() }
    }
    /// The selected repository facet, if any.
    var repoFilter: RepoRef? {
        didSet { clampSelection() }
    }
    /// The selected risk facet, if any (ADR 0023).
    ///
    /// A fourth rail filter beside the three above, and it composes with them rather than
    /// replacing them: "high risk, in this repository, that needs my review" is the question the
    /// facet exists for. It filters on ``TriageCoordinator/risk(for:)``, which is the model's
    /// verdict where there is one and the tier-1 heuristic where there is not — so the facet
    /// keeps working with Apple Intelligence off.
    var riskFilter: TriageVerdict.Risk? {
        didSet { clampSelection() }
    }
    /// The selected row's pull request id — the keyboard cursor, always exactly one row.
    var selectedID: String?
    /// The rows ticked for a bulk action (ADR 0015).
    ///
    /// Deliberately separate from ``selectedID``: the cursor drives `j`/`k` and the detail
    /// panel, the ticks drive bulk triage, and conflating them would make "approve the
    /// selection" mean two different things.
    private(set) var marks = InboxMarkSelection()
    /// The local drafts of the ticked rows, read when a bulk dialog is about to open.
    ///
    /// Only the dialog's notes need them — a draft whose inline comments hang off an older
    /// commit would be parked instead of sent, and the user is owed that *before* the confirm
    /// (ADR 0015). The actual writes read the drafts again in `PullRequestActions`, which is the
    /// read that matters: this one is allowed to be a little behind.
    private(set) var markedDrafts: [String: ReviewDraft] = [:]

    /// The detail of the selected row, from the local cache.
    private(set) var detail: PullRequestDetail?
    /// Deterministic file priorities for the selected row (tier 1, always on).
    private(set) var priorities: [FilePriority] = []
    /// The AI summary card's state.
    private(set) var summaryOutcome: IntelligenceOutcome<PRSummary> = .disabled
    /// The provider router, refreshed by the view whenever Settings change.
    var intelligence: IntelligenceRouter = .disabled
    /// The structured-triage verdicts, handed over by the screen (ADR 0023).
    ///
    /// A reference rather than a copy, and optional so the model can be built — and tested —
    /// without one: the coordinator is owned by ``AppEnvironment`` because a verdict belongs to
    /// the app's lifetime rather than to a screen's, and every screen that shows a chip reads the
    /// same one. Assigned exactly where ``intelligence`` is, in ``InboxScreen``'s `task`.
    var triage: TriageCoordinator?
    /// Whether a detail refresh is in flight.
    private(set) var isRefreshingDetail = false
    /// What each row says about the rounds it has been reviewed in (ADR 0028).
    ///
    /// Keyed by node id and filled in in the background: the numbers come from the local
    /// snapshots table and an interdiff computed on this Mac, so a list with none of them is a
    /// list nobody has reviewed twice yet, not a list that is still loading.
    private(set) var reviewRoundsByID: [String: ReviewRoundsSummary] = [:]

    /// The two-keystroke state machine (`r a`, `g r`, …).
    var keySequence = KeySequenceState()

    private var observationTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var intelligenceTask: Task<Void, Never>?
    private var roundsTask: Task<Void, Never>?
    /// The rows the rounds chips were last computed for, as `id:head` pairs.
    private var roundsSignature = ""

    /// Creates the model.
    /// - Parameters:
    ///   - session: The signed-in session.
    ///   - settings: The preference store.
    init(session: SignedInSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
    }

    // MARK: - Observation

    /// Starts observing the inbox table. Safe to call more than once.
    func startObserving() {
        guard observationTask == nil else { return }
        let stream = session.database.observeInbox()
        observationTask = Task { [weak self] in
            for await rows in stream {
                guard let self else { return }
                self.allRows = rows
                self.hasLoaded = true
                self.clampSelection()
                self.refreshReviewRounds()
            }
        }
    }

    /// Stops observing.
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        detailTask?.cancel()
        detailTask = nil
        intelligenceTask?.cancel()
        intelligenceTask = nil
        roundsTask?.cancel()
        roundsTask = nil
    }

    /// Recomputes the rounds chips, but only when the rows they describe have moved.
    ///
    /// The inbox observation speaks on every write, and the interdiff is real work; the
    /// signature is the cheap gate — a chip can only change when a pull request appears,
    /// disappears or gets a new head (ADR 0028).
    private func refreshReviewRounds() {
        let signature = allRows.map { "\($0.id):\($0.headRefOid)" }.joined(separator: ",")
        guard signature != roundsSignature else { return }
        roundsSignature = signature
        let rows = allRows
        let database = session.database
        let viewerLogin = session.account.login
        roundsTask?.cancel()
        roundsTask = Task { [weak self] in
            let rounds = await SinceReviewLoader.rounds(
                database: database,
                rows: rows,
                viewerLogin: viewerLogin
            )
            guard let self, !Task.isCancelled else { return }
            self.reviewRoundsByID = rounds
        }
    }

    /// What one row shows about its review rounds, or `nil` when it has never been reviewed here.
    /// - Parameter id: The pull request's node id.
    func reviewRounds(for id: String) -> ReviewRoundsSummary? {
        reviewRoundsByID[id]
    }

    // MARK: - Derived state

    /// The rows the centre list shows, after every rail filter.
    var filteredRows: [PullRequestSummary] {
        allRows.filter { row in
            guard smartView.matches(row) else { return false }
            if let provenanceFilter, !provenanceFilter.matches(row) { return false }
            // Case-insensitive: the rail always sets this from a row it is showing, but a
            // `shepherd://inbox?filter=repo:…` link carries whatever casing was typed.
            if let repoFilter, !row.repo.isSameRepository(as: repoFilter) { return false }
            // A row with no risk at all — nobody has opened it, so there is no diff to judge and
            // no verdict — is filtered *out* rather than kept: the facet is a claim about risk,
            // and "we do not know" is not one of its levels.
            if let riskFilter, triage?.risk(for: row.id) != riskFilter { return false }
            return true
        }
    }

    /// The grouped sections, ordered by the user's sort choice.
    var sections: [InboxSection] {
        InboxGrouper.group(filteredRows, by: settings.groupBy).map { section in
            InboxSection(
                id: section.id,
                title: section.title,
                facet: section.facet,
                items: order(section.items)
            )
        }
    }

    /// Every visible row in display order — the order `j`/`k` walks.
    var visibleRows: [PullRequestSummary] {
        sections.flatMap(\.items)
    }

    /// The selected row, if it is still visible.
    var selectedRow: PullRequestSummary? {
        guard let selectedID else { return nil }
        return visibleRows.first { $0.id == selectedID }
    }

    /// The rail counts for the smart views.
    func count(for view: SmartView) -> Int {
        allRows.filter(view.matches).count
    }

    /// The provenance facets present in the current data, with counts.
    var provenanceFacets: [(filter: ProvenanceFilter, title: String, color: Color, count: Int)] {
        var agents: [String: (title: String, count: Int)] = [:]
        var botCount = 0
        var humanCount = 0
        for row in allRows where smartView.matches(row) {
            switch row.author.kind {
            case .agent(let identity):
                let existing = agents[identity.id] ?? (identity.displayName, 0)
                agents[identity.id] = (existing.title, existing.count + 1)
            case .bot:
                botCount += 1
            case .human:
                humanCount += 1
            }
        }
        var result = agents
            .map { id, value in
                (
                    filter: ProvenanceFilter.agent(id: id),
                    title: value.title,
                    color: AgentPalette.color(forAgentID: id),
                    count: value.count
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.title.lowercased() < rhs.title.lowercased()
            }
        if botCount > 0 {
            result.append((.bots, String(localized: "Bots"), Theme.textSecondary, botCount))
        }
        if humanCount > 0 {
            result.append((.humans, String(localized: "Humans"), Theme.accent, humanCount))
        }
        return result
    }

    /// The risk levels present in the current smart view, with counts (ADR 0023).
    ///
    /// Counted over the smart view rather than over the filtered list, exactly as the agents and
    /// repositories facets are: a facet whose counts changed when you selected one of its own
    /// rows could not be used to compare them.
    ///
    /// The counting itself is ``ShepherdCore/TriageFacets/riskFacets(_:)`` — pure, and unit-tested
    /// on Linux — because "how many high-risk pull requests are there" is a number the user reads
    /// off the rail and acts on.
    var riskFacets: [TriageRiskFacet] {
        guard let triage else { return [] }
        let ids = allRows.filter { smartView.matches($0) }.map(\.id)
        return triage.riskFacets(for: ids)
    }

    /// What one row shows beside its title, or `nil` when there is nothing to show.
    /// - Parameter id: The pull request's node id.
    func triageSummary(for id: String) -> TriageRowSummary? {
        triage?.row(for: id)
    }

    /// The repositories present in the current data, with counts.
    var repositoryFacets: [(repo: RepoRef, count: Int)] {
        var counts: [RepoRef: Int] = [:]
        for row in allRows where smartView.matches(row) {
            counts[row.repo, default: 0] += 1
        }
        return counts
            .map { (repo: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.repo < rhs.repo
            }
    }

    private func order(_ rows: [PullRequestSummary]) -> [PullRequestSummary] {
        switch settings.sortOrder {
        case .recentlyUpdated:
            return InboxGrouper.sorted(rows)
        case .oldestFirst:
            return Array(InboxGrouper.sorted(rows).reversed())
        case .priority:
            return InboxModel.prioritySorted(rows)
        }
    }

    /// The rows in the deterministic "what should I look at first" order.
    ///
    /// Split out of ``order(_:)`` because the menu-bar quick inbox needs the same order for its
    /// top eight (``MenuBarQuickInbox``), and two implementations of "most urgent first" would
    /// eventually disagree about which pull request that is.
    /// - Parameter rows: The rows to order.
    /// - Returns: The rows, most urgent first.
    nonisolated static func prioritySorted(
        _ rows: [PullRequestSummary]
    ) -> [PullRequestSummary] {
        rows.sorted { lhs, rhs in
            let left = priorityScore(lhs)
            let right = priorityScore(rhs)
            if left != right { return left > right }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    /// The deterministic "what should I look at first" score used by the priority sort.
    ///
    /// Purely local, purely predictable — the same inputs always produce the same order, which
    /// is what keeps the inbox from reshuffling itself between two sweeps.
    nonisolated static func priorityScore(_ row: PullRequestSummary) -> Int {
        var score = 0
        if row.myRelation.contains(.reviewRequested) { score += 100 }
        if row.reviewDecision == .changesRequested { score += 25 }
        if row.checkRollup?.state == .failure { score += 20 }
        if row.myRelation.contains(.assigned) { score += 10 }
        if row.isDraft { score -= 40 }
        if row.reviewDecision == .approved { score -= 30 }
        return score
    }

    // MARK: - Deep links

    /// Applies a rail filter that arrived from a `shepherd://inbox?filter=…` link (ADR 0013).
    ///
    /// The mapping itself is ``InboxRailSelection``, so it can be tested without a session.
    /// - Parameter filter: The filter from the link.
    func apply(_ filter: InboxDeepLinkFilter) {
        let selection = InboxRailSelection(filter)
        smartView = selection.smartView
        provenanceFilter = selection.provenanceFilter
        repoFilter = selection.repoFilter
        // The link's grammar has no risk token (ADR 0013 is unchanged by ADR 0023), so a risk
        // facet left selected from before would silently narrow what the link asked for — and an
        // empty list looks like a broken link, which is the argument the whole mapping makes.
        riskFilter = nil
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
    /// - Parameter id: The pull request's node id.
    func select(_ id: String?) {
        guard selectedID != id else { return }
        selectedID = id
        detail = nil
        priorities = []
        summaryOutcome = .disabled
        loadDetail()
    }

    private func clampSelection() {
        let rows = visibleRows
        // A tick on a row that has left the view — merged, filtered out, or on another smart
        // view — is dropped rather than carried invisibly into the next bulk action.
        marks.prune(to: rows.map(\.id))
        if let selectedID, rows.contains(where: { $0.id == selectedID }) { return }
        select(rows.first?.id)
    }

    // MARK: - Bulk triage (ADR 0015)

    /// Whether anything is ticked, which is also what makes the tick column appear.
    var hasMarks: Bool { !marks.isEmpty }

    /// The ticked pull-request ids.
    var markedIDs: Set<String> { marks.ids }

    /// The ticked rows, in display order.
    var markedRows: [PullRequestSummary] {
        markedRows(in: visibleRows)
    }

    /// The ticked rows of a list the caller already has, in the order given.
    ///
    /// The parameter is the point of this overload. ``visibleRows`` is the whole filter → group →
    /// sort pipeline over every cached pull request, and it is a computed property with no cache
    /// behind it, so a caller holding the rows already hands them in rather than making the
    /// pipeline run a second time.
    /// - Parameter rows: The rows to filter, in display order.
    /// - Returns: The ticked subset.
    func markedRows(in rows: [PullRequestSummary]) -> [PullRequestSummary] {
        rows.filter { marks.contains($0.id) }
    }

    /// Ticks or unticks one row.
    /// - Parameter id: The pull request's node id.
    func toggleMark(_ id: String) {
        marks.toggle(id)
    }

    /// Ticks every row between the cursor and `id`, inclusive — shift-click.
    /// - Parameter id: The row that was shift-clicked.
    func extendMarks(to id: String) {
        let rows = visibleRows
        marks.extend(to: id, from: selectedID, in: rows.map(\.id))
    }

    /// Ticks the green, agent-authored rows of the current view (ADR 0015).
    /// - Returns: How many rows the preselect found.
    @discardableResult
    func markGreenAgentRows() -> Int {
        let rows = visibleRows
        let green = BulkTriagePlan.greenAgentPullRequests(in: rows)
        marks.insert(contentsOf: green.map(\.id))
        return green.count
    }

    /// Unticks everything.
    func clearMarks() {
        marks.removeAll()
        markedDrafts = [:]
    }

    /// Reads the local drafts of the ticked rows, in one query, for the dialog's notes.
    ///
    /// A read failure yields no drafts rather than an error, exactly as the write path does: the
    /// run is still queueable, it simply cannot warn about a stale draft.
    func loadMarkedDrafts() async {
        let ids = Array(marks.ids)
        guard !ids.isEmpty else {
            markedDrafts = [:]
            return
        }
        markedDrafts = (try? await session.database.fetchDrafts(prIDs: ids)) ?? [:]
    }

    /// The plan a bulk action amounts to for what is currently ticked.
    ///
    /// Rebuilt on demand from the rows the database last handed over, so a dialog that is open
    /// while a sweep lands shows the new state instead of a stale snapshot.
    /// - Parameter action: The action the user asked for.
    /// - Returns: The partitioned plan.
    func bulkPlan(for action: BulkTriageAction) -> BulkTriagePlan {
        let rows = visibleRows
        return BulkTriagePlan.make(
            action: action,
            pullRequests: markedRows(in: rows),
            existingDrafts: markedDrafts
        )
    }

    // MARK: - Detail

    /// Loads the selected pull request from the cache and refreshes it from GitHub.
    func loadDetail() {
        detailTask?.cancel()
        intelligenceTask?.cancel()
        guard let selectedID, let row = allRows.first(where: { $0.id == selectedID }) else { return }

        detailTask = Task { [weak self] in
            guard let self else { return }
            if let cached = try? await self.session.database.fetchPullRequestDetail(id: selectedID) {
                self.apply(detail: cached)
            }
            self.isRefreshingDetail = true
            defer { self.isRefreshingDetail = false }
            do {
                let fresh = try await self.session.github.pullRequestDetail(
                    repo: row.repo,
                    number: row.number
                )
                try? await self.session.database.savePullRequestDetail(fresh)
                guard !Task.isCancelled, self.selectedID == selectedID else { return }
                self.apply(detail: fresh)
            } catch {
                // Offline is a normal state: the cached copy above is what the user sees.
                if self.detail == nil {
                    self.summaryOutcome = .disabled
                }
            }
        }
    }

    private func apply(detail: PullRequestDetail) {
        self.detail = detail
        priorities = FilePrioritizer.prioritize(
            detail.files,
            context: PrioritizationContext(totalChangedLines: detail.summary.churn)
        )
        guard intelligence.isEnabled else {
            summaryOutcome = .disabled
            return
        }
        let id = detail.id
        let router = intelligence
        intelligenceTask?.cancel()
        intelligenceTask = Task { [weak self] in
            let outcome = await router.summary(for: detail)
            guard let self, !Task.isCancelled, self.detail?.id == id else { return }
            self.summaryOutcome = outcome
        }
    }
}
