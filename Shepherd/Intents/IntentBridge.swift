import AppIntents
import Foundation
import ShepherdCore

/// How an App Intent finds the running app (ADR 0021).
///
/// App Intents are values the *system* creates: Shortcuts, Siri and Spotlight instantiate an
/// `AppIntent` with `init()` and call `perform()` inside the app's process, so an intent has no
/// initialiser it could be handed a dependency through and no view hierarchy to read an
/// `@Environment` from. Apple's answer is `@Dependency`, which requires the app to register its
/// dependencies at launch; this is the same idea with one moving part instead of two — the
/// container registers itself at the end of its own `init`, and the intents ask for it here.
///
/// The reference is **weak** and the accessor **throws** rather than force-unwrapping, because
/// there is a real state in which there is no container: the system may launch the app purely to
/// run a read-only intent, and an intent that crashed the app in that moment would be a crash the
/// user cannot connect to anything they did. Every failure is a sentence instead
/// (``IntentFailure``), which is what Shortcuts and Siri put in front of them.
@MainActor
enum IntentBridge {
    /// The container, while the app is running.
    private(set) static weak var environment: AppEnvironment?

    /// Registers the container. Called once, from ``AppEnvironment/init(settings:tokenStore:secretStore:)``.
    /// - Parameter environment: The container.
    static func register(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// The container, or a sentence saying there is none.
    /// - Returns: The container.
    static func requireEnvironment() throws -> AppEnvironment {
        guard let environment else { throw IntentFailure.appNotRunning }
        return environment
    }

    /// The container and its signed-in session, or a sentence saying there is no account.
    ///
    /// Used by the intents that need the local database. "Not signed in" is a genuinely different
    /// answer from "nothing needs your review", and a Shortcut that was told the second when the
    /// first was true would be actively misleading.
    /// - Returns: The container and the session.
    static func requireSession() throws -> (AppEnvironment, SignedInSession) {
        let environment = try requireEnvironment()
        guard let session = environment.session else { throw IntentFailure.notSignedIn }
        return (environment, session)
    }
}

extension AppEnvironment {
    /// Brings Shepherd's window forward for a system surface that is not inside it.
    ///
    /// Both surfaces ADR 0021 adds need this and neither can get it for free. `openAppWhenRun`
    /// activates the *app*, and a Spotlight result likewise, but neither *creates* a window — so a
    /// user who closed the last one would otherwise watch Shepherd come to the front with nothing
    /// in it. The two steps, in this order, are the ones the menu-bar quick inbox and a clicked
    /// digest notification already take: ask AppKit for an existing window, and only when there is
    /// none ask SwiftUI for a new one (``activateMainWindow()``).
    func revealWindow() {
        guard !activateMainWindow() else { return }
        reopenMainWindow?()
    }
}

/// Why an intent could not do what it was asked (ADR 0021).
///
/// `CustomLocalizedStringResourceConvertible` is what makes these sentences the ones Shortcuts and
/// Siri actually read out, rather than "the operation could not be completed". They are written to
/// be heard: each one names the state and the fix, because an intent's error is frequently the
/// only feedback a voice request gets.
enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    /// No running app has registered its environment — the intent ran before launch finished, or
    /// the system chose not to open the app — so there is nothing to act on.
    case appNotRunning
    /// No GitHub account is signed in on this Mac.
    case notSignedIn
    /// The pull request the shortcut refers to is no longer in the local inbox.
    case pullRequestNotAvailable(slug: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotRunning:
            return LocalizedStringResource("Shepherd is not running.")
        case .notSignedIn:
            return LocalizedStringResource(
                "Sign in to Shepherd first — no GitHub account is connected on this Mac."
            )
        case .pullRequestNotAvailable(let slug):
            return LocalizedStringResource("\(slug) is not in Shepherd's inbox any more.")
        }
    }
}
