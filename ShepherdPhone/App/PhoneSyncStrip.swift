import SwiftUI

/// The inbox's inline strip for a sync that is not working: the last sweep failed, the drain gave
/// up on writes, or reviews are parked behind new commits (ADR 0044).
///
/// The phone's half of the Mac's title-bar `SyncStatusView`, reduced to the three states that
/// need the user — a working sync says nothing on the phone, because the pull-to-refresh spinner
/// and the rows themselves already do. The last two never clear by themselves (ADR 0006), so they
/// stay here for as long as they last, as the Mac's status line keeps "· N not sent": the toast a
/// parked review raises is a moment, and easily missed under a sheet or while the app is away. A 401
/// lands here too, as the error's own sentence: nothing on either platform sends the user back to
/// sign-in on its own, and the phone does not start.
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
            VStack(alignment: .leading, spacing: 8) {
                if let error = session.lastSyncError {
                    PhoneSyncStripRow(
                        systemImage: "exclamationmark.triangle.fill",
                        title: String(localized: "Sync failed"),
                        detail: error,
                        action: PhoneSyncStripAction(title: String(localized: "Retry")) {
                            await environment.syncNow()
                        }
                    )
                }
                if session.failedOutboxCount > 0 {
                    // No Retry here: a failed write is one retrying cannot fix by itself, so the
                    // choice — send again or discard — is made row by row in Settings, whose
                    // footer says why.
                    PhoneSyncStripRow(
                        systemImage: "exclamationmark.icloud.fill",
                        title: String(localized: "\(session.failedOutboxCount) not sent"),
                        action: PhoneSyncStripAction(title: String(localized: "Show")) {
                            environment.isSettingsPresented = true
                        }
                    )
                }
                if session.conflictedOutboxCount > 0 {
                    // Listed in Settings beside the failed ones, with Discard (ADR 0006's
                    // 2026-10-29 amendment); the word is the row chip's.
                    PhoneSyncStripRow(
                        systemImage: "exclamationmark.triangle.fill",
                        title: String(localized: "\(session.conflictedOutboxCount) parked"),
                        tint: Theme.pending,
                        action: PhoneSyncStripAction(title: String(localized: "Show")) {
                            environment.isSettingsPresented = true
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            // A status line, not the screen's subject: past the first accessibility size it would
            // take the whole first screen, the way the pills above it would.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .transition(.opacity)
        }
    }
}

/// A strip row's button.
private struct PhoneSyncStripAction {
    let title: String
    let perform: @MainActor () async -> Void
}

/// One state in ``PhoneSyncStrip``: its glyph, a few words and its button — one line, so the strip
/// stays a strip — with its own busy state, so one row's action does not spin another's.
private struct PhoneSyncStripRow: View {
    /// Whether this row's action is in flight.
    @State private var isRunning = false
    /// One column for every row's glyph, so the texts of a cloud row and a triangle row line up.
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 20
    let systemImage: String
    let title: String
    /// The sync error's own sentence, under the title — the only detail the strip keeps, because
    /// it is the one thing that says what went wrong (a 401 among them).
    var detail: String?
    var tint: Color = Theme.failure
    let action: PhoneSyncStripAction?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: systemImage)
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(tint)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.type(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(Theme.type(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let action {
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
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .font(Theme.type(.subheadline, weight: .semibold))
                .fixedSize()
                .disabled(isRunning)
                .sensoryFeedback(.impact(weight: .light), trigger: isRunning) { _, new in new }
            }
        }
    }
}
