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

    /// Encodes an issue-relation set as a stable, comma-separated list.
    ///
    /// A second function rather than a generic over `RawRepresentable`: the two relation sets are
    /// different vocabularies stored in two different tables, and one shared helper would make a
    /// pull-request relation decodable out of an issue's column.
    static func encodeIssueRelations(_ relations: Set<IssueRelation>) -> String {
        relations.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Decodes a comma-separated issue-relation list, skipping values this version does not know.
    static func decodeIssueRelations(_ raw: String) -> Set<IssueRelation> {
        Set(raw.split(separator: ",").compactMap { IssueRelation(rawValue: String($0)) })
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
    /// `MergeStateStatus.rawValue`, or `NULL` when GitHub did not send one (v9, ADR 0041).
    var mergeStateStatus: String?
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
        self.mergeStateStatus = summary.mergeStateStatus?.rawValue
        self.bodyMarkdown = existing?.bodyMarkdown
        self.commitsJSON = existing?.commitsJSON
        self.timelineJSON = existing?.timelineJSON
        self.detailFetchedAt = existing?.detailFetchedAt
    }

    /// Keeps an agent identity a detail fetch read from the commit trailers when a sweep, which
    /// cannot read them, would otherwise overwrite it.
    ///
    /// The search query carries no commit messages, so for a Claude-written pull request on an
    /// ordinary branch the sweep says "human" and the detail fetch says "Claude Code". Written
    /// through as they arrive, the row changed inbox group on every detail load and changed back
    /// on the next sweep — and every flip moved the triage document's hash, so the on-device
    /// model classified the same pull request again each time. A pull request's commits do not
    /// un-author themselves, so the trailer is sticky; a sweep that detects an agent *itself*
    /// (by login or branch) is fresher evidence and still wins.
    /// - Parameter existing: The row as the database held it before this sweep.
    mutating func keepTrailerAgent(from existing: PullRequestRecord) {
        guard existing.agentMatchedBy == AgentMatchSignal.commitTrailer.rawValue,
              authorKind != "agent"
        else { return }
        authorKind = existing.authorKind
        agentID = existing.agentID
        agentDisplayName = existing.agentDisplayName
        agentMatchedBy = existing.agentMatchedBy
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
            mergeable: mergeable.flatMap { Mergeable(rawValue: $0) },
            mergeStateStatus: mergeStateStatus.flatMap { MergeStateStatus(rawValue: $0) }
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
    var originalLine: Int?
    var side: String
    var isResolved: Bool
    var isOutdated: Bool
    var sortIndex: Int

    init(prID: String, thread: ReviewThread, sortIndex: Int) {
        self.id = thread.id
        self.prID = prID
        self.path = thread.path
        self.line = thread.line
        self.originalLine = thread.originalLine
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
            originalLine: originalLine,
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
    /// Added in v8 (ADR 0022, 2026-09-22 amendment); `nil` on every row written before it.
    var lastErrorCode: String?
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
        self.lastErrorCode = item.lastErrorCode
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
            lastErrorCode: lastErrorCode,
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

/// A row of `search_index` (ADR 0019).
///
/// The vector travels as a `Data` property, which GRDB stores as a BLOB — the same treatment
/// ``OutboxRecord``'s payload gets. `dimensions` is stored alongside it even though it is
/// derivable from the blob's length: a row whose blob was truncated by a half-written transaction
/// is then detectable rather than silently decoding as a shorter vector that would still produce
/// a plausible cosine.
struct SearchIndexRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "search_index"

    var prID: String
    var documentHash: String
    var modelIdentifier: String
    var dimensions: Int
    var vector: Data?
    var indexedAt: Double

    init(entry: SearchIndexEntry) {
        self.prID = entry.prID
        self.documentHash = entry.documentHash
        self.modelIdentifier = entry.modelIdentifier
        self.dimensions = entry.vector?.dimensions ?? 0
        self.vector = entry.vector?.data
        self.indexedAt = entry.indexedAt.timeIntervalSince1970
    }

    /// Rebuilds the entry.
    ///
    /// A blob that does not decode, or decodes to a different number of dimensions than the row
    /// claims, yields an entry with **no** vector rather than a failed fetch: the index is a
    /// cache, so the honest response is to rank that pull request lexically and re-embed it on
    /// the next pass.
    var entry: SearchIndexEntry {
        var decoded: SearchVector?
        if let vector, let candidate = SearchVector(data: vector), candidate.dimensions == dimensions {
            decoded = candidate
        }
        return SearchIndexEntry(
            prID: prID,
            documentHash: documentHash,
            modelIdentifier: modelIdentifier,
            vector: decoded,
            indexedAt: Date(timeIntervalSince1970: indexedAt)
        )
    }
}

/// A row of `triage_verdicts` (ADR 0023).
///
/// The verdict is flattened into three plain columns rather than stored as JSON, for
/// ``PullRequestRecord``'s reason: `kind` and `risk` are closed vocabularies that SQL can be
/// asked about, and a JSON blob would make "how many high-risk pull requests are there" a
/// question only Swift could answer.
///
/// The enums travel as their raw values and are mapped by hand, which is the convention in this
/// file — the twin's *lenient* decoding exists for what a model writes, and nothing a model wrote
/// reaches this table without having been through it once already.
struct TriageVerdictRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "triage_verdicts"

    var prID: String
    var documentHash: String
    var kind: String
    var risk: String
    var reason: String
    var modelIdentifier: String
    var classifiedAt: Double

    init(entry: TriageVerdictEntry) {
        self.prID = entry.prID
        self.documentHash = entry.documentHash
        self.kind = entry.verdict.kind.rawValue
        self.risk = entry.verdict.risk.rawValue
        self.reason = entry.verdict.reason
        self.modelIdentifier = entry.modelIdentifier
        self.classifiedAt = entry.classifiedAt.timeIntervalSince1970
    }

    /// Rebuilds the entry, or `nil` when the row's vocabulary is not this version's.
    ///
    /// `nil` rather than a thrown error and rather than a substituted default: the table is a
    /// cache of locally computed opinions, so the honest response to a row Shepherd can no longer
    /// read is to show no chip and classify that pull request again on the next pass. Inventing a
    /// kind would present a guess as the model's verdict, which is the one thing
    /// ``ShepherdCore/TriageVerdict``'s decoding refuses to do.
    var entry: TriageVerdictEntry? {
        guard let decodedKind = TriageVerdict.Kind(rawValue: kind),
              let decodedRisk = TriageVerdict.Risk(rawValue: risk)
        else { return nil }
        return TriageVerdictEntry(
            prID: prID,
            documentHash: documentHash,
            verdict: TriageVerdict(kind: decodedKind, risk: decodedRisk, reason: reason),
            modelIdentifier: modelIdentifier,
            classifiedAt: Date(timeIntervalSince1970: classifiedAt)
        )
    }
}

/// A row of `review_snapshots` (ADR 0028).
///
/// The files travel as one JSON blob rather than as rows of a snapshot-shaped copy of
/// `changed_files`: nothing queries inside a snapshot — the interdiff reads the whole value at
/// once — and the blob is what keeps the patches after a force-push has made them unfetchable.
/// `filesJSON` is `Data`, which GRDB stores as a BLOB, the same treatment ``OutboxRecord``'s
/// payload gets.
struct ReviewSnapshotRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "review_snapshots"

    var prID: String
    var reviewedHeadOid: String
    var reviewedAt: Double
    var filesJSON: Data

    init(snapshot: ReviewSnapshot) {
        self.prID = snapshot.prID
        self.reviewedHeadOid = snapshot.reviewedHeadOid
        self.reviewedAt = snapshot.reviewedAt.timeIntervalSince1970
        self.filesJSON = (try? JSONEncoder().encode(snapshot.files)) ?? Data("[]".utf8)
    }

    /// Rebuilds the snapshot.
    ///
    /// A blob this version cannot decode yields a snapshot with **no** files rather than a
    /// failed fetch, and the interdiff over an empty baseline produces nothing — so the review
    /// screen offers no "Since your review" tab, which is the honest answer to "the baseline is
    /// unreadable" and exactly what the plan calls the unavailable case.
    var snapshot: ReviewSnapshot {
        ReviewSnapshot(
            prID: prID,
            reviewedHeadOid: reviewedHeadOid,
            reviewedAt: Date(timeIntervalSince1970: reviewedAt),
            files: (try? JSONDecoder().decode([ChangedFile].self, from: filesJSON)) ?? []
        )
    }
}

/// A row of `pull_request_outcomes` (ADR 0027).
///
/// The only record in this file whose pull request is deliberately *gone*: there is no foreign
/// key onto `pull_requests` and no cascade, because the row is written at the moment the pull
/// request leaves the inbox. So the repository travels by value, exactly as it does in
/// ``RepoRecord``, and the row survives every prune.
///
/// It carries three columns the counting never reads — `number`, `title` and `mergeCommitOid` —
/// because revert detection is text: a `Revert "…"` opened today has to be able to find the pull
/// request a backfill imported last month, and a title or a `This reverts commit <sha>` line can
/// only be matched against something still on disk.
struct PullRequestOutcomeRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pull_request_outcomes"

    var prID: String
    var repoFullName: String
    var repoOwner: String
    var repoName: String
    var number: Int
    var title: String
    var agentName: String?
    var authorLogin: String
    var openedAt: Double
    var closedAt: Double
    var merged: Bool
    var mergeCommitOid: String?
    var revertedByPRID: String?
    var firstPushCIGreen: Bool?
    var reviewRounds: Int
    var changedLines: Int
    var source: String

    init(closed: ClosedPullRequest) {
        let outcome = closed.outcome
        self.prID = outcome.prID
        self.repoFullName = outcome.repo.fullName
        self.repoOwner = outcome.repo.owner
        self.repoName = outcome.repo.name
        self.number = closed.number
        self.title = closed.title
        self.agentName = outcome.agentName
        self.authorLogin = outcome.authorLogin
        self.openedAt = outcome.openedAt.timeIntervalSince1970
        self.closedAt = outcome.closedAt.timeIntervalSince1970
        self.merged = outcome.merged
        self.mergeCommitOid = closed.mergeCommitOid
        self.revertedByPRID = outcome.revertedByPRID
        self.firstPushCIGreen = outcome.firstPushCIGreen
        self.reviewRounds = outcome.reviewRounds
        self.changedLines = outcome.changedLines
        self.source = outcome.source.rawValue
    }

    /// The row as the badge counts it.
    ///
    /// A `source` this version does not know degrades to ``ShepherdCore/PullRequestOutcomeSource/sync``
    /// rather than failing the fetch: the column says which writer produced the row, nothing
    /// counts on it, and losing a whole repository's history to one unfamiliar word would be a
    /// far worse answer than reading it as the commoner of the two.
    var outcome: PullRequestOutcome {
        PullRequestOutcome(
            prID: prID,
            repo: RepoRef(owner: repoOwner, name: repoName),
            agentName: agentName,
            authorLogin: authorLogin,
            openedAt: Date(timeIntervalSince1970: openedAt),
            closedAt: Date(timeIntervalSince1970: closedAt),
            merged: merged,
            revertedByPRID: revertedByPRID,
            firstPushCIGreen: firstPushCIGreen,
            reviewRounds: reviewRounds,
            changedLines: changedLines,
            source: PullRequestOutcomeSource(rawValue: source) ?? .sync
        )
    }

    /// The row as revert detection needs it: the outcome plus the three text columns.
    var closedPullRequest: ClosedPullRequest {
        ClosedPullRequest(
            outcome: outcome,
            number: number,
            title: title,
            // Bodies are deliberately not stored — they are the largest field of a closed pull
            // request and the only thing they are read for is the `This reverts commit` line,
            // which the *reverting* pull request carries and which is therefore always in hand.
            bodyMarkdown: "",
            mergeCommitOid: mergeCommitOid
        )
    }
}

/// A row of `issues` (ADR 0032).
///
/// ``PullRequestRecord``'s twin, column for column where the two rows hold the same thing: the
/// author and the detected agent flattened by ``ColumnCoding/encodeActorKind(_:)``, the relations
/// as a sorted joined string, the labels as JSON, and the body beside a `detailFetchedAt` stamp
/// so a sweep can upsert the row without discarding a detail fetch.
///
/// Two columns are not on the model and are computed on save:
/// `linkedPullRequestCount`/`hasAgentLinkedPullRequest` denormalise
/// ``ShepherdCore/IssueRowSummary/linkedPullRequests`` so the "has an agent pull request" facet is
/// a column comparison rather than a scan of the side table. They are derived from the list every
/// time it is written, so they cannot drift from it.
struct IssueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "issues"

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
    var closedAt: Double?
    var state: String
    var stateReason: String?
    var relations: String
    var labels: String
    var commentCount: Int
    var linkedPullRequestCount: Int
    var hasAgentLinkedPullRequest: Bool
    var bodyMarkdown: String?
    var detailFetchedAt: Double?

    /// Builds a row from an inbox summary, preserving any detail columns already stored.
    init(summary: IssueRowSummary, existing: IssueRecord? = nil) {
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
        self.closedAt = summary.closedAt?.timeIntervalSince1970
        self.state = summary.state.rawValue
        self.stateReason = summary.stateReason
        self.relations = ColumnCoding.encodeIssueRelations(summary.myRelation)
        self.labels = ColumnCoding.encodeJSON(summary.labels)
        self.commentCount = summary.commentCount
        self.linkedPullRequestCount = summary.linkedPullRequests.count
        self.hasAgentLinkedPullRequest = summary.hasAgentPullRequest
        self.bodyMarkdown = existing?.bodyMarkdown
        self.detailFetchedAt = existing?.detailFetchedAt
    }

    /// Rebuilds the inbox row with the links the caller fetched from the side table.
    ///
    /// The links are a parameter rather than a stored blob for the reason the denormalised
    /// columns exist: the row answers the facet on its own, and the list is read only when
    /// somebody is looking at it.
    /// - Parameter linkedPullRequests: The rows of `issue_linked_pull_requests`, in sort order.
    func summary(
        linkedPullRequests: [LinkedPullRequestReference] = []
    ) -> IssueRowSummary {
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
        return IssueRowSummary(
            id: id,
            // The same tolerant parse ``PullRequestRecord/summary`` uses: a stored `repoFullName`
            // without a slash degrades to a readable reference instead of dropping the row.
            repo: RepoRef.parse(fullName: repoFullName)
                ?? RepoRef(owner: repoFullName, name: repoFullName),
            number: number,
            title: title,
            author: author,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            closedAt: closedAt.map { Date(timeIntervalSince1970: $0) },
            // A `state` this build does not know reads as `unknown` rather than failing the
            // fetch — ADR 0026's amendment's own vocabulary, and the same tolerance every other
            // raw string column in this file gets.
            state: IssueSummary.State(rawValue: state) ?? .unknown,
            stateReason: stateReason,
            labels: ColumnCoding.decodeJSON([String].self, from: labels) ?? [],
            myRelation: ColumnCoding.decodeIssueRelations(relations),
            commentCount: commentCount,
            linkedPullRequests: linkedPullRequests
        )
    }
}

/// A row of `issue_linked_pull_requests` (ADR 0032).
///
/// The pull request is stored by value — repository included — because it may not be in the local
/// inbox at all: the row records what the sweep saw, not a join. Only the author's login, kind and
/// agent display name are kept, which is exactly what the provenance chip beside a link needs;
/// the avatar and the match signal are not, because a link is a line of text and not a row.
struct IssueLinkedPullRequestRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "issue_linked_pull_requests"

    var issueID: String
    var prRepoFullName: String
    var prNumber: Int
    var prTitle: String
    var prState: String
    var authorLogin: String
    var authorKind: String
    var agentDisplayName: String?
    var sortIndex: Int

    init(issueID: String, reference: LinkedPullRequestReference, sortIndex: Int) {
        let kind = ColumnCoding.encodeActorKind(reference.author.kind)
        self.issueID = issueID
        self.prRepoFullName = reference.repo.fullName
        self.prNumber = reference.number
        self.prTitle = reference.title
        self.prState = reference.state
        self.authorLogin = reference.author.login
        self.authorKind = kind.kind
        self.agentDisplayName = kind.agentDisplayName
        self.sortIndex = sortIndex
    }

    /// Rebuilds the reference.
    ///
    /// The agent's own id and match signal are not stored, so an `"agent"` row is rebuilt with
    /// the display name as its id. That is enough for the chip and for
    /// ``ShepherdCore/ActorKind/isMachine`` — which is what the facet reads — and it is why
    /// ``ColumnCoding/decodeActorKind(kind:agentID:agentDisplayName:agentMatchedBy:)`` is given
    /// the display name for both: a row with a name but no id would otherwise degrade to a plain
    /// bot and lose the agent's name from the link.
    var reference: LinkedPullRequestReference {
        LinkedPullRequestReference(
            repo: RepoRef.parse(fullName: prRepoFullName)
                ?? RepoRef(owner: prRepoFullName, name: prRepoFullName),
            number: prNumber,
            title: prTitle,
            state: prState,
            author: ShepherdCore.Actor(
                login: authorLogin,
                displayName: nil,
                avatarURL: nil,
                kind: ColumnCoding.decodeActorKind(
                    kind: authorKind,
                    agentID: agentDisplayName,
                    agentDisplayName: agentDisplayName,
                    agentMatchedBy: nil
                )
            )
        )
    }
}

/// A row of `pull_request_closing_issues` (ADR 0032).
///
/// The other direction of the link — the issues one pull request says it closes — and the one of
/// the two that *does* cascade with `pull_requests`, because it is about a pull request in the
/// inbox and disappears with it, exactly as `changed_files` does.
///
/// The table and this record landed with migration v7 so that the sprint which reads
/// `closingIssuesReferences` needed no migration of its own; that sprint is what filled in the
/// initialiser and the round trip below.
///
/// The issue is stored by value — repository included — for the reason the other direction gives:
/// `closingIssuesReferences` may name an issue in another repository, and one the issues sweep
/// never returned, so the row is about what the detail fetch saw and not about a join. Unlike its
/// twin it carries no author: a provenance chip is a question about a pull request.
struct PullRequestClosingIssueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pull_request_closing_issues"

    var prID: String
    var issueRepoFullName: String
    var issueNumber: Int
    var issueTitle: String
    var issueState: String
    var sortIndex: Int

    init(prID: String, reference: LinkedIssueReference, sortIndex: Int) {
        self.prID = prID
        self.issueRepoFullName = reference.repo.fullName
        self.issueNumber = reference.number
        self.issueTitle = reference.title
        self.issueState = reference.state.rawValue
        self.sortIndex = sortIndex
    }

    /// Rebuilds the reference.
    ///
    /// Both tolerances are the ones every other raw column in this file gets: a stored
    /// `issueRepoFullName` without a slash degrades to a readable reference rather than dropping
    /// the row, and a `issueState` this build does not know reads as `unknown` rather than
    /// failing the fetch.
    var reference: LinkedIssueReference {
        LinkedIssueReference(
            repo: RepoRef.parse(fullName: issueRepoFullName)
                ?? RepoRef(owner: issueRepoFullName, name: issueRepoFullName),
            number: issueNumber,
            title: issueTitle,
            state: IssueSummary.State(rawValue: issueState) ?? .unknown
        )
    }
}

/// A row of `issue_search_index` (ADR 0032).
///
/// ``SearchIndexRecord``'s twin: the same two-hash staleness gate, the same nullable vector, the
/// same `dimensions` column stored beside the blob so a truncated one is detectable rather than
/// silently decoding as a shorter vector that would still produce a plausible cosine.
///
/// `modelIdentifier` is nullable here where `search_index`'s is `NOT NULL DEFAULT ''`, so it is
/// read as an optional and an absent value becomes the empty string — which is what "no model
/// produced this row" already means on the pull-request side.
struct IssueSearchIndexRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "issue_search_index"

    var issueID: String
    var documentHash: String
    var modelIdentifier: String?
    var dimensions: Int
    var vector: Data?
    var indexedAt: Double

    init(entry: IssueSearchIndexEntry) {
        self.issueID = entry.issueID
        self.documentHash = entry.documentHash
        self.modelIdentifier = entry.modelIdentifier
        self.dimensions = entry.vector?.dimensions ?? 0
        self.vector = entry.vector?.data
        self.indexedAt = entry.indexedAt.timeIntervalSince1970
    }

    /// Rebuilds the entry.
    ///
    /// A blob that does not decode, or decodes to a different number of dimensions than the row
    /// claims, yields an entry with **no** vector rather than a failed fetch: the index is a
    /// cache, so the honest response is to rank that issue lexically and re-embed it on the next
    /// pass.
    var entry: IssueSearchIndexEntry {
        var decoded: SearchVector?
        if let vector, let candidate = SearchVector(data: vector), candidate.dimensions == dimensions {
            decoded = candidate
        }
        return IssueSearchIndexEntry(
            issueID: issueID,
            documentHash: documentHash,
            modelIdentifier: modelIdentifier ?? "",
            vector: decoded,
            indexedAt: Date(timeIntervalSince1970: indexedAt)
        )
    }
}
