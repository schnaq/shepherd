import Foundation

/// Which program "Open in editor" hands a file to (ADR 0039).
///
/// No associated value, unlike ``AgentCLIKind``: the custom command's template lives in its own
/// field of ``EditorConfiguration``, so switching to VS Code and back does not lose what the user
/// typed, and the Settings picker can bind to the kind directly without a tag type in between.
enum EditorKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Whatever macOS opens the file with on a double-click in Finder. The default, because it
    /// works on every Mac without a question — and it is the only choice that cannot name a line.
    case systemDefault
    /// Visual Studio Code, through its `vscode://file/…` URL handler.
    case visualStudioCode
    /// IntelliJ IDEA (Ultimate or Community), through its `idea://open?…` URL handler.
    case intelliJ
    /// Cursor, which is a VS Code fork and inherits the same URL shape under `cursor://`.
    case cursor
    /// A command line the user wrote, with `{file}` and `{line}` placeholders.
    case custom

    var id: String { rawValue }

    /// The name shown in the Settings picker and after "Open in".
    ///
    /// The three editors are product names and read the same in German; they go through the
    /// catalog anyway so a German row exists for every visible string (ADR 0022).
    var title: String {
        switch self {
        case .systemDefault: return String(localized: "System default")
        case .visualStudioCode: return String(localized: "Visual Studio Code")
        case .intelliJ: return String(localized: "IntelliJ IDEA")
        case .cursor: return String(localized: "Cursor")
        case .custom: return String(localized: "Custom command")
        }
    }

    /// The bundle identifiers that count as "this editor is installed", in preference order.
    ///
    /// Used twice: by Settings to say which choices this Mac can actually honour, and by the
    /// opener as the fallback when the URL scheme has no handler — an IDE installed but never
    /// launched may not have registered its scheme yet, and opening the file *with* it (without
    /// the line) is better than failing. Empty for the two kinds that are not one application.
    var bundleIdentifiers: [String] {
        switch self {
        case .systemDefault, .custom: return []
        case .visualStudioCode: return ["com.microsoft.VSCode"]
        case .intelliJ: return ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        }
    }
}

/// Where "Open in editor" sends a file (ADR 0039).
///
/// Stored in `UserDefaults` as one JSON blob, like ``AgentCLIConfiguration``, and carried by
/// settings sync: *which editor a person uses* is a preference of the person, not of the Mac. The
/// custom template can name a path that exists on only one of their Macs — the same trade
/// ``AgentCLIConfiguration/executablePath`` already makes, and for the same reason.
struct EditorConfiguration: Codable, Sendable, Equatable {
    /// Which program to use.
    var kind: EditorKind
    /// The command line for ``EditorKind/custom``. Kept when another kind is selected.
    var customCommandTemplate: String

    /// The `{file}` placeholder: the absolute path of the file, as **one** argv element.
    static let filePlaceholder = "{file}"
    /// The `{line}` placeholder: the head-side line number, `1` when none is known.
    static let linePlaceholder = "{line}"
    /// What the custom field shows before the user types anything. A full path on purpose: a
    /// bare `code` is refused (see ``EditorLauncher/customInvocation(template:file:line:)``).
    static let exampleCustomCommandTemplate = "/usr/local/bin/code --goto {file}:{line}"

    /// Creates a configuration; the default opens files the way Finder would.
    init(kind: EditorKind = .systemDefault, customCommandTemplate: String = "") {
        self.kind = kind
        self.customCommandTemplate = customCommandTemplate
    }

    private enum CodingKeys: String, CodingKey {
        case kind, customCommandTemplate
    }

    /// Decodes tolerantly: an unknown kind from a newer build — or a missing key from an older
    /// one — falls back to the default rather than costing the other field.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeIfPresent(EditorKind.self, forKey: .kind))
            .flatMap { $0 } ?? .systemDefault
        customCommandTemplate = (try? container.decodeIfPresent(
            String.self,
            forKey: .customCommandTemplate
        )).flatMap { $0 } ?? ""
    }
}

/// What to do to show one file in the chosen editor — decided here, performed elsewhere.
///
/// The split is the one ``AgentCLIConfiguration`` and `AgentCLIRunner` have: this side is pure
/// and has no AppKit in it, so the tests assert the exact URL or argv, and ``EditorOpener`` is
/// the thin `@MainActor` side that hands it to `NSWorkspace` or `Process`.
enum EditorLaunch: Equatable, Sendable {
    /// Open the file with whatever the system picks.
    case systemDefault(URL)
    /// Open a URL handled by an editor; when no application handles the scheme, open `file` with
    /// the first installed of `fallbackBundleIdentifiers` instead (and lose the line).
    case url(URL, file: URL, fallbackBundleIdentifiers: [String])
    /// Spawn a process directly — never through a shell.
    case process(AgentInvocation)
}

/// Pure URL and argv construction for "Open in editor" (ADR 0039).
enum EditorLauncher {
    /// Why a launch could not be planned.
    enum Failure: LocalizedError, Equatable {
        /// The custom command is empty.
        case emptyTemplate
        /// The custom command never says where the file goes.
        case templateMissingFilePlaceholder
        /// The custom command's first word is a bare name rather than a path.
        case bareExecutable(String)
        /// The custom command could not be split.
        case template(String)
        /// A URL could not be formed from the path.
        case unrepresentablePath

        var errorDescription: String? {
            switch self {
            case .emptyTemplate:
                return String(localized: "The editor command is empty. Set one in Settings → Delegation.")
            case .templateMissingFilePlaceholder:
                return String(localized: "The editor command must contain {file} so Shepherd knows where the file goes.")
            case .bareExecutable(let name):
                return String(localized: "Write the full path to “\(name)” in the editor command, for example /usr/local/bin/\(name). Apps started from the Dock do not see your shell’s PATH.")
            case .template(let message):
                return message
            case .unrepresentablePath:
                return String(localized: "This path cannot be passed to the editor.")
            }
        }
    }

    /// Plans how to show one file in the configured editor.
    ///
    /// A *folder* — the clone itself, when it lacks the file — goes to the three URL editors as
    /// it is (each opens a folder as a project), but never to a custom command: its template was
    /// written for `{file}:{line}`, and `…/review:1` is not a folder any editor can open. Finder
    /// is the honest fallback there.
    /// - Parameters:
    ///   - configuration: The stored editor choice.
    ///   - file: The absolute file (or folder) to open.
    ///   - line: The 1-based head-side line, when one is known.
    ///   - isDirectory: Whether `file` is a folder.
    /// - Returns: The launch to perform.
    /// - Throws: ``Failure`` when the configuration cannot produce one.
    static func launch(
        for configuration: EditorConfiguration,
        file: URL,
        line: Int?,
        isDirectory: Bool = false
    ) throws -> EditorLaunch {
        switch configuration.kind {
        case .systemDefault:
            return .systemDefault(file)
        case .custom where isDirectory:
            return .systemDefault(file)
        case .visualStudioCode, .intelliJ, .cursor:
            guard let url = url(kind: configuration.kind, file: file, line: line) else {
                throw Failure.unrepresentablePath
            }
            return .url(
                url,
                file: file,
                fallbackBundleIdentifiers: configuration.kind.bundleIdentifiers
            )
        case .custom:
            return .process(try customInvocation(
                template: configuration.customCommandTemplate,
                file: file,
                line: line
            ))
        }
    }

    /// The editor's own URL for a file and line.
    ///
    /// - VS Code and Cursor: `vscode://file/<absolute path>:<line>` — the documented shape, the
    ///   path's leading `/` directly after `file`, line and column 1-based. With no line the
    ///   suffix is left off entirely, which opens the file at the top.
    /// - IntelliJ IDEA: `idea://open?file=<absolute path>&line=<line>`, 1-based like the `idea`
    ///   command line's `--line`, which reads the same parameter.
    ///
    /// The path is percent-encoded rather than pasted, so a space or a `#` in a folder name
    /// cannot end the path early; a query value additionally encodes `&`, `=` and `+`, which
    /// `URLComponents` would leave alone and IntelliJ would read as separators.
    /// - Parameters:
    ///   - kind: One of the three URL-scheme editors.
    ///   - file: The absolute path.
    ///   - line: The line, when known.
    /// - Returns: The URL, or `nil` for a kind that has none.
    static func url(kind: EditorKind, file: URL, line: Int?) -> URL? {
        let path = file.standardizedFileURL.path
        let usableLine = line.flatMap { $0 > 0 ? $0 : nil }
        switch kind {
        case .visualStudioCode, .cursor:
            let scheme = kind == .cursor ? "cursor" : "vscode"
            guard let encoded = path.addingPercentEncoding(withAllowedCharacters: pathAllowed)
            else { return nil }
            let suffix = usableLine.map { ":\($0)" } ?? ""
            return URL(string: "\(scheme)://file\(encoded)\(suffix)")
        case .intelliJ:
            guard let encoded = path.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)
            else { return nil }
            let suffix = usableLine.map { "&line=\($0)" } ?? ""
            return URL(string: "idea://open?file=\(encoded)\(suffix)")
        case .systemDefault, .custom:
            return nil
        }
    }

    /// Builds the argv for a custom editor command.
    ///
    /// The mechanism of ``AgentCLIConfiguration/sessionInvocation(message:session:worktree:executable:)``,
    /// deliberately: the template is split by ``ShellWords`` **first** and the placeholders go into
    /// the already-split words **after**, so a path with spaces, quotes or a `;` in it stays one
    /// argv element and no shell is involved anywhere. `{line}` becomes `1` when no line is known
    /// rather than the empty string, because `code --goto path:` and `subl path:` read an empty
    /// line differently and "the top of the file" is what every editor agrees `1` means.
    ///
    /// The first word must be a path. A bare `code` is refused rather than looked up: an app
    /// started from the Dock inherits launchd's minimal `PATH`, so the lookup would find a
    /// different `code` than the user's terminal does — or none — and guessing at a program name
    /// would run something the user did not name. That is ADR 0030's rule for the session
    /// command, applied here without its one exception (there is no located editor CLI).
    /// - Parameters:
    ///   - template: The command line.
    ///   - file: The absolute path, substituted for `{file}`.
    ///   - line: The line, substituted for `{line}`.
    /// - Returns: The invocation to spawn.
    /// - Throws: ``Failure`` when the template cannot produce a command.
    static func customInvocation(template: String, file: URL, line: Int?) throws -> AgentInvocation {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyTemplate }
        guard trimmed.contains(EditorConfiguration.filePlaceholder) else {
            throw Failure.templateMissingFilePlaceholder
        }
        let words: [String]
        do {
            words = try ShellWords.split(trimmed)
        } catch {
            throw Failure.template(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
        guard let binary = words.first, !binary.isEmpty else { throw Failure.emptyTemplate }
        guard binary.contains("/") || binary.hasPrefix("~") else {
            throw Failure.bareExecutable(binary)
        }
        let lineText = String(line.flatMap { $0 > 0 ? $0 : nil } ?? 1)
        let path = file.standardizedFileURL.path
        let arguments = words.dropFirst().map { word in
            word
                .replacingOccurrences(of: EditorConfiguration.linePlaceholder, with: lineText)
                // Last, so a path that happens to contain the literal text `{line}` is not
                // rewritten after it has been substituted.
                .replacingOccurrences(of: EditorConfiguration.filePlaceholder, with: path)
        }
        return AgentInvocation(
            executable: URL(fileURLWithPath: (binary as NSString).expandingTildeInPath),
            arguments: Array(arguments)
        )
    }

    /// `.urlPathAllowed` minus the characters that would end or split a path inside a URL
    /// string: `;` (VS Code's parser treats it as a parameter), and `:` beyond the one Shepherd
    /// appends, which it would otherwise read as a line number.
    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: ";:")
        return set
    }()

    /// Unreserved characters and `/`: everything else in a query value is escaped.
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/")
        return set
    }()
}

/// Where a repository-relative path lands in the user's local clone (ADR 0039).
///
/// Pure, with the file system injected, so the three outcomes — no clone configured, the file is
/// there, the file is not — are each one test.
enum EditorFileTarget: Equatable, Sendable {
    /// No local checkout is linked for this repository.
    case noCheckout
    /// The file exists in the checkout.
    case file(URL)
    /// The checkout exists but does not contain the file — it is on another branch, behind the
    /// pull request, or the path was deleted. The folder is what can still be opened.
    case missingFile(checkout: URL, expected: URL)

    /// Resolves a pull request's file path against a checkout.
    ///
    /// A path that would climb out of the checkout (`../…`) is treated as missing rather than
    /// followed: the paths come from GitHub, and "open in editor" must only ever open something
    /// inside the folder the user chose.
    /// - Parameters:
    ///   - checkout: The linked clone, or `nil`.
    ///   - relativePath: The repository-relative path from the pull request.
    ///   - fileExists: Whether a regular file exists at an absolute path.
    /// - Returns: The resolution.
    static func resolve(
        checkout: URL?,
        relativePath: String,
        fileExists: (String) -> Bool
    ) -> EditorFileTarget {
        guard let checkout else { return .noCheckout }
        let root = checkout.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            return .missingFile(checkout: root, expected: candidate)
        }
        return fileExists(candidate.path)
            ? .file(candidate)
            : .missingFile(checkout: root, expected: candidate)
    }
}
