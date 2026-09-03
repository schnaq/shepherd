import Foundation
import ShepherdCore
import XCTest

@testable import Shepherd

/// The delegation brief (plan §3.E): what a tier is handed, which tier may see it, what happens to
/// the task field while it arrives — and the one thing that must *not* happen, which is a run.
///
/// Five things are worth testing here and none of them needs a window, a network or a Mac with
/// Apple Intelligence switched on:
///
/// - **The budget.** The finding comments' share is reserved before the digest is built, so the
///   two together stay inside the tier's window even on a pull request with a long review on it.
/// - **The privacy rule.** A brief that quotes a colleague's comment is pinned to the on-device
///   tier, and the *ladder* is what enforces it — the cloud rung is never offered the request.
/// - **The field.** A streamed brief grows in the task field and ends labelled with the tier that
///   wrote it.
/// - **Run is the reviewer's.** A draft — arriving, stopped or finished — never starts anything,
///   and the prompt a run sends is built from whatever text is in the field at that moment.
/// - **Unattended stays templated.** A rule-started delegation has no drafter at all, and its task
///   text is exactly what its template rendered (ADR 0016).
@MainActor
final class AgentBriefTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shepherd-brief-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Fixtures

    private func summary(number: Int = 42) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
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
            myRelation: [.author]
        )
    }

    /// A patch far too long for the on-device tier, so the budget has to bite.
    private func longPatch(lines: Int = 400) -> String {
        var text = "@@ -1,\(lines) +1,\(lines) @@\n"
        for index in 1...lines {
            text += " context line \(index) — code long enough for the budget to matter\n"
        }
        return text + "+added tail line\n"
    }

    private func detail(patch: String? = nil) -> PullRequestDetail {
        PullRequestDetail(
            summary: summary(),
            bodyMarkdown: String(repeating: "The upload retries twice before giving up. ", count: 40),
            files: [
                ChangedFile(
                    path: "Sources/Upload.swift",
                    status: .modified,
                    additions: 12,
                    deletions: 3,
                    patch: patch ?? longPatch()
                )
            ]
        )
    }

    private func context(
        origin: DelegationContext.Origin = .pullRequest,
        focusReasons: [String] = ["Sources/Upload.swift — security-sensitive path"],
        findingComments: [String] = [],
        findingCommentAuthors: [String] = []
    ) -> DelegationContext {
        DelegationContext(
            prID: "PR_1",
            repo: RepoRef(owner: "schnaq", name: "review"),
            number: 42,
            title: "Retry the flaky upload",
            headRefName: "agent/fix",
            headRefOid: "0123456789abcdef0123",
            origin: origin,
            focusReasons: focusReasons,
            findingComments: findingComments,
            findingCommentAuthors: findingCommentAuthors
        )
    }

    /// A context that came from a review thread, with one comment per author given.
    private func findingContext(
        comments: [String],
        authors: [String] = []
    ) -> DelegationContext {
        context(
            origin: .reviewFinding(path: "Sources/Upload.swift", line: 12),
            findingComments: comments,
            findingCommentAuthors: authors
        )
    }

    // MARK: - The budget

    func testTheFindingCommentsShareIsReservedBeforeTheDigestIsBuilt() {
        let budget = TokenBudget.onDevice
        let reserved = AgentBriefRequest.digestBudget(in: budget)

        XCTAssertLessThan(reserved.maxTokens, budget.maxTokens, "the digest gets less than the tier")
        XCTAssertEqual(reserved.charactersPerToken, budget.charactersPerToken)
        XCTAssertEqual(
            budget.maxTokens - reserved.maxTokens,
            budget.approximateTokens(
                characterCount: AgentBriefRequest.reservedCharacters(in: budget)
            ),
            "exactly the comments' share plus the header's is held back"
        )
        XCTAssertEqual(
            AgentBriefRequest.reservedCharacters(in: budget),
            AgentBriefRequest.findingsCharacterLimit(in: budget) + AgentBriefRequest.headerCharacters
        )
        // The floor matters on a small budget: one short finding is the whole brief on a one-line
        // review, and a share of a tiny budget would round it away.
        let tiny = TokenBudget(maxTokens: 100)
        XCTAssertEqual(
            AgentBriefRequest.findingsCharacterLimit(in: tiny),
            AgentBriefRequest.minimumFindingsCharacters
        )
        XCTAssertGreaterThanOrEqual(AgentBriefRequest.digestBudget(in: tiny).maxTokens, 1)
    }

    func testTheWholeRequestStaysInsideTheOnDeviceBudget() {
        let budget = TokenBudget.onDevice
        let comments = (1...12).map { index in
            "Comment \(index): " + String(repeating: "this is far too long to send. ", count: 40)
        }
        let request = AgentBriefRequest.build(
            context: findingContext(comments: comments),
            digest: AgentBriefRequest.digest(for: detail(), budget: budget),
            budget: budget
        )

        XCTAssertTrue(request.digest.wasTruncated, "the fixture is bigger than the tier")
        XCTAssertLessThanOrEqual(
            request.digest.approximateTokenCount,
            AgentBriefRequest.digestBudget(in: budget).maxTokens
        )
        XCTAssertLessThanOrEqual(
            request.approximateTokenCount,
            budget.maxTokens,
            "the digest, the header, the reasons and the comments together fit the tier"
        )
    }

    func testTheCloudTierIsAskedForMoreOfTheSamePullRequest() {
        let comments = (1...12).map { index in
            "Comment \(index): " + String(repeating: "please fix the retry bound. ", count: 30)
        }
        let onDevice = AgentBriefRequest.build(
            context: findingContext(comments: comments),
            digest: AgentBriefRequest.digest(for: detail(), budget: .onDevice),
            budget: .onDevice
        )
        let cloud = AgentBriefRequest.build(
            context: findingContext(comments: comments),
            digest: AgentBriefRequest.digest(for: detail(), budget: .cloud),
            budget: .cloud
        )
        // The comments are capped by count long before either tier's character share bites, so
        // what the larger window buys is diff: more of the pull request itself.
        XCTAssertGreaterThan(cloud.digest.approximateTokenCount, onDevice.digest.approximateTokenCount)
        XCTAssertGreaterThan(cloud.approximateTokenCount, onDevice.approximateTokenCount)
        XCTAssertEqual(cloud.findings.count, AgentBriefRequest.maximumFindings)
        XCTAssertEqual(onDevice.findings.count, AgentBriefRequest.maximumFindings)
        XCTAssertLessThanOrEqual(cloud.approximateTokenCount, TokenBudget.cloud.maxTokens)
    }

    func testTheCommentsAreCappedByCountAndByLengthAndTheEmptyOnesAreDropped() {
        let request = AgentBriefRequest.build(
            context: findingContext(comments: (1...20).map { "Finding \($0)." }),
            digest: AgentBriefRequest.digest(for: detail(), budget: .cloud),
            budget: .cloud
        )
        XCTAssertEqual(request.findings.count, AgentBriefRequest.maximumFindings)
        XCTAssertEqual(request.findings.first?.body, "Finding 1.", "oldest first")

        // A comment longer than one comment's share is cut, and says that it was.
        let long = String(repeating: "x", count: AgentBriefRequest.maximumFindingCharacters + 50)
        let capped = AgentBriefRequest.findings(
            in: findingContext(comments: [long]),
            budget: .cloud
        )
        XCTAssertEqual(
            capped.first?.body.count,
            AgentBriefRequest.maximumFindingCharacters + 1,
            "the cap plus the ellipsis that says it was cut"
        )
        XCTAssertTrue(capped.first?.body.hasSuffix("…") == true)

        // Blank comments never take a slot.
        XCTAssertEqual(
            AgentBriefRequest.findings(
                in: findingContext(comments: ["   ", "First finding.", "\n"]),
                budget: .cloud
            ).map(\.body),
            ["First finding."]
        )

        // On a budget small enough for the *character* share to bite before the count cap, it
        // does, and it always keeps at least the first comment.
        let tight = TokenBudget(maxTokens: 200)
        let squeezed = AgentBriefRequest.findings(
            in: findingContext(comments: Array(repeating: String(repeating: "y", count: 300), count: 4)),
            budget: tight
        )
        XCTAssertEqual(squeezed.count, 1)
    }

    func testTheRequestCarriesTheDelegationsOwnFactsAndTheShortenedCommit() {
        let request = AgentBriefRequest.build(
            context: findingContext(comments: ["Fix the retry bound."]),
            digest: AgentBriefRequest.digest(for: detail(), budget: .cloud),
            budget: .cloud
        )
        XCTAssertEqual(request.slug, "schnaq/review#42")
        XCTAssertEqual(request.headRefName, "agent/fix")
        XCTAssertEqual(request.headRefOid, "0123456789ab", "the same twelve the preamble prints")
        XCTAssertEqual(request.findingPath, "Sources/Upload.swift")
        XCTAssertEqual(request.findingLine, 12)

        let wholePullRequest = AgentBriefRequest.build(
            context: context(),
            digest: AgentBriefRequest.digest(for: detail(), budget: .cloud),
            budget: .cloud
        )
        XCTAssertNil(wholePullRequest.findingPath)
        XCTAssertNil(wholePullRequest.findingLine)
        XCTAssertEqual(wholePullRequest.findings, [])
    }

    // MARK: - The prompt

    func testThePromptAsksForTheThreeSectionsAndNamesTheDelegation() {
        let request = AgentBriefRequest.build(
            context: findingContext(comments: ["Fix the retry bound."]),
            digest: AgentBriefRequest.digest(for: detail(), budget: .cloud),
            budget: .cloud
        )
        let body = IntelligencePrompt.body(for: request)

        XCTAssertTrue(body.contains("schnaq/review#42"))
        XCTAssertTrue(body.contains("0123456789ab"))
        XCTAssertTrue(body.contains("Sources/Upload.swift, line 12"))
        XCTAssertTrue(body.contains("Fix the retry bound."))
        // The digest is in there too, and after the delegation's own facts.
        XCTAssertTrue(body.contains("Files (highest review priority first):"))

        let contract = IntelligencePrompt.agentBriefMarkdownContract
        XCTAssertTrue(contract.contains(AgentBrief.goalHeading))
        XCTAssertTrue(contract.contains(AgentBrief.constraintsHeading))
        XCTAssertTrue(contract.contains(AgentBrief.acceptanceHeading))
        XCTAssertTrue(contract.contains("no JSON"), "a half-written JSON object is not readable")

        // The instructions carry the product rule and the reviewer's language.
        let instructions = IntelligencePrompt.agentBriefInstructions
        XCTAssertTrue(instructions.contains("starts the agent themselves"))
        XCTAssertTrue(instructions.contains(IntelligencePrompt.answerLanguageName))
        XCTAssertFalse(IntelligencePrompt.answerLanguageName.isEmpty)
    }

    func testADelegationWithoutAFindingSaysSoRatherThanLeavingTheSectionOut() {
        let body = IntelligencePrompt.body(
            for: AgentBriefRequest.build(
                context: context(),
                digest: AgentBriefRequest.digest(for: detail(), budget: .cloud),
                budget: .cloud
            )
        )
        XCTAssertTrue(body.contains("No review comment is attached"))
        XCTAssertTrue(body.contains("Shepherd ranked these files as the riskiest:"))
    }

    // MARK: - The privacy rule

    func testTheReviewersOwnCommentsAreNotPinnedToTheOnDeviceTier() {
        // Bodies with no author at all: what a delegation has carried since ADR 0011, and what a
        // pending review's comments are — the reviewer's own.
        XCTAssertFalse(
            AgentBriefRequest.requiresOnDevice(
                context: findingContext(comments: ["Fix the retry bound."]),
                viewerLogin: "octocat"
            )
        )
        // Named, and the name is the signed-in user's.
        XCTAssertFalse(
            AgentBriefRequest.requiresOnDevice(
                context: findingContext(comments: ["Fix it."], authors: ["octocat"]),
                viewerLogin: "OctoCat"
            ),
            "GitHub logins are not case-sensitive"
        )
    }

    func testAColleaguesCommentPinsTheBriefToTheOnDeviceTier() {
        XCTAssertTrue(
            AgentBriefRequest.requiresOnDevice(
                context: findingContext(
                    comments: ["Fix it.", "And the timeout."],
                    authors: ["octocat", "hubot"]
                ),
                viewerLogin: "octocat"
            )
        )
        // No signed-in login to compare against is not evidence of ownership.
        XCTAssertTrue(
            AgentBriefRequest.requiresOnDevice(
                context: findingContext(comments: ["Fix it."], authors: ["hubot"]),
                viewerLogin: nil
            )
        )
        // And the rule is read from the *uncapped* comments: a colleague's sentence that the
        // character cap happened to drop still pins the request.
        let many = (1...AgentBriefRequest.maximumFindings + 4).map { "Finding \($0)." }
        let authors = Array(repeating: "octocat", count: many.count - 1) + ["hubot"]
        let mixed = findingContext(comments: many, authors: authors)
        XCTAssertTrue(AgentBriefRequest.requiresOnDevice(context: mixed, viewerLogin: "octocat"))
        let request = AgentBriefRequest.build(
            context: mixed,
            digest: AgentBriefRequest.digest(for: detail(), budget: .onDevice),
            budget: .onDevice,
            viewerLogin: "octocat"
        )
        XCTAssertTrue(request.onDeviceOnly)
        XCTAssertFalse(
            request.findings.contains { $0.author == "hubot" },
            "the cap dropped it, and the flag survived that"
        )
    }

    // MARK: - The ladder

    func testTheCloudRungAnswersABriefBuiltFromTheReviewersOwnComments() async throws {
        let ladder = briefRouter()
        let outcome = await ladder.streamAgentBrief(
            for: findingContext(comments: ["Fix the retry bound."], authors: ["octocat"]),
            digest: AgentBriefRequest.digest(for: detail(), budget: .onDevice),
            viewerLogin: "octocat"
        )
        let stream = try XCTUnwrap(outcome.stream)
        XCTAssertEqual(stream.kind, .anthropic, "the usual ladder: cloud first")
        let received = try await collect(stream.text)
        XCTAssertEqual(received, ["anthropic brief"])
    }

    func testABriefQuotingAColleagueNeverReachesTheCloudRung() async throws {
        let ladder = briefRouter()
        let outcome = await ladder.streamAgentBrief(
            for: findingContext(comments: ["Fix the retry bound."], authors: ["hubot"]),
            digest: AgentBriefRequest.digest(for: detail(), budget: .onDevice),
            viewerLogin: "octocat"
        )
        let stream = try XCTUnwrap(outcome.stream)
        XCTAssertEqual(stream.kind, .onDevice, "the cloud rung was not offered the request")
        let received = try await collect(stream.text)
        XCTAssertEqual(received, ["onDevice brief"])
    }

    func testAnOnDeviceOnlyBriefWithNoOnDeviceTierSaysWhyRatherThanUsingTheCloud() async {
        let reason = "Apple Intelligence is turned off in System Settings."
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in BriefStubTier(kind: .anthropic) },
                onDevice: { BriefStubTier(kind: .onDevice) },
                onDeviceUnavailabilityReason: { reason },
                briefStream: { provider, _ in briefScript(["\(provider.kind.rawValue) brief"]) }
            )
        )
        let outcome = await router.streamAgentBrief(
            for: findingContext(comments: ["Fix it."], authors: ["hubot"]),
            digest: AgentBriefRequest.digest(for: detail(), budget: .onDevice),
            viewerLogin: "octocat"
        )
        XCTAssertNil(outcome.stream, "no tier may answer this one")
        XCTAssertEqual(outcome.failure, .unavailable(reason))
    }

    func testATierWithNoBriefShapedCallDeclinesWithOneReadableLine() async {
        // The protocol's default implementation. A tier that answered out of the review-summary
        // prompt would put six sentences of review prose in the task field.
        let router = IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in BriefStubTier(kind: .anthropic) },
                onDevice: { BriefStubTier(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil }
            )
        )
        let outcome = await router.streamAgentBrief(
            for: context(),
            digest: AgentBriefRequest.digest(for: detail(), budget: .onDevice)
        )
        XCTAssertNil(outcome.stream)
        // Compared against the error the default implementation throws rather than against an
        // English phrase: `String(localized:)` resolves in the runner's own language.
        XCTAssertEqual(
            outcome.failure,
            .failed(
                IntelligenceError.unavailable(
                    String(localized: "This tier cannot draft a brief for a coding agent.")
                ).errorDescription ?? ""
            )
        )
    }

    func testDraftingIsDisabledWhenIntelligenceIsOff() async {
        let router = IntelligenceRouter(configuration: .disabled)
        let outcome = await router.streamAgentBrief(
            for: context(),
            digest: AgentBriefRequest.digest(for: detail(), budget: .onDevice)
        )
        XCTAssertEqual(outcome.failure, .disabled)
    }

    // MARK: - The field, and the Run button beside it

    func testAScriptedBriefGrowsInTheTaskFieldAndEndsLabelledWithItsTier() async {
        let sheet = BriefSheet(
            model: makeModel(
                runner: ScriptedAgentRunner(),
                brief: drafter { .stream(IntelligenceStream(kind: .onDevice, text: briefScript([
                    "## Goal",
                    "## Goal\n\nFix the retry bound.\n",
                ]))) }
            )
        )
        // The prefilled task is the reviewer's text as far as the field is concerned, so the
        // question comes first — this is the same rule the review composers follow.
        XCTAssertFalse(sheet.model.task.isEmpty)
        sheet.toggle()
        XCTAssertTrue(sheet.draft.isConfirmingStream, "nothing was requested yet")
        XCTAssertEqual(sheet.writes, [])

        sheet.resolve(.replace)
        await sheet.settle()

        XCTAssertEqual(sheet.writes.first, "## Goal", "the field grows from the first word")
        XCTAssertEqual(sheet.model.task, "## Goal\n\nFix the retry bound.", "trimmed once, at the end")
        XCTAssertEqual(sheet.draft.draftedKind, .onDevice, "the caption names the tier that wrote it")
        XCTAssertEqual(sheet.draft.labelledKind, .onDevice)
        XCTAssertNil(sheet.draft.failureMessage)
        XCTAssertEqual(sheet.model.state, .idle, "a finished draft has not started anything")
    }

    func testAppendingGrowsTheBriefUnderTheReviewersOwnTask() async {
        let sheet = BriefSheet(
            model: makeModel(
                runner: ScriptedAgentRunner(),
                brief: drafter {
                    .stream(IntelligenceStream(kind: .anthropic, text: briefScript(["## Goal"])))
                }
            )
        )
        let original = sheet.model.task
        sheet.toggle()
        sheet.resolve(.append)
        await sheet.settle()

        XCTAssertEqual(sheet.model.task, original + "\n\n## Goal")
        XCTAssertEqual(sheet.draft.draftedKind, .anthropic)
    }

    func testTypingDuringABriefKeepsTheKeystrokeAndEndsTheRequest() async {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(of: String.self)
        let sheet = BriefSheet(
            model: makeModel(
                runner: ScriptedAgentRunner(),
                brief: drafter { .stream(IntelligenceStream(kind: .onDevice, text: stream)) }
            )
        )
        sheet.toggle()
        sheet.resolve(.replace)
        continuation.yield("## Goal")
        await sheet.wait { sheet.model.task == "## Goal" }

        sheet.type("Fix it yourself.")
        XCTAssertEqual(sheet.model.task, "Fix it yourself.")
        XCTAssertNil(sheet.draft.labelledKind, "their keystroke makes it their text")
        XCTAssertFalse(sheet.draft.isDrafting, "the stop happened without a click")

        continuation.yield("## Goal\n\nFix the retry bound.")
        continuation.finish()
        await sheet.settle()
        XCTAssertEqual(sheet.model.task, "Fix it yourself.", "later snapshots are refused")
        XCTAssertNil(sheet.draft.failureMessage)
    }

    func testStoppingABriefKeepsWhatArrivedAndIsNotAFailure() async {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(of: String.self)
        let sheet = BriefSheet(
            model: makeModel(
                runner: ScriptedAgentRunner(),
                brief: drafter { .stream(IntelligenceStream(kind: .onDevice, text: stream)) }
            )
        )
        sheet.toggle()
        sheet.resolve(.replace)
        continuation.yield("## Goal\n\nFix the retry ")
        await sheet.wait { sheet.draft.streamingDraft?.partial.isEmpty == false }

        // The stop button, which is also what Escape reaches in the sheet's footer.
        sheet.stop()
        XCTAssertEqual(sheet.model.task, "## Goal\n\nFix the retry")
        XCTAssertEqual(sheet.draft.draftedKind, .onDevice, "and it stays labelled")
        XCTAssertNil(sheet.draft.failureMessage, "a stop the reviewer asked for is not a failure")

        continuation.finish()
        await sheet.settle()
        XCTAssertEqual(sheet.model.task, "## Goal\n\nFix the retry")
    }

    func testAFailureBeforeTheFirstTokenIsTheOneLineTheFieldShows() async {
        let sheet = BriefSheet(
            model: makeModel(
                runner: ScriptedAgentRunner(),
                brief: drafter { .failed("the endpoint returned 401") }
            )
        )
        let original = sheet.model.task
        sheet.toggle()
        sheet.resolve(.replace)
        await sheet.settle()

        XCTAssertEqual(sheet.model.task, original, "the field is left exactly as it was")
        XCTAssertEqual(sheet.draft.failureMessage, "the endpoint returned 401")
        XCTAssertNil(sheet.draft.labelledKind)
    }

    func testTheRunCommandIsBuiltFromTheFieldsTextAndNothingTheDraftDid() async throws {
        let runner = ScriptedAgentRunner(events: [.assistantText("done")], exitCode: 0)
        let sheet = BriefSheet(
            model: makeModel(
                runner: runner,
                brief: drafter {
                    .stream(
                        IntelligenceStream(
                            kind: .onDevice,
                            text: briefScript(["## Goal\n\nFix the retry bound."])
                        )
                    )
                }
            )
        )
        sheet.toggle()
        sheet.resolve(.replace)
        await sheet.settle()
        XCTAssertEqual(runner.prompts, [], "a draft does not run anything")

        // The reviewer edits the brief, which is the whole point of it landing in a field.
        sheet.type("## Goal\n\nFix the retry bound, keep it to one file.")

        sheet.model.start()
        await sheet.model.runTask?.value

        let prompt = try XCTUnwrap(runner.prompts.first)
        XCTAssertEqual(
            prompt,
            DelegationPrompt.full(for: sheet.model.context, task: sheet.model.task),
            "the prompt is the preamble plus the field, and nothing else"
        )
        XCTAssertTrue(prompt.hasSuffix("keep it to one file."))
        XCTAssertEqual(runner.prompts.count, 1)
    }

    // MARK: - Unattended delegations keep their template (ADR 0016)

    func testARuleStartedDelegationHasNoDrafterAndCannotDraft() async {
        // The shape `DelegationCenter.startAutomatically` builds: marked automatic, and with no
        // brief argument to pass, because that entry point has no such parameter.
        let model = makeModel(runner: ScriptedAgentRunner(), isAutomatic: true, brief: nil)
        XCTAssertNil(model.brief)
        XCTAssertFalse(model.canDraftBrief, "no ✨ button on a run nobody pressed a button for")
        let outcome = await model.streamBrief()
        XCTAssertEqual(outcome.failure, .disabled, "and nothing to ask even if something asked")
    }

    func testTheRulesInputsAndOutputsCarryNoDraftedText() {
        let rules = AutoDelegationRules(
            isEnabled: true,
            triggers: [.checksFailed],
            maxConcurrent: 1,
            maxPerDay: 5
        )
        let pullRequest = summary()
        let signal = AutoDelegationSignal(
            trigger: .checksFailed,
            pullRequest: pullRequest,
            isTransition: true
        )
        let decision = AutoDelegationPolicy.decide(
            signal,
            context: AutoDelegationContext(
                rules: rules,
                isConfigured: true,
                hasRunningDelegation: false,
                runningAutomaticCount: 0,
                ledger: AutoDelegationLedger(),
                now: Date(timeIntervalSince1970: 1_788_162_000),
                timeZone: TimeZone(identifier: "Europe/Berlin") ?? .gmt
            )
        )
        guard let plan = decision.plan else { return XCTFail("the rule should have fired") }
        // The task is the rendered template, character for character: the rules engine has no
        // input a generated brief could enter through, and this is what says so.
        XCTAssertEqual(
            plan.task,
            AutoDelegationPrompt.render(template: rules.promptTemplate, signal: signal)
        )
        XCTAssertFalse(plan.task.contains(AgentBrief.goalHeading))
        XCTAssertFalse(plan.task.contains(AgentBrief.constraintsHeading))
        XCTAssertFalse(plan.task.contains(AgentBrief.acceptanceHeading))
    }

    // MARK: - Helpers

    private var enabledConfiguration: IntelligenceConfiguration {
        IntelligenceConfiguration(
            mode: .onDeviceAndCloud,
            cloudKind: .anthropic,
            cloudAPIKey: "not-a-real-key"
        )
    }

    /// A router whose tiers both stream a brief naming themselves, cloud rung first.
    private func briefRouter() -> IntelligenceRouter {
        IntelligenceRouter(
            configuration: enabledConfiguration,
            tiers: IntelligenceTiers(
                cloud: { _ in BriefStubTier(kind: .anthropic) },
                onDevice: { BriefStubTier(kind: .onDevice) },
                onDeviceUnavailabilityReason: { nil },
                briefStream: { provider, _ in briefScript(["\(provider.kind.rawValue) brief"]) }
            )
        )
    }

    /// A drafter whose one closure answers with a scripted outcome.
    private func drafter(
        canDraft: Bool = true,
        _ outcome: @escaping @Sendable () async -> IntelligenceStreamOutcome
    ) -> AgentBriefDrafter {
        AgentBriefDrafter(canDraft: canDraft) { _ in await outcome() }
    }

    private func makeModel(
        runner: any AgentRunning,
        isAutomatic: Bool = false,
        brief: AgentBriefDrafter? = nil
    ) -> DelegationModel {
        let repo = RepoRef(owner: "schnaq", name: "review")
        return DelegationModel(
            context: findingContext(comments: ["Fix the retry bound."]),
            configuration: AgentCLIConfiguration(),
            readiness: .ready,
            runner: runner,
            worktree: GitWorktree(
                checkout: URL(fileURLWithPath: "/Users/dev/code/review"),
                directory: GitWorktree.directory(repo: repo, number: 42, root: root),
                managedRoot: root,
                git: URL(fileURLWithPath: "/usr/bin/git"),
                runner: RecordingProcessRunner()
            ),
            isAutomatic: isAutomatic,
            toasts: nil,
            brief: brief
        )
    }

    /// Drains a stream into the elements a field would have been written with.
    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var elements: [String] = []
        for try await element in stream { elements.append(element) }
        return elements
    }
}

/// The delegation sheet's task field, as the sheet wires it up.
///
/// Deliberately the same sequence ``DelegationSheet`` runs — button, task, ``AIDraftFieldState``,
/// field — without a window, so the paths that only happen *from outside* (a stop while text is
/// arriving, a keystroke that has to end the request) are testable as they actually happen. The
/// field is the model's own ``DelegationModel/task``, which is what makes the assertion about the
/// Run button an assertion about the real thing.
@MainActor
private final class BriefSheet {
    /// The delegation whose task field this is.
    let model: DelegationModel
    /// The field's drafting state.
    private(set) var draft = AIDraftFieldState()
    /// Every value written into the field by a draft, in order.
    private(set) var writes: [String] = []

    private var task: Task<Void, Never>?
    private var lastTask: Task<Void, Never>?

    init(model: DelegationModel) {
        self.model = model
    }

    /// The ✨ button, and ⇧⌘D.
    func toggle() {
        guard !draft.isDrafting else { return stop() }
        switch draft.prepareStream(existingText: model.task) {
        case .askFirst:
            break
        case .ready(let base):
            start(base: base)
        }
    }

    /// The reviewer's answer to the replace-or-append question.
    func resolve(_ choice: AIDraftFieldState.Choice) {
        switch draft.resolve(choice, existingText: model.task) {
        case .write(let text):
            write(text)
        case .startStream(let base):
            start(base: base)
        case .nothing:
            break
        }
    }

    /// The stop button, or Escape.
    func stop() {
        task?.cancel()
        task = nil
        draft.cancelDrafting()
        write(draft.cancelStream())
    }

    /// The reviewer typing into the field.
    func type(_ typed: String) {
        model.task = typed
        let wasStreaming = draft.streamingDraft != nil
        draft.fieldChanged(to: typed)
        if wasStreaming, draft.streamingDraft == nil {
            task?.cancel()
            task = nil
        }
    }

    /// Waits for the last draft task to finish, so an assertion is about a settled field.
    func settle() async {
        guard let lastTask else { return }
        await lastTask.value
    }

    /// Waits until the field satisfies `condition`, or lets the following assertion say so.
    func wait(until condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func start(base: String) {
        let started = Task { await self.run(base: base) }
        task = started
        lastTask = started
    }

    private func run(base: String) async {
        let outcome = await model.streamBrief()
        guard !Task.isCancelled else { return }
        guard let stream = outcome.stream else {
            write(draft.finish(outcome.failure ?? .disabled, existingText: model.task))
            return
        }
        draft.streamStarted(kind: stream.kind, base: base)
        do {
            for try await partial in stream.text {
                write(draft.streamed(partial))
            }
            if Task.isCancelled {
                write(draft.cancelStream())
            } else {
                write(draft.finishStream())
            }
        } catch is CancellationError {
            write(draft.cancelStream())
        } catch {
            write(draft.failStream(AIDraftFailure.describe(error)))
        }
    }

    private func write(_ text: String?) {
        guard let text else { return }
        model.task = text
        writes.append(text)
    }
}

/// A scripted brief stream: these cumulative Markdown snapshots, then a clean finish.
/// - Parameters:
///   - chunks: The cumulative briefs to yield, in order.
///   - failure: The error to finish with, or `nil` for a clean end.
/// - Returns: The stream.
private func briefScript(
    _ chunks: [String],
    failure: IntelligenceError? = nil
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        if let failure {
            continuation.finish(throwing: failure)
        } else {
            continuation.finish()
        }
    }
}

/// A tier that answers nothing on its own: the tests script the stream instead.
///
/// It deliberately does **not** implement `streamAgentBrief`, so the tests that do not script the
/// closure exercise the protocol's declining default.
private struct BriefStubTier: IntelligenceProvider {
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
