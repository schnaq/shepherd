import CoreSpotlight
import ShepherdCore
import SwiftUI

/// The identifiers of the app's scenes.
enum ShepherdScene {
    /// The one window group.
    ///
    /// It has an id only so a surface *outside* the window can get it back: the menu-bar quick
    /// inbox is its own scene, and a user who closed the window still expects "Open Shepherd" to
    /// open Shepherd (`openWindow(id:)`).
    static let mainWindow = "shepherd.main"
}

/// Shepherd's entry point.
///
/// One window group holds the whole app — onboarding, inbox and review screen are phases of
/// the same window — plus the standard `Settings` scene and the menu-bar quick inbox.
@main
struct ShepherdApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup(id: ShepherdScene.mainWindow) {
            RootView()
                .environment(environment)
                // 720, not 700: the 2026-09-08 live test found the toolbar collapsing under the
                // title bar below roughly 700 pt of height, so the floor sits just above it.
                .frame(minWidth: 1_040, minHeight: 720)
                .preferredColorScheme(environment.settings.appearance.colorScheme)
                .task {
                    await environment.bootstrap()
                }
                .onChange(of: environment.settings.appearance) { _, _ in
                    environment.applyAppearance()
                }
                // Same shape as the appearance line above, and for the same reason: the flag can
                // change from the Settings toggle *or* from an applied settings-sync document, and
                // both have to reach the MetricKit subscriber (ADR 0017).
                .onChange(of: environment.settings.diagnosticsEnabled) { _, _ in
                    environment.applyDiagnosticsSetting()
                }
                // And once more for usage telemetry (ADR 0036): the picker in Settings and an
                // applied settings document both land here, so there is one route from "the level
                // changed" to "the mechanism exists or does not".
                .onChange(of: environment.settings.telemetryLevel) { _, _ in
                    environment.applyTelemetryLevel()
                }
                // And once more for the acknowledgement, which is a *second* way the mechanism
                // comes into existence. A settings document from another Mac can carry an already
                // answered notice without changing the level — both Macs on `anonymous`, this one
                // simply never asked — and then the route above never fires: the sheet disappears
                // because the flag is now true, and telemetry stays `nil` until the next launch.
                // The heartbeat follows, because that launch would otherwise go uncounted.
                .onChange(of: environment.settings.telemetryNoticeAcknowledged) { _, _ in
                    environment.applyTelemetryLevel()
                    environment.recordLaunchHeartbeat()
                }
                // And once more for the search index (ADR 0019): the toggle in Settings and an
                // applied settings document both land here, so there is one route from "the flag
                // changed" to "the index exists or does not".
                .onChange(of: environment.settings.semanticSearchEnabled) { _, _ in
                    environment.applySemanticSearchSetting()
                }
                // And once more for structured triage (ADR 0023): the toggle in Settings and an
                // applied settings document both land here, so there is one route from "the flag
                // changed" to "the verdicts exist or do not".
                .onChange(of: environment.settings.structuredTriageEnabled) { _, _ in
                    environment.applyStructuredTriageSetting()
                }
                // `shepherd://` links: the terminal, Raycast, an n8n Execute Command node
                // (ADR 0013). A link that arrives before the session exists is queued and
                // replayed after sign-in.
                .onOpenURL { url in
                    environment.open(deepLinkURL: url)
                }
                // …and the reason the line above lands in *this* window rather than a new one.
                // Without it SwiftUI has no open scene that says it handles the event, so it
                // creates a scene per URL: sixteen `shepherd://` links used to leave sixteen
                // windows behind. `"*"` is the documented wildcard — any incoming event.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // And once more for the Spotlight export (ADR 0021), so the toggle in Settings and
                // an applied settings document both reach the exporter through one route.
                .onChange(of: environment.settings.spotlightExportEnabled) { _, _ in
                    environment.applySpotlightSetting()
                }
                // And once more for the watched repositories (ADR 0005's 2026-09-16 amendment).
                // It is device-local, like the ignore list, and not in `SyncedSettingsDocument`,
                // and it goes through an `onChange` rather than through its writers, so that no
                // writer can forget to tell the sweep. There are three now — the Settings card,
                // the inbox's watch dialog and "Add a local repository…" — and none of them
                // needed any wiring of its own to get the same immediate sweep.
                .onChange(of: environment.settings.watchedRepositories) { _, _ in
                    environment.applyWatchedRepositoriesSetting()
                }
                // A clicked Spotlight result, beside `onOpenURL` because it is the same kind of
                // arrival — something outside the app naming a pull request — and it ends in the
                // same `DeepLink.pullRequest` routing (ADR 0021).
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    environment.openSpotlightResult(activity)
                }
        }
        .defaultSize(width: 1_440, height: 900)
        .commands {
            ShepherdCommands(environment: environment)
        }

        // The app's only settings presentation: ⌘, opens it, and so does every in-app surface,
        // through ``AppEnvironment/showSettings(_:)``. It used to have a rival — a sheet on the
        // inbox screen — which had no close button and blocked the window's.
        Settings {
            SettingsView()
                .environment(environment)
                .preferredColorScheme(environment.settings.appearance.colorScheme)
        }

        // The quick inbox (`Features/MenuBar`). `isInserted` is bound straight to the Settings
        // toggle, so switching it off *removes* the item from the menu bar instead of leaving a
        // hidden one behind — and switching it back on needs no relaunch.
        //
        // `.window` rather than the default menu style because the content is a list of rows with
        // chips and a footer, not a list of commands.
        MenuBarExtra(isInserted: menuBarBinding) {
            MenuBarInboxView()
                .environment(environment)
                .preferredColorScheme(environment.settings.appearance.colorScheme)
        } label: {
            // The session is passed rather than read from the environment: the label is not
            // inside the content's view hierarchy, and the badge has to keep tracking the
            // session's rows while every window is closed.
            MenuBarInboxLabel(session: environment.session)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.showsMenuBarExtra },
            set: { environment.settings.showsMenuBarExtra = $0 }
        )
    }
}

/// The menu-bar commands. Every one of them is also reachable from ⌘K (`docs/ARCHITECTURE.md`).
struct ShepherdCommands: Commands {
    /// The shared container.
    let environment: AppEnvironment

    var body: some Commands {
        // The File menu, entire. This group is the menu's anchor, so the *empty* replacement that
        // stood here did more than drop "New Window" — which is the point of replacing it, the app
        // has one window and a second one has always been a bug — it took the menu away, and Close
        // ⌘W with it. The 2026-09-09 live test found what that costs: the Settings window could not
        // be closed from the keyboard at all, because the app's menus carried no ⌘W anywhere. So
        // the group keeps exactly one item, the one a Mac user looks for in this menu.
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Close Window")) {
                environment.closeKeyWindow()
            }
            .keyboardShortcut("w")
        }

        // Directly under "About Shepherd" in the app menu, where every Mac user looks for it
        // (ADR 0010). A build without an update feed and signing key shows the item disabled
        // rather than hiding it: a missing menu item reads as a bug, a greyed-out one sends the
        // user to Settings → Account, which says in one line why updates are off.
        CommandGroup(after: .appInfo) {
            Divider()
            Button(String(localized: "Check for Updates…")) {
                environment.updates.checkForUpdates()
            }
            .disabled(!environment.updates.isEnabled)
        }

        CommandMenu(String(localized: "Review")) {
            // ⇧⌘⏎ rather than a bare ⏎-with-modifiers: the inbox's plain ⏎ opens the row under
            // the cursor, and the main menu resolves its key equivalents before the key ever
            // reaches the list, so the two cannot be confused. `r f` does the same thing from
            // the keyboard-only path.
            Button(String(localized: "Start Review Session")) {
                environment.request(.startReviewSession)
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(environment.session == nil)

            Divider()

            Button(String(localized: "Approve")) {
                environment.request(.approve)
            }
            .disabled(environment.session == nil)

            Button(String(localized: "Request Changes")) {
                environment.request(.requestChanges)
            }
            .disabled(environment.session == nil)

            Button(String(localized: "Comment")) {
                environment.request(.comment)
            }
            .disabled(environment.session == nil)

            Divider()

            Button(String(localized: "Merge…")) {
                environment.request(.merge)
            }
            .disabled(environment.session == nil)

            Button(String(localized: "Delegate to Agent…")) {
                environment.request(.delegate)
            }
            .disabled(environment.session == nil)

            Divider()

            // Bulk triage acts on the inbox's selection, so it is disabled while the review
            // screen is up rather than pretending to have one (ADR 0015).
            Button(String(localized: "Select All Green Agent Pull Requests")) {
                environment.request(.markGreenAgentPullRequests)
            }
            .disabled(!isTriageAvailable)

            ForEach(BulkTriageAction.allCases, id: \.self) { action in
                Button(action.commandTitle) {
                    environment.request(.bulkTriage(action))
                }
                .disabled(!isTriageAvailable)
            }
        }

        CommandGroup(after: .toolbar) {
            Button(String(localized: "Command Palette")) {
                environment.isCommandPaletteVisible = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(environment.session == nil)

            Button(String(localized: "Watch Repository…")) {
                environment.isAddingWatchedRepository = true
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(environment.session == nil)

            Button(String(localized: "Add Local Repository…")) {
                environment.addLocalRepository()
            }
            .disabled(environment.session == nil)

            Button(String(localized: "Sync Now")) {
                Task { await environment.syncNow() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(environment.session == nil)

            Divider()

            Picker(String(localized: "Appearance"), selection: appearanceBinding) {
                ForEach(AppearanceSetting.allCases) { setting in
                    Text(setting.title).tag(setting)
                }
            }

            Divider()

            Picker(String(localized: "Group Inbox By"), selection: groupBinding) {
                Text(String(localized: "Agent")).tag(InboxFacet.provenance)
                Text(String(localized: "Repository")).tag(InboxFacet.repository)
                Text(String(localized: "Review state")).tag(InboxFacet.reviewState)
            }
        }
    }

    /// Whether the inbox — the only screen that owns a bulk selection — is showing.
    private var isTriageAvailable: Bool {
        environment.session != nil && environment.route == .inbox
    }

    private var appearanceBinding: Binding<AppearanceSetting> {
        Binding(
            get: { environment.settings.appearance },
            set: { environment.settings.appearance = $0 }
        )
    }

    private var groupBinding: Binding<InboxFacet> {
        Binding(
            get: { environment.settings.groupBy },
            set: { environment.settings.groupBy = $0 }
        )
    }
}
