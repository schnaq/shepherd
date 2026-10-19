import GitHubKit
import ShepherdCore
import SwiftUI
import UIKit

/// The iPhone's settings, as a sheet over the inbox (ADR 0044): the account and the way out of
/// it, the writes GitHub refused, the watched repositories, the language and what this build is.
///
/// Far fewer than the Mac's nine panes on purpose: the phone runs no automation, no delegation, no
/// intelligence and no settings sync, so a switch for any of them would switch nothing. A system
/// `Form`, because settings are the one screen iOS users expect to look like Settings.
///
/// Opened by assigning ``PhoneEnvironment/isSettingsPresented`` — the inbox's avatar button and the
/// sync strip's *Show* do it.
struct PhoneSettingsView: View {
    @Environment(PhoneEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingSignOut = false
    @State private var watchedRepositoryDraft = ""
    @State private var watchedRepositoryError: String?
    /// The outbox rows the drain gave up on — fetched, keyed on the observed
    /// ``SignedInSession/failedOutboxCount``, for `SyncSettingsTab.failedRows`' reasons.
    @State private var failedRows: [OutboxItem] = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 52

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                notSentSection
                watchedRepositoriesSection
                addWatchedRepositorySection
                languageSection
                aboutSection
                signOutSection
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .sensoryFeedback(.success, trigger: environment.settings.watchedRepositories.count) { old, new in
            new > old
        }
        .task(id: environment.session?.failedOutboxCount) { await reloadFailedRows() }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        if let account = environment.session?.account {
            Section {
                // The avatar goes above the name at the accessibility sizes, and stops growing:
                // beside it, the login and the sentence under it were squeezed to a word a line.
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                    : AnyLayout(HStackLayout(spacing: 14))
                layout {
                    AvatarView(login: account.login, url: account.avatarURL, size: min(avatarSize, 72))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: account.login)
                            .font(Theme.type(.headline))
                            .foregroundStyle(Theme.textStrong)
                        Text(authDescription(account.authKind))
                            .font(Theme.type(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } header: {
                Text(String(localized: "Account"))
            }
        }
    }

    private func authDescription(_ kind: AuthKind) -> String {
        switch kind {
        case .deviceFlow: return String(localized: "Signed in with the GitHub App device flow")
        case .pat: return String(localized: "Signed in with a personal access token")
        }
    }

    // MARK: - Not sent

    /// The writes the drain gave up on, each with Retry and Discard — the Mac's Settings → Sync
    /// group (`SyncSettingsTab.failedOutboxGroup`), and where the inbox's sync strip sends the
    /// user. Second, under the account, so the strip's *Show* lands on it.
    ///
    /// A failed row was refused in a way retrying cannot fix by itself, so it never leaves on its
    /// own: Retry is the user saying the obstacle is gone, Discard that it never mattered. Both are
    /// on the row's ⋯ menu, its long press and its swipes; Discard is never a full swipe, because
    /// what it throws away cannot be queued again from here. The footer carries the explanation
    /// the inbox's one-line strip leaves out.
    @ViewBuilder
    private var notSentSection: some View {
        if let session = environment.session, session.failedOutboxCount > 0 {
            Section {
                ForEach(failedRows) { item in
                    failedRow(item, session: session)
                    .padding(.vertical, 2)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { retry(item, session: session) } label: {
                            Label(String(localized: "Retry"), systemImage: "arrow.clockwise")
                        }
                        .tint(Theme.accent)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { discard(item, session: session) } label: {
                            Label(String(localized: "Discard"), systemImage: "trash")
                        }
                    }
                    .contextMenu { failedRowActions(item, session: session) }
                }
            } header: {
                Text(String(localized: "Not sent"))
            } footer: {
                Text(String(localized: "GitHub refused these writes, or Shepherd could not make them at all, so they will not go out by themselves. Retry one once you have fixed what stopped it, or discard it."))
            }
            .sensoryFeedback(.impact(weight: .light), trigger: failedRows.count) { old, new in new < old }
        }
    }

    /// One write that was not sent: the glyph on the title's line (a `Label` would centre it beside
    /// two lines), what it was and why it failed, and the ⋯ menu — visible, so the two ways out
    /// are not only on a swipe or a long press. At the accessibility sizes the glyph and the menu
    /// share a line above the words, which beside them were squeezed to a syllable a line.
    @ViewBuilder
    private func failedRow(_ item: OutboxItem, session: SignedInSession) -> some View {
        let icon = Image(systemName: "exclamationmark.icloud")
            .font(Theme.type(.body))
            .foregroundStyle(Theme.failure)
            .accessibilityHidden(true)
        let text = VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(item.repo.fullName)#\(item.number) · \(Self.actionName(item.action))")
                .font(Theme.type(.body, weight: .medium))
                .foregroundStyle(Theme.textStrong)
            Text(item.localizedLastError ?? String(localized: "No reason was recorded."))
                .font(Theme.type(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        let menu = Menu {
            failedRowActions(item, session: session)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Theme.type(.title3))
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "More actions"))
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    icon
                    Spacer(minLength: 8)
                    menu
                }
                text
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                icon
                text
                menu
            }
        }
    }

    /// Retry and Discard, for a failed row's ⋯ menu and its long press.
    @ViewBuilder
    private func failedRowActions(_ item: OutboxItem, session: SignedInSession) -> some View {
        Button { retry(item, session: session) } label: {
            Label(String(localized: "Retry"), systemImage: "arrow.clockwise")
        }
        Button(role: .destructive) { discard(item, session: session) } label: {
            Label(String(localized: "Discard"), systemImage: "trash")
        }
    }

    private func retry(_ item: OutboxItem, session: SignedInSession) {
        Task {
            try? await session.database.retryOutboxItem(id: item.id)
            await reloadFailedRows()
            await session.drainOutbox()
            await reloadFailedRows()
        }
    }

    private func discard(_ item: OutboxItem, session: SignedInSession) {
        Task {
            try? await session.database.deleteOutboxItem(id: item.id)
            await reloadFailedRows()
        }
    }

    /// Re-reads the failed rows; a read failure lists nothing, as an empty outbox would.
    private func reloadFailedRows() async {
        guard let session = environment.session else { return }
        failedRows = (try? await session.database.failedOutboxItems()) ?? []
    }

    /// What one queued write would have done, in the user's words.
    ///
    /// A copy of `SyncSettingsTab.actionName(_:)`, word for word so the German carries over: that
    /// file builds the Mac's settings window and cannot be compiled for iOS. Exhaustive for the
    /// same reason — a new ``ShepherdCore/OutboxAction`` case is a compile error here too. At
    /// integration both should call one shared extension on the action (ADR 0044).
    private static func actionName(_ action: OutboxAction) -> String {
        switch action {
        case .submitReview: return String(localized: "Submit review")
        case .replyToComment: return String(localized: "Reply")
        case .addReviewComment: return String(localized: "Comment on a line")
        case .resolveThread: return String(localized: "Resolve")
        case .unresolveThread: return String(localized: "Unresolve")
        case .merge: return String(localized: "Merge")
        case .markReadyForReview: return String(localized: "Mark ready for review")
        case .updateBranch: return String(localized: "Update branch")
        case .addIssueComment: return String(localized: "Comment on an issue")
        case .addIssueLabel: return String(localized: "Add a label")
        case .addIssueAssignee: return String(localized: "Add an assignee")
        case .closeIssue: return String(localized: "Close an issue")
        case .reopenIssue: return String(localized: "Reopen an issue")
        case .addPullRequestComment: return String(localized: "Comment on a pull request")
        case .closePullRequest(let comment):
            return comment == nil
                ? String(localized: "Close a pull request")
                : String(localized: "Comment and close")
        case .react(_, _, let adding):
            return adding ? String(localized: "Add a reaction") : String(localized: "Remove a reaction")
        case .editComment: return String(localized: "Edit a comment")
        case .deleteComment: return String(localized: "Delete a comment")
        }
    }

    // MARK: - Watched repositories

    /// The Mac's Settings → Sync card and inbox sheet in one list: every open pull request in these
    /// repositories reaches the inbox, under Watched (ADR 0005's 2026-09-16 amendment). Swiping a
    /// row stops watching it; ``ShepherdPhoneApp`` hands the change to the engine with a sweep.
    private var watchedRepositoriesSection: some View {
        let watched = environment.settings.watchedRepositories
        return Section {
            if watched.isEmpty {
                Text(String(localized: "No repositories watched."))
                    .font(Theme.type(.body))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(watched, id: \.fullName) { repo in
                Label {
                    Text(verbatim: repo.fullName)
                        .font(Theme.mono(.callout))
                        .foregroundStyle(Theme.text)
                        // One line, cut in the middle where the owner and name ends both
                        // survive; wrapped at the accessibility sizes, where one line is a stub.
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "eye")
                        .font(Theme.type(.callout))
                        .foregroundStyle(Theme.accent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        stopWatching(repo)
                    } label: {
                        Label(String(localized: "Stop watching"), systemImage: "eye.slash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        stopWatching(repo)
                    } label: {
                        Label(String(localized: "Stop watching"), systemImage: "eye.slash")
                    }
                }
            }
        } header: {
            Text(String(localized: "Watched repositories"))
        } footer: {
            Text(String(localized: "Every open pull request in these reaches the inbox, under Watched."))
        }
    }

    private var addWatchedRepositorySection: some View {
        let isFull = environment.settings.watchedRepositories.count >= AppSettings.maximumWatchedRepositories
        return Section {
            HStack(spacing: 10) {
                TextField(
                    String(localized: "Add repository"),
                    text: $watchedRepositoryDraft,
                    prompt: Text(String(localized: "owner/repository or a GitHub URL"))
                )
                .font(Theme.type(.body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .onSubmit { addWatchedRepository() }
                Button(String(localized: "Watch")) { addWatchedRepository() }
                    .font(Theme.type(.body, weight: .semibold))
                    .disabled(watchedRepositoryDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(isFull)
            if let watchedRepositoryError {
                Text(watchedRepositoryError)
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            // The cap is stated before it is hit, as the Mac's sheet does: a field that goes dead
            // with no sentence beside it reads as a bug.
            Text(String(
                localized: "\(environment.settings.watchedRepositories.count) of \(AppSettings.maximumWatchedRepositories) — each repository is one more search on every sweep."
            ))
            .foregroundStyle(isFull ? Theme.pending : Theme.textMuted)
        }
    }

    /// Validates the typed repository through the one rule the Mac's two entry points share
    /// (``AppSettings/watchRepository(named:)``) and adds it.
    private func addWatchedRepository() {
        if let failure = environment.settings.watchRepository(named: watchedRepositoryDraft) {
            watchedRepositoryError = failure
            return
        }
        watchedRepositoryDraft = ""
        watchedRepositoryError = nil
    }

    private func stopWatching(_ repo: RepoRef) {
        environment.settings.watchedRepositories.removeAll { $0.isSameRepository(as: repo) }
        watchedRepositoryError = nil
    }

    // MARK: - Language

    /// No picker in the app (ADR 0022): the language is the iPhone's, and the app's own page in the
    /// Settings app is where iOS lets one app differ from it.
    private var languageSection: some View {
        Section {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(String(localized: "Follows your iPhone"))
                        Image(systemName: "arrow.up.forward.app")
                            .accessibilityHidden(true)
                    }
                    .font(Theme.type(.body))
                    .foregroundStyle(Theme.textSecondary)
                } label: {
                    Label {
                        Text(String(localized: "Language"))
                            .font(Theme.type(.body))
                            .foregroundStyle(Theme.text)
                    } icon: {
                        Image(systemName: "globe")
                            .font(Theme.type(.body))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        } footer: {
            Text(String(localized: "Change it for Shepherd alone in the Settings app."))
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(verbatim: Self.versionLine)
                    .font(Theme.type(.body).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            } label: {
                Label {
                    Text(String(localized: "Version"))
                        .font(Theme.type(.body))
                } icon: {
                    Image(systemName: "info.circle")
                        .font(Theme.type(.body))
                        .foregroundStyle(Theme.accent)
                }
            }
            Link(destination: AppConfig.privacyPolicyURL) {
                LabeledContent {
                    Image(systemName: "arrow.up.forward")
                        .font(Theme.type(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .accessibilityHidden(true)
                } label: {
                    Label {
                        Text(String(localized: "Privacy statement"))
                            .font(Theme.type(.body))
                            .foregroundStyle(Theme.text)
                    } icon: {
                        Image(systemName: "hand.raised")
                            .font(Theme.type(.body))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        } header: {
            Text(String(localized: "About"))
        } footer: {
            Text(String(localized: "Fetched data stays in a local database, your token in the Keychain."))
        }
    }

    /// "0.1.0 (1)": the phone's marketing version and the build number TestFlight stamps.
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: - Sign out

    /// The Mac's button and confirmation, word for word (`AccountSettingsTab`): signing out here
    /// erases the same things, and pending reviews are lost the same way.
    @ViewBuilder
    private var signOutSection: some View {
        if environment.session != nil {
            Section {
                Button(role: .destructive) {
                    isConfirmingSignOut = true
                } label: {
                    Label(String(localized: "Sign out & erase local data"), systemImage: "rectangle.portrait.and.arrow.right")
                        .font(Theme.type(.body))
                        .foregroundStyle(Theme.failure)
                }
                .confirmationDialog(
                    String(localized: "Sign out and erase everything?"),
                    isPresented: $isConfirmingSignOut,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "Sign out & erase"), role: .destructive) {
                        Task { await environment.signOutAndErase() }
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text(String(
                        localized: "The Keychain token is deleted and the local database is emptied. Pending reviews that have not been sent are lost."
                    ))
                }
            }
            .sensoryFeedback(.warning, trigger: isConfirmingSignOut) { _, confirming in confirming }
        }
    }
}
