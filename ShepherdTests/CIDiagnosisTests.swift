import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// "Why is CI red?" in the app target: the log tool, the card's state machine, and the hand-off
/// to a delegation brief (plan §3.F).
///
/// The pure halves are tested where they belong — the reduction and the job-id parser in
/// `ShepherdCoreTests`, the read in `GitHubKitTests`, the tool loop and the router's ladder in
/// `IntelligenceToolLoopTests`. What is left, and what is here, is everything a *reviewer* can
/// see:
///
/// - **The log reaches the model as a digest, or the tool says why it did not.** Four ways to
///   have no log, each with its own sentence, and none of them an error that could end a turn.
/// - **The card's state machine.** The cloud rung is offered for exactly one failure, only when a
///   key is configured, exactly once — and `preferCloud` is only ever `true` because somebody
///   pressed that button.
/// - **What the brief is handed.** One finding comment, the origin the log named, and no author,
///   because the sentence is Shepherd's own rather than a colleague's (ADR 0011's amendment).
@MainActor
final class CIDiagnosisTests: XCTestCase {
    // MARK: - Fixtures

    private static let checkName = "App build (macOS)"
    private static let jobID = 98_765
    private static let path = "ShepherdTests/LocalizationTests.swift"

    private static let log = """
        2026-09-02T09:14:22.1189001Z Run xcodebuild test
        2026-09-02T09:14:23.0000000Z CompileSwift normal arm64 Localizable.xcstrings
        2026-09-02T09:14:24.0000000Z ShepherdTests/LocalizationTests.swift:231:13: error: missing German row
        2026-09-02T09:14:25.0000000Z ** TEST FAILED **
        2026-09-02T09:14:26.0000000Z Process completed with exit code 65.
        """

    private func summary() -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            title: "Add the structured-triage settings row",
            author: ShepherdCore.Actor(login: "octocat", kind: .human),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 0),
            additions: 12,
            deletions: 3,
            changedFiles: 1,
            headRefName: "feature",
            headRefOid: "abc123",
            baseRefName: "main"
        )
    }

    /// A red Actions check, or a red check from another CI system when `detailsURL` says so.
    private func check(detailsURL: String?) -> CheckRun {
        CheckRun(
            id: "1",
            name: Self.checkName,
            status: .completed,
            conclusion: .failure,
            detailsURL: detailsURL.flatMap { URL(string: $0) },
            summary: "1 error"
        )
    }

    private func actionsCheck() -> CheckRun {
        check(
            detailsURL: "https://github.com/schnaq/review/actions/runs/7/job/\(Self.jobID)"
        )
    }

    private func detail(checks: [CheckRun]? = nil) -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(),
            bodyMarkdown: "Adds the row.",
            files: [
                ChangedFile(
                    path: Self.path,
                    status: .modified,
                    additions: 12,
                    deletions: 3,
                    patch: "@@ -1,3 +1,3 @@\n context\n-old\n+new\n"
                ),
            ],
            checks: checks ?? [actionsCheck()]
        )
    }

    private func call() -> IntelligenceToolCall {
        IntelligenceToolCall(
            id: "c1",
            tool: .jobLogTail,
            arguments: ["checkName": .string(Self.checkName)]
        )
    }

    // MARK: - The log tool

    func testTheLogReachesTheModelReducedAndTheTraceLineSaysWhatItCost() async throws {
        let fetcher = FakeLogFetcher(log: Self.log)
        let executor = LocalToolExecutor(
            detail: detail(),
            budget: .onDevice,
            jobLog: fetcher
        )

        let result = try await executor.execute(call())

        XCTAssertTrue(result.content.contains("error: missing German row"))
        XCTAssertTrue(result.content.contains("** TEST FAILED **"))
        // The reduction happened: the Actions timestamps are gone and the compile line that
        // matched nothing is not in the failing region… except as context, which it is here.
        XCTAssertFalse(result.content.contains("2026-09-02T09:14:24"))
        XCTAssertTrue(result.content.contains(Self.checkName))
        XCTAssertTrue(result.summaryLine.contains(Self.checkName))
        XCTAssertTrue(result.summaryLine.contains("5"), "of five lines")
        XCTAssertEqual(result.callID, "c1")

        // The read went to the right job, once.
        let asks = await fetcher.asks
        XCTAssertEqual(
            asks,
            [FakeLogFetcher.Ask(repo: "schnaq/review", jobID: Self.jobID)]
        )
    }

    func testACheckThatIsNotAnActionsJobSaysSoInsteadOfFailing() async throws {
        let executor = LocalToolExecutor(
            detail: detail(checks: [check(detailsURL: "https://buildkite.com/schnaq/review/builds/5")]),
            budget: .onDevice,
            jobLog: FakeLogFetcher(log: Self.log)
        )

        let result = try await executor.execute(call())

        XCTAssertTrue(result.content.contains("not a GitHub Actions job"))
        XCTAssertTrue(result.content.contains("summary"), "it names what to do instead")
        XCTAssertFalse(result.wasTruncated)
        XCTAssertTrue(result.summaryLine.contains(Self.checkName))
    }

    func testAReadThatFailedIsAResultRatherThanAnErrorThatEndsTheTurn() async throws {
        let executor = LocalToolExecutor(
            detail: detail(),
            budget: .onDevice,
            jobLog: FakeLogFetcher(log: nil)
        )

        let result = try await executor.execute(call())

        XCTAssertTrue(result.content.contains("could not be read"))
        XCTAssertTrue(result.content.contains("summary"))
        XCTAssertFalse(result.summaryLine.isEmpty)
    }

    func testAnEmptyLogSaysItIsEmpty() async throws {
        let executor = LocalToolExecutor(
            detail: detail(),
            budget: .onDevice,
            jobLog: FakeLogFetcher(log: "")
        )

        let result = try await executor.execute(call())

        XCTAssertTrue(result.content.contains("is empty"))
        XCTAssertFalse(result.wasTruncated)
    }

    func testTheCloudRungsExecutorMayReadMoreOfTheLogThanTheOnDeviceOne() async throws {
        // A log whose failing region is larger than the on-device share of the budget.
        let long = (1...400)
            .map { "error: failure \($0) " + String(repeating: "x", count: 40) }
            .joined(separator: "\n")
        func content(_ budget: TokenBudget) async throws -> String {
            try await LocalToolExecutor(
                detail: detail(),
                budget: budget,
                jobLog: FakeLogFetcher(log: long)
            ).execute(call()).content
        }

        let onDevice = try await content(.onDevice)
        let cloud = try await content(.cloud)

        XCTAssertLessThanOrEqual(
            onDevice.count,
            LogDigest.characterLimit(for: .onDevice) + 200,
            "the on-device digest stays inside the tier's share"
        )
        XCTAssertGreaterThan(
            cloud.count,
            onDevice.count,
            "the rung the reviewer explicitly asked for sees more of the log"
        )
        XCTAssertTrue(onDevice.contains("failure 400"), "the last failure is always kept")
    }

    // MARK: - The card's state machine

    func testASuccessfulDiagnosisKeepsTheTierAndTheTraceTheModelProduced() async {
        let log = DiagnoseLog()
        let model = CIDiagnosisModel()

        await model.diagnose(
            check: actionsCheck(),
            detail: detail(),
            summary: summary(),
            router: router(log: log),
            jobLog: nil
        )

        guard let state = model.state, case .diagnosed(let kind, let run) = state else {
            XCTFail("expected a diagnosis, got \(String(describing: model.state))")
            return
        }
        XCTAssertEqual(kind, .onDevice)
        XCTAssertEqual(run.value.failingTest, "testGermanRow")
        XCTAssertEqual(run.value.file, Self.path)
        XCTAssertEqual(run.value.line, 231)
        XCTAssertEqual(run.hopCount, 1)
        XCTAssertEqual(run.trace.orderedSteps.first?.resultContent, "the log, as the model saw it")
        XCTAssertFalse(model.isAsking)
        let asked = await log.kinds
        XCTAssertEqual(asked, [.onDevice], "the cloud tier is not part of a successful answer")
    }

    func testABudgetFailureOffersTheCloudRungOnlyWhenOneIsConfigured() async {
        let withKey = CIDiagnosisModel()
        await withKey.diagnose(
            check: actionsCheck(),
            detail: detail(),
            summary: summary(),
            router: router(log: DiagnoseLog(), failures: [.onDevice: .contextExceeded]),
            jobLog: nil
        )
        guard let offeredState = withKey.state,
              case .tooLargeForDevice(let message, let canAskCloud) = offeredState
        else {
            XCTFail("expected the budget state, got \(String(describing: withKey.state))")
            return
        }
        XCTAssertTrue(canAskCloud)
        XCTAssertEqual(message, IntelligenceError.contextExceeded.errorDescription)

        let withoutKey = CIDiagnosisModel()
        await withoutKey.diagnose(
            check: actionsCheck(),
            detail: detail(),
            summary: summary(),
            router: router(
                log: DiagnoseLog(),
                hasCloud: false,
                failures: [.onDevice: .digestTooLarge(tokens: 9_000, limit: 6_000)]
            ),
            jobLog: nil
        )
        guard let silentState = withoutKey.state,
              case .tooLargeForDevice(_, let offered) = silentState
        else {
            XCTFail("expected the budget state, got \(String(describing: withoutKey.state))")
            return
        }
        XCTAssertFalse(offered, "no key, no button — the card says the log did not fit instead")
    }

    func testTheCloudRungIsOnlyReachedByTheButtonAndIsNotOfferedTwice() async {
        let log = DiagnoseLog()
        let ladder = router(log: log, failures: [.onDevice: .contextExceeded])
        let model = CIDiagnosisModel()

        // The first click: no consent, so the cloud tier is not asked at all.
        await model.diagnose(
            check: actionsCheck(),
            detail: detail(),
            summary: summary(),
            router: ladder,
            jobLog: nil
        )
        var asked = await log.kinds
        XCTAssertEqual(asked, [.onDevice])

        // The button: the same question, with consent for this click only.
        await model.diagnose(
            check: actionsCheck(),
            detail: detail(),
            summary: summary(),
            router: ladder,
            jobLog: nil,
            preferCloud: true
        )
        asked = await log.kinds
        XCTAssertEqual(asked, [.onDevice, .onDevice, .anthropic])
        guard let state = model.state, case .diagnosed(let kind, _) = state else {
            XCTFail("expected the cloud rung to answer, got \(String(describing: model.state))")
            return
        }
        XCTAssertEqual(kind, .anthropic)
    }

    func testACloudRungThatFailsIsAFailureRatherThanASecondOffer() async {
        let model = CIDiagnosisModel()
        await model.diagnose(
            check: actionsCheck(),
            detail: detail(),
            summary: summary(),
            router: router(
                log: DiagnoseLog(),
                failures: [.onDevice: .contextExceeded, .anthropic: .http(status: 401, message: "bad key")]
            ),
            jobLog: nil,
            preferCloud: true
        )

        guard let state = model.state, case .failed(let message) = state else {
            XCTFail("expected a failure, got \(String(describing: model.state))")
            return
        }
        XCTAssertTrue(message.contains("401") || message.contains("bad key"), message)
    }

    func testEveryOtherFailureIsShownAsOneLineWithNoWayToTheCloud() async {
        let model = CIDiagnosisModel()
        await model.diagnose(
            check: actionsCheck(),
            detail: detail(),
            summary: summary(),
            router: router(log: DiagnoseLog(), failures: [.onDevice: .guardrailDeclined]),
            jobLog: nil
        )

        XCTAssertEqual(
            model.state,
            .failed(IntelligenceError.guardrailDeclined.errorDescription ?? "")
        )
    }

    func testAPullRequestWithNothingRedIsAnsweredWithoutAskingATier() async {
        let log = DiagnoseLog()
        let green = [CheckRun(id: "9", name: "Tests", status: .completed, conclusion: .success)]
        let model = CIDiagnosisModel()

        await model.diagnose(
            check: green[0],
            detail: detail(checks: green),
            summary: summary(),
            router: router(log: log),
            jobLog: nil
        )

        guard let state = model.state, case .failed(let message) = state else {
            XCTFail("expected the router's own sentence, got \(String(describing: model.state))")
            return
        }
        XCTAssertFalse(message.isEmpty)
        let asked = await log.kinds
        XCTAssertTrue(asked.isEmpty)
    }

    func testClosingTheCardForgetsTheDiagnosisAndTheCheckItWasAbout() async {
        let model = CIDiagnosisModel()
        await model.diagnose(
            check: actionsCheck(),
            detail: detail(),
            summary: summary(),
            router: router(log: DiagnoseLog()),
            jobLog: nil
        )
        XCTAssertNotNil(model.state)
        XCTAssertEqual(model.checkName, Self.checkName)

        model.dismiss()

        XCTAssertNil(model.state)
        XCTAssertNil(model.checkName)
        XCTAssertNil(model.diagnosis)
    }

    // MARK: - The hand-off to a brief (plan §3.E)

    func testTheBriefIsHandedTheFindingTheLogNamedAndNothingElse() async throws {
        let model = CIDiagnosisModel()
        await model.diagnose(
            check: actionsCheck(),
            detail: detail(),
            summary: summary(),
            router: router(log: DiagnoseLog()),
            jobLog: nil
        )

        let context = try XCTUnwrap(
            model.briefContext(summary: summary(), focusReasons: ["A.swift — touches auth"])
        )
        XCTAssertEqual(context.prID, "PR_1")
        XCTAssertEqual(context.headRefOid, "abc123")
        XCTAssertEqual(context.origin, .reviewFinding(path: Self.path, line: 231))
        XCTAssertEqual(
            context.findingComments,
            ["CI: testGermanRow — The German row for the new key is missing."]
        )
        // Empty on purpose: the sentence is Shepherd's, not a colleague's, so the brief may be
        // drafted by whichever tier the ladder picks (ADR 0011's amendment).
        XCTAssertEqual(context.findingCommentAuthors, [])
        XCTAssertEqual(context.focusReasons, ["A.swift — touches auth"])

        // And the task the sheet prefills names the file and the line, which is the whole point
        // of the origin above.
        let task = DelegationPrompt.defaultTask(for: context)
        XCTAssertTrue(task.contains(Self.path))
        XCTAssertTrue(task.contains("231"))
        XCTAssertTrue(task.contains("The German row for the new key is missing."))
    }

    func testWithoutADiagnosisThereIsNoBriefToDraft() {
        XCTAssertNil(CIDiagnosisModel().briefContext(summary: summary()))
    }

    func testADiagnosisThatNamedNoFileFallsBackToThePullRequestAndTheCheckName() {
        let context = CIDiagnosisModel.briefContext(
            diagnosis: CIDiagnosis(hypothesis: "The runner ran out of disk.", confidence: .low),
            checkName: Self.checkName,
            summary: summary()
        )

        XCTAssertEqual(context.origin, .pullRequest)
        XCTAssertEqual(
            context.findingComments,
            ["CI: \(Self.checkName) — The runner ran out of disk."]
        )
    }

    // MARK: - The card's copy

    func testTheCardNamesTheTierTheConfidenceAndTheLocation() {
        XCTAssertEqual(CIDiagnosisCard.tierLine(.onDevice), "Diagnosed on-device")
        XCTAssertTrue(CIDiagnosisCard.tierLine(.anthropic).contains("Anthropic"))
        XCTAssertTrue(
            CIDiagnosisCard.tierLine(.openAICompatible).contains("custom endpoint"),
            "the tier a reviewer configured is named, never \"the cloud\""
        )

        XCTAssertNotEqual(
            CIDiagnosisCard.confidenceLabel(.high),
            CIDiagnosisCard.confidenceLabel(.low)
        )
        for confidence in CIDiagnosis.Confidence.allCases {
            XCTAssertFalse(CIDiagnosisCard.confidenceLabel(confidence).isEmpty)
        }

        XCTAssertEqual(
            CIDiagnosisCard.locationText(file: "A.swift", line: 12),
            "A.swift:12"
        )
        XCTAssertEqual(
            CIDiagnosisCard.locationText(file: "A.swift", line: nil),
            "A.swift",
            "a log that named no line does not get a fabricated one"
        )

        for tool in IntelligenceToolName.allCases {
            XCTAssertFalse(CIDiagnosisTraceView.label(for: tool).isEmpty)
        }
    }

    // MARK: - Router fixtures

    /// Tiers whose diagnosis is scripted per tier, recording which were asked.
    /// - Parameters:
    ///   - log: Records the tiers, in order.
    ///   - hasCloud: Whether a cloud tier is configured. `false` for a Mac with no key.
    ///   - failures: What a tier throws instead of answering.
    private func router(
        log: DiagnoseLog,
        hasCloud: Bool = true,
        failures: [IntelligenceKind: IntelligenceError] = [:]
    ) -> IntelligenceRouter {
        // Copied into locals first: the closure below is `@Sendable` and runs off the main actor,
        // so it must not reach back into this `@MainActor` test class for its fixtures.
        let checkName = Self.checkName
        let path = Self.path
        return IntelligenceRouter(
            configuration: IntelligenceConfiguration(mode: .onDeviceAndCloud),
            tiers: IntelligenceTiers(
                cloud: { _ in hasCloud ? StubDiagnosisTier(kind: .anthropic) : nil },
                onDevice: { StubDiagnosisTier(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil },
                diagnose: { provider, _, _ in
                    await log.record(provider.kind)
                    if let failure = failures[provider.kind] { throw failure }
                    var trace = IntelligenceTrace()
                    trace.append(
                        tool: .jobLogTail,
                        arguments: ["checkName": .string(checkName)],
                        summaryLine: "last 5 of 120 lines of \(checkName)",
                        duration: 0.2,
                        resultContent: "the log, as the model saw it"
                    )
                    return IntelligenceToolRun(
                        value: CIDiagnosis(
                            failingTest: "testGermanRow",
                            file: path,
                            line: 231,
                            hypothesis: "The German row for the new key is missing.",
                            confidence: .high
                        ),
                        trace: trace
                    )
                }
            )
        )
    }
}

// MARK: - Doubles

/// A job-log read that answers from the test instead of from GitHub.
///
/// An `actor` because the executor is one and calls it from its own context, and because the
/// recorded asks are read back from the test's: asserting *which job* was read is half the point.
private actor FakeLogFetcher: JobLogFetching {
    /// One recorded read.
    struct Ask: Equatable {
        var repo: String
        var jobID: Int
    }

    /// The one way this double fails.
    enum Failure: Error {
        case unreachable
    }

    private let log: String?
    /// Every read, in order.
    private(set) var asks: [Ask] = []

    /// Creates a fetcher.
    /// - Parameter log: The log to answer with, or `nil` to fail the way a dropped connection
    ///   would.
    init(log: String?) {
        self.log = log
    }

    func jobLog(repo: RepoRef, jobID: Int) async throws -> String {
        asks.append(Ask(repo: repo.fullName, jobID: jobID))
        guard let log else { throw Failure.unreachable }
        return log
    }
}

/// Which tiers the router asked, in order.
private actor DiagnoseLog {
    private(set) var kinds: [IntelligenceKind] = []

    func record(_ kind: IntelligenceKind) {
        kinds.append(kind)
    }
}

/// A tier that answers nothing on its own: every test here scripts the diagnosis instead.
private struct StubDiagnosisTier: IntelligenceProvider {
    let kind: IntelligenceKind

    var isAvailable: Bool { get async { true } }

    func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary {
        throw IntelligenceError.malformedResponse
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
