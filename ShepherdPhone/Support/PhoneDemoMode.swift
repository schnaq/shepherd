import Foundation
import GitHubKit
import ShepherdCore
import ShepherdPersistence

#if DEBUG
/// The phone's Debug-only demo mode: the app on the Mac demo's sample data (``DemoSeed``), with no
/// account and no network — the one practical way to look at a busy inbox on a simulator.
///
/// Switched on by `-ShepherdDemo YES` on the command line or `SHEPHERD_DEMO=1` in the
/// environment, read the way the Mac's `Shepherd/Debug/DemoMode.swift` reads them; that file
/// builds the Mac's `AppEnvironment` and cannot be shared, so this is its phone counterpart. Like
/// the Mac's, it leaves the real installation alone:
///
/// - **Application Support** moves to `$TMPDIR/ShepherdDemo`, wiped and reseeded on every launch.
///   ``directory`` is what `AppConfig.applicationSupportDirectory` asks; answering `nil` here
///   would seed the phone's real database.
/// - **UserDefaults** live in their own suite, emptied on every launch.
/// - **The Keychain** is an in-memory dictionary (``DemoKeychain``).
/// - **The network** refuses every request (``DemoTransport``) and the sweep loop never starts.
enum DemoMode {
    /// Whether this process was launched in demo mode. Read once: the answer cannot change.
    ///
    /// The command line itself, never `UserDefaults`, for the Mac's reason: a stray persistent
    /// `ShepherdDemo` default would turn every Debug launch into a demo.
    static let isActive: Bool = {
        let environment = ProcessInfo.processInfo.environment["SHEPHERD_DEMO"]?.lowercased()
        if let environment, ["1", "yes", "true"].contains(environment) { return true }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ShepherdDemo"), arguments.indices.contains(index + 1) else {
            return false
        }
        return ["1", "yes", "true"].contains(arguments[index + 1].lowercased())
    }()

    /// The scratch directory that stands in for Application Support, or `nil` outside demo mode.
    static var directory: URL? { isActive ? scratchDirectory : nil }

    /// `$TMPDIR/ShepherdDemo`.
    static let scratchDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShepherdDemo", isDirectory: true)

    /// The defaults suite the demo's settings live in.
    static let defaultsSuiteName = "com.schnaq.shepherd.ios.demo"

    /// Builds the container the demo runs on: fresh scratch state, seeded settings, an in-memory
    /// Keychain that already holds a token, and a transport that refuses every request.
    @MainActor
    static func makeEnvironment() -> PhoneEnvironment {
        let files = FileManager.default
        try? files.removeItem(at: scratchDirectory)
        try? files.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

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
        // Stored before the environment exists, so `bootstrap()` finds a token and goes straight
        // to the inbox. The value is not a token and is never sent.
        if let token = try? JSONEncoder().encode(TokenSet(accessToken: "demo-token")) {
            try? keychain.writeData(token, service: AppConfig.githubKeychainService, account: DemoSeed.viewerLogin)
        }

        return PhoneEnvironment(
            settings: settings,
            tokenStore: KeychainTokenStore(storage: keychain),
            gitHubTransport: DemoTransport(),
            runsSyncLoop: false
        )
    }

    /// Whether the database has been seeded in this process.
    @MainActor private static var hasSeeded = false

    /// Seeds the scratch database before `bootstrap()` opens the session on it. Does nothing
    /// outside demo mode, and nothing the second time.
    /// - Parameter environment: The container ``makeEnvironment()`` built.
    @MainActor
    static func prepare(_ environment: PhoneEnvironment) async {
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
    }
}
#endif
