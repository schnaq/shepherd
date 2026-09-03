import Foundation
import GRDB
import ShepherdCore

/// Owns the SQLite database that is Shepherd's source of truth (ADR 0006).
///
/// The UI never reads from GitHub directly: it reads from here, and the sync engine refreshes
/// this database in the background. Consequently the schema is append-only — every change is
/// a new migration, never an edit to an existing one.
public final class DatabaseManager: Sendable {
    /// The underlying GRDB writer. Exposed so the app can build its own observations.
    public let writer: any DatabaseWriter

    /// Opens (or creates) the database at a URL and migrates it.
    ///
    /// A `DatabasePool` is used so that reads never block the sync engine's writes.
    /// - Parameter url: Where the database file lives, typically
    ///   `~/Library/Application Support/Shepherd/shepherd.sqlite`. Missing parent
    ///   directories are created.
    /// - Throws: A `DatabaseError` when the file cannot be opened or migrated.
    public init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        self.writer = pool
        try DatabaseManager.migrator.migrate(pool)
        try DatabaseManager.prepareForUse(pool)
    }

    /// Creates an in-memory database. Used by tests and previews.
    /// - Throws: A `DatabaseError` when the database cannot be created.
    public static func inMemory() throws -> DatabaseManager {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        return try DatabaseManager(writer: queue)
    }

    /// Wraps an already-open writer and migrates it.
    /// - Parameter writer: The writer to adopt.
    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try DatabaseManager.migrator.migrate(writer)
        try DatabaseManager.prepareForUse(writer)
    }

    /// The append-only schema history.
    ///
    /// A computed property rather than a stored one so that no global mutable state has to be
    /// reasoned about under strict concurrency.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: DatabaseSchema.createV1)
        migrator.registerMigration("v2", migrate: DatabaseSchema.addV2)
        migrator.registerMigration("v3", migrate: DatabaseSchema.addV3)
        migrator.registerMigration("v4", migrate: DatabaseSchema.addV4)
        migrator.registerMigration("v5", migrate: DatabaseSchema.addV5)
        return migrator
    }

    /// How long a conditional-request entry may sit unused before it is swept.
    ///
    /// A week is long enough that a returning user still gets free `304`s and short enough
    /// that the table cannot accumulate response bodies for pull requests that are long gone.
    static let etagMaximumAge: TimeInterval = 7 * 24 * 60 * 60
    /// A hard ceiling on the number of cached responses, enforced oldest-first.
    static let etagMaximumRows = 2_000

    /// One-time housekeeping run every time the database is opened.
    ///
    /// Two jobs, both of which have to happen before anything else touches the file:
    /// mutations a crashed run left claimed are handed back to the queue, and the
    /// conditional-request cache is trimmed so it cannot grow without bound.
    /// - Parameter writer: The freshly migrated writer.
    static func prepareForUse(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            try resetInFlightOutboxItems(db)
            try trimConditionalCache(
                db,
                olderThan: Date().addingTimeInterval(-etagMaximumAge),
                maximumRows: etagMaximumRows
            )
        }
    }

    /// Deletes stale and surplus conditional-cache rows.
    ///
    /// The cache stores whole response bodies so a `304` can be answered locally; without a
    /// TTL and a cap, one row per polled URL accumulates forever.
    /// - Parameters:
    ///   - db: The database.
    ///   - cutoff: Entries stored before this moment are deleted.
    ///   - maximumRows: The ceiling; the oldest rows above it are deleted.
    static func trimConditionalCache(
        _ db: Database,
        olderThan cutoff: Date,
        maximumRows: Int
    ) throws {
        try db.execute(
            sql: "DELETE FROM etags WHERE storedAt < ?",
            arguments: [cutoff.timeIntervalSince1970]
        )
        try db.execute(
            sql: """
                DELETE FROM etags WHERE key IN (
                    SELECT key FROM etags ORDER BY storedAt DESC LIMIT -1 OFFSET ?
                )
                """,
            arguments: [max(0, maximumRows)]
        )
    }

    /// Deletes every row of every table, leaving the schema in place.
    ///
    /// Backs the "Sign out & erase" action (ADR 0006) in tests and in the app.
    public func eraseAllData() async throws {
        try await writer.write { db in
            for table in DatabaseSchema.allTables.reversed() {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}

/// The v1 schema.
///
/// Table names follow `docs/ARCHITECTURE.md`; column names are camelCase, which is what GRDB's
/// Codable records expect and what GRDB's own documentation uses. Timestamps are stored as
/// REAL Unix epoch seconds so that they round-trip exactly and sort without parsing.
enum DatabaseSchema {
    /// Every table, in creation order (so reversing gives a safe deletion order).
    static let allTables = [
        "repos",
        "pull_requests",
        "changed_files",
        "viewed_files",
        "review_threads",
        "review_comments",
        "check_runs",
        "review_drafts",
        "draft_comments",
        "sync_state",
        "outbox",
        "etags",
        "agent_registry_overrides",
        "search_index",
        "triage_verdicts",
        "review_snapshots",
    ]

    static func createV1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE repos (
                fullName TEXT PRIMARY KEY NOT NULL,
                owner TEXT NOT NULL,
                name TEXT NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE pull_requests (
                id TEXT PRIMARY KEY NOT NULL,
                repoFullName TEXT NOT NULL REFERENCES repos(fullName) ON DELETE CASCADE,
                number INTEGER NOT NULL,
                title TEXT NOT NULL,
                authorLogin TEXT NOT NULL,
                authorDisplayName TEXT,
                authorAvatarURL TEXT,
                authorKind TEXT NOT NULL,
                agentID TEXT,
                agentDisplayName TEXT,
                agentMatchedBy TEXT,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                isDraft INTEGER NOT NULL DEFAULT 0,
                additions INTEGER NOT NULL DEFAULT 0,
                deletions INTEGER NOT NULL DEFAULT 0,
                changedFiles INTEGER NOT NULL DEFAULT 0,
                headRefName TEXT NOT NULL DEFAULT '',
                headRefOid TEXT NOT NULL DEFAULT '',
                baseRefName TEXT NOT NULL DEFAULT '',
                reviewDecision TEXT,
                checkState TEXT,
                checkTotal INTEGER NOT NULL DEFAULT 0,
                checkSuccess INTEGER NOT NULL DEFAULT 0,
                checkFailure INTEGER NOT NULL DEFAULT 0,
                checkPending INTEGER NOT NULL DEFAULT 0,
                relations TEXT NOT NULL DEFAULT '',
                labels TEXT NOT NULL DEFAULT '[]',
                mergeable TEXT,
                bodyMarkdown TEXT,
                commitsJSON TEXT,
                timelineJSON TEXT,
                detailFetchedAt REAL
            )
            """)
        try db.execute(sql: """
            CREATE UNIQUE INDEX idx_pull_requests_repo_number
            ON pull_requests(repoFullName, number)
            """)
        try db.execute(sql: "CREATE INDEX idx_pull_requests_updatedAt ON pull_requests(updatedAt)")

        try db.execute(sql: """
            CREATE TABLE changed_files (
                prID TEXT NOT NULL REFERENCES pull_requests(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                previousPath TEXT,
                status TEXT NOT NULL,
                additions INTEGER NOT NULL DEFAULT 0,
                deletions INTEGER NOT NULL DEFAULT 0,
                patch TEXT,
                sortIndex INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (prID, path)
            )
            """)

        try db.execute(sql: """
            CREATE TABLE viewed_files (
                prID TEXT NOT NULL,
                path TEXT NOT NULL,
                headRefOid TEXT NOT NULL DEFAULT '',
                viewedAt REAL NOT NULL,
                PRIMARY KEY (prID, path)
            )
            """)

        try db.execute(sql: """
            CREATE TABLE review_threads (
                id TEXT PRIMARY KEY NOT NULL,
                prID TEXT NOT NULL REFERENCES pull_requests(id) ON DELETE CASCADE,
                path TEXT,
                line INTEGER,
                side TEXT NOT NULL DEFAULT 'RIGHT',
                isResolved INTEGER NOT NULL DEFAULT 0,
                isOutdated INTEGER NOT NULL DEFAULT 0,
                sortIndex INTEGER NOT NULL DEFAULT 0
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_review_threads_prID ON review_threads(prID)")

        try db.execute(sql: """
            CREATE TABLE review_comments (
                id TEXT PRIMARY KEY NOT NULL,
                threadID TEXT NOT NULL REFERENCES review_threads(id) ON DELETE CASCADE,
                databaseID INTEGER,
                authorLogin TEXT NOT NULL,
                authorDisplayName TEXT,
                authorAvatarURL TEXT,
                authorKind TEXT NOT NULL,
                agentID TEXT,
                agentDisplayName TEXT,
                agentMatchedBy TEXT,
                bodyMarkdown TEXT NOT NULL DEFAULT '',
                createdAt REAL NOT NULL,
                pendingLocalID TEXT,
                sortIndex INTEGER NOT NULL DEFAULT 0
            )
            """)
        try db.execute(sql: """
            CREATE INDEX idx_review_comments_threadID ON review_comments(threadID)
            """)

        try db.execute(sql: """
            CREATE TABLE check_runs (
                prID TEXT NOT NULL REFERENCES pull_requests(id) ON DELETE CASCADE,
                id TEXT NOT NULL,
                name TEXT NOT NULL,
                status TEXT NOT NULL,
                conclusion TEXT,
                detailsURL TEXT,
                startedAt REAL,
                completedAt REAL,
                summary TEXT,
                sortIndex INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (prID, id)
            )
            """)

        try db.execute(sql: """
            CREATE TABLE review_drafts (
                prID TEXT PRIMARY KEY NOT NULL,
                verdict TEXT,
                summaryBody TEXT NOT NULL DEFAULT '',
                basedOnHeadOid TEXT NOT NULL DEFAULT '',
                updatedAt REAL NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE draft_comments (
                localID TEXT PRIMARY KEY NOT NULL,
                prID TEXT NOT NULL REFERENCES review_drafts(prID) ON DELETE CASCADE,
                path TEXT NOT NULL,
                line INTEGER NOT NULL,
                side TEXT NOT NULL DEFAULT 'RIGHT',
                startLine INTEGER,
                body TEXT NOT NULL DEFAULT '',
                sortIndex INTEGER NOT NULL DEFAULT 0
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_draft_comments_prID ON draft_comments(prID)")

        try db.execute(sql: """
            CREATE TABLE sync_state (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT,
                updatedAt REAL NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE outbox (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                prID TEXT NOT NULL,
                repoFullName TEXT NOT NULL,
                number INTEGER NOT NULL,
                payload BLOB NOT NULL,
                createdAt REAL NOT NULL,
                attemptCount INTEGER NOT NULL DEFAULT 0,
                nextAttemptAt REAL NOT NULL DEFAULT 0,
                lastError TEXT,
                state TEXT NOT NULL DEFAULT 'pending'
            )
            """)
        try db.execute(sql: """
            CREATE INDEX idx_outbox_state_nextAttemptAt ON outbox(state, nextAttemptAt)
            """)

        try db.execute(sql: """
            CREATE TABLE etags (
                key TEXT PRIMARY KEY NOT NULL,
                etag TEXT,
                lastModified TEXT,
                payload BLOB,
                storedAt REAL NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE agent_registry_overrides (
                id TEXT PRIMARY KEY NOT NULL,
                displayName TEXT NOT NULL,
                loginPatterns TEXT NOT NULL DEFAULT '[]',
                branchPrefixes TEXT NOT NULL DEFAULT '[]',
                commitTrailers TEXT NOT NULL DEFAULT '[]',
                isEnabled INTEGER NOT NULL DEFAULT 1
            )
            """)
    }

    /// The v2 additions.
    ///
    /// Append-only, as ``DatabaseManager`` requires: `createV1` is never edited.
    ///
    /// - `etags(storedAt)` gives the age-based sweep and the row cap in
    ///   ``DatabaseManager/trimConditionalCache(_:olderThan:maximumRows:)`` an index to work
    ///   against instead of a full scan on every launch.
    /// - `review_threads.originalLine` carries the line an outdated thread *used* to hang on.
    ///   It exists only so the conversation view can say where the thread came from; `line`
    ///   stays `NULL` when GitHub says the anchor is gone.
    static func addV2(_ db: Database) throws {
        try db.execute(sql: "CREATE INDEX idx_etags_storedAt ON etags(storedAt)")
        try db.execute(sql: "ALTER TABLE review_threads ADD COLUMN originalLine INTEGER")
    }

    /// The v3 addition: the on-device semantic search index (ADR 0019).
    ///
    /// Append-only again — `createV1` and `addV2` are never edited.
    ///
    /// One row per pull request, holding the two hashes that decide whether work has to be
    /// redone, the identifier of the model that produced the vector, and the vector itself as a
    /// `Float32` BLOB. Four decisions are in the DDL rather than in code:
    ///
    /// - **The foreign key onto `pull_requests` with `ON DELETE CASCADE` *is* the pruning.** A
    ///   pull request that leaves the inbox — merged, closed, or past the search's page cap —
    ///   takes its index row with it, in the same transaction as the sweep's `DELETE`, with
    ///   nothing to remember and no second sweep to schedule. `foreignKeysEnabled` is on for
    ///   every connection Shepherd opens, so the cascade is not optional.
    /// - **`prID` is the primary key**, so re-indexing is an upsert and the table cannot grow a
    ///   second opinion about one pull request.
    /// - **`vector` is nullable.** A Mac whose embedding model is unavailable still gets a row:
    ///   the hashes are what stop the lexical corpus being rebuilt from every stored diff on
    ///   every sweep, and they are worth keeping on their own.
    /// - **No index on anything else.** The similarity search is brute force in Swift over a few
    ///   hundred vectors (ADR 0019); there is no vector extension, no ANN structure, and nothing
    ///   here that a query planner could help with.
    static func addV3(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE search_index (
                prID TEXT PRIMARY KEY NOT NULL
                    REFERENCES pull_requests(id) ON DELETE CASCADE,
                documentHash TEXT NOT NULL,
                modelIdentifier TEXT NOT NULL DEFAULT '',
                dimensions INTEGER NOT NULL DEFAULT 0,
                vector BLOB,
                indexedAt REAL NOT NULL
            )
            """)
    }

    /// The v4 addition: one structured-triage verdict per pull request (ADR 0023).
    ///
    /// Append-only once more — `createV1`, `addV2` and `addV3` are never edited.
    ///
    /// Deliberately shaped like `search_index`, because it is the same kind of row about the same
    /// pull request: a locally computed opinion, keyed by node id, invalidated by a document
    /// hash, stamped with the model that produced it, and pruned by the same foreign key. Four
    /// decisions live in the DDL:
    ///
    /// - **`ON DELETE CASCADE` *is* the pruning.** A pull request that leaves the inbox takes its
    ///   verdict with it inside the sweep's own transaction, with nothing to remember and no
    ///   second sweep to schedule. `foreignKeysEnabled` is on for every connection Shepherd
    ///   opens, so the cascade is not optional.
    /// - **`prID` is the primary key**, so re-classifying is an upsert and the table cannot hold
    ///   two opinions about one pull request.
    /// - **`kind` and `risk` are the twin's raw values, `reason` is free text.** They are read
    ///   back through ``ShepherdCore/TriageVerdict``'s lenient decoding, so a row written by a
    ///   Shepherd whose vocabulary was different fails *that one row* rather than the fetch.
    /// - **Nothing here is an approval.** There is no column a rules engine could read as
    ///   permission, and by ADR 0023's rule the bulk-triage, auto-merge and auto-delegation paths
    ///   do not read this table at all: a verdict sorts and filters the inbox and does nothing
    ///   else. `reason` carries the one sentence the "why?" popover shows.
    static func addV4(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE triage_verdicts (
                prID TEXT PRIMARY KEY NOT NULL
                    REFERENCES pull_requests(id) ON DELETE CASCADE,
                documentHash TEXT NOT NULL,
                kind TEXT NOT NULL,
                risk TEXT NOT NULL,
                reason TEXT NOT NULL DEFAULT '',
                modelIdentifier TEXT NOT NULL DEFAULT '',
                classifiedAt REAL NOT NULL
            )
            """)
    }

    /// The v5 addition: the diff a review was written against (ADR 0028).
    ///
    /// Append-only once more — `createV1`, `addV2`, `addV3` and `addV4` are never edited. The
    /// agent-fleet plan sketched one shared `v5` for two features; the split is deliberate and
    /// recorded in ADR 0028: this migration is the review snapshots, and the track-record
    /// tables of that plan's feature B become `v6`. A migration is an identifier in
    /// `grdb_migrations`, so two features sharing one would mean neither could ship first.
    ///
    /// Four decisions live in the DDL:
    ///
    /// - **The primary key is `(prID, reviewedHeadOid)`.** One row per reviewed head, so a
    ///   second review of the same commit overwrites its own row while a review of a *new* head
    ///   adds one — which is what makes `COUNT(*)` the number of rounds the inbox row shows.
    /// - **`ON DELETE CASCADE` *is* the pruning**, as in `search_index` and `triage_verdicts`: a
    ///   pull request that leaves the inbox takes its snapshots with it inside the sweep's own
    ///   transaction. `foreignKeysEnabled` is on for every connection Shepherd opens.
    /// - **`filesJSON` is a BLOB holding the encoded `changed_files` rows, patches included.**
    ///   Not a second `changed_files`-shaped table: nothing queries inside a snapshot, the whole
    ///   value is read at once by the interdiff, and the point of the snapshot is that it keeps
    ///   the patches a force-push has since made unfetchable.
    /// - **`reviewedAt` is `DATETIME` but holds Unix epoch seconds**, like every other timestamp
    ///   in this schema (`DATETIME` has NUMERIC affinity, so the `REAL` is stored as written).
    ///   The column type documents what the number means; the value stays sortable without
    ///   parsing.
    static func addV5(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE review_snapshots (
                prID TEXT NOT NULL REFERENCES pull_requests(id) ON DELETE CASCADE,
                reviewedHeadOid TEXT NOT NULL,
                reviewedAt DATETIME NOT NULL,
                filesJSON BLOB NOT NULL,
                PRIMARY KEY (prID, reviewedHeadOid)
            )
            """)
    }
}
