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
    }

    private func content(for row: PullRequestSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(row)
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
                }
            }
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
                .buttonStyle(SuccessButtonStyle())
                .help(String(localized: "Approve (r a)"))

                Button {
                    Task { await actions.submitReview(on: row, verdict: .requestChanges) }
                } label: {
                    Text(String(localized: "Request changes"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(String(localized: "Request changes (r x)"))
            }

            HStack(spacing: 8) {
                Button {
                    onOpenReview(row.id)
                } label: {
                    HStack(spacing: 6) {
                        Text(String(localized: "Open full review"))
                        KeyCapView(keys: "⏎")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button(action: onMerge) {
                    Text(String(localized: "Merge…"))
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(String(localized: "Merge (m)"))
                .disabled(row.mergeable == .conflicting)
            }
        }
        .padding(16)
        .background(Theme.panel)
    }

    /// What the outbox is holding for this pull request (ADR 0006).
    ///
    /// The three states a queued write can end in, said about the pull request they belong to:
    /// waiting to be sent, parked because the pull request moved on underneath the write, and
    /// given up on. Until this line the panel said none of them — a review GitHub refused left the
    /// pull request looking untouched — and the only per-pull-request word about the queue was the
    /// one-shot alert a parked review raises once (`DraftConflictQueue`), which a user who was away
    /// when it appeared never sees again.
    ///
    /// It sits at the top of the action bar rather than among the cards, directly above the
    /// buttons that queued it: the sentence a reviewer needs is "the approval you pressed has not
    /// gone out yet", and it is worth reading in the same glance as the button.
    ///
    /// The standing counts in Settings → Sync, the title bar and the morning digest are unchanged
    /// and remain account-wide; this line is what makes them findable from where the write was
    /// queued, and it deliberately carries no Retry or Discard button — those belong to
    /// Settings → Sync, which the failed indicator names.
    @ViewBuilder
    private func queueStatus(_ row: PullRequestSummary) -> some View {
        let queued = model.queuedWriteCount(for: row)
        let parked = model.parkedWriteCount(for: row)
        let failed = model.failedWriteCount(for: row)
        if queued > 0 || parked > 0 || failed > 0 {
            HStack(spacing: 6) {
                if queued > 0 {
                    Image(systemName: "tray.full")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.pending)
                    Text(String(localized: "\(queued) waiting to be sent"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                if parked > 0 {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.failure)
                    Text(String(localized: "\(parked) parked — the pull request moved on"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                if failed > 0 {
                    Image(systemName: "xmark.octagon")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.failure)
                    Text(String(localized: "\(failed) failed — see Settings → Sync"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.failure)
                }
                Spacer(minLength: 0)
            }
            .help(
                String(
                    localized: "Shepherd writes every change to a local queue first and sends it in the background. A parked write is one the pull request changed underneath; a failed one was given up on and will not be retried. Settings → Sync lists them."
                )
            )
        }
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
            Text(priority.reasons.first ?? priority.category.reasonLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
        .help(priority.file.path + "\n" + priority.reasons.joined(separator: "\n"))
    }
}
