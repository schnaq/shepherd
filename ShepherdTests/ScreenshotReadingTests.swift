import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// *Read screenshots* on the inbox's summary card (ADR 0038 item 4): offered only when the
/// description attaches GitHub-hosted screenshots and the reader can read images, nothing fetched
/// until the click, and the request narrowed to what actually downloaded.
@MainActor
final class ScreenshotReadingTests: XCTestCase {
    // MARK: - Doubles

    private actor FakeReader: DescriptionScreenshotReading {
        private let availabilityReason: String?
        private let failure: IntelligenceError?
        private(set) var requests: [ScreenshotReadingRequest] = []

        init(availabilityReason: String? = nil, failure: IntelligenceError? = nil) {
            self.availabilityReason = availabilityReason
            self.failure = failure
        }

        func availability() async -> OnDeviceAvailability {
            guard let availabilityReason else { return .available }
            return .unavailable(availabilityReason)
        }

        func read(_ request: ScreenshotReadingRequest, images: [Data]) async throws -> ScreenshotReading {
            requests.append(request)
            if let failure { throw failure }
            return ScreenshotReading(
                observations: ["A blue button."],
                readCount: request.images.count,
                totalCount: request.totalCount
            )
        }
    }

    private actor FakeFetcher: DescriptionImageFetching {
        private let html: String
        private let failing: Set<String>
        private(set) var htmlReads = 0
        private(set) var downloads: [URL] = []

        init(html: String, failing: Set<String> = []) {
            self.html = html
            self.failing = failing
        }

        func pullRequestBodyHTML(repo: RepoRef, number: Int) async throws -> String {
            htmlReads += 1
            return html
        }

        func descriptionImage(at url: URL) async throws -> Data {
            downloads.append(url)
            if failing.contains(where: { url.absoluteString.contains($0) }) {
                throw URLError(.badServerResponse)
            }
            return Data([0x89])
        }
    }

    // MARK: - Fixtures

    private let first = "https://github.com/user-attachments/assets/aaaaaaaa-0000-0000-0000-000000000001"
    private let second = "https://github.com/user-attachments/assets/bbbbbbbb-0000-0000-0000-000000000002"
    private let third = "https://github.com/user-attachments/assets/cccccccc-0000-0000-0000-000000000003"

    private var html: String {
        """
        <img src="https://private-user-images.githubusercontent.com/1/1-aaaaaaaa-0000-0000-0000-000000000001.png?jwt=a">
        <img src="https://private-user-images.githubusercontent.com/1/2-bbbbbbbb-0000-0000-0000-000000000002.png?jwt=b">
        <img src="https://private-user-images.githubusercontent.com/1/3-cccccccc-0000-0000-0000-000000000003.png?jwt=c">
        """
    }

    private func detail(body: String, id: String = "PR_1") -> PullRequestDetail {
        PullRequestDetail(
            summary: PullRequestSummary(
                id: id,
                repo: RepoRef(owner: "schnaq", name: "review"),
                number: 42,
                title: "Make the button blue",
                author: ShepherdCore.Actor(login: "alice", kind: .human),
                updatedAt: Date(timeIntervalSince1970: 1_000),
                createdAt: Date(timeIntervalSince1970: 0),
                additions: 12,
                deletions: 3,
                changedFiles: 1,
                headRefName: "alice/blue",
                headRefOid: "abc123",
                baseRefName: "main",
                checkRollup: CheckRollup(state: .success, total: 1, failureCount: 0)
            ),
            bodyMarkdown: body
        )
    }

    private func settle(_ model: ScreenshotReadingModel) async {
        for _ in 0..<200 {
            if case .reading = model.state { await Task.yield(); continue }
            return
        }
    }

    // MARK: - Offering

    func testADescriptionWithUploadsIsOfferedWithoutFetchingAnything() async {
        let model = ScreenshotReadingModel()
        let fetcher = FakeFetcher(html: html)

        await model.refresh(detail: detail(body: "![a](\(first)) ![b](\(second)) ![c](\(third))"), reader: FakeReader())

        XCTAssertEqual(model.state, .offered(count: 3))
        let reads = await fetcher.htmlReads
        XCTAssertEqual(reads, 0, "selecting a row never downloads")
    }

    func testNoUploadsNoReaderOrNoVisionMeansNoButton() async {
        let model = ScreenshotReadingModel()
        await model.refresh(detail: detail(body: "![badge](https://img.shields.io/x.svg)"), reader: FakeReader())
        XCTAssertEqual(model.state, .none)

        await model.refresh(detail: detail(body: "![a](\(first))", id: "PR_2"), reader: nil)
        XCTAssertEqual(model.state, .none)

        let blind = ScreenshotReadingModel()
        await blind.refresh(
            detail: detail(body: "![a](\(first))"),
            reader: FakeReader(availabilityReason: "cannot read images")
        )
        XCTAssertEqual(blind.state, .none)
    }

    // MARK: - Reading

    func testTheClickReadsAtMostTwoAndSaysOfHowMany() async {
        let model = ScreenshotReadingModel()
        let reader = FakeReader()
        let fetcher = FakeFetcher(html: html)
        let pullRequest = detail(body: "![a](\(first)) ![b](\(second)) ![c](\(third))")
        await model.refresh(detail: pullRequest, reader: reader)

        model.read(detail: pullRequest, fetcher: fetcher)
        await settle(model)

        guard case .read(let reading) = model.state else { return XCTFail("expected a reading, got \(model.state)") }
        XCTAssertEqual(reading.readCount, 2)
        XCTAssertEqual(reading.totalCount, 3)
        let downloads = await fetcher.downloads
        XCTAssertEqual(downloads.count, 2)
        XCTAssertTrue(downloads.allSatisfy { $0.host == "private-user-images.githubusercontent.com" })
    }

    func testAFailedDownloadNarrowsTheRequestInsteadOfFailingIt() async {
        let model = ScreenshotReadingModel()
        let reader = FakeReader()
        let fetcher = FakeFetcher(html: html, failing: ["aaaaaaaa"])
        let pullRequest = detail(body: "![a](\(first)) ![b](\(second))")
        await model.refresh(detail: pullRequest, reader: reader)

        model.read(detail: pullRequest, fetcher: fetcher)
        await settle(model)

        let requests = await reader.requests
        XCTAssertEqual(requests.first?.images.map(\.url.absoluteString), [second])
        guard case .read(let reading) = model.state else { return XCTFail("expected a reading") }
        XCTAssertTrue(reading.isPartial)
    }

    func testTheWindowFailureDoesNotOfferACloudProvider() async {
        let model = ScreenshotReadingModel()
        let pullRequest = detail(body: "![a](\(first))")
        await model.refresh(detail: pullRequest, reader: FakeReader(failure: .contextExceeded))

        model.read(detail: pullRequest, fetcher: FakeFetcher(html: html))
        await settle(model)

        guard case .failed(let reason) = model.state else { return XCTFail("expected a failure") }
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("cloud"))
    }

    func testSignedOutIsOneSentenceAndNoRead() async {
        let model = ScreenshotReadingModel()
        let reader = FakeReader()
        let pullRequest = detail(body: "![a](\(first))")
        await model.refresh(detail: pullRequest, reader: reader)

        model.read(detail: pullRequest, fetcher: nil)

        guard case .failed = model.state else { return XCTFail("expected a failure") }
        let requests = await reader.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testAnotherPullRequestForgetsTheReading() async {
        let model = ScreenshotReadingModel()
        let reader = FakeReader()
        let pullRequest = detail(body: "![a](\(first))")
        await model.refresh(detail: pullRequest, reader: reader)
        model.read(detail: pullRequest, fetcher: FakeFetcher(html: html))
        await settle(model)

        // The same detail again — a background refetch — keeps it.
        await model.refresh(detail: pullRequest, reader: reader)
        guard case .read = model.state else { return XCTFail("a refetch must not forget the reading") }

        await model.refresh(detail: detail(body: "![b](\(second))", id: "PR_2"), reader: reader)
        XCTAssertEqual(model.state, .offered(count: 1))
    }

    // MARK: - Labels

    func testTheButtonAndCaptionCountWhatIsRead() {
        XCTAssertEqual(ScreenshotReadingBlock.buttonTitle(count: 1), "Read the screenshot")
        XCTAssertEqual(ScreenshotReadingBlock.buttonTitle(count: 2), "Read the 2 screenshots")
        XCTAssertEqual(ScreenshotReadingBlock.buttonTitle(count: 5), "Read 2 of 5 screenshots")
        XCTAssertEqual(
            ScreenshotReadingBlock.caption(for: ScreenshotReading(observations: [], readCount: 1, totalCount: 3)),
            "1 of 3 screenshots, read on this Mac"
        )
    }
}
