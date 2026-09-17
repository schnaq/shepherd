import GitHubKit
import ShepherdCore
import SwiftUI

/// Adds a repository to the watch list, from the inbox rather than from Settings.
///
/// Watching is the one inbox facet the five default searches cannot produce: they are all `@me`
/// queries, so a repository you are responsible for but never named on has no way in (ADR 0005's
/// 2026-09-16 amendment). The list of watched repositories lived only in Settings → Sync, which
/// is where it is *stored* and not where anybody looks for it — "Sync" reads as an interval and a
/// token. So the same list is reachable from the `+` beside the sidebar's REPOSITORIES heading,
/// which is where the repositories already are, and from ⌘⇧A.
///
/// Removing stays here too. A dialog that only adds would send the reader back to Settings for
/// the opposite action, which is the problem this sheet exists to fix.
struct WatchRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Where the watch list lives.
    let settings: AppSettings

    @State private var draft = ""
    @State private var error: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            field
            watchedList
            footer
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.panel)
        .onAppear { isFieldFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Watch a repository"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text(String(
                localized: "Every open pull request in these repositories reaches the inbox, even the ones nobody asked you about. They appear under Watched until you are involved in one."
            ))
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Entry

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(String(localized: "owner/repository or a GitHub URL"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                    .focused($isFieldFocused)
                    .onSubmit { add() }
                Button(String(localized: "Watch")) { add() }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(isFull)
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The cap is stated before it is hit, not only when the field goes dead: a disabled
            // control with no sentence beside it reads as a bug.
            Text(String(
                localized: "\(settings.watchedRepositories.count) of \(AppSettings.maximumWatchedRepositories) — each repository is one more search on every sweep."
            ))
            .font(.system(size: 11))
            .foregroundStyle(isFull ? Theme.pending : Theme.textMuted)
        }
    }

    private var isFull: Bool {
        settings.watchedRepositories.count >= AppSettings.maximumWatchedRepositories
    }

    // MARK: - What is watched

    @ViewBuilder
    private var watchedList: some View {
        if !settings.watchedRepositories.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(settings.watchedRepositories, id: \.fullName) { repo in
                    HStack(spacing: 8) {
                        Text(verbatim: repo.fullName)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 8)
                        Button(String(localized: "Stop watching")) {
                            settings.watchedRepositories
                                .removeAll { $0.isSameRepository(as: repo) }
                            error = nil
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 24))
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Done")) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    /// Validates and adds, through the one rule both this sheet and the Settings card use.
    private func add() {
        if let failure = settings.watchRepository(named: draft) {
            error = failure
            return
        }
        draft = ""
        error = nil
    }
}
