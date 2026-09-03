import Foundation
import Observation
import ShepherdCore

/// What the "why is CI red?" card is showing (plan §3.F).
///
/// Four states and no `idle`: *no state at all* is what the absence of a card means, and
/// modelling that as a case would make the checks list unwrap the same nothing twice — the same
/// reasoning ``ThreadDigestState`` gives. `.disabled` is not a case either: with intelligence
/// switched off the **button** is not drawn, so there is nothing to say.
enum CIDiagnosisState: Sendable, Equatable {
    /// A tier is reading. The check the reviewer asked about is carried so the card can name it.
    ///
    /// There is no partial trace in here on purpose. A tool loop reports its hops when the turn
    /// ends — the framework drives the calls on the on-device tier, and the two cloud shapes are
    /// transcripts — so a card that promised a live step list would be promising something the
    /// providers cannot deliver without being restructured around the UI. It shows a spinner and
    /// then the whole trace, which is the honest version of the same thing.
    case asking(checkName: String)
    /// A tier answered: the diagnosis, its hops, and which tier it was.
    case diagnosed(kind: IntelligenceKind, run: IntelligenceToolRun<CIDiagnosis>)
    /// The on-device tier refused because the content did not fit.
    ///
    /// The one failure with a way out, and ``canAskCloud`` is whether that way exists on this Mac:
    /// with a key configured the card offers *"ask <provider> with the full log?"*, and without
    /// one it says the log did not fit and stops there. A button that could only fail would be
    /// worse than a sentence.
    case tooLargeForDevice(message: String, canAskCloud: Bool)
    /// Nothing answered, in the tier's own words.
    case failed(String)
}

/// Spends the tool-calling run behind the **Why?** button on a red check (plan §3.F).
///
/// One of these lives per review screen, and it holds the card's whole state. Five things about
/// it are decisions rather than mechanics:
///
/// - **It takes the router and the log reader per call, not in its initialiser.** The router is a
///   value snapshot that a settings change replaces, and the log reader belongs to the signed-in
///   session; capturing either at the moment the screen was built is how a card ends up asking a
///   tier the user switched off ten minutes ago. So the caller passes what is current, and this
///   type can be created — in a test, or on a screen with nothing red — with no arguments at all.
/// - **One run at a time, and asking again replaces it.** A second click, or the cloud rung, cancels
///   the run in flight: two model sessions for one question would spend a reviewer's battery (or
///   their money) on an answer only one of which is going to be shown.
/// - **The cloud rung is a separate click, and it is offered once.** ``CIDiagnosisState/tooLargeForDevice(message:canAskCloud:)``
///   is the only state with a button in it, `preferCloud` is only ever `true` because the reviewer
///   pressed that button, and a cloud attempt that fails reports its failure rather than offering
///   itself again (``CIDiagnosisAttempt/didExceedBudget``).
/// - **Nothing is persisted.** No `UserDefaults`, no GRDB table, no field in the synced settings
///   document: a diagnosis is a reading aid that holds a log tail, and it lives exactly as long
///   as the reviewer is looking at it (ADR 0024, and ADR 0020's reasoning about held prose).
/// - **Nothing here acts.** The only things it produces are a card and — on a further click — a
///   ``DelegationContext`` whose Run button is still the reviewer's (ADR 0011's amendment). There
///   is no path from a diagnosis to a comment, to the outbox, to a re-run of CI or to a started
///   agent.
@MainActor
@Observable
final class CIDiagnosisModel {
    /// What the card is showing, or `nil` when there is no card.
    private(set) var state: CIDiagnosisState?
    /// The check the reviewer asked about, for as long as an answer about it is on screen.
    ///
    /// The diagnosis itself names a *test* and a *file*; the check is what the reviewer clicked,
    /// and it is what a brief falls back to naming when the log named no test at all.
    private(set) var checkName: String?

    /// The run in flight, so a second question can cancel the first.
    ///
    /// Not observed: what a view draws is the state the run produces, and a card that re-rendered
    /// because a task handle was stored would be re-rendering on bookkeeping.
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Creates an empty model. No model session exists until the reviewer clicks.
    init() {}

    /// Whether a tier is reading right now.
    var isAsking: Bool {
        guard let state, case .asking = state else { return false }
        return true
    }

    /// The diagnosis on screen, when a tier answered.
    var diagnosis: CIDiagnosis? {
        guard let state, case .diagnosed(_, let run) = state else { return nil }
        return run.value
    }

    /// Asks a tier why CI is red, and shows what it answers.
    ///
    /// Awaits the run, so a caller — a button's task, or a test — can act on the state that comes
    /// out of it rather than polling for one.
    /// - Parameters:
    ///   - check: The red check the reviewer clicked. Names the card and, failing everything
    ///     else, the brief.
    ///   - detail: The fetched pull request; the tools answer from this snapshot.
    ///   - summary: The inbox row the reviewer opened.
    ///   - router: The tier ladder, read at click time.
    ///   - jobLog: How a job log is downloaded — the signed-in session's client, or `nil` on a
    ///     screen that has none, in which case the log tool says so.
    ///   - preferCloud: `true` only when the reviewer pressed the cloud button.
    func diagnose(
        check: CheckRun,
        detail: PullRequestDetail,
        summary: PullRequestSummary,
        router: IntelligenceRouter,
        jobLog: (any JobLogFetching)?,
        preferCloud: Bool = false
    ) async {
        task?.cancel()
        checkName = check.name
        state = .asking(checkName: check.name)
        // `hasCloudTier` is read here rather than after the answer, because it is a property of
        // the settings the reviewer asked *with*: a key added while a run was in flight must not
        // turn into an offer about a run that never considered it.
        let canAskCloud = router.hasCloudTier && !preferCloud
        let task = Task { [weak self] in
            let attempt = await router.attemptDiagnosis(
                for: detail,
                summary: summary,
                preferCloud: preferCloud,
                jobLog: jobLog
            )
            guard !Task.isCancelled else { return }
            self?.finish(attempt, canAskCloud: canAskCloud)
        }
        self.task = task
        await task.value
    }

    /// Closes the card and stops any run behind it.
    ///
    /// The reviewer pressed the close button, or the checks list moved on. A spinner nobody is
    /// filling any more is a lie, and the question can be asked again.
    func dismiss() {
        task?.cancel()
        task = nil
        state = nil
        checkName = nil
    }

    /// Records what a tier answered.
    /// - Parameters:
    ///   - attempt: What the ladder produced.
    ///   - canAskCloud: Whether a cloud rung exists that has not been asked yet.
    private func finish(_ attempt: CIDiagnosisAttempt, canAskCloud: Bool) {
        switch attempt.outcome {
        case .value(let output):
            state = .diagnosed(kind: output.kind, run: output.value)
        case .disabled:
            // Unreachable from the UI — the button is not drawn with intelligence off — and a
            // card saying nothing would be the wrong way to find that out, so the card closes.
            state = nil
        case .unavailable(let reason):
            state = .failed(reason)
        case .failed(let reason):
            state = attempt.didExceedBudget
                ? .tooLargeForDevice(message: reason, canAskCloud: canAskCloud)
                : .failed(reason)
        }
    }

    // MARK: - Handing it to feature E

    /// The delegation context for *Draft an agent brief*, when there is a diagnosis to hand over.
    /// - Parameters:
    ///   - summary: The pull request the card belongs to.
    ///   - focusReasons: The prioritiser's reasons, as the delegation sheet already takes them.
    /// - Returns: The context, or `nil` when no diagnosis is on screen.
    func briefContext(
        summary: PullRequestSummary,
        focusReasons: [String] = []
    ) -> DelegationContext? {
        guard let state, case .diagnosed(_, let run) = state else { return nil }
        return Self.briefContext(
            diagnosis: run.value,
            checkName: checkName,
            summary: summary,
            focusReasons: focusReasons
        )
    }

    /// Builds the context a diagnosis hands to the delegation sheet (plan §3.E/§3.F).
    ///
    /// `static` and pure, so what the agent is told can be asserted without a window, a model or
    /// a session. Three decisions in it:
    ///
    /// - **The origin is the finding when the log named a file.** A brief for
    ///   ``DelegationContext/Origin/reviewFinding(path:line:)`` starts *"Review finding in
    ///   Sources/Upload.swift, line 12"*, which is the difference between an agent that opens the
    ///   right file and one that reads the whole pull request first. The file is used whether or
    ///   not the pull request changed it: CI fails in files a change did not touch, and that is
    ///   exactly the case a brief is most useful for.
    /// - **The finding comment is one line, and it is Shepherd's own.** *"CI: <test> — <hypothesis>"*
    ///   — the failing test's name where the log named one, the check's name where it did not.
    ///   ``DelegationContext/findingCommentAuthors`` is deliberately left empty: it exists so that
    ///   a brief quoting a *colleague's* comment is refused the cloud rung (ADR 0011's amendment),
    ///   and this sentence was written by Shepherd from a model's answer, not by a third party.
    /// - **Nothing else travels.** No log, no trace, no confidence: the brief drafter is given a
    ///   finding to work from, and the log tail stays in the card where the reviewer can see it.
    /// - Parameters:
    ///   - diagnosis: What the model answered.
    ///   - checkName: The check the reviewer asked about, when it is known.
    ///   - summary: The pull request.
    ///   - focusReasons: The prioritiser's reasons.
    /// - Returns: The context to open the delegation sheet with.
    static func briefContext(
        diagnosis: CIDiagnosis,
        checkName: String?,
        summary: PullRequestSummary,
        focusReasons: [String] = []
    ) -> DelegationContext {
        let subject = diagnosis.failingTest
            ?? checkName
            ?? String(localized: "the failing check")
        let origin: DelegationContext.Origin
        if let file = diagnosis.file {
            origin = .reviewFinding(path: file, line: diagnosis.line)
        } else {
            origin = .pullRequest
        }
        return DelegationContext(
            prID: summary.id,
            repo: summary.repo,
            number: summary.number,
            title: summary.title,
            headRefName: summary.headRefName,
            headRefOid: summary.headRefOid,
            origin: origin,
            focusReasons: focusReasons,
            findingComments: [String(localized: "CI: \(subject) — \(diagnosis.hypothesis)")]
        )
    }
}
