import AppIntents
import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// "Summarise my next review" (plan §3.H): which tier may answer it, which pull request it is
/// about, and what it says when it cannot answer at all.
///
/// The split is ADR 0021's and ADR 0019's: the *decisions* are pure values and are pinned here,
/// while Siri, Shortcuts and Apple Intelligence are seams with one production implementation each
/// and nothing left to assert. Five things are worth a test and none of them needs a Mac with the
/// on-device model switched on:
///
/// - **Tier 2 is the ceiling.** A configured cloud rung is never *asked*, even though the same
///   router answers the review screen's own summary from it — which is the whole of ADR 0007's
///   "unattended means on-device only", expressed as a call that did not happen.
/// - **An unavailable model is one sentence.** Not a silent failure, not a cloud call, and not
///   the card's own three-way reason, which is written for a screen this surface does not have.
/// - **An unfetched pull request is a sentence too**, and no tier is asked for it: a digest built
///   from a title alone would be two confident sentences about nothing.
/// - **"My next review" is the queue's first row**, and a supplied entity wins over it.
/// - **The entity is unchanged.** The summary is the result of one run; nothing about it lands on
///   ``PullRequestEntity``, which is what keeps ADR 0021's metadata-only guarantee true.
@MainActor
final class SummarizeIntentTests: XCTestCase {
    private let repo = RepoRef(owner: "schnaq", name: "review")

    // MARK: - Fixtures

    private func summary(id: String = "PR_1", number: Int = 128) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: "Retry the flaky upload",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 0),
            additions: 12,
            deletions: 3,
            changedFiles: 1,
            headRefName: "agent/fix",
            headRefOid: "0123456789abcdef0123",
            baseRefName: "main",
            myRelation: [.reviewRequested]
        )
    }

    private func detail(id: String = "PR_1") -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(id: id),
            bodyMarkdown: "The upload retries twice before giving up.",
            files: [
                ChangedFile(
                    path: "Sources/Upload.swift",
                    status: .modified,
                    additions: 12,
                    deletions: 3,
                    patch: "@@ -1,3 +1,4 @@\n context\n+let retries = 2\n"
                )
            ]
        )
    }

    /// A router whose two tiers each answer with an overview naming themselves.
    ///
    /// The cloud closure ignores the configuration on purpose, so a test can have a cloud rung
    /// present without an API key — what is under test is the *ladder*, not
    /// ``IntelligenceRouter/liveCloudProvider(for:)``.
    private func router(
        mode: IntelligenceMode = .onDeviceAndCloud,
        onDeviceUnavailabilityReason reason: String? = nil,
        onDeviceOverview: String = "ON-DEVICE",
        riskNotes: [String] = [],
        onDeviceFailure: IntelligenceError? = nil,
        log: TierCallLog? = nil
    ) -> IntelligenceRouter {
        IntelligenceRouter(
            configuration: IntelligenceConfiguration(
                mode: mode,
                cloudKind: .anthropic,
                cloudAPIKey: "not-a-real-key"
            ),
            tiers: IntelligenceTiers(
                cloud: { _ in
                    SummaryStubTier(kind: .anthropic, overview: "CLOUD", log: log)
                },
                onDevice: {
                    SummaryStubTier(
                        kind: .onDevice,
                        overview: onDeviceOverview,
                        riskNotes: riskNotes,
                        failure: onDeviceFailure,
                        log: log
                    )
                },
                onDeviceUnavailabilityReason: { reason }
            )
        )
    }

    /// A summarizer over the scripted ``router(mode:onDeviceUnavailabilityReason:onDeviceOverview:riskNotes:onDeviceFailure:log:)``
    /// whose database read is scripted too.
    private func summarizer(
        router: IntelligenceRouter,
        detail: PullRequestDetail?
    ) -> PullRequestSummarizer {
        PullRequestSummarizer.live(router: router, detail: { _ in detail })
    }

    private func entity(id: String = "PR_1", number: Int = 128) -> PullRequestEntity {
        PullRequestEntity(pullRequest: summary(id: id, number: number))
    }

    // MARK: - The answer

    func testTheOverviewIsSpokenAndTheCardCarriesTodaysSlugAndTitle() async {
        let answer = await SummarizePullRequestIntent.answer(
            for: entity(),
            summarizer: summarizer(
                router: router(onDeviceOverview: "It retries the upload twice.", riskNotes: ["No test."]),
                detail: detail()
            )
        )

        guard case .summary(let summarized) = answer else {
            return XCTFail("the on-device tier answered, so there should be a summary")
        }
        XCTAssertEqual(summarized.overview, "It retries the upload twice.")
        XCTAssertEqual(summarized.riskNotes, ["No test."])
        // From the row the digest was built from, not from the entity a stored shortcut kept:
        // ADR 0021's entity is a handle, so a voice answer names today's pull request.
        XCTAssertEqual(summarized.slug, "schnaq/review#128")
        XCTAssertEqual(summarized.title, "Retry the flaky upload")
    }

    func testOnlyTheOnDeviceRungIsAskedEvenWithACloudRungConfigured() async {
        let log = TierCallLog()
        let answer = await SummarizePullRequestIntent.answer(
            for: entity(),
            summarizer: summarizer(router: router(log: log), detail: detail())
        )

        guard case .summary(let summarized) = answer else {
            return XCTFail("the on-device tier is available, so it should have answered")
        }
        XCTAssertEqual(summarized.overview, "ON-DEVICE")
        // The rule stated as a call that did not happen. The cloud rung is present and would
        // ordinarily be tried *first*; the intent's `onDeviceOnly` is what keeps it out.
        let asked = await log.kinds
        XCTAssertEqual(asked, [.onDevice])
    }

    func testWithoutTheRuleTheSameRouterWouldHaveAnsweredFromTheCloud() async {
        // The control for the assertion above: nothing about the tiers, the configuration or the
        // pull request differs — only the parameter — so a regression that dropped `onDeviceOnly`
        // fails one of the two tests rather than neither.
        let log = TierCallLog()
        let outcome = await router(log: log).summary(for: detail())

        XCTAssertEqual(outcome.output?.value.overview, "CLOUD")
        XCTAssertEqual(outcome.output?.kind, .anthropic)
        let asked = await log.kinds
        XCTAssertEqual(asked, [.anthropic])
    }

    func testAnUnavailableOnDeviceModelIsTheFixedSentenceAndNothingElseRuns() async {
        let log = TierCallLog()
        let answer = await SummarizePullRequestIntent.answer(
            for: entity(),
            summarizer: summarizer(
                router: router(onDeviceUnavailabilityReason: "This Mac does not support it.", log: log),
                detail: detail()
            )
        )

        XCTAssertEqual(answer, .refusal(.modelUnavailable))
        // Not the cloud rung, which is configured here, and not the router's own three-way reason
        // either — that one is written for the card beside the toggle that fixes it.
        let asked = await log.kinds
        XCTAssertTrue(asked.isEmpty, "no tier may run once the on-device model is unavailable")
    }

    func testIntelligenceSwitchedOffIsItsOwnSentenceRatherThanTheModelsAbsence() async {
        let answer = await SummarizePullRequestIntent.answer(
            for: entity(),
            summarizer: summarizer(router: router(mode: .off), detail: detail())
        )
        XCTAssertEqual(answer, .refusal(.intelligenceOff))
    }

    func testAPullRequestWhoseDetailWasNeverFetchedIsARefusalAndNoTierIsAsked() async {
        let log = TierCallLog()
        let answer = await SummarizePullRequestIntent.answer(
            for: entity(),
            summarizer: summarizer(router: router(log: log), detail: nil)
        )

        XCTAssertEqual(answer, .refusal(.notFetched))
        let asked = await log.kinds
        XCTAssertTrue(asked.isEmpty, "there is nothing to summarise, so nothing may be asked")
    }

    func testATierThatAnswersWithBlankProseIsARefusalRatherThanSilence() async {
        // The one failure that would otherwise be inaudible: Siri would say nothing at all and
        // the card would be blank, which reads as a broken app.
        let answer = await SummarizePullRequestIntent.answer(
            for: entity(),
            summarizer: summarizer(router: router(onDeviceOverview: "   \n"), detail: detail())
        )
        XCTAssertEqual(answer, .refusal(.emptyAnswer))
    }

    func testADigestTooLargeForTierTwoIsSpokenAsTheTiersOwnReasonAndNotSentOn() async {
        // The budget path (plan §7): the on-device window is the only window this surface has, so
        // a pull request that does not fit is a sentence rather than a step up to the cloud rung —
        // which is exactly what the ladder would have done for the review screen's own card.
        let log = TierCallLog()
        let failure = IntelligenceError.digestTooLarge(tokens: 9_000, limit: 6_000)
        let answer = await SummarizePullRequestIntent.answer(
            for: entity(),
            summarizer: summarizer(
                router: router(onDeviceFailure: failure, log: log),
                detail: detail()
            )
        )

        XCTAssertEqual(answer, .refusal(.failed(failure.errorDescription ?? "")))
        let asked = await log.kinds
        XCTAssertEqual(asked, [.onDevice], "the cloud rung is not a budget fallback here")
    }

    // MARK: - Which pull request

    func testWithNoParameterTheTopOfTheReviewQueueIsSummarised() {
        let first = entity(id: "PR_1", number: 1)
        let second = entity(id: "PR_2", number: 2)

        XCTAssertEqual(
            SummarizePullRequestIntent.target(parameter: nil, queue: [first, second])?.id,
            "PR_1",
            "\"my next review\" is the queue's first row, in the queue's own order"
        )
        XCTAssertEqual(
            SummarizePullRequestIntent.target(parameter: second, queue: [first])?.id,
            "PR_2",
            "a shortcut that supplied an entity gets that entity"
        )
        XCTAssertNil(SummarizePullRequestIntent.target(parameter: nil, queue: []))
    }

    func testAnEmptyQueueAndNoParameterSaysNothingIsWaiting() async {
        let answer = await SummarizePullRequestIntent.answer(
            for: nil,
            summarizer: summarizer(router: router(), detail: detail())
        )
        XCTAssertEqual(answer, .refusal(.nothingWaiting))
    }

    // MARK: - What the card may carry

    func testTheCardKeepsAtMostThreeRiskNotes() {
        let summarized = SummarizedPullRequest(
            slug: "schnaq/review#128",
            title: "T",
            overview: "O",
            riskNotes: ["one", "two", "three", "four"]
        )
        XCTAssertEqual(summarized.riskNotes, ["one", "two", "three"])
        XCTAssertEqual(SummarizedPullRequest.maximumRiskNotes, 3)
    }

    func testEveryRefusalHasItsOwnNonEmptySentence() {
        let refusals: [PullRequestSummaryRefusal] = [
            .intelligenceOff,
            .modelUnavailable,
            .notFetched,
            .nothingWaiting,
            .emptyAnswer,
        ]
        // Compared against each other rather than against English text: `String(localized:)`
        // resolves in the runner's own language (ADR 0022), so the property worth pinning is that
        // each state says something, and something different.
        for refusal in refusals {
            XCTAssertFalse(refusal.sentence.isEmpty)
        }
        XCTAssertEqual(Set(refusals.map(\.sentence)).count, refusals.count)
        // A tier failure speaks the router's own formatted reason, unchanged.
        XCTAssertEqual(PullRequestSummaryRefusal.failed("Anthropic said no.").sentence, "Anthropic said no.")
    }

    func testTheEntityGainedNothingFromTheSummariseIntent() {
        // ADR 0021's guarantee, kept structural: the summary is the *result* of a run, so the
        // entity Shortcuts can drop into any other action still has nowhere to put an overview,
        // a risk note or a diff. A field added to it by accident fails here.
        let labels = Mirror(reflecting: entity())
            .children
            .compactMap { $0.label }
            .map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
        XCTAssertEqual(
            labels.count,
            6,
            "the entity's five exposed properties plus its id — a sixth field needs ADR 0021 reread"
        )
        let forbiddenFragments = [
            "summar", "overview", "risk", "body", "description", "diff", "patch", "comment", "draft",
        ]
        for forbidden in forbiddenFragments {
            XCTAssertFalse(
                labels.contains(where: { $0.lowercased().contains(forbidden) }),
                "PullRequestEntity must carry no \(forbidden): it leaves the app (ADR 0021)"
            )
        }
    }
}

// MARK: - Doubles

/// Which tiers were actually asked, in order.
///
/// An `actor` because ``IntelligenceProvider`` is `Sendable` and the router calls it from whatever
/// task the caller is on; it is also the only way to count the calls without a captured `var`.
private actor TierCallLog {
    private(set) var kinds: [IntelligenceKind] = []

    func record(_ kind: IntelligenceKind) {
        kinds.append(kind)
    }
}

/// A tier that answers a summary with a fixed overview and records that it was asked.
private struct SummaryStubTier: IntelligenceProvider {
    let kind: IntelligenceKind
    /// What this tier's summary says, so a test can tell which rung answered.
    let overview: String
    var riskNotes: [String] = []
    /// What this tier throws instead of answering, when a test wants a failing rung.
    var failure: IntelligenceError?
    /// Where being asked is recorded, when a test cares.
    let log: TierCallLog?

    var isAvailable: Bool { get async { true } }

    func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary {
        await log?.record(kind)
        if let failure = failure { throw failure }
        return PRSummary(overview: overview, riskNotes: riskNotes)
    }

    func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint] {
        throw IntelligenceError.malformedResponse
    }

    func draftReviewSummary(_ request: ReviewSummaryDraftRequest) async throws -> String {
        throw IntelligenceError.malformedResponse
    }

    func draftInlineComment(_ request: InlineCommentDraftRequest) async throws -> String {
        throw IntelligenceError.malformedResponse
    }
}
