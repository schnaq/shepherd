import ShepherdCore
import SwiftUI

/// The full-window review screen: header, priority-bucketed file list, diff, composer.
struct ReviewScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme

    /// The active session.
    let session: SignedInSession
    /// The pull request's node id.
    let prID: String

    @State private var model: ReviewModel
    /// Whether "end the session with pull requests still in it?" is being asked.
    @State private var isEndSessionConfirmationPresented = false
    @FocusState private var isFileListFocused: Bool

    /// Creates the screen.
    /// - Parameters:
    ///   - session: The signed-in session.
    ///   - settings: The shared preference store.
    ///   - prID: The pull request to review.
    init(session: SignedInSession, settings: AppSettings, prID: String) {
        self.session = session
        self.prID = prID
        _model = State(
            initialValue: ReviewModel(session: session, settings: settings, prID: prID)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeaderView(
                model: model,
                onBack: leaveReview,
                onMerge: { model.isMergeSheetPresented = true },
                onReview: { model.isSubmitSheetPresented = true },
                onDelegate: delegate
            )
            Divider().overlay(Theme.border)
            HStack(spacing: 0) {
                ReviewFileListView(model: model)
                    .frame(width: 292)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isFileListFocused)
                    .onKeyPress(phases: .down) { press in
                        handleKey(press)
                    }
                Divider().overlay(Theme.border)
                diffArea
            }
        }
        .background(Theme.background)
        // The session bar sits above the review screen rather than inside it: the screen below is
        // the ordinary review screen, unchanged, and a session adds a strip of chrome to it.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let running = environment.reviewSession {
                ReviewSessionBar(
                    session: running,
                    onNext: { environment.skipCurrentReviewSessionItem() },
                    onDoneAndNext: { environment.completeCurrentReviewSessionItem() },
                    onEnd: leaveReview
                )
            }
        }
        .task {
            model.intelligence = environment.intelligence
            // Set before `start()`, which is what kicks off the detail fetch this hooks (ADR 0019).
            let container = environment
            model.onDidLoadDetail = { prID in
                container.searchIndexDidLoadDetail(prID: prID)
            }
            model.start()
            isFileListFocused = true
            // `r x` / `r c` from the inbox (or the command palette) land here: the verdict
            // needs a summary, so the composer opens rather than a review going out blind.
            if let verdict = environment.consumePendingReviewVerdict() {
                model.pendingVerdict = verdict
                model.isSubmitSheetPresented = true
            }
        }
        .onDisappear { model.stop() }
        // The router is a value snapshot, so a settings change has to be handed over — otherwise
        // switching intelligence on (or off) in another window leaves the drafting buttons showing
        // the state they had when this screen opened. Same hand-over as `InboxScreen`.
        .onChange(of: environment.intelligence.configuration) { _, _ in
            model.intelligence = environment.intelligence
        }
        .onChange(of: environment.pendingAction) { _, pending in
            guard let pending else { return }
            environment.clearPendingAction()
            perform(pending.action)
        }
        .sheet(isPresented: $model.isSubmitSheetPresented) {
            SubmitReviewSheet(model: model, actions: actions)
        }
        .sheet(isPresented: $model.isMergeSheetPresented) {
            if let summary = model.summary {
                MergeSheet(summary: summary, actions: actions, settings: environment.settings)
            }
        }
        .sheet(item: $model.composerRequest) { request in
            InlineCommentComposer(model: model, request: request)
        }
        // Escape is "back to the inbox" everywhere else in the app, so during a session it is
        // asked about once: the queue is the work, and dropping it by reflex on the key that
        // usually closes a panel would be the one destructive keystroke in the app.
        .alert(
            String(localized: "End the review session?"),
            isPresented: $isEndSessionConfirmationPresented,
            presenting: environment.reviewSession
        ) { _ in
            Button(String(localized: "End session"), role: .destructive) {
                environment.endReviewSession()
            }
            Button(String(localized: "Keep reviewing"), role: .cancel) {}
        } message: { running in
            Text(String(
                localized: "\(running.remaining) of \(running.total) pull requests are still in the queue. Nothing you already queued is affected."
            ))
        }
    }

    // MARK: - Diff area

    private var diffArea: some View {
        VStack(spacing: 0) {
            ReviewFileHeader(model: model, actions: actions)
            Divider().overlay(Theme.border)
            Group {
                switch model.tab {
                case .files:
                    diffOrPlaceholder
                case .conversation:
                    ConversationView(model: model, actions: actions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Theme.border)
            ReviewComposerBar(model: model, actions: actions)
        }
        .frame(maxWidth: .infinity)
        .popover(
            isPresented: Binding(
                get: { model.activeThread != nil },
                set: { if !$0 { model.activeThreadID = nil } }
            ),
            arrowEdge: .trailing
        ) {
            if let thread = model.activeThread, let summary = model.summary {
                ThreadPopover(thread: thread, summary: summary, actions: actions) {
                    model.activeThreadID = nil
                }
            }
        }
    }

    @ViewBuilder
    private var diffOrPlaceholder: some View {
        if model.isMissingFromInbox {
            missingFromInbox
        } else if model.detail == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.detail?.files.isEmpty == true {
            EmptyStateView(
                systemImage: "doc.text.magnifyingglass",
                title: String(localized: "No files"),
                message: String(localized: "GitHub reported no changed files for this pull request.")
            )
        } else if let content = model.selectedContent {
            DiffViewerView(
                content: content,
                mode: model.settings.diffUsesInlineMode ? .inline : .sideBySide,
                wrap: model.settings.diffWrapsLines,
                theme: colorScheme == .dark ? .dark : .light,
                fontSize: model.settings.diffFontSize,
                threads: model.bridgeThreads,
                draftComments: model.bridgeDraftComments,
                onEvent: { event in model.handle(event) }
            )
        } else if let path = model.selectedPath {
            DiffUnavailableView(path: path)
        } else {
            EmptyStateView(
                systemImage: "doc.text",
                title: String(localized: "Pick a file"),
                message: String(localized: "Files are ordered by review priority, riskiest first.")
            )
        }
    }

    /// Shown when the sweep pruned this pull request — it was merged, closed, or fell past the
    /// search's page cap. Any pending review is preserved and can be discarded from here.
    @ViewBuilder
    private var missingFromInbox: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                systemImage: "tray",
                title: String(localized: "This pull request is no longer in your inbox"),
                message: model.pendingCommentCount > 0 || model.draft != nil
                    ? String(localized: "It was merged, closed, or dropped out of the sweep. Your pending review is still saved locally.")
                    : String(localized: "It was merged, closed, or dropped out of the sweep.")
            )
            HStack(spacing: 8) {
                // A session lands here when the pull request under the cursor was merged or
                // closed while the user was looking at it — the advance's own vanished check
                // only fires on a move — so the way on is offered rather than only the way out.
                if environment.reviewSession != nil {
                    Button(String(localized: "Next in session")) {
                        environment.skipCurrentReviewSessionItem()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Button(String(localized: "Back to the inbox")) { environment.closeReview() }
                    .buttonStyle(SecondaryButtonStyle())
                if model.draft != nil {
                    Button(String(localized: "Discard pending review")) {
                        Task {
                            do {
                                try await model.discardDraft()
                            } catch {
                                environment.toasts.failure(
                                    error,
                                    context: String(localized: "Could not discard the review")
                                )
                            }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.failure))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Actions

    /// The write helper, with the focus session's advance hooked to the enqueue.
    ///
    /// The callback is attached here and only here: this is the screen a session walks through,
    /// so a verdict or a merge queued from it is the user finishing with the pull request under
    /// the cursor. `AppEnvironment` still checks the id, so a review submitted for anything else
    /// cannot move the queue.
    private var actions: PullRequestActions {
        PullRequestActions(
            session: session,
            toasts: environment.toasts,
            onDidQueueVerdict: { queuedID in
                environment.reviewSessionDidQueueVerdict(on: queuedID)
            }
        )
    }

    /// Leaves the review screen — and asks first when a session would be thrown away.
    private func leaveReview() {
        if environment.reviewSession != nil {
            isEndSessionConfirmationPresented = true
            return
        }
        environment.closeReview()
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .selectNext:
            model.moveFileSelection(by: 1)
        case .selectPrevious:
            model.moveFileSelection(by: -1)
        case .openSelection:
            model.tab = .files
        case .approve:
            submit(.approve)
        case .requestChanges:
            submit(.requestChanges)
        case .comment:
            submit(.comment)
        case .merge:
            model.isMergeSheetPresented = true
        case .startReviewSession:
            // Re-freezing the queue while a session is running would restart the count the user
            // is halfway through, so an already-running session simply stays as it is.
            guard environment.reviewSession == nil else { return }
            environment.startReviewSession()
        case .delegate:
            delegate()
        case .groupBy:
            break
        case .toggleMark, .markGreenAgentPullRequests, .bulkTriage:
            // Bulk triage acts on the inbox's selection, which does not exist here (ADR 0015).
            // The palette hides these commands while the review screen is up; a stray `x`
            // arriving from the key handler is simply ignored.
            break
        }
    }

    /// Hands the whole pull request to the local agent CLI (ADR 0011).
    private func delegate() {
        guard let context = model.delegationContext else { return }
        environment.startDelegation(context)
    }

    private func submit(_ verdict: ReviewVerdict) {
        model.pendingVerdict = verdict
        model.isSubmitSheetPresented = true
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.matches(.downArrow) {
            model.moveFileSelection(by: 1)
            return .handled
        }
        if press.matches(.upArrow) {
            model.moveFileSelection(by: -1)
            return .handled
        }
        if press.matches(.escape) {
            leaveReview()
            return .handled
        }
        guard press.modifiers.isEmpty, let character = press.characters.first else {
            return .ignored
        }
        if character == "v", let path = model.selectedPath {
            Task { await model.toggleViewed(path: path, actions: actions) }
            return .handled
        }
        // The session's own two keys, handled before the two-keystroke machine and only while a
        // session is running: `n` and `d` mean nothing outside one, so they are not registered as
        // global commands and cannot collide with anything in the inbox.
        if environment.reviewSession != nil {
            switch character {
            case "n":
                environment.skipCurrentReviewSessionItem()
                return .handled
            case "d":
                environment.completeCurrentReviewSessionItem()
                return .handled
            default:
                break
            }
        }
        switch model.keySequenceResult(for: character) {
        case .action(let action):
            perform(action)
            return .handled
        case .awaitingSecondKey:
            return .handled
        case .unhandled:
            return .ignored
        }
    }
}

/// The review screen's header bar.
struct ReviewHeaderView: View {
    /// The review model.
    let model: ReviewModel
    /// Returns to the inbox.
    var onBack: () -> Void
    /// Opens the merge sheet.
    var onMerge: () -> Void
    /// Opens the submit sheet.
    var onReview: () -> Void
    /// Opens the delegation sheet.
    var onDelegate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Back to the inbox (esc)"))

            if let summary = model.summary {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(summary.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textStrong)
                            .lineLimit(1)
                        Text(summary.slug)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textMuted)
                        ProvenanceChip(actor: summary.author)
                    }
                    HStack(spacing: 6) {
                        Text("\(summary.headRefName) → \(summary.baseRefName)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("· \(summary.changedFiles) files ·")
                        DiffCountsView(
                            additions: summary.additions,
                            deletions: summary.deletions,
                            size: 11
                        )
                    }
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                }
            } else {
                Text(String(localized: "Loading pull request…"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            }

            Spacer(minLength: 8)

            if let checks = model.detail?.checks, !checks.isEmpty {
                ChecksSummaryView(checks: checks)
            }

            Button(action: onDelegate) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.badge.clock")
                        .font(.system(size: 11))
                    Text(String(localized: "Delegate…"))
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 30, tint: Theme.agent))
            .disabled(model.summary == nil)
            .help(String(localized: "Hand this pull request to your local coding agent"))

            Button(action: onReview) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11))
                    Text(
                        model.pendingCommentCount > 0
                            ? String(localized: "Review · \(model.pendingCommentCount) pending")
                            : String(localized: "Review")
                    )
                }
            }
            .buttonStyle(SecondaryButtonStyle(height: 30, tint: Theme.accentText))

            Button(action: onMerge) {
                HStack(spacing: 6) {
                    Text(String(localized: "Merge"))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(SuccessButtonStyle(height: 30))
            .disabled(model.summary?.mergeable == .conflicting)
            .help(String(localized: "Merge (m)"))
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.panel)
    }
}

/// The "2/3 checks" summary in the review header.
struct ChecksSummaryView: View {
    /// The head commit's check runs.
    let checks: [CheckRun]

    var body: some View {
        let rollup = CheckRollup(runs: checks)
        HStack(spacing: 6) {
            CheckDotView(state: rollup.state, size: 7)
            Text("\(rollup.successCount)/\(rollup.total)")
                .monospacedDigit()
            Text(String(localized: "checks"))
        }
        .font(.system(size: 12))
        .foregroundStyle(color(for: rollup.state))
        .help(helpText(for: rollup))
    }

    private func color(for state: CheckRollup.State) -> Color {
        switch state {
        case .success: return Theme.success
        case .failure: return Theme.failure
        case .pending: return Theme.pending
        case .none: return Theme.textMuted
        }
    }

    private func helpText(for rollup: CheckRollup) -> String {
        String(
            localized: "\(rollup.successCount) passed, \(rollup.failureCount) failed, \(rollup.pendingCount) running"
        )
    }
}
