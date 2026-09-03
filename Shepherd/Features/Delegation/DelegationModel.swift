import AppKit
import Foundation
import Observation
import ShepherdCore

/// How a delegation ended, flattened to values.
///
/// Announced exactly once per run, when ``DelegationModel`` reaches a terminal state — which is
/// the delegation counterpart to "the outbox actually sent it": the point at which something
/// really happened rather than was merely started. ``WebhookCoordinator`` is the only consumer
/// so far (ADR 0012).
///
/// It carries no agent output. ``message`` is Shepherd's own reason (a git failure) or the
/// CLI's machine-readable result subtype (`error_max_turns`), never anything the model wrote.
struct DelegationOutcome: Sendable, Equatable {
    /// The three ways a run can end.
    enum Status: String, Sendable, Equatable, CaseIterable {
        /// The agent ran to completion without reporting an error.
        case finished
        /// The agent reported an error, or Shepherd could not run it at all.
        case failed
        /// The user stopped it.
        case cancelled
    }

    /// The pull request's node id.
    var prID: String
    /// The repository.
    var repo: RepoRef
    /// The pull request number.
    var number: Int
    /// How it ended.
    var status: Status
    /// The agent CLI's display name.
    var agent: String
    /// How long the run took, in whole seconds.
    var durationSeconds: Int
    /// How many files the agent left changed in the worktree.
    var changedFileCount: Int
    /// A short machine-readable reason, when there is one.
    var message: String?
    /// Whether a rule started this run rather than the user (ADR 0016).
    ///
    /// Defaults to `false`: a delegation is the user's unless something says otherwise.
    var wasAutomatic: Bool = false
    /// When the run ended.
    var at: Date
}

/// Drives one delegation: prepare a worktree, run the agent, show what it did, let the user
/// decide what happens to the result.
///
/// The model owns no `Process` and no `git`: it talks to ``AgentRunning`` and ``GitWorktree``,
/// both of which are injected, which is what makes the whole state machine unit-testable.
/// Nothing is pushed without an explicit press (ADR 0011).
@MainActor
@Observable
final class DelegationModel: Identifiable {
    /// Where a delegation is in its life.
    enum State: Equatable {
        /// Not started yet, or reset after the worktree was discarded.
        case idle
        /// Fetching and adding the worktree.
        case preparingWorktree
        /// The agent is running; the transcript is in ``transcript``.
        case running
        /// The agent finished — successfully or not; ``AgentRunResult/isError`` says which.
        case finished(result: AgentRunResult, diffStat: String)
        /// Shepherd could not run the agent at all.
        case failed(message: String)
        /// The user stopped the run.
        case cancelled
    }

    /// Whether this delegation can start at all.
    enum Readiness: Equatable {
        /// Everything is configured.
        case ready
        /// The repository has no local clone in settings.
        case missingCheckout(repo: String)
        /// The agent CLI was not found on this machine.
        case missingCLI
    }

    /// One line of the transcript.
    struct TranscriptEntry: Identifiable, Equatable, Sendable {
        /// What kind of line this is.
        enum Kind: Equatable, Sendable {
            /// Shepherd's own note (start, model, exit).
            case note
            /// Text the agent wrote.
            case assistant
            /// A tool the agent invoked.
            case tool
        }

        /// Identity for `ForEach`.
        let id = UUID()
        /// The kind.
        var kind: Kind
        /// The text.
        var text: String
    }

    /// What the delegation is about.
    let context: DelegationContext
    /// Whether the delegation can run, and why not when it cannot.
    let readiness: Readiness
    /// The agent CLI's display name, for the header chip.
    let agentName: String
    /// The guardrails, shown above the Start button.
    let configuration: AgentCLIConfiguration
    /// Whether a rule started this delegation rather than the user (ADR 0016).
    ///
    /// Only ever set at construction: what started a run is a fact about it, and re-running it
    /// from the sheet does not turn an automatic delegation into a manual one — the badge keeps
    /// saying where it came from.
    let isAutomatic: Bool

    /// How the sheet's ✨ button drafts the task text, or `nil` when nothing can (plan §3.E).
    ///
    /// `nil` for a rule-started run, by construction rather than by check:
    /// ``DelegationCenter/startAutomatically(context:task:settings:toasts:onDidPush:onDidFinish:)``
    /// has no parameter to pass one, so an unattended delegation keeps its fixed template and can
    /// never receive generated text (ADR 0016, ADR 0011's amendment).
    let brief: AgentBriefDrafter?

    /// The editable task text. Shepherd's preamble is prepended when the run starts.
    var task: String
    /// The state machine.
    private(set) var state: State = .idle
    /// The transcript, oldest first.
    private(set) var transcript: [TranscriptEntry] = []
    /// How long the current run has been going, in seconds.
    private(set) var elapsed: TimeInterval = 0
    /// What `git status --porcelain` said after the run.
    private(set) var worktreeStatus: GitWorktree.Snapshot?
    /// Whether a commit-and-push is in flight.
    private(set) var isPublishing = false
    /// Whether the worktree has been pushed already, so the button can say so.
    private(set) var hasPushed = false

    /// The worktree, when a checkout is configured.
    let worktree: GitWorktree?

    private let runner: any AgentRunning
    private let toasts: ToastCenter?
    private let onDidPush: (@MainActor () async -> Void)?
    private let onDidFinish: (@MainActor (DelegationOutcome) -> Void)?

    /// The run task, so tests (and `deinit`-time cleanup) can await it.
    private(set) var runTask: Task<Void, Never>?
    /// The publish/discard task, for the same reason.
    private(set) var actionTask: Task<Void, Never>?

    private var timerTask: Task<Void, Never>?
    private var session: AgentSession?
    private var lastResult: AgentRunResult?
    private var didCancel = false
    private var startedAt: Date?
    /// Guards ``onDidFinish`` against firing twice for one run: `cancel()` during the worktree
    /// step and the run task's own unwinding can both land on the same terminal state.
    private var didAnnounceOutcome = false

    /// One sheet per pull request.
    nonisolated var id: String { context.id }

    /// Creates a delegation.
    /// - Parameters:
    ///   - context: What the delegation is about.
    ///   - configuration: The guardrails, shown in the sheet.
    ///   - readiness: Whether it can run at all.
    ///   - runner: The agent CLI seam.
    ///   - worktree: The worktree seam; `nil` when no checkout is configured.
    ///   - isAutomatic: Whether a rule started this delegation (ADR 0016).
    ///   - toasts: Where failures are surfaced.
    ///   - onDidPush: Called after a successful push, so the app can re-sync the pull request.
    ///   - onDidFinish: Called once when the run reaches a terminal state (ADR 0012).
    ///   - brief: How the ✨ button drafts the task text (plan §3.E). Left out — and therefore
    ///     `nil` — for every run a rule started.
    init(
        context: DelegationContext,
        configuration: AgentCLIConfiguration,
        readiness: Readiness,
        runner: any AgentRunning,
        worktree: GitWorktree?,
        isAutomatic: Bool = false,
        toasts: ToastCenter? = nil,
        onDidPush: (@MainActor () async -> Void)? = nil,
        onDidFinish: (@MainActor (DelegationOutcome) -> Void)? = nil,
        brief: AgentBriefDrafter? = nil
    ) {
        self.context = context
        self.configuration = configuration
        self.readiness = readiness
        self.agentName = configuration.kind.displayName
        self.runner = runner
        self.worktree = worktree
        self.isAutomatic = isAutomatic
        self.toasts = toasts
        self.onDidPush = onDidPush
        self.onDidFinish = onDidFinish
        self.brief = brief
        self.task = DelegationPrompt.defaultTask(for: context)
    }

    // MARK: - Derived state

    /// Whether something is running that must not be started twice.
    var isBusy: Bool {
        switch state {
        case .preparingWorktree, .running: return true
        case .idle, .finished, .failed, .cancelled: return isPublishing
        }
    }

    /// Whether the Start button does anything.
    var canStart: Bool {
        guard readiness == .ready, worktree != nil, !isBusy else { return false }
        return !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the sheet offers the ✨ button next to the task field (plan §3.E).
    ///
    /// Three conditions, all of them known before the click: a drafter exists (so this is not a
    /// rule-started run), a tier could answer, and nothing is running. The last one is what keeps
    /// the button from writing into a field that is disabled because an agent is already working
    /// from the text that is in it.
    var canDraftBrief: Bool {
        guard let brief, brief.canDraft else { return false }
        return !isBusy
    }

    /// Whether the finished run left anything to commit.
    var hasChanges: Bool { worktreeStatus?.isDirty ?? false }

    /// `1 m 12 s`, for the running header.
    var elapsedText: String { RelativeDate.duration(elapsed) }

    /// A one-line summary of the guardrails in force.
    var guardrailSummary: String {
        var parts = [
            configuration.permissionMode.title,
            String(localized: "\(configuration.maxTurns) turns max"),
        ]
        if let budget = configuration.maxBudgetUSD {
            parts.append(String(localized: "$\(AgentCLIConfiguration.format(budget: budget)) max"))
        } else {
            parts.append(String(localized: "no spend cap"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Drafting the task (plan §3.E)

    /// Asks the intelligence layer for a brief, streamed (plan §3.E).
    ///
    /// Returns the outcome instead of writing anywhere: the field belongs to the sheet, and what
    /// happens to a draft that arrives over text the reviewer already wrote is
    /// ``AIDraftFieldState``'s decision. Nothing about this call starts an agent — it does not
    /// touch ``state``, ``task`` or ``canStart``, and ``start()`` still reads whatever text is in
    /// the field at the moment the reviewer presses the button.
    /// - Returns: A labelled stream, or why there is none.
    func streamBrief() async -> IntelligenceStreamOutcome {
        guard let brief else { return .disabled }
        return await brief.stream(context)
    }

    // MARK: - Running

    /// Prepares the worktree and starts the agent.
    func start() {
        guard canStart, let worktree else { return }
        didCancel = false
        didAnnounceOutcome = false
        lastResult = nil
        worktreeStatus = nil
        hasPushed = false
        transcript = []
        state = .preparingWorktree
        startedAt = Date()
        elapsed = 0
        startTimer()

        let prompt = DelegationPrompt.full(for: context, task: task)
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await worktree.prepare(
                    branch: self.context.headRefName,
                    headOid: self.context.headRefOid
                )
            } catch {
                self.fail(with: error)
                return
            }
            guard !Task.isCancelled else { return }

            let session: AgentSession
            do {
                session = try self.runner.run(prompt: prompt, in: worktree.directory)
            } catch {
                self.fail(with: error)
                return
            }
            self.session = session
            self.state = .running
            self.append(.note, String(localized: "Running \(self.agentName) in \(worktree.directory.lastPathComponent)"))
            if self.isAutomatic {
                // A run nobody pressed a button for says so in its own transcript, not only in
                // the header badge and the notification (ADR 0016).
                self.append(
                    .note,
                    String(localized: "Started automatically by a delegation rule. Nothing is pushed.")
                )
            }

            for await event in session.events {
                self.apply(event)
            }
            let code = await session.exitCode()
            await self.finish(exitCode: code)
        }
    }

    /// Stops the run: `SIGTERM`, then `SIGKILL` after a grace period.
    func cancel() {
        guard case .running = state else {
            if case .preparingWorktree = state {
                runTask?.cancel()
                stopTimer()
                state = .cancelled
                announce(.cancelled, message: nil)
            }
            return
        }
        didCancel = true
        append(.note, String(localized: "Stopping the agent…"))
        session?.cancel()
    }

    private func apply(_ event: AgentStreamEvent) {
        switch event {
        case .systemInit(let model):
            if let model, !model.isEmpty {
                append(.note, String(localized: "Model: \(model)"))
            }
        case .assistantText(let text):
            append(.assistant, text)
        case .toolUse(let name):
            append(.tool, name)
        case .result(let result):
            lastResult = result
        case .unknown:
            break
        }
    }

    private func finish(exitCode: Int32) async {
        stopTimer()
        session = nil
        if didCancel {
            state = .cancelled
            append(.note, String(localized: "Cancelled. The worktree is left in place."))
            await refreshWorktreeStatus()
            announce(.cancelled, message: nil)
            return
        }
        // A CLI that does not speak stream-json never sends a result event; the exit code is
        // then the only thing there is to go on.
        let result = lastResult ?? AgentRunResult(
            isError: exitCode != 0,
            resultText: nil,
            subtype: exitCode == 0 ? "success" : String(localized: "exit \(Int(exitCode))")
        )
        var stat = ""
        if let worktree {
            stat = (try? await worktree.diffStat()) ?? ""
        }
        await refreshWorktreeStatus()
        state = .finished(result: result, diffStat: stat)
        append(
            .note,
            result.isError
                ? String(localized: "The agent stopped with an error.")
                : String(localized: "The agent finished.")
        )
        // An agent that reported an error is a *failed* delegation to anything listening, even
        // though the sheet's state machine calls the state `finished` — the run is over either
        // way, and what an automation wants to know is whether the work got done.
        announce(result.isError ? .failed : .finished, message: result.subtype)
    }

    private func refreshWorktreeStatus() async {
        guard let worktree else { return }
        worktreeStatus = try? await worktree.status()
    }

    private func fail(with error: any Error) {
        stopTimer()
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        state = .failed(message: message)
        append(.note, message)
        announce(.failed, message: message)
    }

    /// Hands the finished run to whoever asked to be told, exactly once.
    /// - Parameters:
    ///   - status: How the run ended.
    ///   - message: A short reason, when there is one.
    private func announce(_ status: DelegationOutcome.Status, message: String?) {
        guard !didAnnounceOutcome, let onDidFinish else { return }
        didAnnounceOutcome = true
        onDidFinish(
            DelegationOutcome(
                prID: context.prID,
                repo: context.repo,
                number: context.number,
                status: status,
                agent: agentName,
                durationSeconds: Int(elapsed.rounded()),
                changedFileCount: worktreeStatus?.changedPaths.count ?? 0,
                message: message,
                wasAutomatic: isAutomatic,
                at: Date()
            )
        )
    }

    private func append(_ kind: TranscriptEntry.Kind, _ text: String) {
        transcript.append(TranscriptEntry(kind: kind, text: text))
    }

    private func startTimer() {
        stopTimer()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let startedAt = self.startedAt else { return }
                guard !Task.isCancelled else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
    }

    // MARK: - What happens to the result

    /// The commit message used by ``commitAndPush()``.
    var commitMessage: String {
        switch context.origin {
        case .pullRequest:
            return String(localized: "Address review feedback on #\(context.number)")
        case .reviewFinding(let path, _):
            return String(localized: "Address review finding in \(path)")
        }
    }

    /// Commits everything in the worktree and pushes it to the pull request's branch.
    ///
    /// Only ever runs because the user pressed the button: ADR 0011 forbids auto-pushing agent
    /// output, and the push uses the user's own git credentials, never Shepherd's token.
    func commitAndPush() {
        guard let worktree, !isPublishing, case .finished = state else { return }
        isPublishing = true
        let branch = context.headRefName
        let message = commitMessage
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isPublishing = false }
            do {
                try await worktree.commitAll(message: message)
                try await worktree.push(toBranch: branch)
                self.hasPushed = true
                self.append(.note, String(localized: "Pushed to \(branch)."))
                self.toasts?.success(String(localized: "Pushed the agent's changes to \(branch)."))
                await self.onDidPush?()
            } catch {
                self.toasts?.failure(
                    error,
                    context: String(localized: "Could not push the agent's changes")
                )
            }
            await self.refreshWorktreeStatus()
        }
    }

    /// Deletes the worktree and resets the sheet.
    func discardWorktree() {
        guard let worktree, !isPublishing else { return }
        isPublishing = true
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isPublishing = false }
            do {
                try await worktree.remove()
                self.state = .idle
                self.transcript = []
                self.worktreeStatus = nil
                self.toasts?.info(String(localized: "Removed the worktree."))
            } catch {
                self.toasts?.failure(
                    error,
                    context: String(localized: "Could not remove the worktree")
                )
            }
        }
    }

    /// Shows the worktree in Finder.
    func revealWorktreeInFinder() {
        guard let worktree else { return }
        NSWorkspace.shared.activateFileViewerSelecting([worktree.directory])
    }
}
