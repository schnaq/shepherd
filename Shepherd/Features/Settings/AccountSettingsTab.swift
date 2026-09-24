import ShepherdCore
import ShepherdPersistence
import SwiftUI

/// Avatar, login, sign out & erase — plus the local-diagnostics section (ADR 0017), usage
/// statistics (ADR 0036) and the update section (ADR 0010).
///
/// Updates live here rather than in a pane of their own: it is three controls, and "which build am
/// I running, and where does the next one come from" is the same question as "which account am I".
/// Diagnostics join them for the same reason and one more: this pane is already where Shepherd
/// states what it keeps on this Mac and where, so "and here is the other folder, which stays empty
/// unless you ask for it" belongs next to it rather than under Appearance, where it would read as a
/// display preference.
///
/// Diagnostics, usage statistics and updates sit outside the signed-in branch on purpose: the app
/// updates itself, and crashes, whether or not anyone is signed in.
struct AccountSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingSignOut = false
    /// How many diagnostic reports are on disk.
    ///
    /// Read from the folder when the pane appears and after "Delete all", rather than observed:
    /// the number only ever changes at launch (MetricKit delivers the previous run's diagnostics
    /// then) or because this section just emptied the folder, so there is nothing for an
    /// observation to notice while Settings is open.
    @State private var diagnosticsReportCount = 0
    @State private var isConfirmingDiagnosticsDelete = false
    @State private var diagnosticsError: String?

    var body: some View {
        SettingsPage {
            accountSection
            diagnosticsSection
            // Directly under diagnostics: the two answer the same question from opposite ends —
            // what this Mac keeps about itself, and what it says about itself (ADR 0036).
            TelemetrySettingsCard()
            updatesSection
        }
        .task { refreshDiagnosticsCount() }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        if let session = environment.session {
            Section {
                HStack(spacing: 12) {
                    AvatarView(
                        login: session.account.login,
                        url: session.account.avatarURL,
                        size: 40
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: session.account.login)
                            .font(Theme.type(.headline))
                        Text(authDescription(session.account.authKind))
                            .font(Theme.type(.caption))
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    // The Keychain sentence is the one that turns a frightening system dialog into
                    // a boring one: macOS asks for the Keychain password when a build *other than
                    // the one that stored the token* reaches for it, and says only that "Shepherd"
                    // wants access. Nothing here can change that dialog's words, so the
                    // explanation sits beside the row that says where the token is.
                    InfoButton(localDataDetail)
                } label: {
                    Text(String(localized: "Local data"))
                    Text(String(localized: "Fetched data stays in a local database, your token in the Keychain."))
                }

                Button(String(localized: "Sign out & erase local data"), role: .destructive) {
                    isConfirmingSignOut = true
                }
                .foregroundStyle(Theme.failure)
                .confirmationDialog(
                    String(localized: "Sign out and erase everything?"),
                    isPresented: $isConfirmingSignOut
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
        } else {
            Section {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text(String(localized: "Not signed in"))
                    Text(String(localized: "Sign in from the main window to see your account here."))
                }
            }
        }
    }

    /// Where the database is, and why macOS may ask for the Keychain password.
    private var localDataDetail: String {
        String(localized: "The database is at \(AppConfig.databaseURL.path). Your token is kept in the Keychain and nowhere else.")
            + "\n\n"
            + String(
                localized: "If macOS asks for your Keychain password, a different build of Shepherd than the one that saved the token is asking — a copy you built yourself, for example. Always Allow answers it once for that build."
            )
    }

    // MARK: - Diagnostics (ADR 0017)

    /// The opt-in toggle, how many reports are stored, where they are, and the two buttons that
    /// do the only two things anyone wants to do with them.
    ///
    /// The copy carries two facts the user cannot check for themselves and would otherwise have
    /// to trust: nothing is sent anywhere, and a report only shows up at the *next* launch after a
    /// crash — MetricKit has no other delivery moment, and a section that did not say so would
    /// look broken immediately after the crash it is meant to record.
    private var diagnosticsSection: some View {
        Section {
            Toggle(isOn: diagnosticsBinding) {
                Text(String(localized: "Keep crash and hang reports on this Mac"))
                Text(String(localized: "Stored only on this Mac and never sent anywhere."))
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Button(String(localized: "Show in Finder")) {
                        environment.diagnostics.revealInFinder()
                    }
                    Button(String(localized: "Delete all")) {
                        isConfirmingDiagnosticsDelete = true
                    }
                    .disabled(diagnosticsReportCount == 0)
                }
            } label: {
                Text(diagnosticsCountLine)
                Text(verbatim: environment.diagnostics.directory.path)
                    .font(Theme.mono(.caption))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .confirmationDialog(
                String(localized: "Delete all diagnostic reports?"),
                isPresented: $isConfirmingDiagnosticsDelete
            ) {
                Button(String(localized: "Delete all"), role: .destructive) {
                    deleteAllDiagnostics()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(
                    localized: "The JSON files in the folder are removed. Nothing else is touched, and no copy of them exists anywhere else."
                ))
            }
            if let diagnosticsError {
                Text(diagnosticsError)
                    .font(Theme.type(.caption))
                    .foregroundStyle(Theme.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(String(localized: "Diagnostics"))
        } footer: {
            SettingsNote(String(localized: "A report appears at the next launch after a crash."))
        }
    }

    /// "No reports stored yet." / "1 report stored." / "7 reports stored; the 30 newest are kept."
    private var diagnosticsCountLine: String {
        switch diagnosticsReportCount {
        case 0:
            return String(localized: "No reports stored yet.")
        case 1:
            return String(localized: "1 report stored.")
        default:
            return String(
                localized: "\(diagnosticsReportCount) reports stored; the \(DiagnosticsStore.retentionLimit) newest are kept."
            )
        }
    }

    private var diagnosticsBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.diagnosticsEnabled },
            set: {
                environment.settings.diagnosticsEnabled = $0
                // Registers or removes the MetricKit subscriber right away, the way the appearance
                // picker applies its choice right away rather than waiting for the main window.
                environment.applyDiagnosticsSetting()
            }
        )
    }

    private func refreshDiagnosticsCount() {
        diagnosticsReportCount = environment.diagnostics.reportCount
    }

    private func deleteAllDiagnostics() {
        do {
            try environment.diagnostics.deleteAllReports()
            diagnosticsError = nil
        } catch {
            diagnosticsError = String(
                localized: "Could not delete every report: \(error.userFacingDescription)"
            )
        }
        refreshDiagnosticsCount()
    }

    // MARK: - Updates (ADR 0010)

    /// The Sparkle section: the version, the opt-out toggle, and a manual check.
    ///
    /// The toggle is bound to Sparkle's own `automaticallyChecksForUpdates`, which Sparkle
    /// persists itself — so this is the one preference in the app that deliberately does not go
    /// through ``AppSettings``, because a second copy of it could only ever disagree with the one
    /// the updater actually reads.
    private var updatesSection: some View {
        Section {
            LabeledContent(String(localized: "Version")) {
                Text(verbatim: versionLine)
            }
            Toggle(isOn: autoUpdateBinding) {
                Text(String(localized: "Check for updates automatically"))
                Text(String(localized: "Installed only after you confirm, never in the background."))
            }
            .disabled(!environment.updates.isEnabled)
            if let problem = environment.updates.problem {
                Label(problem.explanation, systemImage: "exclamationmark.triangle")
                    .font(Theme.type(.caption))
                    .foregroundStyle(Theme.pending)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent {
                Button(String(localized: "Check now")) {
                    environment.updates.checkForUpdates()
                }
                .disabled(!environment.updates.isEnabled)
            } label: {
                if let date = environment.updates.lastCheckDate {
                    Text(String(localized: "Last checked \(RelativeDate.long(date))"))
                } else {
                    Text(String(localized: "Not checked yet"))
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text(String(localized: "Updates"))
                InfoButton(updatesDetail)
            }
        }
    }

    /// Where updates come from and why they never install on their own — with the feed, when the
    /// updater has one, so the source can be checked rather than trusted.
    private var updatesDetail: String {
        let rule = String(
            localized: "Updates are downloaded from GitHub Releases and installed only after you confirm — never in the background, so an unsent review draft is never interrupted."
        )
        guard let feed = environment.updates.feedURL else { return rule }
        return rule + "\n\n" + String(localized: "Feed: \(feed.absoluteString)")
    }

    /// `Shepherd 0.1.0 (build 1)`, straight out of the bundle so it can never disagree with what
    /// the updater compares against.
    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return String(localized: "Shepherd \(short) (build \(build))")
    }

    private var autoUpdateBinding: Binding<Bool> {
        Binding(
            get: { environment.updates.checksAutomatically },
            set: { environment.updates.checksAutomatically = $0 }
        )
    }

    private func authDescription(_ kind: AuthKind) -> String {
        switch kind {
        case .deviceFlow: return String(localized: "Signed in with the GitHub App device flow")
        case .pat: return String(localized: "Signed in with a personal access token")
        }
    }
}
