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
///
/// `Codable` for one caller: ``InboxModel/RailState`` writes the rail into scene storage so it
/// survives the screen being rebuilt (ADR 0013). The synthesized shape is nobody's contract — it
/// is read back only by the build that wrote it, and a string that will not decode simply means
/// "no rail to restore" — which is why it is synthesized rather than spelled out a second time
/// beside ``InboxDeepLinkFilter``'s token vocabulary.
enum ProvenanceFilter: Hashable, Sendable, Codable {
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
    /// The smart view to select, or `nil` when the token names no pull-request rail state at all.
    ///
    /// Exactly one token answers `nil`: `filter=issues` names the inbox *section* rather than a
    /// rail state (ADR 0032). Making it widen the pull-request rail — the way a facet token
    /// does — would silently change what the user comes back to when they move the picker back,
    /// and a link that asked for the issues section has said nothing about pull requests.
    var smartView: SmartView?
    /// The provenance facet, if the token names one.
    var provenanceFilter: ProvenanceFilter?
    /// The repository facet, if the token names one.
    var repoFilter: RepoRef?
    /// Which section the token asks the screen to show (ADR 0032).
    var contentKind: ContentKind

    /// Maps a deep-link filter onto rail state.
    ///
    /// A *view* token replaces the whole selection. A *facet* token (provenance or repository)
    /// additionally widens the smart view to "Involved", because `filter=agent:claude-code`
    /// means "everything that agent sent me" — keeping whichever smart view happened to be
    /// selected would answer a different question, and an empty list looks like a broken link.
    /// The *section* token moves the picker and touches nothing else.
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
        case .issues:
            self.init(smartView: nil, contentKind: .issues)
        }
    }

    /// Creates a selection.
    /// - Parameters:
    ///   - smartView: The smart view, or `nil` to leave the pull-request rail alone.
    ///   - provenanceFilter: The provenance facet, if any.
    ///   - repoFilter: The repository facet, if any.
    ///   - contentKind: Which section to show.
    init(
        smartView: SmartView?,
        provenanceFilter: ProvenanceFilter? = nil,
        repoFilter: RepoRef? = nil,
        contentKind: ContentKind = .pullRequests
    ) {
        self.smartView = smartView
        self.provenanceFilter = provenanceFilter
        self.repoFilter = repoFilter
        self.contentKind = contentKind
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
    /// The selected trust lane, if any (ADR 0027).
    ///
    /// A fifth rail filter, composing with the four above exactly as the risk facet does: "the
    /// short looks in this repository" is the question the lane exists for. Unlike the risk
    /// facet, a row with nothing computed for it is *kept* rather than filtered out — the lane
    /// has no unknown state, because ``TrustLaneSnapshot/lane(for:)`` answers "full review" for
    /// anything it has not classified.
    var laneFilter: TrustLane? {
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
    /// The coordinator that owns the track-record backfill and the stored history (ADR 0027).
    ///
    /// A reference rather than a copy and optional for ``triage``'s reason, twice over: the run
    /// belongs to the app's lifetime rather than to a screen's, and a model built in a test has
    /// no app around it to take one from. Assigned in the same place ``triage`` is. Only the
    /// notice reads it — the badges themselves come from ``trust``, which is recomputed from the
    /// table on every refresh, because a coordinator holding a copy of them could only ever be a
    /// second answer to the same question.
    var trackRecordCoordinator: TrackRecordCoordinator?
    /// Whether a detail refresh is in flight.
    private(set) var isRefreshingDetail = false
    /// The return address of each row whose cached head commits carry one (ADR 0030).
    ///
    /// Keyed by node id and filled in in the background from the local rows, like
    /// ``reviewRoundsByID``: a row with no entry is a row whose detail Shepherd has not read yet
    /// or whose commits carry no `Claude-Session:` trailer, never a row that is still loading.
    private(set) var sessionsByID: [String: SessionReference] = [:]
    /// What each row says about the rounds it has been reviewed in (ADR 0028).
    ///
    /// Keyed by node id and filled in in the background: the numbers come from the local
    /// snapshots table and an interdiff computed on this Mac, so a list with none of them is a
    /// list nobody has reviewed twice yet, not a list that is still loading.
    private(set) var reviewRoundsByID: [String: ReviewRoundsSummary] = [:]
    /// The lanes and the track records the list is currently showing (ADR 0027).
    ///
    /// One value, replaced whole, for ``TrustLaneSnapshot``'s reason: the lanes and the badges are
    /// read off the same rows in the same render, and half of one refresh beside half of another
    /// would put a pull request under a header its badge was not counted for.
    private(set) var trust: TrustLaneSnapshot = .empty

    /// Every row the outbox is holding — queued, in flight, parked or failed (ADR 0006).
    ///
    /// Observed rather than re-read after each write, unlike ``IssueInboxModel/pendingWrites``
    /// (``ShepherdPersistence/DatabaseManager/observeOutboxItems()`` explains why the two sides
    /// differ). The consequence worth naming on this side is that the queue announces itself, so
    /// an unattended merge shows up in the panel without the panel knowing that automation
    /// exists.
    ///
    /// The whole outbox rather than one pull request's rows, because the observation is per
    /// model and the selection moves with `j`/`k`: re-subscribing on every cursor move would
    /// trade one `SELECT` per outbox write for one per keystroke, over a table that holds tens
    /// of rows.
    private(set) var outboxItems: [OutboxItem] = []

    /// The two-keystroke state machine (`r a`, `g r`, …).
    var keySequence = KeySequenceState()

    private var observationTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var intelligenceTask: Task<Void, Never>?
    private var roundsTask: Task<Void, Never>?
    private var sessionsTask: Task<Void, Never>?
    private var trustTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?
    /// The rows the rounds chips were last computed for, as `id:head` pairs.
    private var roundsSignature = ""
    /// The rows the session glyphs were last read for, as `id:head` pairs.
    private var sessionsSignature = ""

    /// Creates the model.
    /// - Parameters:
    ///   - session: The signed-in session.
    ///   - settings: The preference store.
    init(session: SignedInSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
    }

    // MARK: - Observation

    /// Starts observing the inbox table and the outbox. Safe to call more than once.
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
                self.refreshSessionReferences()
                self.refreshTrustLanes()
            }
        }
        let writes = session.database.observeOutboxItems()
        outboxTask = Task { [weak self] in
            for await items in writes {
                guard let self else { return }
                self.outboxItems = items
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
        sessionsTask?.cancel()
        sessionsTask = nil
        trustTask?.cancel()
        trustTask = nil
        outboxTask?.cancel()
        outboxTask = nil
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

    /// Re-reads the return addresses, but only when the rows they describe have moved.
    ///
    /// The same cheap gate as ``refreshReviewRounds()``, for the same reason: the inbox
    /// observation speaks on every write, and a glyph can only change when a pull request
    /// appears, disappears or gets a new head commit (ADR 0030).
    private func refreshSessionReferences() {
        let signature = allRows.map { "\($0.id):\($0.headRefOid)" }.joined(separator: ",")
        guard signature != sessionsSignature else { return }
        sessionsSignature = signature
        let rows = allRows
        let database = session.database
        sessionsTask?.cancel()
        sessionsTask = Task { [weak self] in
            let references = await SessionReturnAddressLoader.references(
                database: database,
                rows: rows
            )
            guard let self, !Task.isCancelled else { return }
            self.sessionsByID = references
        }
    }

    /// The session a row can be answered at, or `nil` when it has no return address (ADR 0030).
    /// - Parameter id: The pull request's node id.
    func sessionReference(for id: String) -> SessionReference? {
        sessionsByID[id]
    }

    /// What one row shows about its review rounds, or `nil` when it has never been reviewed here.
    /// - Parameter id: The pull request's node id.
    func reviewRounds(for id: String) -> ReviewRoundsSummary? {
        reviewRoundsByID[id]
    }

    /// Recomputes the lanes and the badges.
    ///
    /// Deliberately **without** the signature gate ``refreshReviewRounds()`` has, and the
    /// difference is the inputs rather than the cost. A rounds chip is a function of the rows and
    /// their heads, so a signature over those is exact. A lane is a function of the rows *and* of
    /// `changed_files` — the sensitive-path exclusion is about paths — and a detail fetch that
    /// stores a diff changes nothing a ``ShepherdCore/PullRequestSummary`` can describe. A
    /// signature over the rows would therefore go stale at exactly the moment the lane finally
    /// becomes knowable, and a pull request would sit under *Full review* until its next push.
    ///
    /// Recomputing instead costs two indexed `SELECT`s and some counting in Swift, with the
    /// previous pass cancelled — which is affordable on every inbox write in a way an interdiff
    /// is not.
    ///
    /// Also called by the screen when a threshold moves in Settings and when the stored history
    /// is replaced by a backfill or by *Clear history*: neither of those touches a row, so
    /// neither reaches the inbox observation.
    func refreshTrustLanes() {
        guard !allRows.isEmpty else {
            // An empty inbox has nothing to lane, and a pass still running for the rows that just
            // left must not repopulate what this line clears.
            trustTask?.cancel()
            trustTask = nil
            trust = .empty
            return
        }
        let rows = allRows
        let database = session.database
        let configuration = settings.trustLaneConfiguration
        trustTask?.cancel()
        trustTask = Task { [weak self] in
            let snapshot = await TrustLaneLoader.load(
                database: database,
                rows: rows,
                configuration: configuration
            )
            guard let self, !Task.isCancelled else { return }
            self.trust = snapshot
        }
    }

    /// The lane of one row (ADR 0027).
    /// - Parameter id: The pull request's node id.
    func lane(for id: String) -> TrustLane {
        trust.lane(for: id)
    }

    /// The track record behind one row's badge, or `nil` when the author has no history here.
    /// - Parameter id: The pull request's node id.
    func trackRecord(for id: String) -> TrackRecord? {
        trust.record(for: id)
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
            // No "we do not know" case, unlike the risk facet above: every row has a lane, and a
            // row nothing has been computed for is a full review (ADR 0027).
            if let laneFilter, trust.lane(for: row.id) != laneFilter { return false }
            return true
        }
    }

    /// The grouped sections, ordered by the user's sort choice.
    ///
    /// The title is remapped here, not in ``InboxGrouper``: that lives in ShepherdCore, which
    /// imports Foundation only and cannot call `String(localized:)`, so its provenance section
    /// title is deliberately plain, stable English ("People"). This maps that one section onto
    /// the same "Humans" key the rail already uses, so the list agrees with the rail instead of
    /// showing GitHub-facing English where everything else on the section is German.
    ///
    /// The section is found by its `id`, not by its title: the id is the bucket key
    /// ``InboxGrouper`` groups on — the literal `"human"` — and that is the contract between the
    /// two. A title is display text, and display text is the one thing a remap has to be free to
    /// change: matching on it means re-wording ShepherdCore's English quietly un-remaps this
    /// section and puts "People" back on screen in a German list.
    var sections: [InboxSection] {
        InboxGrouper.group(filteredRows, by: settings.groupBy).map { section in
            let title: String
            if section.facet == .provenance, section.id == "human" {
                title = String(localized: "Humans")
            } else {
                title = section.title
            }
            return InboxSection(
                id: section.id,
                title: title,
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

    /// Whether any rail facet is narrowing the list.
    ///
    /// The one definition of "a filter is on". The header's chip and the empty state's sentence
    /// each asked the same four-part question before, and the notice and the caught-up state
    /// below would have been a third and a fourth spelling of it — which is three chances for
    /// one of them to disagree with the others about whether the list on screen is the whole
    /// list.
    var hasActiveFilter: Bool {
        provenanceFilter != nil || repoFilter != nil || riskFilter != nil || laneFilter != nil
    }

    // MARK: - The track-record notice (ADR 0027's 2026-09-05 amendment)

    /// Whether the inbox should offer to load the track record.
    var showsTrackRecordNotice: Bool {
        InboxModel.showsTrackRecordNotice(
            hasCompletedFirstSweep: session.hasCompletedFirstSweep,
            rows: allRows,
            hasReadStoredCount: trackRecordCoordinator?.hasReadStoredCount ?? false,
            storedOutcomeCount: trackRecordCoordinator?.storedOutcomeCount ?? 0,
            isDismissed: settings.hasDismissedTrackRecordNotice
        )
    }

    /// The five conditions the one-time offer is made under.
    ///
    /// A function of its inputs rather than a chain of `if`s inside a view, for
    /// ``queuedWrites(_:for:)``'s reason: this is the whole of "when does anybody see this", it
    /// has five branches, and four of them are states that are awkward to reach by hand in a
    /// window. Each condition is a different way of being wrong:
    ///
    /// - **The sweep has finished.** Before it has, an inbox with no agent rows is an inbox
    ///   nobody has looked in yet, so the offer would be withheld from exactly the account it is
    ///   for (``SignedInSession/hasCompletedFirstSweep``).
    /// - **Something an agent opened is in the inbox.** The track record counts agents' closed
    ///   pull requests, so in an inbox with none of them the backfill would read up to five
    ///   hundred pull requests per repository and put no badge anywhere. The test is
    ///   ``ShepherdCore/ActorKind/agentIdentity``, which is the same question
    ///   ``ShepherdCore/BulkTriagePlan`` and ``ShepherdCore/AutoMergePolicy`` ask about an author.
    /// - **The count has been read.** ``TrackRecordCoordinator/storedOutcomeCount`` starts at
    ///   zero, and zero is also what "nothing is stored" looks like, so before the first
    ///   `SELECT COUNT(*)` comes back the condition below cannot tell the two apart. The screen's
    ///   `.task` runs after the first body evaluation, so without this an account that has a
    ///   history would be offered one for a frame
    ///   (``TrackRecordCoordinator/hasReadStoredCount``).
    /// - **Nothing is stored yet.** With a history on disk the badges are already on the rows,
    ///   and the offer has answered itself.
    /// - **It has not been answered.** By *Not now*, or by a run that came back
    ///   (``AppSettings/hasDismissedTrackRecordNotice``).
    ///
    /// A run that is *in flight* is deliberately not a condition. It stores nothing until it
    /// finishes, so the count is still zero and the notice stays up by itself — which is what
    /// lets it carry the progress line rather than vanishing under the press that started it.
    /// - Parameters:
    ///   - hasCompletedFirstSweep: Whether a sweep has run to the end in this session.
    ///   - rows: Every cached inbox row.
    ///   - hasReadStoredCount: Whether `storedOutcomeCount` has been read from the database yet.
    ///   - storedOutcomeCount: How many closed pull requests are on disk.
    ///   - isDismissed: Whether the offer has already been answered.
    /// - Returns: Whether to draw the notice.
    nonisolated static func showsTrackRecordNotice(
        hasCompletedFirstSweep: Bool,
        rows: [PullRequestSummary],
        hasReadStoredCount: Bool,
        storedOutcomeCount: Int,
        isDismissed: Bool
    ) -> Bool {
        guard !isDismissed, hasCompletedFirstSweep, hasReadStoredCount, storedOutcomeCount == 0
        else { return false }
        return rows.contains { $0.author.kind.agentIdentity != nil }
    }

    // MARK: - Inbox Zero

    /// Whether the list should draw the designed caught-up state instead of the generic empty one.
    var showsInboxZero: Bool {
        InboxModel.showsInboxZero(
            smartView: smartView,
            hasCompletedFirstSweep: session.hasCompletedFirstSweep,
            hasActiveFilter: hasActiveFilter,
            rows: allRows
        )
    }

    /// Whether an empty list is the good kind of empty.
    ///
    /// "Nothing matches this filter" and "nobody is waiting on you" are the same pixels and
    /// opposite news, and until now they were the same ``EmptyStateView`` as well. Three of the
    /// four conditions are there to be sure it is the second one: the rail has to be on the pile
    /// that can be cleared, no facet may be hiding anything, and the sweep has to have come
    /// back — which is ``InboxListView``'s `isAwaitingFirstSweep` argument applied to a view
    /// that is empty while other rows exist, and therefore does not reach it.
    /// - Parameters:
    ///   - smartView: The selected rail row.
    ///   - hasCompletedFirstSweep: Whether a sweep has run to the end in this session.
    ///   - hasActiveFilter: Whether a facet is narrowing the list.
    ///   - rows: Every cached inbox row.
    /// - Returns: Whether to draw the caught-up state.
    nonisolated static func showsInboxZero(
        smartView: SmartView,
        hasCompletedFirstSweep: Bool,
        hasActiveFilter: Bool,
        rows: [PullRequestSummary]
    ) -> Bool {
        guard smartView == .needsMyReview, hasCompletedFirstSweep, !hasActiveFilter else {
            return false
        }
        return !rows.contains(where: SmartView.needsMyReview.matches)
    }

    /// The caught-up state's second line.
    var inboxZeroMessage: String {
        InboxModel.inboxZeroMessage(
            openPullRequestsOfMine: allRows.filter { $0.myRelation.contains(.author) }.count
        )
    }

    /// What to say under "You are caught up.".
    ///
    /// Deliberately useful rather than decorative, and there are two useful things to say. When
    /// the user has work of their own still open, the next place to look is one rail row down and
    /// the line says how much is waiting there. When they have not, there is nothing to point at
    /// and the honest thing is what will bring the next review request: the sweep, by itself, or
    /// ⌘R for somebody who does not want to wait for it.
    /// - Parameter openPullRequestsOfMine: How many cached rows the user opened.
    /// - Returns: The line.
    nonisolated static func inboxZeroMessage(openPullRequestsOfMine: Int) -> String {
        guard openPullRequestsOfMine > 0 else {
            return String(localized: "New review requests land here on their own; ⌘R checks now.")
        }
        return String(
            localized: "\(openPullRequestsOfMine) of your own pull requests are still open."
        )
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

    /// The lanes present in the current smart view, with counts (ADR 0027).
    ///
    /// Counted over the smart view rather than over the filtered list, exactly as the risk, agent
    /// and repository facets are: a facet whose counts changed when you selected one of its own
    /// rows could not be used to compare them.
    var laneFacets: [TrustLaneFacet] {
        TrustLaneLoader.facets(
            rows: allRows.filter { smartView.matches($0) },
            snapshot: trust
        )
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
            // The primary key is recency, so the track record only ever reorders rows that were
            // updated at the same instant.
            return trackRecordOrdered(InboxGrouper.sorted(rows)) { $0.updatedAt == $1.updatedAt }
        case .oldestFirst:
            return trackRecordOrdered(Array(InboxGrouper.sorted(rows).reversed())) {
                $0.updatedAt == $1.updatedAt
            }
        case .priority:
            // The primary key is the urgency score; the record slots in underneath it, ahead of
            // the recency tie-break `prioritySorted` applies.
            return trackRecordOrdered(InboxModel.prioritySorted(rows)) {
                InboxModel.priorityScore($0) == InboxModel.priorityScore($1)
            }
        }
    }

    /// Re-orders rows by the author's merged count, descending, **as a secondary key**
    /// (ADR 0027).
    ///
    /// The whole of what a track record does to the list, and three properties make it safe to
    /// slot underneath any of the three primary orders:
    ///
    /// - **It only ever reorders rows the primary order tied.** `rows` arrives already sorted;
    ///   this walks it, cuts it into runs of rows `isTied` calls equal, and sorts each run on its
    ///   own. A row can therefore never overtake one the primary key put in front of it —
    ///   recency stays recency, and urgency stays urgency.
    /// - **Each run is sorted stably**, position as the last tie-breaker, so two agents with the
    ///   same number of merges keep the order the primary sort gave them.
    /// - **It never moves a row across a lane, because it does not know about lanes.** The lanes
    ///   are the rail's filter; this sorts inside whatever list it is handed.
    ///
    /// Rows whose author has no history count as zero merged, which puts a brand-new agent below
    /// an established one at equal urgency — not because it is less trustworthy, but because
    /// there is nothing to read yet and a reviewer's attention is better spent on the row that
    /// has numbers beside it.
    /// - Parameters:
    ///   - rows: The rows in their primary order.
    ///   - isTied: Whether two rows have the same primary key.
    /// - Returns: The rows, with tied ones ordered by merged count.
    private func trackRecordOrdered(
        _ rows: [PullRequestSummary],
        isTied: (PullRequestSummary, PullRequestSummary) -> Bool
    ) -> [PullRequestSummary] {
        guard !trust.records.isEmpty, rows.count > 1 else { return rows }
        var result: [PullRequestSummary] = []
        result.reserveCapacity(rows.count)
        var run: [PullRequestSummary] = [rows[0]]
        for row in rows.dropFirst() {
            if let last = run.last, isTied(last, row) {
                run.append(row)
                continue
            }
            result.append(contentsOf: sortedByMergedCount(run))
            run = [row]
        }
        result.append(contentsOf: sortedByMergedCount(run))
        return result
    }

    /// One run of equally urgent rows, most-merged first, stable on position.
    private func sortedByMergedCount(
        _ run: [PullRequestSummary]
    ) -> [PullRequestSummary] {
        guard run.count > 1 else { return run }
        return run.enumerated()
            .map { (index: $0.offset, row: $0.element, merged: mergedCount(for: $0.element)) }
            .sorted { lhs, rhs in
                if lhs.merged != rhs.merged { return lhs.merged > rhs.merged }
                return lhs.index < rhs.index
            }
            .map(\.row)
    }

    /// How many pull requests this row's author has merged in this repository, or zero.
    private func mergedCount(for row: PullRequestSummary) -> Int {
        trust.record(for: row.id)?.merged ?? 0
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

    // MARK: - Queued writes (ADR 0006)

    /// The outbox rows targeting one pull request.
    /// - Parameter row: The pull request.
    func queuedWrites(for row: PullRequestSummary) -> [OutboxItem] {
        InboxModel.queuedWrites(outboxItems, for: row)
    }

    /// How many writes are queued or in flight for one pull request.
    /// - Parameter row: The pull request.
    func queuedWriteCount(for row: PullRequestSummary) -> Int {
        InboxModel.queuedWriteCount(outboxItems, for: row)
    }

    /// How many writes the drain parked for one pull request because it moved on underneath them.
    /// - Parameter row: The pull request.
    func parkedWriteCount(for row: PullRequestSummary) -> Int {
        InboxModel.parkedWriteCount(outboxItems, for: row)
    }

    /// How many writes for one pull request were given up on.
    ///
    /// The third state a queued write can end in: the drain fails a row **non-retriably** on a
    /// 4xx from GitHub, and on anything else it establishes that retrying cannot help. Such a row
    /// is neither waiting nor parked, so neither of the two counts above sees it — and it never
    /// goes away by itself, which is exactly why it has to be on screen rather than only in the
    /// account-wide count in the title bar.
    /// - Parameter row: The pull request.
    func failedWriteCount(for row: PullRequestSummary) -> Int {
        InboxModel.failedWriteCount(outboxItems, for: row)
    }

    /// The rows out of `items` that target one pull request, in the order they were queued.
    ///
    /// Taking the rows as an argument rather than reading ``outboxItems``, exactly as
    /// ``priorityScore(_:)`` takes a row: this is what the panel's line says, and stating it as a
    /// function of the queue makes it assertable without a ``SignedInSession``, which the tests
    /// have no way to build. The four instance methods above are the same four questions asked of
    /// whatever the observation last handed over.
    /// - Parameters:
    ///   - items: The outbox rows to look in.
    ///   - row: The pull request.
    /// - Returns: The matching rows. An outbox row's ``ShepherdCore/OutboxItem/prID`` is the
    ///   node id of its target, which for these four functions is always a pull request.
    nonisolated static func queuedWrites(
        _ items: [OutboxItem],
        for row: PullRequestSummary
    ) -> [OutboxItem] {
        items.filter { $0.prID == row.id }
    }

    /// How many of `items` are queued or in flight for one pull request.
    ///
    /// A row that is already being sent still counts: from the user's point of view it has not
    /// landed yet, which is the rule the account-wide `pendingOutboxCount()` applies too.
    /// - Parameters:
    ///   - items: The outbox rows to look in.
    ///   - row: The pull request.
    nonisolated static func queuedWriteCount(
        _ items: [OutboxItem],
        for row: PullRequestSummary
    ) -> Int {
        InboxModel.queuedWrites(items, for: row)
            .filter { $0.state == .pending || $0.state == .sending }
            .count
    }

    /// How many of `items` the drain parked for one pull request.
    /// - Parameters:
    ///   - items: The outbox rows to look in.
    ///   - row: The pull request.
    nonisolated static func parkedWriteCount(
        _ items: [OutboxItem],
        for row: PullRequestSummary
    ) -> Int {
        InboxModel.queuedWrites(items, for: row).filter { $0.state == .conflicted }.count
    }

    /// How many of `items` were given up on for one pull request.
    /// - Parameters:
    ///   - items: The outbox rows to look in.
    ///   - row: The pull request.
    nonisolated static func failedWriteCount(
        _ items: [OutboxItem],
        for row: PullRequestSummary
    ) -> Int {
        InboxModel.queuedWrites(items, for: row).filter { $0.state == .failed }.count
    }

    // MARK: - Deep links

    /// Applies a rail filter that arrived from a `shepherd://inbox?filter=…` link (ADR 0013).
    ///
    /// The mapping itself is ``InboxRailSelection``, so it can be tested without a session.
    /// - Parameter filter: The filter from the link.
    func apply(_ filter: InboxDeepLinkFilter) {
        let selection = InboxRailSelection(filter)
        // A token that names the *section* rather than a rail state leaves this rail exactly as
        // it was; the screen moves the picker (ADR 0032). Clearing the facets here would mean a
        // `filter=issues` link quietly discarded the pull-request rail the user set up.
        guard let view = selection.smartView else { return }
        smartView = view
        provenanceFilter = selection.provenanceFilter
        repoFilter = selection.repoFilter
        // The link's grammar has no risk token (ADR 0013 is unchanged by ADR 0023), so a risk
        // facet left selected from before would silently narrow what the link asked for — and an
        // empty list looks like a broken link, which is the argument the whole mapping makes.
        riskFilter = nil
        // The same for the lane facet, which ADR 0027 did not add a token for either.
        laneFilter = nil
    }

    // MARK: - Surviving a rebuild (ADR 0013)

    /// The rail as one small value a `@SceneStorage` string can hold.
    ///
    /// The screen it belongs to is rebuilt whenever ``AppEnvironment/route`` changes (ADR 0013),
    /// and this model goes with it: a trip to the review screen and back used to hand the reader a
    /// rail they had not set — the smart view, the facets and the cursor all back at their
    /// defaults. So the rail is written down somewhere the rebuild cannot reach, and this is the
    /// sentence it is written in.
    ///
    /// Every facet is its own field, and deliberately **not** a `shepherd://inbox?filter=…` token.
    /// The rail *composes*: the sidebar sets a smart view, a repository and a provenance
    /// independently, and the risk and lane facets narrow whatever those three say. The link
    /// grammar does not compose — it has one token for one smart view *or* one facet, and a facet
    /// token widens the view to "Involved" (``InboxRailSelection``). So the ordinary rail "Needs
    /// my review, in this repository" has no token at all, and a token would have restored it as a
    /// rail the reader never set. A vocabulary for addressing an inbox from outside is not a
    /// vocabulary for remembering one from inside.
    ///
    /// A pure value for ``InboxRailSelection``'s reason: it is testable without a session, and the
    /// model only reads it and assigns it.
    struct RailState: Codable, Equatable {
        /// ``SmartView``'s raw value, as a string rather than the enum: a rail written by a build
        /// whose sidebar has a fifth smart view is still a rail this build can read the rest of.
        var smartView: String
        /// The provenance facet, if any.
        var provenance: ProvenanceFilter?
        /// The repository facet, if any.
        var repo: RepoRef?
        /// The risk facet's ``TriageVerdict/Risk`` raw value (ADR 0023).
        var risk: String?
        /// The trust lane's ``TrustLane`` raw value (ADR 0027).
        var lane: String?
        /// The keyboard cursor's pull-request id.
        var selectedID: String?

        /// Writes a rail down.
        /// - Parameters:
        ///   - smartView: The selected smart view.
        ///   - provenanceFilter: The provenance facet, if any.
        ///   - repoFilter: The repository facet, if any.
        ///   - riskFilter: The risk facet, if any.
        ///   - laneFilter: The trust lane, if any.
        ///   - selectedID: The keyboard cursor.
        init(
            smartView: SmartView,
            provenanceFilter: ProvenanceFilter?,
            repoFilter: RepoRef?,
            riskFilter: TriageVerdict.Risk?,
            laneFilter: TrustLane?,
            selectedID: String?
        ) {
            self.smartView = smartView.rawValue
            provenance = provenanceFilter
            repo = repoFilter
            risk = riskFilter?.rawValue
            lane = laneFilter?.rawValue
            self.selectedID = selectedID
        }

        /// The smart view the rail was on.
        ///
        /// A raw value this build does not know falls back to the rail's own default rather than
        /// to nothing, because there is no such thing as an inbox with no smart view selected.
        var view: SmartView { SmartView(rawValue: smartView) ?? .needsMyReview }

        /// The risk facet the rail had, if the stored raw value is one this build knows.
        var riskFacet: TriageVerdict.Risk? { risk.flatMap(TriageVerdict.Risk.init(rawValue:)) }

        /// The trust lane the rail had, if the stored raw value is one this build knows.
        var laneFacet: TrustLane? { lane.flatMap(TrustLane.init(rawValue:)) }
    }

    /// The rail as the screen stores it between rebuilds (ADR 0013).
    var railState: RailState {
        RailState(
            smartView: smartView,
            provenanceFilter: provenanceFilter,
            repoFilter: repoFilter,
            riskFilter: riskFilter,
            laneFilter: laneFilter,
            selectedID: selectedID
        )
    }

    /// Puts a stored rail back, before the observation that fills the list starts (ADR 0013).
    ///
    /// Assigned facet by facet rather than routed through ``apply(_:)``: that method is the deep
    /// link's, and a link is allowed to replace a rail — it clears the risk and lane facets and
    /// widens the smart view — which is the opposite of what putting a rail back means.
    ///
    /// A raw value that does not parse is read as "not set" rather than as a failure: this is
    /// scene storage written by some build of this app, and the worst it can be is out of date.
    /// The smart view falls back to the rail's own default, because there is no such thing as an
    /// inbox with no smart view selected.
    ///
    /// The cursor goes last. Every facet's `didSet` clamps the selection, and on a model whose
    /// rows have not arrived yet that means dropping it. It goes through ``select(_:)`` rather
    /// than an assignment, so the row the reader left the screen on is a *selection* — the one
    /// ``clampSelection()`` keeps, and the one the detail panel loads for.
    /// - Parameter state: The rail written down before the screen was rebuilt.
    func restore(_ state: RailState) {
        smartView = state.view
        provenanceFilter = state.provenance
        repoFilter = state.repo
        riskFilter = state.riskFacet
        laneFilter = state.laneFacet
        select(state.selectedID)
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
        if let selectedID, rows.contains(where: { $0.id == selectedID }) {
            // A cursor restored from scene storage (ADR 0013) points at a row whose detail nobody
            // has asked for yet: ``restore(_:)`` runs before the rows arrive, so `loadDetail()`
            // returned at its own guard — there was nothing to look the row up in — and this is
            // the first moment both halves exist. Without it the reader comes back to their row
            // beside an empty panel.
            //
            // `detailTask` is the exact question "has this model ever started a read", which is
            // what makes this the restore path and only the restore path: the early return above
            // leaves it nil, and every real ``select(_:)`` sets it for the model's lifetime. A
            // read that is running, or one that failed and left the panel empty, is not started
            // again by the next write to the inbox table.
            if detailTask == nil { loadDetail() }
            return
        }
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
