import ShepherdCore
import SwiftUI

/// The three-pane inbox: rail, grouped list, detail preview.
struct InboxScreen: View {
    @Environment(AppEnvironment.self) private var environment
    /// The active session.
    let session: SignedInSession

    @State private var model: InboxModel
    @State private var isMergeSheetPresented = false
    @State private var isSettingsPresented = false
    /// Whether the bulk-triage confirmation is up, and what it is confirming (ADR 0015).
    @State private var isBulkSheetPresented = false
    @State private var bulkAction: BulkTriageAction = .approve
    /// Which tab the Settings sheet opens on — the rail opens Account, a
    /// `shepherd://settings/<tab>` link opens the tab it names (ADR 0013).
    @State private var settingsTab: SettingsDeepLinkTab = .account

    /// Creates the screen for a session.
    /// - Parameters:
    ///   - session: The signed-in session.
    ///   - settings: The shared preference store (grouping and sorting live there).
    init(session: SignedInSession, settings: AppSettings) {
        self.session = session
        _model = State(initialValue: InboxModel(session: session, settings: settings))
    }

    var body: some View {
        NavigationSplitView {
            InboxSidebar(model: model, onOpenSettings: { openSettings(.account) })
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
        } content: {
            InboxListView(model: model, onOpen: open)
                .navigationSplitViewColumnWidth(min: 380, ideal: 640)
        } detail: {
            InboxDetailPanel(
                model: model,
                actions: actions,
                onOpenReview: open,
                onMerge: { isMergeSheetPresented = true }
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbarContent }
        .task {
            model.intelligence = environment.intelligence
            model.startObserving()
            // A deep link raised while the review screen was showing routes here first; the
            // request is waiting in the container by the time this screen appears.
            consumeDeepLinkRequests()
        }
        .onChange(of: environment.intelligence.configuration) { _, _ in
            model.intelligence = environment.intelligence
        }
        .onDisappear {
            model.stopObserving()
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
        .sheet(isPresented: $isMergeSheetPresented) {
            if let summary = model.selectedRow {
                MergeSheet(summary: summary, actions: actions, settings: environment.settings)
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
    }

    /// Applies whatever a `shepherd://` link asked the inbox for (ADR 0013).
    private func consumeDeepLinkRequests() {
        if let pending = environment.pendingInboxFilter {
            environment.clearPendingInboxFilter()
            model.apply(pending.value)
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

    private func perform(_ action: ShortcutAction) {
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
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textMuted)
    }
}
