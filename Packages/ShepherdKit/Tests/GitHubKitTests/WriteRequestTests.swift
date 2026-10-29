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

/// The `PUT /pulls/{n}/merge-async` body (ADR 0042).
private struct AsyncMergeRequestBody: Decodable {
    var sha: String?
    var merge_method: String?
}

/// The `PUT /pulls/{n}/update-branch` body (ADR 0041).
private struct UpdateBranchRequestBody: Decodable {
    var expected_head_sha: String?
}

private struct ReplyRequestBody: Decodable {
    var body: String
}

/// A GraphQL request body: the document and the variables it is sent with. Every variable a
/// reaction mutation takes is a string, so a plain dictionary reads them all.
private struct GraphQLRequestEnvelope: Decodable {
    var query: String
    var variables: [String: String]
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

    func testASingleCommentPostsToThePullRequestCommentsEndpoint() async throws {
        let transport = MockTransport()
        await transport.route("/pulls/128/comments", Fixture.response(json: "{\"id\": 1}", status: 201))
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.addReviewComment(
            DraftComment(path: "Sources/App.swift", line: 9, side: .right, startLine: 7, body: "Nit"),
            commitOid: "head-1",
            repo: repo,
            number: 128
        )

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.url.absoluteString, "https://api.github.com/repos/schnaq/review/pulls/128/comments")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request?.body ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(json["body"] as? String, "Nit")
        XCTAssertEqual(json["commit_id"] as? String, "head-1")
        XCTAssertEqual(json["path"] as? String, "Sources/App.swift")
        XCTAssertEqual(json["line"] as? Int, 9)
        XCTAssertEqual(json["side"] as? String, "RIGHT")
        XCTAssertEqual(json["start_line"] as? Int, 7)
        XCTAssertEqual(json["start_side"] as? String, "RIGHT")
    }

    func testAnAttachmentIsUploadedScopedToTheRepository() async throws {
        let transport = MockTransport()
        await transport.route("/repos/schnaq/review", Fixture.response(json: "{\"id\": 4242}", status: 200))
        await transport.route(
            "/user-attachments/assets",
            Fixture.response(json: "{\"href\": \"https://github.com/user-attachments/assets/abc\"}", status: 201)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let url = try await client.uploadAttachment(
            Data([0x89, 0x50]),
            name: "Screenshot.png",
            contentType: "image/png",
            repo: repo
        )

        XCTAssertEqual(url.absoluteString, "https://github.com/user-attachments/assets/abc")
        let upload = await transport.requests.last
        XCTAssertEqual(upload?.method, "POST")
        XCTAssertEqual(
            upload?.url.absoluteString,
            "https://uploads.github.com/user-attachments/assets?name=Screenshot.png&content_type=image/png&repository_id=4242"
        )
        XCTAssertEqual(upload?.headers["Content-Type"], "image/png")
        XCTAssertEqual(upload?.body, Data([0x89, 0x50]))
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

    // MARK: - Edits and deletes (ADR 0043)

    func testEachTargetIsEditedAtItsOwnEndpointWithOnlyTheBody() async throws {
        let cases: [(ConversationTarget, String, String)] = [
            (.description, "PATCH", "/repos/schnaq/review/pulls/128"),
            (.issueComment(databaseID: 11), "PATCH", "/repos/schnaq/review/issues/comments/11"),
            (.reviewComment(databaseID: 12), "PATCH", "/repos/schnaq/review/pulls/comments/12"),
            (.review(databaseID: 13), "PUT", "/repos/schnaq/review/pulls/128/reviews/13"),
        ]
        for (target, method, path) in cases {
            let transport = MockTransport()
            await transport.route("/repos/", Fixture.response(json: "{\"id\": 1}"))
            let client = GitHubClient.makeForTesting(transport: transport)

            try await client.editConversationText(target, body: "New", repo: repo, number: 128)

            let request = await transport.onlyRequest()
            XCTAssertEqual(request?.method, method, "\(target)")
            XCTAssertEqual(request?.url.absoluteString, "https://api.github.com" + path)
            XCTAssertEqual(try decodeBody(ReplyRequestBody.self, from: request).body, "New")
            XCTAssertEqual(bodyText(request), #"{"body":"New"}"#, "nothing but the body")
        }
    }

    func testEachCommentKindIsDeletedAtItsOwnEndpoint() async throws {
        let cases: [(ConversationTarget, String)] = [
            (.issueComment(databaseID: 11), "/repos/schnaq/review/issues/comments/11"),
            (.reviewComment(databaseID: 12), "/repos/schnaq/review/pulls/comments/12"),
        ]
        for (target, path) in cases {
            let transport = MockTransport()
            await transport.route("/repos/", Fixture.empty(status: 204))
            let client = GitHubClient.makeForTesting(transport: transport)

            try await client.deleteConversationComment(target, repo: repo)

            let request = await transport.onlyRequest()
            XCTAssertEqual(request?.method, "DELETE")
            XCTAssertEqual(request?.url.absoluteString, "https://api.github.com" + path)
            XCTAssertTrue((request?.body ?? Data()).isEmpty)
        }
    }

    func testAGoneCommentIsNotFoundForTheDrainToJudge() async throws {
        let transport = MockTransport()
        await transport.route("/repos/", Fixture.response(json: #"{"message":"Not Found"}"#, status: 404))
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            try await client.deleteConversationComment(.issueComment(databaseID: 11), repo: repo)
            XCTFail("expected not found")
        } catch let error as GitHubError {
            guard case .notFound = error else { return XCTFail("expected .notFound, got \(error)") }
        }
    }

    func testATargetWithNoDeleteIsRefusedWithoutARequestAndIsNotNotFound() async throws {
        let transport = MockTransport()
        let client = GitHubClient.makeForTesting(transport: transport)

        for target in [ConversationTarget.description, .review(databaseID: 13)] {
            do {
                try await client.deleteConversationComment(target, repo: repo)
                XCTFail("expected a refusal")
            } catch let error as GitHubError {
                // Never `.notFound`, which the drain reads as a delete that is done.
                guard case .validationFailed = error else {
                    return XCTFail("expected .validationFailed, got \(error)")
                }
                XCTAssertFalse(error.isRetryable)
            }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty, "nothing was sent")
    }

    // MARK: - Reactions (ADR 0043)

    func testAddReactionSendsTheAddMutationWithTheSubjectAndTheContentName() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdAddReaction",
            Fixture.response(json: #"{"data":{"addReaction":{"reaction":{"content":"THUMBS_UP"}}}}"#)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.setReaction(subjectID: "IC_kwDOComment1", content: .thumbsUp, adding: true)

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.url.absoluteString, "https://api.github.com/graphql")
        let body = try decodeBody(GraphQLRequestEnvelope.self, from: request)
        XCTAssertTrue(body.query.contains("mutation ShepherdAddReaction"), body.query)
        XCTAssertTrue(body.query.contains("addReaction(input:"), body.query)
        XCTAssertFalse(body.query.contains("removeReaction"), body.query)
        // The enum's GraphQL name, not Swift's case name: `thumbsUp` would be a validation error.
        XCTAssertEqual(
            body.variables,
            ["subjectId": "IC_kwDOComment1", "content": "THUMBS_UP"]
        )
    }

    func testRemoveReactionSendsTheRemoveMutation() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdRemoveReaction",
            Fixture.response(json: #"{"data":{"removeReaction":{"reaction":{"content":"THUMBS_DOWN"}}}}"#)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.setReaction(subjectID: "PRR_kwDOReview1", content: .thumbsDown, adding: false)

        let request = await transport.onlyRequest()
        let body = try decodeBody(GraphQLRequestEnvelope.self, from: request)
        XCTAssertTrue(body.query.contains("mutation ShepherdRemoveReaction"), body.query)
        XCTAssertTrue(body.query.contains("removeReaction(input:"), body.query)
        XCTAssertFalse(body.query.contains("addReaction"), body.query)
        XCTAssertEqual(
            body.variables,
            ["subjectId": "PRR_kwDOReview1", "content": "THUMBS_DOWN"]
        )
    }

    func testARemovalGitHubAnswersWithNoReactionIsStillASuccess() async throws {
        // The payload's reaction is nullable in GitHub's schema, and nothing reads it. An answer
        // without one must not become a decoding failure, which would leave a failed row behind
        // for a removal that landed.
        let transport = MockTransport()
        await transport.route(
            "ShepherdRemoveReaction",
            Fixture.response(json: #"{"data":{"removeReaction":{"reaction":null}}}"#)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.setReaction(subjectID: "IC_1", content: .heart, adding: false)
    }

    func testARemovalOfAReactionTheViewerDoesNotHaveIsThrownForTheDrainToJudge() async throws {
        // GitHub's answer, verified live on 2026-10-16, is word for word a permission refusal. The
        // client translates it and decides nothing: the drain reads the post to tell the two apart.
        let transport = MockTransport()
        await transport.route(
            "ShepherdRemoveReaction",
            Fixture.response(json: """
            {"data":{"removeReaction":null},"errors":[{"type":"FORBIDDEN","path":["removeReaction"],\
            "message":"n2o does not have the correct permissions to execute `RemoveReaction`"}]}
            """)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            try await client.setReaction(subjectID: "IC_1", content: .heart, adding: false)
            XCTFail("expected a GraphQL error")
        } catch GitHubError.graphQL(let messages) {
            XCTAssertEqual(
                messages,
                ["n2o does not have the correct permissions to execute `RemoveReaction`"]
            )
        }
    }

    func testTheReactionReadAsksThePostForItsGroupsAndFindsTheViewersOwn() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdViewerReactions",
            Fixture.response(json: """
            {"data":{"node":{"reactionGroups":[\
            {"content":"THUMBS_UP","viewerHasReacted":true},\
            {"content":"HEART","viewerHasReacted":false}]}}}
            """)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let hasThumbsUp = try await client.viewerHasReacted(subjectID: "IC_kwDOComment1", content: .thumbsUp)

        XCTAssertTrue(hasThumbsUp)
        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.url.absoluteString, "https://api.github.com/graphql")
        let body = try decodeBody(GraphQLRequestEnvelope.self, from: request)
        XCTAssertTrue(body.query.contains("query ShepherdViewerReactions"), body.query)
        XCTAssertTrue(body.query.contains("node(id: $subjectId)"), body.query)
        XCTAssertTrue(body.query.contains("... on Reactable"), body.query)
        XCTAssertTrue(body.query.contains("viewerHasReacted"), body.query)
        // The post alone: the content is looked for in the answer, every group comes back anyway.
        XCTAssertEqual(body.variables, ["subjectId": "IC_kwDOComment1"])

        // A group the viewer is not in, and a group the post does not have, are both "no".
        let hasHeart = try await client.viewerHasReacted(subjectID: "IC_kwDOComment1", content: .heart)
        XCTAssertFalse(hasHeart)
        let hasRocket = try await client.viewerHasReacted(subjectID: "IC_kwDOComment1", content: .rocket)
        XCTAssertFalse(hasRocket)
    }

    func testTheReactionReadOfANodeGitHubDoesNotAnswerIsNo() async throws {
        let transport = MockTransport()
        await transport.route("ShepherdViewerReactions", Fixture.response(json: #"{"data":{"node":null}}"#))
        let client = GitHubClient.makeForTesting(transport: transport)

        let hasReacted = try await client.viewerHasReacted(subjectID: "IC_gone", content: .heart)

        XCTAssertFalse(hasReacted)
    }

    func testTheReactionReadThrowsANodeGitHubNulledBehindAnError() async throws {
        // Not partial data: a node nulled for a permission or SAML says nothing about the
        // reaction, and reading it as "none" would take a refused removal for done.
        let transport = MockTransport()
        await transport.route(
            "ShepherdViewerReactions",
            Fixture.response(json: """
            {"data":{"node":null},"errors":[{"type":"FORBIDDEN","path":["node"],\
            "message":"Resource protected by organization SAML enforcement."}]}
            """)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.viewerHasReacted(subjectID: "IC_1", content: .heart)
            XCTFail("expected a GraphQL error")
        } catch GitHubError.graphQL(let messages) {
            XCTAssertEqual(messages, ["Resource protected by organization SAML enforcement."])
        }
    }

    func testAReactionIsNeverReplayedAfterAConnectionFailure() async throws {
        // Like every GraphQL mutation: the method cannot say it is not a query, so the call
        // site does. A reaction that may have landed is retried by its outbox row, which can
        // tell the outcome apart, and not by the transport.
        let transport = MockTransport()
        await transport.failNext(1, with: .transport(message: "offline"))
        await transport.route(
            "ShepherdAddReaction",
            Fixture.response(json: #"{"data":{"addReaction":{"reaction":{"content":"EYES"}}}}"#)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            try await client.setReaction(subjectID: "IC_1", content: .eyes, adding: true)
            XCTFail("expected the connection failure to surface")
        } catch GitHubError.transport {
            // Expected: surfaced to the drain, which backs the row off.
        }

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
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

    // MARK: - Update branch (ADR 0041)

    func testUpdatingABranchIsOnePutPinnedToTheHeadTheUserSaw() async throws {
        let transport = MockTransport()
        await transport.route(
            "/update-branch",
            Fixture.response(
                json: "{\"message\":\"Updating pull request branch.\",\"url\":\"https://github.com\"}",
                status: 202
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.updatePullRequestBranch(
            repo: repo,
            number: 128,
            expectedHeadOid: "3f1a9c0d"
        )

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "PUT")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/pulls/128/update-branch"
        )
        let body = try decodeBody(UpdateBranchRequestBody.self, from: request)
        XCTAssertEqual(body.expected_head_sha, "3f1a9c0d")
    }

    func testAnUnpinnedUpdateSendsNoShaKeyRatherThanANull() async throws {
        let transport = MockTransport()
        await transport.route(
            "/update-branch",
            Fixture.response(json: "{\"message\":\"Updating pull request branch.\"}", status: 202)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.updatePullRequestBranch(repo: repo, number: 128, expectedHeadOid: nil)

        let request = await transport.onlyRequest()
        XCTAssertFalse(bodyText(request).contains("expected_head_sha"))
    }

    func testAHeadThatMovedBecomesStaleHeadLikeTheMergesConflict() async throws {
        // GitHub answers a failed `expected_head_sha` with a 422, not the merge endpoint's 409,
        // and the drain must park it the same way: the pin exists so that a push nobody saw is
        // never built on.
        let transport = MockTransport()
        await transport.route(
            "/update-branch",
            Fixture.response(
                json: "{\"message\":\"expected head sha didn't match current head ref.\"}",
                status: 422
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            try await client.updatePullRequestBranch(
                repo: repo,
                number: 128,
                expectedHeadOid: "3f1a9c0d"
            )
            XCTFail("expected a stale head error")
        } catch let error as GitHubError {
            guard case .staleHead(let expected, let actual) = error else {
                return XCTFail("expected .staleHead, got \(error)")
            }
            XCTAssertEqual(expected, "3f1a9c0d")
            XCTAssertNil(actual)
        }
    }

    func testAnyOtherRefusedUpdateStaysAValidationError() async throws {
        let transport = MockTransport()
        await transport.route(
            "/update-branch",
            Fixture.response(
                json: "{\"message\":\"merge conflict between base and head\"}",
                status: 422
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            try await client.updatePullRequestBranch(
                repo: repo,
                number: 128,
                expectedHeadOid: "3f1a9c0d"
            )
            XCTFail("expected a validation error")
        } catch let error as GitHubError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("expected .validationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("merge conflict"))
        }
    }

    // MARK: - Asynchronous merge (ADR 0042)

    /// A `merge-async` answer in the long shape GitHub documents for an accepted merge.
    private func asyncMergeJSON(status: String) -> String {
        """
        {"status":"\(status)","details":{"message":"ok","uuid":"5f0e-uuid","merge_method":"squash",\
        "merge_action":"default","expected_head_sha":"3f1a9c0d"}}
        """
    }

    func testAnAsynchronousMergeIsOnePutPinnedToTheHeadWithItsMethod() async throws {
        let transport = MockTransport()
        await transport.route(
            "/merge-async",
            Fixture.response(json: asyncMergeJSON(status: "pending"), status: 202)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let result = try await client.mergePullRequestAsync(
            repo: repo,
            number: 128,
            method: .squash,
            expectedHeadOid: "3f1a9c0d"
        )

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "PUT")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/pulls/128/merge-async"
        )
        let body = try decodeBody(AsyncMergeRequestBody.self, from: request)
        XCTAssertEqual(body.sha, "3f1a9c0d")
        XCTAssertEqual(body.merge_method, "squash")
        // GitHub's default action is what a Merge press means, and a title is not Shepherd's to
        // set: neither key is sent.
        XCTAssertFalse(bodyText(request).contains("merge_action"))
        XCTAssertFalse(bodyText(request).contains("commit_title"))
        XCTAssertEqual(result.status, .pending)
        XCTAssertEqual(result.uuid, "5f0e-uuid")
        XCTAssertEqual(result.message, "ok")
        XCTAssertEqual(result.mergeMethod, "squash")
        XCTAssertEqual(result.mergeAction, "default")
        XCTAssertEqual(result.expectedHeadSha, "3f1a9c0d")
    }

    func testAnUnpinnedAsynchronousMergeSendsNoShaKeyRatherThanANull() async throws {
        let transport = MockTransport()
        await transport.route(
            "/merge-async",
            Fixture.response(json: asyncMergeJSON(status: "pending"), status: 202)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.mergePullRequestAsync(
            repo: repo,
            number: 128,
            method: .merge,
            expectedHeadOid: nil
        )

        let request = await transport.onlyRequest()
        XCTAssertFalse(bodyText(request).contains("sha"))
        XCTAssertEqual(
            try decodeBody(AsyncMergeRequestBody.self, from: request).merge_method,
            "merge"
        )
    }

    func testEveryAsynchronousMergeStatusIsDecoded() async throws {
        let cases: [(String, AsyncMergeResult.Status)] = [
            ("pending", .pending), ("merged", .merged), ("enqueued", .enqueued), ("failed", .failed),
        ]
        for (word, expected) in cases {
            let transport = MockTransport()
            await transport.route(
                "/merge-async",
                Fixture.response(json: asyncMergeJSON(status: word), status: 202)
            )
            let client = GitHubClient.makeForTesting(transport: transport)

            let result = try await client.mergePullRequestAsync(
                repo: repo,
                number: 128,
                method: .squash,
                expectedHeadOid: "3f1a9c0d"
            )
            XCTAssertEqual(result.status, expected, word)
        }
    }

    func testAnAlreadyMergedAnswerWithOnlyAMessageAndAShaStillDecodes() async throws {
        // GitHub answers `200` with `details: {message, sha}` for a pull request that is merged
        // already; that shape, like the bare `{message}`, carries no uuid.
        let transport = MockTransport()
        await transport.route(
            "/merge-async",
            Fixture.response(
                json: #"{"status":"merged","details":{"message":"Already merged","sha":"9999"}}"#,
                status: 200
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let result = try await client.mergePullRequestAsync(
            repo: repo,
            number: 128,
            method: .squash,
            expectedHeadOid: "3f1a9c0d"
        )
        XCTAssertEqual(result.status, .merged)
        XCTAssertNil(result.uuid)
        XCTAssertEqual(result.sha, "9999")
        XCTAssertEqual(result.message, "Already merged")
    }

    func testAStatusWordThisBuildDoesNotKnowReadsAsPendingRatherThanAsAFailure() async throws {
        // By the time the answer is read GitHub has accepted the merge; a decoding error here
        // would report a merge that is running as one that did not happen.
        let transport = MockTransport()
        await transport.route(
            "/merge-async",
            Fixture.response(json: asyncMergeJSON(status: "rebasing"), status: 202)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let result = try await client.mergePullRequestAsync(
            repo: repo,
            number: 128,
            method: .squash,
            expectedHeadOid: nil
        )
        XCTAssertEqual(result.status, .pending)
    }

    func testTheStatusOfAnAsynchronousMergeIsOneGetByItsUuid() async throws {
        let transport = MockTransport()
        await transport.route(
            "/merge-async/5f0e-uuid",
            Fixture.response(json: asyncMergeJSON(status: "enqueued"), status: 200)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let result = try await client.asyncMergeStatus(repo: repo, number: 128, uuid: "5f0e-uuid")

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/pulls/128/merge-async/5f0e-uuid"
        )
        XCTAssertEqual(result.status, .enqueued)
        XCTAssertEqual(result.uuid, "5f0e-uuid")
    }

    func testAPullRequestThatIsNotReadyIsNotMergeableRatherThanARetryableServerError() async throws {
        // `400` is GitHub's "closed or draft"; left as `.server(400)` it would be retried for ever.
        let transport = MockTransport()
        await transport.route(
            "/merge-async",
            Fixture.response(json: #"{"message":"Pull request is in draft state"}"#, status: 400)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.mergePullRequestAsync(
                repo: repo,
                number: 128,
                method: .merge,
                expectedHeadOid: nil
            )
            XCTFail("expected a not-mergeable error")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .notMergeable(message: "Pull request is in draft state"))
            XCTAssertFalse(error.isRetryable)
        }
    }

    func testAnAsynchronousMergeWhoseHeadMovedBecomesStaleHead() async throws {
        let transport = MockTransport()
        await transport.route(
            "/merge-async",
            Fixture.response(
                json: #"{"message":"expected head sha didn't match current head ref."}"#,
                status: 422
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.mergePullRequestAsync(
                repo: repo,
                number: 128,
                method: .merge,
                expectedHeadOid: "3f1a9c0d"
            )
            XCTFail("expected a stale head error")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .staleHead(expected: "3f1a9c0d", actual: nil))
        }
    }

    func testAnyOtherRefusedAsynchronousMergeStaysAValidationError() async throws {
        let transport = MockTransport()
        await transport.route(
            "/merge-async",
            Fixture.response(json: #"{"message":"Required status check is failing"}"#, status: 422)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.mergePullRequestAsync(
                repo: repo,
                number: 128,
                method: .merge,
                expectedHeadOid: "3f1a9c0d"
            )
            XCTFail("expected a validation error")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .validationFailed(message: "Required status check is failing"))
        }
    }

    func testAMergeAlreadyUnderWayStaysAConflictAndIsNotMistakenForAMovedHead() async throws {
        // Unlike the synchronous endpoint, `409` here means "a merge request is already enqueued
        // for this pull request" — what a row re-sent after a crash finds.
        let transport = MockTransport()
        await transport.route(
            "/merge-async",
            Fixture.response(
                json: #"{"message":"A merge request is already enqueued for this pull request"}"#,
                status: 409
            )
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.mergePullRequestAsync(
                repo: repo,
                number: 128,
                method: .merge,
                expectedHeadOid: "3f1a9c0d"
            )
            XCTFail("expected a conflict")
        } catch let error as GitHubError {
            XCTAssertEqual(
                error,
                .conflict(message: "A merge request is already enqueued for this pull request")
            )
        }
    }

    func testAnAcceptedAsynchronousMergeWhoseBodyCannotBeReadIsPendingWithoutAUuid() async throws {
        // A `2xx` is GitHub's acceptance. A body this build cannot decode must not fail a row
        // for a merge that is running; the drain sends such an answer as started.
        let transport = MockTransport()
        await transport.route("/merge-async", Fixture.response(json: #"{"state":"accepted"}"#, status: 202))
        let client = GitHubClient.makeForTesting(transport: transport)

        let result = try await client.mergePullRequestAsync(
            repo: repo,
            number: 128,
            method: .squash,
            expectedHeadOid: "3f1a9c0d"
        )

        XCTAssertEqual(result.status, .pending)
        XCTAssertNil(result.uuid)
    }

    func testOnlyGitHubsAlreadyEnqueuedSentenceReadsAsAMergeUnderWay() {
        XCTAssertTrue(GitHubClient.isMergeAlreadyUnderWay(
            "A merge request is already enqueued for this pull request"
        ))
        XCTAssertTrue(GitHubClient.isMergeAlreadyUnderWay("Merge ALREADY in progress"))
        XCTAssertTrue(GitHubClient.isMergeAlreadyUnderWay("already enqueued"))
        XCTAssertFalse(GitHubClient.isMergeAlreadyUnderWay("Base branch was modified"))
        XCTAssertFalse(GitHubClient.isMergeAlreadyUnderWay("Merge already requested"))
        XCTAssertFalse(GitHubClient.isMergeAlreadyUnderWay("A merge request is enqueued"))
    }

    func testAPullRequestIsStackedWhenGitHubReportsItsStack() async throws {
        let transport = MockTransport()
        await transport.route(
            "/pulls/128",
            Fixture.response(json: #"{"number":128,"stack":{"number":7,"size":3,"position":2,"base":{"ref":"main"}}}"#)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let stacked = try await client.pullRequestIsStacked(repo: repo, number: 128)

        XCTAssertTrue(stacked)
        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.url.absoluteString, "https://api.github.com/repos/schnaq/review/pulls/128")
    }

    func testAPullRequestWithoutAStackObjectIsNotStacked() async throws {
        let transport = MockTransport()
        await transport.route("/pulls/128", Fixture.response(json: #"{"number":128,"stack":null}"#))
        let client = GitHubClient.makeForTesting(transport: transport)

        let stacked = try await client.pullRequestIsStacked(repo: repo, number: 128)

        XCTAssertFalse(stacked)
    }

    func testAnExpiredMergeUuidIsNotFound() async throws {
        let transport = MockTransport()
        await transport.route(
            "/merge-async/old-uuid",
            Fixture.response(json: #"{"message":"Not Found"}"#, status: 404)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.asyncMergeStatus(repo: repo, number: 128, uuid: "old-uuid")
            XCTFail("expected not found")
        } catch let error as GitHubError {
            guard case .notFound = error else { return XCTFail("expected .notFound, got \(error)") }
        }
    }

    // MARK: - "Has it already been merged?" (ADR 0005's second 2026-09-05 amendment)

    func testAMergedPullRequestAnswersTheProbeWithTrue() async throws {
        let transport = MockTransport()
        await transport.route("/merge", Fixture.empty(status: 204))
        let client = GitHubClient.makeForTesting(transport: transport)

        let isMerged = try await client.isPullRequestMerged(repo: repo, number: 128)

        XCTAssertTrue(isMerged)
        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/pulls/128/merge"
        )
        XCTAssertNil(request?.body, "the probe is a read and sends nothing")
    }

    func testAPullRequestThatIsNotMergedAnswersFalseRatherThanThrowing() async throws {
        // `404` is this endpoint's word for "no" rather than a failure. Throwing it would make
        // the drain unable to tell "it is not merged" from "we could not ask", and the second one
        // must never be read as the first.
        let transport = MockTransport()
        await transport.route("/merge", Fixture.empty(status: 404))
        let client = GitHubClient.makeForTesting(transport: transport)

        let isMerged = try await client.isPullRequestMerged(repo: repo, number: 128)

        XCTAssertFalse(isMerged)
    }

    func testAProbeThatCouldNotBeMadeIsStillAnError() async throws {
        // Every other status keeps being an error, which is what stops a rate-limited or broken
        // read from being reported as "not merged".
        let transport = MockTransport()
        await transport.route("/merge", Fixture.empty(status: 401))
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.isPullRequestMerged(repo: repo, number: 128)
            XCTFail("expected the probe to throw")
        } catch let error as GitHubError {
            guard case .unauthorized = error else {
                return XCTFail("expected .unauthorized, got \(error)")
            }
        }
    }

    // MARK: - "Can this token see the repository?"

    func testAReadableRepositoryAnswersTrue() async throws {
        let transport = MockTransport()
        await transport.route("/repos/schnaq/review", Fixture.response(json: #"{"id":1}"#))
        let client = GitHubClient.makeForTesting(transport: transport)

        let canRead = try await client.canRead(repo: repo)

        XCTAssertTrue(canRead)
        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.url.absoluteString, "https://api.github.com/repos/schnaq/review")
    }

    func testARepositoryTheTokenCannotSeeAnswersFalse() async throws {
        // 404 for a GitHub App not installed on the owner, 403 for an SSO-protected organization.
        for status in [404, 403] {
            let transport = MockTransport()
            await transport.route(
                "/repos/schnaq/review",
                Fixture.response(json: #"{"message":"Not Found"}"#, status: status)
            )
            let client = GitHubClient.makeForTesting(transport: transport)

            let canRead = try await client.canRead(repo: repo)

            XCTAssertFalse(canRead, "status \(status)")
        }
    }

    func testAnAccessCheckThatCouldNotBeMadeIsStillAnError() async throws {
        let transport = MockTransport()
        await transport.route("/repos/schnaq/review", Fixture.empty(status: 401))
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            _ = try await client.canRead(repo: repo)
            XCTFail("expected the check to throw")
        } catch let error as GitHubError {
            guard case .unauthorized = error else {
                return XCTFail("expected .unauthorized, got \(error)")
            }
        }
    }

    // MARK: - Branch deletion (ADR 0005's 2026-09-05 amendment)

    func testDeletingABranchIsOneDeleteToTheRefsEndpoint() async throws {
        let transport = MockTransport()
        await transport.route("/git/refs/heads/", Fixture.empty(status: 204))
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.deleteBranch(repo: repo, name: "agent/token-store")

        let request = await transport.onlyRequest()
        XCTAssertEqual(request?.method, "DELETE")
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/git/refs/heads/agent/token-store"
        )
        XCTAssertNil(request?.body, "a ref deletion carries no body")
    }

    func testABranchNameKeepsItsSlashesAndPercentEncodesTheRest() async throws {
        // The two halves of the same rule: `feature/thing` is *one* ref with a slash in it, so
        // the slash stays a path separator, while anything a path segment may not carry is
        // encoded rather than sent raw.
        let transport = MockTransport()
        await transport.route("/git/refs/heads/", Fixture.empty(status: 204))
        let client = GitHubClient.makeForTesting(transport: transport)

        try await client.deleteBranch(repo: repo, name: "feature/über")

        let request = await transport.onlyRequest()
        XCTAssertEqual(
            request?.url.absoluteString,
            "https://api.github.com/repos/schnaq/review/git/refs/heads/feature/%C3%BCber"
        )
    }

    func testADeletedRefIsAnOrdinaryTypedError() async throws {
        // What a repository with "automatically delete head branches" switched on answers with.
        // GitHubKit maps it like any other 422; deciding that it is *not* a problem is the
        // drain's job, not the client's.
        let transport = MockTransport()
        await transport.route(
            "/git/refs/heads/",
            Fixture.response(json: "{\"message\":\"Reference does not exist\"}", status: 422)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        do {
            try await client.deleteBranch(repo: repo, name: "agent/token-store")
            XCTFail("expected a validation error")
        } catch let error as GitHubError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("expected .validationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("Reference does not exist"))
        }
    }

    func testTheHeadBranchContextReadsTheBranchItsRepositoryAndTheDefaultBranch() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdHeadBranchContext",
            Fixture.response(json: """
            {"data":{"repository":{"defaultBranchRef":{"name":"main"},
            "pullRequest":{"headRefName":"agent/token-store",
            "headRepository":{"nameWithOwner":"schnaq/review"}}}}}
            """)
        )
        let client = GitHubClient.makeForTesting(transport: transport)

        let context = try await client.headBranchContext(repo: repo, number: 128)

        XCTAssertEqual(context.headRefName, "agent/token-store")
        XCTAssertEqual(context.headRepositoryFullName, "schnaq/review")
        XCTAssertEqual(context.defaultBranchName, "main")
        XCTAssertEqual(context.deletableBranch(in: repo), "agent/token-store")
    }

    func testTheGuardsRefuseAForkTheDefaultBranchAndAnUnansweredQuestion() {
        // A pure function, so the rule a merged branch is deleted under can be read without a
        // network at all — and every refusal below is a fact about GitHub, not an error.
        XCTAssertNil(
            HeadBranchContext(
                headRefName: "patch-1",
                headRepositoryFullName: "someone-else/review",
                defaultBranchName: "main"
            ).deletableBranch(in: repo),
            "a fork's branch is not ours to delete"
        )
        XCTAssertNil(
            HeadBranchContext(
                headRefName: "main",
                headRepositoryFullName: "schnaq/review",
                defaultBranchName: "main"
            ).deletableBranch(in: repo),
            "a pull request from main into a release branch must not delete main"
        )
        XCTAssertNil(
            HeadBranchContext(
                headRefName: "agent/token-store",
                headRepositoryFullName: nil,
                defaultBranchName: "main"
            ).deletableBranch(in: repo),
            "an unanswerable guard is a refusal, not permission"
        )
        XCTAssertNil(
            HeadBranchContext(
                headRefName: "agent/token-store",
                headRepositoryFullName: "schnaq/review",
                defaultBranchName: nil
            ).deletableBranch(in: repo),
            "a repository whose default branch is unknown keeps every branch"
        )
        XCTAssertEqual(
            HeadBranchContext(
                headRefName: "agent/token-store",
                headRepositoryFullName: "Schnaq/Review",
                defaultBranchName: "main"
            ).deletableBranch(in: repo),
            "agent/token-store",
            "GitHub's slugs are case-insensitive, so the repository comparison is too"
        )
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
