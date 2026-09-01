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
            return row.myRelation.contains(.reviewRequested) && row.reviewDecision != .approved
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
    /// The selected row's pull request id.
    var selectedID: String?

    /// The detail of the selected row, from the local cache.
    private(set) var detail: PullRequestDetail?
    /// Deterministic file priorities for the selected row (tier 1, always on).
    private(set) var priorities: [FilePriority] = []
    /// The AI summary card's state.
    private(set) var summaryOutcome: IntelligenceOutcome<PRSummary> = .disabled
    /// The provider router, refreshed by the view whenever Settings change.
    var intelligence: IntelligenceRouter = .disabled
    /// Whether a detail refresh is in flight.
    private(set) var isRefreshingDetail = false

    /// The two-keystroke state machine (`r a`, `g r`, …).
    var keySequence = KeySequenceState()

    private var observationTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var intelligenceTask: Task<Void, Never>?

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
            return rows.sorted { lhs, rhs in
                let left = InboxModel.priorityScore(lhs)
                let right = InboxModel.priorityScore(rhs)
                if left != right { return left > right }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
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
        if let selectedID, rows.contains(where: { $0.id == selectedID }) { return }
        select(rows.first?.id)
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
