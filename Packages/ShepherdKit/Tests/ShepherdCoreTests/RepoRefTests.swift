import XCTest
@testable import ShepherdCore

/// What ``RepoRef/parse(userInput:)`` accepts from a person typing or pasting into a field.
///
/// The interesting half of these is what it *refuses*: the parser is tolerant about shape and
/// strict about content, because whatever comes out of it goes into a GitHub search expression.
final class RepoRefTests: XCTestCase {
    // MARK: - The plain form

    func testParsesOwnerAndName() {
        XCTAssertEqual(RepoRef.parse(userInput: "schnaq/unlock")?.fullName, "schnaq/unlock")
    }

    func testIgnoresSurroundingWhitespace() {
        XCTAssertEqual(RepoRef.parse(userInput: "  schnaq/unlock\n")?.fullName, "schnaq/unlock")
    }

    func testKeepsTheCasingItWasGiven() {
        XCTAssertEqual(RepoRef.parse(userInput: "Schnaq/Review")?.fullName, "Schnaq/Review")
    }

    // MARK: - Pasted URLs

    func testParsesAnHTTPSURL() {
        let parsed = RepoRef.parse(
            userInput: "https://github.com/digital-h-gmbh/thyssenkrupp-packaging-steel-app"
        )
        XCTAssertEqual(parsed?.fullName, "digital-h-gmbh/thyssenkrupp-packaging-steel-app")
    }

    func testParsesAnHTTPURL() {
        XCTAssertEqual(RepoRef.parse(userInput: "http://github.com/a/b")?.fullName, "a/b")
    }

    func testParsesAHostWithoutAScheme() {
        XCTAssertEqual(RepoRef.parse(userInput: "github.com/a/b")?.fullName, "a/b")
    }

    func testParsesTheWWWHost() {
        XCTAssertEqual(RepoRef.parse(userInput: "https://www.github.com/a/b")?.fullName, "a/b")
    }

    func testIgnoresATrailingSlash() {
        XCTAssertEqual(RepoRef.parse(userInput: "https://github.com/a/b/")?.fullName, "a/b")
    }

    /// The URL of a pull request is the one people have in the clipboard most often.
    func testParsesDeeperPathsDownToTheRepository() {
        XCTAssertEqual(
            RepoRef.parse(userInput: "https://github.com/a/b/pull/123")?.fullName,
            "a/b"
        )
    }

    func testIgnoresAQueryAndFragment() {
        XCTAssertEqual(
            RepoRef.parse(userInput: "https://github.com/a/b?tab=readme-ov-file#install")?.fullName,
            "a/b"
        )
    }

    // MARK: - Clone URLs

    func testParsesAnHTTPSCloneURL() {
        XCTAssertEqual(RepoRef.parse(userInput: "https://github.com/a/b.git")?.fullName, "a/b")
    }

    func testParsesAnSSHRemote() {
        XCTAssertEqual(RepoRef.parse(userInput: "git@github.com:a/b.git")?.fullName, "a/b")
    }

    func testParsesAnSSHURL() {
        XCTAssertEqual(RepoRef.parse(userInput: "ssh://git@github.com/a/b.git")?.fullName, "a/b")
    }

    /// A leading dot is a real repository name — `.github` is on half the organisations on the
    /// site — so the clone suffix comes off only when something is left in front of it.
    func testKeepsDotLeadingNames() {
        XCTAssertEqual(RepoRef.parse(userInput: "https://github.com/a/.github")?.fullName, "a/.github")
        XCTAssertEqual(RepoRef.parse(userInput: "https://github.com/a/.git")?.fullName, "a/.git")
    }

    // MARK: - What it refuses

    func testRefusesAnotherHost() {
        XCTAssertNil(RepoRef.parse(userInput: "https://gitlab.com/a/b"))
    }

    /// The shape a host-confusion attempt takes: the real host is `evil.com`, and `github.com`
    /// is just a path segment on it.
    func testRefusesGitHubAsAPathSegmentOfAnotherHost() {
        XCTAssertNil(RepoRef.parse(userInput: "https://evil.com/github.com/a/b"))
    }

    /// Without a host there is no reason to believe the third segment is noise, so a three-part
    /// path is a typo rather than a repository.
    func testRefusesThreeSegmentsWithoutAHost() {
        XCTAssertNil(RepoRef.parse(userInput: "a/b/c"))
    }

    func testRefusesAnOwnerOnItsOwn() {
        XCTAssertNil(RepoRef.parse(userInput: "https://github.com/schnaq"))
        XCTAssertNil(RepoRef.parse(userInput: "schnaq"))
    }

    func testRefusesEmptyInput() {
        XCTAssertNil(RepoRef.parse(userInput: ""))
        XCTAssertNil(RepoRef.parse(userInput: "   "))
    }

    /// The strict half, unchanged: whatever shape the text arrived in, the owner and the name
    /// still have to be the ASCII GitHub allows — a homoglyph must not reach a search query.
    func testRefusesNonASCIINames() {
        XCTAssertNil(RepoRef.parse(userInput: "https://github.com/schnaq/ünlock"))
        XCTAssertNil(RepoRef.parse(userInput: "schnaq/un lock"))
    }

    func testRefusesTraversalShapedNames() {
        XCTAssertNil(RepoRef.parse(userInput: "a/.."))
    }
}
