import Foundation
import XCTest

@testable import Shepherd

/// What the app decides about Sparkle before Sparkle is ever asked (ADR 0010).
///
/// This is the whole reason `UpdateController` reads its configuration from a dictionary instead
/// of straight from `Bundle`: the interesting cases are the *broken* ones, and every one of them
/// has to end as "updates are off, and here is the reason" rather than as an alert Sparkle puts in
/// front of the user a few seconds after launch. The placeholder that ships in `project.yml` until
/// `generate_keys` has been run is the case that matters most, because it is the state of the
/// repository today.
final class UpdateConfigurationTests: XCTestCase {
    /// A valid ed25519 public key is 32 bytes; any 32 bytes will do for shape checking.
    private static let validKey = Data(repeating: 0x2A, count: 32).base64EncodedString()

    private let feed = "https://github.com/schnaq/review/releases/latest/download/appcast.xml"

    // MARK: - The configured case

    func testFullyConfiguredBuildHasNoProblem() {
        let configuration = UpdateConfiguration(
            info: ["SUFeedURL": feed, "SUPublicEDKey": Self.validKey]
        )
        XCTAssertNil(configuration.problem)
        XCTAssertEqual(configuration.feedURL?.absoluteString, feed)
        XCTAssertEqual(configuration.publicKey, Self.validKey)
    }

    func testWhitespaceAroundTheFeedAndKeyIsTolerated() {
        let configuration = UpdateConfiguration(
            info: ["SUFeedURL": "  \(feed)\n", "SUPublicEDKey": "\n \(Self.validKey) "]
        )
        XCTAssertNil(configuration.problem)
        XCTAssertEqual(configuration.feedURL?.absoluteString, feed)
    }

    // MARK: - The placeholder this repository ships with

    func testProjectPlaceholderKeyDisablesUpdates() {
        let configuration = UpdateConfiguration(
            info: [
                "SUFeedURL": feed,
                "SUPublicEDKey": "REPLACE_WITH_SUPublicEDKey_FROM_generate_keys",
            ]
        )
        XCTAssertEqual(configuration.problem, .unusablePublicKey)
    }

    func testMissingKeyDisablesUpdates() {
        XCTAssertEqual(
            UpdateConfiguration(info: ["SUFeedURL": feed]).problem,
            .unusablePublicKey
        )
        XCTAssertEqual(
            UpdateConfiguration(info: ["SUFeedURL": feed, "SUPublicEDKey": "   "]).problem,
            .unusablePublicKey
        )
    }

    /// A key that decodes as base64 but is the wrong length — a truncated copy-paste — is the one
    /// failure Sparkle would otherwise accept at startup and only reject when verifying a
    /// download, i.e. after the user has waited for one.
    func testKeyOfTheWrongLengthDisablesUpdates() {
        let short = Data(repeating: 0x2A, count: 16).base64EncodedString()
        let long = Data(repeating: 0x2A, count: 64).base64EncodedString()
        XCTAssertFalse(UpdateConfiguration.isUsable(publicKey: short))
        XCTAssertFalse(UpdateConfiguration.isUsable(publicKey: long))
        XCTAssertTrue(UpdateConfiguration.isUsable(publicKey: Self.validKey))
    }

    // MARK: - Feeds

    func testMissingOrUnusableFeedIsReportedBeforeTheKey() {
        // No feed at all: the first thing missing is what the user is told about.
        XCTAssertEqual(
            UpdateConfiguration(info: ["SUPublicEDKey": Self.validKey]).problem,
            .noFeedURL
        )
        // Not a URL, and a relative path, both of which Sparkle would fail on later.
        for candidate in ["", "   ", "appcast.xml", "not a url", "ftp://example.com/appcast.xml"] {
            let configuration = UpdateConfiguration(
                info: ["SUFeedURL": candidate, "SUPublicEDKey": Self.validKey]
            )
            XCTAssertNil(configuration.feedURL, "\(candidate) should not be a usable feed")
            XCTAssertEqual(configuration.problem, .noFeedURL, "\(candidate)")
        }
    }

    /// `http` is allowed so that a maintainer can point a development build at a feed served from
    /// their own machine; the signature check is what protects the download, not the scheme.
    func testLocalHTTPFeedIsUsable() {
        let configuration = UpdateConfiguration(
            info: ["SUFeedURL": "http://localhost:8000/appcast.xml", "SUPublicEDKey": Self.validKey]
        )
        XCTAssertNil(configuration.problem)
    }

    // MARK: - The empty build

    /// A source build of a fork that has configured nothing: no crash, no alert, one reason.
    func testEmptyInfoDictionaryYieldsAReasonRatherThanACrash() {
        let configuration = UpdateConfiguration(info: [:])
        XCTAssertEqual(configuration.problem, .noFeedURL)
        XCTAssertFalse(configuration.problem?.explanation.isEmpty ?? true)
    }
}
