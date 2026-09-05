import XCTest

@testable import Shepherd

/// The repository path → Monaco language id mapping.
///
/// This case has a file to itself because it is the leftover of a split: it used to sit at the
/// end of `PatchReconstructorTests`, and when those tests moved into ShepherdCore to gain the
/// Linux leg it could not follow, because `MonacoLanguage` is app-target code.
final class MonacoLanguageTests: XCTestCase {
    func testLanguageMapping() {
        XCTAssertEqual(MonacoLanguage.id(forPath: "Sources/App/Main.swift"), "swift")
        XCTAssertEqual(MonacoLanguage.id(forPath: "web/src/main.ts"), "typescript")
        XCTAssertEqual(MonacoLanguage.id(forPath: "Dockerfile"), "dockerfile")
        XCTAssertEqual(MonacoLanguage.id(forPath: "Cargo.toml"), "toml")
        XCTAssertEqual(MonacoLanguage.id(forPath: "LICENSE"), "plaintext")
        XCTAssertEqual(MonacoLanguage.id(forPath: "deploy/values.YAML"), "yaml")
    }
}
