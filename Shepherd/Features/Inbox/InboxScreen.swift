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
            InboxSidebar(model: model, onOpenSettings: { isSettingsPresented = true })
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
        .sheet(isPresented: $isMergeSheetPresented) {
            if let summary = model.selectedRow {
                MergeSheet(summary: summary, actions: actions)
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
                .environment(environment)
                .frame(width: 620, height: 460)
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
        case .delegate:
            // The inbox has no file priorities yet, so the prompt is built from the row alone;
            // the review screen adds the focus reasons (ADR 0011).
            if let summary = model.selectedRow {
                environment.startDelegation(.pullRequest(summary))
            }
        case .groupBy(let facet):
            environment.settings.groupBy = facet
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
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textMuted)
    }
}
