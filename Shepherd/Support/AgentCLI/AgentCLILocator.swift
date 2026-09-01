import Foundation

/// Finds the locally installed agent CLI.
///
/// Shepherd runs the user's own installation and inherits whatever authentication it has
/// (ADR 0011). Finding the binary is therefore the *entire* setup step — there is no key to
/// enter, no account to connect, nothing to store.
enum AgentCLILocator {
    /// The executable name Claude Code installs.
    static let claudeExecutableName = "claude"

    /// The places `claude` normally lands, in the order they are tried.
    static let wellKnownPaths = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/opt/node/bin/claude",
    ]

    /// Where to send a user who has not installed the CLI yet.
    static let documentationURL = URL(string: "https://docs.claude.com/en/docs/claude-code/overview")

    /// The install hint shown in the empty state.
    static var installHint: String {
        String(localized: "Install it with `npm install -g @anthropic-ai/claude-code`, then point Shepherd at the binary.")
    }

    /// Looks for the executable without spawning anything.
    ///
    /// Order: the configured path, the well-known install locations, then every directory in
    /// the process's `PATH`. A GUI app inherits a minimal `PATH` from `launchd`, so the
    /// well-known list is what usually finds it.
    /// - Parameters:
    ///   - configuration: The stored configuration.
    ///   - fileManager: Injectable for tests.
    ///   - environment: The environment to read `PATH` from.
    /// - Returns: The executable, or `nil` when nothing was found.
    static func locate(
        configuration: AgentCLIConfiguration,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        // A custom template names its own binary in its first word; the configured path and the
        // `claude` defaults do not apply to it.
        if case .custom(let template) = configuration.kind {
            guard let first = (try? ShellWords.split(template))?.first else { return nil }
            return executable(at: first, fileManager: fileManager)
        }

        let configured = configuration.executablePath.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty {
            return executable(at: configured, fileManager: fileManager)
        }
        for candidate in wellKnownPaths {
            if let url = executable(at: candidate, fileManager: fileManager) { return url }
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory) + "/" + claudeExecutableName
            if let url = executable(at: candidate, fileManager: fileManager) { return url }
        }
        return nil
    }

    /// Looks for the executable, falling back to `env which` when the static search fails.
    ///
    /// This is what the "Detect" button in Settings runs: it is allowed to spawn a process,
    /// which the synchronous path deliberately is not.
    /// - Parameters:
    ///   - configuration: The stored configuration.
    ///   - runner: The subprocess runner.
    /// - Returns: The executable, or `nil`.
    static func detect(
        configuration: AgentCLIConfiguration,
        runner: any ProcessRunning = SystemProcessRunner.shared
    ) async -> URL? {
        if let found = locate(configuration: configuration) { return found }
        guard case .claudeCode = configuration.kind else { return nil }
        let result = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["which", claudeExecutableName],
            currentDirectory: nil
        )
        guard let result, result.isSuccess else { return nil }
        let path = result.trimmedOutput.split(separator: "\n").first.map(String.init) ?? ""
        return executable(at: path)
    }

    /// Resolves one candidate path if it exists and is executable.
    /// - Parameters:
    ///   - path: A path, possibly starting with `~`.
    ///   - fileManager: Injectable for tests.
    /// - Returns: The URL, or `nil`.
    static func executable(
        at path: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard fileManager.isExecutableFile(atPath: expanded) else { return nil }
        return URL(fileURLWithPath: expanded)
    }
}
