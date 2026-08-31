import Foundation
import GRDB
import ShepherdCore

// MARK: - Column value coding

/// Encodes and decodes the handful of values that do not have a natural SQLite column type.
///
/// All of it is deliberately explicit: no reflection, no "clever" generic bridge. When a
/// column changes, exactly one function changes with it.
enum ColumnCoding {
    /// Flattens an ``ActorKind`` into its four columns.
    static func encodeActorKind(
        _ kind: ActorKind
    ) -> (kind: String, agentID: String?, agentDisplayName: String?, agentMatchedBy: String?) {
        switch kind {
        case .human:
            return ("human", nil, nil, nil)
        case .bot:
            return ("bot", nil, nil, nil)
        case .agent(let identity):
            return ("agent", identity.id, identity.displayName, identity.matchedBy.rawValue)
        }
    }

    /// Rebuilds an ``ActorKind`` from its four columns.
    ///
    /// An `"agent"` row whose identity columns are missing degrades to ``ActorKind/bot``
    /// rather than failing the fetch: provenance is cosmetic and must never break the inbox.
    static func decodeActorKind(
        kind: String,
        agentID: String?,
        agentDisplayName: String?,
        agentMatchedBy: String?
    ) -> ActorKind {
        switch kind {
        case "agent":
            guard let agentID, let agentDisplayName else { return .bot }
            return .agent(
                AgentIdentity(
                    id: agentID,
                    displayName: agentDisplayName,
                    matchedBy: AgentMatchSignal(rawValue: agentMatchedBy ?? "") ?? .login
                )
            )
        case "bot":
            return .bot
        default:
            return .human
        }
    }

    /// Encodes a relation set as a stable, comma-separated list.
    static func encodeRelations(_ relations: Set<Relation>) -> String {
        relations.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Decodes a comma-separated relation list, skipping values this version does not know.
    static func decodeRelations(_ raw: String) -> Set<Relation> {
        Set(raw.split(separator: ",").compactMap { Relation(rawValue: String($0)) })
    }

    /// Encodes a value as a JSON string column.
    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a JSON string column, returning `nil` on any problem.
    static func decodeJSON<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let string, !string.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: Data(string.utf8))
    }
}

// MARK: - Records

/// A row of `repos`.
struct RepoRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "repos"

    var fullName: String
    var owner: String
    var name: String

    init(_ repo: RepoRef) {
        self.fullName = repo.fullName
        self.owner = repo.owner
        self.name = repo.name
    }

    var repoRef: RepoRef { RepoRef(owner: owner, name: name) }
}

/// A row of `pull_requests`.
///
/// Holds the inbox row plus the two detail collections that have no table of their own
/// (commits and the condensed timeline), stored as JSON so that the table list in
/// `docs/ARCHITECTURE.md` stays exactly as specified.
struct PullRequestRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pull_requests"

    var id: String
    var repoFullName: String
    var number: Int
    var title: String
    var authorLogin: String
    var authorDisplayName: String?
    var authorAvatarURL: String?
    var authorKind: String
    var agentID: String?
    var agentDisplayName: String?
    var agentMatchedBy: String?
    var createdAt: Double
    var updatedAt: Double
    var isDraft: Bool
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var headRefName: String
    var headRefOid: String
    var baseRefName: String
    var reviewDecision: String?
    var checkState: String?
    var checkTotal: Int
    var checkSuccess: Int
    var checkFailure: Int
    var checkPending: Int
    var relations: String
    var labels: String
    var mergeable: String?
    var bodyMarkdown: String?
    var commitsJSON: String?
    var timelineJSON: String?
    var detailFetchedAt: Double?

    /// Builds a row from an inbox summary, preserving any detail columns already stored.
    init(summary: PullRequestSummary, existing: PullRequestRecord? = nil) {
        let kind = ColumnCoding.encodeActorKind(summary.author.kind)
        self.id = summary.id
        self.repoFullName = summary.repo.fullName
        self.number = summary.number
        self.title = summary.title
        self.authorLogin = summary.author.login
        self.authorDisplayName = summary.author.displayName
        self.authorAvatarURL = summary.author.avatarURL?.absoluteString
        self.authorKind = kind.kind
        self.agentID = kind.agentID
        self.agentDisplayName = kind.agentDisplayName
        self.agentMatchedBy = kind.agentMatchedBy
        self.createdAt = summary.createdAt.timeIntervalSince1970
        self.updatedAt = summary.updatedAt.timeIntervalSince1970
        self.isDraft = summary.isDraft
        self.additions = summary.additions
        self.deletions = summary.deletions
        self.changedFiles = summary.changedFiles
        self.headRefName = summary.headRefName
        self.headRefOid = summary.headRefOid
        self.baseRefName = summary.baseRefName
        self.reviewDecision = summary.reviewDecision?.rawValue
        self.checkState = summary.checkRollup?.state.rawValue
        self.checkTotal = summary.checkRollup?.total ?? 0
        self.checkSuccess = summary.checkRollup?.successCount ?? 0
        self.checkFailure = summary.checkRollup?.failureCount ?? 0
        self.checkPending = summary.checkRollup?.pendingCount ?? 0
        self.relations = ColumnCoding.encodeRelations(summary.myRelation)
        self.labels = ColumnCoding.encodeJSON(summary.labels)
        self.mergeable = summary.mergeable?.rawValue
        self.bodyMarkdown = existing?.bodyMarkdown
        self.commitsJSON = existing?.commitsJSON
        self.timelineJSON = existing?.timelineJSON
        self.detailFetchedAt = existing?.detailFetchedAt
    }

    /// Rebuilds the inbox row.
    var summary: PullRequestSummary {
        let rollup: CheckRollup? = checkState
            .flatMap { CheckRollup.State(rawValue: $0) }
            .map { state in
                CheckRollup(
                    state: state,
                    total: checkTotal,
                    successCount: checkSuccess,
                    failureCount: checkFailure,
                    pendingCount: checkPending
                )
            }
        let author = ShepherdCore.Actor(
            login: authorLogin,
            displayName: authorDisplayName,
            avatarURL: authorAvatarURL.flatMap { URL(string: $0) },
            kind: ColumnCoding.decodeActorKind(
                kind: authorKind,
                agentID: agentID,
                agentDisplayName: agentDisplayName,
                agentMatchedBy: agentMatchedBy
            )
        )
        return PullRequestSummary(
            id: id,
            repo: RepoRef.parse(fullName: repoFullName)
                ?? RepoRef(owner: repoFullName, name: repoFullName),
            number: number,
            title: title,
            author: author,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            createdAt: Date(timeIntervalSince1970: createdAt),
            isDraft: isDraft,
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles,
            headRefName: headRefName,
            headRefOid: headRefOid,
            baseRefName: baseRefName,
            reviewDecision: reviewDecision.flatMap { ReviewDecision(rawValue: $0) },
            checkRollup: rollup,
            myRelation: ColumnCoding.decodeRelations(relations),
            labels: ColumnCoding.decodeJSON([String].self, from: labels) ?? [],
            mergeable: mergeable.flatMap { Mergeable(rawValue: $0) }
        )
    }

    /// The stored commit list, or an empty list when no detail fetch has happened yet.
    var commits: [CommitInfo] {
        ColumnCoding.decodeJSON([CommitInfo].self, from: commitsJSON) ?? []
    }

    /// The stored timeline, or an empty list when no detail fetch has happened yet.
    var timeline: [TimelineEvent] {
        ColumnCoding.decodeJSON([TimelineEvent].self, from: timelineJSON) ?? []
    }
}

/// A row of `changed_files`.
struct ChangedFileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "changed_files"

    var prID: String
    var path: String
    var previousPath: String?
    var status: String
    var additions: Int
    var deletions: Int
    var patch: String?
    var sortIndex: Int

    init(prID: String, file: ChangedFile, sortIndex: Int) {
        self.prID = prID
        self.path = file.path
        self.previousPath = file.previousPath
        self.status = file.status.rawValue
        self.additions = file.additions
        self.deletions = file.deletions
        self.patch = file.patch
        self.sortIndex = sortIndex
    }

    /// Rebuilds the model. Viewed state lives in its own table and is applied by the caller.
    var changedFile: ChangedFile {
        ChangedFile(
            path: path,
            previousPath: previousPath,
            status: FileChangeStatus(rawValue: status) ?? .modified,
            additions: additions,
            deletions: deletions,
            patch: patch,
            isViewed: false
        )
    }
}

/// A row of `viewed_files`.
struct ViewedFileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "viewed_files"

    var prID: String
    var path: String
    var headRefOid: String
    var viewedAt: Double
}

/// A row of `review_threads`.
struct ReviewThreadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "review_threads"

    var id: String
    var prID: String
    var path: String?
    var line: Int?
    var side: String
    var isResolved: Bool
    var isOutdated: Bool
    var sortIndex: Int

    init(prID: String, thread: ReviewThread, sortIndex: Int) {
        self.id = thread.id
        self.prID = prID
        self.path = thread.path
        self.line = thread.line
        self.side = thread.side.rawValue
        self.isResolved = thread.isResolved
        self.isOutdated = thread.isOutdated
        self.sortIndex = sortIndex
    }

    /// Rebuilds the model with the comments the caller fetched separately.
    func reviewThread(comments: [ReviewComment]) -> ReviewThread {
        ReviewThread(
            id: id,
            path: path,
            line: line,
            side: DiffSide(rawValue: side) ?? .right,
            isResolved: isResolved,
            isOutdated: isOutdated,
            comments: comments
        )
    }
}

/// A row of `review_comments`.
struct ReviewCommentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "review_comments"

    var id: String
    var threadID: String
    var databaseID: Int?
    var authorLogin: String
    var authorDisplayName: String?
    var authorAvatarURL: String?
    var authorKind: String
    var agentID: String?
    var agentDisplayName: String?
    var agentMatchedBy: String?
    var bodyMarkdown: String
    var createdAt: Double
    var pendingLocalID: String?
    var sortIndex: Int

    init(threadID: String, comment: ReviewComment, sortIndex: Int) {
        let kind = ColumnCoding.encodeActorKind(comment.author.kind)
        self.id = comment.id
        self.threadID = threadID
        self.databaseID = comment.databaseID
        self.authorLogin = comment.author.login
        self.authorDisplayName = comment.author.displayName
        self.authorAvatarURL = comment.author.avatarURL?.absoluteString
        self.authorKind = kind.kind
        self.agentID = kind.agentID
        self.agentDisplayName = kind.agentDisplayName
        self.agentMatchedBy = kind.agentMatchedBy
        self.bodyMarkdown = comment.bodyMarkdown
        self.createdAt = comment.createdAt.timeIntervalSince1970
        self.pendingLocalID = comment.pendingLocalID?.uuidString
        self.sortIndex = sortIndex
    }

    /// Rebuilds the model.
    var reviewComment: ReviewComment {
        ReviewComment(
            id: id,
            databaseID: databaseID,
            author: ShepherdCore.Actor(
                login: authorLogin,
                displayName: authorDisplayName,
                avatarURL: authorAvatarURL.flatMap { URL(string: $0) },
                kind: ColumnCoding.decodeActorKind(
                    kind: authorKind,
                    agentID: agentID,
                    agentDisplayName: agentDisplayName,
                    agentMatchedBy: agentMatchedBy
                )
            ),
            bodyMarkdown: bodyMarkdown,
            createdAt: Date(timeIntervalSince1970: createdAt),
            pendingLocalID: pendingLocalID.flatMap { UUID(uuidString: $0) }
        )
    }
}

/// A row of `check_runs`.
struct CheckRunRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "check_runs"

    var prID: String
    var id: String
    var name: String
    var status: String
    var conclusion: String?
    var detailsURL: String?
    var startedAt: Double?
    var completedAt: Double?
    var summary: String?
    var sortIndex: Int

    init(prID: String, run: CheckRun, sortIndex: Int) {
        self.prID = prID
        self.id = run.id
        self.name = run.name
        self.status = run.status.rawValue
        self.conclusion = run.conclusion?.rawValue
        self.detailsURL = run.detailsURL?.absoluteString
        self.startedAt = run.startedAt?.timeIntervalSince1970
        self.completedAt = run.completedAt?.timeIntervalSince1970
        self.summary = run.summary
        self.sortIndex = sortIndex
    }

    /// Rebuilds the model.
    var checkRun: CheckRun {
        CheckRun(
            id: id,
            name: name,
            status: CheckRun.Status(rawValue: status) ?? .unknown,
            conclusion: conclusion.flatMap { CheckRun.Conclusion(rawValue: $0) },
            detailsURL: detailsURL.flatMap { URL(string: $0) },
            startedAt: startedAt.map { Date(timeIntervalSince1970: $0) },
            completedAt: completedAt.map { Date(timeIntervalSince1970: $0) },
            summary: summary
        )
    }
}

/// A row of `review_drafts`.
struct ReviewDraftRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "review_drafts"

    var prID: String
    var verdict: String?
    var summaryBody: String
    var basedOnHeadOid: String
    var updatedAt: Double

    init(draft: ReviewDraft) {
        self.prID = draft.prID
        self.verdict = draft.verdict?.rawValue
        self.summaryBody = draft.summaryBody
        self.basedOnHeadOid = draft.basedOnHeadOid
        self.updatedAt = draft.updatedAt.timeIntervalSince1970
    }

    /// Rebuilds the model with the comments the caller fetched separately.
    func reviewDraft(comments: [DraftComment]) -> ReviewDraft {
        ReviewDraft(
            prID: prID,
            verdict: verdict.flatMap { ReviewVerdict(rawValue: $0) },
            summaryBody: summaryBody,
            comments: comments,
            basedOnHeadOid: basedOnHeadOid,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}

/// A row of `draft_comments`.
struct DraftCommentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "draft_comments"

    var localID: String
    var prID: String
    var path: String
    var line: Int
    var side: String
    var startLine: Int?
    var body: String
    var sortIndex: Int

    init(prID: String, comment: DraftComment, sortIndex: Int) {
        self.localID = comment.localID.uuidString
        self.prID = prID
        self.path = comment.path
        self.line = comment.line
        self.side = comment.side.rawValue
        self.startLine = comment.startLine
        self.body = comment.body
        self.sortIndex = sortIndex
    }

    /// Rebuilds the model.
    var draftComment: DraftComment {
        DraftComment(
            localID: UUID(uuidString: localID) ?? UUID(),
            path: path,
            line: line,
            side: DiffSide(rawValue: side) ?? .right,
            startLine: startLine,
            body: body
        )
    }
}

/// A row of `sync_state`.
struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_state"

    var key: String
    var value: String?
    var updatedAt: Double
}

/// A row of `outbox`.
struct OutboxRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "outbox"

    var id: String
    var kind: String
    var prID: String
    var repoFullName: String
    var number: Int
    var payload: Data
    var createdAt: Double
    var attemptCount: Int
    var nextAttemptAt: Double
    var lastError: String?
    var state: String

    init(item: OutboxItem) throws {
        self.id = item.id.uuidString
        self.kind = item.action.kind
        self.prID = item.prID
        self.repoFullName = item.repo.fullName
        self.number = item.number
        self.payload = try JSONEncoder().encode(item.action)
        self.createdAt = item.createdAt.timeIntervalSince1970
        self.attemptCount = item.attemptCount
        self.nextAttemptAt = item.nextAttemptAt.timeIntervalSince1970
        self.lastError = item.lastError
        self.state = item.state.rawValue
    }

    /// Rebuilds the model.
    /// - Throws: A decoding error when the stored payload cannot be read back.
    func outboxItem() throws -> OutboxItem {
        let action = try JSONDecoder().decode(OutboxAction.self, from: payload)
        return OutboxItem(
            id: UUID(uuidString: id) ?? UUID(),
            prID: prID,
            repo: RepoRef.parse(fullName: repoFullName)
                ?? RepoRef(owner: repoFullName, name: repoFullName),
            number: number,
            action: action,
            createdAt: Date(timeIntervalSince1970: createdAt),
            attemptCount: attemptCount,
            nextAttemptAt: Date(timeIntervalSince1970: nextAttemptAt),
            lastError: lastError,
            state: OutboxState(rawValue: state) ?? .pending
        )
    }
}

/// A row of `etags`.
struct ETagRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "etags"

    var key: String
    var etag: String?
    var lastModified: String?
    var payload: Data?
    var storedAt: Double
}

/// A row of `agent_registry_overrides`.
struct AgentOverrideRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agent_registry_overrides"

    var id: String
    var displayName: String
    var loginPatterns: String
    var branchPrefixes: String
    var commitTrailers: String
    var isEnabled: Bool

    init(entry: AgentRegistryEntry, isEnabled: Bool = true) {
        self.id = entry.id
        self.displayName = entry.displayName
        self.loginPatterns = ColumnCoding.encodeJSON(entry.loginPatterns)
        self.branchPrefixes = ColumnCoding.encodeJSON(entry.branchPrefixes)
        self.commitTrailers = ColumnCoding.encodeJSON(entry.commitTrailers)
        self.isEnabled = isEnabled
    }

    /// Rebuilds the registry entry.
    var registryEntry: AgentRegistryEntry {
        AgentRegistryEntry(
            id: id,
            displayName: displayName,
            loginPatterns: ColumnCoding.decodeJSON([String].self, from: loginPatterns) ?? [],
            branchPrefixes: ColumnCoding.decodeJSON([String].self, from: branchPrefixes) ?? [],
            commitTrailers: ColumnCoding.decodeJSON([String].self, from: commitTrailers) ?? []
        )
    }
}
