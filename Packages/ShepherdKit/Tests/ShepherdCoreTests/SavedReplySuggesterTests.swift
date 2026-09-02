import Foundation
import XCTest
@testable import ShepherdCore

/// The pure half of the saved-reply suggestion: the ranking, the similarity floor, the total
/// order, the thread-text budget and the cache key.
///
/// Runs on the Linux runner, which is the point of the split — no embedding model exists there, so
/// every vector here is one a test wrote by hand and every cosine is one a reader can check with a
/// pencil. What the app-target `SavedReplySuggestionTests` cover on top of this is the part a pure
/// function cannot see: when an embedding is actually spent, what the cache does when a reply body
/// is edited, and the "plain list" states.
final class SavedReplySuggesterTests: XCTestCase {
    /// A thread pointing along the first axis, so a candidate's first component *is* its cosine.
    private let thread = SearchVector([1, 0, 0])

    private func id(_ last: Int) -> UUID {
        let suffix = String(format: "%012d", last)
        guard let value = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") else {
            preconditionFailure("a hand-written uuid string parses")
        }
        return value
    }

    /// Cosine ≈ 1.0, 0.8 and 0.3 against ``thread``.
    private var near: SearchVector { SearchVector([1, 0, 0]) }
    private var middling: SearchVector { SearchVector([0.8, 0.6, 0]) }
    private var far: SearchVector { SearchVector([0.3, 0.95, 0]) }

    // MARK: - Ranking

    func testTheTwoNearestRepliesComeBackBestFirst() {
        let ranked = SavedReplySuggester.rank(
            threadVector: thread,
            replies: [
                (id: id(3), vector: far),
                (id: id(1), vector: middling),
                (id: id(2), vector: near),
            ]
        )
        // Two, and in similarity order — not three, and not input order.
        XCTAssertEqual(ranked, [id(2), id(1)])
    }

    func testAPoorMatchIsNotSuggestedAtAll() {
        let ranked = SavedReplySuggester.rank(
            threadVector: thread,
            replies: [
                (id: id(1), vector: far),
                (id: id(2), vector: SearchVector([0, 1, 0])),
                (id: id(3), vector: SearchVector([0, 0, 1])),
            ]
        )
        // The whole point of the floor: a menu that always had two suggestions would cost the
        // reviewer a decision on every comment and be right by accident.
        XCTAssertTrue(ranked.isEmpty)
    }

    func testTheFloorIsAnArgumentSoACallerMayLowerIt() {
        let ranked = SavedReplySuggester.rank(
            threadVector: thread,
            replies: [
                (id: id(1), vector: far),
                (id: id(2), vector: SearchVector([0, 1, 0])),
                (id: id(3), vector: SearchVector([0, 0, 1])),
            ],
            minimumSimilarity: 0.2
        )
        XCTAssertEqual(ranked, [id(1)])
    }

    func testTiedRepliesAreOrderedByIdSoTheMenuCannotReshuffle() {
        let replies: [(id: UUID, vector: SearchVector)] = [
            (id: id(9), vector: near),
            (id: id(4), vector: near),
            (id: id(7), vector: near),
        ]
        let first = SavedReplySuggester.rank(threadVector: thread, replies: replies)
        let second = SavedReplySuggester.rank(
            threadVector: thread,
            replies: Array(replies.reversed())
        )
        XCTAssertEqual(first, [id(4), id(7)])
        XCTAssertEqual(first, second, "the order is total, so input order cannot leak into it")
    }

    func testTooFewRepliesMeansNoSuggestionEvenForAPerfectMatch() {
        let ranked = SavedReplySuggester.rank(
            threadVector: thread,
            replies: [(id: id(1), vector: near), (id: id(2), vector: near)]
        )
        // With two replies the section would be the whole list wearing a header, which teaches
        // the reviewer that the header means nothing.
        XCTAssertTrue(ranked.isEmpty)
        XCTAssertEqual(SavedReplySuggester.minimumCandidateCount, 3)
    }

    func testAThreadWithNoVectorSuggestsNothing() {
        let ranked = SavedReplySuggester.rank(
            threadVector: SearchVector([]),
            replies: [
                (id: id(1), vector: near),
                (id: id(2), vector: near),
                (id: id(3), vector: near),
            ]
        )
        XCTAssertTrue(ranked.isEmpty)
    }

    func testACandidateThatCannotBeComparedIsSkippedRatherThanScoredZero() {
        let ranked = SavedReplySuggester.rank(
            threadVector: thread,
            replies: [
                // Wrong dimensions: "this question has no answer", not "unrelated".
                (id: id(1), vector: SearchVector([1, 0])),
                (id: id(2), vector: near),
                (id: id(3), vector: middling),
            ]
        )
        XCTAssertEqual(ranked, [id(2), id(3)])
    }

    func testALimitOfZeroIsHonoured() {
        let ranked = SavedReplySuggester.rank(
            threadVector: thread,
            replies: [
                (id: id(1), vector: near),
                (id: id(2), vector: near),
                (id: id(3), vector: near),
            ],
            limit: 0
        )
        XCTAssertTrue(ranked.isEmpty)
    }

    // MARK: - Thread text

    func testTheWholeThreadIsKeptInChronologicalOrderWhenItFits() {
        let text = SavedReplySuggester.threadText(from: ["first", "second", "third"])
        XCTAssertEqual(text, "first\n\nsecond\n\nthird")
    }

    func testTheOldestCommentsAreTheFirstToBeDropped() {
        let budget = SavedReplyThreadBudget(totalBytes: 9, commentBytes: 20)
        let text = SavedReplySuggester.threadText(
            from: ["aaaa", "bbbb", "cccc"],
            budget: budget
        )
        // What the reviewer is answering is the end of the conversation, so the end is what
        // survives — and it survives in the order it was written.
        XCTAssertEqual(text, "bbbb\n\ncccc")
    }

    func testTheKeptCommentsAreTheNewestContiguousRun() {
        let budget = SavedReplyThreadBudget(totalBytes: 10, commentBytes: 50)
        let text = SavedReplySuggester.threadText(
            from: ["x", "yyyyyyyyyy", "zz"],
            budget: budget
        )
        // `x` would fit in what is left, and is deliberately not picked up: a conversation with
        // a hole in the middle is not a summary of anything.
        XCTAssertEqual(text, "zz")
    }

    func testOneEnormousCommentIsCutRatherThanAllowedToFillTheBudget() {
        let budget = SavedReplyThreadBudget(totalBytes: 100, commentBytes: 3)
        let text = SavedReplySuggester.threadText(from: ["abcdef", "ghijkl"], budget: budget)
        XCTAssertEqual(text, "abc\n\nghi")
    }

    func testTheNewestCommentIsCutRatherThanDroppedWhenItAloneIsOverBudget() {
        let budget = SavedReplyThreadBudget(totalBytes: 3, commentBytes: 50)
        let text = SavedReplySuggester.threadText(from: ["old", "abcdefgh"], budget: budget)
        // Returning "" here would silently switch the feature off on exactly the threads that
        // have the most to match against; substituting the older comment would answer the wrong
        // question.
        XCTAssertEqual(text, "abc")
    }

    func testBlankCommentsAndAnEmptyThreadProduceNothingToEmbed() {
        XCTAssertEqual(SavedReplySuggester.threadText(from: []), "")
        XCTAssertEqual(SavedReplySuggester.threadText(from: ["   ", "\n\t"]), "")
        XCTAssertEqual(SavedReplySuggester.threadText(from: [" hi ", "  "]), "hi")
    }

    func testAZeroBudgetProducesNothingRatherThanEverything() {
        let budget = SavedReplyThreadBudget(totalBytes: 0, commentBytes: 0)
        XCTAssertEqual(SavedReplySuggester.threadText(from: ["hello"], budget: budget), "")
    }

    func testAMultiByteCommentIsNeverCutThroughACharacter() {
        // Four bytes per emoji, so a three-byte ceiling can hold none of them and a five-byte
        // one exactly one.
        let budget = SavedReplyThreadBudget(totalBytes: 100, commentBytes: 5)
        let text = SavedReplySuggester.threadText(from: ["🐑🐑"], budget: budget)
        XCTAssertEqual(text, "🐑")
    }

    // MARK: - Cache keys

    func testTheKeyIgnoresSurroundingWhitespaceBecauseTheEmbeddedTextDoesToo() {
        XCTAssertEqual(
            SavedReplySuggester.bodyKey(for: "Please add a test."),
            SavedReplySuggester.bodyKey(for: "\n  Please add a test.  \n")
        )
    }

    func testEditingTheBodyChangesTheKey() {
        XCTAssertNotEqual(
            SavedReplySuggester.bodyKey(for: "Please add a test."),
            SavedReplySuggester.bodyKey(for: "Please add two tests.")
        )
    }

    func testTheKeyIsStableAcrossCallsBecauseItIsNotSeededPerProcess() {
        let once = SavedReplySuggester.bodyKey(for: "Nit: naming.")
        XCTAssertEqual(once, SavedReplySuggester.bodyKey(for: "Nit: naming."))
        XCTAssertFalse(once.isEmpty)
    }
}
