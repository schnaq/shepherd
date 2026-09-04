import Foundation

/// Constants of the Swift ⇄ Monaco bridge.
///
/// This file is the Swift half of the contract defined in
/// `web/diff-viewer/src/bridge/protocol.ts` and `docs/ARCHITECTURE.md` ("Diff viewer bridge").
/// The two implementations must stay field-for-field identical; the shared fixtures in
/// `web/diff-viewer/fixtures/` are decoded by *both* sides' tests, so drift fails CI on
/// whichever side moved.
enum BridgeProtocol {
    /// Every message carries `"v": 1`.
    static let version = 1
}

/// Everything the bridge can reject a message for.
enum BridgeProtocolError: Error, Equatable, LocalizedError {
    /// The `v` field was not ``BridgeProtocol/version``.
    case unsupportedVersion(Int)
    /// The `type` discriminator named a message this version does not know.
    case unknownMessageType(String)
    /// A line number was not a positive (1-based) integer.
    case invalidLineNumber(Int)
    /// `startLine` was greater than `line`.
    case startLineAfterLine(startLine: Int, line: Int)
    /// `commentClicked` carried both `threadID` and `localID`, or neither.
    case ambiguousCommentTarget
    /// A field that must be non-empty was empty.
    case emptyField(String)
    /// `fontSize` was not positive.
    case invalidFontSize(Double)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported bridge protocol version \(version), expected \(BridgeProtocol.version)."
        case .unknownMessageType(let type):
            return "Unknown bridge message type “\(type)”."
        case .invalidLineNumber(let line):
            return "Invalid line number \(line): line numbers are 1-based."
        case .startLineAfterLine(let startLine, let line):
            return "startLine (\(startLine)) must not be greater than line (\(line))."
        case .ambiguousCommentTarget:
            return "commentClicked must carry exactly one of threadID / localID."
        case .emptyField(let name):
            return "Field “\(name)” must not be empty."
        case .invalidFontSize(let size):
            return "Invalid font size \(size): must be positive."
        }
    }
}

// MARK: - Shared value types

/// Which side of the diff a line, thread or comment belongs to.
enum BridgeSide: String, Codable, Hashable, Sendable, CaseIterable {
    /// The original (left) editor.
    case left
    /// The modified (right) editor.
    case right
}

/// The diff editor's layout.
enum BridgeDiffMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Two panes.
    case sideBySide
    /// One pane.
    case inline
}

/// Monaco's theme.
enum BridgeThemeName: String, Codable, Hashable, Sendable, CaseIterable {
    /// The light theme.
    case light
    /// The dark theme.
    case dark
}

/// One comment inside a published thread.
///
/// ``bodyHTML`` is **trusted-from-native**: the Swift side renders and sanitizes GitHub
/// markdown with ``MarkdownHTML`` before it reaches the webview, which renders it with
/// `innerHTML`.
struct BridgeThreadComment: Codable, Hashable, Sendable {
    /// The author's login.
    var author: String
    /// Sanitized HTML produced by ``MarkdownHTML/render(_:)``.
    var bodyHTML: String
    /// ISO-8601 timestamp.
    var createdAt: String
    /// Whether the author is a coding agent (ADR 0008), which the viewer badges.
    var isAgent: Bool

    /// Creates a comment payload.
    init(author: String, bodyHTML: String, createdAt: String, isAgent: Bool) {
        self.author = author
        self.bodyHTML = bodyHTML
        self.createdAt = createdAt
        self.isAgent = isAgent
    }
}

/// A published review thread, anchored to a line.
struct BridgeThread: Codable, Hashable, Sendable, Identifiable {
    /// The thread's GraphQL node id.
    var id: String
    /// The 1-based line the thread hangs on.
    var line: Int
    /// Which editor the line belongs to.
    var side: BridgeSide
    /// Whether the thread is resolved.
    var resolved: Bool
    /// Whether the anchor is outdated.
    var outdated: Bool
    /// The conversation, oldest first.
    var comments: [BridgeThreadComment]

    /// Creates a thread payload.
    init(
        id: String,
        line: Int,
        side: BridgeSide,
        resolved: Bool,
        outdated: Bool,
        comments: [BridgeThreadComment]
    ) {
        self.id = id
        self.line = line
        self.side = side
        self.resolved = resolved
        self.outdated = outdated
        self.comments = comments
    }

    private enum CodingKeys: String, CodingKey {
        case id, line, side, resolved, outdated, comments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard !id.isEmpty else { throw BridgeProtocolError.emptyField("threads[].id") }
        let line = try container.decode(Int.self, forKey: .line)
        guard line >= 1 else { throw BridgeProtocolError.invalidLineNumber(line) }
        self.init(
            id: id,
            line: line,
            side: try container.decode(BridgeSide.self, forKey: .side),
            resolved: try container.decode(Bool.self, forKey: .resolved),
            outdated: try container.decode(Bool.self, forKey: .outdated),
            comments: try container.decode([BridgeThreadComment].self, forKey: .comments)
        )
    }
}

/// A locally drafted comment, mirrored into the viewer so the user sees their pending review.
struct BridgeDraftComment: Codable, Hashable, Sendable, Identifiable {
    /// The draft comment's local UUID string.
    var localID: String
    /// The 1-based line it hangs on.
    var line: Int
    /// Which editor the line belongs to.
    var side: BridgeSide
    /// Plain text — never HTML.
    var body: String

    /// `BridgeDraftComment` is identified by its ``localID``.
    var id: String { localID }

    /// Creates a draft payload.
    init(localID: String, line: Int, side: BridgeSide, body: String) {
        self.localID = localID
        self.line = line
        self.side = side
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case localID, line, side, body
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let localID = try container.decode(String.self, forKey: .localID)
        guard !localID.isEmpty else {
            throw BridgeProtocolError.emptyField("comments[].localID")
        }
        let line = try container.decode(Int.self, forKey: .line)
        guard line >= 1 else { throw BridgeProtocolError.invalidLineNumber(line) }
        self.init(
            localID: localID,
            line: line,
            side: try container.decode(BridgeSide.self, forKey: .side),
            body: try container.decode(String.self, forKey: .body)
        )
    }
}

// MARK: - Swift → web

/// The lines of a reconstructed diff a comment may be anchored to, per side.
///
/// Shepherd rebuilds both documents from GitHub's unified patch and pads the gaps between
/// hunks with blank lines so that absolute line numbers still match GitHub's. Those filler
/// lines are not part of the diff, and GitHub rejects the entire review when a comment lands
/// on one, so the viewer is told exactly which lines it may arm the “+” on.
///
/// Omitting the field means "no restriction", which is what a viewer built against an older
/// payload sees — the field is additive, so the protocol version stays 1.
/// What a screen reader should call each pane of the diff.
///
/// Monaco's own default is the same sentence on both panes, so it cannot say which one the
/// cursor is in — the single most useful fact at the moment somebody has just handed the
/// keyboard over with `c`. The wording is sent from here rather than written in the bundle
/// because the app is localised and the bundle is not (ADR 0033's second amendment).
struct BridgePaneLabels: Codable, Hashable, Sendable {
    /// What to call the original (left) pane.
    var left: String
    /// What to call the modified (right) pane.
    var right: String

    /// Creates a payload.
    init(left: String, right: String) {
        self.left = left
        self.right = right
    }

    private enum CodingKeys: String, CodingKey {
        case left, right
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let left = try container.decode(String.self, forKey: .left)
        let right = try container.decode(String.self, forKey: .right)
        guard !left.isEmpty else { throw BridgeProtocolError.emptyField("paneLabels.left") }
        guard !right.isEmpty else { throw BridgeProtocolError.emptyField("paneLabels.right") }
        self.init(left: left, right: right)
    }
}

struct BridgeCommentableLines: Codable, Hashable, Sendable {
    /// Commentable 1-based lines of the original (left) document.
    var left: [Int]
    /// Commentable 1-based lines of the modified (right) document.
    var right: [Int]

    /// Creates a payload.
    init(left: [Int], right: [Int]) {
        self.left = left
        self.right = right
    }

    private enum CodingKeys: String, CodingKey {
        case left, right
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let left = try container.decode([Int].self, forKey: .left)
        let right = try container.decode([Int].self, forKey: .right)
        if let bad = (left + right).first(where: { $0 < 1 }) {
            throw BridgeProtocolError.invalidLineNumber(bad)
        }
        self.init(left: left, right: right)
    }
}

/// A message Shepherd sends into the viewer (`InboundMessage` in `protocol.ts`).
enum DiffViewerCommand: Hashable, Sendable, Codable {
    /// The payload of ``loadFile(_:)``.
    struct LoadFile: Hashable, Sendable {
        /// The file's repository path, shown in the viewer's header.
        var path: String
        /// A Monaco language id, or `"plaintext"`.
        var language: String
        /// The left-hand text.
        var original: String
        /// The right-hand text.
        var modified: String
        /// The editor layout.
        var mode: BridgeDiffMode
        /// Whether long lines wrap.
        var wrap: Bool
        /// Which lines may carry a comment, or `nil` for "every line".
        var commentableLines: BridgeCommentableLines?
        /// What a screen reader calls each pane, or `nil` to leave Monaco's own default.
        var paneLabels: BridgePaneLabels?

        /// Creates a payload.
        init(
            path: String,
            language: String,
            original: String,
            modified: String,
            mode: BridgeDiffMode,
            wrap: Bool,
            commentableLines: BridgeCommentableLines? = nil,
            paneLabels: BridgePaneLabels? = nil
        ) {
            self.path = path
            self.language = language
            self.original = original
            self.modified = modified
            self.mode = mode
            self.wrap = wrap
            self.commentableLines = commentableLines
            self.paneLabels = paneLabels
        }
    }

    /// Show a file's diff.
    case loadFile(LoadFile)
    /// Switch appearance and font size.
    case setTheme(theme: BridgeThemeName, fontSize: Double)
    /// Replace the published threads.
    case setThreads([BridgeThread])
    /// Replace the pending draft comments.
    case setDraftComments([BridgeDraftComment])
    /// Scroll a line into view.
    case revealLine(line: Int, side: BridgeSide)
    /// Tell the viewer whether a screen reader is running.
    ///
    /// Monaco decides this for itself when `accessibilitySupport` is `'auto'`, and in a
    /// `WKWebView` it decides wrong: its detection is a browser's, and nothing inside the web
    /// view can see that VoiceOver is reading the window around it. macOS tells the app, so the
    /// app is the honest source (ADR 0033's second amendment).
    case setAccessibility(screenReader: Bool)
    /// Put the keyboard focus in one pane of the diff.
    ///
    /// It exists because the keyboard has a boundary the mouse does not: what a reviewer does to
    /// a *file* is a key in the native screen, and what they do to a *line* is Monaco's, so
    /// somebody working without a mouse needs a way across (ADR 0033's amendment). The side is
    /// how a comment on a *deleted* line is reached: deletions only exist in the original pane.
    /// Sending this twice focuses twice, which is why the view sends it off a request token
    /// rather than off a value it can compare.
    ///
    /// On the wire the side is optional, and absent means `.right` — the shape the command had
    /// before there was another pane to ask for.
    case focusEditor(side: BridgeSide)

    /// The `type` discriminator of this message.
    var messageType: String {
        switch self {
        case .loadFile: return "loadFile"
        case .setTheme: return "setTheme"
        case .setThreads: return "setThreads"
        case .setDraftComments: return "setDraftComments"
        case .revealLine: return "revealLine"
        case .focusEditor: return "focusEditor"
        case .setAccessibility: return "setAccessibility"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case v, type
        case path, language, original, modified, mode, wrap, commentableLines, paneLabels
        case theme, fontSize
        case threads, comments
        case line, side
        case screenReader
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == BridgeProtocol.version else {
            throw BridgeProtocolError.unsupportedVersion(version)
        }
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "loadFile":
            self = .loadFile(
                LoadFile(
                    path: try container.decode(String.self, forKey: .path),
                    language: try container.decode(String.self, forKey: .language),
                    original: try container.decode(String.self, forKey: .original),
                    modified: try container.decode(String.self, forKey: .modified),
                    mode: try container.decode(BridgeDiffMode.self, forKey: .mode),
                    wrap: try container.decode(Bool.self, forKey: .wrap),
                    commentableLines: try container.decodeIfPresent(
                        BridgeCommentableLines.self,
                        forKey: .commentableLines
                    ),
                    paneLabels: try container.decodeIfPresent(
                        BridgePaneLabels.self,
                        forKey: .paneLabels
                    )
                )
            )
        case "setTheme":
            let fontSize = try container.decode(Double.self, forKey: .fontSize)
            guard fontSize > 0, fontSize.isFinite else {
                throw BridgeProtocolError.invalidFontSize(fontSize)
            }
            self = .setTheme(
                theme: try container.decode(BridgeThemeName.self, forKey: .theme),
                fontSize: fontSize
            )
        case "setThreads":
            self = .setThreads(try container.decode([BridgeThread].self, forKey: .threads))
        case "setDraftComments":
            self = .setDraftComments(
                try container.decode([BridgeDraftComment].self, forKey: .comments)
            )
        case "revealLine":
            let line = try container.decode(Int.self, forKey: .line)
            guard line >= 1 else { throw BridgeProtocolError.invalidLineNumber(line) }
            self = .revealLine(
                line: line,
                side: try container.decode(BridgeSide.self, forKey: .side)
            )
        case "focusEditor":
            // The side is optional on the wire: a message without one means the modified pane,
            // which is what this command meant before there was a way to ask for the other one.
            self = .focusEditor(
                side: try container.decodeIfPresent(BridgeSide.self, forKey: .side) ?? .right
            )
        case "setAccessibility":
            self = .setAccessibility(
                screenReader: try container.decode(Bool.self, forKey: .screenReader)
            )
        default:
            throw BridgeProtocolError.unknownMessageType(type)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BridgeProtocol.version, forKey: .v)
        try container.encode(messageType, forKey: .type)
        switch self {
        case .loadFile(let payload):
            try container.encode(payload.path, forKey: .path)
            try container.encode(payload.language, forKey: .language)
            try container.encode(payload.original, forKey: .original)
            try container.encode(payload.modified, forKey: .modified)
            try container.encode(payload.mode, forKey: .mode)
            try container.encode(payload.wrap, forKey: .wrap)
            try container.encodeIfPresent(payload.commentableLines, forKey: .commentableLines)
            try container.encodeIfPresent(payload.paneLabels, forKey: .paneLabels)
        case .setTheme(let theme, let fontSize):
            try container.encode(theme, forKey: .theme)
            try container.encode(fontSize, forKey: .fontSize)
        case .setThreads(let threads):
            try container.encode(threads, forKey: .threads)
        case .setDraftComments(let comments):
            try container.encode(comments, forKey: .comments)
        case .revealLine(let line, let side):
            try container.encode(line, forKey: .line)
            try container.encode(side, forKey: .side)
        case .focusEditor(let side):
            try container.encode(side, forKey: .side)
        case .setAccessibility(let screenReader):
            try container.encode(screenReader, forKey: .screenReader)
        }
    }
}

// MARK: - Web → Swift

/// What a `commentClicked` message pointed at.
enum BridgeCommentTarget: Hashable, Sendable {
    /// A published thread, by GraphQL node id.
    case thread(String)
    /// A local draft comment, by UUID string.
    case draft(String)
}

/// A message the viewer sends back (`OutboundMessage` in `protocol.ts`).
enum DiffViewerEvent: Hashable, Sendable, Codable {
    /// The bundle booted; queued commands may be flushed.
    case ready
    /// The user clicked a gutter “+”; Shepherd opens the *native* composer.
    case addComment(line: Int, side: BridgeSide, startLine: Int?)
    /// The user clicked a thread or draft card.
    case commentClicked(BridgeCommentTarget)
    /// The viewer scrolled (throttled to one message per 120 ms by the web side).
    case viewportChanged(firstVisibleLine: Int)

    /// The `type` discriminator of this message.
    var messageType: String {
        switch self {
        case .ready: return "ready"
        case .addComment: return "addComment"
        case .commentClicked: return "commentClicked"
        case .viewportChanged: return "viewportChanged"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case v, type
        case line, side, startLine
        case threadID, localID
        case firstVisibleLine
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .v)
        guard version == BridgeProtocol.version else {
            throw BridgeProtocolError.unsupportedVersion(version)
        }
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ready":
            self = .ready
        case "addComment":
            let line = try container.decode(Int.self, forKey: .line)
            guard line >= 1 else { throw BridgeProtocolError.invalidLineNumber(line) }
            let side = try container.decode(BridgeSide.self, forKey: .side)
            let startLine = try container.decodeIfPresent(Int.self, forKey: .startLine)
            if let startLine {
                guard startLine >= 1 else { throw BridgeProtocolError.invalidLineNumber(startLine) }
                guard startLine <= line else {
                    throw BridgeProtocolError.startLineAfterLine(startLine: startLine, line: line)
                }
            }
            self = .addComment(line: line, side: side, startLine: startLine)
        case "commentClicked":
            let threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
            let localID = try container.decodeIfPresent(String.self, forKey: .localID)
            switch (threadID, localID) {
            case (.some(let thread), .none):
                guard !thread.isEmpty else { throw BridgeProtocolError.emptyField("threadID") }
                self = .commentClicked(.thread(thread))
            case (.none, .some(let local)):
                guard !local.isEmpty else { throw BridgeProtocolError.emptyField("localID") }
                self = .commentClicked(.draft(local))
            default:
                throw BridgeProtocolError.ambiguousCommentTarget
            }
        case "viewportChanged":
            let line = try container.decode(Int.self, forKey: .firstVisibleLine)
            guard line >= 1 else { throw BridgeProtocolError.invalidLineNumber(line) }
            self = .viewportChanged(firstVisibleLine: line)
        default:
            throw BridgeProtocolError.unknownMessageType(type)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BridgeProtocol.version, forKey: .v)
        try container.encode(messageType, forKey: .type)
        switch self {
        case .ready:
            break
        case .addComment(let line, let side, let startLine):
            try container.encode(line, forKey: .line)
            try container.encode(side, forKey: .side)
            try container.encodeIfPresent(startLine, forKey: .startLine)
        case .commentClicked(let target):
            switch target {
            case .thread(let id): try container.encode(id, forKey: .threadID)
            case .draft(let id): try container.encode(id, forKey: .localID)
            }
        case .viewportChanged(let firstVisibleLine):
            try container.encode(firstVisibleLine, forKey: .firstVisibleLine)
        }
    }
}

// MARK: - Transport encoding

extension DiffViewerCommand {
    /// Encodes the message as a JSON object literal that can be embedded in
    /// `shepherd.receive(…)`.
    ///
    /// The two JavaScript line terminators that are legal in JSON strings are escaped so the
    /// literal is valid on every engine.
    /// - Returns: The JSON text.
    /// - Throws: An encoding error if the message cannot be serialised.
    func javaScriptLiteral() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
