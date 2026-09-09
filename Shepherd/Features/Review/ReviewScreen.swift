import ShepherdCore
import SwiftUI

/// The full-window review screen: header, priority-bucketed file list, diff, composer.
struct ReviewScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    /// Whether VoiceOver is running. The diff viewer needs telling, because Monaco cannot work
    /// it out from inside a `WKWebView` (ADR 0033's second amendment).
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled

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
                checkRollup: headerCheckRollup,
                onBack: leaveReview,
                onMerge: { model.isMergeSheetPresented = true },
                onReview: { model.isSubmitSheetPresented = true },
                onDelegate: delegate
            )
            Divider().overlay(Theme.border)
            // Above everything the review is made of, because it is about all of it: the file
            // list, the diff and the composer are all showing a head commit that GitHub may have
            // moved past.
            if let notice = model.notice {
                ReviewUpdateBanner(
                    notice: notice,
                    onReload: { model.reloadPendingUpdate() },
                    onRetry: { model.load() }
                )
            }
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
        // ⌘K works here too, and here the "selection" is the pull request being reviewed.
        .onChange(of: model.summary, initial: true) { _, summary in
            environment.selectedPullRequest = summary
        }
        .sheet(isPresented: $model.isSubmitSheetPresented) {
            SubmitReviewSheet(model: model, actions: actions)
        }
        // The sheet's warning — "checks are failing", "GitHub reports conflicts" — is built from
        // the row it is handed, and the row is ``ReviewModel/summary``, which is the observed
        // detail's own summary. So the closure is read again whenever the detail observation
        // writes, and a merge dialog left open while CI turns red says so rather than repeating
        // what was true when it opened.
        .sheet(isPresented: $model.isMergeSheetPresented) {
            if let summary = model.summary {
                MergeSheet(
                    summary: summary,
                    checkState: headerCheckRollup?.state,
                    actions: actions,
                    settings: environment.settings
                )
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

    /// The freshest CI rollup Shepherd knows for this pull request.
    ///
    /// The detail's own check runs when there are any, because they are what the header's
    /// "2/3 checks" is counting and they are re-read on every reload; the inbox row's rollup only
    /// while the detail is still loading. Derived with ``ShepherdCore/CheckRollup/init(runs:)``
    /// rather than by a second hand-rolled mapping — one definition of "red", "still running" and
    /// "green" for the badge, the Merge button's colour and the merge sheet's warning.
    ///
    /// The whole rollup rather than only its state, because the badge needs the counts and the
    /// two callers that only want the verdict can ask for `.state`. One fallback chain, read
    /// three ways.
    ///
    /// The fallback cannot show a fraction: the sweep's rollup is built from GraphQL's
    /// `statusCheckRollup`, which reports a verdict and a context total and no split at all, so
    /// its ``ShepherdCore/CheckRollup/successCount`` is zero by construction
    /// (`GitHubKit/Mapping/ResponseMapping.swift`) and "0/3" would be a fact nobody measured.
    /// ``ChecksSummaryView`` draws "3 checks" for it instead.
    private var headerCheckRollup: CheckRollup? {
        if let checks = model.detail?.checks, !checks.isEmpty {
            return CheckRollup(runs: checks)
        }
        return model.summary?.checkRollup
    }

    // MARK: - Diff area

    private var diffArea: some View {
        VStack(spacing: 0) {
            ReviewFileHeader(model: model, actions: actions)
            Divider().overlay(Theme.border)
            // Under the round picker, and only while it is showing that round: the findings are
            // the other half of "since your review" — the diff says what the agent changed, the
            // list says what became of what you asked for (ADR 0028).
            if model.tab == .files, model.roundView == .sinceReview, !model.findings.isEmpty {
                SinceReviewFindingsView(model: model)
                Divider().overlay(Theme.border)
            }
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
        } else if let error = model.detailLoadErrorCard {
            // Only with nothing readable behind it, and ahead of the "Files have not arrived yet"
            // card below because the two overlap: a Try again pressed there that failed has to
            // say why rather than redraw the same sentence. A refresh that fails over a diff the
            // reviewer *is* reading keeps the diff and speaks through the banner instead
            // (``ReviewModel/Notice/refreshFailed(message:)``) — hiding a working diff to report
            // that it could not be re-checked throws away the more useful half. The card is for
            // the case the live test found: an empty Monaco, gutters and no text, saying nothing.
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: String(localized: "Could not load this pull request"),
                message: error,
                action: (title: String(localized: "Try again"), run: { model.load() })
            )
        } else if model.detail == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.detail?.files.isEmpty == true,
                  let claimed = model.summary?.changedFiles, claimed > 0 {
            // The header counts `changedFiles` off the same summary, so an empty file list beside
            // it is a contradiction rather than an empty pull request: GitHub sent the count and
            // not the files. Say which of the two Shepherd believes, and offer the retry.
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: String(localized: "Files have not arrived yet"),
                message: String(
                    localized: "GitHub reports \(claimed) changed files, but sent none of them."
                ),
                action: (title: String(localized: "Try again"), run: { model.load() })
            )
        } else if model.detail?.files.isEmpty == true {
            EmptyStateView(
                systemImage: "doc.text.magnifyingglass",
                title: String(localized: "No files"),
                message: String(localized: "GitHub reported no changed files for this pull request.")
            )
        } else if model.roundView == .sinceReview, model.visiblePriorities.isEmpty {
            EmptyStateView(
                systemImage: "checkmark.circle",
                title: String(localized: "Nothing new"),
                message: String(localized: "No file changed since the head you reviewed.")
            )
        } else if let content = model.selectedContent {
            // The one branch that chooses a renderer. Everything around it — the file header, the
            // round picker, the findings list, the composer bar, the thread popover — keys off the
            // model rather than off which of the two is drawing, so none of it knows or cares.
            if usesNativeList, let listContent = model.selectedListContent {
                DiffListView(
                    model: model,
                    content: listContent,
                    fontSize: model.settings.diffFontSize,
                    wraps: model.settings.diffWrapsLines,
                    // `c`, `[` and `]` pressed on the native screen raise this counter; in this
                    // mode it moves the keyboard into the list rather than into Monaco. One
                    // mechanism, because it is one question: who has the keyboard now.
                    focusRequest: model.focusEditorRequest,
                    onExit: { isFileListFocused = true }
                )
            } else {
                DiffViewerView(
                    content: content,
                    mode: model.settings.diffUsesInlineMode ? .inline : .sideBySide,
                    wrap: model.settings.diffWrapsLines,
                    theme: colorScheme == .dark ? .dark : .light,
                    fontSize: model.settings.diffFontSize,
                    threads: model.bridgeThreads,
                    draftComments: model.bridgeDraftComments,
                    // Set only by the CI diagnosis card's `file:line` link (plan §3.F); the
                    // viewer acts on a change of it and ignores it otherwise.
                    revealLine: model.revealLine,
                    // Raised by `c`, `[` and `]` pressed outside the diff (ADR 0033's
                    // amendment): the native screen owns the keys that act on a *file*, the
                    // editor owns the keys that act on a *line*, and this is the command that
                    // carries the keyboard across. The side is what makes a deleted line
                    // reachable — `[` is the original pane.
                    focusRequest: model.focusEditorRequest,
                    focusSide: model.focusEditorSide,
                    screenReader: isVoiceOverEnabled,
                    onEvent: { event in model.handle(event) }
                )
            }
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

    /// Whether the native, walkable list draws the diff rather than Monaco.
    ///
    /// The setting decides, and ``DiffRenderer/automatic`` decides by asking whether a screen
    /// reader is listening — which is a runtime condition rather than a stored one, and the reason
    /// that setting is three states and not a toggle. `accessibilityVoiceOverEnabled` is live, so
    /// turning VoiceOver on mid-review swaps the renderer under the reviewer rather than waiting
    /// for the next launch.
    private var usesNativeList: Bool {
        switch model.settings.diffRenderer {
        case .native: return true
        case .web: return false
        case .automatic: return isVoiceOverEnabled
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
            activity: environment.activity,
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
            model.setTab(.files)
        case .approve:
            submit(.approve)
        case .requestChanges:
            submit(.requestChanges)
        case .comment:
            submit(.comment)
        case .merge:
            guard !model.hasEndedOnGitHub else { return }
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
        // The keys and the palette reach the same three verdicts the composer bar's buttons do,
        // so they need the same refusal: a review submitted against a pull request that has
        // already been merged or closed would sit in the outbox until the drain threw it away.
        guard !model.hasEndedOnGitHub else { return }
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
        // `u` for *update*: the banner's Reload as a key. Free both as a bare key and as the
        // second half of a sequence — `r` and `g` are the only prefixes and neither claims it —
        // and deliberately not ⌘R, which is the app's Sync Now and writes to the database rather
        // than to this screen. Ignored when there is nothing held back, so the key travels on
        // rather than being eaten by a view that had no answer for it.
        if character == "u", !model.isAwaitingSecondKey, model.canReloadPendingUpdate {
            model.reloadPendingUpdate()
            return .handled
        }
        // `t` for *tab*: Files and Conversation, back and forth. Free both as a bare key and as
        // the second half of a sequence — `r` and `g` are the only prefixes, and neither claims
        // it — and a letter rather than ⇥, which macOS spends on moving the focus ring. It is
        // the other half of opening an agent's pull request on Conversation: a reviewer who
        // wanted the diff has to be able to get there without reaching for the mouse. The guard
        // is the one `c` needs, for the same reason.
        if character == "t", !model.isAwaitingSecondKey {
            model.setTab(model.tab == .files ? .conversation : .files)
            return .handled
        }
        // `c` reaches this handler only when the diff does *not* have the focus — inside it the
        // editor takes the key and comments on the cursor's line. So the honest thing for it to
        // do here is hand the keyboard over, which is the step that was missing: every review
        // action had a key except the one that needed a cursor, because there was no way to get
        // a cursor without a mouse (ADR 0033's amendment).
        //
        // Unless a prefix is armed, and this is the reason that guard is here: `r c` submits the
        // review as a comment. Acting on the bare key first would eat the second half of that
        // sequence *and* leave the prefix armed, so the keystroke after it would be read as a
        // second key as well.
        if character == "c", !model.isAwaitingSecondKey {
            model.requestEditorFocus()
            return .handled
        }
        // `[` and `]` name a pane, here and inside the editor alike: the original side and the
        // modified one, where they sit on the keyboard and on the screen. Without them a comment
        // on a *deleted* line stayed mouse-only, because `c` lands in the modified pane and a
        // deletion exists only in the other one.
        //
        // Brackets rather than a letter deliberately: a letter would have to be free as a bare
        // key *and* as the second half of `r …` and `g …`, and the editor — which needs the same
        // key — cannot see that a prefix is armed over here. The guard below is the same one `c`
        // needs, for the same reason.
        if character == "[" || character == "]", !model.isAwaitingSecondKey {
            model.requestEditorFocus(side: character == "[" ? .left : .right)
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
    /// The freshest CI rollup, from the screen (``ReviewScreen/headerCheckRollup``).
    let checkRollup: CheckRollup?
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
            .accessibilityLabel(Text(String(localized: "Back to the inbox")))

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
                            .lineLimit(1)
                            .truncationMode(.middle)
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

            // The inbox row's rollup stands in while the detail has no check runs of its own
            // (``ReviewScreen/headerCheckRollup``). The sweep knows a suite is red long before
            // the detail fetch lands, and hiding the badge until then said "no checks" when the
            // truth was "not read yet". `total > 0` is the gate rather than the state, because a
            // rollup that counted nothing has nothing to show.
            if let checkRollup, checkRollup.total > 0 {
                ChecksSummaryView(rollup: checkRollup)
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
            .disabled(model.hasEndedOnGitHub)

            mergeButton
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.panel)
    }

    /// The Merge button, green only when merging is the next thing to do.
    ///
    /// Green is a recommendation, and the header used to make it on nothing at all: a draft or a
    /// red suite got the same success-green button as a pull request waiting to land, and the
    /// only thing that dimmed it was a conflict. Now it is green when nothing blocks the merge
    /// *and* CI is green, and neutral otherwise. No chevron on the label either — it opens a
    /// confirmation sheet, not a menu, and the arrow promised one.
    ///
    /// Written as two buttons rather than one with a computed style because a `ButtonStyle` is a
    /// type: there is no value both styles fit in without erasing them.
    @ViewBuilder
    private var mergeButton: some View {
        let isDisabled = model.summary?.mergeBlocker != nil || model.hasEndedOnGitHub
        if model.summary?.mergeBlocker == nil, checkRollup?.state == .success {
            Button(action: onMerge) { Text(String(localized: "Merge")) }
                .buttonStyle(SuccessButtonStyle(height: 30))
                .disabled(isDisabled)
                .help(mergeHelp)
        } else {
            Button(action: onMerge) { Text(String(localized: "Merge")) }
                .buttonStyle(SecondaryButtonStyle(height: 30))
                .disabled(isDisabled)
                .help(mergeHelp)
        }
    }

    /// Why the Merge button is dark, or the shortcut that presses it.
    private var mergeHelp: String {
        guard let summary = model.summary, let blocker = summary.mergeBlocker else {
            return String(localized: "Merge (m)")
        }
        return PullRequestActions.blockerMessage(blocker, slug: summary.slug)
    }
}

/// The "2/3 checks" summary in the review header.
struct ChecksSummaryView: View {
    /// The rolled-up state of the head commit's checks.
    ///
    /// A rollup rather than the check runs, because two kinds of caller have one: the detail's
    /// runs, counted with ``ShepherdCore/CheckRollup/init(runs:)``, and the inbox row's, which
    /// the sweep built from GraphQL's `statusCheckRollup`. The second knows the state and the
    /// number of contexts but not the split — ``ShepherdCore/CheckRollup/successCount`` is zero
    /// there (see `ResponseMapping.pullRequestSummary(from:relations:detector:)`) — so the
    /// fraction is drawn only when somebody actually counted, and "3 checks" beside the dot
    /// otherwise: it is every fact there is, and "0/3" would be a wrong one.
    let rollup: CheckRollup

    /// Whether the rollup carries the per-outcome split, or only a verdict and a total.
    private var hasCounts: Bool {
        rollup.successCount + rollup.failureCount + rollup.pendingCount > 0
    }

    var body: some View {
        HStack(spacing: 6) {
            CheckDotView(state: rollup.state, size: 7)
            if hasCounts {
                Text("\(rollup.successCount)/\(rollup.total)")
                    .monospacedDigit()
            } else {
                // `verbatim` because a bare number is the same in every language, and giving it a
                // catalog key would ask a translator to translate "3".
                Text(verbatim: "\(rollup.total)")
                    .monospacedDigit()
            }
            Text(String(localized: "checks"))
        }
        .font(.system(size: 12))
        .foregroundStyle(color(for: rollup.state))
        .help(
            hasCounts
                ? helpText(for: rollup)
                : String(
                    localized: "\(rollup.total) checks on the head commit; Shepherd has not read them yet."
                )
        )
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
