import ShepherdCore
import SwiftUI

/// The right-hand preview panel of the inbox.
struct InboxDetailPanel: View {
    @Environment(AppEnvironment.self) private var environment
    /// The inbox model.
    let model: InboxModel
    /// The outbox-backed write actions.
    let actions: PullRequestActions
    /// Opens the full review screen.
    var onOpenReview: (String) -> Void
    /// Opens the merge sheet.
    var onMerge: () -> Void

    /// Whether the conversation composer is up, and what is in it.
    ///
    /// Held here rather than on the screen, exactly as ``IssueDetailPanel`` holds its own: the
    /// text is bound into the composer, so state one level up would re-evaluate the whole
    /// three-column screen — rail, list and toolbar — on every character typed.
    @State private var isCommentSheetPresented = false
    @State private var commentBody = ""

    /// The selected pull request's screenshot reading (ADR 0038 item 4). Held here for the
    /// composer's reason above, and refreshed from the detail without ever downloading anything.
    @State private var screenshots = ScreenshotReadingModel()

    var body: some View {
        Group {
            if let row = model.selectedRow {
                content(for: row)
            } else {
                EmptyStateView(
                    systemImage: "sidebar.right",
                    title: String(localized: "No pull request selected"),
                    message: String(localized: "Pick a row with j / k, or click one.")
                )
            }
        }
        .background(Theme.panel)
        // Keyed by the detail and by whether a reader exists, so switching the tiers off takes
        // the button away at once. A Markdown scan and an availability question; no request.
        .task(id: ScreenshotRefreshKey(detail: model.detail, hasReader: environment.screenshotReader != nil)) {
            await screenshots.refresh(detail: model.detail, reader: environment.screenshotReader)
        }
        .sheet(isPresented: $isCommentSheetPresented) {
            if let row = model.selectedRow {
                PullRequestCommentSheet(summary: row, actions: actions, text: $commentBody)
            }
        }
    }

    private func content(for row: PullRequestSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(row)
                    // Under the header because it says the same kind of thing — where this pull
                    // request comes from and what it builds on — and nothing when it is in no
                    // stack (ADR 0042).
                    if let stack = model.stackOverview(for: row) {
                        PullRequestStackCard(overview: stack, onOpen: openStackMember)
                    }
                    checksCard(row)
                    priorityCard
                    intelligenceCard
                }
                .padding(18)
            }
            Divider().overlay(Theme.border)
            actionBar(row)
        }
    }

    /// A click on another pull request of the stack: selected in the list when the rail shows it,
    /// so the reader stays in the inbox, and opened in the review screen when it does not —
    /// selecting a row the list hides would leave this panel empty.
    private func openStackMember(_ member: PullRequestSummary) {
        if model.isShown(member.id) {
            model.select(member.id)
        } else {
            onOpenReview(member.id)
        }
    }

    // MARK: - Header

    private func header(_ row: PullRequestSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProvenanceChip(actor: row.author)
                Text(String(localized: "opened \(RelativeDate.long(row.createdAt))"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Text(row.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                Text("\(row.headRefName) → \(row.baseRefName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: - Cards

    private func checksCard(_ row: PullRequestSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(String(localized: "CHECKS"))
                let checks = model.detail?.checks ?? []
                if checks.isEmpty {
                    Text(
                        model.isRefreshingDetail
                            ? String(localized: "Loading checks…")
                            : String(localized: "No checks configured for this commit.")
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(checks.prefix(6)) { check in
                        CheckRowView(check: check)
                    }
                    if checks.count > 6 {
                        Text(String(localized: "+ \(checks.count - 6) more"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }

    private var priorityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    CardTitle(String(localized: "REVIEW PRIORITY"))
                    ChipView(text: String(localized: "heuristics"), color: Theme.accentText, size: 10)
                }
                if model.priorities.isEmpty {
                    Text(String(localized: "File list not fetched yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(model.priorities.prefix(4)) { priority in
                        PriorityRowView(priority: priority)
                    }
                    let remaining = model.priorities.count - min(4, model.priorities.count)
                    if remaining > 0 {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Theme.priorityMuted)
                                .frame(width: 6, height: 6)
                            Text(String(localized: "+ \(remaining) more files"))
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textMuted)
                            Spacer(minLength: 0)
                            Text(String(localized: "skim"))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var intelligenceCard: some View {
        switch model.summaryOutcome {
        case .disabled:
            EmptyView()
        case .value(let output):
            Card(tint: Theme.accent.opacity(0.06)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accentText)
                        CardTitle(
                            output.kind == .onDevice
                                ? String(localized: "ON-DEVICE SUMMARY")
                                : String(localized: "AI SUMMARY"),
                            tint: Theme.accentText
                        )
                        Spacer(minLength: 0)
                        Text(output.kind.badge)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Text(output.value.overview)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(output.value.riskNotes, id: \.self) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(Theme.pending)
                            Text(note)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    screenshotBlock
                }
            }
        case .unavailable(let reason), .failed(let reason):
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    CardTitle(String(localized: "AI SUMMARY"))
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    // A text summary that failed — too long a description, a cloud tier that
                    // declined — says nothing about whether the images can be read here: the
                    // block asks its own model, and is only drawn when that one said yes.
                    screenshotBlock
                }
            }
        }
    }

    /// The screenshot reading, under the summary it belongs with. Its own seam and its own tier:
    /// whichever tier wrote the summary, the images are read on this Mac or not at all.
    @ViewBuilder
    private var screenshotBlock: some View {
        if screenshots.state != .none {
            ScreenshotReadingBlock(state: screenshots.state) {
                guard let detail = model.detail else { return }
                let fetcher = environment.descriptionImageFetcher
                Task { await screenshots.read(detail: detail, fetcher: fetcher) }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Actions

    private func actionBar(_ row: PullRequestSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            queueStatus(row)
            HStack(spacing: 8) {
                Button {
                    Task { await actions.submitReview(on: row, verdict: .approve) }
                } label: {
                    Label(String(localized: "Approve"), systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                // Neutral: Merge is the panel's one green button (ADR 0040's 2026-09-23
                // amendment), and two of them side by side would be two recommendations. Not even
                // a green label, which from across the panel reads as a second green button; the
                // tick is what keeps it recognisable.
                .buttonStyle(SecondaryButtonStyle())
                // Both verdict buttons go dark for either reason: GitHub would refuse this one
                // (``disabled``), or a verdict for this pull request is already on its way to the
                // outbox (``busy``, which disables as well and spins while it does).
                .busy(isWriting(row, .review))
                .disabled(row.verdictBlocker != nil)
                .help(PullRequestActions.help(
                    for: row.verdictBlocker,
                    on: row,
                    otherwise: String(localized: "Approve (r a)")
                ))

                Button {
                    Task { await actions.submitReview(on: row, verdict: .requestChanges) }
                } label: {
                    Text(String(localized: "Request changes"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.failure))
                .busy(isWriting(row, .review))
                .disabled(row.verdictBlocker != nil)
                .help(PullRequestActions.help(
                    for: row.verdictBlocker,
                    on: row,
                    otherwise: String(localized: "Request changes (r x)")
                ))
            }

            HStack(spacing: 8) {
                Button {
                    onOpenReview(row.id)
                } label: {
                    HStack(spacing: 6) {
                        Text(String(localized: "Open review"))
                        KeyCapView(keys: "⏎")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button(action: onMerge) {
                    Text(String(localized: "Merge…"))
                        .frame(maxWidth: .infinity)
                }
                // The primary action, here as everywhere (ADR 0040's 2026-09-23 amendment): the
                // one filled green button in the panel. A blocker disables it rather than
                // repainting it, and the help text says why.
                .buttonStyle(SuccessButtonStyle())
                // This one only opens the sheet, but it opens the sheet onto a merge that is
                // already queueing — so it goes quiet with the write rather than with the click.
                .busy(isWriting(row, .merge))
                .disabled(row.mergeBlocker != nil)
                .help(PullRequestActions.help(
                    for: row.mergeBlocker,
                    on: row,
                    otherwise: String(localized: "Merge (m)")
                ))
            }

            // On its own row under the two above, and last: a verdict is what this panel is for,
            // a merge is what a verdict leads to, and saying something without a verdict — or
            // closing the thing unmerged — is the rarer errand. It is one button rather than
            // two because the sheet behind it holds both of GitHub's, and because "close" with
            // no chance to say why is a button worth not having.
            Button { isCommentSheetPresented = true } label: {
                Text(String(localized: "Comment…"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(String(localized: "Comment on the conversation, or comment and close"))
        }
        .padding(16)
        .background(Theme.panel)
    }

    /// Whether this pull request already has a write of this kind on its way to the outbox.
    ///
    /// Read off ``AppEnvironment/activity``, which the write funnel marks, so a verdict queued by
    /// `r a`, by ⌘K or by the review screen dims this panel's buttons too.
    /// - Parameters:
    ///   - row: The pull request.
    ///   - kind: Which verb.
    /// - Returns: `true` while the write runs.
    private func isWriting(_ row: PullRequestSummary, _ kind: ActionActivity.Kind) -> Bool {
        environment.activity.isRunning(row.id, kind)
    }

    /// What the outbox is holding for this pull request (ADR 0006).
    ///
    /// It sits at the top of the action bar rather than among the cards, directly above the
    /// buttons that queued it: the sentence a reviewer needs is "the approval you pressed has not
    /// gone out yet", and it is worth reading in the same glance as the button.
    ///
    /// Until this line the panel said none of the three — a review GitHub refused left the pull
    /// request looking untouched — and the only per-pull-request word about the queue was the
    /// one-shot alert a parked review raises once (`DraftConflictQueue`), which a user who was
    /// away when it appeared never sees again.
    /// Sends the row's failed writes again; the observed outbox updates the line by itself.
    private func retryFailedWrites(_ row: PullRequestSummary) {
        guard let session = environment.session else { return }
        Task { await session.retryFailedWrites(for: row.id) }
    }

    @ViewBuilder
    private func queueStatus(_ row: PullRequestSummary) -> some View {
        QueueStatusLine(
            queued: model.queuedWriteCount(for: row),
            parked: model.parkedWriteCount(for: row),
            failed: model.failedWriteCount(for: row),
            target: .pullRequest,
            onRetry: { retryFailedWrites(row) }
        )
        if environment.mergeWhenGreen.isArmed(row) {
            mergeWhenGreenStatus
        }
        if let chip = environment.mergeSeries.chip(for: row.id, row: row) {
            mergeSeriesStatus(chip, row: row)
        }
    }

    /// Where the pull request stands in its merge series, and the way out of it (ADR 0041).
    ///
    /// Beside the merge-when-green line for that line's reason: a series is a decision that
    /// has been made and has not reached the outbox yet, so the queue status above cannot say
    /// it. **Remove from series** lives here because this is the surface the reviewer is on when
    /// they change their mind about one pull request; the whole series is cancelled in
    /// Settings → Sync.
    private func mergeSeriesStatus(_ chip: MergeSeriesChip, row: PullRequestSummary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "list.number")
                .font(Theme.type(.caption2))
                .foregroundStyle(chip.color)
            Text(chip.text)
                .font(Theme.type(.caption))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if environment.mergeSeries.canRemove(row.id, hasUnsentWrite: model.queuedWriteCount(for: row) > 0) {
                Button(String(localized: "Remove from series")) {
                    environment.removeFromMergeSeries(row.id)
                }
                .buttonStyle(.link)
                .font(Theme.type(.caption))
            }
        }
        .help(chip.help)
    }

    /// The one line about a merge that is waiting for this commit's checks (ADR 0037).
    ///
    /// Beside the queue status rather than inside it: the outbox holds nothing yet — that is the
    /// point — so this is the only place the panel can say that a decision has been made. The
    /// sheet (`m`) is where it is cancelled, which is why the line names the key.
    private var mergeWhenGreenStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 10))
                .foregroundStyle(Theme.pending)
            Text(String(localized: "Merges when the checks pass"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .help(String(localized: "You decided to merge this commit once its checks are green. Press m to stop waiting."))
    }
}

/// One line of the checks card.
struct CheckRowView: View {
    /// The check run.
    let check: CheckRun

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(check.name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(detailText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(height: 24)
        .help(check.summary ?? check.name)
    }

    @ViewBuilder
    private var icon: some View {
        switch check.rollupContribution {
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.success)
        case .failure:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.failure)
        case .pending:
            Circle()
                .strokeBorder(Theme.pending, lineWidth: 2)
                .frame(width: 11, height: 11)
        }
    }

    private var detailText: String {
        if check.status != .completed { return String(localized: "running") }
        guard let started = check.startedAt, let finished = check.completedAt else {
            return check.conclusion?.rawValue ?? ""
        }
        return RelativeDate.duration(finished.timeIntervalSince(started))
    }
}

/// One line of the review-priority card.
struct PriorityRowView: View {
    /// The ranked file.
    let priority: FilePriority

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(priority.bucket.tint)
                .frame(width: 6, height: 6)
            Text(priority.file.fileName)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(priority.category.localizedLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
        .help(helpText)
        // The dot's colour is the *only* thing on this row that says which bucket the file is
        // in — the card has no section headers, unlike the review screen's file list, where the
        // same buckets are printed as "REVIEW FIRST · 3". So the bucket is named here, where a
        // reader who cannot tell the colours apart, or who hears the row read out, can still
        // get at it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                SpokenRow.sentence([
                    priority.bucket.localizedTitle,
                    priority.file.fileName,
                    priority.category.localizedLabel,
                ])
            )
        )
    }

    /// The tooltip: what the row shows, in the reader's language, and then why it was ranked.
    ///
    /// The category is named in the head line, so its reason
    /// (``ShepherdCore/FilePriorityReason/category(_:)``) is left out of the lines below it
    /// rather than said twice.
    private var helpText: String {
        let head = SpokenRow.sentence([
            priority.bucket.localizedTitle,
            priority.file.path,
            priority.category.localizedLabel,
        ])
        let rest = priority.reasons.filter { !$0.isCategory }.map { $0.localizedText() }
        guard !rest.isEmpty else { return head }
        return head + "\n" + rest.joined(separator: "\n")
    }
}

/// What the screenshot refresh depends on: the pull request, its description and whether a reader
/// exists. The detail's other fields — checks, threads — change on every background refetch and
/// must not restart it.
private struct ScreenshotRefreshKey: Equatable {
    var id: String?
    var body: String?
    var hasReader: Bool

    init(detail: PullRequestDetail?, hasReader: Bool) {
        id = detail?.id
        body = detail?.bodyMarkdown
        self.hasReader = hasReader
    }
}
