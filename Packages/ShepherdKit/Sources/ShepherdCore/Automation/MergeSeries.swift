import Foundation

/// Why an entry of a merge series was left behind instead of merged (ADR 0041).
///
/// Complete, and kept: every way an entry stops without a merge names one of these, so the
/// chip and the final notification can say why.
public enum MergeSeriesSkipReason: String, Sendable, Codable, Hashable, CaseIterable {
    /// At least one check failed on the pinned head.
    case checksFailed
    /// The head has no checks at all, so there is nothing to wait for.
    case noChecks
    /// GitHub reports conflicts with the base branch.
    case conflicting
    /// The pull request is (again) a draft.
    case draft
    /// A reviewer asked for changes.
    case changesRequested
    /// The head moved without Shepherd's own branch update, or moved a second time after it.
    case headMoved
    /// An outbox row for this pull request failed or was parked while the entry was waiting.
    case writeFailed
    /// GitHub refused the branch update the series queued.
    case updateRefused
    /// GitHub refused the merge the series queued.
    case mergeRefused
    /// The row left the inbox without a confirmed merge and did not come back within the grace
    /// period — or, for a queued merge whose outbox row is gone too, GitHub says it is not merged.
    /// Also the fallback for an entry whose stored state this build cannot read.
    case disappeared
    /// The user took the entry out of the series, or cancelled the series.
    case removedByUser
}

/// Where one entry of a merge series stands.
public enum MergeSeriesEntryState: Sendable, Hashable {
    /// Not yet acted on. Only the active entry is evaluated; the rest simply wait their turn.
    case pending
    /// A branch update was queued with `from` as the expected head; waiting for the drain to
    /// confirm it.
    case updatingBranch(from: String)
    /// The drain confirmed the update. The next head the sweep reports that differs from `from`
    /// becomes the new pin, once.
    case branchUpdated(from: String)
    /// The merge was queued; waiting for GitHub to confirm it.
    case merging
    /// GitHub confirmed the merge.
    case merged
    /// Left behind, with the reason.
    case skipped(MergeSeriesSkipReason)

    /// Whether the entry is done, one way or the other.
    public var isFinished: Bool {
        switch self {
        case .merged, .skipped: return true
        case .pending, .updatingBranch, .branchUpdated, .merging: return false
        }
    }

    /// The reason, when the entry was skipped.
    public var skipReason: MergeSeriesSkipReason? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }

    /// Whether **Remove from series** (or **Cancel**) can take an entry in this state out right
    /// now.
    ///
    /// A queued merge or branch update cannot be taken back out of the outbox, so a `merging` or
    /// `updatingBranch` entry can only go once the caller has checked that the outbox holds no
    /// unsent row for it any more — there is nothing left to wait for then. Shared by
    /// ``MergeSeries/remove(_:hasNoUnsentWrite:)``, ``MergeSeries/cancel(withoutUnsentWrites:)``
    /// and the app's `MergeSeriesCoordinator.canRemove(_:hasUnsentWrite:)`, so the rule is written
    /// once.
    /// - Parameter hasNoUnsentWrite: Whether the outbox is known to hold no unsent row for it.
    public func isRemovable(hasNoUnsentWrite: Bool) -> Bool {
        switch self {
        case .pending, .branchUpdated: return true
        case .updatingBranch, .merging: return hasNoUnsentWrite
        case .merged, .skipped: return false
        }
    }
}

extension MergeSeriesEntryState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, from, reason
    }

    private enum Kind: String, Codable {
        case pending, updatingBranch, branchUpdated, merging, merged, skipped
    }

    /// Encodes as `{"kind": …}` plus `from` or `reason` where the case carries one.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending:
            try container.encode(Kind.pending, forKey: .kind)
        case .updatingBranch(let from):
            try container.encode(Kind.updatingBranch, forKey: .kind)
            try container.encode(from, forKey: .from)
        case .branchUpdated(let from):
            try container.encode(Kind.branchUpdated, forKey: .kind)
            try container.encode(from, forKey: .from)
        case .merging:
            try container.encode(Kind.merging, forKey: .kind)
        case .merged:
            try container.encode(Kind.merged, forKey: .kind)
        case .skipped(let reason):
            try container.encode(Kind.skipped, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    /// Decodes tolerantly. A state this build cannot read becomes a terminal skip
    /// (``MergeSeriesSkipReason/disappeared``) rather than `pending`: an unreadable state must
    /// never turn into a write without a fresh decision by the user.
    public init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)).flatMap({ $0 })
        else {
            self = .skipped(.disappeared)
            return
        }
        let from = (try? container.decodeIfPresent(String.self, forKey: .from)).flatMap { $0 }
        switch kind {
        case .pending:
            self = .pending
        case .updatingBranch:
            self = from.map { .updatingBranch(from: $0) } ?? .skipped(.disappeared)
        case .branchUpdated:
            self = from.map { .branchUpdated(from: $0) } ?? .skipped(.disappeared)
        case .merging:
            self = .merging
        case .merged:
            self = .merged
        case .skipped:
            let reason = (try? container.decodeIfPresent(MergeSeriesSkipReason.self, forKey: .reason))
                .flatMap { $0 }
            self = .skipped(reason ?? .disappeared)
        }
    }
}

/// One pull request in a merge series.
public struct MergeSeriesEntry: Sendable, Codable, Hashable, Identifiable {
    /// The pull request's node id.
    public var prID: String
    /// `owner/name#number`, copied in so a notice can name the pull request after the sweep
    /// pruned the row.
    public var slug: String
    /// The pull request number.
    public var number: Int
    /// The title at the time the series started.
    public var title: String
    /// The head commit the merge is pinned to: the one the user ticked, or the one Shepherd's
    /// own branch update produced (ADR 0041, "Re-pinning").
    public var pinnedHeadOid: String
    /// Where the entry stands.
    public var state: MergeSeriesEntryState
    /// When the entry became the active one — the start of its missing-row grace period.
    public var activeSince: Date?
    /// When the series last queued a branch update for this entry. GitHub answers the update
    /// with `202` and creates the merge commit asynchronously, so the wait for the new head is
    /// bounded by the grace period counted from here rather than from ``activeSince``, which may
    /// lie long before (the checks can take hours).
    public var updateQueuedAt: Date?
    /// When the series queued the merge for this entry — the start of the bound on how long a
    /// `merging` entry waits for a confirmation whose outbox row is gone (ADR 0041's
    /// 2026-09-25 amendment).
    public var mergeQueuedAt: Date?
    /// Whether **Cancel** asked for this entry to be taken out while its branch update was still
    /// in the outbox. The update cannot be taken back and still goes out; once it is settled the
    /// entry is *removed by user* instead of going on to a merge nobody wants any more, and until
    /// then it stays `updatingBranch`, so a parked update still keeps its alert down.
    public var removalRequested: Bool
    /// The stack the pull request was in when the series started (ADR 0042). Copied in rather
    /// than read off the row, because the row changes under a stack exactly when it matters: once
    /// the pull request below merges, GitHub re-numbers the stack (or dissolves it) and
    /// re-targets and rebases this one, and the row's own position no longer says that something
    /// below it just merged. `nil` for a pull request in no stack.
    public var stackNumber: Int?
    /// The place in that stack, 1-based from the bottom like ``PullRequestStack/position``.
    public var stackPosition: Int?
    /// Whether the series already took a new head for this entry after a lower member of its
    /// stack merged. Once: the rebase GitHub does after the lower merge is expected, a second
    /// head change is somebody's push (ADR 0042).
    public var repinnedAfterStackMerge: Bool
    /// When the entry started waiting, behind its base and above the bottom of a stack, for
    /// GitHub to bring its branch up to date — the series never queues an update for such a pull
    /// request (ADR 0042). The start of that wait's grace period; cleared once the pull request
    /// is no longer behind.
    public var restackWaitSince: Date?
    /// When GitHub accepted the merge without having finished it — put it into the merge queue,
    /// or started merging the stack (`mergeEnqueued` / `mergeStarted`, ADR 0042). The entry is
    /// still `merging`, but is waited for much longer
    /// (``unconfirmedMergeDeadline(gracePeriod:now:)``), because the pull request stays open in
    /// the inbox for as long as GitHub's queue takes.
    public var mergeAcceptedAt: Date?

    /// How long a merge GitHub accepted but has not finished is waited for: 24 hours, as long as
    /// GitHub keeps an asynchronous merge's result (`GET …/merge-async/{uuid}`). A queue that has
    /// not landed the pull request by then is not one the series should hold every later entry
    /// behind.
    public static let acceptedMergeGracePeriod: TimeInterval = 24 * 60 * 60

    /// Creates an entry.
    public init(
        prID: String,
        slug: String,
        number: Int,
        title: String,
        pinnedHeadOid: String,
        state: MergeSeriesEntryState = .pending,
        activeSince: Date? = nil,
        updateQueuedAt: Date? = nil,
        mergeQueuedAt: Date? = nil,
        removalRequested: Bool = false,
        stackNumber: Int? = nil,
        stackPosition: Int? = nil,
        repinnedAfterStackMerge: Bool = false,
        restackWaitSince: Date? = nil,
        mergeAcceptedAt: Date? = nil
    ) {
        self.prID = prID
        self.slug = slug
        self.number = number
        self.title = title
        self.pinnedHeadOid = pinnedHeadOid
        self.state = state
        self.activeSince = activeSince
        self.updateQueuedAt = updateQueuedAt
        self.mergeQueuedAt = mergeQueuedAt
        self.removalRequested = removalRequested
        self.stackNumber = stackNumber
        self.stackPosition = stackPosition
        self.repinnedAfterStackMerge = repinnedAfterStackMerge
        self.restackWaitSince = restackWaitSince
        self.mergeAcceptedAt = mergeAcceptedAt
    }

    /// Creates a pending entry pinned to the row's current head, with its place in a stack.
    /// - Parameter pullRequest: The ticked row.
    public init(pullRequest: PullRequestSummary) {
        self.init(
            prID: pullRequest.id,
            slug: pullRequest.slug,
            number: pullRequest.number,
            title: pullRequest.title,
            pinnedHeadOid: pullRequest.headRefOid,
            stackNumber: pullRequest.stack?.number,
            stackPosition: pullRequest.stack?.position
        )
    }

    /// An entry is identified by its pull request.
    public var id: String { prID }

    /// When a `merging` entry whose outbox row is gone, without a failure or a confirmation,
    /// stops being waited for while its pull request is still open.
    ///
    /// A merge GitHub accepted (``mergeAcceptedAt``) gets ``acceptedMergeGracePeriod`` from the
    /// acceptance: the pull request stays open while GitHub's merge queue works, and skipping it
    /// as *merge refused* after an hour would be wrong about a merge that is running. An entry
    /// with a recorded stack gets the same 24 hours from when the merge was queued, acceptance
    /// seen or not. Any other gets `gracePeriod` from when the merge was queued.
    /// - Parameters:
    ///   - gracePeriod: The ordinary bound (`MergeSeriesCoordinator.missingRowGracePeriod`).
    ///   - now: The fallback start for an entry without any timestamp.
    public func unconfirmedMergeDeadline(gracePeriod: TimeInterval, now: Date) -> Date {
        if let mergeAcceptedAt {
            return mergeAcceptedAt.addingTimeInterval(Self.acceptedMergeGracePeriod)
        }
        let queued = mergeQueuedAt ?? activeSince ?? now
        // A stacked pull request is always merged through GitHub's asynchronous API, so it gets
        // the long wait whether or not the acceptance event was seen: that event lives only in
        // memory, and an app that quit before it arrived must not skip a running merge after an
        // hour. Stored with the entry, the stack survives the restart the event does not.
        if stackNumber != nil {
            return queued.addingTimeInterval(Self.acceptedMergeGracePeriod)
        }
        return queued.addingTimeInterval(gracePeriod)
    }

    private enum CodingKeys: String, CodingKey {
        case prID, slug, number, title, pinnedHeadOid, state, activeSince, updateQueuedAt, mergeQueuedAt
        case removalRequested
        case stackNumber, stackPosition, repinnedAfterStackMerge, restackWaitSince, mergeAcceptedAt
    }

    /// Decodes tolerantly, like every persisted value in this folder. A missing pin decodes as
    /// an empty string, which no row matches, so such an entry skips as *head moved* instead of
    /// merging a commit nobody pinned.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prID = (try? container.decodeIfPresent(String.self, forKey: .prID)).flatMap { $0 } ?? ""
        slug = (try? container.decodeIfPresent(String.self, forKey: .slug)).flatMap { $0 } ?? ""
        number = (try? container.decodeIfPresent(Int.self, forKey: .number)).flatMap { $0 } ?? 0
        title = (try? container.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 } ?? ""
        pinnedHeadOid = (try? container.decodeIfPresent(String.self, forKey: .pinnedHeadOid))
            .flatMap { $0 } ?? ""
        state = (try? container.decodeIfPresent(MergeSeriesEntryState.self, forKey: .state))
            .flatMap { $0 } ?? .skipped(.disappeared)
        activeSince = (try? container.decodeIfPresent(Date.self, forKey: .activeSince)).flatMap { $0 }
        updateQueuedAt = (try? container.decodeIfPresent(Date.self, forKey: .updateQueuedAt))
            .flatMap { $0 }
        mergeQueuedAt = (try? container.decodeIfPresent(Date.self, forKey: .mergeQueuedAt))
            .flatMap { $0 }
        removalRequested = (try? container.decodeIfPresent(Bool.self, forKey: .removalRequested))
            .flatMap { $0 } ?? false
        // A series stored before stacks existed reads as in no stack, which is how it was run.
        stackNumber = (try? container.decodeIfPresent(Int.self, forKey: .stackNumber)).flatMap { $0 }
        stackPosition = (try? container.decodeIfPresent(Int.self, forKey: .stackPosition)).flatMap { $0 }
        repinnedAfterStackMerge = (try? container.decodeIfPresent(Bool.self, forKey: .repinnedAfterStackMerge))
            .flatMap { $0 } ?? false
        restackWaitSince = (try? container.decodeIfPresent(Date.self, forKey: .restackWaitSince))
            .flatMap { $0 }
        mergeAcceptedAt = (try? container.decodeIfPresent(Date.self, forKey: .mergeAcceptedAt))
            .flatMap { $0 }
    }
}

/// Several pull requests of one repository, merged one after another (ADR 0041).
///
/// Everything the writes will need is copied in when the user presses **Start**, because that
/// press is the decision: the method and the branch answer are the ones the sheet showed.
public struct MergeSeries: Sendable, Codable, Hashable, Identifiable {
    /// A UUID string.
    public var id: String
    /// The repository every entry belongs to.
    public var repository: RepoRef
    /// The merge method, as GitHub's raw value (`"merge"`, `"squash"`, `"rebase"`).
    public var mergeMethod: String
    /// Whether each head branch is deleted after its merge.
    public var deletesHeadBranch: Bool
    /// When the user pressed Start.
    public var createdAt: Date
    /// The entries, in merge order.
    public var entries: [MergeSeriesEntry]

    /// Creates a series.
    public init(
        id: String = UUID().uuidString,
        repository: RepoRef,
        mergeMethod: String,
        deletesHeadBranch: Bool,
        createdAt: Date,
        entries: [MergeSeriesEntry]
    ) {
        self.id = id
        self.repository = repository
        self.mergeMethod = mergeMethod
        self.deletesHeadBranch = deletesHeadBranch
        self.createdAt = createdAt
        self.entries = entries
    }

    /// Creates a series over these rows, in this order, each pinned to its current head.
    ///
    /// With one exception to "in this order": members of one GitHub stack are put back into
    /// position order, bottom first, within the slots they occupy
    /// (``MergeSeriesPlan/stacksBottomFirst(_:)``, ADR 0042). An upper member merged first would
    /// take the lower ones along before the series had checked them, and the lower entries would
    /// then wait for a row that is gone. The sheet already keeps its order that way; this is the
    /// backstop for any caller that does not.
    /// - Parameters:
    ///   - repository: The repository.
    ///   - pullRequests: The rows, in merge order.
    ///   - mergeMethod: GitHub's raw merge method.
    ///   - deletesHeadBranch: The sheet's branch answer.
    ///   - id: The series id.
    ///   - now: When the user pressed Start.
    public init(
        repository: RepoRef,
        pullRequests: [PullRequestSummary],
        mergeMethod: String,
        deletesHeadBranch: Bool,
        id: String = UUID().uuidString,
        now: Date
    ) {
        self.init(
            id: id,
            repository: repository,
            mergeMethod: mergeMethod,
            deletesHeadBranch: deletesHeadBranch,
            createdAt: now,
            entries: MergeSeriesPlan.stacksBottomFirst(pullRequests).map(MergeSeriesEntry.init(pullRequest:))
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, repository, mergeMethod, deletesHeadBranch, createdAt, entries
    }

    /// Decodes tolerantly. The branch answer falls back to *keep*, the answer that can be
    /// corrected later; an unreadable entry list is empty, which makes the series finished.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)).flatMap { $0 } ?? ""
        repository = (try? container.decodeIfPresent(RepoRef.self, forKey: .repository))
            .flatMap { $0 } ?? RepoRef(owner: "", name: "")
        mergeMethod = (try? container.decodeIfPresent(String.self, forKey: .mergeMethod))
            .flatMap { $0 } ?? ""
        deletesHeadBranch = (try? container.decodeIfPresent(Bool.self, forKey: .deletesHeadBranch))
            .flatMap { $0 } ?? false
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt))
            .flatMap { $0 } ?? Date(timeIntervalSince1970: 0)
        entries = (try? container.decodeIfPresent([MergeSeriesEntry].self, forKey: .entries))
            .flatMap { $0 } ?? []
    }

    // MARK: - Reading

    /// The index of the first entry that is neither merged nor skipped.
    public var activeIndex: Int? { entries.firstIndex { !$0.state.isFinished } }

    /// The one entry the series is working on. Strict by design: the next entry only becomes
    /// active once this one is merged or skipped.
    public var activeEntry: MergeSeriesEntry? { activeIndex.map { entries[$0] } }

    /// Whether every entry is merged or skipped — the moment the summary notification fires.
    public var isFinished: Bool { activeIndex == nil }

    /// How many entries GitHub confirmed as merged.
    public var mergedCount: Int { entries.filter { $0.state == .merged }.count }

    /// How many entries were skipped.
    public var skippedCount: Int { entries.filter { $0.state.skipReason != nil }.count }

    /// The entry for a pull request, if it is part of this series.
    /// - Parameter prID: The pull request's node id.
    public func entry(for prID: String) -> MergeSeriesEntry? {
        entries.first { $0.prID == prID }
    }

    /// Where a pull request sits in the series.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: The **zero-based** index and the number of entries, or `nil` when the pull
    ///   request is not part of the series. A chip reading "2/5" shows `index + 1`.
    public func position(of prID: String) -> (index: Int, total: Int)? {
        entries.firstIndex { $0.prID == prID }.map { (index: $0, total: entries.count) }
    }

    // MARK: - Events

    /// Records GitHub's confirmation of a merge (`mutationSent(.merged)`).
    ///
    /// The confirmation is the truth, so it wins over any state, a skip included.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: Whether anything changed.
    @discardableResult
    public mutating func markMerged(_ prID: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.prID == prID }),
              entries[index].state != .merged
        else { return false }
        entries[index].state = .merged
        return true
    }

    /// Records that GitHub accepted a `merging` entry's merge without finishing it
    /// (`mutationSent(.mergeEnqueued)` or `.mergeStarted`, ADR 0042). The entry stays `merging` —
    /// accepted is not merged — but its wait is now bounded by
    /// ``MergeSeriesEntry/acceptedMergeGracePeriod``. The first acceptance counts: a second event
    /// for the same merge does not push the deadline out.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - now: When the drain reported it.
    /// - Returns: Whether anything changed.
    @discardableResult
    public mutating func markMergeAccepted(_ prID: String, at now: Date) -> Bool {
        guard let index = entries.firstIndex(where: { $0.prID == prID }),
              entries[index].state == .merging,
              entries[index].mergeAcceptedAt == nil
        else { return false }
        entries[index].mergeAcceptedAt = now
        return true
    }

    /// Records that GitHub said a vanished `merging` entry's pull request is **not** merged
    /// (asked once per pass when its row has left both the outbox and the inbox without a
    /// confirmation — see `MergeSeriesCoordinator.probeVanishedMerges`): closed elsewhere, or its
    /// row was discarded by hand and it left the inbox on its own. Only a `merging` entry is
    /// touched, like ``markMerged(_:)`` and ``markBranchUpdated(_:)`` beside it.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: Whether anything changed.
    @discardableResult
    public mutating func markGoneUnmerged(_ prID: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.prID == prID }),
              entries[index].state == .merging
        else { return false }
        entries[index].state = .skipped(.disappeared)
        return true
    }

    /// Records the drain's confirmation of the branch update the series queued
    /// (`mutationSent(.branchUpdated)`). Only an entry that is waiting for its update moves;
    /// a confirmation for anything else is ignored. An entry **Cancel** asked to take out
    /// (``MergeSeriesEntry/removalRequested``) is removed now instead of going on to its merge.
    /// - Parameter prID: The pull request's node id.
    /// - Returns: Whether anything changed.
    @discardableResult
    public mutating func markBranchUpdated(_ prID: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.prID == prID }),
              case .updatingBranch(let from) = entries[index].state
        else { return false }
        entries[index].state = entries[index].removalRequested
            ? .skipped(.removedByUser)
            : .branchUpdated(from: from)
        return true
    }

    /// Takes a pull request out of the series (**Remove from series**).
    ///
    /// A queued merge or branch update cannot be taken back out of the outbox, so a `merging`
    /// or `updatingBranch` entry stays and the drain's outcome decides — unless the caller has
    /// checked that the outbox holds no unsent row for it any more (`hasNoUnsentWrite`), in
    /// which case there is nothing left to wait for. An update that is still to go out must keep
    /// its entry, too: the entry is what tells a parked update's conflict apart from a review
    /// draft's, and without it the user would get the "review not sent" alert for a review they
    /// never wrote. Finished entries stay as they are.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - hasNoUnsentWrite: Whether the outbox is known to hold no unsent row for it.
    /// - Returns: Whether anything changed.
    @discardableResult
    public mutating func remove(_ prID: String, hasNoUnsentWrite: Bool = false) -> Bool {
        guard let index = entries.firstIndex(where: { $0.prID == prID }),
              entries[index].state.isRemovable(hasNoUnsentWrite: hasNoUnsentWrite)
        else { return false }
        entries[index].state = .skipped(.removedByUser)
        return true
    }

    /// Cancels the series: every entry that is pending or re-pinning becomes *removed by user*,
    /// and so does a `merging` or `updatingBranch` entry named in `withoutUnsentWrites` — see
    /// ``remove(_:hasNoUnsentWrite:)``. A `merging` entry with its merge still in the outbox
    /// stays, and the confirmation decides. An `updatingBranch` one stays too, until its update
    /// is settled, but is marked (``MergeSeriesEntry/removalRequested``) so that it is removed
    /// then rather than merged. Finished entries are untouched.
    /// - Parameter withoutUnsentWrites: Entries whose outbox row is known to be gone.
    /// - Returns: Whether anything changed, like every other mutator here.
    @discardableResult
    public mutating func cancel(withoutUnsentWrites: Set<String> = []) -> Bool {
        var changed = false
        for index in entries.indices {
            let hasNoUnsentWrite = withoutUnsentWrites.contains(entries[index].prID)
            if entries[index].state.isRemovable(hasNoUnsentWrite: hasNoUnsentWrite) {
                entries[index].state = .skipped(.removedByUser)
                changed = true
            } else if case .updatingBranch = entries[index].state, !entries[index].removalRequested {
                entries[index].removalRequested = true
                changed = true
            }
        }
        return changed
    }
}

/// Every running series on this Mac.
///
/// Machine-local like ``MergeWhenGreenList``, and for the same reason: a second Mac cannot know
/// what this one's user decided.
public struct MergeSeriesList: Sendable, Codable, Hashable {
    /// The series, oldest first.
    public var series: [MergeSeries]

    /// Creates a list.
    public init(series: [MergeSeries] = []) {
        self.series = series
    }

    private enum CodingKeys: String, CodingKey {
        case series
    }

    /// Decodes tolerantly — an unreadable list is empty rather than fatal.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        series = (try? container.decodeIfPresent([MergeSeries].self, forKey: .series))
            .flatMap { $0 } ?? []
    }

    /// Whether nothing is running.
    public var isEmpty: Bool { series.isEmpty }

    /// The unfinished series a pull request belongs to, if any. A pull request can only be in
    /// one running series at a time; a finished one is history.
    /// - Parameter prID: The pull request's node id.
    public func series(containing prID: String) -> MergeSeries? {
        series.first { !$0.isFinished && $0.entry(for: prID) != nil }
    }
}
