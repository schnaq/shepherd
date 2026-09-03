import Foundation
import ShepherdCore
import XCTest

@testable import GitHubKit

/// The pull-request side of ADR 0032's link: `closingIssuesReferences`, against recorded
/// responses.
///
/// Five things are worth a test rather than a reading of the code:
///
/// - the three shapes the field actually comes back in — no issues, one, several — because the
///   "Closes" section is drawn from the count and the middle case is the common one;
/// - a cross-repository reference keeps *its own* repository, since GitHub resolves
///   `closes owner/repo#1` and a section that assumed the pull request's own repository would
///   open the wrong issue;
/// - a state this build does not know decodes as `unknown` instead of dropping the row: the row
///   still names an issue somebody can open;
/// - the document travels on the same detail fetch as the review threads, which is the whole
///   argument for reading it here rather than per screen;
/// - a failure of *this one* call leaves the list empty and the rest of the detail intact.
final class ClosingIssueParsingTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    // MARK: - The three fixture shapes

    func testAPullRequestThatClosesNothingHasAnEmptyList() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdPullRequestClosingIssues",
            try Fixture.response("closing-issues-none")
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let issues = try await client.closingIssues(repo: repo, number: 128)

        XCTAssertTrue(issues.isEmpty)
    }

    func testOneClosingIssueCarriesItsNumberTitleStateAndRepository() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdPullRequestClosingIssues",
            try Fixture.response("closing-issues-one")
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let issues = try await client.closingIssues(repo: repo, number: 128)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].number, 142)
        XCTAssertEqual(issues[0].title, "Uploads fail silently")
        XCTAssertEqual(issues[0].state, .open)
        XCTAssertEqual(issues[0].repo, repo)
        XCTAssertEqual(issues[0].id, "schnaq/review#142")
        XCTAssertEqual(issues[0].slug, "schnaq/review#142")
    }

    func testSeveralClosingIssuesKeepGitHubsOrderAcrossRepositories() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdPullRequestClosingIssues",
            try Fixture.response("closing-issues-several")
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let issues = try await client.closingIssues(repo: repo, number: 128)

        // Three of the four nodes survive: the fourth has no number, so there is nothing the row
        // could name or open, and it is dropped rather than faked.
        XCTAssertEqual(issues.map(\.number), [142, 7, 9])
        XCTAssertEqual(
            issues.map(\.repo.fullName),
            ["schnaq/review", "schnaq/shepherd-web", "schnaq/review"]
        )
        XCTAssertEqual(issues[1].state, .closed)
        XCTAssertEqual(issues[1].title, "Token refresh logs the user out")
        // A vocabulary this build does not know is `unknown`, not a dropped row.
        XCTAssertEqual(issues[2].state, .unknown)
        XCTAssertEqual(issues[2].title, "")
    }

    func testTheRequestIsOnePostOfTheNamedDocument() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdPullRequestClosingIssues",
            try Fixture.response("closing-issues-one")
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.closingIssues(repo: repo, number: 128)

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.url.absoluteString, "https://api.github.com/graphql")
        let body = request?.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(body.contains("closingIssuesReferences(first: 10)"), body)
        XCTAssertTrue(body.contains("\"number\":128"), body)
    }

    // MARK: - Inside the detail fetch

    /// Wires up every endpoint a detail fetch touches, including the new document.
    private func makeTransport(closingIssues fixture: String?) async throws -> MockTransport {
        let transport = MockTransport()
        await transport.route("/pulls/128/files", try Fixture.response("pull-files-page"))
        await transport.route("/pulls/128/commits", try Fixture.response("pull-commits"))
        await transport.route("/pulls/128/reviews", try Fixture.response("pull-reviews"))
        await transport.route("ShepherdReviewThreads", try Fixture.response("review-threads"))
        if let fixture {
            await transport.route(
                "ShepherdPullRequestClosingIssues",
                try Fixture.response(fixture)
            )
        }
        await transport.route("check-runs", try Fixture.response("check-runs"))
        await transport.route("/pulls/128", try Fixture.response("pull-request"))
        return transport
    }

    func testTheDetailFetchCarriesTheClosingIssues() async throws {
        let transport = try await makeTransport(closingIssues: "closing-issues-one")
        let client = GitHubClient.makeForTesting(transport: transport)

        let detail = try await client.pullRequestDetail(repo: repo, number: 128)

        XCTAssertEqual(detail.closingIssues.map(\.number), [142])
        // The rest of the detail is untouched by the addition.
        XCTAssertEqual(detail.files.count, 4)
        XCTAssertEqual(detail.threads.count, 2)
        XCTAssertEqual(detail.checks.count, 3)
    }

    func testAFailingClosingIssuesCallLeavesTheListEmptyWithoutFailingTheDetail() async throws {
        // No route for the document: the mock answers 501, which is what a GitHub error looks
        // like to the client. The section is not drawn; the review screen is unaffected.
        let transport = try await makeTransport(closingIssues: nil)
        let client = GitHubClient.makeForTesting(transport: transport)

        let detail = try await client.pullRequestDetail(repo: repo, number: 128)

        XCTAssertTrue(detail.closingIssues.isEmpty)
        XCTAssertEqual(detail.number, 128)
        XCTAssertEqual(detail.files.count, 4)
        XCTAssertEqual(detail.threads.count, 2)
    }

    func testAskingDirectlyStillSurfacesTheError() async throws {
        let transport = try await makeTransport(closingIssues: nil)
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.closingIssues(repo: repo, number: 128)
            XCTFail("a caller that asks on its own gets the error")
        } catch {
            XCTAssertTrue(error is GitHubError, String(describing: error))
        }
    }

    // MARK: - The mapper on its own

    func testTheMapperDropsANodeWithoutARepository() throws {
        let dto = ClosingIssueNodeDTO(
            number: 3,
            title: "No repository at all",
            state: "OPEN",
            repository: nil
        )
        XCTAssertNil(ResponseMapping.closingIssue(from: dto))
    }

    func testTheMapperDeduplicatesByRepositoryAndNumber() throws {
        let node = ClosingIssueNodeDTO(
            number: 142,
            title: "Uploads fail silently",
            state: "OPEN",
            repository: GraphQLRepositoryDTO(
                name: "review",
                owner: GraphQLRepositoryDTO.Owner(login: "schnaq")
            )
        )
        let data = PullRequestClosingIssuesData(
            repository: PullRequestClosingIssuesData.Repository(
                pullRequest: PullRequestClosingIssuesData.Repository.PullRequest(
                    closingIssuesReferences:
                        PullRequestClosingIssuesData.Repository.PullRequest.IssueConnection(
                            totalCount: 2,
                            nodes: [node, node]
                        )
                )
            )
        )
        XCTAssertEqual(ResponseMapping.closingIssues(from: data).map(\.number), [142])
    }

    func testAResponseWithNoPullRequestNodeIsAnEmptyList() throws {
        let data = PullRequestClosingIssuesData(repository: nil)
        XCTAssertTrue(ResponseMapping.closingIssues(from: data).isEmpty)
    }
}
