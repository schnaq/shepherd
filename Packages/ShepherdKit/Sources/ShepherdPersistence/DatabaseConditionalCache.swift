import Foundation
import GRDB
import ShepherdCore

/// The SQLite-backed ``ConditionalCache`` (ADR 0005): ETags and `Last-Modified` values, plus
/// the bodies they validate, survive app restarts.
///
/// That persistence is the point. A cold start that can answer `304`s costs nothing against
/// the rate limit, so Shepherd can poll on launch without burning budget.
public final class DatabaseConditionalCache: ConditionalCache {
    private let writer: any DatabaseWriter

    /// Creates a cache backed by a database.
    /// - Parameter database: The database manager that owns the connection.
    public init(database: DatabaseManager) {
        self.writer = database.writer
    }

    /// Looks up the stored validators for a request key.
    /// - Parameter key: The cache key — the absolute request URL.
    public func entry(for key: String) async -> ConditionalCacheEntry? {
        let record = try? await writer.read { db in
            try ETagRecord.fetchOne(
                db,
                sql: "SELECT * FROM etags WHERE key = ?",
                arguments: [key]
            )
        }
        guard let record else { return nil }
        return ConditionalCacheEntry(
            etag: record.etag,
            lastModified: record.lastModified,
            payload: record.payload,
            storedAt: Date(timeIntervalSince1970: record.storedAt)
        )
    }

    /// Stores validators for a request key.
    /// - Parameters:
    ///   - entry: The entry to store.
    ///   - key: The cache key.
    public func store(_ entry: ConditionalCacheEntry, for key: String) async {
        let record = ETagRecord(
            key: key,
            etag: entry.etag,
            lastModified: entry.lastModified,
            payload: entry.payload,
            storedAt: entry.storedAt.timeIntervalSince1970
        )
        // A cache write must never take down a sweep: a failure here only costs one 304.
        try? await writer.write { db in
            try record.save(db)
        }
    }

    /// Removes the entry for a request key.
    /// - Parameter key: The cache key.
    public func remove(for key: String) async {
        try? await writer.write { db in
            try db.execute(sql: "DELETE FROM etags WHERE key = ?", arguments: [key])
        }
    }

    /// Removes every entry.
    public func removeAll() async {
        try? await writer.write { db in
            try db.execute(sql: "DELETE FROM etags")
        }
    }
}
