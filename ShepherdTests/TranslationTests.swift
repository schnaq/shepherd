import Foundation
import XCTest

@testable import Shepherd

/// On-device translation of pull-request text (ADR 0020).
///
/// The two halves worth testing are the two that can be wrong without anybody noticing on screen:
///
/// - **Whether a *Translate* button is offered at all.** The rule set is a pure function
///   (``TranslationOffer/decide(source:target:isPairSupported:)``), so "never offer to translate
///   text that is already in the reader's language" is asserted rather than eyeballed — including
///   the `en-GB` / `en-US` case, where a naive `==` on `Locale.Language` would offer a translation
///   of English into English.
/// - **The cache.** It is keyed by text *and* target language and bounded, and the reviewer can
///   collapse a translation without losing it. A cache that quietly returned another comment's
///   translation would be the one unacceptable failure of this feature.
///
/// Neither half needs a language pack, a network or Apple Intelligence. What is *not* tested here
/// is `TranslationSession` itself: a session only exists inside `.translationTask`, and mocking
/// Apple's translator would assert nothing about Apple's translator.
@MainActor
final class TranslationTests: XCTestCase {
    private let english = Locale.Language(identifier: "en")
    private let german = Locale.Language(identifier: "de")
    private let french = Locale.Language(identifier: "fr")

    // MARK: - Whether to offer a translation

    func testNothingIsOfferedWhenNoLanguageCouldBeDetected() {
        XCTAssertEqual(
            TranslationOffer.decide(source: nil, target: english, isPairSupported: true),
            .undetectable
        )
    }

    func testNothingIsOfferedForTextAlreadyInTheTargetLanguage() {
        XCTAssertEqual(
            TranslationOffer.decide(source: english, target: english, isPairSupported: true),
            .alreadyInTargetLanguage
        )
    }

    func testRegionAndScriptDoNotMakeTwoLanguagesDifferent() {
        XCTAssertEqual(
            TranslationOffer.decide(
                source: Locale.Language(identifier: "en-GB"),
                target: Locale.Language(identifier: "en-US"),
                isPairSupported: true
            ),
            .alreadyInTargetLanguage
        )
        XCTAssertTrue(
            TranslationOffer.isSameLanguage(
                Locale.Language(identifier: "pt-BR"),
                Locale.Language(identifier: "pt-PT")
            )
        )
    }

    func testAnUnsupportedPairIsNamedRatherThanHidden() {
        XCTAssertEqual(
            TranslationOffer.decide(source: german, target: english, isPairSupported: false),
            .unsupportedPair(source: german)
        )
    }

    func testASupportedForeignLanguageIsOffered() {
        XCTAssertEqual(
            TranslationOffer.decide(source: german, target: english, isPairSupported: true),
            .eligible(source: german)
        )
    }

    // MARK: - Detection

    func testAProseCommentIsDetected() {
        let body = """
            Diese Änderung entfernt die alte Fehlerbehandlung und ersetzt sie durch einen \
            erneuten Versuch mit exponentiellem Backoff, damit ein kurzer Netzwerkausfall den \
            Upload nicht abbricht.
            """
        XCTAssertEqual(
            TranslationOffer.detectedLanguage(in: body)?.languageCode?.identifier,
            "de"
        )
    }

    func testAShortCommentIsNotDetectedAtAll() {
        XCTAssertNil(TranslationOffer.detectedLanguage(in: "LGTM"))
        XCTAssertNil(TranslationOffer.detectedLanguage(in: "+1 👍"))
    }

    func testABodyThatIsOnlyCodeIsNotDetected() {
        let body = """
            ```swift
            let result = try await client.upload(payload, to: destination, retrying: policy)
            XCTAssertEqual(result.statusCode, 200)
            ```
            """
        XCTAssertNil(TranslationOffer.detectedLanguage(in: body))
    }

    func testCodeLinksAndMentionsAreStrippedBeforeDetection() {
        let body = """
            Hallo @octocat, siehe https://example.com/build/42 — der Aufruf `assertEquals(a, b)` \
            schlägt fehl.
            ```
            assertEquals(a, b)
            ```
            """
        let prose = TranslationOffer.prose(in: body)
        XCTAssertFalse(prose.contains("assertEquals"))
        XCTAssertFalse(prose.contains("https://"))
        XCTAssertFalse(prose.contains("@octocat"))
        XCTAssertTrue(prose.contains("Hallo"))
        XCTAssertTrue(prose.contains("schlägt fehl"))
    }

    func testAnUnterminatedFenceSwallowsTheRestRatherThanNothing() {
        let prose = TranslationOffer.prose(in: "Vorher\n```\nlet x = 1\nNachher")
        XCTAssertEqual(prose, "Vorher")
    }

    // MARK: - The cache

    func testATranslationIsKeyedByTextAndTargetLanguage() {
        let coordinator = TranslationCoordinator()
        let key = TranslationKey(text: "Guten Morgen", target: english)
        XCTAssertNil(coordinator.state(for: key))

        coordinator.begin(key)
        XCTAssertEqual(coordinator.state(for: key), TranslationState.translating)
        coordinator.finish("Good morning", for: key)
        XCTAssertEqual(coordinator.state(for: key), TranslationState.translated("Good morning"))

        // The same words, another reader's language: a separate entry, never the English one.
        XCTAssertNil(coordinator.state(for: TranslationKey(text: "Guten Morgen", target: french)))
        // Another comment in the same language: also separate.
        XCTAssertNil(coordinator.state(for: TranslationKey(text: "Guten Abend", target: english)))
    }

    func testCollapsingTheBlockKeepsTheTranslation() {
        let coordinator = TranslationCoordinator()
        let key = TranslationKey(text: "Guten Morgen", target: english)
        coordinator.begin(key)
        coordinator.finish("Good morning", for: key)
        XCTAssertTrue(coordinator.isVisible(key))

        coordinator.setVisible(false, for: key)
        XCTAssertFalse(coordinator.isVisible(key))
        XCTAssertEqual(coordinator.state(for: key), TranslationState.translated("Good morning"))

        // Asking again has to show something, so it un-collapses.
        coordinator.begin(key)
        XCTAssertTrue(coordinator.isVisible(key))
    }

    func testAFailureIsKeptSoTheReasonCanBeShown() {
        let coordinator = TranslationCoordinator()
        let key = TranslationKey(text: "Guten Morgen", target: english)
        coordinator.begin(key)
        coordinator.fail("The language pair is not available.", for: key)
        XCTAssertEqual(
            coordinator.state(for: key),
            TranslationState.failed("The language pair is not available.")
        )
    }

    func testTheOldestTranslationIsEvictedWhenTheCacheIsFull() {
        let coordinator = TranslationCoordinator(capacity: 2)
        let first = TranslationKey(text: "eins", target: english)
        let second = TranslationKey(text: "zwei", target: english)
        let third = TranslationKey(text: "drei", target: english)

        coordinator.finish("one", for: first)
        coordinator.finish("two", for: second)
        coordinator.finish("three", for: third)

        XCTAssertEqual(coordinator.count, 2)
        XCTAssertNil(coordinator.state(for: first))
        XCTAssertEqual(coordinator.state(for: second), TranslationState.translated("two"))
        XCTAssertEqual(coordinator.state(for: third), TranslationState.translated("three"))
    }
}
