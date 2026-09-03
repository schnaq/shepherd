import Foundation
import ShepherdCore
import XCTest

@testable import GitHubKit

/// The one issue read (ADR 0026's amendment), against recorded responses.
///
/// Four things about it are worth a test rather than a reading of the code:
///
/// - the body arrives as Markdown source, because that is what
///   ``ShepherdCore/AcceptanceCriteria/bullets(from:)`` is written against;
/// - a `pull_request` object in the payload means the reference was a pull request, which is the
///   one input that makes the card say there are no acceptance criteria to check;
/// - the read is conditionally cached and its validator is replayed, which is what makes the
///   second reviewer to open the same card cost a `304` — and, unlike `/check-runs`, the URL is
///   immutable, so the cache holds one row per issue however often it is read;
/// - a `404` and a `403` come back as typed errors rather than as an empty issue, because the
///   card turns each of them into its own sentence.
final class IssueParsingTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    func testAnIssueIsParsedWithItsBodyAsMarkdown() async throws {
        let transport = MockTransport()
        await transport.route("/issues/142", try Fixture.response("issue"))
        let client = GitHubClient.makeForTesting(transport: transport)

        let issue = try await client.issue(repo: repo, number: 142)

        XCTAssertEqual(issue.number, 142)
        XCTAssertEqual(issue.repo, repo)
        XCTAssertEqual(issue.title, "Uploads fail silently on a flaky connection")
        XCTAssertEqual(issue.state, .open)
        XCTAssertFalse(issue.isPullRequest)
        XCTAssertEqual(
            issue.url,
            URL(string: "https://github.com/schnaq/review/issues/142")
        )
        XCTAssertTrue(
            issue.bodyMarkdown.contains("- [ ] The upload retries a dropped connection three times"),
            issue.bodyMarkdown
        )
        XCTAssertEqual(issue.id, "schnaq/review#142")
    }

    func testTheRequestIsOneGetAgainstTheIssuesEndpoint() async throws {
        let transport = MockTransport()
        await transport.route("/issues/142", try Fixture.response("issue"))
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.issue(repo: repo, number: 142)

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/issues/142"
        )
        XCTAssertNil(request?.body, "a read has no request body")
    }

    func testAPullRequestReferenceIsReportedAsOne() async throws {
        let transport = MockTransport()
        await transport.route("/issues/7", try Fixture.response("issue-as-pull-request"))
        let client = GitHubClient.makeForTesting(transport: transport)

        let issue = try await client.issue(repo: repo, number: 7)

        // GitHub's issues endpoint serves pull requests too, and the `pull_request` object is
        // the documented marker. A task list in a pull request is not acceptance criteria.
        XCTAssertTrue(issue.isPullRequest)
        XCTAssertEqual(issue.state, .closed)
    }

    func testTheReadIsConditionallyCachedAndItsValidatorIsReplayed() async throws {
        let transport = MockTransport()
        await transport.route(
            "/issues/142",
            try Fixture.response("issue", headers: ["ETag": "W/\"issue-142\""])
        )
        await transport.route("/issues/142", Fixture.empty(status: 304))

        let cache = InMemoryConditionalCache()
        let client = GitHubClient.makeForTesting(transport: transport, cache: cache)

        let first = try await client.issue(repo: repo, number: 142)
        let cachedCount = await cache.count
        XCTAssertEqual(cachedCount, 1, "the issue URL is immutable, so it is one row per issue")

        // The second open of the same card is a 304, and the cached body is replayed as the
        // answer — unlike `/notifications`, where "nothing changed" is the whole point, here the
        // caller needs the body it already paid for.
        let second = try await client.issue(repo: repo, number: 142)
        XCTAssertEqual(second, first)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].headers["If-None-Match"], "W/\"issue-142\"")
    }

    func testAMissingIssueIsNotFoundAndNamesTheResource() async throws {
        let transport = MockTransport()
        await transport.route(
            "/issues/999",
            Fixture.response(json: "{\"message\":\"Not Found\"}", status: 404)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.issue(repo: repo, number: 999)
            XCTFail("a 404 has to reach the caller")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .notFound(resource: "schnaq/review#999 issue"))
        }
    }

    func testAnIssueTheTokenCannotSeeIsForbidden() async throws {
        let transport = MockTransport()
        await transport.route(
            "/issues/142",
            Fixture.response(json: "{\"message\":\"Resource not accessible\"}", status: 403)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.issue(repo: repo, number: 142)
            XCTFail("a 403 has to reach the caller")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .forbidden(message: "Resource not accessible"))
        }
    }

    func testAPayloadWithoutANumberIsADecodingFailure() async throws {
        let transport = MockTransport()
        await transport.route("/issues/142", Fixture.response(json: "{\"title\":\"x\"}"))
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.issue(repo: repo, number: 142)
            XCTFail("an issue with no number cannot be identified")
        } catch let error as GitHubError {
            guard case .decoding = error else {
                return XCTFail("expected a decoding failure, got \(error)")
            }
        }
    }
}
