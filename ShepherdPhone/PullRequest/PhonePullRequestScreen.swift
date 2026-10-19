import ShepherdCore
import ShepherdPersistence
import SwiftUI

/// Where the pull request screen's *Files* row goes: the file list and the diff of one pull
/// request (ADR 0044).
///
/// A value rather than a view for ``PhoneRoute``'s reason. It is pushed with
/// `navigationDestination(item:)` *inside* ``PhonePullRequestScreen`` rather than appended to the
/// router's path: the path is `[PhoneRoute]`, a typed array that cannot carry a second type, and
/// the files screen has to share this screen's ``ReviewModel`` — the selected file, the drafts and
/// the round are all on it — which a destination registered here gets for free. The price: the
/// router's path does not know about it, so a path change from the shell (a deep link) leaves it
/// out — to be settled together with the router.
///
/// With a ``path`` it is *Show in diff*: that file's diff is pushed straight from the
/// conversation, so Back returns to the thread it came from rather than to the file list.
struct PhoneFilesDestination: Hashable {
    /// The pull request's node id.
    let prID: String
    /// The file to open at once, or `nil` for the file list.
    var path: String?
    /// The line to scroll that file's diff to.
    var line: Int?
}

/// One pull request on the phone (ADR 0044): what it is, what it says, what everyone said about it,
/// and the verdicts and the merge as the bottom bar.
///
/// Top to bottom in one scroll: the banner when GitHub moved on, the header card (state, slug,
/// title, author, branches, CI, size, what the outbox is doing), the *Files* row, the description
/// as the first post, the conversation in GitHub's order (``PhoneConversationStream``) and the
/// checks. The Mac splits the same content over a Files and a Conversation tab; a phone has the
/// width for one, so the conversation is the screen and the files are a push away.
///
/// The bottom bar keeps the Mac toolbar's shape (ADR 0040): the verdict pair, *Review*, and Merge —
/// the one green, prominent glass button. The ⋯ menu is ``PullRequestMoreMenuItems`` plus the
/// phone's copy and share. Every write goes through ``PullRequestActions``, so the refusal rules,
/// the outbox and the double-press guard (``ActionActivity``) are the Mac's own.
///
/// **The model's lifecycle is the caller's.** This screen neither starts nor stops its
/// ``ReviewModel``: pushing the files screen on top makes this one disappear while the model must
/// keep running under the diff, so `onDisappear` is the wrong signal (the router, which knows when
/// the pull request leaves the stack, is the right one).
struct PhonePullRequestScreen: View {
    @Environment(PhoneEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    /// The review model, started by the caller.
    @Bindable var model: ReviewModel

    /// This pull request's outbox rows, observed, for the write line and the Merge button.
    @State private var outboxItems: [OutboxItem] = []
    /// The files screen, while it is pushed.
    @State private var files: PhoneFilesDestination?
    /// The pull request the close confirmation is asking about.
    @State private var closeTarget: PullRequestSummary?
    /// Whether the conversation's comment sheet is up — *Comment…* and *Quote reply*.
    @State private var isCommentSheetPresented = false
    /// Bumped by every write the reviewer will want to feel land (``SwiftUI/View/sensoryFeedback(_:trigger:)``).
    @State private var successes = 0

    var body: some View {
        content
            .background(Theme.background)
            .navigationTitle(model.summary.map { "#" + String($0.number) } ?? "")
            .navigationSubtitle(model.summary?.repo.fullName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbar(model.summary == nil ? .hidden : .visible, for: .bottomBar)
            .navigationDestination(item: $files) { destination in
                if let path = destination.path {
                    PhoneDiffView(model: model, path: path, revealing: destination.line)
                } else {
                    PhoneFilesScreen(model: model)
                }
            }
            .sheet(isPresented: $model.isSubmitSheetPresented) {
                PhoneSubmitReviewSheet(model: model, actions: actions) { successes += 1 }
            }
            // Read again whenever the detail observation writes, so a sheet left open while CI turns
            // red says so — the Mac's arrangement.
            .sheet(isPresented: $model.isMergeSheetPresented) {
                if let summary = model.summary {
                    PhoneMergeSheet(
                        summary: summary,
                        checkState: model.checkRollup?.state,
                        actions: actions,
                        settings: model.settings,
                        stack: PullRequestStackOverview.make(
                            for: summary,
                            in: model.settings.ignoredPullRequests.filter(model.session.inboxRows)
                        ),
                        onMerged: {
                            successes += 1
                            // A merged pull request is not one you are still reviewing (the Mac's
                            // `onMerged: leaveReview`).
                            dismiss()
                        }
                    )
                }
            }
            .sheet(isPresented: $isCommentSheetPresented) {
                if let summary = model.summary {
                    PhoneConversationComposer(model: model, actions: actions, summary: summary) { successes += 1 }
                }
            }
            // The inline composer and the thread sheet are presented here for every screen of this
            // pull request — the diff raises them through the model — so one presenter owns each.
            .sheet(item: $model.composerRequest) { request in
                PhoneInlineCommentSheet(model: model, request: request)
            }
            .sheet(isPresented: threadSheetBinding) {
                if let thread = shownActiveThread, let summary = model.summary {
                    PhoneThreadSheet(model: model, actions: actions, summary: summary, thread: thread)
                }
            }
            .closePullRequestConfirmation($closeTarget, actions: actions)
            // *Quote reply* fills the conversation draft and asks for the keyboard; on the phone the
            // field is the comment sheet's.
            .onChange(of: model.composerFocusRequest) { isCommentSheetPresented = true }
            .task(id: model.prID) {
                let prID = model.prID
                for await items in model.session.database.observeOutboxItems() {
                    outboxItems = items.filter { $0.prID == prID }
                }
            }
            .sensoryFeedback(.success, trigger: successes)
    }

    // MARK: - Content and its states

    @ViewBuilder
    private var content: some View {
        if let summary = model.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = model.notice {
                        PhoneReviewNotice(
                            notice: notice,
                            onReload: { model.reloadPendingUpdate() },
                            onRetry: { model.load() }
                        )
                    }
                    PhonePullRequestHeader(
                        summary: summary,
                        notice: model.notice,
                        checkRollup: model.checkRollup,
                        write: writeState,
                        onRetry: { Task { await model.session.retryFailedWrites(for: model.prID) } }
                    )
                    filesRow(summary)
                    descriptionPost(summary)
                    if model.detail?.conversation?.hasEarlierItems == true {
                        PhoneStreamNotice(
                            symbol: "clock.arrow.circlepath",
                            text: String(localized: "Earlier activity is on GitHub"),
                            buttonTitle: String(localized: "Open on GitHub")
                        ) { actions.openOnGitHub(summary) }
                    }
                    if !model.conversationEntries.isEmpty {
                        PhoneConversationStream(
                            entries: model.conversationEntries,
                            summary: summary,
                            model: model,
                            actions: actions,
                            onShowInDiff: showInDiff
                        )
                    }
                    PhoneChecksCard(checks: model.detail?.checks ?? [])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable { await model.reload() }
        } else if model.isMissingFromInbox {
            missingFromInbox
        } else if let error = model.detailLoadErrorCard {
            ContentUnavailableView {
                Label(String(localized: "Could not load this pull request"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(String(localized: "Try again")) { model.load() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ProgressView(String(localized: "Loading pull request…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The sweep pruned the pull request — merged, closed, or past the search's page cap — and there
    /// was no copy on this phone to show. A pending review is still saved and can be let go of.
    private var missingFromInbox: some View {
        ContentUnavailableView {
            Label(String(localized: "This pull request is no longer in your inbox"), systemImage: "tray")
        } description: {
            Text(model.draft != nil
                ? String(localized: "It was merged, closed, or dropped out of the sweep. Your pending review is still saved locally.")
                : String(localized: "It was merged, closed, or dropped out of the sweep."))
        } actions: {
            Button(String(localized: "Back to the inbox")) { dismiss() }
                .buttonStyle(.borderedProminent)
            if model.draft != nil {
                Button(String(localized: "Discard pending review"), role: .destructive) {
                    Task {
                        do {
                            try await model.discardDraft()
                        } catch {
                            environment.toasts.failure(error, context: String(localized: "Could not discard the review"))
                        }
                    }
                }
            }
        }
    }

    /// The row into the file list: how many files, how far through them, how big.
    private func filesRow(_ summary: PullRequestSummary) -> some View {
        Button {
            files = PhoneFilesDestination(prID: model.prID)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(Theme.type(.title3))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Files"))
                        .font(Theme.type(.body, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                    Text(filesProgress(summary))
                        .font(Theme.type(.footnote))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                if model.pendingCommentCount > 0 {
                    PhoneChip(text: String(localized: "\(model.pendingCommentCount) pending"), color: Theme.accentText)
                }
                Image(systemName: "chevron.right")
                    .font(Theme.type(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)
            }
            .phoneCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(String(localized: "Shows the changed files and the diff"))
    }

    /// "4 of 12 viewed", or "12 files" before anything is viewed.
    private func filesProgress(_ summary: PullRequestSummary) -> String {
        let total = model.detail?.files.count ?? summary.changedFiles
        let viewed = model.viewedPaths.count
        guard viewed > 0 else { return String(localized: "\(total) files") }
        return String(localized: "\(viewed) of \(total) viewed")
    }

    /// The description, drawn as the conversation's first post.
    private func descriptionPost(_ summary: PullRequestSummary) -> some View {
        let conversation = model.detail?.conversation
        return PhonePostView(
            model: model,
            actions: actions,
            subjectID: summary.id,
            author: summary.author,
            verb: String(localized: "opened this pull request"),
            date: summary.createdAt,
            // The reviewer's edit, until GitHub has it (ADR 0043, C).
            markdown: model.descriptionMarkdown,
            isEdited: conversation?.isDescriptionEdited ?? false,
            reactions: conversation?.descriptionReactions ?? [],
            url: pullRequestURL(summary),
            editing: PostEditing.description(of: summary.id, conversation: conversation)
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let summary = model.summary {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    PullRequestMoreMenuItems(
                        summary: summary,
                        actions: actions,
                        onComment: { isCommentSheetPresented = true },
                        onClose: { closeTarget = summary }
                    )
                    Divider()
                    Button(String(localized: "Copy link"), systemImage: "link") {
                        PlatformServices.copyToPasteboard(pullRequestURL(summary).absoluteString)
                    }
                    ShareLink(item: pullRequestURL(summary), subject: Text(summary.title))
                } label: {
                    Label(String(localized: "More actions"), systemImage: "ellipsis")
                }
            }

            // The verdict pair, one capsule, because they are one decision.
            ToolbarItemGroup(placement: .bottomBar) {
                Button(action: approve) {
                    // A symbol, as bar items are: spelled out, the pair pushed Merge into the bar's
                    // overflow menu on a 393-point screen. VoiceOver reads the label's title.
                    Label(String(localized: "Approve"), systemImage: "checkmark")
                        .busyLabel(isBusy: isSubmittingVerdict)
                }
                .disabled(verdictDisabled)
                Button { requestReview(.requestChanges) } label: {
                    Label(String(localized: "Request changes"), systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                // A bar item takes its colour from the tint, not from its label's style.
                .tint(Theme.failure)
                .disabled(verdictDisabled)
                .accessibilityLabel(Text(String(localized: "Request changes")))
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button { requestReview(model.verdictBlocker == nil ? .approve : .comment) } label: {
                    Text(model.pendingCommentCount > 0
                        ? String(localized: "Review · \(model.pendingCommentCount)")
                        : String(localized: "Review"))
                }
                .disabled(model.hasEndedOnGitHub || isSubmittingVerdict)
            }
            ToolbarItem(placement: .bottomBar) {
                mergeButton(summary)
            }
        }
    }

    /// Merge: the one prominent, green action (ADR 0040's 2026-09-23 amendment). Disabled when
    /// GitHub would refuse it, when the pull request has ended, and once a merge is queued or done;
    /// not while it is being *sent* — a disabled toolbar item dims its spinner — so that press is
    /// refused by the guard instead, the Mac toolbar's rule.
    private func mergeButton(_ summary: PullRequestSummary) -> some View {
        let isOnItsWay = writeState?.isMergeOnItsWay ?? false
        let isMerging = writeState == .merging
        return Button {
            guard !isOnItsWay else { return }
            model.isMergeSheetPresented = true
        } label: {
            Text(String(localized: "Merge"))
                .busyLabel(isBusy: isMerging)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.success)
        .disabled(summary.mergeBlocker != nil || model.hasEndedOnGitHub || (isOnItsWay && !isMerging))
        .accessibilityHint(mergeHint(summary))
    }

    /// Why Merge is dark, when it is.
    private func mergeHint(_ summary: PullRequestSummary) -> String {
        if let writeState, writeState.isMergeOnItsWay { return writeState.help }
        if let blocker = summary.mergeBlocker { return PullRequestActions.blockerMessage(blocker, slug: summary.slug) }
        return ""
    }

    // MARK: - Actions

    /// The write helper for this session.
    private var actions: PullRequestActions { environment.actions(for: model.session) }

    /// What the outbox is doing for this pull request — the state its inbox row shows. No merge
    /// series on the phone (ADR 0041 is the Mac's).
    private var writeState: RowWriteState? {
        RowWriteState.make(
            items: outboxItems,
            for: model.prID,
            isMerging: environment.activity.isRunning(model.prID, .merge),
            wasMerged: model.session.mergedPullRequestIDs.contains(model.prID)
        )
    }

    private var isSubmittingVerdict: Bool { environment.activity.isRunning(model.prID, .review) }

    private var verdictDisabled: Bool {
        model.verdictBlocker != nil || model.hasEndedOnGitHub || model.summary == nil || isSubmittingVerdict
    }

    /// The bar's ✓: an approval needs no words, so it goes out at once with the pending comments —
    /// the Mac toolbar's Approve.
    private func approve() {
        guard !model.hasEndedOnGitHub, !isSubmittingVerdict, let summary = model.summary else { return }
        Task {
            if await actions.submitReview(on: summary, verdict: .approve, body: model.summaryText) {
                successes += 1
            }
        }
    }

    /// Opens the submit sheet on a verdict — never on a pull request GitHub has already ended.
    private func requestReview(_ verdict: ReviewVerdict) {
        guard !model.hasEndedOnGitHub else { return }
        model.pendingVerdict = verdict
        model.isSubmitSheetPresented = true
    }

    /// *Show in diff* on a thread: the file's diff, at the line. ``ReviewModel/reveal(path:line:)``
    /// leaves the selection alone for a file the pull request no longer has; the file list is
    /// then the honest place to land.
    private func showInDiff(path: String, line: Int?) {
        model.reveal(path: path, line: line)
        files = model.selectedPath == path
            ? PhoneFilesDestination(prID: model.prID, path: path, line: line)
            : PhoneFilesDestination(prID: model.prID)
    }

    /// The thread the sheet shows, with the reviewer's edits and deletes laid over it — the sheet
    /// offers both, and ``ReviewModel/activeThread`` is the stored copy, which would put a deleted
    /// comment back under the reviewer's finger. The binding above keeps asking the stored copy,
    /// so deleting a comment does not close the sheet.
    private var shownActiveThread: ReviewThread? {
        guard let id = model.activeThreadID, let detail = model.detail else { return nil }
        return model.conversationOverlay.applied(to: detail).threads.first { $0.id == id }
    }

    private var threadSheetBinding: Binding<Bool> {
        Binding(
            get: { model.activeThread != nil },
            set: { if !$0 { model.activeThreadID = nil } }
        )
    }

    private func pullRequestURL(_ summary: PullRequestSummary) -> URL {
        AppConfig.pullRequestURL(owner: summary.repo.owner, name: summary.repo.name, number: summary.number)
    }
}

// MARK: - Header

/// What the pull request *is*, in one card: its state and slug, the title, who opened it and when,
/// the branches, CI, the review decision, its size, and what the outbox is doing for it.
struct PhonePullRequestHeader: View {
    let summary: PullRequestSummary
    let notice: ReviewModel.Notice?
    let checkRollup: CheckRollup?
    let write: RowWriteState?
    let onRetry: () -> Void

    @ScaledMetric(relativeTo: .footnote) private var countsSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The slug is the navigation bar's subtitle already; this row says whose and how old.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { stateAndAuthor }
                VStack(alignment: .leading, spacing: 6) { stateAndAuthor }
            }
            Text(summary.title)
                .font(Theme.type(.title2, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) { branches(lineLimit: 1) }
                // Large text: the names wrap whole rather than shrink to "cl…es", the chip under them.
                VStack(alignment: .leading, spacing: 6) { branches(lineLimit: nil) }
            }
            .font(Theme.mono(.footnote))
            .accessibilityElement(children: .combine)
            Divider().overlay(Theme.hairline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { facts }
                VStack(alignment: .leading, spacing: 8) { facts }
            }
            if let write {
                writeLine(write)
            }
        }
        .phoneCard(padding: 16)
    }

    @ViewBuilder
    private func branches(lineLimit: Int?) -> some View {
        Label {
            Text(verbatim: "\(summary.headRefName) → \(summary.baseRefName)")
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Theme.textMuted)
        }
        if let stack = summary.stack {
            PhoneChip(text: String(localized: "Stack \(stack.position)/\(stack.size)"), color: Theme.accentText)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var stateAndAuthor: some View {
        stateChip
        ProvenanceChip(actor: summary.author, size: countsSize - 1)
            .accessibilityLabel(Text(ProvenanceChip.spokenProvenance(of: summary.author)))
        RelativeDateText(date: summary.createdAt, style: .long)
            .font(Theme.type(.footnote))
            .foregroundStyle(Theme.textMuted)
    }

    /// Open, Draft, Merged or Closed — the word, a symbol and the colour, never the colour alone.
    private var stateChip: some View {
        let (text, symbol, color): (String, String, Color) = {
            switch notice {
            case .merged?: return (String(localized: "Merged"), "arrow.triangle.merge", Theme.priority)
            case .closed?: return (String(localized: "Closed"), "xmark.circle", Theme.failure)
            default:
                return summary.isDraft
                    ? (String(localized: "Draft"), "pencil.circle", Theme.textSecondary)
                    : (String(localized: "Open"), "arrow.triangle.pull", Theme.success)
            }
        }()
        return Label(text, systemImage: symbol)
            .font(Theme.type(.caption, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.chipBackground(color), in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var facts: some View {
        if let checkRollup, checkRollup.total > 0 {
            HStack(spacing: 6) {
                CheckDotView(state: checkRollup.state)
                Text(Self.checksText(checkRollup))
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
        if let decision = summary.reviewDecision {
            PhoneChip(text: decision.chipTitle, color: decision.chipColor)
        }
        DiffCountsView(additions: summary.additions, deletions: summary.deletions, size: countsSize)
            .fixedSize()
    }

    /// "1 of 9 checks failing" while any fails, "7 of 9 checks passed" otherwise, "3 checks" when
    /// only the sweep's verdict and total are known — the Mac's `ChecksSummaryView` rule: the
    /// sweep's rollup carries no split, and "0 of 3" would be a fact nobody measured. Failures
    /// lead, as the inbox row's "1 check failing" does, so the red dot beside the words and the
    /// row the reviewer tapped say the same thing.
    static func checksText(_ rollup: CheckRollup) -> String {
        let hasCounts = rollup.successCount + rollup.failureCount + rollup.pendingCount > 0
        guard hasCounts else { return String(localized: "\(rollup.total) checks") }
        if rollup.failureCount > 0 {
            return String(localized: "\(rollup.failureCount) of \(rollup.total) checks failing")
        }
        return String(localized: "\(rollup.successCount) of \(rollup.total) checks passed")
    }

    /// The outbox's one line for this pull request, with Retry for a failed write.
    private func writeLine(_ write: RowWriteState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(for: write))
                .foregroundStyle(write.color)
                .accessibilityHidden(true)
            Text(write.text)
                .font(Theme.type(.footnote, weight: .medium))
                .foregroundStyle(write.color)
            Spacer(minLength: 0)
            if case .failed = write {
                Button(String(localized: "Retry"), action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(write.help))
    }

    private static func symbol(for write: RowWriteState) -> String {
        switch write {
        case .failed: return "xmark.octagon"
        case .parked: return "exclamationmark.triangle"
        case .merged: return "checkmark.circle"
        case .merging, .mergeQueued, .series: return "arrow.triangle.merge"
        case .queued: return "tray.full"
        }
    }
}

// MARK: - Banner

/// What GitHub did to the pull request while it was open — the phone's ``ReviewUpdateBanner``:
/// the same four notices, with Reload or Try again, as a card at the top of the scroll and without
/// the Mac's keyboard hint.
struct PhoneReviewNotice: View {
    let notice: ReviewModel.Notice
    let onReload: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if notice.offersReload {
                Button(String(localized: "Reload"), action: onReload)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if notice.offersRetry {
                Button(String(localized: "Try again"), action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    private var message: String {
        switch notice {
        case .newCommits(let count):
            guard let count else { return String(localized: "Updated on GitHub — new commits.") }
            return String(localized: "Updated on GitHub — \(count) new commits.")
        case .merged: return String(localized: "Merged on GitHub.")
        case .closed: return String(localized: "Closed on GitHub.")
        case .refreshFailed(let message): return String(localized: "Could not refresh: \(message)")
        }
    }

    private var symbol: String {
        switch notice {
        case .newCommits: return "arrow.triangle.branch"
        case .merged: return "arrow.triangle.pull"
        case .closed: return "xmark.octagon"
        case .refreshFailed: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch notice {
        case .newCommits: return Theme.accent
        case .merged: return Theme.success
        case .closed: return Theme.textMuted
        case .refreshFailed: return Theme.failure
        }
    }
}

// MARK: - Checks

/// The head commit's checks, red first, then running, then green — the Mac's order, so a long list
/// of green checks cannot push the failing one off the bottom. A check with a page opens it.
struct PhoneChecksCard: View {
    let checks: [CheckRun]

    @Environment(\.openURL) private var openURL

    var body: some View {
        let sorted = checks.sorted { Self.rank($0) < Self.rank($1) }
        VStack(alignment: .leading, spacing: 4) {
            PhoneCardTitle(String(localized: "CHECKS · \(checks.count)"))
                .padding(.bottom, 6)
            if sorted.isEmpty {
                Text(String(localized: "No checks configured for this commit."))
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.textMuted)
            } else {
                ForEach(sorted) { check in
                    if let url = check.detailsURL {
                        Button { openURL(url) } label: { row(check, opens: true) }
                            .buttonStyle(.plain)
                            .accessibilityHint(String(localized: "Open the check on GitHub"))
                    } else {
                        row(check, opens: false)
                    }
                    if check.id != sorted.last?.id {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
        }
        .phoneCard()
    }

    private func row(_ check: CheckRun, opens: Bool) -> some View {
        HStack(spacing: 10) {
            CheckDotView(state: Self.state(check))
            Text(check.name)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.detail(check))
                .font(Theme.type(.footnote))
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
            if opens {
                Image(systemName: "arrow.up.right")
                    .font(Theme.type(.caption, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private static func rank(_ check: CheckRun) -> Int {
        switch check.rollupContribution {
        case .failure: return 0
        case .pending: return 1
        case .success: return 2
        }
    }

    private static func state(_ check: CheckRun) -> CheckRollup.State {
        switch check.rollupContribution {
        case .failure: return .failure
        case .pending: return .pending
        case .success: return .success
        }
    }

    /// "running", or how long it took — the Mac's check row (`CheckRowView`).
    private static func detail(_ check: CheckRun) -> String {
        if check.status != .completed { return String(localized: "running") }
        guard let started = check.startedAt, let finished = check.completedAt else {
            return check.conclusion?.rawValue ?? ""
        }
        return RelativeDate.duration(finished.timeIntervalSince(started))
    }
}
