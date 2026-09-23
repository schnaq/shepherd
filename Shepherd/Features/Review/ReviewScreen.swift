import ShepherdCore
import SwiftUI

/// The full-window review screen: toolbar, priority-bucketed file list, diff, composer.
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
    /// This pull request's outbox rows, observed, for the toolbar's write state.
    @State private var outboxItems: [OutboxItem] = []
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
            // The line where the toolbar's glass ends and the review begins. Kept although a
            // macOS 27 toolbar usually has none, because nothing here scrolls *under* the
            // toolbar to draw that edge with a scroll edge effect: the file list and the diff
            // start below it, and the diff is a `WKWebView` that must not have glass over it
            // (ADR 0040). Not during a focus session: the session bar is then the first thing
            // under the toolbar, draws its own line underneath, and two would stack.
            if environment.reviewSession == nil {
                Divider().overlay(Theme.border)
            }
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
                ReviewFileListView(model: model, editor: editorContext)
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
        // The header, as the window's toolbar (ADR 0040). The title and subtitle are the window's
        // own: macOS lays them out and truncates them beside the back button, and hands the title
        // to the Window menu and Mission Control.
        .navigationTitle(model.summary?.title ?? String(localized: "Loading pull request…"))
        .navigationSubtitle(subtitle)
        .toolbar {
            ReviewToolbar(
                model: model,
                checkRollup: model.checkRollup,
                write: writeState,
                onBack: leaveReview,
                onMerge: { model.isMergeSheetPresented = true },
                onReview: { model.isSubmitSheetPresented = true },
                onDelegate: delegate,
                onRetry: { Task { await session.retryFailedWrites(for: prID) } }
            )
        }
        // Here rather than on the header it used to hang off: a toolbar item is not a view with
        // a lifetime of its own to hang a `.task` on, and this screen is the one that has the id.
        .task(id: prID) {
            for await items in session.database.observeOutboxItems() {
                outboxItems = items.filter { $0.prID == prID }
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
                    checkState: model.checkRollup?.state,
                    actions: actions,
                    settings: environment.settings,
                    mergeWhenGreen: environment.mergeWhenGreen,
                    // A merged pull request is not one you are still reviewing, so the screen
                    // that was reviewing it goes away. Queued rather than done — the write is in
                    // the outbox (ADR 0006) — but the decision is made, and standing in a diff
                    // you have just decided about is the wrong place to be left.
                    onMerged: { leaveReview() }
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

    // MARK: - Diff area

    private var diffArea: some View {
        VStack(spacing: 0) {
            ReviewFileHeader(model: model, actions: actions, editor: editorContext)
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
        } else if let card = model.filesNotArrivedCard {
            // The header counts `changedFiles` off the same summary, so an empty file list beside
            // it is a contradiction rather than an empty pull request: GitHub sent the count and
            // not the files. Which of the two Shepherd believes is
            // ``ReviewModel/filesNotArrivedCard``'s sentence, shared with the file list beside
            // this pane; the retry is this pane's own, because the list has nowhere to put one.
            EmptyStateView(
                systemImage: card.systemImage,
                title: card.title,
                message: card.message,
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
        model.settings.diffRenderer.usesNativeList(voiceOverEnabled: isVoiceOverEnabled)
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

    /// The window subtitle under the pull request's title: which one, and between which branches.
    ///
    /// Verbatim, because every part of it is an identifier — a repository, a number, two branch
    /// names — and an arrow; there is nothing in it a translator could change. Empty while the
    /// summary is still loading, so the subtitle line does not flash a placeholder of its own
    /// under the title's "Loading pull request…".
    private var subtitle: Text {
        guard let summary = model.summary else { return Text(verbatim: "") }
        return Text(verbatim: "\(summary.slug) · \(summary.headRefName) → \(summary.baseRefName)")
    }

    // MARK: - Actions

    /// What the outbox is doing for this pull request (``RowWriteState``), the same state its
    /// inbox row shows.
    private var writeState: RowWriteState? {
        RowWriteState.make(
            items: outboxItems,
            for: prID,
            isMerging: environment.activity.isRunning(prID, .merge),
            wasMerged: session.mergedPullRequestIDs.contains(prID)
        )
    }

    /// "Open in …" for the file list and the file header (ADR 0039), or `nil` before the pull
    /// request's summary has loaded and there is no repository to resolve a path against.
    private var editorContext: EditorContext? {
        guard let repo = model.summary?.repo else { return nil }
        return EditorContext(
            opener: EditorOpener(settings: environment.settings, toasts: environment.toasts),
            repo: repo
        )
    }

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
            },
            telemetry: environment.telemetry
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
            // The same rule the Merge button follows, so the key cannot open a sheet the button
            // would not.
            if let writeState, writeState.isMergeOnItsWay { return }
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
        // `a` for *accept*, the motion a reviewer repeats down a diff: mark this file seen and go
        // to the next one that is not. `v` stays as the correction — it toggles and holds its
        // place — so the two keys are the two different things a reviewer means.
        if character == "a", let path = model.selectedPath {
            Task { await model.acceptFile(path: path, actions: actions) }
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

/// The review screen's controls, in the window's own toolbar (ADR 0040).
///
/// They were a 52 pt `HStack` of custom buttons on an opaque ``Theme/panel`` band, drawn *under*
/// an empty title bar — two bars' worth of height, and the one screen of the app that ignored the
/// system toolbar the inbox already uses. On macOS 27 the toolbar is Liquid Glass: its items float
/// as glass capsules over the content, the system answers Reduce Transparency, Increase Contrast
/// and Reduce Motion for them, and the window's title and subtitle carry the pull request's name
/// into the Window menu and Mission Control. So the header is the toolbar now, and everything it
/// did moved across: the help texts, the spoken labels, the disable rules, the write chip and its
/// Retry.
///
/// No `.buttonStyle(.glass)` on the ordinary items, on purpose: a toolbar item already *is*
/// system glass, and an explicit glass style inside one nests a second capsule in the first. The
/// one exception is the recommended action — Merge while it is green — which is
/// `.glassProminent`, the system's way of saying "this one" (ADR 0040's button rule).
///
/// Only one screen is in the window at a time (``SignedInRootView`` switches on the route), so
/// this and the inbox's toolbar never coexist and nothing has to be merged or hidden.
struct ReviewToolbar: ToolbarContent {
    /// The review model.
    let model: ReviewModel
    /// The freshest CI rollup, from the model (``ReviewModel/checkRollup``).
    let checkRollup: CheckRollup?
    /// What the outbox is doing for this pull request, or `nil`.
    var write: RowWriteState?
    /// Returns to the inbox.
    var onBack: () -> Void
    /// Opens the merge sheet.
    var onMerge: () -> Void
    /// Opens the submit sheet.
    var onReview: () -> Void
    /// Opens the delegation sheet.
    var onDelegate: () -> Void
    /// Sends this pull request's failed writes again.
    var onRetry: () -> Void = {}

    var body: some ToolbarContent {
        // The navigation slot, leading, where macOS puts "back". A real button with a word on
        // it: it was a bare 13 pt chevron once, a target you had to aim for, and the word stays.
        ToolbarItem(placement: .navigation) {
            Button(action: onBack) {
                Label(String(localized: "Inbox"), systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .help(String(localized: "Back to the inbox (esc)"))
            .accessibilityLabel(Text(String(localized: "Back to the inbox")))
        }

        // What the pull request *is*: who wrote it, how big it is, where CI stands. Read-only
        // facts, so the item gives up its shared glass capsule — a capsule is what a toolbar
        // says a control looks like, and chips inside one read as a button that does nothing.
        ToolbarItem(placement: .primaryAction) {
            facts
        }
        .sharedBackgroundVisibility(.hidden)

        // Only while there is something to retry, and as an item of its own so it gets the
        // toolbar's button treatment rather than a custom style inside the facts row.
        if case .failed = write {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Retry"), action: onRetry)
                    .help(String(localized: "Send the failed changes to GitHub again"))
            }
        }

        // Three groups, as on the inbox's toolbar: the facts, the hand-off to an agent, and the
        // two verdicts. One capsule around all of it would read as one control.
        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button(action: onDelegate) {
                Label(
                    String(localized: "Delegate…"),
                    systemImage: "arrow.uturn.backward.badge.clock"
                )
                .labelStyle(.titleAndIcon)
                // The agent colour the header's button had, on the label only: the capsule is
                // the system's, and a tinted capsule is reserved for the one recommended action.
                .foregroundStyle(Theme.agent)
            }
            .disabled(model.summary == nil)
            .help(String(localized: "Hand this pull request to your local coding agent"))
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: onReview) {
                Label(
                    model.pendingCommentCount > 0
                        ? String(localized: "Review · \(model.pendingCommentCount) pending")
                        : String(localized: "Review"),
                    systemImage: "square.and.pencil"
                )
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Theme.accentText)
            }
            .disabled(model.hasEndedOnGitHub)

            mergeButton
        }
    }

    /// The facts row: provenance, size, checks, and the outbox's state for this pull request.
    ///
    /// The slug and the branch line went to the window subtitle (``ReviewScreen``'s
    /// `navigationSubtitle`), which is where macOS puts "which one, exactly"; what is left is what
    /// a reviewer looks at before pressing anything to the right of it.
    private var facts: some View {
        ReviewToolbarFacts(model: model, checkRollup: checkRollup, write: write)
    }

    /// The Merge button: the toolbar's one prominent action, always (ADR 0040's 2026-09-23
    /// amendment).
    ///
    /// Merge is the primary action on every surface — the maintainer's decision — so it is
    /// `.glassProminent` tinted ``Theme/success`` whatever the checks say. What a red suite or a
    /// draft changes is whether it can be pressed, not how it looks: it used to go neutral whenever
    /// CI was not green, which made the button's *colour* one of the places a red suite was
    /// reported, and the checks summary to its left already says that in words. Disabled when
    /// GitHub would refuse the merge (``PullRequestSummary/mergeBlocker``), when the pull request
    /// has ended, and once a merge is queued or done. No chevron on the label — it opens a
    /// confirmation sheet, not a menu.
    ///
    /// The spinner is on the label itself (``SwiftUI/View/busyLabel(isBusy:tint:)``), because
    /// ``SwiftUI/View/busy(_:)`` only raises a flag that the app's *own* three styles draw, and a
    /// system style never reads it. No tint on it: it takes the label colour the prominent style
    /// picks for its fill. And the button is not `.disabled` while the merge is being sent — only
    /// once it is queued or done: the system dims a disabled toolbar item, spinner and all, and a
    /// spinner at half strength is the bug ``SwiftUI/View/busy(_:)``'s arrangement exists to
    /// prevent. The press is refused by the guard instead, the same rule `m` meets in
    /// ``ReviewScreen``'s `perform(_:)`, so neither can open a second merge sheet.
    private var mergeButton: some View {
        let isOnItsWay = write?.isMergeOnItsWay ?? false
        let isMerging = write == .merging
        let isDisabled = model.summary?.mergeBlocker != nil || model.hasEndedOnGitHub
            || (isOnItsWay && !isMerging)
        return Button {
            guard !isOnItsWay else { return }
            onMerge()
        } label: {
            Text(String(localized: "Merge"))
                .busyLabel(isBusy: isMerging)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.success)
        .disabled(isDisabled)
        .help(mergeHelp)
        .accessibilityValue(isMerging ? Text(write?.text ?? "") : Text(verbatim: ""))
    }

    /// Why the Merge button is dark, or the shortcut that presses it
    /// (``PullRequestActions/help(for:on:otherwise:)``).
    private var mergeHelp: String {
        if let write, write.isMergeOnItsWay { return write.help }
        let shortcut = String(localized: "Merge (m)")
        guard let summary = model.summary else { return shortcut }
        return PullRequestActions.help(
            for: summary.mergeBlocker,
            on: summary,
            otherwise: shortcut
        )
    }
}

/// The "2/3 checks" summary in the review toolbar.
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

/// The read-out at the head of the review toolbar's trailing items: author, size, checks and what
/// the outbox is doing.
///
/// A view of its own rather than a property of ``ReviewToolbar``, because the write chip appears
/// and disappears as a merge goes out, and an entrance that pops in reads as a glitch — so it
/// animates, and not at all when the system's Reduce Motion is on (ADR 0033), which needs the
/// environment a `ToolbarContent` does not carry.
private struct ReviewToolbarFacts: View {
    let model: ReviewModel
    let checkRollup: CheckRollup?
    let write: RowWriteState?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if let summary = model.summary {
                ProvenanceChip(actor: summary.author)
                HStack(spacing: 6) {
                    Text("· \(summary.changedFiles) files ·")
                        .lineLimit(1)
                    DiffCountsView(
                        additions: summary.additions,
                        deletions: summary.deletions,
                        size: 11
                    )
                }
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)
            }
            // The inbox row's rollup stands in while the detail has no check runs of its own
            // (``ReviewModel/checkRollup``). The sweep knows a suite is red long before the detail
            // fetch lands, and hiding the badge until then said "no checks" when the truth was
            // "not read yet". `total > 0` is the gate rather than the state, because a rollup
            // that counted nothing has nothing to show.
            if let checkRollup, checkRollup.total > 0 {
                ChecksSummaryView(rollup: checkRollup)
            }
            if let write {
                ChipView(text: write.text, color: write.color)
                    .help(write.help)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: write)
    }
}
