import GitHubKit
import Observation
import ShepherdCore
import ShepherdSync

/// The iPhone's composition root (ADR 0044): what `AppEnvironment` is on the Mac, minus
/// everything the phone does not run.
///
/// It holds the settings, the token store and the signed-in session, and nothing else of the
/// Mac's: no automations, no delegation, no webhooks, no Sparkle, no Spotlight, no search index,
/// no digest, no MetricKit, no telemetry. Those types are still *compiled* into the phone —
/// shared files name them — but none of them is constructed here, and that is the line this
/// type exists to hold. The review logic itself is not re-implemented: the session, the inbox
/// and review models and the outbox-backed actions are the Mac's own, from the shared list in
/// project.yml.
///
/// This is the skeleton: bootstrap, sign-in and the session. Sign-out and erase, the merge and
/// re-read follow-ups of `AppEnvironment.handle(_:)`, the watched repositories and the
/// scene-phase handling arrive with the phone's shell (ADR 0044, step 5).
@MainActor
@Observable
final class PhoneEnvironment: AccountSigningIn, SyncEventPresenting {
    /// Where the app is in its life.
    enum Phase {
        /// The stored account and token are being read.
        case launching
        /// No usable credential: the sign-in screen.
        case signedOut
        /// A session is open.
        case signedIn(SignedInSession)
    }

    /// The current phase. Drives ``PhoneRootView``.
    private(set) var phase: Phase = .launching
    /// Whether ``bootstrap()`` has run in this process.
    @ObservationIgnored private var hasBootstrapped = false
    /// The user's preferences — the Mac's `AppSettings`, on the phone's own defaults.
    let settings: AppSettings
    /// The GitHub credential, in the phone's Keychain.
    let tokenStore: KeychainTokenStore
    /// Transient notices.
    let toasts = ToastCenter()
    /// Which pull request has which write in flight, for busy states.
    let activity = ActionActivity()
    /// The navigation path of the signed-in screens.
    let router = PhoneRouter()

    /// How the client reaches GitHub: `URLSessionTransport` except in the demo mode.
    private let gitHubTransport: any HTTPTransport
    /// Whether the session's sweep loop runs. Off only in the demo mode, which must not sync.
    private let runsSyncLoop: Bool

    /// Creates the container.
    /// - Parameters:
    ///   - settings: The settings store.
    ///   - tokenStore: The token store.
    ///   - gitHubTransport: The GitHub transport.
    ///   - runsSyncLoop: Whether the session sweeps on its own.
    init(
        settings: AppSettings = AppSettings(),
        tokenStore: KeychainTokenStore = KeychainTokenStore(),
        gitHubTransport: any HTTPTransport = URLSessionTransport(),
        runsSyncLoop: Bool = true
    ) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.gitHubTransport = gitHubTransport
        self.runsSyncLoop = runsSyncLoop
    }

    /// The open session, if any.
    var session: SignedInSession? {
        if case .signedIn(let session) = phase { return session }
        return nil
    }

    /// Opens the session for the stored account, or lands on sign-in.
    ///
    /// The Mac's rule (`AppEnvironment.bootstrap()`): an account whose token is gone is not an
    /// account, so it is forgotten rather than left to fail every request.
    ///
    /// Once only: it runs from the window's `.task`, which iOS runs again when it discards a scene
    /// and reconnects it, and a second run would start a second session — and a second sweep
    /// loop — beside the first, which nothing would ever stop. Marked before the first `await`,
    /// because `phase` is still `.launching` while the token is read.
    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
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
            phase = .signedOut
            toasts.failure(error, context: String(localized: "Sign-in failed"))
        }
    }

    // MARK: - AccountSigningIn

    func signIn(account: Account, token: TokenSet) async {
        do {
            try await tokenStore.setToken(token, for: account.login)
            settings.store(account: account)
            try await startSession(for: account)
        } catch {
            toasts.failure(error, context: String(localized: "Sign-in failed"))
        }
    }

    // MARK: - SyncEventPresenting

    /// No notifications in v1 (ADR 0044: no push, and no local notification either — the phone
    /// does not sweep in the background, so there is nothing to announce while it is closed).
    func present(_ event: SyncEvent, settings: AppSettings) async {}

    // MARK: - Session

    /// The outbox-backed write actions for the open session.
    /// - Parameter session: The open session.
    func actions(for session: SignedInSession) -> PullRequestActions {
        PullRequestActions(session: session, toasts: toasts, activity: activity)
    }

    private func startSession(for account: Account) async throws {
        let session = try await SignedInSession.make(
            account: account,
            tokenStore: tokenStore,
            sweepInterval: settings.sweepIntervalMinutes * 60,
            transport: gitHubTransport
        )
        phase = .signedIn(session)
        session.start(
            settings: settings,
            notifications: self,
            runsSyncLoop: runsSyncLoop,
            onEvent: { _ in }
        )
    }
}
