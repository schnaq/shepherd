import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// How ``AppSettings`` stores saved replies and review templates: order, editing, and the fact that
/// both survive a relaunch.
///
/// The order is the interesting part, which is why it is tested rather than assumed: it is the order
/// of the insert menu *and* the last tie-breaker of the template match, so a
/// reorder that silently did not persist would change which template a repository gets.
@MainActor
final class SavedReplySettingsTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() {
        if !suiteName.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteName = ""
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        suiteName = "com.schnaq.shepherd.tests.savedReplies.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("a fresh suite name always opens")
        }
        return defaults
    }

    func testAFreshInstallHasNoRepliesAndNoTemplates() {
        let settings = AppSettings(defaults: makeDefaults())
        XCTAssertTrue(settings.savedReplies.isEmpty)
        XCTAssertTrue(settings.reviewTemplates.isEmpty)
        XCTAssertTrue(settings.usableSavedReplies.isEmpty)
    }

    func testRepliesAndTemplatesSurviveARelaunchInTheirOrder() {
        let defaults = makeDefaults()
        let first = AppSettings(defaults: defaults)
        first.upsert(savedReply: SavedReply(name: "Needs a test", body: "Please add a test."))
        first.upsert(savedReply: SavedReply(name: "Nit", body: "Naming nit."))
        first.upsert(reviewTemplate: ReviewTemplate(pattern: "schnaq/*", body: "## Checklist"))

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.savedReplies.map(\.name), ["Needs a test", "Nit"])
        XCTAssertEqual(relaunched.savedReplies.map(\.id), first.savedReplies.map(\.id))
        XCTAssertEqual(relaunched.reviewTemplates.map(\.pattern), ["schnaq/*"])
    }

    func testUpsertingAnExistingIdentityEditsTheRowInPlace() {
        let settings = AppSettings(defaults: makeDefaults())
        let reply = SavedReply(name: "Nit", body: "Naming nit.")
        settings.upsert(savedReply: reply)
        settings.upsert(savedReply: SavedReply(id: reply.id, name: "Naming", body: "Rename this."))
        XCTAssertEqual(settings.savedReplies.count, 1)
        XCTAssertEqual(settings.savedReplies.first?.name, "Naming")
        XCTAssertEqual(settings.savedReplies.first?.id, reply.id)
    }

    func testMovingARowSwapsItWithItsNeighbourAndStopsAtTheEnds() {
        let settings = AppSettings(defaults: makeDefaults())
        let a = SavedReply(name: "A", body: "a")
        let b = SavedReply(name: "B", body: "b")
        let c = SavedReply(name: "C", body: "c")
        for reply in [a, b, c] { settings.upsert(savedReply: reply) }

        settings.moveSavedReply(id: c.id, by: -1)
        XCTAssertEqual(settings.savedReplies.map(\.name), ["A", "C", "B"])
        settings.moveSavedReply(id: a.id, by: -1)
        XCTAssertEqual(settings.savedReplies.map(\.name), ["A", "C", "B"])
        settings.moveSavedReply(id: b.id, by: 1)
        XCTAssertEqual(settings.savedReplies.map(\.name), ["A", "C", "B"])
        settings.moveSavedReply(id: UUID(), by: 1)
        XCTAssertEqual(settings.savedReplies.map(\.name), ["A", "C", "B"])
    }

    func testTemplatesReorderTheSameWayAndDelete() {
        let settings = AppSettings(defaults: makeDefaults())
        let owner = ReviewTemplate(pattern: "schnaq/*", body: "owner")
        let everything = ReviewTemplate(pattern: "*", body: "everything")
        settings.upsert(reviewTemplate: owner)
        settings.upsert(reviewTemplate: everything)
        settings.moveReviewTemplate(id: everything.id, by: -1)
        XCTAssertEqual(settings.reviewTemplates.map(\.pattern), ["*", "schnaq/*"])
        settings.deleteReviewTemplate(id: everything.id)
        XCTAssertEqual(settings.reviewTemplates.map(\.pattern), ["schnaq/*"])
    }

    func testTheInsertMenuOnlyOffersRepliesWithANameAndABody() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.upsert(savedReply: SavedReply(name: "Good", body: "usable"))
        settings.upsert(savedReply: SavedReply(name: "  ", body: "no name"))
        settings.upsert(savedReply: SavedReply(name: "No body", body: "\n "))
        XCTAssertEqual(settings.savedReplies.count, 3)
        XCTAssertEqual(settings.usableSavedReplies.map(\.name), ["Good"])
    }

    func testDeletingARowLeavesTheRest() {
        let settings = AppSettings(defaults: makeDefaults())
        let keep = SavedReply(name: "Keep", body: "keep")
        let drop = SavedReply(name: "Drop", body: "drop")
        settings.upsert(savedReply: keep)
        settings.upsert(savedReply: drop)
        settings.deleteSavedReply(id: drop.id)
        XCTAssertEqual(settings.savedReplies.map(\.name), ["Keep"])
    }
}
