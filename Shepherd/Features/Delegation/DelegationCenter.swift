import Foundation
import Observation
import ShepherdCore

/// Owns the delegation sheets: at most one on screen, at most one *run* per pull request.
///
/// The "one per pull request" rule is the reason this exists at all. Two delegations for the
/// same pull request would race for the same worktree directory, so a second request while one
/// is running simply reveals the running one instead of starting anything (ADR 0011). An
/// automatic start (ADR 0016) goes through the same rule and the same models — it only differs
/// in not putting a sheet on screen and in being marked as automatic.
@MainActor
@Observable
final class DelegationCenter {
    /// The delegation whose sheet is up, if any.
    private(set) var presented: DelegationModel?

    /// Every delegation started this launch, keyed by pull-request id. Finished ones are kept
    /// so re-opening the sheet still shows the diff stat and the push button.
    private(set) var models: [String: DelegationModel] = [:]

    /// Creates an empty centre.
    init() {}

    /// Whether a delegation for a pull request is currently running.
    /// - Parameter prID: The pull request's node id.
    func isRunning(prID: String) -> Bool {
        models[prID]?.isBusy ?? false
    }

    /// How many delegations that a rule started are running right now.
    ///
    /// This is the number the concurrency cap is checked against, and it deliberately counts
    /// only automatic runs: a user who starts three delegations by hand has not used up the
    /// automation's budget (ADR 0016).
    var runningAutomaticCount: Int {
        models.values.filter { $0.isAutomatic && $0.isBusy }.count
    }

    /// Opens (or re-opens) the sheet for a delegation.
    ///
    /// A running delegation for the same pull request is shown as it is: its prompt and
    /// transcript belong to the run in flight and must not be replaced by a new context.
    /// - Parameters:
    ///   - context: What the delegation is about.
    ///   - settings: Where the CLI configuration and the checkout mapping live.
    ///   - toasts: Where failures are surfaced.
    ///   - onDidPush: Called after a successful push so the caller can re-sync.
    ///   - onDidFinish: Called once when the run reaches a terminal state (ADR 0012).
    ///   - onDidStart: Called once when an issue handover is actually running (ADR 0032).
    ///   - brief: How the sheet's ✨ button drafts the task text (plan §3.E), when a tier could
    ///     take it. Only the *attended* entry point takes one — see
    ///     ``startAutomatically(context:task:settings:toasts:onDidPush:onDidFinish:)``.
    /// - Returns: The model now on screen.
    @discardableResult
    func open(
        context: DelegationContext,
        settings: AppSettings,
        toasts: ToastCenter,
        onDidPush: (@MainActor () async -> Void)? = nil,
        onDidFinish: (@MainActor (DelegationOutcome) -> Void)? = nil,
        onDidBegin: (@MainActor () -> Void)? = nil,
        onDidStart: (@MainActor (DelegationStart) -> Void)? = nil,
        brief: AgentBriefDrafter? = nil
    ) -> DelegationModel {
        if let existing = models[context.prID], existing.isBusy {
            presented = existing
            return existing
        }

        let model = make(
            context: context,
            settings: settings,
            toasts: toasts,
            isAutomatic: false,
            onDidPush: onDidPush,
            onDidFinish: onDidFinish,
            onDidBegin: onDidBegin,
            onDidStart: onDidStart,
            brief: brief
        )
        models[context.prID] = model
        presented = model
        return model
    }

    /// Starts a delegation the user did not ask for (ADR 0016).
    ///
    /// Two differences from ``open(context:settings:toasts:onDidPush:onDidFinish:brief:)``, and
    /// nothing else: no sheet is presented — an unexpected modal in front of whatever the user is
    /// doing would be worse than the notification that announces the start — and the model is
    /// marked automatic, which is what the badge and the webhook payload read.
    ///
    /// It also takes **no brief drafter**, and that omission is load-bearing: a rule-started run
    /// gets the task text its template rendered and nothing else, so there is no code path from a
    /// generated brief to an agent nobody pressed a button for (ADR 0016, ADR 0011's amendment).
    /// - Parameters:
    ///   - context: What the delegation is about.
    ///   - task: The rendered task text; replaces the prefilled default.
    ///   - settings: Where the CLI configuration and the checkout mapping live.
    ///   - toasts: Where failures are surfaced.
    ///   - onDidPush: Called after a successful push so the caller can re-sync.
    ///   - onDidFinish: Called once when the run reaches a terminal state (ADR 0012).
    /// - Returns: The model that was started, or `nil` when one was already running for this
    ///   pull request or the run could not be started at all.
    @discardableResult
    func startAutomatically(
        context: DelegationContext,
        task: String,
        settings: AppSettings,
        toasts: ToastCenter,
        onDidPush: (@MainActor () async -> Void)? = nil,
        onDidFinish: (@MainActor (DelegationOutcome) -> Void)? = nil,
        onDidBegin: (@MainActor () -> Void)? = nil
    ) -> DelegationModel? {
        // A free-text task on a repository is somebody's words typed into a sheet; no rule has
        // a condition that could stand for them (ADR 0016's rules fire on a pull request's
        // transitions). `AutoDelegationCoordinator` only ever builds a pull-request context, so
        // this is belt and braces — but it makes "a rule never starts a repository task" a line
        // of code rather than a property of today's callers (ADR 0011's 2026-09-23 amendment).
        guard !context.isRepositoryTask else { return nil }
        // The one-per-pull-request rule, again from the one place that owns it.
        if let existing = models[context.prID], existing.isBusy { return nil }

        let model = make(
            context: context,
            settings: settings,
            toasts: toasts,
            isAutomatic: true,
            onDidPush: onDidPush,
            onDidFinish: onDidFinish,
            onDidBegin: onDidBegin,
            // No handover event either: a rule only ever starts from a pull request (ADR 0016),
            // and ``DelegationStart`` is an issue's news.
            onDidStart: nil,
            // No drafter: see above.
            brief: nil
        )
        model.task = task
        // Nothing is remembered unless it actually runs: a model parked in "no checkout" that
        // nobody asked for would show up later as a stale sheet for a delegation that never was.
        guard model.canStart else { return nil }
        models[context.prID] = model
        model.start()
        return model
    }

    /// Puts a delegation this centre already holds back on screen, as it is.
    ///
    /// For the repository task's re-entry: ``open(context:settings:toasts:onDidPush:onDidFinish:onDidBegin:onDidStart:brief:)``
    /// replaces a model that is not running, which for a pull request costs nothing — the next run
    /// reuses the same directory — but for a repository task would orphan the finished run's
    /// worktree under a slug nothing points at any more. The caller decides when to keep one.
    /// - Parameter model: A model from ``models``.
    func present(_ model: DelegationModel) {
        guard models[model.id] === model else { return }
        presented = model
    }

    /// Closes the sheet. A run keeps going in the background; re-opening shows it again.
    func dismiss() {
        presented = nil
    }

    /// Where a context's worktree lives, as far as it is known when the sheet opens.
    ///
    /// Issue 128 and pull request 128 are two different pieces of work in the same repository, so
    /// they get two directories (ADR 0032's 2026-09-04 amendment). A repository task's directory
    /// is named after its task text, which nobody has typed yet, so the handle starts out aimed at
    /// the managed root itself and ``DelegationModel`` re-aims it when the run starts — the root is
    /// also the one directory ``GitWorktree/remove()`` refuses to delete, so a stray *Discard*
    /// before that point cannot take anything with it.
    /// - Parameter context: What the delegation is about.
    static func worktreeDirectory(
        for context: DelegationContext,
        root: URL = AppConfig.worktreesDirectory
    ) -> URL {
        switch context.origin {
        case .issue:
            return GitWorktree.directory(repo: context.repo, issueNumber: context.number, root: root)
        case .repository:
            return root
        case .pullRequest, .reviewFinding:
            return GitWorktree.directory(repo: context.repo, number: context.number, root: root)
        }
    }

    /// Builds a model for a context, resolving the CLI and the worktree from settings.
    private func make(
        context: DelegationContext,
        settings: AppSettings,
        toasts: ToastCenter,
        isAutomatic: Bool,
        onDidPush: (@MainActor () async -> Void)?,
        onDidFinish: (@MainActor (DelegationOutcome) -> Void)?,
        onDidBegin: (@MainActor () -> Void)?,
        onDidStart: (@MainActor (DelegationStart) -> Void)?,
        brief: AgentBriefDrafter?
    ) -> DelegationModel {
        let configuration = settings.agentCLI
        let executable = AgentCLILocator.locate(configuration: configuration)
        let checkout = settings.localCheckoutURL(for: context.repo)

        let readiness: DelegationModel.Readiness
        if checkout == nil {
            readiness = .missingCheckout(repo: context.repo.fullName)
        } else if executable == nil {
            readiness = .missingCLI
        } else {
            readiness = .ready
        }

        let worktree = checkout.map { checkout in
            GitWorktree(
                checkout: checkout,
                // Issue 128 and pull request 128 are two different pieces of work in the same
                // repository, so they get two directories (ADR 0032's 2026-09-04 amendment).
                directory: Self.worktreeDirectory(for: context)
            )
        }

        return DelegationModel(
            context: context,
            configuration: configuration,
            readiness: readiness,
            // The session travels into the runner, which is the one place that decides which
            // template builds the command (ADR 0030). Everything else about the run — worktree,
            // guardrails, transcript, "never pushes" — is the same code either way.
            runner: AgentCLIRunner(
                configuration: configuration,
                executable: executable,
                session: context.session
            ),
            worktree: worktree,
            isAutomatic: isAutomatic,
            toasts: toasts,
            onDidPush: onDidPush,
            onDidFinish: onDidFinish,
            onDidBegin: onDidBegin,
            onDidStart: onDidStart,
            brief: brief
        )
    }
}
