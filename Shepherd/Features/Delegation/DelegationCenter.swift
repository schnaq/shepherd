import Foundation
import Observation
import ShepherdCore

/// Owns the delegation sheets: at most one on screen, at most one *run* per pull request.
///
/// The "one per pull request" rule is the reason this exists at all. Two delegations for the
/// same pull request would race for the same worktree directory, so a second request while one
/// is running simply reveals the running one instead of starting anything (ADR 0011).
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
    /// - Returns: The model now on screen.
    @discardableResult
    func open(
        context: DelegationContext,
        settings: AppSettings,
        toasts: ToastCenter,
        onDidPush: (@MainActor () async -> Void)? = nil,
        onDidFinish: (@MainActor (DelegationOutcome) -> Void)? = nil
    ) -> DelegationModel {
        if let existing = models[context.prID], existing.isBusy {
            presented = existing
            return existing
        }

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
                directory: GitWorktree.directory(repo: context.repo, number: context.number)
            )
        }

        let model = DelegationModel(
            context: context,
            configuration: configuration,
            readiness: readiness,
            runner: AgentCLIRunner(configuration: configuration, executable: executable),
            worktree: worktree,
            toasts: toasts,
            onDidPush: onDidPush,
            onDidFinish: onDidFinish
        )
        models[context.prID] = model
        presented = model
        return model
    }

    /// Closes the sheet. A run keeps going in the background; re-opening shows it again.
    func dismiss() {
        presented = nil
    }
}
