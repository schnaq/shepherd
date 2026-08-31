import Foundation

/// One cached HTTP response, keyed by request URL, used to issue conditional requests.
///
/// GitHub does not charge a `304 Not Modified` against the primary rate limit when the
/// request carries a valid `Authorization` header, which is the main reason Shepherd can poll
/// at all (ADR 0005).
public struct ConditionalCacheEntry: Sendable, Codable, Hashable {
    /// The `ETag` header of the cached response, replayed as `If-None-Match`.
    public var etag: String?
    /// The `Last-Modified` header of the cached response, replayed as `If-Modified-Since`.
    public var lastModified: String?
    /// The response body, so a `304` can be answered from cache.
    public var payload: Data?
    /// When the entry was stored.
    public var storedAt: Date

    /// Creates a cache entry.
    /// - Parameters:
    ///   - etag: The response `ETag`, if any.
    ///   - lastModified: The response `Last-Modified`, if any.
    ///   - payload: The response body, if it should be replayable.
    ///   - storedAt: When the entry was stored. Defaults to now.
    public init(
        etag: String? = nil,
        lastModified: String? = nil,
        payload: Data? = nil,
        storedAt: Date = Date()
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.payload = payload
        self.storedAt = storedAt
    }

    /// Whether the entry carries anything that can be used for a conditional request.
    public var isUsable: Bool { etag != nil || lastModified != nil }
}

/// Storage for conditional-request validators.
///
/// The protocol lives in `ShepherdCore` so that `GitHubKit` can depend on it without
/// depending on `ShepherdPersistence`, while the SQLite-backed implementation lives in
/// `ShepherdPersistence` (see `docs/ARCHITECTURE.md`).
public protocol ConditionalCache: Sendable {
    /// Looks up the cached validators for a request key.
    /// - Parameter key: The cache key, conventionally the absolute request URL.
    func entry(for key: String) async -> ConditionalCacheEntry?

    /// Stores validators for a request key, replacing any previous entry.
    /// - Parameters:
    ///   - entry: The entry to store.
    ///   - key: The cache key, conventionally the absolute request URL.
    func store(_ entry: ConditionalCacheEntry, for key: String) async

    /// Removes the entry for a request key, if present.
    /// - Parameter key: The cache key.
    func remove(for key: String) async

    /// Removes every entry.
    func removeAll() async
}

/// A process-local ``ConditionalCache``. Used by tests and as a default when no persistent
/// cache is wired up.
public actor InMemoryConditionalCache: ConditionalCache {
    private var storage: [String: ConditionalCacheEntry] = [:]

    /// Creates an empty cache.
    public init() {}

    /// Looks up the cached validators for a request key.
    /// - Parameter key: The cache key.
    public func entry(for key: String) async -> ConditionalCacheEntry? {
        storage[key]
    }

    /// Stores validators for a request key.
    /// - Parameters:
    ///   - entry: The entry to store.
    ///   - key: The cache key.
    public func store(_ entry: ConditionalCacheEntry, for key: String) async {
        storage[key] = entry
    }

    /// Removes the entry for a request key.
    /// - Parameter key: The cache key.
    public func remove(for key: String) async {
        storage.removeValue(forKey: key)
    }

    /// Removes every entry.
    public func removeAll() async {
        storage.removeAll()
    }

    /// The number of entries currently held. Intended for tests.
    public var count: Int { storage.count }
}
