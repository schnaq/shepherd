import Foundation
import GitHubKit
import Observation
import ShepherdCore
import ShepherdPersistence
import ShepherdSync

/// Everything that only exists while an account is signed in.
///
/// Wiring order follows `Packages/ShepherdKit/README.md`: database → client (Keychain token
/// provider, SQLite conditional cache, agent detector seeded with the user's registry
/// overrides) → sync engine.
@MainActor
@Observable
final class SignedInSession {
    /// The signed-in account.
    let account: Account
    /// The local source of truth (ADR 0006).
    let database: DatabaseManager
    /// The GitHub façade.
    let github: GitHubClient
    /// The background sync loops.
    let syncEngine: SyncEngine

    /// When the last successful sweep finished, for the title-bar indicator.
    var lastSyncedAt: Date?
    /// Whether a manual sync is in flight.
    var isSyncing = false
    /// The most recent sync failure, shown as a dot in the title bar.
    var lastSyncError: String?
    /// How many mutations are waiting in the outbox.
    var pendingOutboxCount = 0

    private var eventTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?

    private init(
        account: Account,
        database: DatabaseManager,
        github: GitHubClient,
        syncEngine: SyncEngine
    ) {
        self.account = account
        self.database = database
        self.github = github
        self.syncEngine = syncEngine
    }

    /// Builds a session for an account whose token is already in the Keychain.
    /// - Parameters:
    ///   - account: The account to sign in as.
    ///   - tokenStore: The Keychain-backed token store.
    ///   - sweepInterval: How often the inbox sweep runs, in seconds.
    /// - Returns: A fully wired session; the caller starts the loops.
    static func make(
        account: Account,
        tokenStore: KeychainTokenStore,
        sweepInterval: TimeInterval
    ) async throws -> SignedInSession {
        let database = try DatabaseManager(url: AppConfig.databaseURL)
        let overrides = (try? await database.agentRegistryOverrides()) ?? []
        let detector = try AgentDetector(extensions: overrides)

        let transport = URLSessionTransport()
        let refresher: TokenRefresher? = account.authKind == .deviceFlow
            && AppConfig.isDeviceFlowConfigured
            ? TokenRefresher(clientID: AppConfig.githubAppClientID, transport: transport)
            : nil

        let github = GitHubClient(
            transport: transport,
            tokenProvider: RefreshingTokenProvider(
                login: account.login,
                store: tokenStore,
                refresher: refresher
            ),
            agentDetector: detector,
            cache: DatabaseConditionalCache(database: database)
        )

        let engine = SyncEngine(
            github: github,
            store: database,
            configuration: SyncConfiguration(sweepInterval: sweepInterval)
        )

        return SignedInSession(
            account: account,
            database: database,
            github: github,
            syncEngine: engine
        )
    }

    /// Starts the sync loops and the event/outbox observers.
    /// - Parameters:
    ///   - settings: Used to decide which events become notifications.
    ///   - notifications: The notification manager.
    ///   - onEvent: Called on the main actor for every sync event, after notification mapping.
    func start(
        settings: AppSettings,
        notifications: NotificationManager,
        onEvent: @escaping @MainActor (SyncEvent) -> Void
    ) {
        guard eventTask == nil else { return }

        let events = syncEngine.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await notifications.present(event, settings: settings)
                self.note(event)
                onEvent(event)
            }
        }

        let stream = database.observePendingOutboxCount()
        outboxTask = Task { [weak self] in
            for await count in stream {
                self?.pendingOutboxCount = count
            }
        }

        Task { [syncEngine] in
            await syncEngine.start()
        }
    }

    /// Runs one sweep and outbox drain now (⌘R).
    func syncNow() async throws {
        isSyncing = true
        defer { isSyncing = false }
        try await syncEngine.syncNow()
        lastSyncedAt = Date()
        lastSyncError = nil
    }

    /// Pushes the outbox without running a full sweep.
    func drainOutbox() async {
        await syncEngine.drainOutbox()
    }

    /// Stops the loops and observers. Called on sign-out and on quit.
    func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        outboxTask?.cancel()
        outboxTask = nil
        await syncEngine.shutdown()
    }

    private func note(_ event: SyncEvent) {
        switch event {
        case .syncFailed(let failure):
            lastSyncError = failure.message
        case .newReviewRequest, .checksFailedOnOwnPR, .prMerged, .prUpdated:
            lastSyncedAt = Date()
            lastSyncError = nil
        case .draftConflict:
            break
        }
    }
}
