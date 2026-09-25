#if DEBUG
import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence

/// A Debug-only way to launch Shepherd on realistic sample data, for screenshots and for looking
/// at a busy inbox without owning one.
///
/// Switched on by `-ShepherdDemo YES` on the command line or `SHEPHERD_DEMO=1` in the
/// environment, and by nothing else: the whole `Shepherd/Debug` folder is inside `#if DEBUG`, so a
/// Release build has neither the switch nor anything it would switch on.
///
/// The one hard requirement is that a demo launch leaves the developer's real installation alone.
/// A Debug build carries the installed app's bundle id, so every piece of state that is keyed by
/// it is redirected here rather than trusted to be absent:
///
/// - **Application Support** — database, worktrees, diagnostics, telemetry queue — moves to
///   `$TMPDIR/ShepherdDemo`, wiped and reseeded on every launch (``AppConfig/applicationSupportDirectory``).
/// - **UserDefaults** — the settings, the automation ledgers, the recurring-finding dismissals —
///   live in the `com.schnaq.shepherd.demo` suite, emptied on every launch.
/// - **The Keychain** is never touched: the token and every secret are an in-memory dictionary
///   (``DemoKeychain``).
/// - **The network** is unreachable: the GitHub client's transport refuses every request
///   (``DemoTransport``), the sweep loop is never started, Sparkle gets an empty configuration,
///   telemetry and the intelligence tiers are off, and the Spotlight export writes to nothing
///   (``DemoSpotlightIndex``) — the system index is shared by bundle id too.
///
/// What it cannot redirect is AppKit's own bookkeeping in the standard defaults domain (window
/// frames) and the saved-state folder; `Scripts/demo-screenshots.sh` passes
/// `-ApplePersistenceIgnoreState YES` for the second, and the first is a window size.
enum DemoMode {
    /// Whether this process was launched in demo mode. Read once: the answer cannot change.
    ///
    /// The command line itself, never `UserDefaults` — whose `-ShepherdDemo YES` would also be
    /// satisfied by a stray `defaults write` in the persistent domain, turning a developer's
    /// everyday Debug build into a demo.
    static let isActive: Bool = {
        let environment = ProcessInfo.processInfo.environment["SHEPHERD_DEMO"]?.lowercased()
        if let environment, ["1", "yes", "true"].contains(environment) { return true }
        return argument("-ShepherdDemo").map { ["1", "yes", "true"].contains($0.lowercased()) } ?? false
    }()

    /// The value after `name` on the command line, `-Name value` style.
    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    /// The scratch directory that stands in for Application Support, or `nil` outside demo mode.
    static var directory: URL? { isActive ? scratchDirectory : nil }

    /// `$TMPDIR/ShepherdDemo`.
    static let scratchDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShepherdDemo", isDirectory: true)

    /// The defaults suite the demo's settings live in.
    static let defaultsSuiteName = "com.schnaq.shepherd.demo"

    /// A `shepherd://` link to open once the seeded session is up (`-ShepherdDemoOpen <url>`).
    ///
    /// A launch argument rather than `open shepherd://…`, because the installed app and the demo
    /// share a bundle id and LaunchServices picks which of the two running processes receives an
    /// URL — the screenshot script needs it to reach *this* one.
    static var linkToOpen: URL? {
        argument("-ShepherdDemoOpen").flatMap(URL.init(string:))
    }

    /// Builds the container the demo runs on: fresh scratch state, seeded settings, and a fake
    /// for every seam that would otherwise reach the real installation or the network.
    @MainActor
    static func makeEnvironment() -> AppEnvironment {
        resetScratchDirectory()
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            // Falling back to `.standard` would write the demo into the real settings.
            fatalError("The demo defaults suite \(defaultsSuiteName) could not be opened.")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let settings = AppSettings(defaults: defaults)
        DemoSeed.configure(settings, checkout: scratchDirectory.appendingPathComponent(
            "Checkouts/shepherd",
            isDirectory: true
        ))

        let keychain = DemoKeychain()
        // Stored before the environment exists, so the launch check in `bootstrap()` finds a
        // token and goes straight to the inbox. The value is not a token and is never sent.
        if let token = try? JSONEncoder().encode(TokenSet(accessToken: "demo-token")) {
            try? keychain.writeData(token, service: AppConfig.githubKeychainService, account: DemoSeed.viewerLogin)
        }

        return AppEnvironment(
            settings: settings,
            tokenStore: KeychainTokenStore(storage: keychain),
            secretStore: KeychainSecretStore(storage: keychain),
            defaults: defaults,
            // No feed, no key: the updater is created inert and never asks the appcast.
            updates: UpdateController(configuration: UpdateConfiguration(info: [:])),
            spotlightIndex: DemoSpotlightIndex(),
            gitHubTransport: DemoTransport(),
            runsSyncLoop: false
        )
    }

    /// Whether the database has been seeded in this process.
    @MainActor private static var hasSeeded = false

    /// Seeds the scratch database and queues the requested link, before `bootstrap()` opens the
    /// session on it. Does nothing outside demo mode, and nothing the second time.
    /// - Parameter environment: The container ``makeEnvironment()`` built.
    @MainActor
    static func prepare(_ environment: AppEnvironment) async {
        guard isActive, !hasSeeded else { return }
        hasSeeded = true
        do {
            // Its own connection, released at the end of the scope; the session opens the file
            // again a moment later.
            let database = try DatabaseManager(url: AppConfig.databaseURL)
            try await DemoSeed.write(into: database)
        } catch {
            environment.toasts.failure(error, context: "Demo mode could not seed its database")
        }
        // Straight into the store: Start would run a pass, and the demo must write nothing.
        environment.mergeSeriesStore.save(DemoSeed.mergeSeries(now: Date()))
        if let link = linkToOpen {
            // The phase is still `.launching`, so this parks the link in `pendingDeepLink` and the
            // session start replays it — the same path a link clicked during launch takes.
            environment.open(deepLinkURL: link)
        }
    }

    /// Makes the title bar read like a session that has been syncing for a while.
    /// - Parameter environment: The container, after `bootstrap()`.
    @MainActor
    static func didBootstrap(_ environment: AppEnvironment) {
        guard isActive else { return }
        environment.session?.lastSyncedAt = Date().addingTimeInterval(-40)
    }

    /// Empties the scratch directory, so every launch starts from the same seed.
    private static func resetScratchDirectory() {
        let files = FileManager.default
        try? files.removeItem(at: scratchDirectory)
        try? files.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
    }
}
#endif
