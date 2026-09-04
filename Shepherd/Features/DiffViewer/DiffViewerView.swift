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
        context.coordinator.apply(
            content: content,
            mode: mode,
            wrap: wrap,
            theme: theme,
            fontSize: fontSize,
            threads: threads,
            draftComments: draftComments,
            revealLine: revealLine
        )
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
        func apply(
            content: DiffViewerContent,
            mode: BridgeDiffMode,
            wrap: Bool,
            theme: BridgeThemeName,
            fontSize: Double,
            threads: [BridgeThread],
            draftComments: [BridgeDraftComment],
            revealLine: Int?
        ) {
            if sentTheme != theme || sentFontSize != fontSize {
                sentTheme = theme
                sentFontSize = fontSize
                send(.setTheme(theme: theme, fontSize: fontSize))
            }
            if sentContent != content || sentMode != mode || sentWrap != wrap {
                sentContent = content
                sentMode = mode
                sentWrap = wrap
                // A newly loaded file starts with no zones, so the snapshots must be re-sent.
                sentThreads = nil
                sentDrafts = nil
                sentRevealLine = nil
                send(.loadFile(
                    DiffViewerCommand.LoadFile(
                        path: content.path,
                        language: content.language,
                        original: content.original,
                        modified: content.modified,
                        mode: mode,
                        wrap: wrap,
                        commentableLines: content.commentableLines
                    )
                ))
            }
            if sentThreads != threads {
                sentThreads = threads
                send(.setThreads(threads))
            }
            if sentDrafts != draftComments {
                sentDrafts = draftComments
                send(.setDraftComments(draftComments))
            }
            if let revealLine, sentRevealLine != revealLine, revealLine >= 1 {
                sentRevealLine = revealLine
                send(.revealLine(line: revealLine, side: .right))
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
        static func isInsideBundle(_ url: URL, root: URL?) -> Bool {
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
