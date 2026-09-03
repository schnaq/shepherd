import Foundation
import GitHubKit
import ShepherdCore

/// Something that can run a tool call a model produced.
///
/// The seam between "a model asked for a read" and "the read happened", and the reason the three
/// providers can share one tool loop: each of them parses its own wire shape into an
/// ``ShepherdCore/IntelligenceToolCall``, hands it here, and puts the
/// ``ShepherdCore/IntelligenceToolResult`` back on the wire in its own shape. Nothing about the
/// executor is provider-specific, and nothing about a provider is data-specific.
///
/// `Sendable` because a provider calls it from whatever task the request is on, and `async throws`
/// because the reads behind it are I/O. Throwing is for a failure of the *machinery* — a cancelled
/// task, later a network read that died — never for a call the model got wrong: a refused or
/// impossible call comes back as a result whose text says so, so the model can correct itself and
/// the reviewer sees the hop in the trace. A crash, or an error that ends the turn, would turn a
/// model's typo into a missing card.
protocol IntelligenceToolExecuting: Sendable {
    /// Runs one call.
    /// - Parameter call: The call the provider parsed out of the model's answer, unvalidated.
    /// - Returns: What the model is told, plus the one line the reviewer reads.
    /// - Throws: Only when the read itself could not be attempted.
    func execute(_ call: IntelligenceToolCall) async throws -> IntelligenceToolResult
}

/// Something that can download the log of one CI job.
///
/// The seam between ``LocalToolExecutor``'s `jobLogTail` tool and the network (plan §3.F), and it
/// exists for three reasons that are one reason:
///
/// - **The executor stays testable.** Every other answer the executor gives comes out of a
///   `PullRequestDetail` snapshot; the log is the one that needs a GitHub call, and a test of
///   "does the digest reach the model" must not need a token, a network or a real failing job.
/// - **A missing log is a state, not a failure.** The parameter is optional wherever it is
///   passed, so a caller that has no client — a test, or a screen with no session — produces a
///   tool that answers *there is no log here* rather than one that throws.
/// - **Nothing about the reads is provider-specific.** Like ``IntelligenceToolExecuting``, this
///   is one method with plain values on either side, so the three tiers share it untouched.
///
/// The one production conformance is ``GitHubKit/GitHubClient``, whose
/// `jobLog(repo:jobID:)` this method *is* — the conformance below adds no behaviour, which is
/// deliberate: a seam that transformed the answer on the way through would be a second place for
/// the 2 MB cap and the lossy decode to live.
protocol JobLogFetching: Sendable {
    /// Downloads one job's log.
    /// - Parameters:
    ///   - repo: The repository the job ran in.
    ///   - jobID: The Actions job id, from ``ShepherdCore/CheckRun/actionsJobID``.
    /// - Returns: The log as text.
    /// - Throws: Whatever the read failed with; the tool turns it into one line for the model.
    func jobLog(repo: RepoRef, jobID: Int) async throws -> String
}

/// The live log read: GitHub's own, with nothing in between.
extension GitHubClient: JobLogFetching {}

/// The numbers and the string tests every provider's tool loop shares.
///
/// One place, because a cap that differs between tiers is a cap nobody can reason about: "why is
/// CI red?" costs at most six reads whichever model is answering, and a reviewer comparing the
/// on-device answer with the cloud one is comparing two answers that were allowed to look at the
/// same amount.
enum IntelligenceToolLoop {
    /// The most tools one tool-calling turn may run.
    ///
    /// Six is three tools plus room to re-read: the planned turn is *failing checks → one log →
    /// one file*, and a model that has to look at a second file or re-read a log after a refusal
    /// still fits. What it stops is the loop that does not converge — a model that alternates
    /// between two reads forever, spending the reviewer's battery and, on a cloud tier, their
    /// money. It is a hard stop rather than a nudge in the prompt, because a prompt is a request
    /// and this has to be a guarantee.
    ///
    /// Counted per **attempted** call, on every tier. A call the model got wrong comes back as a
    /// refusal rather than as a step in the typed trace (``ShepherdCore/IntelligenceTrace`` holds
    /// validated calls only), so counting what was *recorded* would leave the one turn that
    /// cannot converge — a model asking over and over for a tool nobody declared — uncapped.
    static let maximumHops = 6

    /// Whether an endpoint's error message is about tool calling.
    ///
    /// The tier-3b endpoints are "whatever speaks the chat-completions shape", and a good part of
    /// that population — Ollama with a model that has no tool head, a small self-hosted gateway —
    /// answers a request carrying `tools` with a plain `400` and a sentence. There is no code to
    /// switch on, so the sentence is what there is: matching two stems catches "tools are not
    /// supported", "unknown parameter: tools", "this model does not support function calling"
    /// without matching a rate limit or an authentication failure, and being wrong here costs a
    /// slightly less accurate error message rather than a wrong answer.
    /// - Parameter message: The endpoint's own message.
    /// - Returns: `true` when it mentions tools or functions.
    static func mentionsTools(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("tool") || lowered.contains("function")
    }
}

/// The three read-only tools, answered from one pull request's local snapshot.
///
/// An `actor` because it owns state a model reaches into concurrently — the framework on the
/// on-device tier may run two tool calls at once — and because the plan's concrete tools are
/// actors that own their data source (§0.3). What it owns here is a *snapshot*: a
/// ``ShepherdCore/PullRequestDetail`` as it was when the reviewer pressed the button, so the
/// answers a diagnosis is built from cannot change underneath it mid-turn and the trace stays a
/// true record of what the model saw.
///
/// Every answer is **budgeted before it exists**. That is the plan's rule that the model never
/// sees a raw log or a raw file, and it is enforced here rather than in the providers, because the
/// tool is the only thing that knows what its own content is worth cutting: a check summary is
/// capped per check, a diff is windowed around the line the model named.
///
/// The content handed to the model is English, like every prompt in this layer: it is input to a
/// model, not text on screen. The one-line summaries beside it are the reviewer's, so those are
/// localised — the split is exactly the split ``ShepherdCore/IntelligenceToolResult`` makes.
actor LocalToolExecutor: IntelligenceToolExecuting {
    /// Fraction of the tier's characters the failing-check list may occupy.
    ///
    /// Small: the list is names, conclusions and one summary line each, and it is the *cheapest*
    /// of the three reads. Spending more of the window on it would come straight out of the diff,
    /// which is where the answer usually is.
    static let checksShare = 0.15
    /// The failing-check list may always use at least this many characters.
    static let minimumChecksCharacters = 800
    /// Each check's own summary text is capped to this many characters.
    ///
    /// A check summary is written by whoever wrote the workflow: usually one line, occasionally a
    /// whole rendered Markdown report. The cap is what keeps one talkative check from crowding
    /// out the other five.
    static let maximumCheckSummaryCharacters = 240
    /// At most this many failing checks are listed.
    static let maximumChecks = 12
    /// Fraction of the tier's characters one diff window may occupy.
    ///
    /// The largest share of the three, because the diff is what a hypothesis is checked against.
    static let diffShare = 0.4
    /// A diff window may always use at least this many characters.
    static let minimumDiffCharacters = 600

    /// The pull request as it was when the turn started.
    private let detail: PullRequestDetail
    /// The one rule validation needs from outside the descriptors: which paths may be read.
    private let registry: IntelligenceToolRegistry
    /// The tier's budget, which every answer is cut to fit.
    private let budget: TokenBudget
    /// How a job log is downloaded, or `nil` when this executor cannot read one.
    private let logFetcher: (any JobLogFetching)?

    /// Creates an executor over one pull request.
    /// - Parameters:
    ///   - detail: The fetched pull request. Held as a snapshot.
    ///   - budget: The answering tier's token budget.
    ///   - jobLog: How to download a job log. `nil` — the default — makes `jobLogTail` answer
    ///     that there is no log rather than fail, which is the honest answer for a caller with no
    ///     signed-in session and the answer every test that is not about logs wants.
    init(
        detail: PullRequestDetail,
        budget: TokenBudget,
        jobLog: (any JobLogFetching)? = nil
    ) {
        self.detail = detail
        self.registry = IntelligenceToolRegistry(changedFiles: detail.files)
        self.budget = budget
        self.logFetcher = jobLog
    }

    /// Runs one call, refusing rather than throwing when the model got it wrong.
    ///
    /// Validation comes first and always: ``ShepherdCore/IntelligenceToolRegistry/validate(_:)``
    /// is where "no free text a model wrote reaches GitHub" is decided, so no tool below is
    /// reachable with a path this pull request does not contain, an argument nobody declared or a
    /// name that is not one of the three. A refusal is a *result* — the model reads why and can
    /// try again inside the hop cap — and never an error, because a model's typo must not be able
    /// to end the turn.
    /// - Parameter call: The unvalidated call.
    /// - Returns: The budgeted answer, or the refusal.
    func execute(_ call: IntelligenceToolCall) async throws -> IntelligenceToolResult {
        do {
            try registry.validate(call)
        } catch let error as IntelligenceToolError {
            return Self.refusal(error, callID: call.id)
        }
        // Unreachable: validation has already established that the name is one of the three. The
        // guard is here so the switch below can be total over the enum rather than over a string.
        guard let name = IntelligenceToolName(rawValue: call.toolName) else {
            return Self.refusal(.unknownTool(call.toolName), callID: call.id)
        }
        switch name {
        case .failingChecks:
            return failingChecks(callID: call.id)
        case .jobLogTail:
            return await jobLogTail(
                checkName: call.arguments[IntelligenceToolName.checkNameArgument]?.stringValue ?? "",
                callID: call.id
            )
        case .fileDiff:
            return fileDiff(
                path: call.arguments[IntelligenceToolName.pathArgument]?.stringValue ?? "",
                line: call.arguments[IntelligenceToolName.lineArgument]?.integerValue,
                callID: call.id
            )
        }
    }

    // MARK: - failingChecks

    /// The red checks on this pull request, from the rows already in the database.
    ///
    /// "Red" is ``ShepherdCore/CheckRun/rollupContribution``, not `conclusion == .failure`: a
    /// cancelled job and one that timed out are what a reviewer is looking at when they ask why
    /// CI is red, and a rollup that counts them and a tool that does not would disagree on
    /// screen.
    /// - Parameter callID: The call being answered.
    private func failingChecks(callID: String) -> IntelligenceToolResult {
        let failing = Self.failingChecks(in: detail)
        let count = failing.count
        guard count > 0 else {
            return IntelligenceToolResult(
                callID: callID,
                content: "No check on this pull request is failing.",
                summaryLine: String(localized: "\(count) checks failing")
            )
        }
        let limit = max(
            Self.minimumChecksCharacters,
            Int(Double(budget.maxCharacters) * Self.checksShare)
        )
        var lines: [String] = []
        var used = 0
        var truncated = failing.count > Self.maximumChecks
        for check in failing.prefix(Self.maximumChecks) {
            var line = "- \(check.name) — \(check.conclusion?.rawValue ?? "no conclusion")"
            if let summary = check.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                let capped = summary.count > Self.maximumCheckSummaryCharacters
                    ? String(summary.prefix(Self.maximumCheckSummaryCharacters)) + "…"
                    : summary
                // Newlines out: the list is one line per check, and a check that pasted a
                // rendered report into its summary must not be able to reshape the prompt.
                line += "\n  summary: " + capped.replacingOccurrences(of: "\n", with: " ")
            }
            if used + line.count > limit, !lines.isEmpty {
                truncated = true
                break
            }
            used += line.count
            lines.append(line)
        }
        return IntelligenceToolResult(
            callID: callID,
            content: "Failing checks on this pull request:\n" + lines.joined(separator: "\n"),
            summaryLine: String(localized: "\(count) checks failing"),
            wasTruncated: truncated
        )
    }

    // MARK: - jobLogTail

    /// The failing region of one check's job log (plan §3.F).
    ///
    /// Three steps, and each of them can end the tool honestly rather than emptily: the check has
    /// to be one of the red ones the model was told about, it has to be a GitHub Actions job (so
    /// that ``ShepherdCore/CheckRun/actionsJobID`` finds an id in its `detailsURL`), and the
    /// download has to work. Every one of those failures answers *there is no log — work from the
    /// check's own summary and the diff*, **and says which of the three it was**, because the
    /// three call for different next moves from a model: a Buildkite check will never have a log,
    /// while a fetch that failed once might work on the next hop.
    ///
    /// What comes back on success is never the log. ``ShepherdCore/LogDigest`` reduces it to the
    /// failing region first — that is the tier-1 pre-digestion ADR 0007 requires, and on the
    /// on-device tier it is the difference between a megabyte of `xcodebuild` output and the
    /// ~1,200 tokens the model can actually be given. The digest is cut to *this executor's*
    /// budget, so the cloud rung a reviewer explicitly asked for genuinely sees more of the log
    /// than the on-device tier did rather than the same digest through a bigger window.
    ///
    /// The content is English, like every prompt in this layer; the summary line beside it is the
    /// reviewer's and says what the reduction cost.
    /// - Parameters:
    ///   - checkName: The check the model named.
    ///   - callID: The call being answered.
    private func jobLogTail(checkName: String, callID: String) async -> IntelligenceToolResult {
        guard let check = Self.failingChecks(in: detail).first(where: { $0.name == checkName })
        else {
            return IntelligenceToolResult(
                callID: callID,
                content: """
                    There is no failing check called "\(checkName)" on this pull request. Call \
                    failingChecks to see the names.
                    """,
                summaryLine: String(localized: "no check called \(checkName) on this pull request")
            )
        }
        guard let fetcher = logFetcher else {
            return Self.noLog(
                callID: callID,
                content: """
                    Shepherd cannot read logs in this context, so there is no log for \
                    "\(checkName)". Answer from the check's own summary text and from the diff.
                    """,
                summaryLine: String(localized: "no log available for this check")
            )
        }
        guard let jobID = check.actionsJobID else {
            return Self.noLog(
                callID: callID,
                content: """
                    "\(checkName)" is not a GitHub Actions job, so it has no log Shepherd can \
                    read. Answer from the check's own summary text and from the diff.
                    """,
                summaryLine: String(localized: "\(checkName) is not a GitHub Actions job")
            )
        }

        let log: String
        do {
            log = try await fetcher.jobLog(repo: detail.repo, jobID: jobID)
        } catch {
            // The reason travels to the model in English and to the reviewer as one line. It is a
            // *result*, not a throw, for this file's own rule: a read that failed must not be
            // able to end a turn that could still answer from the summary and the diff.
            return Self.noLog(
                callID: callID,
                content: """
                    The log of "\(checkName)" could not be read: \
                    \(AIDraftFailure.describe(error)) Answer from the check's own summary text \
                    and from the diff.
                    """,
                summaryLine: String(localized: "the log of \(checkName) could not be read")
            )
        }

        let digest = LogDigest.reduce(log, budget: budget)
        guard !digest.isEmpty else {
            return Self.noLog(
                callID: callID,
                content: """
                    The log of "\(checkName)" is empty. Answer from the check's own summary text \
                    and from the diff.
                    """,
                summaryLine: String(localized: "the log of \(checkName) is empty")
            )
        }
        let count = digest.lineCount
        let total = digest.totalLines
        return IntelligenceToolResult(
            callID: callID,
            content: """
                Log of \(checkName), reduced to the failing lines and their context \
                (\(count) of \(total) lines):
                \(digest.text)
                """,
            summaryLine: String(localized: "last \(count) of \(total) lines of \(checkName)"),
            wasTruncated: digest.wasTruncated
        )
    }

    /// The answer for a check whose log cannot be read, in the model's words and the reviewer's.
    ///
    /// One helper because there are four ways to have no log and they must be indistinguishable
    /// in *shape*: never truncated, never an error, always naming what to do instead.
    /// - Parameters:
    ///   - callID: The call being answered.
    ///   - content: What the model is told, in English.
    ///   - summaryLine: The one line the reviewer reads in the trace.
    private static func noLog(
        callID: String,
        content: String,
        summaryLine: String
    ) -> IntelligenceToolResult {
        IntelligenceToolResult(
            callID: callID,
            content: content,
            summaryLine: summaryLine,
            wasTruncated: false
        )
    }

    // MARK: - fileDiff

    /// A window into one changed file's diff.
    /// - Parameters:
    ///   - path: The path, already known to be one of this pull request's changed files.
    ///   - line: The head-side line to centre on, when the model named one.
    ///   - callID: The call being answered.
    private func fileDiff(path: String, line: Int?, callID: String) -> IntelligenceToolResult {
        let file = detail.files.first { $0.path == path || $0.previousPath == path }
        let window = IntelligenceDiffWindow.window(
            patch: file?.patch ?? "",
            aroundLine: line,
            characterLimit: max(
                Self.minimumDiffCharacters,
                Int(Double(budget.maxCharacters) * Self.diffShare)
            )
        )
        guard !window.isEmpty else {
            return IntelligenceToolResult(
                callID: callID,
                content: """
                    GitHub sent no diff for \(path) — it is a binary file, or the diff was too \
                    large to include.
                    """,
                summaryLine: String(localized: "GitHub sent no diff for this file")
            )
        }
        let count = window.lineCount
        return IntelligenceToolResult(
            callID: callID,
            content: "Diff of \(path):\n" + window.text,
            summaryLine: String(localized: "\(count) diff lines"),
            wasTruncated: window.wasTruncated
        )
    }

    // MARK: - Shared

    /// The checks a reviewer would call red, in the order GitHub reported them.
    ///
    /// `static` and `internal` because the router asks the same question before it picks a tier:
    /// a pull request with nothing failing has nothing to diagnose, and finding that out should
    /// not cost a model session.
    /// - Parameter detail: The fetched pull request.
    /// - Returns: The failing check runs.
    static func failingChecks(in detail: PullRequestDetail) -> [CheckRun] {
        detail.checks.filter { $0.rollupContribution == .failure }
    }

    /// Turns a refused call into the result the model and the reviewer each see.
    ///
    /// The model gets the precise reason in English, because it is the only thing that can act on
    /// it — "that path is not in this pull request" is what makes the next call right. The
    /// reviewer gets one short line, and the only refusal spelled out for them is the one with
    /// product meaning: a path the model invented is the guardrail the plan names, and seeing it
    /// in the trace is seeing the guardrail work. The rest read as "refused" next to the
    /// arguments the trace already renders.
    /// - Parameters:
    ///   - error: Why the call was refused.
    ///   - callID: The call being answered.
    /// - Returns: A result carrying the refusal.
    private static func refusal(
        _ error: IntelligenceToolError,
        callID: String
    ) -> IntelligenceToolResult {
        let content: String
        var summaryLine = String(localized: "the tool call was refused")
        switch error {
        case let .unknownTool(name):
            content = """
                There is no tool called "\(name)". The tools you may call are failingChecks, \
                jobLogTail and fileDiff.
                """
        case let .missingArgument(tool, argument):
            content = "\(tool.rawValue) needs the argument \"\(argument)\"."
        case let .wrongArgumentType(tool, argument, expected):
            content = """
                The argument "\(argument)" of \(tool.rawValue) must be of type \
                \(expected.jsonSchemaType).
                """
        case let .unexpectedArgument(tool, argument):
            content = "\(tool.rawValue) does not take an argument called \"\(argument)\"."
        case let .pathNotInChangedFiles(path):
            content = """
                "\(path)" is not one of the files this pull request changed, and only those can \
                be read. Call failingChecks or use a path from the list in the prompt.
                """
            summaryLine = String(
                localized: "\(path) is not one of this pull request's changed files"
            )
        }
        return IntelligenceToolResult(
            callID: callID,
            content: content,
            summaryLine: summaryLine,
            wasTruncated: false
        )
    }
}
