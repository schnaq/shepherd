import Foundation
import XCTest

@testable import Shepherd

/// The German String Catalog actually reaches the app bundle and is actually consulted (ADR 0022).
///
/// `Scripts/check-localization.py` is the exhaustive gate — it walks every call site in
/// `Shepherd/` and every entry in `Shepherd/Resources/Localizable.xcstrings`, and it runs on the
/// Linux job where there is no Xcode. What it *cannot* see is the half of the pipeline that only
/// exists once Xcode has built something: that `project.yml` puts the catalog in the app target's
/// resources phase, that `xcstringstool` compiled a `de.lproj` out of it, and that a
/// `String(localized:)` at runtime resolves through that table rather than falling back to its
/// key. All three fail *silently* — the app shows English — so a build check cannot notice them
/// and the whole feature can be broken with a green CI. This test is the one assertion that only
/// a built bundle can make, which is why it is three keys rather than eight hundred: coverage of
/// the catalog's contents lives in the Python gate, coverage of the *wiring* lives here.
///
/// The keys below are asserted against literal German, so they are also a canary for a
/// translation being silently dropped in a merge. They are picked to exercise the three shapes
/// that behave differently at lookup time:
///
/// - a plain key whose German differs from its English (a table hit);
/// - a second one from a different file, so a single stale entry cannot make this pass;
/// - an interpolated key, where the *lookup* key is `Comment on line %lld` while the *argument*
///   has to survive the substitution — the failure mode a plain key cannot show is a German
///   value whose specifier disagrees with the key's, which yields a wrong number rather than a
///   missing string.
///
/// `String(localized:table:bundle:locale:comment:)` (macOS 13+) is used with `table: nil` for the
/// default `Localizable` table, `bundle: .main` — the app bundle, because `ShepherdTests` is
/// hosted by the app target, not the bundle these tests are compiled into — and an explicit
/// `locale:`, which is what makes the assertion independent of the machine running it.
@MainActor
final class LocalizationTests: XCTestCase {
    /// German, regardless of what the runner's own language is.
    private let german = Locale(identifier: "de")
    /// The source language, where every key stands for itself.
    private let english = Locale(identifier: "en")

    // MARK: - German

    func testPlainKeysResolveToGerman() {
        // `Support/DesignComponents.swift` — a smart-view name on the rail.
        let smartView = String(
            localized: "Needs my review",
            table: nil,
            bundle: .main,
            locale: german
        )
        XCTAssertEqual(smartView, "Braucht mein Review")

        // `Features/Digest/DigestPresentation.swift` — the morning digest's greeting, in a
        // different file so that one surviving entry cannot carry this test on its own.
        let greeting = String(
            localized: "Good morning",
            table: nil,
            bundle: .main,
            locale: german
        )
        XCTAssertEqual(greeting, "Guten Morgen")
    }

    func testInterpolatedKeyResolvesToGermanAndKeepsItsArgument() {
        // The literal below is `Comment on line %lld` once the compiler has derived the key, and
        // the German value carries the same specifier — so the number has to come out unchanged.
        let line = 42
        let composed = String(
            localized: "Comment on line \(line)",
            table: nil,
            bundle: .main,
            locale: german
        )
        XCTAssertEqual(composed, "Kommentar zu Zeile 42")
    }

    // MARK: - English

    func testEnglishRoundTripsTheSourceKey() {
        // No `en` string unit is written for a plain key: the key *is* the English string
        // (ADR 0022), and a second copy of it in the catalog could only ever drift. So the
        // English lookup has to give the key back verbatim — which is also the fallback a
        // missing translation lands on, and therefore the reason a missing one is invisible.
        let smartView = String(
            localized: "Needs my review",
            table: nil,
            bundle: .main,
            locale: english
        )
        XCTAssertEqual(smartView, "Needs my review")

        let line = 42
        let composed = String(
            localized: "Comment on line \(line)",
            table: nil,
            bundle: .main,
            locale: english
        )
        XCTAssertEqual(composed, "Comment on line 42")
    }
}
