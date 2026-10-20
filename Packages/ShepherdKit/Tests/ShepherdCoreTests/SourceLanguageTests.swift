import XCTest

@testable import ShepherdCore

/// The repository path → language mapping both diff renderers read.
///
/// These cases used to be `MonacoLanguageTests` in the app target, the leftover of the split that
/// moved `PatchReconstructorTests` into this package: the table was app code, so it could not
/// follow. It moved here with the table (ADR 0044), and gained its Linux leg on the way.
final class SourceLanguageTests: XCTestCase {
    func testMonacoIDs() {
        XCTAssertEqual(SourceLanguage(path: "Sources/App/Main.swift").monacoID, "swift")
        XCTAssertEqual(SourceLanguage(path: "web/src/main.ts").monacoID, "typescript")
        XCTAssertEqual(SourceLanguage(path: "Dockerfile").monacoID, "dockerfile")
        XCTAssertEqual(SourceLanguage(path: "Cargo.toml").monacoID, "toml")
        XCTAssertEqual(SourceLanguage(path: "LICENSE").monacoID, "plaintext")
        XCTAssertEqual(SourceLanguage(path: "deploy/values.YAML").monacoID, "yaml")
        XCTAssertEqual(SourceLanguage(path: "Sources/Model.m").monacoID, "objective-c")
    }

    func testAStringCatalogIsJSON() {
        XCTAssertEqual(SourceLanguage(path: "Shepherd/Resources/Localizable.xcstrings"), .json)
        XCTAssertEqual(SourceLanguage(path: "Shepherd/Resources/Localizable.xcstrings").monacoID, "json")
    }

    func testClojureIsColouredNativelyButPlainInMonaco() {
        // Monaco's bundle registers no Clojure grammar, so handing it "clojure" would only make
        // it fall back by itself; the native tokenizer does colour it.
        XCTAssertEqual(SourceLanguage(path: "src/app/core.cljs"), .clojure)
        XCTAssertEqual(SourceLanguage(path: "deps.edn"), .clojure)
        XCTAssertEqual(SourceLanguage(path: "project.clj"), .clojure)
        XCTAssertEqual(SourceLanguage(path: "src/app/core.clj").monacoID, "plaintext")
    }

    func testAPathWithoutAnExtensionIsPlainText() {
        XCTAssertEqual(SourceLanguage(path: ".env"), .plaintext)
        XCTAssertEqual(SourceLanguage(path: "bin/run"), .plaintext)
    }
}
