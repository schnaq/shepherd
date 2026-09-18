import Foundation

/// Build-time configuration constants.
///
/// The GitHub App client ID is deliberately a plain constant (ADR 0004: a desktop app cannot
/// keep a secret, so the *public* client ID lives in the repository). Maintainers and forks
/// fill it in here; when it is empty the app hides the device flow and offers only the
/// personal-access-token path, which needs no client ID at all.
enum AppConfig {
    /// The public client ID of the Shepherd GitHub App.
    ///
    /// Leave empty in forks that have not registered their own app — the sign-in screen
    /// degrades to the personal-access-token field automatically.
    static let githubAppClientID = "Iv23liu9WQQC0cJERKGM"

    /// Whether the OAuth device flow can be offered.
    static var isDeviceFlowConfigured: Bool { !githubAppClientID.isEmpty }

    /// Keychain service for GitHub credentials.
    static let githubKeychainService = "com.schnaq.shepherd.github"

    /// Keychain service for everything else Shepherd must keep secret (AI API keys).
    static let secretsKeychainService = "com.schnaq.shepherd.secrets"

    /// Name of the SQLite file inside the application-support directory.
    static let databaseFileName = "shepherd.sqlite"

    /// `~/Library/Application Support/Shepherd`, created on demand by `DatabaseManager`.
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Shepherd", isDirectory: true)
    }

    /// Where the local database lives (ADR 0006).
    static var databaseURL: URL {
        applicationSupportDirectory.appendingPathComponent(databaseFileName, isDirectory: false)
    }

    /// `~/Library/Application Support/Shepherd/Worktrees` — every delegation worktree lives
    /// here and nowhere else (ADR 0011). `GitWorktree.remove()` refuses to delete anything
    /// outside this directory.
    static var worktreesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Worktrees", isDirectory: true)
    }

    /// `~/Library/Application Support/Shepherd/Diagnostics` — the local crash and hang reports
    /// MetricKit hands over, when the user opted in (ADR 0017).
    ///
    /// Created on demand by ``DiagnosticsStore``, never uploaded, and emptied by the "Delete all"
    /// button in Settings → Account.
    static var diagnosticsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// `~/Library/Application Support/Shepherd/Telemetry` — the queue of usage events not yet sent
    /// (ADR 0036).
    ///
    /// Beside the diagnostics folder and for the same reason: what leaves the Mac should be
    /// readable on it first. Deleted whole when telemetry is switched off.
    static var telemetryDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Telemetry", isDirectory: true)
    }

    /// PostHog's EU ingest endpoint for batched events (ADR 0036).
    static var postHogBatchURL: URL {
        URL(string: "https://eu.i.posthog.com/batch/") ?? URL(fileURLWithPath: "/")
    }

    /// `https://github.com`, used for "open on GitHub" links.
    static var webBaseURL: URL {
        URL(string: "https://github.com") ?? URL(fileURLWithPath: "/")
    }

    /// The URL a pull request lives at on github.com.
    /// - Parameters:
    ///   - owner: Repository owner.
    ///   - name: Repository name.
    ///   - number: Pull request number.
    static func pullRequestURL(owner: String, name: String, number: Int) -> URL {
        webBaseURL
            .appendingPathComponent(owner)
            .appendingPathComponent(name)
            .appendingPathComponent("pull")
            .appendingPathComponent(String(number))
    }

    /// The URL an issue lives at on github.com (ADR 0032).
    ///
    /// Beside ``pullRequestURL(owner:name:number:)`` and built the same way, on the host that is
    /// already the only one "open on GitHub" ever reaches: `github.com`, no new entry on
    /// `CONTRIBUTING.md`'s list, and nothing is requested — the URL is handed to the browser.
    /// - Parameters:
    ///   - owner: Repository owner.
    ///   - name: Repository name.
    ///   - number: Issue number.
    static func issueURL(owner: String, name: String, number: Int) -> URL {
        webBaseURL
            .appendingPathComponent(owner)
            .appendingPathComponent(name)
            .appendingPathComponent("issues")
            .appendingPathComponent(String(number))
    }
}
