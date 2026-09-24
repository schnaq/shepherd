import ShepherdCore
import ShepherdPersistence
import SwiftUI

/// Avatar, login, sign out & erase — plus the local-diagnostics section (ADR 0017) and the update
/// section (ADR 0010).
///
/// Updates live here rather than in a tab of their own: it is three controls, and "which build am
/// I running, and where does the next one come from" is the same question as "which account am I".
/// Diagnostics join them for the same reason and one more: this tab is already where Shepherd
/// states what it keeps on this Mac and where — the LOCAL DATA card just above names the database
/// path — so "and here is the other folder, which stays empty unless you ask for it" belongs next
/// to it rather than under Appearance, where it would read as a display preference.
///
/// Both sections sit outside the signed-in branch on purpose: the app updates itself, and crashes,
/// whether or not anyone is signed in.
struct AccountSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingSignOut = false
    /// How many diagnostic reports are on disk.
    ///
    /// Read from the folder when the tab appears and after "Delete all", rather than observed:
    /// the number only ever changes at launch (MetricKit delivers the previous run's diagnostics
    /// then) or because this card just emptied the folder, so there is nothing for an observation
    /// to notice while Settings is open.
    @State private var diagnosticsReportCount = 0
    @State private var isConfirmingDiagnosticsDelete = false
    @State private var diagnosticsError: String?

    var body: some View {
        SettingsPage {
            accountSection
            diagnosticsCard
            // Directly under diagnostics: the two answer the same question from opposite ends —
            // what this Mac keeps about itself, and what it says about itself (ADR 0036).
            TelemetrySettingsCard()
            updatesCard
        }
        .task { refreshDiagnosticsCount() }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        if let session = environment.session {
            HStack(spacing: 12) {
                AvatarView(
                    login: session.account.login,
                    url: session.account.avatarURL,
                    size: 46
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.account.login)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                    Text(authDescription(session.account.authKind))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            }

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(String(localized: "LOCAL DATA"))
                    Text(String(
                        localized: "Everything Shepherd has fetched lives in a SQLite file in Application Support. Your token lives in the Keychain and nowhere else."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(AppConfig.databaseURL.path)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    // The one sentence that turns a frightening system dialog into a boring one.
                    // macOS asks for the Keychain password when a build *other than the one that
                    // stored the token* reaches for it, and says only that "Shepherd" wants
                    // access — which reads like something is wrong. Nothing here can change that
                    // dialog's words, so the explanation lives beside the sentence that says
                    // where the token is.
                    Text(String(
                        localized: "If macOS asks for your Keychain password, it is because a different build of Shepherd than the one that saved the token is asking for it — a copy you built yourself beside the installed one, for example. Always Allow answers it once for that build."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(String(localized: "Sign out & erase local data")) {
                isConfirmingSignOut = true
            }
            .buttonStyle(SecondaryButtonStyle(tint: Theme.failure))
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
        } else {
            EmptyStateView(
                systemImage: "person.crop.circle.badge.questionmark",
                title: String(localized: "Not signed in"),
                message: String(localized: "Sign in from the main window to see your account here.")
            )
        }
    }

    // MARK: - Diagnostics (ADR 0017)

    /// The opt-in toggle, how many reports are stored, where they are, and the two buttons that
    /// do the only two things anyone wants to do with them.
    ///
    /// The wording carries two facts the user cannot check for themselves and would otherwise
    /// have to trust: nothing is sent anywhere, and a report only shows up at the *next* launch
    /// after a crash — MetricKit has no other delivery moment, and a card that did not say so
    /// would look broken immediately after the crash it is meant to record.
    private var diagnosticsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "DIAGNOSTICS"))
                Toggle(
                    String(localized: "Keep crash and hang reports on this Mac"),
                    isOn: diagnosticsBinding
                )
                Text(String(
                    localized: "Off by default. With this on, macOS hands Shepherd the crash, hang and CPU-exception reports of previous runs and Shepherd writes each one as a JSON file in the folder below. They are stored only on this Mac and are never sent anywhere — there is no crash service and no upload. Reports appear after the next launch following a crash, not while it happens."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                Text(diagnosticsCountLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text(environment.diagnostics.directory.path)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button(String(localized: "Show in Finder")) {
                        environment.diagnostics.revealInFinder()
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                    Button(String(localized: "Delete all")) {
                        isConfirmingDiagnosticsDelete = true
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28, tint: Theme.failure))
                    .disabled(diagnosticsReportCount == 0)
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
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
    private var updatesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "UPDATES"))
                Text(versionLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Toggle(String(localized: "Check for updates automatically"), isOn: autoUpdateBinding)
                    .disabled(!environment.updates.isEnabled)
                if let problem = environment.updates.problem {
                    Label(problem.explanation, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.pending)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(
                        localized: "Updates are downloaded from GitHub Releases and are only installed after you confirm — never in the background, so an unsent review draft can never be interrupted."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(String(localized: "Check now")) {
                        environment.updates.checkForUpdates()
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                    .disabled(!environment.updates.isEnabled)
                    if let date = environment.updates.lastCheckDate {
                        Text(String(localized: "Last checked \(RelativeDate.long(date))"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                if let feed = environment.updates.feedURL {
                    Text(feed.absoluteString)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textMuted)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
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

