import AppKit
import GitHubKit
import ShepherdCore
import XCTest
@testable import Shepherd

/// How the conversation tab gets a post's screenshots (ADR 0043): the post's rendering once for
/// all of its uploads, each upload downloaded once, and nothing kept after sign-out.
@MainActor
final class MarkdownImagesTests: XCTestCase {
    private actor FakeFetcher: DescriptionImageFetching {
        let png: Data
        private(set) var renderings: [String] = []
        private(set) var downloads: [URL] = []

        init(png: Data) { self.png = png }

        func pullRequestBodyHTML(repo: RepoRef, number: Int) async throws -> String { "" }

        func bodyHTML(subjectID: String) async throws -> String {
            renderings.append(subjectID)
            return """
                <img src="https://private-user-images.githubusercontent.com/1/1-aaaaaaaa-0000-0000-0000-000000000001.png?jwt=a">
                <img src="https://private-user-images.githubusercontent.com/1/2-bbbbbbbb-0000-0000-0000-000000000002.png?jwt=b">
                """
        }

        func descriptionImage(at url: URL) async throws -> Data {
            downloads.append(url)
            return png
        }
    }

    private func upload(_ uuid: String) -> DescriptionImage {
        DescriptionImages.attachments(inMarkdown: "![shot](https://github.com/user-attachments/assets/\(uuid))")[0]
    }

    private var png: Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    override func tearDown() async throws {
        MarkdownImages.forget()
    }

    func testAPostIsRenderedOnceForAllItsUploadsAndEachIsDownloadedOnce() async {
        let fetcher = FakeFetcher(png: png)
        let first = upload("aaaaaaaa-0000-0000-0000-000000000001")
        let second = upload("bbbbbbbb-0000-0000-0000-000000000002")

        let one = await MarkdownImages.load(first, in: "PR_1", fetcher: fetcher)
        let two = await MarkdownImages.load(second, in: "PR_1", fetcher: fetcher)

        XCTAssertEqual(one?.size, NSSize(width: 4, height: 2))
        XCTAssertNotNil(two)
        XCTAssertNotNil(MarkdownImages.cached(first))
        let renderings = await fetcher.renderings
        XCTAssertEqual(renderings, ["PR_1"])
        let downloads = await fetcher.downloads
        XCTAssertEqual(downloads.map(\.host), ["private-user-images.githubusercontent.com", "private-user-images.githubusercontent.com"])
    }

    func testAnUploadThePostNoLongerHasIsNotDownloadedAndSignOutForgetsTheRest() async {
        let fetcher = FakeFetcher(png: png)
        let gone = upload("cccccccc-0000-0000-0000-000000000003")
        let kept = upload("aaaaaaaa-0000-0000-0000-000000000001")

        let missing = await MarkdownImages.load(gone, in: "PR_1", fetcher: fetcher)
        _ = await MarkdownImages.load(kept, in: "PR_1", fetcher: fetcher)
        MarkdownText.forgetParsedBodies()

        XCTAssertNil(missing)
        let downloads = await fetcher.downloads
        XCTAssertEqual(downloads.count, 1)
        XCTAssertNil(MarkdownImages.cached(kept))
    }
}
