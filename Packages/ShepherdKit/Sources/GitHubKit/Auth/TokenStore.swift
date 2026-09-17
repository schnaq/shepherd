import Foundation

/// A GitHub credential: the access token plus, for GitHub App user-to-server tokens, the
/// refresh token and expiry needed to renew it (ADR 0004).
///
/// Fine-grained personal access tokens have no refresh token and no expiry Shepherd can see,
/// so both optional fields are `nil` for them.
public struct TokenSet: Sendable, Hashable, Codable {
    /// The bearer token sent as `Authorization: Bearer …`.
    public var accessToken: String
    /// The refresh token, for GitHub App user-to-server tokens.
    public var refreshToken: String?
    /// When ``accessToken`` expires, when the server told us.
    public var expiresAt: Date?
    /// When ``refreshToken`` expires, when the server told us.
    public var refreshTokenExpiresAt: Date?
    /// The OAuth scopes the token carries, when the server reported them.
    public var scopes: [String]

    /// Creates a token set.
    /// - Parameters:
    ///   - accessToken: The bearer token.
    ///   - refreshToken: The refresh token, if any.
    ///   - expiresAt: When the access token expires, if known.
    ///   - refreshTokenExpiresAt: When the refresh token expires, if known.
    ///   - scopes: The scopes the token carries.
    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        refreshTokenExpiresAt: Date? = nil,
        scopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scopes = scopes
    }

    /// Whether the access token is expired (or about to be) at a given moment.
    /// - Parameters:
    ///   - date: The moment to test. Defaults to now.
    ///   - leeway: How long before the real expiry the token counts as expired. Defaults to
    ///     60 seconds so a request never starts with a token that dies mid-flight.
    /// - Returns: `true` when the token should be refreshed before use. Tokens without a
    ///   known expiry (personal access tokens) never report as expired.
    public func isExpired(at date: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return date.addingTimeInterval(leeway) >= expiresAt
    }

    /// Whether this token can be renewed without user interaction.
    public var isRefreshable: Bool { refreshToken != nil }
}

/// Storage for ``TokenSet`` values, keyed by GitHub login.
///
/// `GitHubKit` never touches the Keychain itself: the app target provides the Keychain-backed
/// implementation (ADR 0004), and tests use ``InMemoryTokenStore``.
public protocol TokenStore: Sendable {
    /// Reads the stored credential for a login.
    /// - Parameter login: The GitHub login the credential belongs to.
    func token(for login: String) async throws -> TokenSet?

    /// Stores (or replaces) the credential for a login.
    /// - Parameters:
    ///   - token: The credential to store.
    ///   - login: The GitHub login the credential belongs to.
    func setToken(_ token: TokenSet, for login: String) async throws

    /// Deletes the credential for a login, if present.
    /// - Parameter login: The GitHub login the credential belongs to.
    func deleteToken(for login: String) async throws
}

/// A process-local ``TokenStore`` used by tests and previews.
///
/// Never use this in the app: credentials must not outlive the Keychain (ADR 0004).
public actor InMemoryTokenStore: TokenStore {
    private var storage: [String: TokenSet]

    /// Creates a store.
    /// - Parameter initial: Credentials to seed the store with, keyed by login.
    public init(initial: [String: TokenSet] = [:]) {
        self.storage = initial
    }

    /// Reads the stored credential for a login.
    /// - Parameter login: The GitHub login.
    public func token(for login: String) async throws -> TokenSet? {
        storage[login]
    }

    /// Stores the credential for a login.
    /// - Parameters:
    ///   - token: The credential.
    ///   - login: The GitHub login.
    public func setToken(_ token: TokenSet, for login: String) async throws {
        storage[login] = token
    }

    /// Deletes the credential for a login.
    /// - Parameter login: The GitHub login.
    public func deleteToken(for login: String) async throws {
        storage.removeValue(forKey: login)
    }

    /// Every login that currently has a credential. Intended for tests.
    public var storedLogins: [String] { storage.keys.sorted() }
}

/// Supplies the bearer token for outgoing requests.
///
/// Keeping this behind a protocol lets ``GitHubClient`` stay ignorant of *where* the token
/// comes from — Keychain, in-memory store, or a literal string in a test.
public protocol AccessTokenProviding: Sendable {
    /// Returns a token that is valid right now, refreshing it if necessary.
    /// - Throws: ``GitHubError/missingToken(login:)`` when no credential is available.
    func accessToken() async throws -> String
}

/// An ``AccessTokenProviding`` that always returns the same token — personal access tokens,
/// and tests.
public struct StaticTokenProvider: AccessTokenProviding {
    private let token: String

    /// Creates a provider.
    /// - Parameter token: The token to return for every request.
    public init(_ token: String) {
        self.token = token
    }

    /// Returns the fixed token.
    public func accessToken() async throws -> String { token }
}

/// An ``AccessTokenProviding`` that reads from a ``TokenStore`` and transparently refreshes
/// expired GitHub App tokens through a ``TokenRefresher``.
public actor RefreshingTokenProvider: AccessTokenProviding {
    private let login: String
    private let store: any TokenStore
    private let refresher: TokenRefresher?
    private let now: @Sendable () -> Date

    /// The last credential read out of the store, and when it was read.
    ///
    /// The store is the macOS Keychain, and `accessToken()` is called once per HTTP request:
    /// five facet searches a sweep, up to five concurrent detail fetches, every outbox drain.
    /// That was a `SecItemCopyMatching` every time — hundreds an hour for a credential that
    /// changes about twice a year. While the item's ACL has not been answered with *Always
    /// Allow* yet, every one of those reads is a chance for macOS to put up the Keychain
    /// password dialog, which is what "Shepherd keeps asking for my Keychain password" is.
    ///
    /// A time-to-live rather than "cache until it changes", because nothing tells this actor
    /// when the item is written from outside it — a settings document arriving from another Mac
    /// carries a token (ADR 0014), and so does signing in again. A minute keeps the reads down
    /// by three orders of magnitude and keeps the window in which this actor can be holding a
    /// credential someone else replaced down to a minute.
    private var cached: (token: TokenSet, readAt: Date)?

    /// How long a credential read from the store is reused before it is read again.
    private static let cacheTTL: TimeInterval = 60

    /// The renewal currently in flight, if any.
    ///
    /// GitHub App refresh tokens are **single-use and rotate**: the first refresh invalidates
    /// the token it was called with. Five concurrent detail fetches all noticing the same
    /// expiry used to POST the same refresh token five times — one winner, four
    /// `tokenRefreshFailed`, and a store that could end up holding the loser's stale pair.
    /// Everyone now waits on the same task.
    private var refreshTask: Task<TokenSet, Error>?

    /// Creates a provider.
    /// - Parameters:
    ///   - login: The GitHub login whose credential to use.
    ///   - store: Where credentials live.
    ///   - refresher: The refresher to use for expiring tokens, or `nil` for personal access
    ///     tokens.
    ///   - now: Clock injection point for tests.
    public init(
        login: String,
        store: any TokenStore,
        refresher: TokenRefresher? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.login = login
        self.store = store
        self.refresher = refresher
        self.now = now
    }

    /// Returns a currently-valid access token, refreshing it first when needed.
    /// - Throws: ``GitHubError/missingToken(login:)`` when the store is empty for this login,
    ///   or ``GitHubError/tokenRefreshFailed(message:)`` when renewal fails.
    public func accessToken() async throws -> String {
        guard let stored = try await currentToken() else {
            throw GitHubError.missingToken(login: login)
        }
        guard stored.isExpired(at: now()), stored.refreshToken != nil, let refresher else {
            return stored.accessToken
        }
        return try await refreshedToken(using: refresher).accessToken
    }

    /// The stored credential, from ``cached`` while it is fresh enough and from the store
    /// otherwise.
    ///
    /// An *expired* credential is never served from the cache: the expiry is the one thing the
    /// caller above acts on, and answering it from memory would keep a refresh from happening.
    private func currentToken() async throws -> TokenSet? {
        let moment = now()
        if let cached, moment.timeIntervalSince(cached.readAt) < Self.cacheTTL,
           !cached.token.isExpired(at: moment) {
            return cached.token
        }
        let stored = try await store.token(for: login)
        cached = stored.map { ($0, moment) }
        return stored
    }

    /// Renews the credential, at most once no matter how many callers ask at the same time.
    private func refreshedToken(using refresher: TokenRefresher) async throws -> TokenSet {
        while true {
            if let inFlight = refreshTask {
                return try await inFlight.value
            }

            // Re-read, past the cache: this call may have been suspended on its *first* store
            // read while another one refreshed and stored a perfectly good token, and the whole
            // point of arriving here is that what we last read is no longer good.
            cached = nil
            guard let current = try await currentToken() else {
                throw GitHubError.missingToken(login: login)
            }

            // Nothing below this line suspends before `refreshTask` is assigned, so no second
            // caller can slip past the check above and start a competing refresh.
            if refreshTask != nil { continue }
            guard current.isExpired(at: now()), let refreshToken = current.refreshToken else {
                return current
            }
            let login = self.login
            let store = self.store
            let task = Task<TokenSet, Error> {
                let refreshed = try await refresher.refresh(refreshToken: refreshToken)
                try await store.setToken(refreshed, for: login)
                return refreshed
            }
            refreshTask = task
            defer { refreshTask = nil }
            let refreshed = try await task.value
            // What was just written *is* the current credential, so remember it rather than
            // going back to the Keychain for a value this actor produced.
            cached = (refreshed, now())
            return refreshed
        }
    }
}
