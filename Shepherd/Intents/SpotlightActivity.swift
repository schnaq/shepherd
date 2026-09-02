import CoreSpotlight
import Foundation
import ShepherdCore

/// The two halves of the Spotlight export that belong to the container (ADR 0021).
///
/// Kept out of `AppEnvironment.swift` on purpose, the way `DeepLinkRouter.swift` keeps deep-link
/// routing out of it: the container should stay a list of what the app *has*, and the routing for
/// one system surface is a feature.
extension AppEnvironment {
    /// Exports the inbox to Spotlight, or deletes the domain, to match the setting.
    ///
    /// Called at launch and whenever ``AppSettings/spotlightExportEnabled`` changes — from the
    /// toggle in Settings, or because a downloaded settings document carried the flag from another
    /// Mac (ADR 0014). **One route for both**, exactly as ``applyDiagnosticsSetting()`` (ADR 0017)
    /// and ``applySemanticSearchSetting()`` (ADR 0019) have one: `ShepherdApp` watches the flag,
    /// the toggle only writes it, and nothing else in the app talks to ``SpotlightIndexer`` about
    /// being on or off.
    ///
    /// Switching it off **deletes the whole domain** rather than leaving the items to expire.
    /// Spotlight's index is outside Shepherd's database and outside its sandbox; a switch called
    /// "Show pull requests in Spotlight" that left a few hundred of them in the system index would
    /// not be off, it would be hidden. Switching it back on costs one batched export from rows
    /// that are already in memory.
    func applySpotlightSetting() {
        guard settings.spotlightExportEnabled else {
            // Awaited in a task of its own because the deletion is a framework round trip; nothing
            // in the app waits for it, and `disable()` has already put the status on screen.
            Task { [weak self] in
                guard let self else { return }
                await self.spotlight.disable()
            }
            return
        }
        guard let session else { return }
        spotlight.considerExporting(rows: session.inboxRows)
    }

    /// Opens the pull request behind a Spotlight result.
    ///
    /// Wired to `onContinueUserActivity(CSSearchableItemActionType)` in `ShepherdApp`, beside
    /// `onOpenURL`, because it is the same kind of arrival: something outside the app is naming a
    /// pull request. And it ends in the same place — ``open(_:)`` with a
    /// ``ShepherdCore/DeepLink/pullRequest(repo:number:)`` — so a Spotlight click gets the cache
    /// lookup, the individual fetch for a pull request that is not cached, the queue-until-signed-in
    /// slot and the failure toast that a `shepherd://pr/...` link gets, rather than a second,
    /// thinner implementation of "open a pull request" (ADR 0013).
    ///
    /// The identifier is the only thing Spotlight hands back, so the repository and number are
    /// resolved out of the cached rows (``PullRequestIdentifierLookup``). Everything else is a
    /// sentence: an item whose pull request has left the inbox is a stale item, not a bug, and
    /// saying so beats opening nothing.
    /// - Parameter activity: The user activity Spotlight continued into the app.
    func openSpotlightResult(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return }
        revealWindow()
        guard let session else {
            toasts.info(
                String(localized: "Sign in to Shepherd to open pull requests from Spotlight.")
            )
            return
        }
        guard let row = PullRequestIdentifierLookup.row(
            nodeID: identifier,
            in: session.inboxRows
        ) else {
            toasts.show(
                Toast(
                    message: String(
                        localized: "That pull request is not in Shepherd's inbox any more."
                    ),
                    kind: .warning
                )
            )
            return
        }
        open(.pullRequest(repo: row.repo, number: row.number))
    }
}
