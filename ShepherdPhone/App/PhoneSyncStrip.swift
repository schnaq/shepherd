import SwiftUI

/// The inbox's inline strip for a sync that is not working: the last sweep failed, or the drain
/// gave up on writes (ADR 0044).
///
/// The phone's half of the Mac's title-bar `SyncStatusView`, reduced to the two states that need
/// the user — a working sync says nothing on the phone, because the pull-to-refresh spinner and
/// the rows themselves already do. A 401 lands here too, as the error's own sentence: nothing on
/// either platform sends the user back to sign-in on its own, and the phone does not start.
///
/// Opaque on ``Theme/raised`` rather than glass: it is content in the list, not a control floating
/// over it (ADR 0040). Placed as the inbox list's first row, it renders nothing while all is well.
struct PhoneSyncStrip: View {
    @Environment(PhoneEnvironment.self) private var environment

    var body: some View {
        if let session = environment.session,
           session.lastSyncError != nil || session.failedOutboxCount > 0 {
            VStack(alignment: .leading, spacing: 12) {
                if let error = session.lastSyncError {
                    PhoneSyncStripRow(
                        systemImage: "exclamationmark.triangle.fill",
                        title: String(localized: "Sync failed"),
                        detail: error,
                        lastSyncedAt: session.lastSyncedAt
                    ) {
                        await environment.syncNow()
                    }
                }
                if session.failedOutboxCount > 0 {
                    PhoneSyncStripRow(
                        systemImage: "exclamationmark.icloud.fill",
                        title: String(localized: "Not sent to GitHub: \(session.failedOutboxCount)"),
                        detail: String(localized: "GitHub refused them or they could not be made. Retry sends them again."),
                        lastSyncedAt: nil
                    ) {
                        await environment.retryFailedWrites()
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.failure.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .transition(.opacity)
        }
    }
}

/// One state in ``PhoneSyncStrip``, with its own Retry — and its own busy state, so retrying the
/// failed writes does not spin the sweep's button too.
private struct PhoneSyncStripRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Whether this row's Retry is in flight.
    @State private var isRetrying = false
    let systemImage: String
    let title: String
    let detail: String
    let lastSyncedAt: Date?
    let retry: @MainActor () async -> Void

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
                        .foregroundStyle(Theme.failure)
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
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Button {
                isRetrying = true
                Task {
                    await retry()
                    isRetrying = false
                }
            } label: {
                if isRetrying {
                    ProgressView()
                } else {
                    Text(String(localized: "Retry"))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(Theme.type(.subheadline, weight: .semibold))
            .disabled(isRetrying)
            .sensoryFeedback(.impact(weight: .light), trigger: isRetrying) { _, new in new }
        }
    }
}
