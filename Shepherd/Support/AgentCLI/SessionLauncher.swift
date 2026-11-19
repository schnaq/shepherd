import AppKit
import Foundation

/// How a delegation is run: headless in Shepherd, or handed to a session the user drives (ADR
/// 0011's 2026-11-19 amendment).
///
/// Four cases rather than three and a Remote Control toggle: a Remote Control session *is* an
/// interactive Terminal session, only reachable from claude.ai and the phone as well, and one
/// remembered value is simpler than a value and a flag that only means something for one of the
/// other values.
enum DelegationHandoff: String, CaseIterable, Identifiable, Sendable {
    /// `claude -p … --output-format stream-json` inside Shepherd, with the transcript in the
    /// sheet — the only path an automatic rule, a session send or a custom CLI ever takes.
    case background
    /// An interactive Claude Code session in a terminal window, in the prepared worktree.
    case terminal
    /// The same session with `--remote-control`, so claude.ai/code and the Claude app reach it.
    case remoteControl
    /// `claude --cloud`: a session on claude.ai/code that works on the GitHub repository, not on
    /// this Mac — so no worktree is prepared for it.
    case cloud

    var id: String { rawValue }

    /// The label in the sheet's picker.
    var title: String {
        switch self {
        case .background: return String(localized: "In the background")
        case .terminal: return String(localized: "Interactive session")
        case .remoteControl: return String(localized: "Remote Control")
        case .cloud: return String(localized: "Claude Code on the web")
        }
    }

    /// One line under the picker: where the work happens and who drives it.
    var explanation: String {
        switch self {
        case .background:
            return String(localized: "Shepherd runs the agent headless in a worktree and shows the transcript here.")
        case .terminal:
            return String(localized: "Opens Claude Code in your terminal, in a prepared worktree. You drive the session.")
        case .remoteControl:
            return String(localized: "Like an interactive session, and also reachable from claude.ai/code and the Claude app.")
        case .cloud:
            return String(localized: "Starts a session on claude.ai/code. It works on the repository on GitHub, not on your local changes.")
        }
    }

    /// Whether the run is a session the user drives rather than one Shepherd reads.
    var isInteractive: Bool { self == .terminal || self == .remoteControl }
}

/// The terminal app an interactive delegation opens in.
///
/// Per Mac rather than synced: which terminals are installed is a fact about the machine.
enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    /// Terminal.app, which ships with every Mac.
    case terminal
    /// iTerm2.
    case iTerm
    /// Ghostty.
    case ghostty

    var id: String { rawValue }

    /// The product name, in the picker and in "Running in Terminal".
    var title: String {
        switch self {
        case .terminal: return String(localized: "Terminal")
        case .iTerm: return String(localized: "iTerm")
        case .ghostty: return String(localized: "Ghostty")
        }
    }

    /// The bundle identifier that says the app is installed, and that it is opened by.
    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iTerm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }

    /// Where the app is installed, or `nil` when this Mac does not have it.
    @MainActor
    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

/// Writes and opens the launcher script of a handed-off delegation (ADR 0011's 2026-11-19
/// amendment).
///
/// An interactive session needs a terminal, and the only portable way to put a command in one is
/// a script the terminal runs. That reintroduces a shell, which ADR 0030's invariant has kept out
/// of every delegation so far — so the script is built to keep the invariant anyway:
/// - **Only Shepherd's own words are in the script**: the worktree path, the located CLI, the
///   flags Shepherd chose and the session name, each single-quoted by ``quote(_:)``.
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

    /// Quotes one word for zsh: `'…'`, with every `'` inside written as `'\''`.
    ///
    /// Inside single quotes zsh interprets nothing at all — no `$`, no backtick, no backslash —
    /// so the only character that needs care is the closing quote itself.
    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
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
        let command = ([executable.path] + arguments).map(quote).joined(separator: " ")
        return """
            #!/bin/zsh
            # Written by Shepherd for one delegation. The task is in the prompt file, not here.
            cd \(quote(directory.path)) || exit 1
            exec \(command) "$(cat \(quote(promptFile.path)))"

            """
    }

    /// The line *Copy command* puts on the pasteboard: the script, quoted, to paste into any
    /// shell.
    /// - Parameter script: The written script.
    static func copyCommand(script: URL) -> String {
        quote(script.path)
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
    /// - Parameters:
    ///   - script: The written script.
    ///   - app: The terminal app.
    @MainActor
    static func open(_ script: URL, in app: TerminalApp) throws {
        guard let application = app.applicationURL else {
            throw LaunchFailure.notInstalled(app.title)
        }
        switch app {
        case .terminal, .iTerm:
            NSWorkspace.shared.open(
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
