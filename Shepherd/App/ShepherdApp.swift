import ShepherdCore
import SwiftUI

/// Shepherd's entry point.
///
/// One window group holds the whole app — onboarding, inbox and review screen are phases of
/// the same window — plus the standard `Settings` scene.
@main
struct ShepherdApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .frame(minWidth: 1_040, minHeight: 640)
                .preferredColorScheme(environment.settings.appearance.colorScheme)
                .task {
                    await environment.bootstrap()
                }
                .onChange(of: environment.settings.appearance) { _, _ in
                    environment.applyAppearance()
                }
                // `shepherd://` links: the terminal, Raycast, an n8n Execute Command node
                // (ADR 0013). A link that arrives before the session exists is queued and
                // replayed after sign-in.
                .onOpenURL { url in
                    environment.open(deepLinkURL: url)
                }
        }
        .defaultSize(width: 1_440, height: 900)
        .commands {
            ShepherdCommands(environment: environment)
        }

        Settings {
            SettingsView()
                .environment(environment)
                .preferredColorScheme(environment.settings.appearance.colorScheme)
        }
    }
}

/// The menu-bar commands. Every one of them is also reachable from ⌘K (`docs/ARCHITECTURE.md`).
struct ShepherdCommands: Commands {
    /// The shared container.
    let environment: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

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
