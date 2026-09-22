import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// Every file-priority reason and triage hint has a German phrase, and the English one is the
/// wording ShepherdCore sends to a model (ADR 0022's amendment for the prioritiser's reasons).
///
/// The same shape as `EvidenceFactTextTests`, for the same reason: `Scripts/check-localization.py`
/// proves every key the renderer writes has a German row, but not that every case the prioritiser
/// can produce reaches one of those keys. The German lookup goes through the compiled `de.lproj`
/// as a bundle of its own; the test bundle carries no `Localizable` table, so a lookup there gives
/// the key — the English phrase — back.
@MainActor
final class FilePriorityReasonTextTests: XCTestCase {
    // MARK: - The samples

    /// One reason per case, and per category.
    ///
    /// `requireEveryReasonIsSampled(_:)` keeps this list honest: a new case stops that `switch`
    /// compiling until it has been added here.
    private static let reasons: [FilePriorityReason] = FileCategory.allCases.map { .category($0) } + [
        .securitySensitivePath(hint: "auth"),
        .ciWorkflow,
        .containerBuildFile,
        .entitlements,
        .deletesTestFile,
        .deletesSourceFile,
        .largeChange(lines: 420),
        .sizeableChange(lines: 120),
        .dominatesChanges,
        .newSourceFile,
        .renamed(from: "Sources/Auth/OldSession.swift"),
        .noDiffAvailable,
    ]

    private static let hints: [TriageRiskHint] = [
        .everyFileGenerated,
        .file(path: "Sources/Auth/TokenStore.swift", reasons: [.securitySensitivePath(hint: "auth"), .deletesSourceFile]),
    ]

    // MARK: - Tables

    private func germanTable() throws -> Bundle {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "de", withExtension: "lproj"),
            "no de.lproj in the app bundle: the String Catalog was not compiled for German"
        )
        return try XCTUnwrap(Bundle(url: url), "de.lproj is not loadable as a bundle")
    }

    private var englishTable: Bundle { Bundle(for: Self.self) }

    // MARK: - English

    /// The English rendering is ShepherdCore's wording, so a prompt and the screen of an English
    /// Mac say the same thing.
    func testTheEnglishPhraseIsShepherdCoresWording() {
        for reason in Self.reasons {
            XCTAssertEqual(reason.localizedText(bundle: englishTable), reason.englishText)
        }
        for hint in Self.hints {
            XCTAssertEqual(hint.localizedText(bundle: englishTable), hint.englishText)
        }
    }

    // MARK: - German

    func testEveryReasonHasAGermanRow() throws {
        let german = try germanTable()
        for reason in Self.reasons {
            let translated = reason.localizedText(bundle: german)
            XCTAssertFalse(translated.isEmpty, "\(reason) renders to nothing in German")
            XCTAssertNotEqual(translated, reason.englishText, "no German row for \(reason)")
        }
        for hint in Self.hints {
            XCTAssertNotEqual(hint.localizedText(bundle: german), hint.englishText, "no German row for \(hint)")
        }
    }

    /// Paths, the hint and the line count survive translation untouched.
    func testTheGermanPhraseInterpolatesPathsVerbatim() throws {
        let german = try germanTable()
        XCTAssertTrue(
            FilePriorityReason.renamed(from: "Sources/Auth/OldSession.swift")
                .localizedText(bundle: german).contains("Sources/Auth/OldSession.swift")
        )
        XCTAssertTrue(
            FilePriorityReason.securitySensitivePath(hint: "auth")
                .localizedText(bundle: german).contains("„auth“")
        )
        XCTAssertTrue(FilePriorityReason.largeChange(lines: 420).localizedText(bundle: german).contains("420"))
        XCTAssertTrue(
            TriageRiskHint.file(path: "Sources/Auth/TokenStore.swift", reasons: [.ciWorkflow])
                .localizedText(bundle: german).hasPrefix("Sources/Auth/TokenStore.swift — ")
        )
    }

    // MARK: - Exhaustiveness

    private func requireEveryReasonIsSampled(_ reason: FilePriorityReason) {
        switch reason {
        case .category, .securitySensitivePath, .ciWorkflow, .containerBuildFile, .entitlements,
            .deletesTestFile, .deletesSourceFile, .largeChange, .sizeableChange, .dominatesChanges,
            .newSourceFile, .renamed, .noDiffAvailable:
            break
        }
    }

    func testTheSampleListCoversEveryCase() {
        for reason in Self.reasons { requireEveryReasonIsSampled(reason) }
        XCTAssertEqual(Set(Self.reasons).count, Self.reasons.count)
    }
}
