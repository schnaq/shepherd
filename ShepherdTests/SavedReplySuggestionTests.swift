import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The app half of the saved-reply suggestion: when an embedding is spent, what the cache does
/// when a reply body is edited, and every route back to the plain menu.
///
/// The *ranking* is covered exhaustively by `SavedReplySuggesterTests` in ShepherdKit, which runs
/// on the Linux runner. What is tested here is what a pure function cannot see — the cost. Two
/// promises of this feature are cost promises rather than quality promises ("nothing is embedded
/// unless the menu is used", "editing a reply costs one embedding and renaming costs none"), and
/// they are asserted through the fake embedder's call log.
///
/// Every embedding goes through the injected ``EmbeddingProviding`` seam, the same one ⌘K search
/// is tested through, so nothing here depends on Apple's model being present or on its output
/// being stable.
@MainActor
final class SavedReplySuggestionTests: XCTestCase {
    // MARK: - Doubles

    /// An embedder that answers from a table a test wrote, and remembers every question.
    ///
    /// A lookup table rather than the concept-counting stand-in `SemanticSearchTests` uses,
    /// because what is asserted here are exact cosines: a vector this file can point at is what
    /// makes "0.8 clears the floor and 0.30 does not" a readable test rather than a coincidence.
    /// A text that is not in the table gets `nil`, which is what the real model does for input it
    /// cannot embed.
    private actor FakeEmbedder: EmbeddingProviding {
        nonisolated let modelIdentifier = "fake-saved-reply-1"

        private let isAvailable: Bool
        private let table: [String: SearchVector]
        private(set) var embeddedTexts: [String] = []
        private(set) var availabilityAsks = 0

        init(table: [String: SearchVector], isAvailable: Bool = true) {
            self.table = table
            self.isAvailable = isAvailable
        }

        var callCount: Int { embeddedTexts.count }

        func availability() async -> EmbeddingAvailability {
            availabilityAsks += 1
            return isAvailable ? .available : .unavailable("no model in this test")
        }

        func vector(for text: String) async -> SearchVector? {
            embeddedTexts.append(text)
            guard isAvailable else { return nil }
            return table[text]
        }
    }

    // MARK: - Fixtures

    private func id(_ last: Int) -> UUID {
        let suffix = String(format: "%012d", last)
        guard let value = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") else {
            preconditionFailure("a hand-written uuid string parses")
        }
        return value
    }

    private var comments: [String] {
        ["Should this be behind a flag?", "It needs a test first."]
    }

    /// The text the coordinator will embed for ``comments``.
    private var threadText: String {
        SavedReplySuggester.threadText(from: comments)
    }

    private var needsTest: SavedReply {
        SavedReply(id: id(1), name: "Needs a test", body: "Please add a test for this branch.")
    }

    private var nit: SavedReply {
        SavedReply(id: id(2), name: "Nit", body: "Naming nit.")
    }

    private var generated: SavedReply {
        SavedReply(id: id(3), name: "Generated", body: "This is generated code.")
    }

    private var replies: [SavedReply] { [needsTest, nit, generated] }

    /// Cosines of 1.0, 0.8 and ≈0.30 against the thread's `[1, 0, 0]`.
    private var standardTable: [String: SearchVector] {
        [
            threadText: SearchVector([1, 0, 0]),
            needsTest.trimmedBody: SearchVector([1, 0, 0]),
            nit.trimmedBody: SearchVector([0.8, 0.6, 0]),
            generated.trimmedBody: SearchVector([0.3, 0.95, 0]),
        ]
    }

    private func makeCoordinator(
        _ embedder: any EmbeddingProviding
    ) -> SavedReplySuggestionCoordinator {
        SavedReplySuggestionCoordinator(embedder: embedder)
    }

    // MARK: - Ranking through the coordinator

    func testTheTwoNearestRepliesLeadAndTheThirdIsNotOffered() async {
        let embedder = FakeEmbedder(table: standardTable)
        let coordinator = makeCoordinator(embedder)

        let suggested = await coordinator.suggestions(
            forThreadComments: comments,
            replies: replies
        )

        XCTAssertEqual(suggested, [id(1), id(2)], "best first, and only two of the three")
        let calls = await embedder.callCount
        XCTAssertEqual(calls, 4, "one thread vector plus one per saved reply, and not one more")
    }

    func testTheThreadIsEmbeddedFromItsCommentsInChronologicalOrder() async {
        let embedder = FakeEmbedder(table: standardTable)
        let coordinator = makeCoordinator(embedder)

        _ = await coordinator.suggestions(forThreadComments: comments, replies: replies)

        let asked = await embedder.embeddedTexts
        XCTAssertEqual(asked.first, "Should this be behind a flag?\n\nIt needs a test first.")
    }

    func testASecondOpeningReusesEveryReplyVector() async {
        let embedder = FakeEmbedder(table: standardTable)
        let coordinator = makeCoordinator(embedder)

        _ = await coordinator.suggestions(forThreadComments: comments, replies: replies)
        _ = await coordinator.suggestions(forThreadComments: comments, replies: replies)

        let calls = await embedder.callCount
        // Four, then one: the replies are cached per body, the thread vector is not cached at all
        // because the thread is what changes between two openings.
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(coordinator.cachedBodyCount, 3)
    }

    func testRenamingAReplyCostsNoEmbeddingAtAll() async {
        let embedder = FakeEmbedder(table: standardTable)
        let coordinator = makeCoordinator(embedder)
        _ = await coordinator.suggestions(forThreadComments: comments, replies: replies)

        // The id is stable across an edit on purpose, and the *body* is what the cache is keyed
        // on — so a rename is free.
        let renamed = [
            SavedReply(id: id(1), name: "Add a test", body: needsTest.body),
            nit,
            generated,
        ]
        let suggested = await coordinator.suggestions(
            forThreadComments: comments,
            replies: renamed
        )

        XCTAssertEqual(suggested, [id(1), id(2)])
        let calls = await embedder.callCount
        XCTAssertEqual(calls, 5, "the thread again, and nothing else")
    }

    func testEditingAReplyBodyInvalidatesItsCachedVector() async {
        let edited = SavedReply(id: id(2), name: "Nit", body: "Naming nit — please rename this.")
        var table = standardTable
        table[edited.trimmedBody] = SearchVector([0.8, 0.6, 0])
        let embedder = FakeEmbedder(table: table)
        let coordinator = makeCoordinator(embedder)
        _ = await coordinator.suggestions(forThreadComments: comments, replies: replies)

        let suggested = await coordinator.suggestions(
            forThreadComments: comments,
            replies: [needsTest, edited, generated]
        )

        XCTAssertEqual(suggested, [id(1), id(2)])
        let calls = await embedder.callCount
        // The thread, plus exactly the one body that changed: the other two keys still match.
        XCTAssertEqual(calls, 6)
        let asked = await embedder.embeddedTexts
        XCTAssertEqual(asked.last, edited.trimmedBody)
        // The vector under the old key is unreachable and is dropped, so the cache stays the size
        // of the reply list rather than the size of the reviewer's edit history.
        XCTAssertEqual(coordinator.cachedBodyCount, 3)
    }

    // MARK: - Every route back to the plain list

    func testAPoorMatchIsNotSuggested() async {
        let table: [String: SearchVector] = [
            threadText: SearchVector([1, 0, 0]),
            needsTest.trimmedBody: SearchVector([0.3, 0.95, 0]),
            nit.trimmedBody: SearchVector([0, 1, 0]),
            generated.trimmedBody: SearchVector([0, 0, 1]),
        ]
        let coordinator = makeCoordinator(FakeEmbedder(table: table))

        let suggested = await coordinator.suggestions(
            forThreadComments: comments,
            replies: replies
        )

        XCTAssertTrue(suggested.isEmpty, "a menu that always suggests two is a menu nobody trusts")
    }

    func testFewerThanThreeSavedRepliesEmbedsNothing() async {
        let embedder = FakeEmbedder(table: standardTable)
        let coordinator = makeCoordinator(embedder)

        let suggested = await coordinator.suggestions(
            forThreadComments: comments,
            replies: [needsTest, nit]
        )

        XCTAssertTrue(suggested.isEmpty)
        let calls = await embedder.callCount
        let asks = await embedder.availabilityAsks
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(asks, 0, "the cheap rule is checked before the model is even woken")
    }

    func testAnUnusableReplyIsNeitherCountedNorOffered() async {
        let embedder = FakeEmbedder(table: standardTable)
        let coordinator = makeCoordinator(embedder)

        // Three rows, but one of them has nothing to insert — so there are two candidates, and
        // two is not a shortlist.
        let suggested = await coordinator.suggestions(
            forThreadComments: comments,
            replies: [needsTest, nit, SavedReply(id: id(9), name: "Empty", body: "   ")]
        )

        XCTAssertTrue(suggested.isEmpty)
        let calls = await embedder.callCount
        XCTAssertEqual(calls, 0)
    }

    func testAThreadWithNoTextEmbedsNothing() async {
        let embedder = FakeEmbedder(table: standardTable)
        let coordinator = makeCoordinator(embedder)

        let suggested = await coordinator.suggestions(forThreadComments: [], replies: replies)

        XCTAssertTrue(suggested.isEmpty)
        let calls = await embedder.callCount
        XCTAssertEqual(calls, 0, "a fresh review summary has no thread, so it costs nothing")
    }

    func testAThreadTheModelCannotEmbedCostsNoReplyEmbeddings() async {
        // The thread text is missing from the table, so the model answers `nil` for it.
        var table = standardTable
        table[threadText] = nil
        let embedder = FakeEmbedder(table: table)
        let coordinator = makeCoordinator(embedder)

        let suggested = await coordinator.suggestions(
            forThreadComments: comments,
            replies: replies
        )

        XCTAssertTrue(suggested.isEmpty)
        let calls = await embedder.callCount
        XCTAssertEqual(calls, 1, "no answer for the thread means the replies are never asked")
    }

    func testWithNoModelOnThisMacTheMenuIsThePlainListAndStaysCheap() async {
        let embedder = FakeEmbedder(table: standardTable, isAvailable: false)
        let coordinator = makeCoordinator(embedder)

        let first = await coordinator.suggestions(forThreadComments: comments, replies: replies)
        let second = await coordinator.suggestions(forThreadComments: comments, replies: replies)

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        let calls = await embedder.callCount
        XCTAssertEqual(calls, 0, "the availability gate is in front of every embedding")
        let asks = await embedder.availabilityAsks
        XCTAssertEqual(asks, 1, "asked once and remembered for the life of the app")
    }

    // MARK: - Menu ordering

    func testTheMenuPutsTheSuggestionsFirstAndKeepsTheWholeListBelow() {
        let menu = SavedReplyMenu(
            replies: replies,
            suggestedIDs: [id(3), id(1)],
            onInsert: { _ in }
        )

        XCTAssertEqual(
            menu.suggestedReplies.map(\.id),
            [id(3), id(1)],
            "ranking order, not list order"
        )
        XCTAssertEqual(
            menu.replies.map(\.id),
            [id(1), id(2), id(3)],
            "the full list is untouched, so a reviewer who knows where a reply sits still finds it"
        )
    }

    func testAnIdThatIsNoLongerASavedReplyDropsOutOfTheSection() {
        let menu = SavedReplyMenu(
            replies: replies,
            suggestedIDs: [id(42), id(2)],
            onInsert: { _ in }
        )

        XCTAssertEqual(menu.suggestedReplies.map(\.id), [id(2)])
    }

    func testWithNoSuggestionsTheMenuIsExactlyTheListItAlwaysWas() {
        let menu = SavedReplyMenu(replies: replies, onInsert: { _ in })
        XCTAssertTrue(menu.suggestedReplies.isEmpty)
        XCTAssertEqual(menu.replies.count, 3)
    }
}
