import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

/// The request bodies Shepherd is expected to send, decoded with `JSONDecoder` rather than
/// `JSONSerialization` so the assertions behave identically on macOS and Linux.
private struct ReviewRequestBody: Decodable {
    struct Comment: Decodable {
        var path: String
        var body: String
        var line: Int
        var side: String
        var start_line: Int?
        var start_side: String?
    }
    var commit_id: String?
    var body: String?
    var event: String?
    var comments: [Comment]?
}

private struct MergeRequestBody: Decodable {
    var merge_method: String?
    var sha: String?
    var commit_title: String?
}

private struct ReplyRequestBody: Decodable {
    var body: String
}

final class WriteRequestTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    private func decodeBody<T: Decodable>(_ type: T.Type, from request: HTTPRequest?) throws -> T {
        let data = request?.body ?? Data()
        return try JSONDecoder().decode(type, from: data)
    }

    private func bodyText(_ request: HTTPRequest?) -> String {
        String(decoding: request?.body ?? Data(), as: UTF8.self)
    }

    // MARK: - Review submission

    func testSubmitReviewSendsOnePostWithEveryInlineComment() async throws {
        let transport = MockTransport()
        let response = try Fixture.response("review-submitted", status: 200)
        await transport.route("/pulls/128/reviews", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        let draft = ReviewDraft(
            prID: "PR_kwDOAgentOne",
            verdict: .approve,
            summaryBody: "Ship it.",
            comments: [
                DraftComment(
                    path: "Sources/Auth/TokenStore.swift",
                    line: 42,
                    side: .right,
                    body: "Nice."
                ),
                DraftComment(
                    path: "Sources/Auth/KeychainTokenStore.swift",
                    line: 20,
                    side: .right,
                    startLine: 15,
                    body: "Multi-line note."
                ),
            ],
            basedOnHeadOid: "3f1a9c0d"
        )

        let receipt = try await client.submitReview(draft, repo: repo, number: 128)
        XCTAssertEqual(receipt.id, 777_001)
        XCTAssertEqual(receipt.state, "APPROVED")
        XCTAssertFalse(receipt.isPending)

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/pulls/128/reviews"
        )

        let body = try decodeBody(ReviewRequestBody.self, from: request)
        XCTAssertEqual(body.event, "APPROVE")
        XCTAssertEqual(body.body, "Ship it.")
        XCTAssertEqual(body.commit_id, "3f1a9c0d")
        XCTAssertEqual(body.comments?.count, 2)
        XCTAssertEqual(body.comments?[0].path, "Sources/Auth/TokenStore.swift")
        XCTAssertEqual(body.comments?[0].line, 42)
        XCTAssertEqual(body.comments?[0].side, "RIGHT")
        XCTAssertNil(body.comments?[0].start_line)
        XCTAssertEqual(body.comments?[1].start_line, 15)
        XCTAssertEqual(body.comments?[1].start_side, "RIGHT")
    }

    func testDraftWithoutAVerdictOmitsTheEventFieldSoGitHubKeepsItPending() async throws {
        let transport = MockTransport()
        let response = try Fixture.response("review-pending", status: 200)
        await transport.route("/pulls/128/reviews", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        let draft = ReviewDraft(
            prID: "PR_kwDOAgentOne",
            verdict: nil,
            summaryBody: "Still thinking.",
            comments: [],
            basedOnHeadOid: "3f1a9c0d"
        )
        let receipt = try await client.submitReview(draft, repo: repo, number: 128)
        XCTAssertTrue(receipt.isPending)

        let request = await transport.onlyRequest()
        let body = try decodeBody(ReviewRequestBody.self, from: request)
        XCTAssertNil(body.event, "a pending review must not carry an event")
        XCTAssertFalse(bodyText(request).contains("\"event\""))
    }

    func testVerdictMapping() {
        XCTAssertEqual(ReviewVerdict.approve.apiEvent, "APPROVE")
        XCTAssertEqual(ReviewVerdict.requestChanges.apiEvent, "REQUEST_CHANGES")
        XCTAssertEqual(ReviewVerdict.comment.apiEvent, "COMMENT")
    }

    // MARK: - Replies and thread resolution

    func testReplyUsesTheDedicatedRESTEndpoint() async throws {
        let transport = MockTransport()
        await transport.route("/replies", Fixture.response(json: "{\"id\": 1}", status: 201))
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.replyToComment(
            repo: repo,
            number: 128,
            commentID: 987_654_321,
            body: "Thanks!"
        )

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/pulls/128/comments/987654321/replies"
        )
        let body = try decodeBody(ReplyRequestBody.self, from: request)
        XCTAssertEqual(body.body, "Thanks!")
    }

    func testResolveThreadUsesTheGraphQLMutation() async throws {
        let transport = MockTransport()
        let response = try Fixture.response("resolve-thread")
        await transport.route("ShepherdResolveThread", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.resolveThread(id: "PRRT_kwDOThreadOne")

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.url.absoluteString, "https://api.github.com/graphql")
        let text = bodyText(request)
        XCTAssertTrue(text.contains("resolveReviewThread"))
        XCTAssertTrue(text.contains("PRRT_kwDOThreadOne"))
    }

    func testUnresolveThreadUsesTheGraphQLMutation() async throws {
        let transport = MockTransport()
        let response = Fixture.response(
            json: "{\"data\":{\"unresolveReviewThread\":{\"thread\":{\"id\":\"T\",\"isResolved\":false}}}}"
        )
        await transport.route("ShepherdUnresolveThread", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.unresolveThread(id: "T")
        let request = await transport.onlyRequest()
        XCTAssertTrue(bodyText(request).contains("unresolveReviewThread"))
    }

    func testMarkReadyForReviewUsesTheGraphQLMutation() async throws {
        let transport = MockTransport()
        let response = Fixture.response(
            json: """
            {"data":{"markPullRequestReadyForReview":{"pullRequest":{"id":"PR_1","isDraft":false}}}}
            """
        )
        await transport.route("ShepherdMarkReady", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.markReadyForReview(pullRequestID: "PR_1")
        let request = await transport.onlyRequest()
        let text = bodyText(request)
        XCTAssertTrue(text.contains("markPullRequestReadyForReview"))
        XCTAssertTrue(text.contains("PR_1"))
    }

    // MARK: - Merge

    func testMergeSendsMethodAndShaPrecondition() async throws {
        let transport = MockTransport()
        let response = try Fixture.response("merge-result")
        await transport.route("/merge", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        let sha = try await client.mergePullRequest(
            repo: repo,
            number: 128,
            method: .squash,
            expectedHeadOid: "3f1a9c0d"
        )
        XCTAssertEqual(sha, "9999999999999999999999999999999999999999")

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "PUT")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/pulls/128/merge"
        )
        let body = try decodeBody(MergeRequestBody.self, from: request)
        XCTAssertEqual(body.merge_method, "squash")
        XCTAssertEqual(body.sha, "3f1a9c0d")
    }

    func testMergeConflictBecomesStaleHead() async throws {
        let transport = MockTransport()
        await transport.route(
            "/merge",
            Fixture.response(json: "{\"message\":\"Head branch was modified\"}", status: 409)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.mergePullRequest(
                repo: repo,
                number: 128,
                method: .merge,
                expectedHeadOid: "3f1a9c0d"
            )
            XCTFail("expected a stale head error")
        } catch let error as GitHubError {
            guard case .staleHead(let expected, _) = error else {
                return XCTFail("expected .staleHead, got \(error)")
            }
            XCTAssertEqual(expected, "3f1a9c0d")
        }
    }

    func testNotMergeableBecomesATypedError() async throws {
        let transport = MockTransport()
        let response = try Fixture.response("error-not-mergeable", status: 405)
        await transport.route("/merge", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.mergePullRequest(
                repo: repo,
                number: 128,
                method: .merge,
                expectedHeadOid: nil
            )
            XCTFail("expected a not-mergeable error")
        } catch let error as GitHubError {
            guard case .notMergeable(let message) = error else {
                return XCTFail("expected .notMergeable, got \(error)")
            }
            XCTAssertTrue(message.contains("not mergeable"))
        }
    }
}
