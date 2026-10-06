import XCTest
@testable import Shepherd

final class SuggestionBlockTests: XCTestCase {
    private let document = "one\ntwo\nthree\nfour"

    func testOneLineIsFencedOnItsOwn() {
        XCTAssertEqual(
            SuggestionBlock.make(document: document, startLine: nil, line: 2),
            "```suggestion\ntwo\n```"
        )
    }

    func testARangeKeepsEveryLineInOrder() {
        XCTAssertEqual(
            SuggestionBlock.make(document: document, startLine: 2, line: 4),
            "```suggestion\ntwo\nthree\nfour\n```"
        )
    }

    func testLinesOutsideTheDocumentGiveNoBlock() {
        XCTAssertNil(SuggestionBlock.make(document: document, startLine: nil, line: 5))
        XCTAssertNil(SuggestionBlock.make(document: document, startLine: 3, line: 2))
    }
}
