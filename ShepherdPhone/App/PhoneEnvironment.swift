import GitHubKit
import Observation
import ShepherdCore
import ShepherdSync
import SwiftUI
import UIKit

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
/// Beyond bootstrap and sign-in it carries the four things a session needs to behave like the
/// Mac's: sign-out and erase, the follow-ups of `AppEnvironment.handle(_:)` that make a write's
/// outcome visible, the watched repositories, and the scene-phase policy — the phone sweeps while
/// it is open and drains its outbox on the way out, and nothing in between (ADR 0044, "No push, no
/// background refresh in v1").
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
    /// Whether the settings sheet is up. A flag rather than a closure so any screen — the inbox's
    /// account button, later a toast's action — can open it by assignment, and so sign-out can
    /// close it before the sign-in screen replaces what it was covering.
    var isSettingsPresented = false
    /// Bumped on every sign-in this process completes — not on a launch that restores one — so the
    /// root view has something to fire the success haptic on: the sign-in screen is already gone
    /// by the time the session opens.
    private(set) var signInCount = 0

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
            signInCount += 1
        } catch {
            toasts.failure(error, context: String(localized: "Sign-in failed"))
        }
    }

    // MARK: - Sign out

    /// Signs out and deletes both the credential and the local cache (ADR 0006).
    ///
    /// `AppEnvironment.signOutAndErase()`, minus the Mac's automation ledgers, digest, search
    /// index, triage verdicts and Spotlight domain — none of which the phone constructs. The order
    /// is the Mac's and matters the same way: every screen and every follow-up that could still
    /// write the leaving account's pull requests is stopped *before* the database is emptied.
    func signOutAndErase() async {
        let current = session
        // The sheet first: it is what the user pressed the button in, and left up it would float
        // over the sign-in screen.
        isSettingsPresented = false
        phase = .signedOut
        // Stops every open pull request's `ReviewModel`: their observations read the database
        // about to be erased.
        router.reset()
        // The re-reads still waiting after a write, and the sweep a merge asked for: they would
        // fetch the leaving account's pull requests and store them back after the erase.
        rereadTasks.values.forEach { $0.cancel() }
        rereadTasks = [:]
        syncAfterMergeTask?.cancel()
        syncAfterMergeTask = nil
        backgroundWork?.cancel()
        backgroundWork = nil
        isStoppedForBackground = false
        endBackgroundTask()
        // The comments it read: parsed bodies stay in memory for as long as the app runs.
        MarkdownText.forgetParsedBodies()
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

    /// Runs a sweep now, from the sync strip's Retry — through the session, never the engine, so
    /// ``SignedInSession/isSyncing`` and ``SignedInSession/lastSyncedAt`` move with it.
    func syncNow() async {
        guard let session else { return }
        do {
            try await session.syncNow(awaitingInFlight: true)
        } catch {
            toasts.failure(error, context: String(localized: "Sync failed"))
        }
    }

    /// Sends every write the drain gave up on again — Settings → Sync's *Retry* on the Mac, for
    /// all of them at once, because the phone has no per-row list to choose from (the sync strip is
    /// the only place it names them).
    func retryFailedWrites() async {
        guard let session else { return }
        let failed = (try? await session.database.failedOutboxItems()) ?? []
        for item in failed {
            try? await session.database.retryOutboxItem(id: item.id)
        }
        await session.drainOutbox(awaitingInFlight: true)
    }

    private func startSession(for account: Account) async throws {
        let session = try await SignedInSession.make(
            account: account,
            tokenStore: tokenStore,
            sweepInterval: settings.sweepIntervalMinutes * 60,
            transport: gitHubTransport
        )
        phase = .signedIn(session)
        // The pull request route's models are built for this session and no other; the factory is
        // dropped again in `router.reset()` on sign-out, so a model can never be made against a
        // session that has shut down.
        router.makeReviewModel = { [settings] prID in
            ReviewModel(session: session, settings: settings, prID: prID)
        }
        // Before `start`, so the first sweep usually carries them already — the Mac's order and
        // its reasoning (`AppEnvironment.startSession`).
        applyWatchedRepositoriesSetting(sweepNow: false)
        session.start(
            settings: settings,
            notifications: self,
            runsSyncLoop: runsSyncLoop,
            onEvent: { [weak self] event in
                self?.handle(event)
            }
        )
    }

    // MARK: - Watched repositories

    /// Hands ``AppSettings/watchedRepositories`` to the engine as extra inbox facets.
    ///
    /// `AppEnvironment.applyWatchedRepositoriesSetting(sweepNow:)`, verbatim in substance: called
    /// at sign-in and whenever the list changes (``ShepherdPhoneApp`` watches it), with a sweep
    /// straight away so a newly watched repository fills the inbox now. Never a sweep in the demo
    /// mode, whose transport refuses every request and would paint a sync error over the seed.
    /// - Parameter sweepNow: Whether to ask for a sweep immediately. False at sign-in, where the
    ///   loop's own first iteration is about to sweep anyway.
    func applyWatchedRepositoriesSetting(sweepNow: Bool = true) {
        guard let session else { return }
        let queries = InboxQuery.watching(settings.watchedRepositories)
        let engine = session.syncEngine
        let sweeps = sweepNow && runsSyncLoop
        Task {
            await engine.setAdditionalQueries(queries)
            guard sweeps else { return }
            try? await session.syncNow()
        }
    }

    // MARK: - Sync events

    // The follow-ups below are copied from `AppEnvironment.handle(_:)` and its helpers, trimmed to
    // what the phone runs (no merge series, no webhooks, no automatic delegation). They are copies
    // only because `AppEnvironment.swift` cannot be compiled for iOS; once the two composition
    // roots can share a type, `confirmMerge`, `rereadAfterConversationWrite`, `followBranchUpdate`
    // and `scheduleSyncAfterMerge` should move into one and both should call it (ADR 0044).

    /// What a sync event means for the screens, beyond the session's own bookkeeping.
    private func handle(_ event: SyncEvent) {
        confirmMerge(event)
        rereadAfterConversationWrite(event)
        followBranchUpdate(event)
        // The Mac raises a parked review as an alert through its `DraftConflictQueue`, which is
        // not shared. The phone says it once, as a warning; the pull request's own screen shows
        // the parked row from then on.
        if case .draftConflict(let conflict) = event {
            // Built first, as in `confirmMerge`: a number interpolated straight into the key would
            // be formatted with a thousands separator.
            let slug = "\(conflict.repo.fullName)#\(conflict.number)"
            toasts.show(Toast(
                message: String(localized: "Not sent: \(slug) has new commits since you wrote your review."),
                kind: .warning,
                duration: 8
            ))
        }
    }

    /// Says so when a merge actually lands, or when GitHub took a stacked pull request's merge but
    /// had not finished it (ADR 0042), and records the landing for the *Merged* chip.
    ///
    /// `AppEnvironment.confirmMerge(_:)`, which argues every case: the button can only honestly say
    /// "queued", so this is the one place the loop closes.
    private func confirmMerge(_ event: SyncEvent) {
        guard case .mutationSent(let sent) = event else { return }
        let slug = "\(sent.repo.fullName)#\(sent.number)"
        switch sent.kind {
        case .merged:
            toasts.success(String(localized: "Merged \(slug)."))
            session?.noteMerged(sent.prID)
        case .mergeEnqueued:
            toasts.success(String(localized: "Queued on GitHub: \(slug)."))
        case .mergeStarted:
            toasts.success(String(localized: "GitHub is merging the stack for \(slug)."))
        case .pullRequestClosed:
            // Toasted where it was queued; the sweep is what takes the closed row out.
            break
        default:
            return
        }
        scheduleSyncAfterMerge()
    }

    /// The detail re-reads a sent conversation write asks for, one per pull request.
    @ObservationIgnored private var rereadTasks: [String: Task<Void, Never>] = [:]

    /// Re-reads a pull request's detail soon after a comment, reply, resolution, review, reaction,
    /// edit or delete reached GitHub, so it shows without waiting for the next sweep (ADR 0043).
    ///
    /// `AppEnvironment.rereadAfterConversationWrite(_:)`: coalesced per pull request, failures
    /// ignored (the sweep reads the same detail), cancelled by sign-out.
    private func rereadAfterConversationWrite(_ event: SyncEvent) {
        guard case .mutationSent(let sent) = event else { return }
        switch sent.kind {
        case .pullRequestCommentAdded, .replyPosted, .reviewCommentPosted, .threadResolved,
             .threadUnresolved, .reviewSubmitted, .reactionChanged, .commentEdited, .commentDeleted:
            break
        default:
            return
        }
        guard rereadTasks[sent.prID] == nil, let session else { return }
        rereadTasks[sent.prID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PhoneEnvironment.rereadAfterWriteDelay))
            self?.rereadTasks[sent.prID] = nil
            guard !Task.isCancelled,
                  let detail = try? await session.github.pullRequestDetail(repo: sent.repo, number: sent.number),
                  // A sign-out during the read: its database is being erased.
                  !Task.isCancelled
            else { return }
            try? await session.database.savePullRequestDetail(detail)
        }
    }

    /// How long a sent conversation write waits before its re-read (the Mac's value).
    static let rereadAfterWriteDelay: Double = 1

    /// Sweeps soon after GitHub accepted an *Update branch* (ADR 0041): the new head only reaches
    /// the phone with a sweep. `AppEnvironment.followBranchUpdate(_:)`.
    private func followBranchUpdate(_ event: SyncEvent) {
        guard case .mutationSent(let sent) = event, case .branchUpdated = sent.kind else { return }
        scheduleSyncAfterMerge()
    }

    /// The sweep a confirmed merge asks for, coalesced.
    @ObservationIgnored private var syncAfterMergeTask: Task<Void, Never>?

    /// Syncs a few seconds after a merge landed, so the merged pull request leaves the inbox now;
    /// the delay is for GitHub's search index. `AppEnvironment.scheduleSyncAfterMerge()`.
    private func scheduleSyncAfterMerge() {
        guard syncAfterMergeTask == nil else { return }
        syncAfterMergeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PhoneEnvironment.syncAfterMergeDelay))
            guard let self else { return }
            // Cleared on every exit, or the coalescing guard would never schedule again.
            self.syncAfterMergeTask = nil
            guard !Task.isCancelled else { return }
            try? await self.session?.syncNow()
        }
    }

    /// How long a confirmed merge waits before its sweep (the Mac's value).
    static let syncAfterMergeDelay: Double = 3

    // MARK: - Scene phase

    /// How old the last sweep may be before coming back to the foreground sweeps again.
    static let staleAfter: TimeInterval = 60

    /// Whether the engine's loop was stopped by ``scenePhaseChanged(to:)`` on the way out, and so
    /// has to be started on the way back in.
    @ObservationIgnored private var isStoppedForBackground = false
    /// Bumped on every phase change, so a background drain that finishes after the app came back
    /// does not stop the loop the return just relied on.
    @ObservationIgnored private var scenePhaseGeneration = 0
    /// The drain-then-stop that runs on the way out.
    @ObservationIgnored private var backgroundWork: Task<Void, Never>?
    /// The background-execution window that drain runs in, while one is open.
    @ObservationIgnored private var backgroundTaskID = UIBackgroundTaskIdentifier.invalid

    /// The phone's whole background policy (ADR 0044): sweep while open, drain on the way out.
    ///
    /// - `.active`: a loop that was stopped on the way out is started again, and its first lap
    ///   sweeps at once (`SyncEngine.runSweepLoop`). A loop that never stopped — a glance at
    ///   another app shorter than the drain — sweeps only when the last sweep is older than
    ///   ``staleAfter``. Never while `lastSyncedAt` is still `nil`: the first sweep is then still
    ///   running, and a second would only race it.
    /// - `.background`: the outbox is drained inside a `beginBackgroundTask` window — iOS suspends
    ///   the process a few seconds after it leaves the foreground, and a review queued just before
    ///   would otherwise wait for the next launch — and then the loop is stopped, so a suspended
    ///   app holds no half-finished sweep. The window is ended once, by whichever comes first of
    ///   the stop, the expiry handler and a return to the foreground.
    ///
    /// Nothing at all in the demo mode, whose loop never runs.
    /// - Parameter phase: The scene's new phase.
    func scenePhaseChanged(to phase: ScenePhase) {
        guard runsSyncLoop, let session else { return }
        switch phase {
        case .active:
            scenePhaseGeneration += 1
            // In the foreground the window buys nothing; a drain still running carries on.
            endBackgroundTask()
            if isStoppedForBackground {
                isStoppedForBackground = false
                Task { await session.syncEngine.start() }
            } else if let last = session.lastSyncedAt, Date().timeIntervalSince(last) > Self.staleAfter {
                Task { try? await session.syncNow() }
            }
        case .background:
            scenePhaseGeneration += 1
            let generation = scenePhaseGeneration
            endBackgroundTask()
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Shepherd outbox") { [weak self] in
                // iOS calls this on the main thread when the window runs out.
                MainActor.assumeIsolated {
                    self?.backgroundWork?.cancel()
                    self?.endBackgroundTask()
                }
            }
            backgroundWork = Task { [weak self] in
                await session.drainOutbox(awaitingInFlight: true)
                // Back in the foreground already, or out of time: leave the loop running. A
                // newer phase owns the window by now, so this one must not end it.
                guard let self, !Task.isCancelled, self.scenePhaseGeneration == generation else { return }
                // Before the `await`, so a return during it starts the loop again.
                self.isStoppedForBackground = true
                await session.syncEngine.stop()
                if self.scenePhaseGeneration == generation { self.endBackgroundTask() }
            }
        default:
            break
        }
    }

    /// Ends the open background-execution window, if any. Safe to call twice.
    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
