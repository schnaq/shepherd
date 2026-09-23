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

/// That an issue was handed to an assistant, flattened to values (ADR 0032's 2026-09-04
/// amendment).
///
/// ``DelegationOutcome``'s counterpart at the other end of the run, and it exists for exactly one
/// consumer: the `issue.assigned_to_agent` webhook. The moment it describes is the moment the
/// assistant is **actually running** in the worktree — not the click, and not the assignment
/// comment reaching GitHub. A click can be followed by a missing checkout, a branch git refuses
/// to create or a tool that will not start, and an event fired there would report work nobody is
/// doing; the comment, in turn, is queued locally and may sit out a backoff for minutes. What is
/// true at this one point is "something is working on this issue now", which is what the event
/// name promises.
///
/// Only an issue-origin run announces one. The two pull-request origins are already covered by
/// ``DelegationOutcome`` and have no assignment to report.
struct DelegationStart: Sendable, Equatable {
    /// The issue's node id.
    var prID: String
    /// The repository.
    var repo: RepoRef
    /// The issue number.
    var number: Int
    /// The agent CLI's display name.
    var agent: String
    /// Which task template the brief was rendered from — a name, never the text.
    var template: String
    /// When the run started.
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
    ///
    /// Settable for one origin only: a repository task learns its directory when it starts,
    /// because the directory is named after the task text (``DelegationContext/Origin/repository``),
    /// so the handle the centre built is re-aimed there. Every other origin's directory is known
    /// when the sheet opens and never changes.
    private(set) var worktree: GitWorktree?

    /// The branch a repository task was given when it started, e.g. `agent/add-dark-mode`.
    ///
    /// `nil` before the first run and for every other origin, whose branch is the context's own.
    /// Kept across *Run again*, which continues on the same branch in the same worktree rather
    /// than starting a second one, and cleared by *Discard worktree*.
    private(set) var taskBranch: String?

    /// What a new-work run's branch was started from, e.g. `origin/main`.
    ///
    /// The diff the result card shows is taken against this rather than against `HEAD`, because
    /// a new-work run is allowed to commit (ADR 0011's 2026-09-04 amendment) and a committed
    /// change is invisible to `git diff HEAD` — the card would say "changed nothing" about a run
    /// that did all its work.
    private var newWorkBase: String?

    private let runner: any AgentRunning
    private let toasts: ToastCenter?
    private let onDidPush: (@MainActor () async -> Void)?
    private let onDidFinish: (@MainActor (DelegationOutcome) -> Void)?
    /// Called once each time a run actually begins (ADR 0036).
    ///
    /// Beside ``onDidFinish`` and deliberately *not* ``onDidStart``: that one is issue-only and
    /// carries a ``DelegationStart`` for the handover webhook (ADR 0032). This one fires for every
    /// origin and carries nothing, because its only caller counts runs — and counting them where
    /// the sheet is *opened* would count the sheets nobody pressed Start in.
    private let onDidBegin: (@MainActor () -> Void)?
    private let onDidStart: (@MainActor (DelegationStart) -> Void)?
    /// Guards ``onDidStart`` against firing twice: a handover is announced once per run, and a
    /// run that is restarted from the same sheet is a second handover of the same issue.
    private var didAnnounceStart = false

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
    ///   - onDidBegin: Called once each time a run begins (ADR 0036).
    ///   - onDidStart: Called once when an issue-origin run is actually running (ADR 0032).
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
        onDidBegin: (@MainActor () -> Void)? = nil,
        onDidStart: (@MainActor (DelegationStart) -> Void)? = nil,
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
        self.onDidBegin = onDidBegin
        self.onDidStart = onDidStart
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
    ///
    /// For new work that includes commits the run made itself: the diff stat is taken against the
    /// branch's starting point, so a non-empty one means there is something to push even when the
    /// worktree is clean.
    var hasChanges: Bool {
        if worktreeStatus?.isDirty == true { return true }
        guard context.isNewWork, case .finished(_, let stat) = state else { return false }
        return !stat.isEmpty
    }

    /// The branch the run works on: the pull request's, the issue's, or the one a repository
    /// task was given — empty for a repository task that has not started yet.
    var branchName: String {
        context.isRepositoryTask ? (taskBranch ?? "") : context.headRefName
    }

    /// Whether ``worktree`` names the directory the run uses.
    ///
    /// False only for a repository task before its first run, whose handle still points at the
    /// managed root because the directory's name is not known yet.
    var isWorktreeDirectoryKnown: Bool {
        worktree != nil && (!context.isRepositoryTask || taskBranch != nil)
    }

    /// `1 m 12 s`, for the running header.
    var elapsedText: String { RelativeDate.duration(elapsed) }

    /// A one-line summary of the guardrails in force.
    var guardrailSummary: String {
        var parts = [
            configuration.permissionMode.title,
            // `0` is "no limit" (Settings → Delegation), and the CLI is then run without
            // `--max-turns` — so the summary says that rather than "0 turns max".
            configuration.maxTurns > 0
                ? String(localized: "\(configuration.maxTurns) turns max")
                : String(localized: "no turn limit"),
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
        didAnnounceStart = false
        lastResult = nil
        worktreeStatus = nil
        hasPushed = false
        transcript = []
        state = .preparingWorktree
        startedAt = Date()
        elapsed = 0
        startTimer()

        // After the guard above, so a press that could not start anything is not counted, and
        // before the work, so it does not depend on how the run ends (ADR 0036).
        onDidBegin?()

        let taskText = task
        runTask = Task { [weak self] in
            guard let self else { return }
            var startedFrom: String?
            var worktree = worktree
            do {
                if self.context.isRepositoryTask {
                    // New work whose branch is named after the task, so the name is chosen now
                    // rather than when the sheet opened (ADR 0011's 2026-09-23 amendment).
                    let prepared = try await self.prepareRepositoryTask(taskText, from: worktree)
                    worktree = prepared.worktree
                    startedFrom = prepared.startedFrom
                } else if self.context.isIssue {
                    // New work, so there is no commit to stand on: the worktree is created on
                    // Shepherd's branch at the default branch's tip (ADR 0032's 2026-09-04
                    // amendment). The two pull-request origins keep the detached checkout.
                    startedFrom = try await worktree.addForNewWork(branch: self.context.headRefName)
                    self.newWorkBase = startedFrom
                } else {
                    try await worktree.prepare(
                        branch: self.context.headRefName,
                        headOid: self.context.headRefOid
                    )
                }
            } catch {
                self.fail(with: error)
                return
            }
            guard !Task.isCancelled else { return }
            if let startedFrom {
                // Which branch the work is on, and what it was started from. A pull-request run
                // needs no such line — its branch and commit are the pull request's, and both
                // are in the header — but for new work both are Shepherd's own choice, so the
                // transcript is where they are recorded.
                self.append(
                    .note,
                    String(
                        localized: "Working on \(self.branchName), started from \(startedFrom)."
                    )
                )
            } else if self.context.isRepositoryTask {
                self.append(
                    .note,
                    String(localized: "Continuing on \(self.branchName) in the same worktree.")
                )
            }

            // Built after the worktree step rather than before it: a repository task's preamble
            // names its branch, and the branch is only known once the step above has chosen it.
            var promptContext = self.context
            promptContext.headRefName = self.branchName
            let prompt = DelegationPrompt.full(for: promptContext, task: taskText)

            let session: AgentSession
            do {
                session = try self.runner.run(prompt: prompt, in: worktree.directory)
            } catch {
                self.fail(with: error)
                return
            }
            self.session = session
            self.state = .running
            self.announceStart()
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

    /// Chooses a repository task's branch and adds its worktree.
    ///
    /// The first run picks a free slug from the task's first line
    /// (``GitWorktree/freeTaskSlug(for:repo:suffix:)``), re-aims the handle at the directory of
    /// that name and adds the worktree through the same ``GitWorktree/addForNewWork(branch:)``
    /// an issue uses — so the fetch, the default-branch lookup and its "git could not tell which
    /// branch" message are the issue path's, not a second copy. *Run again* in the same sheet
    /// continues in the worktree the first run left, on the same branch: the first run's work,
    /// committed or not, is what the second one is meant to build on.
    /// - Parameters:
    ///   - task: The task text the run was started with.
    ///   - worktree: The handle as it is now.
    /// - Returns: The handle the run uses, and the ref a fresh branch was started from — `nil`
    ///   when the run continues in place.
    private func prepareRepositoryTask(
        _ task: String,
        from worktree: GitWorktree
    ) async throws -> (worktree: GitWorktree, startedFrom: String?) {
        if taskBranch != nil, FileManager.default.fileExists(atPath: worktree.directory.path) {
            return (worktree, nil)
        }
        guard let slug = await worktree.freeTaskSlug(for: task, repo: context.repo) else {
            throw GitWorktree.Failure.noFreeTaskBranch
        }
        let branch = RepositoryTaskBranch.branchName(slug: slug)
        let relocated = worktree.relocated(
            to: GitWorktree.directory(repo: context.repo, taskSlug: slug, root: worktree.managedRoot)
        )
        // Recorded before git runs, so a failure below still leaves the sheet naming the branch
        // and the directory it was trying to create — and a cancelled preparation's footer path
        // is the one it would have used.
        self.worktree = relocated
        taskBranch = branch
        let base = try await relocated.addForNewWork(branch: branch)
        newWorkBase = base
        return (relocated, base)
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
            if let newWorkBase {
                stat = (try? await worktree.diffStat(since: newWorkBase)) ?? ""
            } else {
                stat = (try? await worktree.diffStat()) ?? ""
            }
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
        let message = error.userFacingDescription
        state = .failed(message: message)
        append(.note, message)
        announce(.failed, message: message)
    }

    /// Says that an issue is being worked on, exactly once per run.
    ///
    /// Called at the transition to ``State/running``, which is the first moment the statement is
    /// true: the worktree exists, the branch exists and the assistant's process is up. Nothing is
    /// announced for a pull-request origin — see ``DelegationStart``.
    private func announceStart() {
        guard !didAnnounceStart, context.isIssue, let onDidStart else { return }
        didAnnounceStart = true
        onDidStart(
            DelegationStart(
                prID: context.prID,
                repo: context.repo,
                number: context.number,
                agent: agentName,
                template: IssueDelegationPrompt.name(
                    of: context.taskTemplate ?? IssueDelegationPrompt.defaultTemplate
                ),
                at: Date()
            )
        )
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
        case .issue:
            // GitHub's own closing keyword, so the pull request this branch becomes closes the
            // issue it was assigned from without anybody having to remember to link them.
            return String(localized: "Fix #\(context.number): \(context.title)")
        case .repository:
            // The task's own first line: it is what the user wrote the work down as, and there is
            // no number or title to say it better. Cut at a commit subject's customary length.
            let firstLine = task
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            guard !firstLine.isEmpty else { return String(localized: "Agent task") }
            return firstLine.count > 72 ? String(firstLine.prefix(71)) + "…" : firstLine
        }
    }

    /// Commits everything in the worktree and pushes it to the pull request's branch.
    ///
    /// Only ever runs because the user pressed the button: ADR 0011 forbids auto-pushing agent
    /// output, and the push uses the user's own git credentials, never Shepherd's token.
    func commitAndPush() {
        guard let worktree, !isPublishing, case .finished = state else { return }
        isPublishing = true
        let branch = branchName
        let message = commitMessage
        // A new-work run may have committed everything itself, leaving a clean worktree and
        // commits to publish; `git commit` would then fail with "nothing to commit".
        let needsCommit = worktreeStatus?.isDirty ?? true
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isPublishing = false }
            do {
                if needsCommit {
                    try await worktree.commitAll(message: message)
                }
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
        // A repository task stopped before its directory was chosen has nothing on disk yet, and
        // its handle still names the managed root — which `remove()` refuses anyway.
        guard isWorktreeDirectoryKnown, let worktree, !isPublishing else { return }
        isPublishing = true
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isPublishing = false }
            do {
                try await worktree.remove()
                self.state = .idle
                self.transcript = []
                self.worktreeStatus = nil
                // A repository task's next run is a new task: it gets a branch and a directory
                // of its own rather than resuming the branch this worktree was on, which is
                // still in the clone with whatever the run committed to it.
                if self.context.isRepositoryTask {
                    self.taskBranch = nil
                    self.newWorkBase = nil
                }
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
        // Known is not the same as created: a repository task that failed before `worktree add`
        // names its directory without having one.
        guard isWorktreeDirectoryKnown, let worktree,
              FileManager.default.fileExists(atPath: worktree.directory.path)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([worktree.directory])
    }
}
