import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

/// The two reads behind *Read screenshots* (ADR 0038 item 4).
///
/// What is asserted is where the token goes and which hosts are contacted: the rendered
/// description is an `api.github.com` read with the token, and the screenshot is a plain `GET`
/// to GitHub's upload host **without** it — and to no other host, whatever URL arrives.
final class DescriptionImageTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let signed = "https://private-user-images.githubusercontent.com/1/2-8a9a7a9a.png?jwt=abc"

    func testTheRenderedDescriptionIsAskedForAsHTMLAndNotCached() async throws {
        let transport = MockTransport()
        await transport.route(
            "/pulls/7",
            Fixture.response(json: #"{"body_html":"<p><img src=\"x\"></p>"}"#, status: 200)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let html = try await client.pullRequestBodyHTML(repo: repo, number: 7)

        XCTAssertEqual(html, #"<p><img src="x"></p>"#)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].headers["Accept"], "application/vnd.github.html+json")
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer ghu_test-token")
        XCTAssertNil(requests[0].headers["If-None-Match"], "signed links expire; never replay a 304")
    }

    func testTheScreenshotIsFetchedWithoutTheToken() async throws {
        let transport = MockTransport()
        await transport.route(
            "private-user-images.githubusercontent.com",
            HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50]))
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let data = try await client.descriptionImage(at: try XCTUnwrap(URL(string: signed)))

        XCTAssertEqual(data, Data([0x89, 0x50]))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests[0].headers["Authorization"])
    }

    func testAnyOtherHostIsRefusedBeforeARequestIsMade() async throws {
        let transport = MockTransport()
        let client = GitHubClient.makeForTesting(transport: transport)

        for link in [
            "https://github.com/user-attachments/assets/8a9a7a9a",
            "https://github-production-user-asset-6210df.s3.amazonaws.com/1.png",
            "https://example.com/shot.png",
            "http://private-user-images.githubusercontent.com/1/2.png",
            "https://private-user-images.githubusercontent.com.evil.com/1/2.png",
        ] {
            do {
                _ = try await client.descriptionImage(at: try XCTUnwrap(URL(string: link)))
                XCTFail("expected \(link) to be refused")
            } catch let error as GitHubError {
                guard case .invalidURL = error else { return XCTFail("expected invalidURL, got \(error)") }
            }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)
    }

    func testAnAnswerFromAnotherHostAfterARedirectIsRefused() async throws {
        // A transport that followed a redirect on its own reports the URL that answered; the
        // image must have come from GitHub's upload host, or it is refused unread.
        let transport = MockTransport()
        await transport.route(
            "private-user-images.githubusercontent.com",
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "image/png"],
                body: Data([0x89]),
                url: URL(string: "https://github-production-user-asset-6210df.s3.amazonaws.com/2.png")
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.descriptionImage(at: try XCTUnwrap(URL(string: signed)))
            XCTFail("expected a foreign final host to be refused")
        } catch let error as GitHubError {
            guard case .invalidURL = error else { return XCTFail("expected invalidURL, got \(error)") }
        }
    }

    func testTheSessionRefusesToFollowARedirectFromTheUploadHosts() throws {
        XCTAssertTrue(RedirectPolicy.refusesRedirect(from: try XCTUnwrap(URL(string: signed))))
        XCTAssertTrue(RedirectPolicy.refusesRedirect(
            from: try XCTUnwrap(URL(string: "https://user-images.githubusercontent.com/1/a.png"))
        ))
        // The job log's redirect off api.github.com is still followed (ADR 0024).
        XCTAssertFalse(RedirectPolicy.refusesRedirect(
            from: try XCTUnwrap(URL(string: "https://api.github.com/repos/o/r/actions/jobs/1/logs"))
        ))
    }

    func testAnAnswerThatIsNotAnImageOrTooLargeIsRefused() async throws {
        let transport = MockTransport()
        await transport.route(
            "/1/2-8a9a7a9a.png",
            HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8))
        )
        await transport.route(
            "/1/3-big.png",
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "image/png"],
                body: Data(count: GitHubClient.maximumDescriptionImageBytes + 1)
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.descriptionImage(at: try XCTUnwrap(URL(string: signed)))
            XCTFail("expected a page to be refused")
        } catch let error as GitHubError {
            guard case .decoding = error else { return XCTFail("expected decoding, got \(error)") }
        }
        do {
            _ = try await client.descriptionImage(
                at: try XCTUnwrap(URL(string: "https://private-user-images.githubusercontent.com/1/3-big.png?jwt=x"))
            )
            XCTFail("expected an oversized image to be refused")
        } catch let error as GitHubError {
            guard case .responseTooLarge = error else { return XCTFail("expected responseTooLarge, got \(error)") }
        }
    }
}
