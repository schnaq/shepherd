import XCTest

@testable import Shepherd

/// Decodes **the shared fixture corpus** in `web/diff-viewer/fixtures/`.
///
/// The web side runs the same files through `parseInbound`/`parseOutbound`
/// (`web/diff-viewer/tests/fixtures.test.ts`); this suite is the Swift half of that contract.
/// The directory is walked rather than listed, so a fixture added on the web side fails here
/// until `BridgeProtocol.swift` understands it.
final class BridgeProtocolTests: XCTestCase {
    /// Message types that travel Swift → web.
    private static let commandTypes: Set<String> = [
        "loadFile", "setTheme", "setThreads", "setDraftComments", "revealLine", "focusEditor",
    ]

    /// Message types that travel web → Swift.
    private static let eventTypes: Set<String> = [
        "ready", "addComment", "commentClicked", "viewportChanged",
    ]

    private func fixtureURLs() throws -> [URL] {
        let bundle = Bundle(for: BridgeProtocolTests.self)
        guard let directory = bundle.url(forResource: "fixtures", withExtension: nil) else {
            XCTFail("The fixtures folder reference is missing from the test bundle")
            return []
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    private func messageType(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .split(separator: ".")
            .first
            .map(String.init) ?? ""
    }

    func testFixtureDirectoryIsPresentAndCovered() throws {
        let urls = try fixtureURLs()
        XCTAssertFalse(urls.isEmpty, "No bridge fixtures were copied into the test bundle")
        let types = Set(urls.map(messageType))
        for expected in Self.commandTypes.union(Self.eventTypes) {
            XCTAssertTrue(types.contains(expected), "No fixture covers “\(expected)”")
        }
    }

    func testValidFixturesDecodeAndRoundTrip() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for url in try fixtureURLs() {
            let name = url.lastPathComponent
            guard name.contains(".valid") else { continue }
            let data = try Data(contentsOf: url)
            let type = messageType(of: url)

            if Self.commandTypes.contains(type) {
                let decoded = try decoder.decode(DiffViewerCommand.self, from: data)
                XCTAssertEqual(decoded.messageType, type, "\(name)")
                let reencoded = try encoder.encode(decoded)
                let again = try decoder.decode(DiffViewerCommand.self, from: reencoded)
                XCTAssertEqual(decoded, again, "\(name) did not round-trip")
            } else if Self.eventTypes.contains(type) {
                let decoded = try decoder.decode(DiffViewerEvent.self, from: data)
                XCTAssertEqual(decoded.messageType, type, "\(name)")
                let reencoded = try encoder.encode(decoded)
                let again = try decoder.decode(DiffViewerEvent.self, from: reencoded)
                XCTAssertEqual(decoded, again, "\(name) did not round-trip")
            } else {
                XCTFail("Fixture \(name) has an unknown message type “\(type)”")
            }
        }
    }

    func testInvalidFixturesAreRejected() throws {
        let decoder = JSONDecoder()

        for url in try fixtureURLs() {
            let name = url.lastPathComponent
            guard name.contains(".invalid") else { continue }
            let data = try Data(contentsOf: url)
            let type = messageType(of: url)

            if Self.commandTypes.contains(type) {
                XCTAssertThrowsError(
                    try decoder.decode(DiffViewerCommand.self, from: data),
                    "\(name) must be rejected"
                )
            } else if Self.eventTypes.contains(type) {
                XCTAssertThrowsError(
                    try decoder.decode(DiffViewerEvent.self, from: data),
                    "\(name) must be rejected"
                )
            } else {
                XCTFail("Fixture \(name) has an unknown message type “\(type)”")
            }
        }
    }

    // MARK: - Individual guarantees the fixtures encode

    func testLoadFileDecodesEveryField() throws {
        let json = """
            {"v":1,"type":"loadFile","path":"a/b.swift","language":"swift",
             "original":"one\\n","modified":"two\\n","mode":"sideBySide","wrap":true}
            """
        let message = try JSONDecoder().decode(DiffViewerCommand.self, from: Data(json.utf8))
        guard case .loadFile(let payload) = message else {
            return XCTFail("Expected a loadFile message")
        }
        XCTAssertEqual(payload.path, "a/b.swift")
        XCTAssertEqual(payload.language, "swift")
        XCTAssertEqual(payload.original, "one\n")
        XCTAssertEqual(payload.modified, "two\n")
        XCTAssertEqual(payload.mode, .sideBySide)
        XCTAssertTrue(payload.wrap)
    }

    func testLoadFileCommentableLinesAreOptionalAndAdditive() throws {
        // A payload without the field still decodes: the field is additive, which is why the
        // protocol version stays 1 and the older fixtures keep working on both sides.
        let without = """
            {"v":1,"type":"loadFile","path":"a.sql","language":"sql",
             "original":"x","modified":"y","mode":"inline","wrap":false}
            """
        let message = try JSONDecoder().decode(DiffViewerCommand.self, from: Data(without.utf8))
        guard case .loadFile(let bare) = message else {
            return XCTFail("Expected a loadFile message")
        }
        XCTAssertNil(bare.commentableLines)
        let reencoded = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("commentableLines"), "nil is omitted, not sent as null")

        let with = """
            {"v":1,"type":"loadFile","path":"a.sql","language":"sql",
             "original":"x","modified":"y","mode":"inline","wrap":false,
             "commentableLines":{"left":[1,2],"right":[1,2,3]}}
            """
        let full = try JSONDecoder().decode(DiffViewerCommand.self, from: Data(with.utf8))
        guard case .loadFile(let payload) = full else {
            return XCTFail("Expected a loadFile message")
        }
        XCTAssertEqual(payload.commentableLines?.left, [1, 2])
        XCTAssertEqual(payload.commentableLines?.right, [1, 2, 3])
    }

    func testCommentableLinesMustBeOneBased() {
        let json = """
            {"v":1,"type":"loadFile","path":"a.sql","language":"sql",
             "original":"x","modified":"y","mode":"inline","wrap":false,
             "commentableLines":{"left":[0],"right":[1]}}
            """
        XCTAssertThrowsError(
            try JSONDecoder().decode(DiffViewerCommand.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(error as? BridgeProtocolError, .invalidLineNumber(0))
        }
    }

    func testWrongProtocolVersionIsRejected() {
        let json = #"{"v":2,"type":"ready"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(DiffViewerEvent.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(error as? BridgeProtocolError, .unsupportedVersion(2))
        }
    }

    func testCommentClickedNeedsExactlyOneTarget() {
        let both = #"{"v":1,"type":"commentClicked","threadID":"a","localID":"b"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(DiffViewerEvent.self, from: Data(both.utf8))
        ) { error in
            XCTAssertEqual(error as? BridgeProtocolError, .ambiguousCommentTarget)
        }

        let neither = #"{"v":1,"type":"commentClicked"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(DiffViewerEvent.self, from: Data(neither.utf8))
        )
    }

    func testAddCommentRejectsAStartLineAfterTheLine() {
        let json = #"{"v":1,"type":"addComment","line":7,"side":"right","startLine":9}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(DiffViewerEvent.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(
                error as? BridgeProtocolError,
                .startLineAfterLine(startLine: 9, line: 7)
            )
        }
    }

    func testAddCommentWithoutStartLineOmitsItWhenEncoding() throws {
        let message = DiffViewerEvent.addComment(line: 7, side: .right, startLine: nil)
        let data = try JSONEncoder().encode(message)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("startLine"))
    }

    func testDraftCommentLineMustBeOneBased() {
        let json = """
            {"v":1,"type":"setDraftComments","comments":[
              {"localID":"A","line":0,"side":"right","body":"x"}]}
            """
        XCTAssertThrowsError(
            try JSONDecoder().decode(DiffViewerCommand.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(error as? BridgeProtocolError, .invalidLineNumber(0))
        }
    }

    func testUnknownMessageTypeIsRejected() {
        let json = #"{"v":1,"type":"teleport"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(DiffViewerCommand.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(error as? BridgeProtocolError, .unknownMessageType("teleport"))
        }
    }

    func testJavaScriptLiteralEscapesLineSeparators() throws {
        let message = DiffViewerCommand.loadFile(
            DiffViewerCommand.LoadFile(
                path: "a.txt",
                language: "plaintext",
                original: "before\u{2028}after",
                modified: "x",
                mode: .inline,
                wrap: false
            )
        )
        let literal = try message.javaScriptLiteral()
        XCTAssertTrue(literal.contains("\\u2028"))
        XCTAssertFalse(literal.contains("\u{2028}"))
    }

    func testScriptMessageBodyDecoding() {
        let body: [String: Any] = ["v": 1, "type": "viewportChanged", "firstVisibleLine": 128]
        let event = DiffViewerView.Coordinator.decode(body: body)
        XCTAssertEqual(event, .viewportChanged(firstVisibleLine: 128))
    }
}

/// The one navigation the diff viewer is allowed to perform (ADR 0003).
///
/// The viewer renders somebody else's text, and `MarkdownHTML` deliberately lets `https://` links
/// through, so a review comment can put a clickable link inside the web view that holds the
/// `shepherd` message handler. `WKWebView`'s default answer to a click is *allow*, so the boundary
/// the ADR always assumed is asserted here: file URLs inside the bundle directory, and nothing
/// else. The delegate method itself needs a real `WKNavigationAction`, which cannot be
/// constructed; what it decides with is this function.
final class DiffViewerNavigationBoundaryTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Applications/Shepherd.app/Contents/Resources/DiffViewer/dist", isDirectory: true)

    private func isInside(_ url: URL, root: URL? = nil) -> Bool {
        DiffViewerView.Coordinator.isInsideBundle(url, root: root ?? self.root)
    }

    func testTheBundlesOwnFilesLoad() {
        XCTAssertTrue(isInside(root.appendingPathComponent("index.html")))
        XCTAssertTrue(isInside(root.appendingPathComponent("assets/monaco.js")))
        XCTAssertTrue(isInside(root), "the directory itself is inside itself")
    }

    func testAWebPageIsRefusedHoweverItArrives() {
        // The attack this closes: a link in a pull-request description or a review comment,
        // clicked inside the viewer, navigating the view that owns the bridge to a stranger's
        // page — which could then post forged bridge messages from the same configuration.
        XCTAssertFalse(isInside(URL(string: "https://attacker.example/page")!))
        XCTAssertFalse(isInside(URL(string: "http://attacker.example/page")!))
        XCTAssertFalse(isInside(URL(string: "about:blank")!))
        XCTAssertFalse(isInside(URL(string: "data:text/html,<script>alert(1)</script>")!))
    }

    func testAFileOutsideTheBundleIsRefusedIncludingBySpellingItsWayOut() {
        XCTAssertFalse(isInside(URL(fileURLWithPath: "/etc/passwd")))
        XCTAssertFalse(
            isInside(root.appendingPathComponent("../../../../../../etc/passwd")),
            "a traversal is resolved before the comparison, not compared as a string"
        )
        XCTAssertFalse(
            isInside(URL(fileURLWithPath: "/Applications/Shepherd.app/Contents/Resources/DiffViewer/dist-elsewhere/index.html")),
            "a sibling whose name starts the same way is not inside"
        )
    }

    func testAViewWithNoBundleNavigatesNowhere() {
        XCTAssertFalse(
            DiffViewerView.Coordinator.isInsideBundle(
                URL(fileURLWithPath: "/tmp/index.html"),
                root: nil
            ),
            "a view that could not find its own bundle allows nothing at all"
        )
    }
}
