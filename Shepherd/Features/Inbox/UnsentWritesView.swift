import ShepherdCore
import SwiftUI

/// The writes that will not go out by themselves — parked and not sent — as one clickable count
/// with a popover that names each one (ADR 0006's 2026-10-29 amendment).
///
/// The inbox's sync line and the review screen's toolbar both show it, so the way out of a stuck
/// write is one click from wherever the user is. One vocabulary everywhere: **Parked** (amber) is
/// a write the target moved on underneath, **Not sent** (red) one the drain gave up on.
struct UnsentWritesButton: View {
    /// The active session, whose observed counts and rows this shows.
    let session: SignedInSession
    /// Only the worse of the two counts, for the narrowest form of the sync line.
    var isCompact = false
    @State private var isPresented = false

    var body: some View {
        let failed = session.failedOutboxCount
        let parked = session.conflictedOutboxCount
        if failed > 0 || parked > 0 {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 4) {
                    if failed > 0 {
                        Text(String(localized: "\(failed) not sent"))
                            .foregroundStyle(Theme.failure)
                    }
                    if parked > 0, failed == 0 || !isCompact {
                        if failed > 0 {
                            Text(verbatim: "·")
                        }
                        Text(String(localized: "\(parked) parked"))
                            .foregroundStyle(Theme.pending)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Writes that will not go out by themselves. Click to see each one and send or discard it."))
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                UnsentWritesList(session: session)
            }
        }
    }
}

/// Every parked and not-sent write, each with what it would have done, why it is stuck and its
/// actions — the popover behind ``UnsentWritesButton``.
struct UnsentWritesList: View {
    /// The active session.
    let session: SignedInSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Not sent to GitHub"))
                .font(Theme.type(.headline))
                .foregroundStyle(Theme.textStrong)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.unsentWrites) { item in
                        UnsentWriteRow(item: item, session: session)
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "Parked: the pull request or issue changed after you queued the write, so Shepherd held it back. Not sent: GitHub refused it, or Shepherd could not make it."))
                .font(Theme.type(.caption))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 440)
    }
}

/// One write that will not go out by itself: where it was going, what it would have done, why it
/// is stuck, and what can be done about it. The same row in the popover and in Settings → Sync.
///
/// Open for both states; Retry for a write the drain gave up on; Send anyway for a parked review,
/// which goes out on the commit it was written on; Discard for both. A parked merge or branch
/// update gets no Send anyway: the head moved, so the user looks again and merges again. Discarding
/// a parked review deletes its draft, so that one asks first.
struct UnsentWriteRow: View {
    /// The outbox row.
    let item: OutboxItem
    /// The active session, for the target's title and the actions.
    let session: SignedInSession
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingDiscard = false

    private var isParked: Bool { item.state == .conflicted }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: target)
                    .font(Theme.type(.callout, weight: .medium))
                    .foregroundStyle(Theme.textStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(isParked ? String(localized: "Parked") : String(localized: "Not sent"))
                        .foregroundStyle(isParked ? Theme.pending : Theme.failure)
                    Text(verbatim: "·")
                    Text(item.action.localizedName)
                }
                .font(Theme.type(.caption, weight: .medium))
                Text(item.unsentReason)
                    .font(Theme.type(.caption))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button(String(localized: "Show")) {
                    environment.openTarget(item.prID, isIssue: item.action.targetsIssue)
                }
                if !isParked {
                    Button(String(localized: "Retry")) {
                        Task { await session.retry(item) }
                    }
                } else if item.isParkedReview {
                    Button(String(localized: "Send anyway")) {
                        Task { await session.sendParkedReviewAnyway(for: item.prID) }
                    }
                    .help(String(localized: "Send the review on the commit you wrote it on. GitHub keeps your inline comments there."))
                }
                Button(String(localized: "Discard"), role: .destructive) {
                    if item.isParkedReview {
                        isConfirmingDiscard = true
                    } else {
                        Task { await session.discard(item) }
                    }
                }
            }
            .controlSize(.small)
        }
        .discardParkedReviewConfirmation(isPresented: $isConfirmingDiscard) {
            Task { await session.discard(item) }
        }
    }

    /// "schnaq/shepherd#42 · Bump the client", the title when this Mac holds the row.
    private var target: String {
        let slug = "\(item.repo.fullName)#\(item.number)"
        let title = item.action.targetsIssue
            ? session.issueRows.first { $0.id == item.prID }?.title
            : session.inboxRows.first { $0.id == item.prID }?.title
        return title.map { "\(slug) · \($0)" } ?? slug
    }
}
