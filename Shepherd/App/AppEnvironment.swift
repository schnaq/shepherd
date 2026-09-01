import AppKit
import Foundation
import GitHubKit
import Observation
import ShepherdCore
import ShepherdPersistence
import ShepherdSync
import SwiftUI

/// The dependency container and top-level state machine.
///
/// The app has exactly two states: signed out (onboarding) and signed in (inbox). Everything
/// that needs a token, a database or the network lives in ``SignedInSession`` and therefore
/// cannot exist in the signed-out state.
@MainActor
@Observable
final class AppEnvironment {
    /// Which top-level screen is showing.
    enum Phase {
        /// Reading the Keychain to find out whether an account is signed in.
        case launching
        /// No account: onboarding.
        case signedOut
        /// An account is signed in: the inbox.
        case signedIn(SignedInSession)
    }

    /// Which screen the signed-in window is showing.
    enum Route: Hashable {
        /// The three-pane inbox.
        case inbox
        /// The full-window review screen for one pull request.
        case review(prID: String)
    }

    /// The current phase.
    private(set) var phase: Phase = .launching
    /// The current route within the signed-in window.
    var route: Route = .inbox
    /// Whether the ⌘K palette is up.
    var isCommandPaletteVisible = false
    /// A draft that could not be submitted because the pull request moved on (ADR 0006).
    var draftConflict: DraftConflict?

    /// User preferences.
    let settings: AppSettings
    /// GitHub credentials (Keychain only, ADR 0004).
    let tokenStore: KeychainTokenStore
    /// AI keys (Keychain only, ADR 0007).
    let secretStore: KeychainSecretStore
    /// The window's toast queue; errors are surfaced here, never printed.
    let toasts = ToastCenter()
    /// Maps sync events to macOS notifications.
    let notifications = NotificationManager()
    /// The delegation sheets: one per pull request, at most one on screen (ADR 0011).
    let delegation = DelegationCenter()
    /// Posts events to the user's own webhook URL, when they configured one (ADR 0012).
    let webhooks: WebhookDispatcher
    /// Maps Shepherd's events onto webhook deliveries.
    let webhookCoordinator: WebhookCoordinator

    /// The provider router, rebuilt whenever the intelligence settings change.
    private(set) var intelligence: IntelligenceRouter = .disabled

    /// The signed-in session, when there is one.
    var session: SignedInSession? {
        if case .signedIn(let session) = phase { return session }
        return nil
    }

    /// Creates the container.
    /// - Parameters:
    ///   - settings: The preference store.
    ///   - tokenStore: The GitHub credential store.
    ///   - secretStore: The AI-key store.
    init(
        settings: AppSettings = AppSettings(),
        tokenStore: KeychainTokenStore = KeychainTokenStore(),
        secretStore: KeychainSecretStore = KeychainSecretStore()
    ) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.secretStore = secretStore
        let webhooks = WebhookDispatcher()
        self.webhooks = webhooks
        self.webhookCoordinator = WebhookCoordinator(
            dispatcher: webhooks,
            settings: settings,
            secretStore: secretStore
        )
        refreshIntelligence()
    }

    // MARK: - Lifecycle

    /// Restores the signed-in account, if the Keychain still has its token.
    func bootstrap() async {
        applyAppearance()
        guard let account = settings.account else {
            phase = .signedOut
            return
        }
        do {
            guard try await tokenStore.token(for: account.login) != nil else {
                settings.clearAccount()
                phase = .signedOut
                return
            }
            try await startSession(for: account)
        } catch {
            toasts.failure(error, context: String(localized: "Could not open the local database"))
            phase = .signedOut
        }
    }

    /// Completes a sign-in: stores the credential, remembers the account, starts syncing.
    /// - Parameters:
    ///   - account: The account that authenticated.
    ///   - token: The credential to store in the Keychain.
    func signIn(account: Account, token: TokenSet) async {
        do {
            try await tokenStore.setToken(token, for: account.login)
            settings.store(account: account)
            try await startSession(for: account)
        } catch {
            toasts.failure(error, context: String(localized: "Sign-in failed"))
        }
    }

    /// Signs out and deletes both the credential and the local cache (ADR 0006).
    func signOutAndErase() async {
        let current = session
        route = .inbox
        phase = .signedOut
        if let current {
            await current.shutdown()
            do {
                try await current.database.eraseAllData()
            } catch {
                toasts.failure(error, context: String(localized: "Could not erase local data"))
            }
            do {
                try await tokenStore.deleteToken(for: current.account.login)
            } catch {
                toasts.failure(error, context: String(localized: "Could not remove the Keychain item"))
            }
        }
        settings.clearAccount()
    }

    private func startSession(for account: Account) async throws {
        let session = try await SignedInSession.make(
            account: account,
            tokenStore: tokenStore,
            sweepInterval: settings.sweepIntervalMinutes * 60
        )
        phase = .signedIn(session)
        // `start` spawns the sweep loop, whose first iteration sweeps immediately — an extra
        // `syncNow()` here only bought a second concurrent sweep on every launch.
        session.start(
            settings: settings,
            notifications: notifications
        ) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: SyncEvent) {
        if case .draftConflict(let conflict) = event {
            draftConflict = conflict
        }
        // Fire-and-forget by construction: the coordinator spawns its own task and swallows
        // every failure, so a broken webhook cannot slow down or break the sync (ADR 0012).
        webhookCoordinator.handle(event, database: session?.database)
    }

    // MARK: - Actions

    /// Runs a sweep now (⌘R).
    func syncNow() async {
        guard let session else { return }
        do {
            try await session.syncNow()
        } catch {
            toasts.failure(error, context: String(localized: "Sync failed"))
        }
    }

    /// Opens the delegation sheet for a pull request or a review finding (ADR 0011).
    ///
    /// A delegation already running for the same pull request is revealed rather than
    /// replaced — one worktree per pull request, one run at a time.
    /// - Parameter context: What the delegation is about.
    func startDelegation(_ context: DelegationContext) {
        delegation.open(
            context: context,
            settings: settings,
            toasts: toasts,
            onDidPush: { [weak self] in
                // The agent's commits are on the pull request now; refresh so the review screen
                // shows the new head instead of the one the user delegated from.
                await self?.syncNow()
            },
            onDidFinish: { [weak self] outcome in
                guard let self else { return }
                self.webhookCoordinator.handle(outcome, database: self.session?.database)
            }
        )
    }

    /// Applies the stored appearance preference to the whole app.
    func applyAppearance() {
        NSApplication.shared.appearance = settings.appearance.nsAppearance
    }

    /// Rebuilds the intelligence router from the current settings and Keychain.
    ///
    /// Called at launch and whenever the Intelligence settings tab changes something.
    func refreshIntelligence() {
        var configuration = IntelligenceConfiguration(
            mode: settings.intelligenceMode,
            cloudKind: settings.cloudProviderKind,
            anthropicModel: settings.anthropicModel,
            openAIBaseURL: settings.openAICompatibleBaseURL,
            openAIModel: settings.openAICompatibleModel
        )
        let key = settings.cloudProviderKind == .anthropic
            ? KeychainSecretStore.Key.anthropicAPIKey
            : KeychainSecretStore.Key.openAICompatibleAPIKey
        configuration.cloudAPIKey = ((try? secretStore.secret(for: key)) ?? nil) ?? ""
        intelligence = IntelligenceRouter(configuration: configuration)
    }

    // MARK: - Menu / palette commands

    /// A command raised by the menu bar or the command palette, waiting for the screen that
    /// owns the selection to run it.
    struct PendingAction: Equatable, Identifiable {
        /// Makes two otherwise identical requests distinguishable.
        let id = UUID()
        /// What was asked for.
        let action: ShortcutAction
    }

    /// The command waiting to be executed, if any.
    private(set) var pendingAction: PendingAction?

    /// Raises a command. The visible screen picks it up and clears it.
    /// - Parameter action: The command.
    func request(_ action: ShortcutAction) {
        pendingAction = PendingAction(action: action)
    }

    /// Clears the pending command after a screen has handled it.
    func clearPendingAction() {
        pendingAction = nil
    }

    /// A verdict the review screen should open its composer on, set by an inbox shortcut.
    ///
    /// Transient routing state that is read once, imperatively, when the review screen
    /// appears — no view observes it, so it stays out of the observation graph.
    @ObservationIgnored private var pendingReviewVerdict: ReviewVerdict?

    /// Opens the full-window review screen.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - verdict: When given, the review screen opens its submit composer on this verdict
    ///     instead of the caller queueing a review blind. `r x` and `r c` need a summary body,
    ///     which only the composer can collect.
    func openReview(prID: String, composing verdict: ReviewVerdict? = nil) {
        pendingReviewVerdict = verdict
        route = .review(prID: prID)
    }

    /// Reads and clears the verdict the review screen should open its composer on.
    func consumePendingReviewVerdict() -> ReviewVerdict? {
        defer { pendingReviewVerdict = nil }
        return pendingReviewVerdict
    }

    /// Returns to the inbox.
    func closeReview() {
        route = .inbox
    }
}
