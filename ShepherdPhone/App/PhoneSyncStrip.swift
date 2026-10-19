import SwiftUI

/// The inbox's inline strip for a sync that is not working: the last sweep failed, the drain gave
/// up on writes, or reviews are parked behind new commits (ADR 0044).
///
/// The phone's half of the Mac's title-bar `SyncStatusView`, reduced to the three states that
/// need the user — a working sync says nothing on the phone, because the pull-to-refresh spinner
/// and the rows themselves already do. The last two never clear by themselves (ADR 0006), so they
/// stay here for as long as they last, as the Mac's status line keeps "· N not sent": the toast a
/// parked review raises is a moment, and easily missed under a sheet or while the app is away. A 401 lands here too, as the error's own sentence: nothing on
/// either platform sends the user back to sign-in on its own, and the phone does not start.
///
/// Opaque on ``Theme/raised`` rather than glass: it is content in the list, not a control floating
/// over it (ADR 0040). Placed as the inbox list's first row, it renders nothing while all is well.
struct PhoneSyncStrip: View {
    @Environment(PhoneEnvironment.self) private var environment

    var body: some View {
        if let session = environment.session,
           session.lastSyncError != nil || session.failedOutboxCount > 0 || session.conflictedOutboxCount > 0 {
            // Red while anything failed; amber when all that is left is a parked review.
            let tint = session.lastSyncError != nil || session.failedOutboxCount > 0 ? Theme.failure : Theme.pending
            VStack(alignment: .leading, spacing: 12) {
                if let error = session.lastSyncError {
                    PhoneSyncStripRow(
                        systemImage: "exclamationmark.triangle.fill",
                        title: String(localized: "Sync failed"),
                        detail: error,
                        lastSyncedAt: session.lastSyncedAt,
                        action: PhoneSyncStripAction(title: String(localized: "Retry")) {
                            await environment.syncNow()
                        }
                    )
                }
                if session.failedOutboxCount > 0 {
                    // No Retry here: a failed write is one retrying cannot fix by itself, so the
                    // choice — send again or discard — is made row by row in Settings.
                    PhoneSyncStripRow(
                        systemImage: "exclamationmark.icloud.fill",
                        title: String(localized: "Not sent to GitHub: \(session.failedOutboxCount)"),
                        detail: String(localized: "GitHub refused them or they could not be made. Retry or discard them in Settings."),
                        lastSyncedAt: nil,
                        action: PhoneSyncStripAction(title: String(localized: "Show")) {
                            environment.isSettingsPresented = true
                        }
                    )
                }
                if session.conflictedOutboxCount > 0 {
                    // No button: a parked review is re-checked on its own pull request, against
                    // the new commit — the Mac's wording, which already has its German.
                    PhoneSyncStripRow(
                        systemImage: "exclamationmark.triangle.fill",
                        title: String(localized: "\(session.conflictedOutboxCount) conflicted — needs your attention."),
                        detail: String(
                            localized: "These pull requests got new commits after the review was queued, so nothing was sent. Open each one and check your draft against the new commit."
                        ),
                        tint: Theme.pending,
                        lastSyncedAt: nil,
                        action: nil
                    )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .transition(.opacity)
        }
    }
}

/// A strip row's button.
private struct PhoneSyncStripAction {
    let title: String
    let perform: @MainActor () async -> Void
}

/// One state in ``PhoneSyncStrip``, with its own button — and its own busy state, so one row's
/// action does not spin another's.
private struct PhoneSyncStripRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Whether this row's action is in flight.
    @State private var isRunning = false
    /// One column for every row's glyph, so the texts of a cloud row and a triangle row line up.
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 22
    let systemImage: String
    let title: String
    let detail: String
    var tint: Color = Theme.failure
    let lastSyncedAt: Date?
    let action: PhoneSyncStripAction?

    var body: some View {
        // Side by side at ordinary sizes; the button drops under the text at the accessibility
        // sizes, where a row of three would squeeze the sentence into a column of single words.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Dropped at the accessibility sizes, where it would push the title into a ragged
                // column; the title says the same thing in words.
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: systemImage)
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(tint)
                        .frame(width: iconWidth)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.type(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                    Text(detail)
                        .font(Theme.type(.footnote))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let lastSyncedAt {
                        HStack(spacing: 4) {
                            Text(String(localized: "Synced"))
                            Text(verbatim: "·")
                            RelativeDateText(date: lastSyncedAt, style: .long)
                        }
                        .font(Theme.type(.footnote))
                        .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if let action {
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button {
                    isRunning = true
                    Task {
                        await action.perform()
                        isRunning = false
                    }
                } label: {
                    if isRunning {
                        ProgressView()
                    } else {
                        Text(action.title)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(Theme.type(.subheadline, weight: .semibold))
                .disabled(isRunning)
                .sensoryFeedback(.impact(weight: .light), trigger: isRunning) { _, new in new }
            }
        }
    }
}
