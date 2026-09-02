import ShepherdCore
import SwiftUI

/// The Settings window: Account, Sync, Replies, Agents, Intelligence, Delegation, Automation,
/// Appearance.
///
/// Replies (saved replies + per-repository review templates) sits between Sync and the AI cluster
/// because it is the one tab about the *review path* itself, and because it is the only tab where
/// the user authors content rather than configuring a connection.
///
/// Webhooks get their own tab rather than a section under Sync: Sync is about keeping the local
/// cache in step with GitHub, while Automation is about what Shepherd tells the outside world —
/// a different direction, a different failure mode, and the place the next integration will go.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model = SettingsModel()
    /// The encrypted settings-sync model (ADR 0014). Owned here rather than by the section so
    /// the passphrase and key fields survive a tab switch within one Settings window.
    @State private var syncModel = SettingsSyncModel()
    /// Which tab is showing. Every tab is tagged with its ``SettingsDeepLinkTab``, which is
    /// what lets `shepherd://settings/<tab>` land on one (ADR 0013).
    @State private var selection: SettingsDeepLinkTab

    /// Creates the Settings window or sheet.
    /// - Parameter initialTab: The tab to open on. Defaults to Account, which is what the
    ///   ⌘, window and the rail button want.
    init(initialTab: SettingsDeepLinkTab = .account) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            AccountSettingsTab()
                .tabItem { Label(String(localized: "Account"), systemImage: "person.crop.circle") }
                .tag(SettingsDeepLinkTab.account)
            SyncSettingsTab(syncModel: syncModel)
                .tabItem { Label(String(localized: "Sync"), systemImage: "arrow.clockwise") }
                .tag(SettingsDeepLinkTab.sync)
            RepliesSettingsTab()
                .tabItem {
                    Label(String(localized: "Replies"), systemImage: "text.badge.plus")
                }
                .tag(SettingsDeepLinkTab.replies)
            AgentSettingsTab(model: model)
                .tabItem { Label(String(localized: "Agents"), systemImage: "cpu") }
                .tag(SettingsDeepLinkTab.agents)
            IntelligenceSettingsTab(model: model)
                .tabItem { Label(String(localized: "Intelligence"), systemImage: "sparkles") }
                .tag(SettingsDeepLinkTab.intelligence)
            DelegationSettingsTab()
                .tabItem {
                    Label(
                        String(localized: "Delegation"),
                        systemImage: "arrow.uturn.backward.badge.clock"
                    )
                }
                .tag(SettingsDeepLinkTab.delegation)
            AutomationSettingsTab(model: model)
                .tabItem {
                    Label(String(localized: "Automation"), systemImage: "bolt.horizontal")
                }
                .tag(SettingsDeepLinkTab.automation)
            AppearanceSettingsTab()
                .tabItem { Label(String(localized: "Appearance"), systemImage: "paintbrush") }
                .tag(SettingsDeepLinkTab.appearance)
        }
        .frame(width: 620, height: 460)
        .background(Theme.background)
    }
}

// MARK: - Account

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
                localized: "Could not delete every report: \(error.localizedDescription)"
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

// MARK: - Sync

/// Sweep interval, notification toggles, and settings sync across Macs (ADR 0014).
///
/// The encrypted sync belongs here rather than in its own tab because it is the same subject as
/// the rest of the page — keeping things in step — just with a different peer: the sweep keeps
/// this Mac in step with GitHub, the section at the bottom keeps it in step with the user's other
/// Macs.
struct SyncSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    /// The encrypted settings-sync model, owned by ``SettingsView``.
    let syncModel: SettingsSyncModel

    var body: some View {
        SettingsPage {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(String(localized: "INBOX SWEEP"))
                    HStack(spacing: 12) {
                        Slider(value: intervalBinding, in: 1...10, step: 1)
                        Text(String(localized: "\(Int(environment.settings.sweepIntervalMinutes)) min"))
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    Text(String(
                        localized: "Notifications are polled at the interval GitHub asks for; this slider only controls the full search sweep. It takes effect the next time you sign in."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "NOTIFICATIONS"))
                    Toggle(String(localized: "A new review is requested from me"), isOn: reviewBinding)
                    Toggle(String(localized: "Checks fail on a pull request I opened"), isOn: checksBinding)
                    Toggle(String(localized: "A queued review could not be sent"), isOn: conflictBinding)
                    Text(String(
                        localized: "macOS asks for permission the first time Shepherd actually needs to post one."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                }
            }

            digestCard

            if let session = environment.session {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        CardTitle(String(localized: "OUTBOX"))
                        Text(session.pendingOutboxCount == 0
                            ? String(localized: "Nothing waiting to be sent.")
                            : String(localized: "\(session.pendingOutboxCount) mutations waiting to be sent."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        // A parked mutation is never retried on its own (ADR 0006), so it stays
                        // on screen until someone acts on it — the alert it raised was a moment,
                        // this is the standing reminder.
                        if session.conflictedOutboxCount > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text(String(
                                    localized: "\(session.conflictedOutboxCount) conflicted — needs your attention."
                                ))
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.pending)
                            .help(String(
                                localized: "These pull requests got new commits after the review was queued, so nothing was sent. Open each one and check your draft against the new commit."
                            ))
                        }
                        Button(String(localized: "Sync now")) {
                            Task { await environment.syncNow() }
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 28))
                    }
                }
            }

            SettingsSyncSection(model: syncModel)
        }
    }

    // MARK: - Morning digest

    /// The opt-in, the time, the weekday switch, and what the digest actually reports.
    ///
    /// It sits on this tab, under the notification toggles, rather than on a tab of its own: it *is*
    /// a notification preference — a scheduled one — and the two things it reports on that are not
    /// pull requests, the outbox and its parked reviews, are counted in the card directly below.
    /// A tab of its own would be three controls in an empty room.
    ///
    /// The wording carries the two facts the user cannot check for themselves: nothing is fetched or
    /// sent when the digest is built, and a Mac that was asleep still gets its digest — once — when
    /// it wakes up on the same day.
    private var digestCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "MORNING DIGEST"))
                Toggle(String(localized: "Send me a morning digest"), isOn: digestEnabledBinding)
                HStack(spacing: 12) {
                    DatePicker(
                        String(localized: "At"),
                        selection: digestTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.field)
                    .fixedSize()
                    Toggle(String(localized: "Weekdays only"), isOn: digestWeekdaysBinding)
                }
                .disabled(!environment.settings.digest.isEnabled)
                Text(String(
                    localized: "Off by default. One notification a day summarising what came in since the last one: new review requests, green agent pull requests that only need an approval or a merge, your own pull requests with red CI or a change request, and reviews the outbox could not send. Clicking it opens the inbox, and the same summary sits above the list as a card you can dismiss."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                Text(String(
                    localized: "It is built from the local database only — no GitHub call, no AI, nothing sent anywhere — because it runs while you are not watching. If your Mac was asleep at that time, the digest arrives when it wakes up, and only if that is still the same day. A quiet night produces nothing at all."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                Text(digestStatusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// "No digest delivered on this Mac yet." / "Last digest 2 hours ago."
    private var digestStatusLine: String {
        guard let last = environment.settings.digestLastDeliveredAt else {
            return String(localized: "No digest delivered on this Mac yet.")
        }
        return String(localized: "Last digest \(RelativeDate.long(last)).")
    }

    private var digestEnabledBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.digest.isEnabled },
            // Nothing to apply: `DigestCoordinator` reads the schedule on every tick, so the
            // next check — within a minute — sees the new value, whether it was flipped here or
            // arrived in a settings-sync document.
            set: { isOn in
                var schedule = environment.settings.digest
                schedule.isEnabled = isOn
                environment.settings.digest = schedule
            }
        )
    }

    private var digestWeekdaysBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.digest.weekdaysOnly },
            set: { isOn in
                var schedule = environment.settings.digest
                schedule.weekdaysOnly = isOn
                environment.settings.digest = schedule
            }
        )
    }

    /// The hour and minute as a `Date`, which is the only shape `DatePicker` speaks.
    ///
    /// Built on *today* rather than on a bare `DateComponents`: a components-only date lands in
    /// year one, where a calendar's answers stop being interesting, and the picker shows the time
    /// either way.
    private var digestTimeBinding: Binding<Date> {
        Binding(
            get: {
                let schedule = environment.settings.digest
                let calendar = Calendar.current
                var parts = calendar.dateComponents([.year, .month, .day], from: Date())
                parts.hour = schedule.normalizedHour
                parts.minute = schedule.normalizedMinute
                parts.second = 0
                return calendar.date(from: parts) ?? Date()
            },
            set: { picked in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                var schedule = environment.settings.digest
                schedule.hour = parts.hour ?? DigestSchedule.defaultHour
                schedule.minute = parts.minute ?? DigestSchedule.defaultMinute
                environment.settings.digest = schedule
            }
        )
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { environment.settings.sweepIntervalMinutes },
            set: { environment.settings.sweepIntervalMinutes = $0 }
        )
    }

    private var reviewBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.notifyOnReviewRequest },
            set: { environment.settings.notifyOnReviewRequest = $0 }
        )
    }

    private var checksBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.notifyOnChecksFailed },
            set: { environment.settings.notifyOnChecksFailed = $0 }
        )
    }

    private var conflictBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.notifyOnDraftConflict },
            set: { environment.settings.notifyOnDraftConflict = $0 }
        )
    }
}

// MARK: - Agents

/// The bundled registry (read-only) plus the user's extensions (ADR 0008).
struct AgentSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    /// The settings model.
    let model: SettingsModel
    @State private var errorMessage: String?

    var body: some View {
        SettingsPage {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(String(localized: "BUNDLED REGISTRY"))
                    if let error = model.registryError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.failure)
                    }
                    ForEach(model.bundledAgents) { entry in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(AgentPalette.color(forAgentID: entry.id))
                                .frame(width: 8, height: 8)
                            Text(entry.displayName)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: 6)
                            Text(entry.loginPatterns.joined(separator: ", "))
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Text(String(
                        localized: "Bundled entries ship with Shepherd. Add your own below — an entry with the same id replaces the bundled one."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "YOUR EXTENSIONS"))
                    if model.overrides.isEmpty {
                        Text(String(localized: "None yet."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    ForEach(model.overrides) { entry in
                        HStack(spacing: 8) {
                            Text(entry.displayName)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text)
                            Text(entry.id)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.textMuted)
                            Spacer(minLength: 6)
                            Button(String(localized: "Remove")) {
                                Task {
                                    await model.removeOverride(
                                        id: entry.id,
                                        session: environment.session
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.failure)
                        }
                    }

                    Divider().overlay(Theme.hairline)

                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text(String(localized: "Id"))
                            TextField("my-agent", text: idBinding)
                        }
                        GridRow {
                            Text(String(localized: "Name"))
                            TextField("My Agent", text: nameBinding)
                        }
                        GridRow {
                            Text(String(localized: "Logins"))
                            TextField("my-agent[bot], my-agent-*", text: loginsBinding)
                        }
                        GridRow {
                            Text(String(localized: "Branches"))
                            TextField("my-agent/", text: branchesBinding)
                        }
                        GridRow {
                            Text(String(localized: "Trailers"))
                            TextField("Co-Authored-By: My Agent", text: trailersBinding)
                        }
                    }
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.failure)
                    }

                    Button(String(localized: "Add entry")) {
                        Task {
                            errorMessage = await model.addOverride(session: environment.session)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                }
            }
        }
        .task {
            await model.loadRegistry(session: environment.session)
        }
    }

    private var idBinding: Binding<String> {
        Binding(get: { model.newAgentID }, set: { model.newAgentID = $0 })
    }

    private var nameBinding: Binding<String> {
        Binding(get: { model.newAgentName }, set: { model.newAgentName = $0 })
    }

    private var loginsBinding: Binding<String> {
        Binding(get: { model.newAgentLogins }, set: { model.newAgentLogins = $0 })
    }

    private var branchesBinding: Binding<String> {
        Binding(get: { model.newAgentBranches }, set: { model.newAgentBranches = $0 })
    }

    private var trailersBinding: Binding<String> {
        Binding(get: { model.newAgentTrailers }, set: { model.newAgentTrailers = $0 })
    }
}

// MARK: - Intelligence

/// Provider picker, BYOK configuration, connection test (ADR 0007).
struct IntelligenceSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    /// The settings model.
    let model: SettingsModel
    @State private var saveError: String?

    var body: some View {
        SettingsPage {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "PROVIDER"))
                    Picker(String(localized: "Provider"), selection: modeBinding) {
                        ForEach(IntelligenceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(environment.settings.intelligenceMode.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if environment.settings.intelligenceMode != .off,
                       let reason = OnDeviceProvider.unavailabilityReason() {
                        Text(String(localized: "On-device model: \(reason)"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.pending)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if environment.settings.intelligenceMode == .onDeviceAndCloud {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(String(localized: "BRING YOUR OWN KEY"))
                        Picker(String(localized: "Kind"), selection: kindBinding) {
                            ForEach(CloudProviderKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if environment.settings.cloudProviderKind == .openAICompatible {
                            endpointPresetPicker
                            LabeledField(
                                label: String(localized: "Base URL"),
                                placeholder: "https://api.example.eu/v1",
                                text: baseURLBinding
                            )
                            modelField
                            endpointNote
                        } else {
                            LabeledField(
                                label: String(localized: "Model"),
                                placeholder: AnthropicProvider.defaultModel,
                                text: anthropicModelBinding
                            )
                        }

                        HStack(spacing: 8) {
                            Text(String(localized: "API key"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 74, alignment: .leading)
                            SecureField(apiKeyPlaceholder, text: keyBinding)
                                .textFieldStyle(.roundedBorder)
                        }

                        Text(String(
                            localized: "The key is stored in your Keychain, next to the GitHub token, and is sent only to the endpoint above."
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button(String(localized: "Save key")) {
                                saveError = model.saveKey(
                                    kind: environment.settings.cloudProviderKind,
                                    store: environment.secretStore
                                )
                                environment.refreshIntelligence()
                            }
                            .buttonStyle(SecondaryButtonStyle(height: 28))

                            if environment.settings.cloudProviderKind == .openAICompatible {
                                Button(String(localized: "Load models")) {
                                    Task { await model.loadModels(settings: environment.settings) }
                                }
                                .buttonStyle(SecondaryButtonStyle(height: 28))
                                .disabled(
                                    model.modelListState == .loading
                                        || !model.canLoadModels(settings: environment.settings)
                                )
                            }

                            Button(String(localized: "Test connection")) {
                                Task { await model.testConnection(settings: environment.settings) }
                            }
                            .buttonStyle(SecondaryButtonStyle(height: 28))
                            .disabled(model.testState == .running)

                            if model.testState == .running || model.modelListState == .loading {
                                ProgressView().controlSize(.small)
                            }
                        }

                        modelListResult
                        testResult
                        if let saveError {
                            Text(saveError)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.failure)
                        }
                    }
                }
            }

            semanticSearchCard

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(String(localized: "WHAT AI NEVER DOES"))
                    Text(String(
                        localized: "AI output is only ever shown as a dismissible hint. Shepherd never submits a review, approves, merges or comments on your behalf."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            model.loadKey(
                kind: environment.settings.cloudProviderKind,
                store: environment.secretStore
            )
            await model.loadModelsIfConfigured(settings: environment.settings)
        }
        .onChange(of: environment.settings.cloudProviderKind) { _, kind in
            model.loadKey(kind: kind, store: environment.secretStore)
            environment.refreshIntelligence()
        }
        .onChange(of: environment.settings.intelligenceMode) { _, _ in
            environment.refreshIntelligence()
        }
    }

    // MARK: - Semantic ⌘K search (ADR 0019)

    /// The one toggle, one status line and one button the search index needs.
    ///
    /// It sits on the Intelligence tab because that is where a user looks for "how does Shepherd
    /// understand my pull requests", and it sits *below* the provider card with its own copy
    /// because the answer for this feature is different from the answer for every other one on the
    /// tab: it never uses a provider. The two sentences below are the whole privacy story, and they
    /// are in the UI rather than only in the ADR because "does typing in ⌘K send my diffs
    /// somewhere" is a question a user is entitled to have answered where they are standing.
    ///
    /// On by default, which no other intelligence-shaped setting is (ADR 0019 argues it).
    private var semanticSearchCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "SEMANTIC SEARCH"))
                Toggle(
                    String(localized: "Semantic search index"),
                    isOn: semanticSearchBinding
                )
                Text(String(
                    localized: "⌘K searches your pull requests by what they are about — the title, the description, the labels, the branch, the changed files and the diff of anything you have opened — not just by exact words. The index is built on this Mac from what Shepherd already downloaded, with Apple's on-device embeddings, and it is stored in the local database."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                Text(String(
                    localized: "It never uses an AI endpoint, even when you have configured one: search runs on every keystroke and over every pull request, so it stays on this Mac. Switching it off leaves ⌘K searching titles, labels, repositories, branches and authors, and empties the index."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                Text(searchIndexStatusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(String(localized: "Rebuild index")) {
                        environment.rebuildSearchIndex()
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                    .disabled(
                        !environment.settings.semanticSearchEnabled
                            || environment.session == nil
                    )
                    if environment.search.status.isIndexing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    /// "412 pull requests indexed · 806 KB · last updated 4 minutes ago", and the honest variants.
    ///
    /// Assembled from ``SearchIndexStatus`` rather than from the database directly, so the line
    /// says what the *running* index holds. The two states worth naming are switched-off and
    /// "no model on this Mac": both leave search working on words, and a card that showed a size
    /// of zero without saying why would read as a bug.
    private var searchIndexStatusLine: String {
        let status = environment.search.status
        guard environment.settings.semanticSearchEnabled else {
            return String(localized: "Off — ⌘K matches words only, and nothing is stored.")
        }
        if let reason = status.embeddingUnavailabilityReason {
            return reason
        }
        let sizeText = ByteCountFormatter.string(
            fromByteCount: Int64(status.vectorByteCount),
            countStyle: .file
        )
        guard let last = status.lastIndexedAt else {
            guard status.isIndexing else { return String(localized: "Nothing indexed yet.") }
            return String(localized: "Indexing \(status.documentCount) pull requests…")
        }
        return String(
            localized: "\(status.embeddedCount) of \(status.documentCount) pull requests indexed · \(sizeText) · last updated \(RelativeDate.long(last))."
        )
    }

    private var semanticSearchBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.semanticSearchEnabled },
            // Nothing is applied here: `ShepherdApp` watches the flag and calls
            // `applySemanticSearchSetting()`, so the toggle and an arriving settings document
            // reach the coordinator through one route (ADR 0017's rule, ADR 0019's feature).
            set: { environment.settings.semanticSearchEnabled = $0 }
        )
    }

    // MARK: - OpenAI-compatible endpoint (ADR 0007, tier 3b)

    /// The preset picker. Selecting a preset fills in its base URL; "Custom" keeps the typed one.
    private var endpointPresetPicker: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Endpoint"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 74, alignment: .leading)
            Picker(String(localized: "Endpoint"), selection: presetBinding) {
                ForEach(IntelligenceEndpointPreset.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
        }
    }

    /// The endpoint's note plus, where the endpoint issues keys, a link to its console.
    @ViewBuilder
    private var endpointNote: some View {
        if let note = preset.note {
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let url = preset.consoleURL, let title = preset.consoleLinkTitle {
            Link(title, destination: url)
                .font(.system(size: 11))
        }
    }

    /// The model row: a picker once the endpoint's list is loaded, the free-text field otherwise.
    @ViewBuilder
    private var modelField: some View {
        if modelOptions.isEmpty {
            LabeledField(
                label: String(localized: "Model"),
                placeholder: preset.modelPlaceholder,
                text: openAIModelBinding
            )
        } else {
            HStack(spacing: 8) {
                Text(String(localized: "Model"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 74, alignment: .leading)
                Picker(String(localized: "Model"), selection: openAIModelBinding) {
                    ForEach(modelOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                Button(String(localized: "Type a name")) { model.forgetLoadedModels() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accentText)
            }
        }
    }

    /// What the last model-discovery run produced.
    @ViewBuilder
    private var modelListResult: some View {
        switch model.modelListState {
        case .idle, .loading:
            EmptyView()
        case .loaded(let models):
            Text(String(localized: "\(models.count) models offered by this endpoint."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        case .failed(let message):
            Label(
                String(localized: "Could not load models: \(message)"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.pending)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The model ids the picker should offer, empty when the free-text field is in charge.
    private var modelOptions: [String] {
        model.modelOptions(selected: environment.settings.openAICompatibleModel)
    }

    /// The endpoint preset currently selected.
    private var preset: IntelligenceEndpointPreset {
        environment.settings.openAICompatiblePreset
    }

    /// The placeholder of the key field, which differs per endpoint.
    private var apiKeyPlaceholder: String {
        environment.settings.cloudProviderKind == .openAICompatible
            ? preset.apiKeyPlaceholder
            : "sk-…"
    }

    private var testResult: some View {
        AsyncActionStatusLine(state: model.testState)
    }

    private var modeBinding: Binding<IntelligenceMode> {
        Binding(
            get: { environment.settings.intelligenceMode },
            set: { environment.settings.intelligenceMode = $0 }
        )
    }

    private var kindBinding: Binding<CloudProviderKind> {
        Binding(
            get: { environment.settings.cloudProviderKind },
            set: { environment.settings.cloudProviderKind = $0 }
        )
    }

    private var presetBinding: Binding<IntelligenceEndpointPreset> {
        Binding(
            get: { environment.settings.openAICompatiblePreset },
            set: { selection in
                environment.settings.applyEndpointPreset(selection)
                // A list loaded from the previous endpoint would offer models the new one does
                // not serve, so it is dropped rather than shown for the wrong host.
                model.forgetLoadedModels()
                environment.refreshIntelligence()
            }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { environment.settings.openAICompatibleBaseURL },
            set: { url in
                // The picker follows the field on its own — the preset is derived from the base
                // URL — so editing by hand cannot leave it claiming an endpoint the field
                // contradicts, and typing a preset's URL selects that preset.
                environment.settings.openAICompatibleBaseURL = url
                model.forgetLoadedModels()
            }
        )
    }

    private var openAIModelBinding: Binding<String> {
        Binding(
            get: { environment.settings.openAICompatibleModel },
            set: { environment.settings.openAICompatibleModel = $0 }
        )
    }

    private var anthropicModelBinding: Binding<String> {
        Binding(
            get: { environment.settings.anthropicModel },
            set: { environment.settings.anthropicModel = $0 }
        )
    }

    private var keyBinding: Binding<String> {
        Binding(get: { model.apiKeyField }, set: { model.apiKeyField = $0 })
    }
}

// MARK: - Appearance

/// Dark, light or system, the diff viewer's chrome, and whether the menu-bar quick inbox is
/// inserted.
///
/// The menu-bar toggle lives here rather than on its own tab or under Sync: it decides whether a
/// piece of Shepherd's chrome is on screen, which is the question this tab answers — and the
/// synced document keeps it in `appearance` for the same reason.
struct AppearanceSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsPage {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "APPEARANCE"))
                    Picker(String(localized: "Appearance"), selection: appearanceBinding) {
                        ForEach(AppearanceSetting.allCases) { setting in
                            Text(setting.title).tag(setting)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(String(
                        localized: "The diff viewer follows the same setting: the theme is pushed into Monaco over the bridge."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "MENU BAR"))
                    Toggle(String(localized: "Show in menu bar"), isOn: menuBarBinding)
                    Text(String(
                        localized: "On by default. The menu-bar item shows how many pull requests are waiting for your review and opens a short list of them; clicking one opens it in the main window. Switching this off removes the item — nothing else changes, and no sync of its own runs either way."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(String(localized: "DIFF VIEWER"))
                    HStack(spacing: 12) {
                        Text(String(localized: "Font size"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Slider(value: fontBinding, in: 10...18, step: 1)
                        Text("\(Int(environment.settings.diffFontSize)) pt")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                    Toggle(String(localized: "Wrap long lines"), isOn: wrapBinding)
                    Toggle(String(localized: "Show diffs inline instead of side by side"), isOn: inlineBinding)
                }
            }
        }
    }

    private var appearanceBinding: Binding<AppearanceSetting> {
        Binding(
            get: { environment.settings.appearance },
            set: {
                environment.settings.appearance = $0
                environment.applyAppearance()
            }
        )
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.showsMenuBarExtra },
            // Nothing to apply: `MenuBarExtra(isInserted:)` in `ShepherdApp` reads this setting,
            // so the item appears and disappears with the toggle.
            set: { environment.settings.showsMenuBarExtra = $0 }
        )
    }

    private var fontBinding: Binding<Double> {
        Binding(
            get: { environment.settings.diffFontSize },
            set: { environment.settings.diffFontSize = $0 }
        )
    }

    private var wrapBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.diffWrapsLines },
            set: { environment.settings.diffWrapsLines = $0 }
        )
    }

    private var inlineBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.diffUsesInlineMode },
            set: { environment.settings.diffUsesInlineMode = $0 }
        )
    }
}

// MARK: - Shared chrome

/// The scrolling container every settings tab uses.
struct SettingsPage<Content: View>: View {
    /// The tab's content.
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }
}

/// A labelled text field used by the intelligence tab.
struct LabeledField: View {
    /// The field's label.
    let label: String
    /// The placeholder text.
    let placeholder: String
    /// The bound value.
    let text: Binding<String>

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 74, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
