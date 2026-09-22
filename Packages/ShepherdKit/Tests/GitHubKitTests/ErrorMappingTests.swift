import Foundation
import ShepherdCore
import XCTest
@testable import GitHubKit

final class ErrorMappingTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let now = Date(timeIntervalSince1970: 1_788_162_000)

    private func mapped(_ response: HTTPResponse) -> GitHubError {
        GitHubClient.mapFailure(response, resource: "schnaq/review#128", now: now)
    }

    func testUnauthorized() {
        XCTAssertEqual(
            mapped(Fixture.response(json: "{\"message\":\"Bad credentials\"}", status: 401)),
            .unauthorized
        )
    }

    func testNotFoundCarriesTheResource() {
        guard case .notFound(let resource) = mapped(Fixture.empty(status: 404)) else {
            return XCTFail("expected .notFound")
        }
        XCTAssertEqual(resource, "schnaq/review#128")
    }

    func testValidationFailureIncludesFieldErrors() throws {
        let response = try Fixture.response("error-validation", status: 422)
        guard case .validationFailed(let message) = mapped(response) else {
            return XCTFail("expected .validationFailed")
        }
        XCTAssertTrue(message.contains("Validation Failed"))
        XCTAssertTrue(message.contains("line must be part of the diff"))
        XCTAssertTrue(message.contains("PullRequestReviewComment.line"))
    }

    func testSecondaryRateLimitWithRetryAfter() throws {
        let response = try Fixture.response(
            "error-rate-limit",
            status: 403,
            headers: ["Retry-After": "37"]
        )
        guard case .rateLimited(let retryAfter, _) = mapped(response) else {
            return XCTFail("expected .rateLimited")
        }
        XCTAssertEqual(retryAfter, 37)
    }

    func testPrimaryRateLimitUsesTheResetHeader() {
        let response = Fixture.response(
            json: "{\"message\":\"API rate limit exceeded\"}",
            status: 403,
            headers: [
                "x-ratelimit-limit": "5000",
                "x-ratelimit-remaining": "0",
                "x-ratelimit-used": "5000",
                "x-ratelimit-reset": "1788162600",
                "x-ratelimit-resource": "core",
            ]
        )
        guard case .rateLimited(let retryAfter, let resetAt) = mapped(response) else {
            return XCTFail("expected .rateLimited")
        }
        XCTAssertEqual(retryAfter, 600, "reset is 600 s after `now`")
        XCTAssertEqual(resetAt, Date(timeIntervalSince1970: 1_788_162_600))
    }

    func testTooManyRequestsIsAlwaysARateLimit() {
        let response = Fixture.response(json: "{}", status: 429, headers: ["retry-after": "5"])
        guard case .rateLimited(let retryAfter, _) = mapped(response) else {
            return XCTFail("expected .rateLimited")
        }
        XCTAssertEqual(retryAfter, 5)
    }

    func testForbiddenWithoutRateLimitSignalsStaysForbidden() {
        let response = Fixture.response(
            json: "{\"message\":\"Resource not accessible by integration\"}",
            status: 403,
            headers: ["x-ratelimit-remaining": "4900"]
        )
        guard case .forbidden(let message) = mapped(response) else {
            return XCTFail("expected .forbidden")
        }
        XCTAssertTrue(message.contains("not accessible"))
    }

    func testServerErrorsKeepTheirStatus() {
        guard case .server(let status, _) = mapped(Fixture.empty(status: 502)) else {
            return XCTFail("expected .server")
        }
        XCTAssertEqual(status, 502)
    }

    func testRetryabilityMatchesTheKindOfFailure() {
        XCTAssertTrue(GitHubError.transport(message: "offline").isRetryable)
        XCTAssertTrue(GitHubError.rateLimited(retryAfter: 1, resetAt: nil).isRetryable)
        XCTAssertTrue(GitHubError.server(status: 502, message: "").isRetryable)
        XCTAssertFalse(GitHubError.unauthorized.isRetryable)
        XCTAssertFalse(GitHubError.validationFailed(message: "").isRetryable)
        XCTAssertFalse(GitHubError.staleHead(expected: "a", actual: "b").isRetryable)
    }

    func testEveryErrorHasAHumanReadableDescription() {
        let errors: [GitHubError] = [
            .invalidURL("nope"),
            .transport(message: "offline"),
            .unauthorized,
            .forbidden(message: "no"),
            .rateLimited(retryAfter: 30, resetAt: nil),
            .rateLimited(retryAfter: nil, resetAt: Date(timeIntervalSince1970: 0)),
            .rateLimited(retryAfter: nil, resetAt: nil),
            .notFound(resource: "x"),
            .validationFailed(message: "bad"),
            .notMergeable(message: "conflict"),
            .staleHead(expected: "a", actual: "b"),
            .conflict(message: "c"),
            .graphQL(messages: ["boom"]),
            .decoding(message: "shape"),
            .server(status: 500, message: "oops"),
            .deviceFlowDenied,
            .deviceFlowExpired,
            .deviceFlowError(code: "unsupported_grant_type", description: nil),
            .tokenRefreshFailed(message: "gone"),
            .missingToken(login: "octocat"),
            .missingToken(login: nil),
        ]
        for error in errors {
            XCTAssertFalse(
                (error.errorDescription ?? "").isEmpty,
                "\(error) has no description"
            )
        }
    }

    // MARK: - Retry behaviour

    func testRateLimitedRequestsAreRetriedWithTheServerSuppliedDelay() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdInboxSweep",
            Fixture.response(
                json: "{\"message\":\"secondary rate limit\"}",
                status: 403,
                headers: ["retry-after": "3"]
            )
        )
        let searchResponse = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", searchResponse)

        let sleeper = RecordingSleeper()
        let client = GitHubClient.makeForTesting(transport: transport, sleeper: sleeper)

        let summaries = try await client.searchOpenPullRequests(queries: [.involves])
        XCTAssertEqual(summaries.count, 2)

        let waits = await sleeper.recorded
        XCTAssertEqual(waits.count, 1)
        XCTAssertEqual(waits.first?.inSeconds ?? 0, 3, accuracy: 0.001)

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "the request is retried exactly once")
    }

    func testRetriesGiveUpAndSurfaceTheError() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdInboxSweep",
            Fixture.response(
                json: "{\"message\":\"secondary rate limit\"}",
                status: 403,
                headers: ["retry-after": "1"]
            )
        )
        let sleeper = RecordingSleeper()
        let configuration = GitHubConfiguration(maxRetries: 2)
        let client = GitHubClient.makeForTesting(
            transport: transport,
            configuration: configuration,
            sleeper: sleeper
        )

        do {
            _ = try await client.searchOpenPullRequests(queries: [.involves])
            XCTFail("expected the rate limit to surface")
        } catch let error as GitHubError {
            guard case .rateLimited = error else {
                return XCTFail("expected .rateLimited, got \(error)")
            }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3, "initial attempt plus two retries")
    }

    func testBackoffIsCappedByConfiguration() async throws {
        let transport = MockTransport()
        await transport.route(
            "ShepherdInboxSweep",
            Fixture.response(
                json: "{\"message\":\"rate limit\"}",
                status: 403,
                headers: ["retry-after": "3600"]
            )
        )
        let searchResponse = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", searchResponse)

        let sleeper = RecordingSleeper()
        let client = GitHubClient.makeForTesting(
            transport: transport,
            configuration: GitHubConfiguration(maxRetries: 1, maxBackoff: 30),
            sleeper: sleeper
        )
        _ = try await client.searchOpenPullRequests(queries: [.involves])

        let waits = await sleeper.recorded
        XCTAssertEqual(waits.first?.inSeconds ?? 0, 30, accuracy: 0.001)
    }

    func testRateLimitHeadersAreRecorded() async throws {
        let transport = MockTransport()
        let response = try Fixture.response(
            "search-response",
            headers: [
                "x-ratelimit-limit": "5000",
                "x-ratelimit-remaining": "4711",
                "x-ratelimit-used": "289",
                "x-ratelimit-reset": "1788165600",
                "x-ratelimit-resource": "graphql",
            ]
        )
        await transport.route("ShepherdInboxSweep", response)
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.searchOpenPullRequests(queries: [.involves])
        let snapshot = await client.latestRateLimit
        XCTAssertEqual(snapshot?.remaining, 4_711)
        XCTAssertEqual(snapshot?.limit, 5_000)
        XCTAssertEqual(snapshot?.resource, "graphql")
        XCTAssertEqual(snapshot?.isExhausted, false)
    }

    func testTransportFailuresAreRetriedThenSurfaced() async throws {
        let transport = MockTransport()
        await transport.failNext(1, with: .transport(message: "offline"))
        let searchResponse = try Fixture.response("search-response")
        await transport.route("ShepherdInboxSweep", searchResponse)

        let sleeper = RecordingSleeper()
        let client = GitHubClient.makeForTesting(transport: transport, sleeper: sleeper)
        let summaries = try await client.searchOpenPullRequests(queries: [.involves])
        XCTAssertEqual(summaries.count, 2)

        let waits = await sleeper.recorded
        XCTAssertEqual(waits.count, 1)
    }

    // MARK: - Retries and idempotency

    func testATransportFailureNeverReplaysAReviewSubmission() async throws {
        let transport = MockTransport()
        await transport.failNext(1, with: .transport(message: "the request timed out"))
        await transport.route("/pulls/128/reviews", try Fixture.response("review-submitted"))

        let sleeper = RecordingSleeper()
        let client = GitHubClient.makeForTesting(transport: transport, sleeper: sleeper)

        do {
            _ = try await client.submitReview(
                ReviewDraft(prID: "PR_1", verdict: .approve, basedOnHeadOid: "abc123"),
                repo: RepoRef(owner: "schnaq", name: "review"),
                number: 128
            )
            XCTFail("the transport failure must surface, not be papered over with a retry")
        } catch let error as GitHubError {
            guard case .transport = error else {
                return XCTFail("expected .transport, got \(error)")
            }
        }

        // A POST that timed out may well have been executed: GitHub could have created the
        // review and lost the response. Replaying it is how one review becomes two.
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "a write is never replayed on a transport error")
        let waits = await sleeper.recorded
        XCTAssertTrue(waits.isEmpty)
    }

    func testATransportFailureNeverReplaysAMergeOrAReply() async throws {
        let repo = RepoRef(owner: "schnaq", name: "review")
        for attempt in 0..<2 {
            let transport = MockTransport()
            await transport.failNext(1, with: .transport(message: "connection reset"))
            await transport.route("/merge", try Fixture.response("merge-result"))
            await transport.route("/replies", Fixture.response(json: "{}"))
            let client = GitHubClient.makeForTesting(transport: transport)

            if attempt == 0 {
                _ = try? await client.mergePullRequest(
                    repo: repo,
                    number: 128,
                    method: .squash,
                    expectedHeadOid: "abc123"
                )
            } else {
                try? await client.replyToComment(
                    repo: repo,
                    number: 128,
                    commentID: 42,
                    body: "Thanks!"
                )
            }

            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1, "attempt \(attempt) must not be replayed")
        }
    }

    func testATransportFailureNeverReplaysAGraphQLMutation() async throws {
        let transport = MockTransport()
        await transport.failNext(1, with: .transport(message: "offline"))
        await transport.route("resolveReviewThread", try Fixture.response("resolve-thread"))
        let client = GitHubClient.makeForTesting(transport: transport)

        // GraphQL always POSTs, so the method cannot tell a query from a mutation; the call
        // site declares it. A resolve that may already have landed is not replayed.
        try? await client.resolveThread(id: "PRRT_1")

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testIdempotentMethodClassification() {
        XCTAssertTrue(GitHubClient.isIdempotentMethod("GET"))
        XCTAssertTrue(GitHubClient.isIdempotentMethod("get"))
        XCTAssertTrue(GitHubClient.isIdempotentMethod("HEAD"))
        XCTAssertFalse(GitHubClient.isIdempotentMethod("POST"))
        XCTAssertFalse(GitHubClient.isIdempotentMethod("PUT"))
        XCTAssertFalse(GitHubClient.isIdempotentMethod("PATCH"))
        XCTAssertFalse(GitHubClient.isIdempotentMethod("DELETE"))
    }

    // MARK: - Review submission preconditions

    func testAReviewThatCommentsOrRequestsChangesNeedsABody() async throws {
        let repo = RepoRef(owner: "schnaq", name: "review")
        for verdict in [ReviewVerdict.comment, .requestChanges] {
            let transport = MockTransport()
            await transport.route("/pulls/128/reviews", try Fixture.response("review-submitted"))
            let client = GitHubClient.makeForTesting(transport: transport)

            do {
                _ = try await client.submitReview(
                    ReviewDraft(prID: "PR_1", verdict: verdict, summaryBody: "   ", basedOnHeadOid: "abc123"),
                    repo: repo,
                    number: 128
                )
                XCTFail("\(verdict) without a body must not reach GitHub")
            } catch let error as GitHubError {
                guard case .validationFailed = error else {
                    return XCTFail("expected .validationFailed, got \(error)")
                }
            }

            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty, "\(verdict) is rejected before the request is built")
        }
    }

    func testAnApprovalMayBeSubmittedWithoutABody() async throws {
        let transport = MockTransport()
        await transport.route("/pulls/128/reviews", try Fixture.response("review-submitted"))
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.submitReview(
            ReviewDraft(prID: "PR_1", verdict: .approve, summaryBody: "", basedOnHeadOid: "abc123"),
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 128
        )

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testAPendingReviewWithoutAVerdictMayHaveNoBody() async throws {
        let transport = MockTransport()
        await transport.route("/pulls/128/reviews", try Fixture.response("review-pending"))
        let client = GitHubClient.makeForTesting(transport: transport)

        _ = try await client.submitReview(
            ReviewDraft(prID: "PR_1", verdict: nil, summaryBody: "", basedOnHeadOid: "abc123"),
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 128
        )

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }
}

/// ``GitHubError/storageCode`` — the value the outbox's `lastErrorCode` column holds so the app can
/// say a stored error in the user's language (ADR 0022, 2026-09-22 amendment).
final class GitHubErrorStorageCodeTests: XCTestCase {
    func testEveryShapeOfPayloadSurvivesTheRoundTrip() {
        let errors: [GitHubError] = [
            .invalidURL("not a url"),
            .transport(message: "offline"),
            .unauthorized,
            .forbidden(message: "Resource not accessible by integration"),
            .rateLimited(retryAfter: 42, resetAt: Date(timeIntervalSince1970: 1_788_162_000)),
            .rateLimited(retryAfter: nil, resetAt: nil),
            .notFound(resource: "schnaq/review#128"),
            .validationFailed(message: "line not in diff"),
            .notMergeable(message: "Pull Request is not mergeable"),
            .staleHead(expected: "abc", actual: nil),
            .conflict(message: "reference already exists"),
            .graphQL(messages: ["one", "two"]),
            .decoding(message: "keyNotFound"),
            .responseTooLarge(resource: "log", bytes: 20_000_000, limit: 10_000_000),
            .server(status: 502, message: "bad gateway"),
            .deviceFlowDenied,
            .deviceFlowExpired,
            .deviceFlowError(code: "unsupported_grant_type", description: nil),
            .tokenRefreshFailed(message: "bad_refresh_token"),
            .missingToken(login: "octocat"),
            .missingToken(login: nil),
        ]
        for error in errors {
            XCTAssertEqual(GitHubError(storageCode: error.storageCode), error, "\(error)")
        }
    }

    func testTheCodeIsKeyedByTheCaseNameSoItStaysReadableAcrossBuilds() {
        // The contract the column relies on: the case name and its labels, nothing positional
        // beyond the unlabelled `invalidURL`. A rename would change this string — and the test.
        XCTAssertEqual(
            GitHubError.server(status: 502, message: "bad gateway").storageCode,
            #"{"server":{"message":"bad gateway","status":502}}"#
        )
    }

    func testAStringNoBuildWroteDecodesToNothingRatherThanAGuess() {
        XCTAssertNil(GitHubError(storageCode: ""))
        XCTAssertNil(GitHubError(storageCode: "422 Unprocessable Entity"))
        XCTAssertNil(GitHubError(storageCode: #"{"renamedCase":{}}"#))
    }
}
