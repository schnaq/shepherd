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

private struct LabelsRequestBody: Decodable {
    var labels: [String]
}

private struct AssigneesRequestBody: Decodable {
    var assignees: [String]
}

/// The `PATCH /issues/{n}` body, decoded with every key the endpoint accepts so that a test can
/// assert the ones Shepherd deliberately never sends are absent (ADR 0032).
private struct IssuePatchRequestBody: Decodable {
    var state: String?
    var state_reason: String?
    var title: String?
    var body: String?
    var labels: [String]?
    var assignees: [String]?
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

    // MARK: - Issue writes (ADR 0032's Sprint 4a amendment)

    func testAnIssueCommentIsOnePostToTheIssuesCommentsEndpoint() async throws {
        let transport = MockTransport()
        await transport.route("/issues/128/comments", Fixture.response(json: "{\"id\":1}"))
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.addIssueComment(repo: repo, number: 128, body: "Picking this up.")

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/issues/128/comments"
        )
        let body = try decodeBody(ReplyRequestBody.self, from: request)
        XCTAssertEqual(body.body, "Picking this up.")
    }

    func testALabelWriteUsesTheAdditiveEndpointAndNotTheFullReplacePatch() async throws {
        let transport = MockTransport()
        await transport.route("/issues/128/labels", Fixture.response(json: "[]"))
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.addIssueLabels(repo: repo, number: 128, labels: ["needs-triage"])

        let request = await transport.onlyRequest()
        // The whole point: `POST .../labels`, so a second queued label cannot undo the first.
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/issues/128/labels"
        )
        let body = try decodeBody(LabelsRequestBody.self, from: request)
        XCTAssertEqual(body.labels, ["needs-triage"])
    }

    func testAnAssigneeWriteUsesTheAdditiveAssigneesEndpoint() async throws {
        let transport = MockTransport()
        await transport.route("/issues/128/assignees", Fixture.response(json: "{\"number\":128}"))
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.addIssueAssignees(repo: repo, number: 128, logins: ["octocat"])

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/issues/128/assignees"
        )
        let body = try decodeBody(AssigneesRequestBody.self, from: request)
        XCTAssertEqual(body.assignees, ["octocat"])
    }

    func testClosingAnIssueSendsOnlyTheStateAndTheReason() async throws {
        let transport = MockTransport()
        await transport.route("/issues/128", Fixture.response(json: "{\"number\":128}"))
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.setIssueState(
            repo: repo,
            number: 128,
            state: "closed",
            stateReason: "not_planned"
        )

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "PATCH")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/issues/128"
        )
        let body = try decodeBody(IssuePatchRequestBody.self, from: request)
        XCTAssertEqual(body.state, "closed")
        XCTAssertEqual(body.state_reason, "not_planned")
        // The endpoint would happily rewrite all four of these; a body that carried them would
        // overwrite whatever somebody else changed in the meantime.
        XCTAssertNil(body.title)
        XCTAssertNil(body.body)
        XCTAssertNil(body.labels)
        XCTAssertNil(body.assignees)
        XCTAssertFalse(bodyText(request).contains("title"))
        XCTAssertFalse(bodyText(request).contains("assignees"))
    }

    func testReopeningAnIssueOmitsTheReasonRatherThanSendingANull() async throws {
        let transport = MockTransport()
        await transport.route("/issues/128", Fixture.response(json: "{\"number\":128}"))
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.setIssueState(repo: repo, number: 128, state: "open", stateReason: nil)

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "PATCH")
        XCTAssertEqual(bodyText(request), "{\"state\":\"open\"}")
    }

    // MARK: - The issue staleness probe

    func testTheIssueProbeReadsTheTimestampTheDrainComparesAgainst() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdIssueState",
            Fixture.response(
                json: """
                {"data":{"repository":{"issue":{
                  "id":"I_kwDOissue","updatedAt":"2026-09-03T08:15:00Z","closed":false
                }}}}
                """
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let state = try await client.issueState(repo: repo, number: 128)

        XCTAssertEqual(state.id, "I_kwDOissue")
        XCTAssertEqual(state.updatedAt, Date(timeIntervalSince1970: 1_788_423_300))
        XCTAssertFalse(state.isClosed)

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.url.absoluteString, "https://api.github.com/graphql")
    }

    func testAnIssueTheProbeCannotSeeIsNotFoundRatherThanASilentPass() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdIssueState",
            Fixture.response(json: "{\"data\":{\"repository\":{\"issue\":null}}}")
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.issueState(repo: repo, number: 404)
            XCTFail("expected a not-found error")
        } catch let error as GitHubError {
            guard case .notFound(let resource) = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
            XCTAssertEqual(resource, "schnaq/review#404")
        }
    }

    func testStalenessIsAOneSecondQuestionRatherThanAFloatingPointOne() {
        let base = Date(timeIntervalSince1970: 1_788_423_300)
        let state = IssueState(id: "I_1", updatedAt: base, isClosed: false)
        XCTAssertFalse(state.isStale(against: base))
        XCTAssertFalse(state.isStale(against: base.addingTimeInterval(0.4)))
        XCTAssertTrue(state.isStale(against: base.addingTimeInterval(-60)))
        XCTAssertTrue(state.isStale(against: base.addingTimeInterval(60)))
    }
}
