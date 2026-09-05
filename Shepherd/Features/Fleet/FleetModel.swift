import Foundation
import Observation
import ShepherdCore
import ShepherdPersistence

/// The two reads the fleet is built from.
///
/// A seam rather than a `DatabaseManager` for ``IssueFetching``'s reason: these two calls are the
/// whole of this model's dependency on the world outside it, and naming them is what lets
/// `FleetScreenTests` build the model against an in-memory database — or against a double that
/// counts how often it was asked — with no Keychain, no token and no network anywhere near it.
///
/// Both requirements are `DatabaseManager` methods already, spelled exactly as they are declared
/// there. That is the point rather than a coincidence: the fleet adds no query, no request and no
/// host (ADR 0027), so a seam whose shape did not already exist would mean it had.
protocol FleetReading: Sendable {
    /// Every stored outcome that closed since one moment, most recently closed first.
    func pullRequestOutcomes(since: Date) async throws -> [PullRequestOutcome]
    /// The user's own agent-registry entries, which replace bundled ones of the same id
    /// (ADR 0008).
    func agentRegistryOverrides() async throws -> [AgentRegistryEntry]
}

/// The live reads: the local database, with nothing in between.
extension DatabaseManager: FleetReading {}

/// One agent's open pull requests in one repository, as the detail page groups them.
struct FleetOpenGroup: Identifiable, Hashable {
    /// The repository.
    var repo: RepoRef
    /// The agent's open pull requests there, in the order the page draws them.
    var rows: [PullRequestSummary]

    /// Identified by the repository's full name, lower-cased — ``FleetRepositoryRecord``'s key,
    /// so a group and the grid row above it cannot disagree about which repository they are.
    var id: String { repo.fullName.lowercased() }
}

/// The finished counting, on its way from a background task to the observation graph.
///
/// At file scope rather than nested inside ``FleetModel`` on purpose: it is built by a
/// `nonisolated` function inside a `Task.detached` and read on the main actor, so it must be
/// plainly `Sendable` and plainly *not* main-actor isolated — which a type declared inside a
/// `@MainActor` class is not obviously either.
private struct FleetSnapshot: Sendable {
    /// The roster, in ``FleetRoster``'s one order.
    var agents: [FleetAgent]
    /// Each agent's notices, keyed by ``FleetAgent/id``.
    var notices: [String: [FleetNotice]]
}

/// Which of the three states with nothing much to show the fleet is in (plan §6).
///
/// A named decision rather than a chain of `if`s inside a view, for
/// ``InboxModel/showsTrackRecordNotice(hasCompletedFirstSweep:rows:storedOutcomeCount:isDismissed:)``'s
/// reason: two of the three are states that are awkward to reach by hand in a window, and a
/// screen that shows the wrong one is a screen that lies about whether Shepherd has counted
/// anything.
enum FleetEmptyState: Equatable {
    /// Agents, with counted history behind at least one of them: the ordinary screen.
    case counted
    /// Agents, and nothing counted at all — every one of them is here because something of its
    /// is open right now. The closed-side columns are em-dashes and the screen offers the
    /// backfill.
    case noHistory
    /// No agent at all: nothing of an agent's is open and nothing of an agent's was counted.
    case noAgents
}

/// Drives the fleet screen: who the agents are, what they have closed, and what they have open
/// (plan §2).
///
/// Everything on the screen is assembled here from the two things Shepherd already stores — the
/// outcome table ADR 0027 writes, and the inbox rows the session is already observing. There is
/// no new query, no new request and no new host: ``FleetReading/pullRequestOutcomes(since:)`` is
/// the same read the badges are computed from, so a badge beside an inbox row and a number on
/// this screen cannot come to different conclusions about the same ninety days.
///
/// Three things about its shape are decisions rather than mechanics:
///
/// - **It is built from a reader and a list of rows, not from a `SignedInSession`.** The narrower
///   dependency is ``IssueInboxModel``'s, for its reason: the screen's whole behaviour is
///   assertable without a session. The open rows are *passed in* on every refresh rather than
///   observed here, because the session already observes them for the inbox and a second
///   observation of the same table would be a second answer to "what is open".
/// - **The counting happens off the main actor and the assigning on it.** The read and the two
///   pure builders (``FleetRoster/make(outcomes:openRows:since:)`` and
///   ``FleetNotices/detect(for:outcomes:since:)``) walk every outcome in the window several
///   times; only the finished snapshot touches the observation graph.
/// - **Nothing here sorts, ranks or scores.** The order is `FleetRoster`'s, which takes no
///   parameter, and this model adds no second one. There is no `sortBy`, no picker binding and no
///   place for one.
@MainActor
@Observable
final class FleetModel {
    /// How the two reads are made.
    let reader: any FleetReading

    /// The fleet, in ``FleetRoster``'s one order.
    private(set) var agents: [FleetAgent] = []
    /// Each agent's notices, keyed by ``FleetAgent/id``.
    ///
    /// Computed once per refresh rather than per redraw: ``FleetNotices/detect(for:outcomes:since:)``
    /// buckets the whole window by repository and by agent, and a SwiftUI `body` that called it
    /// would do that on every frame the detail page draws.
    private(set) var noticesByAgent: [String: [FleetNotice]] = [:]
    /// The inbox as it stood at the last refresh — what "open right now" is read from.
    private(set) var openRows: [PullRequestSummary] = []
    /// Whether a first snapshot has arrived. `false` is "still counting", not "nothing to show".
    private(set) var hasLoaded = false
    /// A registry id a caller asked for that no agent in the roster carries.
    ///
    /// A state and not a failure: the screen shows the unfiltered fleet and says the id was not
    /// recognised, which is the honest answer for a link naming an agent whose work has all
    /// closed outside the window — or an agent the user has since removed from their registry.
    private(set) var unknownAgentID: String?
    /// The bundled registry merged with the user's overrides, for the detail page's one line
    /// about *how* Shepherd recognises an agent.
    private(set) var registry: AgentRegistry = .empty

    /// The selected agent's ``FleetAgent/id``, or `nil` when nothing is selected.
    ///
    /// The display name lower-cased rather than the registry id, because the id is the half that
    /// can be missing: an agent with history and nothing open never had a live `Actor` to carry
    /// one. A route names an agent by id — see ``request(agentID:)`` — and this is what that
    /// resolves *to*.
    var selectedAgentID: String? {
        didSet {
            guard oldValue != selectedAgentID else { return }
            selectedOpenPullRequestID = openPullRequestsInOrder(forAgentID: selectedAgentID)
                .first?.id
        }
    }
    /// The open pull request Return opens.
    ///
    /// One cursor for the agents and one for the pull requests underneath the selected one, which
    /// is the smallest arrangement that makes "Return opens an open pull request" mean something
    /// definite: it starts at the first row of *Open right now* in the order that section draws
    /// them, and moves when the reader points at another. `nil` when the selected agent has
    /// nothing open, and Return then does nothing rather than opening a pull request nobody
    /// chose.
    private(set) var selectedOpenPullRequestID: String?

    private let now: @MainActor () -> Date
    private var refreshTask: Task<Void, Never>?
    /// The registry id the route asked for, kept until a roster arrives that can answer it.
    private var requestedAgentID: String?

    /// Creates the model.
    /// - Parameters:
    ///   - reader: How the outcomes and the registry overrides are read; the database in the app.
    ///   - now: The clock the ninety-day window is measured back from. Injectable so a test can
    ///     place an outcome inside or outside it without waiting.
    init(reader: any FleetReading, now: @escaping @MainActor () -> Date = { Date() }) {
        self.reader = reader
        self.now = now
    }

    // MARK: - Refreshing

    /// Rebuilds the fleet from the stored outcomes and the inbox as it stands.
    ///
    /// The window is ``TrackRecord/windowStart(from:)`` and therefore ADR 0027's ninety days,
    /// taken from the constant the badge and the backfill's search query already quote. Writing
    /// the number again here would make it two decisions that happen to agree, and the first time
    /// they stopped agreeing the badge beside a row and the grid on this screen would be counting
    /// two different windows.
    ///
    /// The whole of the work happens away from the main actor: the read on the database's own
    /// executor, then the two pure builders in a detached task. `Task.detached` rather than a
    /// plain `nonisolated` call, because the latter's isolation depends on a language-mode flag
    /// while this does not — ``TriageCoordinator``'s reason, unchanged.
    ///
    /// A refresh in flight is cancelled rather than queued: the two events that call this — a
    /// finished backfill and a sweep writing new inbox rows — each replace the answer wholesale,
    /// so a superseded pass has nothing left to contribute.
    /// - Parameter openRows: The inbox as the session holds it.
    func refresh(openRows: [PullRequestSummary]) {
        refreshTask?.cancel()
        let since = TrackRecord.windowStart(from: now())
        let reader = self.reader
        refreshTask = Task(priority: .utility) { [weak self] in
            // A failed read answers "nothing is counted", which is exactly what an empty table
            // answers and what the screen already knows how to say. There is nothing for a user
            // to do about a local `SELECT` that failed, and a fleet that refused to draw would
            // hide the open pull requests it can still list from the rows it was handed.
            let outcomes = (try? await reader.pullRequestOutcomes(since: since)) ?? []
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .utility) {
                FleetModel.snapshot(outcomes: outcomes, openRows: openRows, since: since)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(snapshot, openRows: openRows)
        }
    }

    /// Stops a refresh in flight. Called when the screen goes away.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Loads the registry the detail page's detection line is read from.
    ///
    /// The bundled entries merged with the user's overrides — which is what `AgentDetector` is
    /// built from in `SignedInSession`, arrived at the same way `SettingsModel` arrives at it,
    /// rather than by reaching into a session for a detector it does not publish. The two cannot
    /// drift, because `AgentRegistry.merging(extensions:)` is the one merge and both call it.
    ///
    /// A failure leaves ``registry`` empty, and an empty registry simply means the detail page
    /// draws no detection line — the numbers, which are what the page is for, do not depend on it.
    func loadRegistry() async {
        let bundled = (try? AgentRegistry.bundled()) ?? .empty
        let overrides = (try? await reader.agentRegistryOverrides()) ?? []
        registry = bundled.merging(extensions: overrides)
    }

    /// The whole of the fleet's arithmetic, in one pure function off the main actor.
    ///
    /// `outcomes` is handed to ``FleetNotices/detect(for:outcomes:since:)`` **whole** — every
    /// agent's rows, not the asking agent's — because the pairwise revert-share sentence compares
    /// two agents in one repository and cannot be computed from one agent's rows. The detector
    /// does its own filtering on both axes.
    /// - Parameters:
    ///   - outcomes: Every stored outcome inside the window.
    ///   - openRows: The inbox as it stands.
    ///   - since: The oldest `closedAt` to count.
    /// - Returns: The roster and each agent's notices.
    private nonisolated static func snapshot(
        outcomes: [PullRequestOutcome],
        openRows: [PullRequestSummary],
        since: Date
    ) -> FleetSnapshot {
        let agents = FleetRoster.make(outcomes: outcomes, openRows: openRows, since: since)
        var notices: [String: [FleetNotice]] = [:]
        for agent in agents {
            notices[agent.id] = FleetNotices.detect(
                for: agent.displayName,
                outcomes: outcomes,
                since: since
            )
        }
        return FleetSnapshot(agents: agents, notices: notices)
    }

    private func apply(_ snapshot: FleetSnapshot, openRows: [PullRequestSummary]) {
        agents = snapshot.agents
        noticesByAgent = snapshot.notices
        self.openRows = openRows
        hasLoaded = true
        applyRequestedAgent()
        // And again afterwards, because the selection may not have *changed*: an agent that was
        // already selected keeps its cursor, and the pull request under it can perfectly well
        // have merged since the last snapshot.
        clampOpenPullRequest()
    }

    // MARK: - Selection

    /// Asks for one agent by registry id, whether or not a roster has arrived yet.
    ///
    /// The route's own value, handed over on appearance and again whenever a link names a second
    /// agent. It is remembered rather than resolved on the spot because the roster is counted
    /// asynchronously: a link that opens the window is nearly always ahead of the first snapshot,
    /// and an ask that was dropped for arriving early would leave the reader on the wrong agent
    /// with nothing to say why.
    /// - Parameter agentID: The registry id to select, or `nil` for the whole fleet.
    func request(agentID: String?) {
        requestedAgentID = agentID
        if agentID == nil { unknownAgentID = nil }
        applyRequestedAgent()
    }

    private func applyRequestedAgent() {
        guard let requestedAgentID else {
            clampSelection()
            return
        }
        // Nothing has been counted yet, so "no agent carries this id" is not yet a true statement
        // about anything. The ask is kept and answered by the next snapshot.
        guard hasLoaded else { return }
        // Case-insensitively, because a registry id reaches this screen through a URL somebody
        // may have typed, and `AgentRegistry` treats ids as names rather than as opaque bytes.
        if let match = agents.first(where: {
            $0.registryID?.caseInsensitiveCompare(requestedAgentID) == .orderedSame
        }) {
            unknownAgentID = nil
            selectedAgentID = match.id
            return
        }
        // Nothing selected, and the list stays unfiltered: an id the fleet does not recognise is
        // a link that has gone stale — an agent whose work all closed outside the ninety days, or
        // one the user removed from their registry — and the useful answer is the fleet plus a
        // line saying so, not an empty screen.
        unknownAgentID = requestedAgentID
        selectedAgentID = nil
    }

    /// Keeps the cursor on a row that exists, landing on the first one when it does not.
    private func clampSelection() {
        if let selectedAgentID, agents.contains(where: { $0.id == selectedAgentID }) {
            clampOpenPullRequest()
            return
        }
        // The first row, which is also what a fleet of exactly one agent gets: its page opens
        // rather than an empty detail column with a list of one beside it (plan §6.4).
        selectedAgentID = agents.first?.id
    }

    /// Moves the agent cursor by one row, stopping at either end.
    /// - Parameter offset: `+1` for the down arrow, `-1` for the up arrow.
    func moveSelection(by offset: Int) {
        guard !agents.isEmpty else { return }
        guard let selectedAgentID,
            let index = agents.firstIndex(where: { $0.id == selectedAgentID })
        else {
            selectAgent(agents[0].id)
            return
        }
        let next = min(max(0, index + offset), agents.count - 1)
        selectAgent(agents[next].id)
    }

    /// Selects one agent by ``FleetAgent/id``.
    ///
    /// Clears ``unknownAgentID`` and the standing request with it: once the reader has picked a
    /// row by hand, a note about the id a link carried is about something they have moved on
    /// from, and the next refresh must not put them back on it.
    /// - Parameter id: The agent's identity, or `nil` to select nothing.
    func selectAgent(_ id: String?) {
        requestedAgentID = nil
        unknownAgentID = nil
        selectedAgentID = id
    }

    /// Points the Return key at one of the selected agent's open pull requests.
    /// - Parameter prID: The pull request's node id.
    func selectOpenPullRequest(_ prID: String?) {
        selectedOpenPullRequestID = prID
    }

    private func clampOpenPullRequest() {
        let rows = openPullRequestsInOrder(forAgentID: selectedAgentID)
        if let selectedOpenPullRequestID, rows.contains(where: { $0.id == selectedOpenPullRequestID }) {
            return
        }
        selectedOpenPullRequestID = rows.first?.id
    }

    // MARK: - Derived state

    /// The selected agent, when the roster still carries it.
    var selectedAgent: FleetAgent? {
        guard let selectedAgentID else { return nil }
        return agents.first { $0.id == selectedAgentID }
    }

    /// Which of the three sparse states the screen is in.
    var emptyState: FleetEmptyState { FleetModel.emptyState(for: agents) }

    /// Which of the three sparse states a roster is in (plan §6).
    ///
    /// Asked of the roster rather than of a `SELECT COUNT(*)` over the outcome table, and the two
    /// are genuinely different questions: a table holding only rows older than the window, or
    /// only rows whose author is a person, is a table with a count and a fleet with nothing
    /// counted. The screen must describe what the grid below it shows.
    /// - Parameter agents: The roster, as ``FleetRoster/make(outcomes:openRows:since:)`` built it.
    /// - Returns: The state.
    nonisolated static func emptyState(for agents: [FleetAgent]) -> FleetEmptyState {
        guard !agents.isEmpty else { return .noAgents }
        return agents.allSatisfy { $0.overall.isEmpty } ? .noHistory : .counted
    }

    /// One agent's notices — at most three, in ``FleetNotices``' fixed order.
    /// - Parameter agent: The agent whose page is asking.
    /// - Returns: The notices, possibly none.
    func notices(for agent: FleetAgent) -> [FleetNotice] {
        noticesByAgent[agent.id] ?? []
    }

    /// The registry entry behind one agent, when the registry knows it.
    ///
    /// `nil` for an agent with no ``FleetAgent/registryID`` — one that only history knows, whose
    /// stored outcomes carry its name and not its id — and `nil` again for an id the registry no
    /// longer has. Both mean the same thing to the page: there is nothing truthful to say about
    /// how this agent is recognised, so the line is not drawn.
    /// - Parameter agent: The agent.
    /// - Returns: The entry, or `nil`.
    func registryEntry(for agent: FleetAgent) -> AgentRegistryEntry? {
        guard let registryID = agent.registryID else { return nil }
        return registry.agents.first { $0.id == registryID }
    }

    /// One agent's open pull requests, grouped by repository.
    ///
    /// The groups come in ``FleetAgent/repositories``' order — the fleet's one order — so the
    /// *Open right now* section and the grid above it list the same repositories the same way
    /// round. Inside a group the rows are most recently updated first, which is the inbox's own
    /// order, tie-broken by number so two rows touched in the same second cannot swap places
    /// between two redraws.
    /// - Parameter agent: The agent.
    /// - Returns: The groups, each with at least one row.
    func openPullRequests(for agent: FleetAgent) -> [FleetOpenGroup] {
        // The same case-insensitive join on the display name `FleetRoster` makes between a stored
        // outcome and a live row, and `TrackRecordSubject.matches(_:)` before it.
        let mine = openRows.filter {
            $0.author.kind.agentIdentity?.displayName.lowercased() == agent.id
        }
        var byRepo: [String: [PullRequestSummary]] = [:]
        for row in mine { byRepo[row.repo.fullName.lowercased(), default: []].append(row) }
        return agent.repositories.compactMap { record -> FleetOpenGroup? in
            guard var rows = byRepo[record.id], !rows.isEmpty else { return nil }
            rows.sort { left, right in
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                return left.number > right.number
            }
            return FleetOpenGroup(repo: record.repo, rows: rows)
        }
    }

    /// One agent's open pull requests flattened into the order the page draws them.
    /// - Parameter id: The agent's ``FleetAgent/id``, or `nil`.
    /// - Returns: The rows, in drawn order.
    func openPullRequestsInOrder(forAgentID id: String?) -> [PullRequestSummary] {
        guard let id, let agent = agents.first(where: { $0.id == id }) else { return [] }
        return openPullRequests(for: agent).flatMap(\.rows)
    }
}
