import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The app half of the thread digest: when a model run is spent, what invalidates a cached
/// digest, and every state the card can be in (plan §3.G, ADR 0007's on-device-only amendment).
///
/// The *budgeting* is covered exhaustively by `ThreadDigestRequestTests` in ShepherdKit, which
/// runs on the Linux runner. What is tested here is what a pure function cannot see — the cost and
/// the wiring. Two promises of this feature are cost promises rather than quality promises
/// ("pressing the button twice costs one run", "a reply invalidates the digest of the conversation
/// as it was"), and both are asserted through the fake digester's call log.
///
/// Every model call goes through the injected ``ThreadDigesting`` seam, so nothing here depends on
/// Apple's model being present, on its answers being stable, or on a window existing.
@MainActor
final class ThreadDigestTests: XCTestCase {
    // MARK: - Doubles

    /// A digester that answers from what a test wrote, and remembers every request.
    ///
    /// It yields twice before answering, which is what makes the de-duplication assertion a
    /// statement about the coordinator rather than about scheduling luck: a second call that
    /// arrives while this one is suspended has to be de-duplicated, not merely to be late.
    private actor FakeDigester: ThreadDigesting {
        /// What the fake does when it is asked.
        enum Answer: Sendable {
            /// Answer with this digest.
            case digest(ThreadDigest)
            /// Throw this error.
            case failure(IntelligenceError)
            /// Never answer until the run is cancelled.
            case hold
        }

        private let availabilityAnswer: ThreadDigesterAvailability
        private let answer: Answer
        private(set) var requests: [ThreadDigestRequest] = []
        private(set) var availabilityAsks = 0

        init(
            availability: ThreadDigesterAvailability = .available,
            answer: Answer = .digest(
                ThreadDigest(
                    state: .blocked,
                    summary: "Agreed to add a test; the author has not answered the flag question.",
                    openQuestions: ["Should this be behind a flag?"]
                )
            )
        ) {
            self.availabilityAnswer = availability
            self.answer = answer
        }

        var callCount: Int { requests.count }

        func availability() async -> ThreadDigesterAvailability {
            availabilityAsks += 1
            return availabilityAnswer
        }

        func digest(_ request: ThreadDigestRequest) async throws -> ThreadDigestResult {
            requests.append(request)
            await Task.yield()
            await Task.yield()
            switch answer {
            case .digest(let digest):
                return ThreadDigestResult(
                    digest: digest,
                    coveredCount: request.coveredCount,
                    totalCount: request.totalCount
                )
            case .failure(let error):
                throw error
            case .hold:
                while !Task.isCancelled { await Task.yield() }
                throw CancellationError()
            }
        }
    }

    // MARK: - Fixtures

    private let threadID = "PRRT_1"

    private func comment(_ index: Int, body: String? = nil) -> ReviewComment {
        ReviewComment(
            id: "RC_\(index)",
            databaseID: index,
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            bodyMarkdown: body ?? "comment number \(index) about the retry loop",
            createdAt: Date(timeIntervalSince1970: TimeInterval(index) * 60)
        )
    }

    private func comments(_ count: Int, body: String? = nil) -> [ReviewComment] {
        (1...count).map { comment($0, body: body) }
    }

    /// Spins the main actor until a condition holds, or gives up.
    ///
    /// Yields rather than sleeps: everything under test runs on this actor, so handing it back is
    /// enough and the test costs no wall-clock time.
    private func spin(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 2_000 {
            await Task.yield()
            spins += 1
        }
    }

    // MARK: - The seam

    func testTheCoordinatorIsBuiltFromADigesterAndNothingElse() async {
        // A compile-level assertion as much as a runtime one: this call type-checks only while
        // the coordinator's single dependency is the `ThreadDigesting` seam. There is no router,
        // no base URL and no key to hand it — which is how "colleagues' comments never reach a
        // BYOK endpoint" is a property of the types rather than of a setting a user could flip
        // (ADR 0007's amendment, ADR 0020's argument).
        let coordinator = ThreadDigestCoordinator(digester: FakeDigester())

        XCTAssertFalse(coordinator.isAvailable, "availability is unknown until it is asked")
        XCTAssertNil(coordinator.unavailabilityReason)
        XCTAssertEqual(coordinator.cachedDigestCount, 0, "created inert: nothing is loaded")
        XCTAssertNil(coordinator.state(for: threadID, comments: comments(6)))
    }

    func testTheProductionDigesterIsNotARungOnTheTierLadder() {
        // Held as `any Sendable` so the check is a real runtime question rather than a cast the
        // compiler answers: the on-device digester must not be an `IntelligenceProvider`, because
        // that protocol is the ladder whose top rung is a cloud endpoint.
        let digester: any Sendable = OnDeviceThreadDigester()

        XCTAssertFalse(
            digester is any IntelligenceProvider,
            "a digest has one tier and no ladder to fall down"
        )
        XCTAssertTrue(digester is any ThreadDigesting)
    }

    // MARK: - Spending a run

    func testAThreadIsSummarisedOnceAndThenRememberedForFree() async {
        let fake = FakeDigester()
        let coordinator = ThreadDigestCoordinator(digester: fake)
        let thread = comments(8)

        await coordinator.digest(for: threadID, comments: thread)
        await coordinator.digest(for: threadID, comments: thread)

        let calls = await fake.callCount
        XCTAssertEqual(calls, 1, "the second press of the button costs nothing")
        guard let state = coordinator.state(for: threadID, comments: thread),
            case .digest(let result) = state
        else { return XCTFail("the digest is on screen") }
        XCTAssertEqual(result.digest.state, .blocked)
        XCTAssertEqual(result.digest.openQuestions, ["Should this be behind a flag?"])
        XCTAssertEqual(coordinator.cachedDigestCount, 1)
    }

    func testAnArrivingReplyInvalidatesTheDigestOfTheConversationAsItWas() async {
        let fake = FakeDigester()
        let coordinator = ThreadDigestCoordinator(digester: fake)
        let before = comments(8)
        let after = before + [comment(9, body: "Fine, adding the flag.")]

        await coordinator.digest(for: threadID, comments: before)
        XCTAssertNotNil(coordinator.state(for: threadID, comments: before))

        // The same thread id, one comment more: the key changed, so there is no card until the
        // reviewer asks again — a digest that predates the answer would be actively misleading.
        XCTAssertNil(coordinator.state(for: threadID, comments: after))

        await coordinator.digest(for: threadID, comments: after)
        let calls = await fake.callCount
        XCTAssertEqual(calls, 2)
        guard let state = coordinator.state(for: threadID, comments: after),
            case .digest(let result) = state
        else { return XCTFail("the newer digest is on screen") }
        XCTAssertEqual(result.totalCount, 9)
    }

    func testTheCacheKeyIsTheThreadItsLengthAndItsNewestComment() {
        let thread = comments(8)
        let key = ThreadDigestCoordinator.cacheKey(threadID: threadID, comments: thread)

        XCTAssertEqual(key, "\(threadID)|8|RC_8")
        XCTAssertNotEqual(
            key,
            ThreadDigestCoordinator.cacheKey(threadID: "PRRT_2", comments: thread),
            "two threads of the same length do not share a digest"
        )
        XCTAssertEqual(
            ThreadDigestCoordinator.cacheKey(threadID: threadID, comments: []),
            "\(threadID)|0|",
            "an empty thread has a key rather than a crash"
        )
    }

    func testTwoOverlappingRequestsForTheSameThreadSpendOneRun() async {
        let fake = FakeDigester()
        let coordinator = ThreadDigestCoordinator(digester: fake)
        let thread = comments(8)

        let first = Task { await coordinator.digest(for: threadID, comments: thread) }
        let second = Task { await coordinator.digest(for: threadID, comments: thread) }
        await first.value
        await second.value

        let calls = await fake.callCount
        XCTAssertEqual(calls, 1, "one thread, one session, however many clicks")
        let asks = await fake.availabilityAsks
        XCTAssertEqual(asks, 1, "and one availability question for the life of the app")
        XCTAssertNotNil(coordinator.state(for: threadID, comments: thread))
    }

    func testAThreadWithNothingInItIsNotSentToTheModel() async {
        let fake = FakeDigester()
        let coordinator = ThreadDigestCoordinator(digester: fake)
        let blank = comments(6, body: "   ")

        await coordinator.digest(for: threadID, comments: blank)

        let calls = await fake.callCount
        XCTAssertEqual(calls, 0, "an empty prompt would come back as a summary of nothing")
        XCTAssertNil(coordinator.state(for: threadID, comments: blank))
    }

    // MARK: - The unavailable Mac

    func testAMacWithoutTheModelGetsNoButtonAndSpendsNothing() async {
        let fake = FakeDigester(availability: .unavailable("Apple Intelligence is turned off."))
        let coordinator = ThreadDigestCoordinator(digester: fake)
        let thread = comments(8)

        await coordinator.digest(for: threadID, comments: thread)

        XCTAssertFalse(coordinator.isAvailable, "which is what removes the button entirely")
        XCTAssertEqual(coordinator.unavailabilityReason, "Apple Intelligence is turned off.")
        let calls = await fake.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertNil(
            coordinator.state(for: threadID, comments: thread),
            "no card, no spinner and no error line — there was nothing to try"
        )
    }

    func testAvailabilityIsAskedOncePerAppRun() async {
        let fake = FakeDigester()
        let coordinator = ThreadDigestCoordinator(digester: fake)

        await coordinator.prepare()
        await coordinator.prepare()
        await coordinator.digest(for: threadID, comments: comments(8))

        let asks = await fake.availabilityAsks
        XCTAssertEqual(asks, 1, "whether this Mac has the model is a property of the Mac")
    }

    // MARK: - Failure

    func testAFailureIsOneLineOfTheTiersOwnWords() async {
        let fake = FakeDigester(answer: .failure(.guardrailDeclined))
        let coordinator = ThreadDigestCoordinator(digester: fake)
        let thread = comments(8)

        await coordinator.digest(for: threadID, comments: thread)

        guard let state = coordinator.state(for: threadID, comments: thread),
            case .failed(let reason) = state
        else { return XCTFail("a failure is shown, not swallowed") }
        XCTAssertEqual(reason, IntelligenceError.guardrailDeclined.errorDescription)
        XCTAssertFalse(reason.isEmpty)
    }

    func testABudgetRefusalReachesTheCardAndTheButtonMayAskAgain() async {
        let fake = FakeDigester(answer: .failure(.digestTooLarge(tokens: 9_000, limit: 6_000)))
        let coordinator = ThreadDigestCoordinator(digester: fake)
        let thread = comments(8)

        await coordinator.digest(for: threadID, comments: thread)
        // Asked again with the same thread: a failure is not cached like an answer — the button
        // stays, like every other drafting button, so the second press is a second run. Only a
        // finished digest is final for its content.
        await coordinator.digest(for: threadID, comments: thread)

        let calls = await fake.callCount
        XCTAssertEqual(calls, 2)
        guard let state = coordinator.state(for: threadID, comments: thread),
            case .failed(let reason) = state
        else { return XCTFail("the refusal is shown") }
        // The number is formatted for the runner's locale, so the sentence is compared whole
        // rather than searched for one spelling of nine thousand.
        XCTAssertEqual(
            reason,
            IntelligenceError.digestTooLarge(tokens: 9_000, limit: 6_000).errorDescription
        )
    }

    // MARK: - Coverage

    func testAThreadTooLongForTheBudgetIsCoveredInPartAndTheCardSaysSo() async {
        let fake = FakeDigester()
        let coordinator = ThreadDigestCoordinator(digester: fake)
        // Thirty comments of 500 characters each: far past the on-device tier's share.
        let thread = comments(30, body: String(repeating: "argument ", count: 60))

        await coordinator.digest(for: threadID, comments: thread)

        guard let state = coordinator.state(for: threadID, comments: thread),
            case .digest(let result) = state
        else { return XCTFail("a partial digest is still a digest") }
        XCTAssertEqual(result.totalCount, 30)
        XCTAssertLessThan(result.coveredCount, 30)
        XCTAssertGreaterThan(result.coveredCount, 0)
        XCTAssertTrue(result.wasTruncated)

        // The line the card draws under the summary names both counts.
        let coverage = ThreadDigestCard.coverage(result)
        XCTAssertTrue(coverage.contains("\(result.coveredCount)"))
        XCTAssertTrue(coverage.contains("30"))

        // And the request the model saw agrees with what the card says about it.
        let requests = await fake.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.coveredCount, result.coveredCount)
        XCTAssertEqual(requests.first?.comments.count, result.coveredCount)
    }

    func testAWholeThreadThatFitsHasNoCoverageLineToDraw() async {
        let fake = FakeDigester()
        let coordinator = ThreadDigestCoordinator(digester: fake)
        let thread = comments(8)

        await coordinator.digest(for: threadID, comments: thread)

        guard let state = coordinator.state(for: threadID, comments: thread),
            case .digest(let result) = state
        else { return XCTFail("the digest is on screen") }
        XCTAssertFalse(result.wasTruncated)
        XCTAssertEqual(result.coveredCount, 8)
    }

    func testTheResolvedFlagTravelsWithTheThread() async {
        let fake = FakeDigester()
        let coordinator = ThreadDigestCoordinator(digester: fake)
        let thread = comments(8)

        await coordinator.digest(for: threadID, comments: thread, isResolved: true)

        let requests = await fake.requests
        XCTAssertEqual(requests.first?.isResolved, true)
        XCTAssertTrue(requests.first?.promptText.contains("marked resolved") == true)
    }

    // MARK: - Cancellation

    func testLeavingAThreadStopsTheRunAndTakesTheSpinnerWithIt() async {
        let fake = FakeDigester(answer: .hold)
        let coordinator = ThreadDigestCoordinator(digester: fake)
        let thread = comments(8)

        let running = Task { await coordinator.digest(for: threadID, comments: thread) }
        await spin { coordinator.state(for: threadID, comments: thread) != nil }
        guard let pending = coordinator.state(for: threadID, comments: thread) else {
            return XCTFail("the card shows a spinner while the model reads")
        }
        XCTAssertEqual(pending, .loading)

        coordinator.cancel(for: threadID)
        await running.value

        XCTAssertNil(
            coordinator.state(for: threadID, comments: thread),
            "a spinner nobody is filling any more is worse than no card"
        )
        XCTAssertEqual(coordinator.cachedDigestCount, 0)
    }

    func testCancellingAThreadNobodyIsSummarisingDoesNothing() {
        let coordinator = ThreadDigestCoordinator(digester: FakeDigester())

        coordinator.cancel(for: threadID)

        XCTAssertEqual(coordinator.cachedDigestCount, 0)
    }

    // MARK: - The card's own words

    func testEveryThreadStateHasAWordForItsChip() {
        for state in ThreadDigest.State.allCases {
            XCTAssertFalse(
                ThreadDigestCard.label(for: state).isEmpty,
                "\(state) needs a word on the chip"
            )
        }
        XCTAssertNotEqual(
            ThreadDigestCard.label(for: .agreed),
            ThreadDigestCard.label(for: .blocked)
        )
    }

    func testTheOfferThresholdIsTheOneTheRequestDefines() {
        // The button's condition and the budgeting's idea of "long enough to summarise" are the
        // same number, taken from the same place.
        XCTAssertEqual(
            ThreadDigestCoordinator.minimumCommentCount,
            ThreadDigestRequest.minimumCommentCount
        )
        XCTAssertEqual(ThreadDigestCoordinator.minimumCommentCount, 6)
    }
}
