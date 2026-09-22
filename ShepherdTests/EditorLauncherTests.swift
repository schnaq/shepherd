import Foundation
import XCTest

@testable import Shepherd

/// "Open in editor" (ADR 0039): the URL each editor gets, the argv a custom command becomes, and
/// where a pull request's path lands in the user's clone.
///
/// Everything here is the pure half; `EditorOpener`, which hands the result to `NSWorkspace` or
/// `Process`, has no decision of its own left to test.
final class EditorLauncherTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/Users/alex/code/review/Sources/App/Main.swift")

    // MARK: - URL schemes

    func testVisualStudioCodeGetsItsFileURLWithTheLine() {
        XCTAssertEqual(
            EditorLauncher.url(kind: .visualStudioCode, file: file, line: 42)?.absoluteString,
            "vscode://file/Users/alex/code/review/Sources/App/Main.swift:42"
        )
    }

    func testCursorIsVisualStudioCodesShapeUnderItsOwnScheme() {
        XCTAssertEqual(
            EditorLauncher.url(kind: .cursor, file: file, line: 7)?.absoluteString,
            "cursor://file/Users/alex/code/review/Sources/App/Main.swift:7"
        )
    }

    func testWithoutALineTheSuffixIsLeftOffRatherThanSentEmpty() {
        XCTAssertEqual(
            EditorLauncher.url(kind: .visualStudioCode, file: file, line: nil)?.absoluteString,
            "vscode://file/Users/alex/code/review/Sources/App/Main.swift"
        )
        // A zero or negative line is not a line: the diff never produces one, but a caller that
        // did must not send `:0`, which VS Code reads as an invalid position.
        XCTAssertEqual(
            EditorLauncher.url(kind: .intelliJ, file: file, line: 0)?.absoluteString,
            "idea://open?file=/Users/alex/code/review/Sources/App/Main.swift"
        )
    }

    func testIntelliJGetsTheOpenURLWithAOneBasedLine() {
        XCTAssertEqual(
            EditorLauncher.url(kind: .intelliJ, file: file, line: 42)?.absoluteString,
            "idea://open?file=/Users/alex/code/review/Sources/App/Main.swift&line=42"
        )
    }

    func testAPathWithSpacesAndSeparatorsIsEncodedRatherThanSplit() {
        let awkward = URL(fileURLWithPath: "/Users/alex/My Code/a&b=c+d #1;x:y.swift")
        XCTAssertEqual(
            EditorLauncher.url(kind: .visualStudioCode, file: awkward, line: 3)?.absoluteString,
            // `:` inside the path is escaped, so the only bare colon is the one before the line.
            "vscode://file/Users/alex/My%20Code/a&b=c+d%20%231%3Bx%3Ay.swift:3"
        )
        XCTAssertEqual(
            EditorLauncher.url(kind: .intelliJ, file: awkward, line: 3)?.absoluteString,
            // `&`, `=` and `+` would be read as query separators, so they are escaped too.
            "idea://open?file=/Users/alex/My%20Code/a%26b%3Dc%2Bd%20%231%3Bx%3Ay.swift&line=3"
        )
    }

    func testTheTwoKindsThatAreNotOneApplicationHaveNoURL() {
        XCTAssertNil(EditorLauncher.url(kind: .systemDefault, file: file, line: 1))
        XCTAssertNil(EditorLauncher.url(kind: .custom, file: file, line: 1))
    }

    // MARK: - Launch plans

    func testTheDefaultOpensTheFileTheWayFinderWould() throws {
        XCTAssertEqual(EditorConfiguration().kind, .systemDefault)
        XCTAssertEqual(
            try EditorLauncher.launch(for: EditorConfiguration(), file: file, line: 12),
            .systemDefault(file)
        )
    }

    func testAURLEditorFallsBackToItsOwnBundleWhenTheSchemeIsUnclaimed() throws {
        let launch = try EditorLauncher.launch(
            for: EditorConfiguration(kind: .intelliJ),
            file: file,
            line: 12
        )
        guard case .url(_, let fallbackFile, let bundles) = launch else {
            return XCTFail("expected a URL launch, got \(launch)")
        }
        XCTAssertEqual(fallbackFile, file)
        // Ultimate first, then Community: whichever this Mac has opens the file.
        XCTAssertEqual(bundles, ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"])
    }

    func testTheBundleIdentifiersAreTheOnesTheEditorsShipWith() {
        XCTAssertEqual(EditorKind.visualStudioCode.bundleIdentifiers, ["com.microsoft.VSCode"])
        XCTAssertEqual(EditorKind.cursor.bundleIdentifiers, ["com.todesktop.230313mzl4w4u92"])
        XCTAssertTrue(EditorKind.systemDefault.bundleIdentifiers.isEmpty)
        XCTAssertTrue(EditorKind.custom.bundleIdentifiers.isEmpty)
    }

    // MARK: - Custom command

    func testACustomCommandIsSplitFirstAndSubstitutedAfter() throws {
        let spaced = URL(fileURLWithPath: "/Users/alex/My Code/it's; rm -rf ~.swift")
        let invocation = try EditorLauncher.customInvocation(
            template: "/usr/local/bin/code --goto {file}:{line}",
            file: spaced,
            line: 9
        )
        XCTAssertEqual(invocation.executable.path, "/usr/local/bin/code")
        // One argument, whatever the path contains: no shell ever sees it.
        XCTAssertEqual(
            invocation.arguments,
            ["--goto", "/Users/alex/My Code/it's; rm -rf ~.swift:9"]
        )
    }

    func testAnUnknownLineBecomesOneRatherThanNothing() throws {
        let invocation = try EditorLauncher.customInvocation(
            template: "'/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl' {file}:{line}",
            file: file,
            line: nil
        )
        XCTAssertEqual(
            invocation.executable.path,
            "/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl"
        )
        XCTAssertEqual(invocation.arguments, ["\(file.path):1"])
    }

    func testATildeInTheBinaryIsExpanded() throws {
        let invocation = try EditorLauncher.customInvocation(
            template: "~/bin/edit {file}",
            file: file,
            line: 2
        )
        XCTAssertFalse(invocation.executable.path.hasPrefix("~"))
        XCTAssertTrue(invocation.executable.path.hasSuffix("/bin/edit"))
        XCTAssertEqual(invocation.arguments, [file.path])
    }

    func testAPathContainingThePlaceholderTextIsNotRewrittenTwice() throws {
        let odd = URL(fileURLWithPath: "/tmp/{line}/a.swift")
        let invocation = try EditorLauncher.customInvocation(
            template: "/usr/bin/edit {file} +{line}",
            file: odd,
            line: 5
        )
        XCTAssertEqual(invocation.arguments, ["/tmp/{line}/a.swift", "+5"])
    }

    func testABareCommandNameIsRefusedRatherThanLookedUp() {
        XCTAssertThrowsError(
            try EditorLauncher.customInvocation(template: "code --goto {file}", file: file, line: 1)
        ) { error in
            XCTAssertEqual(error as? EditorLauncher.Failure, .bareExecutable("code"))
        }
    }

    func testAnEmptyOrPlaceholderlessCommandIsRefused() {
        XCTAssertThrowsError(
            try EditorLauncher.customInvocation(template: "   ", file: file, line: 1)
        ) { error in
            XCTAssertEqual(error as? EditorLauncher.Failure, .emptyTemplate)
        }
        XCTAssertThrowsError(
            try EditorLauncher.customInvocation(template: "/usr/bin/open -a Xcode", file: file, line: 1)
        ) { error in
            XCTAssertEqual(error as? EditorLauncher.Failure, .templateMissingFilePlaceholder)
        }
    }

    func testAnUnterminatedQuoteIsReportedAsATemplateError() {
        XCTAssertThrowsError(
            try EditorLauncher.customInvocation(template: "/usr/bin/edit '{file}", file: file, line: 1)
        ) { error in
            guard case .template = error as? EditorLauncher.Failure else {
                return XCTFail("expected a template error, got \(error)")
            }
        }
    }

    // MARK: - Resolving the path in the clone

    func testNoLinkedCheckoutIsItsOwnOutcome() {
        XCTAssertEqual(
            EditorFileTarget.resolve(checkout: nil, relativePath: "a.swift", fileExists: { _ in true }),
            .noCheckout
        )
    }

    func testAFileTheCheckoutHasIsOpenedWhereItIs() {
        let checkout = URL(fileURLWithPath: "/Users/alex/code/review")
        XCTAssertEqual(
            EditorFileTarget.resolve(
                checkout: checkout,
                relativePath: "Sources/App/Main.swift",
                fileExists: { $0 == "/Users/alex/code/review/Sources/App/Main.swift" }
            ),
            .file(file)
        )
    }

    func testAFileTheCheckoutLacksFallsBackToTheCheckout() {
        let checkout = URL(fileURLWithPath: "/Users/alex/code/review")
        XCTAssertEqual(
            EditorFileTarget.resolve(
                checkout: checkout,
                relativePath: "Sources/New.swift",
                fileExists: { _ in false }
            ),
            .missingFile(
                checkout: checkout,
                expected: URL(fileURLWithPath: "/Users/alex/code/review/Sources/New.swift")
            )
        )
    }

    func testAPathThatClimbsOutOfTheCheckoutIsNeverOpened() {
        let checkout = URL(fileURLWithPath: "/Users/alex/code/review")
        let target = EditorFileTarget.resolve(
            checkout: checkout,
            relativePath: "../../.ssh/id_ed25519",
            // Even when the file exists: it is outside the folder the user chose.
            fileExists: { _ in true }
        )
        guard case .missingFile(let root, _) = target else {
            return XCTFail("expected the path to be refused, got \(target)")
        }
        XCTAssertEqual(root, checkout)
        // A sibling whose name merely starts with the checkout's is outside it too.
        let sibling = EditorFileTarget.resolve(
            checkout: checkout,
            relativePath: "../review-other/a.swift",
            fileExists: { _ in true }
        )
        guard case .missingFile = sibling else {
            return XCTFail("expected the sibling to be refused, got \(sibling)")
        }
    }

    // MARK: - Stored shape

    func testTheConfigurationDecodesTolerantly() throws {
        // An unknown kind from a newer build costs the kind, not the command.
        let newer = Data(#"{"kind":"zed","customCommandTemplate":"/usr/bin/zed {file}"}"#.utf8)
        let decoded = try JSONDecoder().decode(EditorConfiguration.self, from: newer)
        XCTAssertEqual(decoded.kind, .systemDefault)
        XCTAssertEqual(decoded.customCommandTemplate, "/usr/bin/zed {file}")
        // And an empty object is the default.
        XCTAssertEqual(
            try JSONDecoder().decode(EditorConfiguration.self, from: Data("{}".utf8)),
            EditorConfiguration()
        )
    }

    @MainActor
    func testTheSettingIsStoredUnderTheEditorKey() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EditorLauncherTests-\(UUID())"))
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.editor, EditorConfiguration())
        settings.editor = EditorConfiguration(kind: .visualStudioCode)
        XCTAssertNotNil(defaults.data(forKey: "editor.configuration"))
        XCTAssertEqual(AppSettings(defaults: defaults).editor.kind, .visualStudioCode)
    }
}
