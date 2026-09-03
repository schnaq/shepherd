import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

/// The job-log read behind "why is CI red?" (plan §3.F).
///
/// Everything worth asserting about it is about the *shape* of GitHub's answer rather than about
/// parsing, because there is nothing to parse — the response is a log. Four properties, and each
/// one is a way this read can go wrong on somebody's machine:
///
/// - the redirect to the short-lived blob is followed, and the **bearer token is not sent to the
///   blob host** (a transport that does not follow redirects itself is the only way to observe
///   that, which is exactly what the mock is) — and the rule holds for the transport that *does*
///   follow it, where `RedirectPolicy` is what drops the header on the hop;
/// - a transport that *did* follow the redirect on its own — `URLSessionTransport`, because
///   `URLSession` does — is answered from the body it already has, with no second request;
/// - a log larger than ``GitHubClient/maximumJobLogBytes`` is refused with a typed error rather
///   than digested from its first two megabytes;
/// - a `404` (a job whose log has expired — Actions keeps them for weeks, not forever) is the
///   ordinary typed failure, so the tool above can say so in one line.
final class JobLogTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let blob = "https://objects.githubusercontent.com/github-production-actions-log/1?sig=abc"

    private let log = """
        2026-09-02T09:14:22.1189001Z Run swift test
        2026-09-02T09:14:23.0000000Z error: it broke
        """

    func testTheRedirectIsFollowedWithoutSendingTheTokenToTheBlobHost() async throws {
        let transport = MockTransport()
        // Registration order matters — the mock matches the first fragment that occurs in the
        // URL — so the blob is registered before the API path.
        await transport.route(
            "objects.githubusercontent.com",
            Fixture.response(json: log, status: 200)
        )
        await transport.route(
            "/actions/jobs/98765/logs",
            Fixture.empty(status: 302, headers: ["Location": blob])
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let text = try await client.jobLog(repo: repo, jobID: 98_765)

        XCTAssertEqual(text, log)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url.absoluteString.hasSuffix("/actions/jobs/98765/logs"))
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer ghu_test-token")
        XCTAssertEqual(requests[1].url.absoluteString, blob)
        // The whole point: the blob URL carries its own signature, so the token stays behind.
        XCTAssertNil(requests[1].headers["Authorization"])
    }

    func testTheTransportsOwnRedirectWouldStripTheSameHeader() throws {
        // The other half of the same rule, asserted where it can be: `MockTransport` answers with
        // the `302` and lets the method above make the second request, but the production
        // transport never gets that far — `URLSession` follows the hop inside itself and copies
        // the request's headers onto it. So the header the blob host must never see is decided by
        // `RedirectPolicy`, and this is the API request as `GitHubClient` actually sends it.
        let sent = HTTPRequest(
            method: "GET",
            url: try XCTUnwrap(
                URL(string: "https://api.github.com/repos/schnaq/review/actions/jobs/98765/logs")
            ),
            headers: [
                "Accept": "application/vnd.github+json",
                "Authorization": "Bearer ghu_test-token",
                "User-Agent": "Shepherd-Test",
            ]
        )

        let followed = RedirectPolicy.request(
            for: sent,
            redirectingTo: try XCTUnwrap(URL(string: blob))
        )

        XCTAssertNil(followed.headers["Authorization"], "the token stays behind on both paths")
        XCTAssertEqual(followed.headers["Accept"], "application/vnd.github+json")
        XCTAssertEqual(followed.url.absoluteString, blob)
    }

    func testATransportThatFollowedTheRedirectItselfCostsOneRequest() async throws {
        let transport = MockTransport()
        await transport.route("/actions/jobs/1/logs", Fixture.response(json: log, status: 200))
        let client = GitHubClient.makeForTesting(transport: transport)

        let text = try await client.jobLog(repo: repo, jobID: 1)

        XCTAssertEqual(text, log)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "nothing is re-fetched when the body is already here")
    }

    func testALogLargerThanTheCapIsRefusedRatherThanDigestedInPart() async throws {
        let transport = MockTransport()
        await transport.route(
            "/actions/jobs/2/logs",
            HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(count: GitHubClient.maximumJobLogBytes + 1)
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.jobLog(repo: repo, jobID: 2)
            XCTFail("expected the read to refuse an oversized log")
        } catch let error as GitHubError {
            guard case .responseTooLarge(_, let bytes, let limit) = error else {
                XCTFail("expected responseTooLarge, got \(error)")
                return
            }
            XCTAssertEqual(bytes, GitHubClient.maximumJobLogBytes + 1)
            XCTAssertEqual(limit, GitHubClient.maximumJobLogBytes)
            XCTAssertFalse(error.isRetryable, "the same request answers the same way")
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testAnExpiredLogIsTheOrdinaryTypedFailure() async throws {
        let transport = MockTransport()
        await transport.route(
            "/actions/jobs/3/logs",
            Fixture.response(json: #"{"message":"Not Found"}"#, status: 404)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.jobLog(repo: repo, jobID: 3)
            XCTFail("expected the read to fail")
        } catch let error as GitHubError {
            guard case .notFound(let resource) = error else {
                XCTFail("expected notFound, got \(error)")
                return
            }
            XCTAssertTrue(resource.contains("schnaq/review"))
            XCTAssertTrue(resource.contains("3"))
        }
    }

    func testABytewiseInvalidLogIsDecodedLossilyRatherThanRefused() async throws {
        let transport = MockTransport()
        // A tool printed a lone `0xFF`, which is not UTF-8. A diagnosis must not fail over it.
        var body = Data("error: it broke ".utf8)
        body.append(0xFF)
        await transport.route(
            "/actions/jobs/4/logs",
            HTTPResponse(statusCode: 200, headers: [:], body: body)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let text = try await client.jobLog(repo: repo, jobID: 4)

        XCTAssertTrue(text.hasPrefix("error: it broke "))
        XCTAssertTrue(text.contains("\u{FFFD}"), "the bad byte became a replacement character")
    }
}
