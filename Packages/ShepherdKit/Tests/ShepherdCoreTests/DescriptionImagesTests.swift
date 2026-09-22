import Foundation
import XCTest
@testable import ShepherdCore

/// The pure half of *Read screenshots* (ADR 0038 item 4): which images in a description count as
/// attachments, and which signed link in GitHub's rendering belongs to which of them.
///
/// The assertions that matter most are the refusals. A screenshot on a host GitHub does not own
/// is a host that is not on CONTRIBUTING.md's list, so it must not come back from either half; and
/// the signed link is the only thing downloaded, so a `camo` proxy or a `<video>` must not be
/// mistaken for one.
final class DescriptionImagesTests: XCTestCase {
    private let upload = "https://github.com/user-attachments/assets/8a9a7a9a-b522-4d7c-b0ce-0cada5cf1568"
    private let second = "https://github.com/user-attachments/assets/5D313B65-21DB-44E8-BE42-88418A37C4F9"
    private let legacy = "https://user-images.githubusercontent.com/182555024/372185885-3d23e0a5-f280-4cfb-99be-04f373a27779.jpg"

    // MARK: - Markdown

    func testMarkdownAndHTMLUploadsAreFoundInDocumentOrder() {
        let markdown = """
            ## Before / after

            <img width="400" alt="before" src="\(upload)" />

            ![After the change](\(second))
            """
        let images = DescriptionImages.attachments(inMarkdown: markdown)

        XCTAssertEqual(images.map(\.url.absoluteString), [upload, second])
        XCTAssertEqual(images.map(\.altText), ["before", "After the change"])
        XCTAssertEqual(images[0].key, "8a9a7a9a-b522-4d7c-b0ce-0cada5cf1568")
        XCTAssertEqual(images[1].key, "5d313b65-21db-44e8-be42-88418a37c4f9", "keys are lowercased")
    }

    func testTheOlderUploadHostAndATitledImageCount() {
        let markdown = #"![shot](\#(legacy) "the new sidebar")"#
        let images = DescriptionImages.attachments(inMarkdown: markdown)

        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].key, "372185885-3d23e0a5-f280-4cfb-99be-04f373a27779.jpg")
    }

    func testImagesOnOtherHostsAreNotAttachments() {
        let markdown = """
            ![badge](https://img.shields.io/badge/ci-green.svg)
            ![shot](https://example.com/shot.png)
            ![repo file](https://github.com/schnaq/shepherd/blob/main/docs/shot.png)
            ![plain](http://github.com/user-attachments/assets/8a9a7a9a-b522-4d7c-b0ce-0cada5cf1568)
            [a link, not an image](\(upload))
            """
        XCTAssertEqual(DescriptionImages.attachments(inMarkdown: markdown), [])
    }

    func testAnImageInsideAFencedBlockIsText() {
        let markdown = """
            ```markdown
            ![example](\(upload))
            ```
            ~~~
            <img src="\(second)">
            ~~~
            """
        XCTAssertEqual(DescriptionImages.attachments(inMarkdown: markdown), [])
    }

    func testTheSameUploadTwiceIsReadOnce() {
        let markdown = "![one](\(upload))\n\n<img src=\"\(upload)\">"
        XCTAssertEqual(DescriptionImages.attachments(inMarkdown: markdown).count, 1)
    }

    // MARK: - Signed links

    /// The shape GitHub's `body_html` has, trimmed: every upload rewritten to a signed link whose
    /// file name keeps the asset's UUID, with `&amp;` in the query.
    private var bodyHTML: String {
        """
        <p><a target="_blank" rel="noopener noreferrer" href="https://private-user-images.githubusercontent.com/1101828/655551598-5d313b65-21db-44e8-be42-88418a37c4f9.png?jwt=abc"><img width="400" src="https://private-user-images.githubusercontent.com/1101828/655551598-5d313b65-21db-44e8-be42-88418a37c4f9.png?jwt=abc&amp;x=1" style="max-width: 100%;"></a></p>
        <p><img src="https://camo.githubusercontent.com/deadbeef/8a9a7a9a-b522-4d7c-b0ce-0cada5cf1568"></p>
        <p><img width="400" src="https://private-user-images.githubusercontent.com/1101828/655551628-8a9a7a9a-b522-4d7c-b0ce-0cada5cf1568.png?jwt=def"></p>
        <video src="https://private-user-images.githubusercontent.com/1/0-ffffffff-0000-0000-0000-000000000000.mov?jwt=v"></video>
        """
    }

    func testEachAttachmentIsMatchedToItsSignedLinkInItsOwnOrder() {
        let attachments = DescriptionImages.attachments(inMarkdown: "![a](\(upload)) ![b](\(second))")
        let sources = DescriptionImages.signedSources(for: attachments, inBodyHTML: bodyHTML)

        XCTAssertEqual(sources.map(\.image), attachments)
        XCTAssertEqual(sources.map(\.url.absoluteString), [
            "https://private-user-images.githubusercontent.com/1101828/655551628-8a9a7a9a-b522-4d7c-b0ce-0cada5cf1568.png?jwt=def",
            "https://private-user-images.githubusercontent.com/1101828/655551598-5d313b65-21db-44e8-be42-88418a37c4f9.png?jwt=abc&x=1",
        ])
    }

    func testAProxiedImageOrAVideoIsNeverASource() {
        let video = DescriptionImage(
            url: URL(string: "https://github.com/user-attachments/assets/ffffffff-0000-0000-0000-000000000000")!,
            altText: "",
            key: "ffffffff-0000-0000-0000-000000000000"
        )
        XCTAssertTrue(DescriptionImages.signedSources(for: [video], inBodyHTML: bodyHTML).isEmpty)
        // Only `camo` carries the key for this one once the private link is gone.
        let camoOnly = bodyHTML.replacingOccurrences(of: "655551628-8a9a7a9a", with: "655551628-00000000")
        let attachments = DescriptionImages.attachments(inMarkdown: "![a](\(upload))")
        XCTAssertTrue(DescriptionImages.signedSources(for: attachments, inBodyHTML: camoOnly).isEmpty)
    }

    func testAnUnmatchedFirstAttachmentDoesNotShiftTheSecondsLink() {
        let missing = DescriptionImage(url: URL(string: "https://github.com/user-attachments/assets/00000000")!, altText: "", key: "00000000")
        let attachments = [missing] + DescriptionImages.attachments(inMarkdown: "![b](\(second))")
        let sources = DescriptionImages.signedSources(for: attachments, inBodyHTML: bodyHTML)

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].image.key, "5d313b65-21db-44e8-be42-88418a37c4f9")
        XCTAssertTrue(sources[0].url.absoluteString.contains("5d313b65"))
    }

    func testTheOlderUploadIsItsOwnSource() {
        let attachments = DescriptionImages.attachments(inMarkdown: "![x](\(legacy))")
        let html = "<p><img src=\"\(legacy)\" alt=\"x\"></p>"
        XCTAssertEqual(DescriptionImages.signedSources(for: attachments, inBodyHTML: html).map(\.url.absoluteString), [legacy])
    }

    func testOnlyHTTPSOnGitHubsUploadHostsIsDownloadable() {
        XCTAssertTrue(DescriptionImages.isDownloadable(URL(string: "https://private-user-images.githubusercontent.com/1/a.png?jwt=x")!))
        XCTAssertTrue(DescriptionImages.isDownloadable(URL(string: legacy)!))
        XCTAssertFalse(DescriptionImages.isDownloadable(URL(string: "http://user-images.githubusercontent.com/1/a.png")!))
        XCTAssertFalse(DescriptionImages.isDownloadable(URL(string: upload)!), "github.com redirects to S3")
        XCTAssertFalse(DescriptionImages.isDownloadable(URL(string: "https://camo.githubusercontent.com/a")!))
        XCTAssertFalse(DescriptionImages.isDownloadable(URL(string: "https://github-production-user-asset-6210df.s3.amazonaws.com/a.png")!))
    }

    // MARK: - The request

    func testTheRequestReadsAtMostTwoAndRemembersHowManyThereWere() {
        let attachments = (0..<3).map {
            DescriptionImage(url: URL(string: "https://github.com/user-attachments/assets/\($0)")!, altText: "", key: "\($0)")
        }
        let request = ScreenshotReadingRequest(title: "  Make the button blue  ", attachments: attachments)

        XCTAssertEqual(request.images.count, DescriptionImages.maximumImages)
        XCTAssertEqual(request.totalCount, 3)
        XCTAssertEqual(request.title, "Make the button blue")
        let narrowed = request.keeping([attachments[1], attachments[2]])
        XCTAssertEqual(narrowed.images, [attachments[1]], "an image never in the request stays out")
        XCTAssertEqual(narrowed.totalCount, 3)
    }

    func testThePromptCarriesTheTitleAndNotTheDescription() {
        let image = DescriptionImage(url: URL(string: upload)!, altText: "before", key: "k")
        let request = ScreenshotReadingRequest(title: "Blue button", attachments: [image])

        XCTAssertTrue(request.promptText.contains("Pull request: Blue button"))
        XCTAssertTrue(request.promptText.contains("One screenshot"))
        XCTAssertEqual(request.label(at: 0), "Screenshot 1: before")
    }

    func testAnUploadsDefaultAltTextIsNotALabel() {
        for alt in ["image", "Screenshot 2026-09-22 at 10.14.03", "IMG_1234", "shot.png", ""] {
            let image = DescriptionImage(url: URL(string: upload)!, altText: alt, key: "k")
            let request = ScreenshotReadingRequest(title: "t", attachments: [image])
            XCTAssertEqual(request.label(at: 0), "Screenshot 1", alt)
        }
    }
}
