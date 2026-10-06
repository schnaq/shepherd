import AppKit
import XCTest
@testable import Shepherd

final class PastedImageTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        board.clearContents()
        return board
    }

    func testAScreenshotOnThePasteboardIsAnImage() {
        let board = pasteboard()
        board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)

        let image = PastedImage.image(on: board)

        XCTAssertEqual(image?.name, "Screenshot.png")
        XCTAssertEqual(image?.contentType, "image/png")
    }

    func testTextIsLeftToTheTextView() {
        let board = pasteboard()
        board.setString("let x = 1", forType: .string)

        XCTAssertNil(PastedImage.image(on: board))
    }

    func testAPlaceholderHoldsTheSendBack() {
        XCTAssertTrue(PastedImage.containsPendingUpload("Look:\n![Uploading Screenshot.png…](abc)\n"))
        XCTAssertFalse(PastedImage.containsPendingUpload("![Screenshot.png](https://github.com/x)"))
    }
}
