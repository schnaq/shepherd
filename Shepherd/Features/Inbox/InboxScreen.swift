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
    @State private var isMergeSheetPresented = false
    @State private var isSettingsPresented = false
    /// Whether the bulk-triage confirmation is up, and what it is confirming (ADR 0015).
    @State private var isBulkSheetPresented = false
    @State private var bulkAction: BulkTriageAction = .approve
    /// Which tab the Settings sheet opens on — the rail opens Account, a
    /// `shepherd://settings/<tab>` link opens the tab it names (ADR 0013).
    @State private var settingsTab: SettingsDeepLinkTab = .account
    /// Whether the conversation composer is up.
    @State private var isCommentSheetPresented = false
    /// What has been typed into it, held here so dismissing the sheet does not lose the text —
    /// the same reason the issue panel holds its own.
    @State private var commentBody = ""

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
            model.startObserving()
            // Handed over here rather than at construction, for `model.intelligence`'s reason:
            // the screen is rebuilt whenever the route changes, and a queued write has to reach
            // the sync engine that outlives it.
            issueModel.drain = { [session] in await session.drainOutbox() }
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
        .onChange(of: environment.pendingInboxFilter) { _, _ in
            consumeDeepLinkRequests()
        }
        .onChange(of: environment.pendingSettingsTab) { _, _ in
            consumeDeepLinkRequests()
        }
        .onChange(of: environment.pendingIssueSelection) { _, _ in
            consumeDeepLinkRequests()
        }
        .sheet(isPresented: $isMergeSheetPresented) {
            if let summary = model.selectedRow {
                MergeSheet(summary: summary, actions: actions, settings: environment.settings)
            }
        }
        .sheet(isPresented: $isCommentSheetPresented) {
            if let summary = model.selectedRow {
                PullRequestCommentSheet(
                    summary: summary,
                    actions: actions,
                    text: $commentBody
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
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(initialTab: settingsTab)
                .environment(environment)
                .frame(width: 620, height: 460)
                .id(settingsTab)
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
                InboxSidebar(model: model, onOpenSettings: { openSettings(.account) })
            case .issues:
                IssueSidebar(model: issueModel, onOpenSettings: { openSettings(.account) })
            }
        }
        .background(Theme.panel)
    }

    @ViewBuilder
    private var centre: some View {
        switch contentKind {
        case .pullRequests:
            InboxListView(model: model, onOpen: open)
        case .issues:
            IssueListView(model: issueModel)
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
                onMerge: { isMergeSheetPresented = true },
                onComment: { isCommentSheetPresented = true }
            )
        case .issues:
            IssueDetailPanel(model: issueModel)
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
        if let pending = environment.pendingSettingsTab {
            environment.clearPendingSettingsTab()
            openSettings(pending.value)
        }
    }

    private func openSettings(_ tab: SettingsDeepLinkTab) {
        settingsTab = tab
        isSettingsPresented = true
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
            openSettings(.sync)
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

        ToolbarItemGroup(placement: .primaryAction) {
            SyncStatusView(session: session)

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
                Label(
                    model.hasMarks
                        ? String(localized: "Triage \(model.markedIDs.count) selected")
                        : String(localized: "Bulk triage"),
                    systemImage: "checklist"
                )
            }
            .help(String(localized: "Bulk triage: approve or merge the selected pull requests"))

            Button {
                Task { await environment.syncNow() }
            } label: {
                Label(String(localized: "Sync now"), systemImage: "arrow.clockwise")
            }
            .help(String(localized: "Sync now (⌘R)"))
            .disabled(session.isSyncing)

            AvatarView(
                login: session.account.login,
                url: session.account.avatarURL,
                size: 22
            )
            .help(Text(session.account.login))
        }
    }

    // MARK: - Actions

    private var actions: PullRequestActions {
        PullRequestActions(session: session, toasts: environment.toasts)
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

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.lastSyncError == nil ? Theme.success : Theme.failure)
                .frame(width: 6, height: 6)
            if session.isSyncing {
                Text(String(localized: "Syncing…"))
            } else if let error = session.lastSyncError {
                Text(String(localized: "Sync failed"))
                    .help(error)
            } else if let date = session.lastSyncedAt {
                HStack(spacing: 4) {
                    Text(String(localized: "Synced"))
                    RelativeDateText(date: date)
                }
            } else {
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
                Text(String(localized: "\(session.failedOutboxCount) failed — see Settings → Sync"))
                    .foregroundStyle(Theme.failure)
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
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 4)
    }
}
