import ShepherdCore
import SwiftUI

/// The fleet: every agent Shepherd has seen, and one of them at a time in detail.
///
/// Two columns rather than the inbox's three — the agent list and the agent's page — because the
/// third pane of a three-pane screen is a *preview of a selection*, and the selection here is
/// already the page. Everything else is ``InboxScreen``'s arrangement: one screen, one model, the
/// keyboard on the list.
///
/// It refreshes on three events and no timer: when it appears, when the stored history is
/// replaced (a finished backfill, *Clear history*, a sign-out — all of which bump
/// ``TrackRecordCoordinator/historyVersion``), and when the sweep writes new inbox rows. Those are
/// the two inputs the counting has, and neither of them reports itself any other way.
struct FleetScreen: View {
    @Environment(AppEnvironment.self) private var environment
    /// The active session — the database the counting reads and the inbox rows it counts against.
    let session: SignedInSession
    /// The registry id the route named, or `nil` for the whole fleet.
    let agentID: String?

    @State private var model: FleetModel
    @FocusState private var isListFocused: Bool

    /// Creates the screen.
    /// - Parameters:
    ///   - session: The signed-in session.
    ///   - agentID: The registry id of the agent to open on, or `nil`.
    init(session: SignedInSession, agentID: String?) {
        self.session = session
        self.agentID = agentID
        // The database rather than the whole session, which is ``IssueInboxModel``'s narrowing
        // and its reason: the model's whole behaviour is assertable without a Keychain or a
        // token. The inbox rows are handed over on every refresh instead of being observed a
        // second time — the session already observes them.
        _model = State(initialValue: FleetModel(reader: session.database))
    }

    var body: some View {
        content
            .background(Theme.background)
            // The way back, as the window's toolbar (ADR 0040) — on `content`, so it is there in
            // every state of the screen, the one with no agents and no list included.
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    backButton
                }
            }
            .task {
                // The ask first, so a link that opened the window is already waiting when the
                // first snapshot lands; then the counting; then the registry, which only the
                // detection line needs and which nothing else waits for.
                model.request(agentID: agentID)
                model.refresh(openRows: session.inboxRows)
                // One per opening of the screen (ADR 0036). `.task` runs on appearance, and the
                // `onChange` below covers a second link arriving while the screen is already up —
                // which is a second page viewed, not the same one again.
                environment.telemetry?.record(.fleetViewed(scope: agentID == nil ? .all : .agent))
                await model.loadRegistry()
            }
            // A second link naming another agent while this screen is up. There is no `.id()` on
            // the screen for this reason: re-creating it would throw away a roster that has just
            // been counted, to answer a question that is one property assignment.
            .onChange(of: agentID) { _, id in
                model.request(agentID: id)
                environment.telemetry?.record(.fleetViewed(scope: id == nil ? .all : .agent))
            }
            // The stored history, replaced wholesale by a backfill or by *Clear history*. The
            // inbox watches the same counter for the same reason (ADR 0027).
            .onChange(of: environment.trackRecord.historyVersion) { _, _ in
                model.refresh(openRows: session.inboxRows)
            }
            // And the other half of the counting: what is open. The sweep replaces these rows,
            // and an agent's "7 open · 3 waiting on you" is stale the moment it does.
            .onChange(of: session.inboxRows) { _, rows in
                model.refresh(openRows: rows)
            }
            .onDisappear { model.stop() }
    }

    // MARK: - The screen

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            // The spinner rather than "no agents yet", because the two are the same pixels and
            // opposite claims: Shepherd cannot say an inbox has no agents in it before it has
            // finished counting (``LoadingStateView``'s own argument).
            LoadingStateView(
                title: String(localized: "Counting what your agents have closed…"),
                message: nil
            )
        } else {
            switch model.emptyState {
            case .noAgents:
                noAgentsState
            case .noHistory, .counted:
                VStack(spacing: 0) {
                    if model.emptyState == .noHistory {
                        FleetHistoryCard()
                    }
                    if let unknown = model.unknownAgentID {
                        unknownAgentNote(unknown)
                    }
                    splitView
                }
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            agentList
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - The list

    private var agentList: some View {
        VStack(spacing: 0) {
            Text(String(localized: "Agents"))
                .font(Theme.type(.body, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 42)
            Divider().overlay(Theme.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.agents) { agent in
                            FleetAgentRow(
                                agent: agent,
                                isSelected: model.selectedAgentID == agent.id
                            )
                            .id(agent.id)
                            .onTapGesture { model.selectAgent(agent.id) }
                        }
                    }
                }
                .onChange(of: model.selectedAgentID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        // The sidebar column of a `NavigationSplitView`, so the system's glass is its surface and
        // an opaque ``Theme/panel`` would only cover it — the inbox rail's reason (ADR 0040).
        .focusable()
        .focusEffectDisabled()
        .focused($isListFocused)
        .onKeyPress(phases: .down) { press in
            handle(press)
        }
        .onAppear { isListFocused = true }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // No Escape branch: ``backButton`` carries it as a key equivalent, which is offered the
        // key before this handler is, and is in the toolbar in every state of the screen — which
        // this list is not. Two answers to one key, one of them unreachable, is how they drift
        // apart.
        if press.matches(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        if press.matches(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        // ⌘ excluded for ``InboxListView``'s reason: ⇧⌘⏎ belongs to the Review menu and must not
        // also read as "open the row under the cursor" if it reaches a list.
        if press.matches(.return), !press.modifiers.contains(.command) {
            guard let prID = model.selectedOpenPullRequestID else { return .ignored }
            environment.openReview(prID: prID)
            return .handled
        }
        return .ignored
    }

    // MARK: - The detail

    @ViewBuilder
    private var detail: some View {
        if let agent = model.selectedAgent {
            FleetAgentDetail(model: model, agent: agent)
        } else {
            EmptyStateView(
                systemImage: "person.2",
                title: String(localized: "Select an agent"),
                message: String(
                    localized: "Every agent Shepherd has seen is on the left, with what became of the work it closed."
                )
            )
        }
    }

    // MARK: - Sparse states

    private var noAgentsState: some View {
        // The button is the empty state's own `action`, not a sibling under a vertically fixed
        // copy of it: a `.fixedSize` on a column's whole content is the mechanism that drew the
        // inbox rail above the title bar (``EmptyStateView`` has the measurement), and the
        // `action` slot exists for exactly this — one way out, drawn under the message.
        EmptyStateView(
            systemImage: "person.2",
            title: String(localized: "No agents yet"),
            message: String(
                localized: "Shepherd names an author as an agent from its login, its branch prefix or a commit trailer."
            ),
            action: (
                title: String(localized: "Open Settings → Agents"),
                run: { environment.showSettings(.agents) }
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One line about a link that named an agent this fleet does not have.
    ///
    /// The whole list stays on screen underneath it. A stale link — an agent whose work all
    /// closed outside the ninety days, or one the user has since removed from their registry —
    /// is answered with the fleet and a sentence, because an empty screen after clicking a link
    /// reads as a broken app rather than as a stale link.
    private func unknownAgentNote(_ id: String) -> some View {
        Text(String(localized: "Shepherd has no agent with the id \(id). Showing the whole fleet."))
            .font(Theme.type(.subheadline))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.background)
    }

    // MARK: - Shared pieces

    /// The way back: the toolbar's navigation item, with ``ReviewToolbar``'s label, help and
    /// accessibility label — but not its Escape, which the review screen answers from its file
    /// list's key handler.
    ///
    /// It used to be a bare chevron in the agent list's header — about eleven points across, a
    /// hard thing to hit — and a second copy over the empty state, because the list is not drawn
    /// when there are no agents. The toolbar is drawn in every state, so one button covers both,
    /// and the word makes it a target rather than a glyph (ADR 0040).
    ///
    /// Escape is *this button's* shortcut rather than the list's key handler, because the list is
    /// not always there to be focused. The shortcut steps aside while ⌘K is up — a key equivalent
    /// is offered the key before the palette's own handler sees it, and Escape over an open
    /// palette means "close the palette".
    ///
    /// It goes to ``AppEnvironment/route`` directly and deliberately **not** through
    /// ``AppEnvironment/closeReview()``: that method exists to end a focus session, and there is
    /// no session here to end. A fleet that ended one on Escape would quietly cancel a queue the
    /// reader had merely stepped away from to look something up.
    private var backButton: some View {
        Button {
            environment.route = .inbox
        } label: {
            Label(String(localized: "Inbox"), systemImage: "chevron.left")
                .labelStyle(.titleAndIcon)
        }
        .keyboardShortcut(environment.isCommandPaletteVisible ? nil : KeyboardShortcut.cancelAction)
        .help(String(localized: "Back to the inbox (esc)"))
        .accessibilityLabel(Text(String(localized: "Back to the inbox")))
    }
}

/// The offer to count, on the one screen that is made entirely of counting (plan §6.1, §6.2).
///
/// The fleet is the second surface that has to explain the backfill, and it is the one where the
/// explanation is unavoidable: with nothing stored, every closed-side column on this screen is an
/// em-dash, and a page of em-dashes with no sentence beside it reads as broken rather than as
/// empty.
///
/// It presses ``AppEnvironment/startTrackRecordBackfill()`` directly rather than sending the
/// reader to Settings → Automation. Plan §6.1 routed it through Settings because the run's
/// ingredients — which repositories, read by what, stored where — lived on that tab, so a second
/// starting point would have been a second copy of them. That reason is gone: ADR 0027's
/// 2026-09-05 amendment moved all three onto ``AppEnvironment`` precisely so more than one
/// surface could offer the same run, and the progress both of them show is
/// ``TrackRecordCoordinator``'s own. Starting a backfill here and then opening Settings shows one
/// run at one position.
struct FleetHistoryCard: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "TRACK RECORD"), tint: Theme.accentText)
                Text(String(
                    localized: "Shepherd has not counted any closed pull requests yet. Loading the last 90 days lets this screen say what happened to each agent's work — at most 500 pull requests per repository, read once."
                ))
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                controls
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.background)
        // One element with its actions rather than three stops in the rotor, which is
        // ``TrackRecordNoticeView``'s arrangement and its reason: a banner is read as a whole —
        // the sentence and what can be done about it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenCard))
        .accessibilityActions {
            if environment.trackRecord.isRunning {
                Button(String(localized: "Stop")) { environment.trackRecord.cancel() }
            } else {
                Button(String(localized: "Load track record")) {
                    environment.startTrackRecordBackfill()
                }
            }
        }
    }

    /// The buttons, or the live progress line and a way out of it while a run is in flight.
    @ViewBuilder
    private var controls: some View {
        if environment.trackRecord.isRunning {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                if let progressLine {
                    Text(progressLine)
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(String(localized: "Stop")) { environment.trackRecord.cancel() }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
            }
        } else {
            HStack(spacing: 8) {
                Button(String(localized: "Load track record")) {
                    environment.startTrackRecordBackfill()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(environment.trackRecordBackfillRepositories.isEmpty)
                Spacer(minLength: 0)
            }
        }
    }

    /// The same line the Settings card and the inbox notice show, from the same coordinator.
    private var progressLine: String? {
        environment.trackRecord.progress.map { TrackRecordProgressLine.text(for: $0) }
    }

    private var spokenCard: String {
        SpokenRow.sentence([
            String(
                localized: "Shepherd has not counted any closed pull requests yet. Loading the last 90 days lets this screen say what happened to each agent's work — at most 500 pull requests per repository, read once."
            ),
            environment.trackRecord.isRunning ? progressLine : nil,
        ])
    }
}
