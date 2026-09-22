import AppKit
import ShepherdCore
import SwiftUI

/// Performs "Open in editor": resolves a pull request's path in the user's local clone and hands
/// it to the editor chosen in Settings → Delegation (ADR 0039).
///
/// The thin, effectful half of ``EditorLauncher``: every decision about *which* URL or argv is
/// made there and tested there, and this type only talks to `NSWorkspace`, `Process`, the folder
/// panel and the toast queue. A value type built on the spot by the view that needs it, because
/// it holds nothing of its own — the choice lives in ``AppSettings/editor`` and the clones in
/// ``AppSettings/localCheckouts``, which is the map delegation already uses, so linking a clone
/// here also makes delegation work for that repository and the reverse.
///
/// Honest about the one thing it cannot know: whether the clone is at the pull request's head.
/// Line numbers are head-side, the clone is whatever branch the user left it on, and Shepherd
/// does not run git to find out — so a file that is missing is *said* to be missing, and the
/// menu item's help says the line may be off.
@MainActor
struct EditorOpener {
    /// Where the editor choice and the clone map live.
    let settings: AppSettings
    /// Where failures and the "not in your checkout" note are shown.
    let toasts: ToastCenter

    /// The menu title for the configured editor: "Open in Visual Studio Code".
    var openTitle: String { Self.openTitle(for: settings.editor.kind) }

    /// The title for a given editor.
    /// - Parameter kind: The editor.
    /// - Returns: The menu or button title.
    static func openTitle(for kind: EditorKind) -> String {
        switch kind {
        case .systemDefault: return String(localized: "Open in Default App")
        case .custom: return String(localized: "Open with Editor Command")
        case .visualStudioCode, .intelliJ, .cursor:
            return String(localized: "Open in \(kind.title)")
        }
    }

    /// The help text under the action: what it opens, and the one caveat that matters.
    static var openHelp: String {
        String(localized: "Opens the file in your local checkout. Lines are counted on the pull request's head, so they only match when the checkout is on that commit.")
    }

    /// Whether a local clone is linked for the repository, i.e. whether the action opens a file
    /// or first asks for a folder.
    /// - Parameter repo: The repository.
    /// - Returns: `true` when a checkout is configured.
    func hasCheckout(for repo: RepoRef) -> Bool {
        settings.localCheckoutURL(for: repo) != nil
    }

    /// Opens one file of a pull request in the configured editor.
    ///
    /// With no clone linked it offers to link one rather than failing — the toast's button runs
    /// ``linkCheckoutAndOpen(repo:path:line:)``. A file the clone does not have opens the clone's
    /// folder instead, with a warning that says why.
    /// - Parameters:
    ///   - repo: The pull request's repository.
    ///   - path: The repository-relative path.
    ///   - line: The head-side line, when one is known.
    func open(repo: RepoRef, path: String, line: Int?) {
        let target = EditorFileTarget.resolve(
            checkout: settings.localCheckoutURL(for: repo),
            relativePath: path,
            fileExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
        )
        switch target {
        case .noCheckout:
            let opener = self
            toasts.show(Toast(
                message: String(localized: "No local checkout is linked for \(repo.fullName) yet."),
                kind: .warning,
                actionTitle: String(localized: "Link a Local Checkout…"),
                action: { opener.linkCheckoutAndOpen(repo: repo, path: path, line: line) },
                duration: 8
            ))
        case .file(let file):
            perform(file: file, line: line)
        case .missingFile(let checkout, _):
            guard perform(file: checkout, line: nil) else { return }
            toasts.show(Toast(
                message: String(localized: "\(path) is not in your checkout of \(repo.fullName) — it may be on another branch than this pull request. Opened the checkout instead."),
                kind: .warning,
                duration: 8
            ))
        }
    }

    /// Asks for the repository's clone, stores it, then opens the file.
    ///
    /// The same folder panel and the same map as Settings → Delegation's *Local checkouts* card,
    /// so the answer is not a second setting that could disagree with the first.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - path: The repository-relative path to open afterwards.
    ///   - line: The line to open it at.
    func linkCheckoutAndOpen(repo: RepoRef, path: String, line: Int?) {
        guard let url = FolderPicker.choose(
            title: String(localized: "Choose the local clone of \(repo.fullName)")
        ) else { return }
        settings.setLocalCheckout(url, forRepoNamed: repo.fullName)
        open(repo: repo, path: path, line: line)
    }

    /// Which editors this Mac has, for Settings. The two kinds that are not one application are
    /// always available.
    /// - Returns: The installed kinds.
    static func installedKinds() -> Set<EditorKind> {
        Set(EditorKind.allCases.filter { kind in
            kind.bundleIdentifiers.isEmpty || installedApplication(for: kind) != nil
        })
    }

    // MARK: - Performing

    /// Hands one file or folder to the editor.
    /// - Returns: Whether anything was launched; a failure has already been toasted.
    @discardableResult
    private func perform(file: URL, line: Int?) -> Bool {
        let launch: EditorLaunch
        do {
            launch = try EditorLauncher.launch(for: settings.editor, file: file, line: line)
        } catch {
            toasts.failure(error, context: String(localized: "Could not open the editor"))
            return false
        }
        switch launch {
        case .systemDefault(let url):
            guard NSWorkspace.shared.open(url) else {
                toasts.show(Toast(
                    message: String(localized: "macOS could not open \(url.lastPathComponent)."),
                    kind: .failure,
                    duration: 8
                ))
                return false
            }
            return true
        case .url(let url, let file, let fallbacks):
            if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                return NSWorkspace.shared.open(url)
            }
            // The scheme has no handler — an editor that was installed but never launched has
            // not registered it yet. Opening the file *with* the editor loses the line and keeps
            // the rest, which beats a refusal.
            if let application = fallbacks.lazy.compactMap(Self.application(bundleIdentifier:)).first {
                NSWorkspace.shared.open(
                    [file],
                    withApplicationAt: application,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                return true
            }
            toasts.show(Toast(
                message: String(localized: "\(settings.editor.kind.title) is not installed on this Mac. Choose another editor in Settings → Delegation."),
                kind: .failure,
                duration: 8
            ))
            return false
        case .process(let invocation):
            return spawn(invocation)
        }
    }

    /// Runs a custom editor command: `Process`, never a shell, and never waited for — an editor
    /// CLI that stays in the foreground must not hold anything up.
    private func spawn(_ invocation: AgentInvocation) -> Bool {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let toasts = self.toasts
        let name = invocation.executable.lastPathComponent
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else { return }
            Task { @MainActor in
                toasts.show(Toast(
                    message: String(localized: "The editor command \(name) reported an error."),
                    kind: .failure,
                    duration: 8
                ))
            }
        }
        do {
            try process.run()
            return true
        } catch {
            toasts.failure(error, context: String(localized: "Could not run the editor command"))
            return false
        }
    }

    private static func installedApplication(for kind: EditorKind) -> URL? {
        kind.bundleIdentifiers.lazy.compactMap(application(bundleIdentifier:)).first
    }

    private static func application(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

/// The "Open in …" entry of a file's context menu — or "Link a Local Checkout…" when the
/// repository has none yet, which links one and then opens the file (ADR 0039).
///
/// One view for every place that offers it, so the file list, the file header and the claims
/// card cannot disagree about the title or the no-checkout path.
struct OpenInEditorMenuItem: View {
    /// The opener, built by the screen that has the settings and the toast queue.
    let opener: EditorOpener
    /// The pull request's repository.
    let repo: RepoRef
    /// The repository-relative path.
    let path: String
    /// The head-side line, when known.
    var line: Int?

    var body: some View {
        if opener.hasCheckout(for: repo) {
            Button {
                opener.open(repo: repo, path: path, line: line)
            } label: {
                Label(opener.openTitle, systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .help(EditorOpener.openHelp)
        } else {
            Button {
                opener.linkCheckoutAndOpen(repo: repo, path: path, line: line)
            } label: {
                Label(String(localized: "Link a Local Checkout…"), systemImage: "folder.badge.plus")
            }
            .help(String(localized: "Choose the folder where you cloned \(repo.fullName). Delegation uses the same checkout."))
        }
    }
}

/// What a row needs to offer "Open in …" for a path of one pull request: the opener and the
/// repository the path belongs to.
///
/// Passed as one optional value into the cards that show `path:line` links (claims, CI
/// diagnosis), so a card built without it simply has no menu, and a card cannot be handed an
/// opener for one repository and paths from another.
@MainActor
struct EditorContext {
    /// The opener.
    let opener: EditorOpener
    /// The pull request's repository.
    let repo: RepoRef
}

extension View {
    /// Adds an "Open in …" context menu for one path, when there is an editor context.
    /// - Parameters:
    ///   - context: The opener and repository, or `nil` for no menu at all.
    ///   - path: The repository-relative path.
    ///   - line: The head-side line, when known.
    /// - Returns: The view, with the menu attached.
    func openInEditorMenu(_ context: EditorContext?, path: String, line: Int?) -> some View {
        modifier(OpenInEditorMenuModifier(context: context, path: path, line: line))
    }
}

/// The modifier behind ``SwiftUI/View/openInEditorMenu(_:path:line:)``. A modifier rather than a
/// bare `.contextMenu`, so a view with no context gets no menu instead of an empty one.
private struct OpenInEditorMenuModifier: ViewModifier {
    let context: EditorContext?
    let path: String
    let line: Int?

    func body(content: Content) -> some View {
        if let context {
            content.contextMenu {
                OpenInEditorMenuItem(
                    opener: context.opener,
                    repo: context.repo,
                    path: path,
                    line: line
                )
            }
        } else {
            content
        }
    }
}
