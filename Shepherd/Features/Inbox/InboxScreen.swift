import GitHubKit
import ShepherdCore
import SwiftUI

/// The three-pane inbox: rail, grouped list, detail preview.
///
/// One screen, two sections. The rail's content-kind picker (ADR 0032) decides which of the two
/// models drives all three panes; both are held here for the screen's lifetime, so switching the
/// picker changes what is drawn and nothing else — the pull-request model keeps its smart view,
/// its facets, its cursor, its ticks and its half-typed key sequence, because it is never told
/// anything happened.
struct InboxScreen: View {
    @Environment(AppEnvironment.self) private var environment
    /// The active session.
    let session: SignedInSession

    @State private var model: InboxModel
    /// The issues section's model (ADR 0032).
    @State private var issueModel: IssueInboxModel
    /// Which section is showing, remembered per window.
    ///
    /// `@SceneStorage` rather than `@State`, and that is the whole of what "remembered" means
    /// here: this screen is rebuilt whenever ``AppEnvironment/route`` changes, so a `@State`
    /// property would put the picker back on *Pull requests* after every trip to the review
    /// screen — including the trip a linked pull request in the issue panel just made. Scene
    /// storage is per window and per session of the window, which is exactly the scope a picker
    /// like this has.
    ///
    /// It is deliberately **not** in ``AppSettings`` and therefore not in
    /// ``SyncedSettingsDocument``: which section a window happens to be showing is not a
    /// preference, and travelling between a user's Macs it would only ever arrive wrong
    /// (ADR 0014's obligation applies to settings, and this is UI state).
    @SceneStorage("inbox.contentKind") private var contentKind: ContentKind = .pullRequests
    /// The pull-request rail — smart view, facets, cursor — remembered per window.
    ///
    /// ``contentKind``'s reason, one level down (ADR 0013): this screen is rebuilt whenever the
    /// route changes, and `InboxModel` is `@State` here, so a trip to the review screen and back
    /// used to hand the reader a rail they had not set. It is a JSON string rather than the value
    /// because `@SceneStorage` holds what a property list can hold; ``InboxModel/RailState`` is
    /// the value, and it is `Codable` for exactly this.
    ///
    /// Not in ``AppSettings`` either, and for ``contentKind``'s second reason: which pull requests
    /// a window happens to be showing is not a preference, and it would only ever arrive wrong on
    /// another Mac (ADR 0014).
    @SceneStorage("inbox.rail") private var railStateJSON = ""
    @State private var isMergeSheetPresented = false
    /// Whether the bulk-triage confirmation is up, and what it is confirming (ADR 0015).
    @State private var isBulkSheetPresented = false
    @State private var bulkAction: BulkTriageAction = .approve

    /// Creates the screen for a session.
    /// - Parameters:
    ///   - session: The signed-in session.
    ///   - settings: The shared preference store (grouping and sorting live there).
    init(session: SignedInSession, settings: AppSettings) {
        self.session = session
        _model = State(initialValue: InboxModel(session: session, settings: settings))
        // The database and the issue read, rather than the whole session: the narrower
        // dependency is what makes `IssueInboxModel` testable without a Keychain (ADR 0032).
        _issueModel = State(
            initialValue: IssueInboxModel(
                database: session.database,
                issues: session.github,
                viewerLogin: session.account.login
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
        } content: {
            centre
                // Above the list header, as a top safe-area inset — the same mechanism the shortcut
                // bar and the review session bar use, so the cards are chrome around the list
                // rather than rows inside it, and the list keeps its own focus and key handling.
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if let report = environment.digest.report {
                            DigestCardView(
                                report: report,
                                onShow: show,
                                onDismiss: { environment.digest.dismiss() }
                            )
                        }
                        // Under the digest on the rare morning both are up: the digest is about
                        // the night that just passed and expires by itself, while this is about a
                        // feature and is answered once (ADR 0027's 2026-09-05 amendment). Only
                        // over the pull requests, because it is an offer to count *their*
                        // authors' history — an issue has no track record.
                        if contentKind == .pullRequests, model.showsTrackRecordNotice {
                            TrackRecordNoticeView(
                                onAnswer: {
                                    environment.settings.hasDismissedTrackRecordNotice = true
                                }
                            )
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 380, ideal: 640)
        } detail: {
            panel
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
        }
        .navigationSplitViewStyle(.balanced)
        // "This view has no preferred height; take the one the window gives you."
        //
        // Without it, the first layout pass after sign-in proposed the split view its *ideal*
        // height rather than the window's: measured on 2026-09-17, the split group came out
        // 1158 pt inside a 949 pt window and centred itself at y = −46, so every column was
        // drawn 79 pt too high — the rail's first rows over the traffic lights, the list header
        // level with the window title. AppKit's own divider was 897 pt throughout, the correct
        // content height, which is what says the window was right and the SwiftUI content inside
        // it was not.
        //
        // It looked intermittent because nothing forced a second pass: the layout stood, wrong,
        // until some state changed. On a cold start that was the first sweep returning, about
        // ten seconds in — long enough to be the first thing anyone sees, and short enough that
        // it was gone by the time it was investigated. Clicking any rail row fixed it instantly,
        // which is the measurement that told us it was a stale pass and not content that was too
        // tall for the window.
        .frame(maxHeight: .infinity)
        .toolbar { toolbarContent }
        .task {
            model.intelligence = environment.intelligence
            // The verdicts the chips and the RISK facet read (ADR 0023). Handed over here rather
            // than at construction for ``intelligence``'s reason: the coordinator belongs to the
            // app's lifetime, the screen is rebuilt whenever the route changes.
            model.triage = environment.triage
            // Handed over here for ``triage``'s reason once more. The inbox reads it for one
            // question only — whether to offer the backfill — and the count it asks is refreshed
            // below (ADR 0027's 2026-09-05 amendment).
            model.trackRecordCoordinator = environment.trackRecord
            // Before the observation and after the three handovers above: the rows arrive from
            // `startObserving()`, and the restored cursor has to be in place by then or the first
            // value would clamp it onto the top row (ADR 0013).
            restoreRail()
            model.startObserving()
            // Handed over here rather than at construction, for `model.intelligence`'s reason:
            // the screen is rebuilt whenever the route changes, and a queued write has to reach
            // the sync engine that outlives it.
            issueModel.drain = { [session] in await session.drainOutbox() }
            // And the tracker the panel's triage buttons read, handed over here for the same
            // reason: the screen is rebuilt whenever the route changes, and the button that has
            // to go quiet is watching an object that outlives it.
            issueModel.activity = environment.activity
            issueModel.startObserving()
            // A deep link raised while the review screen was showing routes here first; the
            // request is waiting in the container by the time this screen appears.
            consumeDeepLinkRequests()
            // One indexed `SELECT COUNT(*)`, and the notice's third condition: an inbox that
            // already has a history must not be offered one.
            await environment.refreshTrackRecordCount()
        }
        .onChange(of: environment.intelligence.configuration) { _, _ in
            model.intelligence = environment.intelligence
        }
        // Three inputs of the lanes and the badges that no inbox write reports (ADR 0027): the
        // two thresholds, which move in Settings without touching a row, and the stored history,
        // which a backfill or *Clear history* replaces wholesale.
        .onChange(of: environment.settings.trustLaneMaxFiles) { _, _ in
            model.refreshTrustLanes()
        }
        .onChange(of: environment.settings.trustLaneMaxChangedLines) { _, _ in
            model.refreshTrustLanes()
        }
        .onChange(of: environment.trackRecord.historyVersion) { _, _ in
            model.refreshTrustLanes()
            // And the count the notice reads, which the same three events move: a finished
            // backfill, *Clear history*, and a sign-out.
            Task { await environment.refreshTrackRecordCount() }
        }
        .onDisappear {
            model.stopObserving()
            issueModel.stopObserving()
        }
        .onChange(of: environment.pendingAction) { _, pending in
            guard let pending else { return }
            environment.clearPendingAction()
            perform(pending.action)
        }
        // What ⌘K's review commands act on. `initial: true` because the cursor is already on a
        // row by the time this screen is built, and a palette opened before the first `j` would
        // otherwise show none of them.
        .onChange(of: model.selectedRow, initial: true) { _, row in
            environment.selectedPullRequest = row
        }
        // Every move of the rail, written down for the next rebuild (ADR 0013). `RailState` is
        // `Equatable`, so this is silent while the reader is doing anything else — including the
        // restore above, which sets the value it just read.
        .onChange(of: model.railState) { _, state in
            storeRail(state)
        }
        .onChange(of: environment.pendingInboxFilter) { _, _ in
            consumeDeepLinkRequests()
        }
        .onChange(of: environment.pendingIssueSelection) { _, _ in
            consumeDeepLinkRequests()
        }
        .sheet(isPresented: $isMergeSheetPresented) {
            if let summary = model.selectedRow {
                MergeSheet(
                    summary: summary,
                    checkState: summary.checkRollup?.state,
                    actions: actions,
                    settings: environment.settings
                )
            }
        }
        .sheet(isPresented: $isBulkSheetPresented) {
            // Built here rather than captured when the menu was clicked: a sweep that lands
            // while the dialog is open re-partitions it instead of confirming stale state.
            BulkTriageSheet(
                plan: model.bulkPlan(for: bulkAction),
                actions: actions,
                settings: environment.settings,
                onQueued: { [model] in model.clearMarks() }
            )
        }
        // The end of a focus session, on the screen the session returns to. Here
        // rather than on the review screen because ``AppEnvironment/endReviewSession(announcing:)``
        // routes back to the inbox first — by the time there is something to show, the review
        // screen it was showing has gone.
        .sheet(isPresented: sessionSummaryBinding) {
            if let summary = environment.reviewSessionSummary {
                ReviewSessionSummaryView(summary: summary)
            }
        }
    }

    /// Whether the focus session's completion view is up.
    ///
    /// A binding onto the container's optional rather than a `@State` mirror of it: the summary
    /// is set from outside this screen, and a copy here would have to be kept in step with the
    /// one place that can set it.
    private var sessionSummaryBinding: Binding<Bool> {
        Binding(
            get: { environment.reviewSessionSummary != nil },
            set: { isPresented in
                if !isPresented { environment.clearReviewSessionSummary() }
            }
        )
    }

    // MARK: - The three panes

    /// The rail: the content-kind picker, then whichever section's facets (ADR 0032).
    private var sidebar: some View {
        VStack(spacing: 0) {
            ContentKindPicker(selection: $contentKind)
            switch contentKind {
            case .pullRequests:
                InboxSidebar(
                    model: model,
                    onOpenSettings: { environment.showSettings(.account) },
                    onWatchRepository: { environment.isAddingWatchedRepository = true },
                    watchedRepositories: environment.settings.watchedRepositories
                )
            case .issues:
                IssueSidebar(
                    model: issueModel,
                    onOpenSettings: { environment.showSettings(.account) }
                )
            }
        }
        .background(Theme.panel)
    }

    @ViewBuilder
    private var centre: some View {
        switch contentKind {
        case .pullRequests:
            // The palette is an overlay in `RootView`, not a sheet, so nothing takes the
            // keyboard away from this list by itself: while ⌘K is up, every letter the reader
            // types would otherwise also be a list shortcut.
            InboxListView(
                model: model,
                onOpen: open,
                isKeyboardOwner: !environment.isCommandPaletteVisible
            )
        case .issues:
            IssueListView(
                model: issueModel,
                isKeyboardOwner: !environment.isCommandPaletteVisible
            )
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch contentKind {
        case .pullRequests:
            InboxDetailPanel(
                model: model,
                actions: actions,
                onOpenReview: open,
                onMerge: { isMergeSheetPresented = true }
            )
        case .issues:
            IssueDetailPanel(model: issueModel)
        }
    }

    /// Puts back the rail this window was on before the screen was rebuilt (ADR 0013).
    private func restoreRail() {
        let data = Data(railStateJSON.utf8)
        guard !data.isEmpty else { return }
        do {
            model.restore(try JSONDecoder().decode(InboxModel.RailState.self, from: data))
        } catch {
            // The one failure this screen is allowed to swallow, and it is not a failure of
            // anything the reader did: a scene-storage string that will not decode is one an
            // older build wrote, and the only thing it can mean is "no rail to restore". There is
            // nothing to report and nothing to retry — the defaults are a correct inbox.
        }
    }

    /// Writes the rail down for the next rebuild (ADR 0013).
    /// - Parameter state: The rail as it now stands.
    private func storeRail(_ state: InboxModel.RailState) {
        do {
            railStateJSON = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        } catch {
            // ``InboxModel/RailState`` is plain `Codable` value types all the way down, so
            // there is nothing in it that can fail to encode — and if something somehow did,
            // there would be nothing to tell the reader: nothing they did has failed, and the
            // next move of the rail writes again. ``restoreRail()``'s argument, from the other
            // side.
        }
    }

    /// Applies whatever a `shepherd://` link asked the inbox for (ADR 0013).
    private func consumeDeepLinkRequests() {
        if let pending = environment.pendingInboxFilter {
            environment.clearPendingInboxFilter()
            // The section first, then the rail: `filter=issues` names the section and narrows
            // nothing, so `InboxRailSelection` answers `nil` for the smart view and
            // `InboxModel.apply` leaves the pull-request rail exactly as the user left it
            // (ADR 0032).
            contentKind = InboxRailSelection(pending.value).contentKind
            model.apply(pending.value)
        }
        if let pending = environment.pendingIssueSelection {
            environment.clearPendingIssueSelection()
            contentKind = .issues
            issueModel.reveal(issueID: pending.value)
        }
    }

    /// Hands one digest section over to the inbox.
    ///
    /// Every case routes through something that already exists rather than building a fifth way to
    /// filter a list: the rail mapping a `shepherd://inbox?filter=…` link uses
    /// (``InboxRailSelection``), the bulk-triage preselect (ADR 0015), and the Settings tab the
    /// parked reviews are actually dealt with on.
    /// - Parameter kind: The section whose *Show* was pressed.
    private func show(_ kind: DigestSectionKind) {
        switch kind {
        case .newReviewRequests:
            model.apply(.needsMyReview)
        case .issuesAssignedToYou, .agentPullRequestsThatClosedAnIssue:
            // The picker, and nothing else. There is no "assigned to me" rail state on the issues
            // side — the whole section is already the three relations the sweep searches — and
            // inventing a facet for one digest line would be a second vocabulary nobody asked
            // for (ADR 0032).
            contentKind = .issues
        case .greenAgentPullRequests:
            // "Involved" first, because an agent's pull request that is green and unmerged is
            // usually not one that asked for a review — the "Needs my review" rail would show an
            // empty list for a line that just promised four pull requests. Then the ordinary
            // preselect ticks them, which is exactly what "only needs approve or merge" means: the
            // next step is the bulk-triage dialog.
            model.apply(.involved)
            markGreenAgentRows()
        case .ownPullRequestsNeedingAttention:
            model.apply(.myPullRequests)
        case .parkedReviews, .failedWrites:
            // Not an inbox filter at all: both are outbox rows, and Settings → Sync is where they
            // are counted and explained — and, for the failed ones, retried or discarded.
            environment.showSettings(.sync)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                environment.isCommandPaletteVisible = true
            } label: {
                Label(String(localized: "Search pull requests…"), systemImage: "magnifyingglass")
            }
            .help(String(localized: "Command palette (⌘K)"))
        }

        // Three groups rather than one, with `ToolbarSpacer` between them (macOS 26). A single
        // `ToolbarItemGroup` draws everything in it as one capsule, which put the sync status,
        // the triage menu, the refresh button and the account avatar shoulder to shoulder in a
        // row that reads as one control. They are three unrelated things: where the data stands,
        // what to do with the selection, and whose account this is. The spacers give each its own
        // capsule and the system's own spacing between them.
        ToolbarItem(placement: .primaryAction) {
            SyncStatusView(session: session)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button(String(localized: "Select all green agent pull requests")) {
                    markGreenAgentRows()
                }
                Divider()
                ForEach(BulkTriageAction.allCases, id: \.self) { action in
                    Button(action.commandTitle) { presentBulkTriage(action) }
                        .disabled(!model.hasMarks)
                }
                Divider()
                Button(String(localized: "Clear the selection")) { model.clearMarks() }
                    .disabled(!model.hasMarks)
            } label: {
                Label(bulkTriageTitle, systemImage: "checklist")
            }
            .help(String(localized: "Bulk triage: approve or merge the selected pull requests"))
            // A toolbar menu draws the symbol alone and hands the symbol's *name* to
            // accessibility with it: VoiceOver read this button out as "checklist"
            // (2026-09-09 live test). What it should hear is the title the button would show if
            // it showed one — including the count, once rows are ticked.
            .accessibilityLabel(Text(bulkTriageTitle))

            Button {
                Task { await environment.syncNow() }
            } label: {
                Label(String(localized: "Sync now"), systemImage: "arrow.clockwise")
            }
            .help(String(localized: "Sync now (⌘R)"))
            .disabled(session.isSyncing)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            AvatarView(
                login: session.account.login,
                url: session.account.avatarURL,
                size: 22
            )
            .help(Text(session.account.login))
        }
    }

    /// What the bulk-triage menu is called: on screen if it ever draws its title, and to
    /// VoiceOver, which is the only place it is ever actually read.
    private var bulkTriageTitle: String {
        model.hasMarks
            ? String(localized: "Triage \(model.markedIDs.count) selected")
            : String(localized: "Bulk triage")
    }

    // MARK: - Actions

    private var actions: PullRequestActions {
        PullRequestActions(
            session: session,
            toasts: environment.toasts,
            activity: environment.activity
        )
    }

    private func open(_ prID: String) {
        environment.openReview(prID: prID)
    }

    /// Runs one raised command against the model that owns the current selection (ADR 0032).
    ///
    /// The navigation pair goes to whichever section is showing — which is the plan's own
    /// wording, and is why `j`/`k` needed no new mechanism: both lists raise the same action and
    /// the container decides. Everything else is a pull-request verb. Rather than let `r a` from
    /// the menu bar or the palette approve a pull request the user cannot see, those are refused
    /// with one line while the issues section is up; the two exceptions are the focus session,
    /// which builds its queue from the session's own observation and not from a screen's list,
    /// and the grouping commands, which change a preference.
    private func perform(_ action: ShortcutAction) {
        if contentKind == .issues {
            switch action {
            case .selectNext:
                issueModel.moveSelection(by: 1)
                return
            case .selectPrevious:
                issueModel.moveSelection(by: -1)
                return
            case .startReviewSession, .groupBy:
                break
            default:
                environment.toasts.info(
                    String(
                        localized: "That command works on pull requests. Switch the section with the picker."
                    )
                )
                return
            }
        }
        switch action {
        case .selectNext:
            model.moveSelection(by: 1)
        case .selectPrevious:
            model.moveSelection(by: -1)
        case .openSelection:
            if let id = model.selectedID { open(id) }
        case .approve:
            // An approval is the one verdict GitHub accepts without a summary body.
            queueReview(.approve)
        case .requestChanges:
            // `REQUEST_CHANGES` and `COMMENT` require a body, so these open the review
            // screen's composer instead of firing a review GitHub would answer 422 to.
            compose(.requestChanges)
        case .comment:
            compose(.comment)
        case .merge:
            if model.selectedRow != nil { isMergeSheetPresented = true }
        case .startReviewSession:
            // The queue is frozen from the session's own inbox observation, not from this
            // screen's filtered list, so nothing about the rail's current facets is passed in.
            environment.startReviewSession()
        case .delegate:
            // The inbox has no file priorities yet, so the prompt is built from the row alone;
            // the review screen adds the focus reasons (ADR 0011).
            if let summary = model.selectedRow {
                environment.startDelegation(.pullRequest(summary))
            }
        case .groupBy(let facet):
            environment.settings.groupBy = facet
        case .toggleMark:
            if let id = model.selectedID { model.toggleMark(id) }
        case .markGreenAgentPullRequests:
            markGreenAgentRows()
        case .bulkTriage(let bulk):
            presentBulkTriage(bulk)
        }
    }

    /// Ticks the green agent pull requests of the current view and says how many (ADR 0015).
    ///
    /// The count is the point: a preselect that silently did nothing — because everything is
    /// still building, or nothing is green — would look like a broken menu item.
    private func markGreenAgentRows() {
        let count = model.markGreenAgentRows()
        if count == 0 {
            environment.toasts.info(
                String(localized: "No green agent pull request in this view.")
            )
        } else {
            environment.toasts.info(String(localized: "\(count) selected."))
        }
    }

    /// Opens the one confirmation dialog for a bulk action.
    private func presentBulkTriage(_ action: BulkTriageAction) {
        guard model.hasMarks else {
            environment.toasts.info(
                String(localized: "Select pull requests first — press x, or ⌘-click rows.")
            )
            return
        }
        bulkAction = action
        // The drafts of the ticked rows are read *before* the dialog comes up: one of the notes
        // it shows is "this pull request has draft comments on an older commit", and a note that
        // arrived after the confirm button would be no warning at all (ADR 0015). One local
        // query on the rows the user ticked.
        Task {
            await model.loadMarkedDrafts()
            isBulkSheetPresented = true
        }
    }

    private func queueReview(_ verdict: ReviewVerdict) {
        guard let summary = model.selectedRow else { return }
        Task {
            await actions.submitReview(on: summary, verdict: verdict)
        }
    }

    /// Opens the review screen with its submit composer already showing the verdict.
    private func compose(_ verdict: ReviewVerdict) {
        guard let id = model.selectedID else { return }
        environment.openReview(prID: id, composing: verdict)
    }
}

/// The "Synced · 32 s ago" indicator from the mockup's title bar.
struct SyncStatusView: View {
    /// The active session.
    let session: SignedInSession
    /// Needed only so the failed-writes text below can act as a button to Settings → Sync.
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                // Failure outranks the merely-parked state, and a failed write is a failure even
                // while a *different* sync attempt is still succeeding — the dot has to say the
                // worst true thing, not just the most recent one.
                .fill(dotColor)
                .frame(width: 6, height: 6)
            if session.isSyncing {
                Text(String(localized: "Syncing…"))
            } else if let error = session.lastSyncError {
                Text(String(localized: "Sync failed"))
                    .help(error)
            } else if let date = session.lastSyncedAt {
                // The separator is not decoration. Without it the two words run together as
                // "Synchronisiert jetzt", which German reads as a verb in the present tense —
                // "synchronises now", a claim about what the app is doing rather than about when
                // it last finished. English survives it ("Synced now") and German does not, and
                // the mockup this came from had the middot anyway.
                HStack(spacing: 4) {
                    Text(String(localized: "Synced"))
                    Text(verbatim: "·").foregroundStyle(Theme.textMuted)
                    RelativeDateText(date: date)
                }
            } else if session.failedOutboxCount == 0 {
                // "Not synced yet" would be a lie once there are failed writes on record — those
                // came from a sync that did happen.
                Text(String(localized: "Not synced yet"))
            }
            // Parked mutations do not drain by themselves (ADR 0006), so the title bar says so
            // for as long as they sit there — the conflict alert is only shown once.
            if session.conflictedOutboxCount > 0 {
                Text(String(localized: "· \(session.conflictedOutboxCount) not sent"))
                    .foregroundStyle(Theme.pending)
                    .help(String(
                        localized: "Queued reviews that were parked because the pull request moved on. Settings → Sync has the count; open the pull request to check your draft."
                    ))
            }
            // And the third state, the one this side of the app could not say until now: a write
            // the drain **gave up on**. It is not coming back by itself either, and unlike a
            // parked one there is no draft to re-apply and no alert that ever raised it — a 4xx
            // from GitHub simply ends the row. The issue panel says exactly this about one issue
            // (ADR 0032); this is the same sentence about the account.
            if session.failedOutboxCount > 0 {
                Text(verbatim: "·")
                // A status line that names the fix but does not let you take it is a dead end —
                // Settings → Sync is one click away everywhere else this count is mentioned
                // (the toolbar menu at `.failedWrites` above), so the title bar should not be the
                // one place you have to go find it yourself.
                Button {
                    environment.showSettings(.sync)
                } label: {
                    Text(String(localized: "\(session.failedOutboxCount) failed — see Settings → Sync"))
                        .foregroundStyle(Theme.failure)
                }
                .buttonStyle(.plain)
                .help(String(
                    localized: "Queued writes Shepherd gave up on: GitHub refused them, or they could not be made at all. They are never retried by themselves — Settings → Sync lists each one and offers Retry or Discard."
                ))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textMuted)
        .lineLimit(1)
        // Without this the line is handed a width by the toolbar and truncates inside its own
        // glass capsule — "Wird synchronisiert…" lost its last letters against the capsule's
        // edge. `fixedSize` makes it ask for the width it actually needs; the padding keeps the
        // text off the capsule's rim, which is drawn tight around the item.
        //
        // 10 pt rather than the 4 it started with: 4 cleared the rim and nothing more, so the
        // capsule read as a label someone had forgotten to pad rather than as a control. The dot
        // and the text inside it are 6 pt apart, and a gutter narrower than that gap makes the
        // whole group look pushed against the glass.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
    }

    /// The worst true state wins: a failed write outranks "synced fine a moment ago", and a
    /// merely parked (conflicted) write outranks a clean success but not a failure.
    /// "Not synced yet" is amber rather than green, and it used to be green: the dot is the
    /// one-glance version of the sentence beside it, and green says *this worked*. Before the
    /// first sweep lands nothing has worked — the inbox on screen is empty because it is
    /// unfilled, not because it is clear — and a green dot over an empty list is the app claiming
    /// to be up to date when it has never spoken to GitHub. Amber, not red, because it is not a
    /// failure either; it usually resolves itself within a sweep.
    private var dotColor: Color {
        if session.lastSyncError != nil || session.failedOutboxCount > 0 {
            Theme.failure
        } else if session.conflictedOutboxCount > 0 || session.lastSyncedAt == nil {
            Theme.pending
        } else {
            Theme.success
        }
    }
}
