import Foundation

/// A merge the user decided on while the checks were still running (ADR 0037).
///
/// The reviewer read the pull request, judged it good, pressed *Merge when checks pass* — and
/// Shepherd's job from then on is bookkeeping: merge *that commit* the moment its checks are
/// green, and stop if anything about it changes. Everything the write will need is copied in at
/// the click, because the click is the decision: the method and the branch answer are the ones
/// the sheet showed, not whatever the settings say when the checks finally finish.
public struct MergeWhenGreenRequest: Sendable, Codable, Hashable, Identifiable {
    /// The pull request's node id.
    public var prID: String
    /// `owner/name#number`, copied in so a notice can name the pull request after the sweep has
    /// pruned the row.
    public var slug: String
    /// The title at the time of the click.
    public var title: String
    /// The head commit the user looked at. The merge is pinned to it and a push abandons the arm.
    public var headRefOid: String
    /// The merge method, as GitHub's raw value (`"merge"`, `"squash"`, `"rebase"`).
    public var mergeMethod: String
    /// Whether the head branch is deleted afterwards — the box as the sheet showed it.
    public var deletesHeadBranch: Bool
    /// When the user pressed the button.
    public var armedAt: Date

    /// Creates a request.
    public init(
        prID: String,
        slug: String,
        title: String,
        headRefOid: String,
        mergeMethod: String,
        deletesHeadBranch: Bool,
        armedAt: Date
    ) {
        self.prID = prID
        self.slug = slug
        self.title = title
        self.headRefOid = headRefOid
        self.mergeMethod = mergeMethod
        self.deletesHeadBranch = deletesHeadBranch
        self.armedAt = armedAt
    }

    /// One arm per pull request: a second press replaces the first.
    public var id: String { prID }

    /// The first twelve characters of the head commit — what a human recognises a commit by.
    public var shortHead: String { String(headRefOid.prefix(12)) }

    private enum CodingKeys: String, CodingKey {
        case prID, slug, title, headRefOid, mergeMethod, deletesHeadBranch, armedAt
    }

    /// Decodes tolerantly, like every persisted value in this folder: an entry written by another
    /// build must not cost the whole list. The one field whose fallback matters is the branch
    /// answer, and it falls back to *keep*, which is the answer that can be corrected later.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prID = (try? container.decodeIfPresent(String.self, forKey: .prID)).flatMap { $0 } ?? ""
        slug = (try? container.decodeIfPresent(String.self, forKey: .slug)).flatMap { $0 } ?? ""
        title = (try? container.decodeIfPresent(String.self, forKey: .title)).flatMap { $0 } ?? ""
        headRefOid = (try? container.decodeIfPresent(String.self, forKey: .headRefOid))
            .flatMap { $0 } ?? ""
        mergeMethod = (try? container.decodeIfPresent(String.self, forKey: .mergeMethod))
            .flatMap { $0 } ?? ""
        deletesHeadBranch = (try? container.decodeIfPresent(Bool.self, forKey: .deletesHeadBranch))
            .flatMap { $0 } ?? false
        armedAt = (try? container.decodeIfPresent(Date.self, forKey: .armedAt))
            .flatMap { $0 } ?? Date(timeIntervalSince1970: 0)
    }
}

/// Why an armed merge is still waiting.
public enum MergeWhenGreenWaitReason: String, Sendable, Codable, Hashable, CaseIterable {
    /// At least one check is still queued or running.
    case checksPending
    /// GitHub has not finished computing mergeability.
    case mergeabilityUnknown
    /// The outbox still holds an unsent write for this pull request.
    case writeInFlight
}

/// Why an armed merge was given up rather than queued.
///
/// Complete, and kept: every path out of the policy that neither merges nor waits names one of
/// these, so the notice that says "not merged" can also say why.
public enum MergeWhenGreenAbandonReason: String, Sendable, Codable, Hashable, CaseIterable {
    /// Somebody pushed. The commit the user judged is no longer the one that would be merged.
    case headMoved
    /// At least one check failed on the armed head.
    case checksFailed
    /// The head has no checks at all, so there is nothing to wait for.
    case noChecks
    /// The pull request was turned back into a draft.
    case draft
    /// GitHub reports conflicts with the base branch.
    case conflicting
}

/// What the policy decided about one armed merge.
public enum MergeWhenGreenDecision: Sendable, Equatable {
    /// Queue the merge, with this head commit as the merge precondition.
    case merge(expectedHeadOid: String)
    /// Keep the arm and look again after the next sweep.
    case wait(MergeWhenGreenWaitReason)
    /// Drop the arm and tell the user why.
    case abandon(MergeWhenGreenAbandonReason)

    /// The head commit to merge against, when the decision was to merge.
    public var expectedHeadOid: String? {
        if case .merge(let oid) = self { return oid }
        return nil
    }

    /// The reason, when the decision was to abandon.
    public var abandonReason: MergeWhenGreenAbandonReason? {
        if case .abandon(let reason) = self { return reason }
        return nil
    }
}

/// The merges waiting for green on this Mac.
///
/// One entry per pull request, keyed by node id. Machine-local by design and never in the
/// settings document (ADR 0014): a second Mac cannot know what this one's user looked at, so it
/// must not merge on their behalf.
public struct MergeWhenGreenList: Sendable, Codable, Equatable {
    /// The armed merges, oldest first.
    public var entries: [MergeWhenGreenRequest]

    /// Creates a list.
    /// - Parameter entries: The armed merges, oldest first.
    public init(entries: [MergeWhenGreenRequest] = []) {
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    /// Decodes tolerantly — see ``MergeWhenGreenRequest/init(from:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? container.decodeIfPresent([MergeWhenGreenRequest].self, forKey: .entries))
            .flatMap { $0 } ?? []
    }

    /// Whether nothing is armed — the check a sweep makes before doing anything else.
    public var isEmpty: Bool { entries.isEmpty }

    /// The arm for a pull request, if any.
    /// - Parameter prID: The pull request's node id.
    public func request(forPullRequestID prID: String) -> MergeWhenGreenRequest? {
        entries.first { $0.prID == prID }
    }

    /// Whether a merge is armed for this pull request *at this head*.
    ///
    /// The head is part of the question because the arm is about a commit: a sheet opened on a
    /// newer push must not say "waiting for green" about a decision made on an older one.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - headRefOid: The head commit the caller is looking at.
    public func isArmed(pullRequestID prID: String, headRefOid: String) -> Bool {
        request(forPullRequestID: prID)?.headRefOid == headRefOid
    }

    /// The list with this merge armed. A second arm for the same pull request replaces the first.
    /// - Parameter request: What the user asked for.
    public func arming(_ request: MergeWhenGreenRequest) -> MergeWhenGreenList {
        var updated = self
        updated.entries.removeAll { $0.prID == request.prID }
        updated.entries.append(request)
        return updated
    }

    /// The list without this pull request's arm.
    /// - Parameter prID: The pull request's node id.
    public func disarming(pullRequestID prID: String) -> MergeWhenGreenList {
        var updated = self
        updated.entries.removeAll { $0.prID == prID }
        return updated
    }
}

/// Decides what to do about a merge the user armed while the checks were running (ADR 0037).
///
/// Split the way ``AutoMergePolicy`` is: a pure function over values — the arm, the row as the
/// last sweep wrote it, what the outbox holds — with the app layer supplying the inputs and
/// performing the write through the ordinary outbox. Nothing here talks to GitHub or the database.
///
/// What is **not** checked here, deliberately: approval, authorship, the repository. The human
/// formed the verdict when they pressed the button; this function only asks whether the commit
/// they judged is still the commit that would be merged, and whether it went green.
public enum MergeWhenGreenPolicy {
    /// Decides what to do about one armed merge.
    ///
    /// The checks run in a fixed order, so the reason a notice gives never depends on evaluation
    /// order: head moved → draft → conflicting → checks failed → checks running → no checks →
    /// mergeability unknown → a write is in flight → merge. The head goes first because once it
    /// moved, nothing else about the row is about the commit the user decided on.
    /// - Parameters:
    ///   - request: The arm.
    ///   - pullRequest: The inbox row, as the last sweep wrote it.
    ///   - existingOutbox: The node ids of pull requests the outbox still holds a write for.
    /// - Returns: The decision.
    public static func decide(
        request: MergeWhenGreenRequest,
        pullRequest: PullRequestSummary,
        existingOutbox: Set<String>
    ) -> MergeWhenGreenDecision {
        guard pullRequest.headRefOid == request.headRefOid else { return .abandon(.headMoved) }
        guard !pullRequest.isDraft else { return .abandon(.draft) }
        if pullRequest.mergeable == .conflicting { return .abandon(.conflicting) }
        guard let rollup = pullRequest.checkRollup else { return .abandon(.noChecks) }
        // The state is read before the count: a rollup can carry a state and no count (GitHubKit
        // documents `total` as 0 "when only the rollup state is known"), and a running suite
        // with an unknown count is still a running suite. Only *green* has to prove it has
        // something to be green about — ``AutoMergePolicy/hasGreenChecks(_:)``'s standard.
        switch rollup.state {
        case .failure:
            return .abandon(.checksFailed)
        case .pending:
            return .wait(.checksPending)
        case .none:
            return .abandon(.noChecks)
        case .success:
            guard rollup.total > 0 else { return .abandon(.noChecks) }
        }
        // Unknown mergeability is a wait rather than a refusal, unlike ADR 0018's rule: GitHub
        // recomputes it after every push and every base-branch merge, and it is usually unknown
        // for the seconds that follow the last check turning green. The next sweep answers it.
        guard pullRequest.mergeable == .mergeable else { return .wait(.mergeabilityUnknown) }
        guard !existingOutbox.contains(pullRequest.id) else { return .wait(.writeInFlight) }
        return .merge(expectedHeadOid: pullRequest.headRefOid)
    }
}
