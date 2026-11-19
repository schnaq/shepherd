import AppKit
import Foundation

/// Needs AppKit, so it lives here rather than beside ``TerminalApp``, which the iPhone app
/// compiles through ``AppSettings``.
extension TerminalApp {
    /// Where the app is installed, or `nil` when this Mac does not have it.
    @MainActor
    var applicationURL: URL? {
        EditorOpener.application(bundleIdentifier: bundleIdentifier)
    }
}

/// Writes and opens the launcher script of a handed-off delegation (ADR 0011's 2026-11-19
/// amendment).
///
/// An interactive session needs a terminal, and the only portable way to put a command in one is
/// a script the terminal runs. That reintroduces a shell, which ADR 0030's invariant has kept out
/// of every delegation so far — so the script is built to keep the invariant anyway:
/// - **Only Shepherd's own words are in the script**: the worktree path, the located CLI, the
///   flags Shepherd chose and the session name, each single-quoted by ``ShellWords/quote(_:)``.
/// - **The task is not.** It is written to a file of its own, and the script reads it back at
///   run time as `"$(cat '<file>')"` — one double-quoted command substitution, which zsh expands
///   to exactly one argv element and never re-parses. An issue body containing `'; rm -rf ~` is
///   text in that file and nothing else.
/// - Both files live under Application Support, beside the worktrees rather than in one, so
///   neither can be committed by the session they start.
enum SessionLauncher {
    /// The folder the scripts and prompt files are written to: a sibling of the managed
    /// worktrees directory, `…/Shepherd/Launchers`.
    /// - Parameter worktreesRoot: The managed worktrees directory.
    static func directory(worktreesRoot: URL) -> URL {
        worktreesRoot.deletingLastPathComponent()
            .appendingPathComponent("Launchers", isDirectory: true)
    }

    /// The launcher script.
    /// - Parameters:
    ///   - directory: Where the session starts: the worktree, or the clone for a cloud session.
    ///   - executable: The located CLI.
    ///   - arguments: The flags, all of them Shepherd's (``AgentCLIConfiguration/sessionArguments(for:permissionMode:name:)``).
    ///   - promptFile: The file the task is read from at run time.
    /// - Returns: The script's text.
    static func script(
        directory: URL,
        executable: URL,
        arguments: [String],
        promptFile: URL
    ) -> String {
        let command = ([executable.path] + arguments).map(ShellWords.quote).joined(separator: " ")
        return """
            #!/bin/zsh
            # Written by Shepherd for one delegation. The task is in the prompt file, not here.
            cd \(ShellWords.quote(directory.path)) || exit 1
            exec \(command) "$(cat \(ShellWords.quote(promptFile.path)))"

            """
    }

    /// The line *Copy command* puts on the pasteboard: the script, quoted, to paste into any
    /// shell.
    /// - Parameter script: The written script.
    static func copyCommand(script: URL) -> String {
        ShellWords.quote(script.path)
    }

    /// Writes the prompt file and the script.
    ///
    /// Readable by the user only — the prompt holds third-party text, and the script is for one
    /// person to run. Overwritten on each hand-off of the same target, so a target leaves one pair
    /// behind rather than one per press.
    /// - Parameters:
    ///   - name: A file name stem, Shepherd's own (never task text).
    ///   - folder: ``directory(worktreesRoot:)``.
    ///   - prompt: The full prompt.
    ///   - directory: Where the session starts.
    ///   - executable: The located CLI.
    ///   - arguments: The flags.
    /// - Returns: The script's URL.
    static func write(
        name: String,
        in folder: URL,
        prompt: String,
        directory: URL,
        executable: URL,
        arguments: [String]
    ) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let promptFile = folder.appendingPathComponent("\(name).prompt.txt")
        let scriptFile = folder.appendingPathComponent("\(name).command")
        try Data(prompt.utf8).write(to: promptFile, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptFile.path)
        let text = script(
            directory: directory,
            executable: executable,
            arguments: arguments,
            promptFile: promptFile
        )
        try Data(text.utf8).write(to: scriptFile, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptFile.path)
        return scriptFile
    }

    /// Opens a written script in a terminal app.
    ///
    /// Terminal and iTerm run a `.command` file they are asked to open. Ghostty does not: it is
    /// started with `-e <script>` instead, through `/usr/bin/open` so a running Ghostty gets a new
    /// window rather than nothing — and it may ask the user to confirm the command first.
    ///
    /// Waits for the terminal to take the script, so a refusal from Launch Services is thrown
    /// rather than lost.
    /// - Parameters:
    ///   - script: The written script.
    ///   - app: The terminal app.
    @MainActor
    static func open(_ script: URL, in app: TerminalApp) async throws {
        guard let application = app.applicationURL else {
            throw LaunchFailure.notInstalled(app.title)
        }
        switch app {
        case .terminal, .iTerm:
            _ = try await NSWorkspace.shared.open(
                [script],
                withApplicationAt: application,
                configuration: NSWorkspace.OpenConfiguration()
            )
        case .ghostty:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", application.path, "--args", "-e", script.path]
            try process.run()
        }
    }

    /// Why a script could not be opened.
    enum LaunchFailure: LocalizedError, Equatable {
        /// The chosen terminal app is not on this Mac.
        case notInstalled(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let name):
                return String(localized: "\(name) is not installed on this Mac. Choose another terminal in Settings → Delegation, or copy the command.")
            }
        }
    }
}
