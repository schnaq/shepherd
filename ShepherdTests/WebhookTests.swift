import Foundation
import ShepherdCore
import ShepherdSync
import XCTest

@testable import Shepherd

/// A scripted webhook transport: records what was posted, answers from a script.
///
/// Locked rather than an actor so the assertions read straight through, the same shape
/// `ScriptedAgentRunner` uses for the agent CLI. The answers list is not consumed past its end —
/// the last one repeats — so a test that wants "always 503" writes it once.
final class RecordingPoster: WebhookPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [WebhookResponse]
    private let failure: WebhookError?
    private var recorded: [WebhookRequest] = []

    /// Creates a poster.
    /// - Parameters:
    ///   - answers: The statuses to answer with, in order.
    ///   - failure: When set, every attempt throws this instead of answering.
    init(answers: [WebhookResponse] = [], failure: WebhookError? = nil) {
        self.answers = answers
        self.failure = failure
    }

    /// Everything that was posted, in order.
    var requests: [WebhookRequest] {
        lock.withLock { recorded }
    }

    func post(_ request: WebhookRequest) async throws -> WebhookResponse {
        let answer = lock.withLock { () -> WebhookResponse in
            recorded.append(request)
            if answers.isEmpty {
                return WebhookResponse(status: 200)
            } else if answers.count > 1 {
                return answers.removeFirst()
            } else {
                return answers[0]
            }
        }
        if let failure { throw failure }
        return answer
    }
}

/// The outbound-webhook layer (ADR 0012): the payload schema, the HMAC signature, the retry
/// policy, and the mapping from Shepherd's own events to the four documented ones.
///
/// Nothing here touches the network. The dispatcher's transport is a protocol seam — the same
/// pattern `ModelListing` and `AgentRunning` use — so the retry policy is asserted against
/// scripted answers, and the payload against the exact bytes that would have been sent.
@MainActor
final class WebhookTests: XCTestCase {
    // MARK: - Fixtures

    private let repo = RepoRef(owner: "schnaq", name: "review")
    private let occurredAt = Date(timeIntervalSince1970: 1_788_162_000)
    private let occurredAtISO = "2026-08-31T07:40:00Z"
    private let deliveryID = UUID(uuidString: "0f7ac1de-0000-4000-8000-00000000002a")!
    private let destination = "https://n8n.example.com/webhook/shepherd"

    private func agentSummary() -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_kwDOexample",
            repo: repo,
            number: 42,
            title: "Fix the login flow",
            author: ShepherdCore.Actor(
                login: "claude[bot]",
                displayName: "Claude",
                avatarURL: nil,
                kind: .agent(
                    AgentIdentity(id: "claude-code", displayName: "Claude Code", matchedBy: .login)
                )
            ),
            updatedAt: occurredAt,
            createdAt: Date(timeIntervalSince1970: 1_788_100_000),
            isDraft: false,
            additions: 120,
            deletions: 8,
            changedFiles: 5,
            headRefName: "claude/fix-login",
            headRefOid: "abc123def456",
            baseRefName: "main",
            reviewDecision: .reviewRequired,
            checkRollup: CheckRollup(state: .success, total: 3),
            myRelation: [.reviewRequested, .mentioned],
            labels: ["bug", "agent"],
            mergeable: .mergeable
        )
    }

    private func humanSummary() -> PullRequestSummary {
        var summary = agentSummary()
        summary.author = ShepherdCore.Actor(
            login: "octocat",
            displayName: "The Octocat",
            avatarURL: nil,
            kind: .human
        )
        return summary
    }

    private func event(
        _ kind: WebhookEventKind,
        details: WebhookEventDetails,
        summary: PullRequestSummary? = nil
    ) -> WebhookEvent {
        WebhookEvent(
            event: kind,
            pullRequest: WebhookPullRequest(summary: summary ?? agentSummary()),
            details: details,
            occurredAt: occurredAt,
            deliveryID: deliveryID
        )
    }

    private func reviewEvent(
        verdict: String = "approve",
        comments: Int = 0
    ) -> WebhookEvent {
        event(
            .reviewSubmitted,
            details: .reviewSubmitted(verdict: verdict, inlineCommentCount: comments)
        )
    }

    private func object(_ event: WebhookEvent) throws -> [String: Any] {
        let data = try event.canonicalJSON()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func nested(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        try XCTUnwrap(object[key] as? [String: Any])
    }

    // MARK: - The envelope

    func testTheEnvelopeCarriesExactlyTheDocumentedKeys() throws {
        let json = try object(reviewEvent(comments: 2))

        XCTAssertEqual(
            json.keys.sorted(),
            ["details", "event", "id", "occurredAt", "pullRequest", "source", "v"],
            "the envelope is a contract; a new key is a schema change"
        )
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["source"] as? String, "shepherd")
        XCTAssertEqual(json["event"] as? String, "review.submitted")
        XCTAssertEqual(json["occurredAt"] as? String, occurredAtISO)
        XCTAssertEqual(json["id"] as? String, deliveryID.uuidString.lowercased())
    }

    func testEveryEventKindHasAStableDottedWireName() {
        XCTAssertEqual(
            WebhookEventKind.allCases.map(\.rawValue).sorted(),
            [
                "delegation.finished",
                "inbox.new_review_request",
                "issue.assigned_to_agent",
                "issue.closed",
                "pr.auto_merge_queued",
                "pr.merged",
                "review.submitted",
                "shepherd.test",
            ]
        )
        // The test event is delivered by a button, never subscribed to.
        XCTAssertFalse(WebhookEventKind.userSelectable.contains(.test))
        XCTAssertEqual(WebhookEventKind.userSelectable.count, 7)
        // Two events describe an issue; every other one describes a pull request, and the two
        // shapes are the whole vocabulary.
        XCTAssertEqual(
            WebhookEventKind.allCases.filter(\.isAboutAnIssue),
            [.issueClosed, .issueAssignedToAgent]
        )
        for kind in WebhookEventKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.explanation.isEmpty)
        }
    }

    func testEncodingIsAPureFunctionOfTheValue() throws {
        let subject = event(.pullRequestMerged, details: .merged(method: "squash"))
        let first = try subject.canonicalJSON()
        let second = try subject.canonicalJSON()
        XCTAssertEqual(
            first,
            second,
            "the signature is computed over these bytes, so they must not drift"
        )
    }

    // MARK: - The pull-request object

    func testThePullRequestObjectDescribesProvenanceAndSize() throws {
        let json = try nested(try object(reviewEvent()), "pullRequest")

        XCTAssertEqual(
            json.keys.sorted(),
            [
                "additions", "agentId", "author", "authorKind", "baseBranch", "branch",
                "changedFiles", "deletions", "headSha", "isAgentAuthored", "isDraft", "labels",
                "nodeId", "number", "owner", "repo", "title", "url",
            ]
        )
        XCTAssertEqual(json["owner"] as? String, "schnaq")
        XCTAssertEqual(json["repo"] as? String, "review")
        XCTAssertEqual(json["number"] as? Int, 42)
        XCTAssertEqual(json["nodeId"] as? String, "PR_kwDOexample")
        XCTAssertEqual(json["title"] as? String, "Fix the login flow")
        XCTAssertEqual(json["url"] as? String, "https://github.com/schnaq/review/pull/42")
        XCTAssertEqual(json["author"] as? String, "claude[bot]")
        XCTAssertEqual(json["authorKind"] as? String, "agent")
        XCTAssertEqual(json["isAgentAuthored"] as? Bool, true)
        XCTAssertEqual(json["agentId"] as? String, "claude-code")
        XCTAssertEqual(json["branch"] as? String, "claude/fix-login")
        XCTAssertEqual(json["baseBranch"] as? String, "main")
        XCTAssertEqual(json["headSha"] as? String, "abc123def456")
        XCTAssertEqual(json["isDraft"] as? Bool, false)
        XCTAssertEqual(json["additions"] as? Int, 120)
        XCTAssertEqual(json["deletions"] as? Int, 8)
        XCTAssertEqual(json["changedFiles"] as? Int, 5)
        XCTAssertEqual(json["labels"] as? [String], ["bug", "agent"])
    }

    func testTheURLIsNotEscapedSoItStaysReadableInTheReceiver() throws {
        let data = try reviewEvent().canonicalJSON()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("https://github.com/schnaq/review/pull/42"))
        XCTAssertFalse(text.contains("\\/"))
    }

    func testAHumanAuthoredPullRequestSaysSoWithAnExplicitNull() throws {
        let subject = event(
            .newReviewRequest,
            details: .newReviewRequest(relations: [], reviewDecision: nil, checks: nil),
            summary: humanSummary()
        )
        let json = try nested(try object(subject), "pullRequest")

        XCTAssertEqual(json["authorKind"] as? String, "human")
        XCTAssertEqual(json["isAgentAuthored"] as? Bool, false)
        // Present-and-null, not absent: a receiver must be able to tell "no agent" from
        // "this producer does not know about agents".
        XCTAssertTrue(json.keys.contains("agentId"))
        XCTAssertTrue(json["agentId"] is NSNull)
    }

    func testAPullRequestTheCacheHasAlreadyPrunedStillProducesTheFullShape() throws {
        // The real case this covers: a merge that succeeds just after a sweep removed the row.
        let subject = WebhookEvent(
            event: .pullRequestMerged,
            pullRequest: WebhookPullRequest(
                identity: WebhookPullRequest.Identity(prID: "PR_gone", repo: repo, number: 7)
            ),
            details: .merged(method: "merge"),
            occurredAt: occurredAt,
            deliveryID: deliveryID
        )
        let json = try nested(try object(subject), "pullRequest")

        XCTAssertEqual(json.keys.count, 18, "the shape does not change when the cache is empty")
        XCTAssertEqual(json["number"] as? Int, 7)
        XCTAssertEqual(json["owner"] as? String, "schnaq")
        XCTAssertEqual(json["url"] as? String, "https://github.com/schnaq/review/pull/7")
        XCTAssertEqual(json["title"] as? String, "")
        XCTAssertEqual(json["authorKind"] as? String, "unknown")
        XCTAssertEqual(json["labels"] as? [String], [])
    }

    // MARK: - The details objects

    func testReviewDetailsCarryTheVerdictAndTheCommentCount() throws {
        let json = try nested(
            try object(reviewEvent(verdict: "request_changes", comments: 3)),
            "details"
        )
        XCTAssertEqual(json.keys.sorted(), ["inlineCommentCount", "verdict"])
        XCTAssertEqual(json["verdict"] as? String, "request_changes")
        XCTAssertEqual(json["inlineCommentCount"] as? Int, 3)
    }

    func testTheVerdictWireValuesAreSnakeCaseAndCoverPending() {
        XCTAssertEqual(WebhookEventDetails.verdict(.approve), "approve")
        XCTAssertEqual(WebhookEventDetails.verdict(.requestChanges), "request_changes")
        XCTAssertEqual(WebhookEventDetails.verdict(.comment), "comment")
        XCTAssertEqual(WebhookEventDetails.verdict(nil), "pending")
    }

    func testMergeDetailsCarryTheMethod() throws {
        let json = try nested(
            try object(event(.pullRequestMerged, details: .merged(method: "rebase"))),
            "details"
        )
        XCTAssertEqual(json.keys.sorted(), ["mergeMethod"])
        XCTAssertEqual(json["mergeMethod"] as? String, "rebase")
    }

    func testDelegationDetailsCarryTheStatusAndNullTheAbsentReason() throws {
        let subject = event(
            .delegationFinished,
            details: .delegation(
                status: "finished",
                agent: "Claude Code",
                durationSeconds: 72,
                changedFileCount: 3,
                message: nil,
                automatic: false
            )
        )
        let json = try nested(try object(subject), "details")

        XCTAssertEqual(
            json.keys.sorted(),
            ["agent", "automatic", "changedFileCount", "durationSeconds", "message", "status"]
        )
        XCTAssertEqual(json["status"] as? String, "finished")
        XCTAssertEqual(json["agent"] as? String, "Claude Code")
        XCTAssertEqual(json["durationSeconds"] as? Int, 72)
        XCTAssertEqual(json["changedFileCount"] as? Int, 3)
        XCTAssertTrue(json["message"] is NSNull)
        // Additive under `"v": 1` (ADR 0016): always present, `false` for a run the user started.
        XCTAssertEqual(json["automatic"] as? Bool, false)
    }

    func testReviewRequestDetailsCarryTheTriageState() throws {
        let subject = event(
            .newReviewRequest,
            details: .newReviewRequest(
                relations: ["mentioned", "reviewRequested"],
                reviewDecision: "reviewRequired",
                checks: "success"
            )
        )
        let json = try nested(try object(subject), "details")

        XCTAssertEqual(json.keys.sorted(), ["checks", "relations", "reviewDecision"])
        XCTAssertEqual(json["relations"] as? [String], ["mentioned", "reviewRequested"])
        XCTAssertEqual(json["reviewDecision"] as? String, "reviewRequired")
        XCTAssertEqual(json["checks"] as? String, "success")
    }

    func testTheTestEventIsClearlyMarkedAsFictional() throws {
        let json = try object(WebhookEvent.testEvent(occurredAt: occurredAt))
        XCTAssertEqual(json["event"] as? String, "shepherd.test")
        let details = try nested(json, "details")
        XCTAssertEqual(details.keys.sorted(), ["note"])
        XCTAssertEqual((details["note"] as? String)?.contains("fictional"), true)
        let pullRequest = try nested(json, "pullRequest")
        XCTAssertEqual(pullRequest["owner"] as? String, "octocat")
    }

    // MARK: - Signature

    func testTheSignatureMatchesTheRFC4231VectorForHMACSHA256() {
        // RFC 4231, test case 2 — a known answer, so a change in the hashing itself fails here
        // rather than at a receiver that silently rejects everything.
        XCTAssertEqual(
            WebhookSignature.header(
                for: Data("what do ya want for nothing?".utf8),
                secret: "Jefe"
            ),
            "sha256=5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        )
    }

    func testTheSignatureIsLowercaseHexOverTheBodyAndOnlyExistsWithASecret() {
        let body = Data("{\"v\":1}".utf8)
        XCTAssertEqual(
            WebhookSignature.header(for: body, secret: "shepherd-secret"),
            "sha256=0b6098586d204e2c3d0a0dd07008fc0b50e02782cc7713630aca89c005098b85"
        )
        // No secret means no header at all, rather than a header a receiver would trust.
        XCTAssertNil(WebhookSignature.header(for: body, secret: ""))
        // A different secret over the same body, and the same secret over a different body,
        // both change the signature.
        XCTAssertNotEqual(
            WebhookSignature.header(for: body, secret: "a"),
            WebhookSignature.header(for: body, secret: "b")
        )
        XCTAssertNotEqual(
            WebhookSignature.header(for: body, secret: "a"),
            WebhookSignature.header(for: Data("{\"v\":2}".utf8), secret: "a")
        )
        XCTAssertEqual(WebhookSignature.headerName, "X-Shepherd-Signature")
    }

    // MARK: - URL validation

    func testOnlyHTTPSOrThisMachineIsAcceptedAsADestination() throws {
        let cleaned = try WebhookConfiguration.destination("  https://n8n.example.com/webhook/abc  ")
        XCTAssertEqual(cleaned.absoluteString, "https://n8n.example.com/webhook/abc")
        // A local n8n over plain HTTP is the common local-first case and is allowed.
        XCTAssertNoThrow(try WebhookConfiguration.destination("http://localhost:5678/webhook/abc"))
        XCTAssertNoThrow(try WebhookConfiguration.destination("http://127.0.0.1:5678/webhook/abc"))

        XCTAssertThrowsError(try WebhookConfiguration.destination("")) { error in
            XCTAssertEqual(error as? WebhookError, .notConfigured)
        }
        XCTAssertThrowsError(try WebhookConfiguration.destination("not a url")) { error in
            XCTAssertEqual(error as? WebhookError, .invalidURL)
        }
        XCTAssertThrowsError(try WebhookConfiguration.destination("ftp://example.com/x")) { error in
            XCTAssertEqual(error as? WebhookError, .invalidURL)
        }
        // Plain HTTP to somebody else's host would put pull-request titles on the wire in the
        // clear, so it is refused rather than silently downgraded.
        XCTAssertThrowsError(
            try WebhookConfiguration.destination("http://n8n.example.com/webhook/abc")
        ) { error in
            XCTAssertEqual(error as? WebhookError, .insecureScheme("n8n.example.com"))
        }
    }

    func testEveryFailureCarriesAUserReadableReason() {
        let failures: [WebhookError] = [
            .notConfigured, .invalidURL, .insecureScheme("host"), .malformedPayload,
            .rejected(status: 500), .transport("offline"),
        ]
        for failure in failures {
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true)
        }
    }

    // MARK: - The delivery gate

    func testNothingIsDeliveredUntilTheToggleTheURLAndTheEventAllAgree() async {
        let poster = RecordingPoster(answers: [WebhookResponse(status: 200)])
        let dispatcher = makeDispatcher(poster)
        let subject = reviewEvent()

        let gated: [WebhookConfiguration] = [
            // Feature off.
            WebhookConfiguration(isEnabled: false, urlText: destination, events: [.reviewSubmitted]),
            // No URL.
            WebhookConfiguration(isEnabled: true, urlText: "", events: [.reviewSubmitted]),
            // Event not subscribed to.
            WebhookConfiguration(isEnabled: true, urlText: destination, events: [.pullRequestMerged]),
        ]
        for configuration in gated {
            XCTAssertFalse(configuration.wantsEvent(.reviewSubmitted))
            await dispatcher.deliver(subject, configuration: configuration)
        }

        XCTAssertTrue(poster.requests.isEmpty)
        XCTAssertNil(dispatcher.lastDelivery, "a gated event is not a delivery attempt")
    }

    func testASubscribedEventIsPostedOnceWithItsHeadersAndSignature() async throws {
        let poster = RecordingPoster(answers: [WebhookResponse(status: 202)])
        let dispatcher = makeDispatcher(poster)
        let subject = reviewEvent(comments: 1)

        await dispatcher.deliver(subject, configuration: enabled(secret: "shepherd-secret"))

        XCTAssertEqual(poster.requests.count, 1)
        let request = try XCTUnwrap(poster.requests.first)
        XCTAssertEqual(request.url.absoluteString, destination)
        XCTAssertEqual(request.eventKind, .reviewSubmitted)
        XCTAssertEqual(request.deliveryID, deliveryID)
        XCTAssertEqual(request.body, try subject.canonicalJSON())
        XCTAssertEqual(
            request.signature,
            WebhookSignature.header(for: request.body, secret: "shepherd-secret")
        )
        XCTAssertEqual(request.timeout, WebhookDispatcher.timeout)

        let delivery = try XCTUnwrap(dispatcher.lastDelivery)
        XCTAssertTrue(delivery.isSuccess)
        XCTAssertEqual(delivery.attempts, 1)
        XCTAssertEqual(delivery.event, .reviewSubmitted)
    }

    func testAnUnsignedDeliveryOmitsTheHeaderRatherThanSendingAnEmptyOne() async {
        let poster = RecordingPoster(answers: [WebhookResponse(status: 200)])
        let dispatcher = makeDispatcher(poster)

        await dispatcher.deliver(
            event(.pullRequestMerged, details: .merged(method: "squash")),
            configuration: enabled(secret: "")
        )

        XCTAssertNil(poster.requests.first?.signature)
    }

    // MARK: - Retry policy

    func testAServerErrorIsRetriedExactlyOnceAndThenGivenUpOn() async throws {
        let poster = RecordingPoster(answers: [WebhookResponse(status: 503)])
        let sleeper = RecordingSleeper()
        let dispatcher = makeDispatcher(poster, sleeper: sleeper)

        await dispatcher.deliver(
            event(.pullRequestMerged, details: .merged(method: "merge")),
            configuration: enabled()
        )

        XCTAssertEqual(poster.requests.count, WebhookDispatcher.attemptLimit)
        let waits = await sleeper.recorded
        XCTAssertEqual(waits, [WebhookDispatcher.retryDelay])
        let delivery = try XCTUnwrap(dispatcher.lastDelivery)
        XCTAssertFalse(delivery.isSuccess)
        XCTAssertEqual(delivery.attempts, 2)
        XCTAssertEqual(delivery.failure, WebhookError.rejected(status: 503).errorDescription)
        XCTAssertTrue(delivery.summary.contains("pr.merged"))
    }

    func testTheRetryReusesTheSameBodyAndDeliveryIDSoAReceiverCanDeduplicate() async throws {
        let poster = RecordingPoster(
            answers: [WebhookResponse(status: 500), WebhookResponse(status: 200)]
        )
        let dispatcher = makeDispatcher(poster)

        await dispatcher.deliver(
            reviewEvent(verdict: "comment"),
            configuration: enabled(secret: "s")
        )

        let requests = poster.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.body, requests.last?.body)
        XCTAssertEqual(requests.first?.deliveryID, requests.last?.deliveryID)
        XCTAssertEqual(requests.first?.signature, requests.last?.signature)
        let delivery = try XCTUnwrap(dispatcher.lastDelivery)
        XCTAssertTrue(delivery.isSuccess)
        XCTAssertEqual(delivery.attempts, 2)
    }

    func testAConfigurationErrorIsNotRetried() async throws {
        for status in [400, 401, 404, 410] {
            let poster = RecordingPoster(
                answers: [WebhookResponse(status: status), WebhookResponse(status: 200)]
            )
            let dispatcher = makeDispatcher(poster)

            await dispatcher.deliver(
                event(.pullRequestMerged, details: .merged(method: "merge")),
                configuration: enabled()
            )

            XCTAssertEqual(
                poster.requests.count,
                1,
                "a \(status) will not fix itself in two seconds"
            )
            let delivery = try XCTUnwrap(dispatcher.lastDelivery)
            XCTAssertEqual(delivery.attempts, 1)
            XCTAssertFalse(delivery.isSuccess)
        }
    }

    func testThrottlingAndTimeoutsAreRetriedButSuccessAndNotFoundAreNot() {
        XCTAssertTrue(WebhookResponse(status: 429).isRetryable)
        XCTAssertTrue(WebhookResponse(status: 408).isRetryable)
        XCTAssertTrue(WebhookResponse(status: 500).isRetryable)
        XCTAssertFalse(WebhookResponse(status: 404).isRetryable)
        XCTAssertFalse(WebhookResponse(status: 200).isRetryable)
        XCTAssertTrue(WebhookResponse(status: 204).isSuccess)
        XCTAssertFalse(WebhookResponse(status: 0).isSuccess, "no HTTP response is not a success")
    }

    func testATransportFailureIsRetriedAndReportedButNeverThrown() async throws {
        let poster = RecordingPoster(failure: .transport("network is down"))
        let dispatcher = makeDispatcher(poster)

        // `deliver` is the fire-and-forget path and cannot throw by construction: its caller is
        // the sync engine's event loop, which must not learn about webhooks at all.
        await dispatcher.deliver(reviewEvent(), configuration: enabled())

        XCTAssertEqual(poster.requests.count, WebhookDispatcher.attemptLimit)
        let delivery = try XCTUnwrap(dispatcher.lastDelivery)
        XCTAssertEqual(delivery.failure, WebhookError.transport("network is down").errorDescription)
        XCTAssertTrue(delivery.summary.contains("Last delivery failed"))
    }

    func testAnUnusableURLIsReportedWithoutEverOpeningAConnection() async throws {
        let poster = RecordingPoster(answers: [WebhookResponse(status: 200)])
        let dispatcher = makeDispatcher(poster)

        // The test event bypasses the toggle and the checkboxes, but never the URL.
        do {
            try await dispatcher.deliverTestEvent(
                configuration: WebhookConfiguration(
                    isEnabled: true,
                    urlText: "http://evil.example.com/x"
                )
            )
            XCTFail("an insecure destination must be refused")
        } catch {
            XCTAssertEqual(error as? WebhookError, .insecureScheme("evil.example.com"))
        }
        XCTAssertTrue(poster.requests.isEmpty)
        let delivery = try XCTUnwrap(dispatcher.lastDelivery)
        XCTAssertEqual(delivery.attempts, 0)
        XCTAssertFalse(delivery.isSuccess)
    }

    func testTheTestEventIsSentEvenWhileTheToggleIsStillOff() async throws {
        let poster = RecordingPoster(answers: [WebhookResponse(status: 200)])
        let dispatcher = makeDispatcher(poster)

        // Setting the integration up would be impossible if the button needed the feature to
        // already be on. It still only ever posts to the URL in the field.
        try await dispatcher.deliverTestEvent(
            configuration: WebhookConfiguration(
                isEnabled: false,
                urlText: destination,
                events: []
            )
        )

        XCTAssertEqual(poster.requests.count, 1)
        XCTAssertEqual(poster.requests.first?.eventKind, .test)
        XCTAssertEqual(dispatcher.lastDelivery?.event, .test)
        XCTAssertEqual(dispatcher.lastDelivery?.isSuccess, true)
    }

    // MARK: - Mapping Shepherd's events to the four documented ones

    func testASentReviewBecomesAReviewSubmittedEvent() throws {
        let plan = try XCTUnwrap(
            WebhookCoordinator.plan(
                for: .mutationSent(
                    mutation(.reviewSubmitted(verdict: .requestChanges, inlineCommentCount: 4))
                )
            )
        )
        XCTAssertEqual(plan.kind, .reviewSubmitted)
        XCTAssertEqual(
            plan.details,
            .reviewSubmitted(verdict: "request_changes", inlineCommentCount: 4)
        )
        XCTAssertEqual(plan.identity.prID, "PR_1")
        XCTAssertEqual(plan.identity.number, 42)
        XCTAssertEqual(plan.occurredAt, occurredAt, "the moment it was sent, not the moment we look")
        XCTAssertNil(plan.summary, "the event only names the pull request; it is looked up")
    }

    func testASentMergeBecomesAMergedEventCarryingTheMethod() throws {
        let plan = try XCTUnwrap(
            WebhookCoordinator.plan(for: .mutationSent(mutation(.merged(method: "squash"))))
        )
        XCTAssertEqual(plan.kind, .pullRequestMerged)
        XCTAssertEqual(plan.details, .merged(method: "squash"))
    }

    func testADiscoveredReviewRequestCarriesTheTriageStateItWasFoundWith() throws {
        let summary = agentSummary()
        let plan = try XCTUnwrap(
            WebhookCoordinator.plan(for: .newReviewRequest(summary), now: occurredAt)
        )
        XCTAssertEqual(plan.kind, .newReviewRequest)
        XCTAssertEqual(
            plan.details,
            .newReviewRequest(
                // Sorted: `myRelation` is a Set, and two identical events must encode alike.
                relations: ["mentioned", "reviewRequested"],
                reviewDecision: "reviewRequired",
                checks: "success"
            )
        )
        XCTAssertEqual(plan.summary, summary, "the sweep already has the row; no lookup needed")
        XCTAssertEqual(plan.occurredAt, occurredAt)
    }

    func testEventsThatDoNotMeanSomethingDefinitelyHappenedMapToNothing() {
        let summary = agentSummary()
        let ignored: [SyncEvent] = [
            // A sweep of *open* pull requests cannot tell a merge from a close, so this one is
            // deliberately not `pr.merged`.
            .prMerged(summary),
            .prUpdated(summary),
            .checksFailedOnOwnPR(
                ChecksFailure(summary: summary, previousState: .success, wasTracked: true)
            ),
            .changesRequestedOnOwnPR(
                ChangesRequested(summary: summary, previousDecision: nil, wasTracked: true)
            ),
            .draftConflict(
                DraftConflict(
                    prID: "PR_1",
                    repo: repo,
                    number: 42,
                    expectedHeadOid: "a",
                    actualHeadOid: "b"
                )
            ),
            .syncFailed(SyncFailure(stage: .outbox, message: "nope")),
            // A heartbeat about this Mac rather than a fact about a pull request.
            .sweepCompleted(SweepCompletion(finishedAt: occurredAt)),
            // Sent, but not one of the four events v1 promises.
            .mutationSent(mutation(.replyPosted)),
            .mutationSent(mutation(.threadResolved)),
            .mutationSent(mutation(.threadUnresolved)),
            .mutationSent(mutation(.markedReadyForReview)),
        ]
        for event in ignored {
            XCTAssertNil(WebhookCoordinator.plan(for: event), "this event must not be a webhook")
        }
    }

    func testAFinishedDelegationCarriesItsStatusWithoutAnyAgentOutput() {
        let outcome = DelegationOutcome(
            prID: "PR_1",
            repo: repo,
            number: 42,
            status: .failed,
            agent: "Claude Code",
            durationSeconds: 91,
            changedFileCount: 0,
            message: "error_max_turns",
            wasAutomatic: true,
            at: occurredAt
        )
        let plan = WebhookCoordinator.plan(for: outcome)
        XCTAssertEqual(plan.kind, .delegationFinished)
        XCTAssertEqual(
            plan.details,
            .delegation(
                status: "failed",
                agent: "Claude Code",
                durationSeconds: 91,
                changedFileCount: 0,
                message: "error_max_turns",
                // The run was started by a rule, and the payload says so (ADR 0016).
                automatic: true
            )
        )
        XCTAssertEqual(plan.occurredAt, occurredAt)
        XCTAssertEqual(
            DelegationOutcome.Status.allCases.map(\.rawValue),
            ["finished", "failed", "cancelled"]
        )
    }

    // MARK: - Settings (non-secret only)

    func testTheNonSecretConfigurationRoundTripsAndTheSecretNeverReachesUserDefaults() throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let settings = AppSettings(defaults: defaults)
        // Off on a fresh install, but subscribed to everything, so switching it on just works.
        XCTAssertFalse(settings.webhooksEnabled)
        XCTAssertEqual(settings.webhookEvents, Set(WebhookEventKind.userSelectable))

        settings.webhooksEnabled = true
        settings.webhookURL = destination
        settings.setWebhookEvent(.newReviewRequest, isOn: false)
        settings.setWebhookEvent(.delegationFinished, isOn: false)
        settings.setWebhookEvent(.autoMergeQueued, isOn: false)
        settings.setWebhookEvent(.issueClosed, isOn: false)
        settings.setWebhookEvent(.issueAssignedToAgent, isOn: false)

        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.webhooksEnabled)
        XCTAssertEqual(restored.webhookURL, destination)
        XCTAssertEqual(restored.webhookEvents, [.reviewSubmitted, .pullRequestMerged])

        let model = SettingsModel()
        model.webhookSecretField = "shepherd-not-a-real-secret"

        let stored = defaults.dictionaryRepresentation()
        XCTAssertFalse(
            stored.values.contains { ($0 as? String)?.contains("not-a-real-secret") == true },
            "the signing secret must never reach UserDefaults"
        )
        XCTAssertEqual(
            (stored["automation.webhook.events"] as? [String])?.sorted(),
            ["pr.merged", "review.submitted"]
        )
    }

    func testTheButtonOnlyEventCanNeverBeSubscribedToThroughStoredSettings() throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        // A hand-edited (or future) defaults file naming the button-only event, plus junk.
        defaults.set(
            ["shepherd.test", "review.submitted", "not.an.event"],
            forKey: "automation.webhook.events"
        )

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.webhookEvents, [.reviewSubmitted])
    }

    // MARK: - Test doubles

    private func makeDispatcher(
        _ poster: RecordingPoster,
        sleeper: RecordingSleeper = RecordingSleeper()
    ) -> WebhookDispatcher {
        WebhookDispatcher(
            poster: poster,
            sleeper: sleeper,
            now: { Date(timeIntervalSince1970: 1_788_165_600) }
        )
    }

    private func enabled(secret: String = "") -> WebhookConfiguration {
        WebhookConfiguration(
            isEnabled: true,
            urlText: destination,
            events: Set(WebhookEventKind.userSelectable),
            secret: secret
        )
    }

    private func mutation(_ kind: SentMutation.Kind) -> SentMutation {
        SentMutation(prID: "PR_1", repo: repo, number: 42, kind: kind, sentAt: occurredAt)
    }

    // MARK: - The issue object and `issue.closed` (ADR 0032's Sprint 4a amendment)

    private func issueRow(
        author: ShepherdCore.Actor? = nil
    ) -> IssueRowSummary {
        IssueRowSummary(
            id: "I_kwDOissue",
            repo: repo,
            number: 128,
            title: "The login flow drops the session",
            author: author
                ?? ShepherdCore.Actor(
                    login: "example-agent[bot]",
                    displayName: nil,
                    avatarURL: nil,
                    kind: .agent(
                        AgentIdentity(
                            id: "example-agent",
                            displayName: "Example Agent",
                            matchedBy: .login
                        )
                    )
                ),
            createdAt: occurredAt,
            updatedAt: occurredAt,
            state: .closed,
            stateReason: "COMPLETED",
            labels: ["bug"]
        )
    }

    private func issueEvent(
        details: WebhookEventDetails = .issueClosed(reason: "completed"),
        issue: WebhookIssue? = nil
    ) -> WebhookEvent {
        WebhookEvent(
            event: .issueClosed,
            issue: issue ?? WebhookIssue(summary: issueRow()),
            details: details,
            occurredAt: occurredAt,
            deliveryID: deliveryID
        )
    }

    func testAnIssueEnvelopeCarriesAnIssueObjectWhereAPullRequestOneCarriesAPullRequest() throws {
        let json = try object(issueEvent())

        XCTAssertEqual(
            json.keys.sorted(),
            ["details", "event", "id", "issue", "occurredAt", "source", "v"],
            "one subject key or the other, never both and never an empty one"
        )
        XCTAssertNil(json["pullRequest"], "a receiver must not have to guard an empty object")
        XCTAssertEqual(json["v"] as? Int, 1, "additive: no existing event changed shape")
        XCTAssertEqual(json["event"] as? String, "issue.closed")
    }

    func testTheIssueObjectSaysWhereItIsAndWhoWroteItAndNothingElse() throws {
        let json = try nested(try object(issueEvent()), "issue")

        XCTAssertEqual(
            json.keys.sorted(),
            [
                "agentId", "author", "authorKind", "isAgentAuthored", "nodeId", "number",
                "owner", "repo", "title", "url",
            ],
            "no body, no labels, no comment count: the payload says what happened"
        )
        XCTAssertEqual(json["owner"] as? String, "schnaq")
        XCTAssertEqual(json["repo"] as? String, "review")
        XCTAssertEqual(json["number"] as? Int, 128)
        XCTAssertEqual(json["nodeId"] as? String, "I_kwDOissue")
        XCTAssertEqual(json["title"] as? String, "The login flow drops the session")
        XCTAssertEqual(json["url"] as? String, "https://github.com/schnaq/review/issues/128")
        XCTAssertEqual(json["authorKind"] as? String, "agent")
        XCTAssertEqual(json["isAgentAuthored"] as? Bool, true)
        XCTAssertEqual(json["agentId"] as? String, "example-agent")
    }

    func testAHumanAuthoredIssueNullsTheAgentIdExplicitly() throws {
        let human = ShepherdCore.Actor(
            login: "octocat",
            displayName: nil,
            avatarURL: nil,
            kind: .human
        )
        let json = try nested(
            try object(issueEvent(issue: WebhookIssue(summary: issueRow(author: human)))),
            "issue"
        )
        XCTAssertEqual(json["authorKind"] as? String, "human")
        XCTAssertEqual(json["isAgentAuthored"] as? Bool, false)
        XCTAssertTrue(json["agentId"] is NSNull, "a missing key and a null key are not the same")
    }

    func testAnIssueTheSweepAlreadyPrunedStillProducesTheFullShape() throws {
        // The likely case rather than a defensive one: closing the issue is exactly what makes
        // the next sweep drop its row.
        let pruned = WebhookIssue(
            identity: WebhookPullRequest.Identity(
                prID: "I_gone",
                repo: repo,
                number: 128
            )
        )
        let json = try nested(try object(issueEvent(issue: pruned)), "issue")
        XCTAssertEqual(
            json.keys.sorted(),
            [
                "agentId", "author", "authorKind", "isAgentAuthored", "nodeId", "number",
                "owner", "repo", "title", "url",
            ]
        )
        XCTAssertEqual(json["authorKind"] as? String, "unknown")
        XCTAssertEqual(json["title"] as? String, "")
        XCTAssertEqual(json["url"] as? String, "https://github.com/schnaq/review/issues/128")
    }

    func testTheCloseDetailsCarryGitHubsOwnReasonWord() throws {
        let json = try nested(
            try object(issueEvent(details: .issueClosed(reason: "not_planned"))),
            "details"
        )
        XCTAssertEqual(json.keys.sorted(), ["reason"])
        XCTAssertEqual(json["reason"] as? String, "not_planned")
    }

    func testAClosedIssueBecomesAnIssueClosedEvent() throws {
        let plan = try XCTUnwrap(
            WebhookCoordinator.plan(for: .mutationSent(issueMutation(.issueClosed(reason: "completed"))))
        )
        XCTAssertEqual(plan.kind, .issueClosed)
        XCTAssertEqual(plan.details, .issueClosed(reason: "completed"))
        XCTAssertEqual(plan.identity.prID, "I_kwDOissue", "the identity names the issue")
        XCTAssertEqual(plan.identity.number, 128)
        XCTAssertEqual(plan.occurredAt, occurredAt)
        XCTAssertNil(plan.summary)
        XCTAssertNil(plan.issue, "the event only names the issue; it is looked up")
    }

    func testAHandoverBecomesAnIssueAssignedToAgentEvent() throws {
        let plan = WebhookCoordinator.plan(
            for: DelegationStart(
                prID: "I_kwDOissue",
                repo: RepoRef(owner: "schnaq", name: "review"),
                number: 128,
                agent: "Example Agent",
                template: "default",
                at: occurredAt
            )
        )
        XCTAssertEqual(plan.kind, .issueAssignedToAgent)
        XCTAssertEqual(
            plan.details,
            .issueAssignment(agent: "Example Agent", template: "default")
        )
        XCTAssertEqual(plan.identity.prID, "I_kwDOissue", "the identity names the issue")
        XCTAssertEqual(plan.identity.number, 128)
        XCTAssertEqual(plan.occurredAt, occurredAt)
        XCTAssertNil(plan.summary)
        XCTAssertNil(plan.issue, "the event only names the issue; it is looked up")
        XCTAssertTrue(plan.kind.isAboutAnIssue, "so the envelope carries an issue, not a pull request")
    }

    func testTheHandoverDetailsCarryTheAgentAndTheTemplatesNameOnly() throws {
        let json = try nested(
            try object(
                WebhookEvent(
                    event: .issueAssignedToAgent,
                    issue: WebhookIssue(summary: issueRow()),
                    details: .issueAssignment(agent: "Example Agent", template: "default"),
                    occurredAt: occurredAt,
                    deliveryID: deliveryID
                )
            ),
            "details"
        )
        XCTAssertEqual(json.keys.sorted(), ["agent", "template"])
        XCTAssertEqual(json["agent"] as? String, "Example Agent")
        // A name, not the text: a template may quote the issue, and this envelope says what
        // happened rather than what was written (ADR 0012).
        XCTAssertEqual(json["template"] as? String, "default")
    }

    func testTheOtherFourIssueWritesAreSentButAreNotEventsThisVersionPromises() {
        let ignored: [SentMutation.Kind] = [
            .issueCommentAdded,
            .issueLabelAdded(name: "needs-triage"),
            .issueAssigneeAdded(login: "octocat"),
            .issueReopened,
        ]
        for kind in ignored {
            XCTAssertNil(
                WebhookCoordinator.plan(for: .mutationSent(issueMutation(kind))),
                "\(kind) reached GitHub, but v1 promises no event for it"
            )
        }
    }

    private func issueMutation(_ kind: SentMutation.Kind) -> SentMutation {
        SentMutation(
            prID: "I_kwDOissue",
            repo: repo,
            number: 128,
            kind: kind,
            sentAt: occurredAt
        )
    }
}
