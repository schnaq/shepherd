import GitHubKit
import ShepherdCore
import SwiftUI
import UIKit

/// The iPhone's settings, as a sheet over the inbox (ADR 0044): the account and the way out of
/// it, the watched repositories, the language and what this build is.
///
/// Far fewer than the Mac's nine panes on purpose: the phone runs no automation, no delegation, no
/// intelligence and no settings sync, so a switch for any of them would switch nothing. A system
/// `Form`, because settings are the one screen iOS users expect to look like Settings.
///
/// Opened by assigning ``PhoneEnvironment/isSettingsPresented`` — ``PhoneSettingsButton`` does it
/// from the inbox's toolbar.
struct PhoneSettingsView: View {
    @Environment(PhoneEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingSignOut = false
    @State private var watchedRepositoryDraft = ""
    @State private var watchedRepositoryError: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 52

    var body: some View {
        NavigationStack {
            Form {
                accountSection
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

/// The inbox's account button: the signed-in avatar, opening ``PhoneSettingsView``.
///
/// For the inbox's leading toolbar item (`ToolbarItem(placement: .topBarLeading)`), where the
/// system draws its glass around it. Its own type so the inbox screen only has to place it.
struct PhoneSettingsButton: View {
    @Environment(PhoneEnvironment.self) private var environment
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        Button {
            environment.isSettingsPresented = true
        } label: {
            if let account = environment.session?.account {
                AvatarView(login: account.login, url: account.avatarURL, size: size)
            } else {
                Image(systemName: "gearshape")
            }
        }
        .accessibilityLabel(Text(String(localized: "Settings")))
    }
}
