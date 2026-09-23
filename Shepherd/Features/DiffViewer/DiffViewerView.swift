import AppKit
import SwiftUI
import WebKit

/// The file a ``DiffViewerView`` is showing.
struct DiffViewerContent: Hashable, Sendable {
    /// The repository-relative path (also the viewer's model key).
    var path: String
    /// A Monaco language id.
    var language: String
    /// The left-hand document.
    var original: String
    /// The right-hand document.
    var modified: String
    /// Which lines came from the patch, and may therefore carry a comment.
    var commentableLines: BridgeCommentableLines?
}

/// Hosts the bundled Monaco diff editor in a `WKWebView` (ADR 0003).
///
/// Everything crossing the boundary is a typed ``DiffViewerCommand`` /
/// ``DiffViewerEvent``. Commands sent before the bundle reports `ready` are queued and flushed
/// on receipt, which is what `web/diff-viewer/README.md` asks callers to do.
struct DiffViewerView: NSViewRepresentable {
    /// The file to show.
    let content: DiffViewerContent
    /// Side-by-side or inline.
    var mode: BridgeDiffMode = .sideBySide
    /// Whether long lines wrap.
    var wrap: Bool = false
    /// The appearance to mirror into Monaco.
    var theme: BridgeThemeName
    /// Monaco's font size.
    var fontSize: Double = 13
    /// Published review threads for this file.
    var threads: [BridgeThread] = []
    /// Locally drafted comments for this file.
    var draftComments: [BridgeDraftComment] = []
    /// A line to reveal after loading, if any.
    var revealLine: Int?
    /// A token that asks for the keyboard focus to move into the editor.
    ///
    /// A counter rather than a flag, because "focus now" is an event and not a state: the caller
    /// raises it, the view sends the command once, and raising it again sends it again. Zero is
    /// "nobody has asked", which is what a screen that never hands focus over stays at.
    var focusRequest: Int = 0
    /// Which pane the pending ``focusRequest`` wants, read only when that token advances.
    ///
    /// The modified side unless somebody asks otherwise: it is the one a reviewer reads. The
    /// original side is how a comment on a deleted line is reached.
    var focusSide: BridgeSide = .right
    /// Whether a screen reader is running, as macOS sees it.
    ///
    /// Monaco's `accessibilitySupport: 'auto'` cannot work this out from inside a `WKWebView`:
    /// its detection is a browser's, and nothing in the web view knows that VoiceOver is reading
    /// the window around it. The app does know — SwiftUI publishes it — so it says
    /// (ADR 0033's second amendment).
    var screenReader: Bool = false
    /// Called on the main actor for every message the viewer sends back.
    var onEvent: (DiffViewerEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing the viewer does should ever be persisted: it is a renderer, not a browser.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: DiffViewerView.handlerName)
        // Before the web view exists, because the script has to be registered before the first
        // navigation starts for `.atDocumentStart` to mean anything.
        configuration.userContentController.addUserScript(DiffViewerView.themeBootstrap(theme))
        // Monaco's own words — the "hidden lines" bar, its hovers, its accessibility help — in
        // the app's language. Same reason to be a document-start script: Monaco reads its message
        // table while its modules evaluate, long before the bridge exists to carry anything.
        if let dist = DiffViewerView.distributionURL(),
           let messages = DiffViewerView.monacoMessages(for: DiffViewerView.appLanguage(), in: dist) {
            configuration.userContentController.addUserScript(
                WKUserScript(source: messages, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = NSColor(rgbHex: theme == .dark ? 0x101116 : 0xF7F8FA)
        webView.allowsMagnification = false
        #if DEBUG
        webView.isInspectable = true
        #endif

        context.coordinator.attach(webView)
        if let dist = DiffViewerView.distributionURL() {
            // The one directory this web view is ever allowed to be in. Handed to the
            // coordinator before the load, so the first navigation is already checked against
            // it (ADR 0003's "no remote loads" is enforced here rather than assumed).
            context.coordinator.bundleRoot = dist
            webView.navigationDelegate = context.coordinator
            webView.loadFileURL(
                dist.appendingPathComponent("index.html"),
                allowingReadAccessTo: dist
            )
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.apply(self)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: DiffViewerView.handlerName
        )
        nsView.navigationDelegate = nil
        coordinator.detach()
    }

    /// The message-handler name the web bundle looks up. It must be exactly `"shepherd"`.
    static let handlerName = "shepherd"

    /// Hands the page shell its theme before the shell has parsed a single tag.
    ///
    /// Runs at `.atDocumentStart`, so it is ahead of `index.html`'s own boot script and far ahead
    /// of the stylesheet. The shell reads `window.__shepherdTheme` first and only asks
    /// `prefers-color-scheme` when nothing set it, which is the order that matters here: the app
    /// can be forced dark while macOS is light, and a viewer guessing from the system painted a
    /// white page for a frame every time a file was opened. ``theme`` is already the resolved
    /// answer — the screen hands over `colorScheme`, not the preference.
    ///
    /// The class is written as well as the flag, so the frame is right even if the shell's own
    /// script never runs. Nothing is fetched to do any of it, so ADR 0003's "no remote loads"
    /// is untouched; the class name is the one `web/diff-viewer/src/styles.css` and the bridge's
    /// `setTheme` both use, which is `shepherd-theme-` plus the raw value. Add and remove rather
    /// than an assignment to `className`, so this, the shell's boot script and `setTheme` all
    /// move the class the same way.
    /// - Parameter theme: The appearance the app has already resolved.
    /// - Returns: The document-start script to register on the configuration.
    private static func themeBootstrap(_ theme: BridgeThemeName) -> WKUserScript {
        WKUserScript(
            source: """
            window.__shepherdTheme = '\(theme.rawValue)';
            if (document.documentElement) {
              var root = document.documentElement.classList;
              root.remove('shepherd-theme-light', 'shepherd-theme-dark');
              root.add('shepherd-theme-\(theme.rawValue)');
            }
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// What a screen reader calls each pane of the diff.
    ///
    /// The file's *name*, not its path: VoiceOver reads this whole label every time the cursor
    /// enters a pane, and the path is already on screen in the review header. What the label has
    /// to carry is which of the two panes this is — the one thing Monaco's own default, the same
    /// sentence on both, cannot say (ADR 0033's second amendment).
    ///
    /// `nonisolated` because it is a pure function over a string, and a test asserting one
    /// should not have to be on the main actor; nesting it in a `View` would otherwise make it.
    /// - Parameter path: The repository-relative path of the file being shown.
    nonisolated static func paneLabels(for path: String) -> BridgePaneLabels {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return BridgePaneLabels(
            left: String(localized: "Original, \(name)"),
            right: String(localized: "Changed, \(name)")
        )
    }

    /// The language the app's own strings resolved to — `"de"` or `"en"` — as a BCP 47 tag.
    ///
    /// The *bundle's* answer rather than `Locale.current`: a Mac set to French gets this app in
    /// English (it ships no French), and the diff has to agree with the screen around it rather
    /// than with the system. `Locale.current.identifier` would also be `de_DE`, which `Intl`
    /// rejects outright.
    nonisolated static func appLanguage(bundle: Bundle = .main) -> String {
        let language = bundle.preferredLocalizations.first ?? "en"
        return language == "Base" ? "en" : language
    }

    /// The words the web bundle draws itself, in the app's language (ADR 0022's diff-viewer amendment).
    ///
    /// The thread-card pills, the agent badge and the gutter's hover text are the only UI the
    /// bundle writes on its own; everything else in the diff is Monaco's or GitHub's. The bundle
    /// is not localised, so it is told.
    nonisolated static func viewerStrings() -> BridgeViewerStrings {
        BridgeViewerStrings(
            resolved: String(localized: "Resolved"),
            outdated: String(localized: "Outdated"),
            pending: String(localized: "Pending"),
            noComments: String(localized: "No comments."),
            unknownAuthor: String(localized: "unknown"),
            agentBadgeTitle: String(localized: "Posted by an agent"),
            agentBadgeLabel: String(localized: "Agent"),
            addComment: String(localized: "Add a review comment"),
            // `{count}` is the bundle's placeholder, not a format specifier: the count lives in
            // the web view, and `Intl.PluralRules` picks between the two phrases there.
            commentCount: BridgeViewerStrings.CommentCount(
                one: String(localized: "1 comment"),
                other: String(localized: "{count} comments")
            )
        )
    }

    /// Monaco's message table for a language, the source of a document-start user script — or
    /// `nil` for English, which is what Monaco is written in, and for a language the build did not
    /// copy.
    ///
    /// The file is Monaco's own (`web/diff-viewer/scripts/build.mjs` copies it into `dist/nls/`),
    /// a classic script that sets the global Monaco looks its strings up in. It is read here and
    /// injected rather than referenced from `index.html`, because only the app knows which
    /// language it is in before the page parses, and nothing is fetched — ADR 0003 is untouched.
    /// - Parameters:
    ///   - language: The app's language, from ``appLanguage(bundle:)``.
    ///   - dist: The bundle directory, from ``distributionURL()``.
    nonisolated static func monacoMessages(for language: String, in dist: URL) -> String? {
        guard language != "en", !language.contains("/"), !language.contains(".") else { return nil }
        let file = dist.appendingPathComponent("nls/\(language).js")
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// Locates the built web bundle inside the app bundle.
    ///
    /// Tries the folder-reference layout first (`DiffViewer/dist`, which is how `project.yml`
    /// ships it) and falls back to a flattened copy so a differently configured build still
    /// finds `index.html`.
    static func distributionURL() -> URL? {
        if let url = Bundle.main.url(
            forResource: "dist",
            withExtension: nil,
            subdirectory: "DiffViewer"
        ) {
            return url
        }
        if let resources = Bundle.main.resourceURL {
            let nested = resources.appendingPathComponent("DiffViewer/dist", isDirectory: true)
            if FileManager.default.fileExists(
                atPath: nested.appendingPathComponent("index.html").path
            ) {
                return nested
            }
        }
        if let index = Bundle.main.url(forResource: "index", withExtension: "html") {
            return index.deletingLastPathComponent()
        }
        return nil
    }

    /// Bridges `WKScriptMessage`s into typed events and holds the outbound queue.
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        /// Called for every decoded event.
        var onEvent: (DiffViewerEvent) -> Void

        /// The bundle directory this web view may load from, and nothing else.
        ///
        /// Set before the first load. `nil` would mean "no navigation is allowed at all", which
        /// is the safe answer for a view that could not find its own bundle.
        var bundleRoot: URL?

        private weak var webView: WKWebView?
        private var isReady = false
        private var queue: [DiffViewerCommand] = []

        private var sentContent: DiffViewerContent?
        private var sentMode: BridgeDiffMode?
        private var sentWrap: Bool?
        private var sentTheme: BridgeThemeName?
        private var sentFontSize: Double?
        private var sentThreads: [BridgeThread]?
        private var sentDrafts: [BridgeDraftComment]?
        private var sentRevealLine: Int?
        private var sentFocusRequest = 0
        private var sentScreenReader: Bool?
        private var sentLocale = false

        /// Creates a coordinator.
        /// - Parameter onEvent: The event sink.
        init(onEvent: @escaping (DiffViewerEvent) -> Void) {
            self.onEvent = onEvent
        }

        /// Remembers the web view commands are sent to.
        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        /// Drops the web view reference when the representable goes away.
        func detach() {
            webView = nil
            queue.removeAll()
            isReady = false
        }

        /// Sends whatever changed since the last update.
        ///
        /// Takes the view rather than its ten properties one by one: every one of them is
        /// already stored on the view, so a parameter list is a second copy of the same
        /// declaration that has to be extended twice for every field the bridge grows.
        /// - Parameter view: The representable being updated.
        func apply(_ view: DiffViewerView) {
            // First of all, so no card is ever drawn in English and then redrawn. The app's
            // language does not change while it runs, so once is enough.
            if !sentLocale {
                sentLocale = true
                send(.setLocale(
                    locale: DiffViewerView.appLanguage(),
                    strings: DiffViewerView.viewerStrings()
                ))
            }
            if sentTheme != view.theme || sentFontSize != view.fontSize {
                sentTheme = view.theme
                sentFontSize = view.fontSize
                send(.setTheme(theme: view.theme, fontSize: view.fontSize))
            }
            // Before `loadFile`, so a file that arrives while a screen reader is running is
            // rendered in the mode that reader needs rather than switched into it afterwards.
            if sentScreenReader != view.screenReader {
                sentScreenReader = view.screenReader
                send(.setAccessibility(screenReader: view.screenReader))
            }
            if sentContent != view.content || sentMode != view.mode || sentWrap != view.wrap {
                sentContent = view.content
                sentMode = view.mode
                sentWrap = view.wrap
                // A newly loaded file starts with no zones, so the snapshots must be re-sent.
                sentThreads = nil
                sentDrafts = nil
                sentRevealLine = nil
                send(.loadFile(
                    DiffViewerCommand.LoadFile(
                        path: view.content.path,
                        language: view.content.language,
                        original: view.content.original,
                        modified: view.content.modified,
                        mode: view.mode,
                        wrap: view.wrap,
                        commentableLines: view.content.commentableLines,
                        paneLabels: DiffViewerView.paneLabels(for: view.content.path)
                    )
                ))
            }
            if sentThreads != view.threads {
                sentThreads = view.threads
                send(.setThreads(view.threads))
            }
            if sentDrafts != view.draftComments {
                sentDrafts = view.draftComments
                send(.setDraftComments(view.draftComments))
            }
            if let revealLine = view.revealLine, sentRevealLine != revealLine, revealLine >= 1 {
                sentRevealLine = revealLine
                send(.revealLine(line: revealLine, side: .right))
            }
            // Last, and after `loadFile`: focus follows the content it is being handed to, and a
            // command queued before the bundle is ready is flushed in this order too.
            if view.focusRequest > sentFocusRequest {
                sentFocusRequest = view.focusRequest
                send(.focusEditor(side: view.focusSide))
            }
        }

        /// Sends a command, queuing it until the bundle reports `ready`.
        func send(_ command: DiffViewerCommand) {
            guard isReady else {
                queue.append(command)
                return
            }
            deliver(command)
        }

        private func deliver(_ command: DiffViewerCommand) {
            guard let webView else { return }
            guard let literal = try? command.javaScriptLiteral() else { return }
            webView.evaluateJavaScript("shepherd.receive(\(literal))") { _, _ in
                // Delivery failures are non-fatal: the next update re-sends the state, and
                // the viewer is a presentation surface, not a source of truth.
            }
        }

        private func flushQueue() {
            let pending = queue
            queue.removeAll()
            for command in pending {
                deliver(command)
            }
        }

        // MARK: - WKNavigationDelegate

        /// Allows the bundle to load and nothing else.
        ///
        /// The viewer renders somebody else's text: a pull-request description or a review
        /// comment may contain a link, `MarkdownHTML` deliberately lets `https://` links
        /// through, and the bundle draws them as ordinary anchors. Without this method
        /// `WKWebView`'s default answer to a click is *allow*, which would navigate this view —
        /// the one holding the `shepherd` message handler — to a stranger's page, and that page
        /// could then post forged bridge events from the same `WKWebViewConfiguration`.
        ///
        /// So the rule is the one ADR 0003 always assumed: the only navigation this view
        /// performs is inside its own bundle directory. A link goes to the user's browser,
        /// where a URL bar and a real security model exist, and everything else is refused
        /// without comment.
        /// - Parameters:
        ///   - webView: The view.
        ///   - navigationAction: What it is about to do.
        ///   - decisionHandler: Where the answer goes.
        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                guard let url = navigationAction.request.url else {
                    decisionHandler(.cancel)
                    return
                }
                if DiffViewerView.Coordinator.isInsideBundle(url, root: bundleRoot) {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                // A link the reviewer clicked is still worth following — just not here. Only the
                // two web schemes are handed on: `file:`, `javascript:` and anything a comment
                // author invented are refused outright.
                if url.scheme == "https" || url.scheme == "http" {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        /// Whether a URL is a file inside the bundle directory.
        ///
        /// Symlinks are resolved on both sides before the prefix is compared, which is
        /// ``GitWorktree/ensureManaged()``'s reasoning: a path that spells its way out with
        /// `..` or through a link must not pass a string comparison.
        /// - Parameters:
        ///   - url: The URL to check.
        ///   - root: The bundle directory, or `nil` when there is none.
        nonisolated static func isInsideBundle(_ url: URL, root: URL?) -> Bool {
            guard let root, url.isFileURL else { return false }
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            let target = url.standardizedFileURL.resolvingSymlinksInPath().path
            let boundary = base.hasSuffix("/") ? base : base + "/"
            return target == base || target.hasPrefix(boundary)
        }

        // MARK: - WKScriptMessageHandler

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // WebKit always delivers script messages on the main thread.
            guard let event = Coordinator.decode(body: message.body) else { return }
            MainActor.assumeIsolated {
                if case .ready = event {
                    isReady = true
                    flushQueue()
                }
                onEvent(event)
            }
        }

        /// Decodes a raw script-message body into a typed event.
        ///
        /// `nonisolated` and `static` so it can run wherever WebKit calls from, and so the
        /// decoding path is unit-testable on its own.
        nonisolated static func decode(body: Any) -> DiffViewerEvent? {
            let data: Data
            if let text = body as? String {
                data = Data(text.utf8)
            } else if JSONSerialization.isValidJSONObject(body),
                      let serialised = try? JSONSerialization.data(withJSONObject: body) {
                data = serialised
            } else {
                return nil
            }
            return try? JSONDecoder().decode(DiffViewerEvent.self, from: data)
        }
    }
}

/// Shown instead of the web view when GitHub sent no patch for a file.
struct DiffUnavailableView: View {
    /// The file's path.
    let path: String
    /// Why there is no diff.
    var reason: String = String(
        localized: "GitHub did not send a diff for this file — it is binary, or the patch was too large."
    )

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Text(path)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
