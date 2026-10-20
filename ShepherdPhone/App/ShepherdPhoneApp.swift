import SwiftUI

/// Shepherd for iPhone's entry point (ADR 0044).
///
/// One window group whose content is ``PhoneRootView``; the phases — launching, signed out,
/// signed in — live in ``PhoneEnvironment`` exactly as they do in the Mac's `AppEnvironment`.
@main
struct ShepherdPhoneApp: App {
    @State private var environment = ShepherdPhoneApp.makeEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    /// The container: the real one, or — in a Debug build launched with `-ShepherdDemo YES` — the
    /// demo mode's, which never touches the phone's real database, defaults or Keychain.
    private static func makeEnvironment() -> PhoneEnvironment {
        #if DEBUG
        if DemoMode.isActive { return DemoMode.makeEnvironment() }
        #endif
        return PhoneEnvironment()
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environment(environment)
                .preferredColorScheme(environment.settings.appearance.colorScheme)
                .task {
                    #if DEBUG
                    // Seeds the scratch database before the session opens it; a no-op unless the
                    // demo mode is on.
                    await DemoMode.prepare(environment)
                    #endif
                    await environment.bootstrap()
                }
                // Sweep while open, drain on the way out (ADR 0044); the policy is the
                // environment's, this only reports the moment.
                .onChange(of: scenePhase) { _, phase in
                    environment.scenePhaseChanged(to: phase)
                }
                // The Mac's `ShepherdApp` watches the same key: adding or removing a repository in
                // settings reaches the engine at once, with a sweep.
                .onChange(of: environment.settings.watchedRepositories) { _, _ in
                    environment.applyWatchedRepositoriesSetting()
                }
        }
    }
}
