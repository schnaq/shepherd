import Foundation
import ShepherdCore

/// Translates GitHub's wire shapes into `ShepherdCore` models.
///
/// Kept as one explicit, side-effect-free enum so that every field mapping is visible in one
/// place and testable against recorded fixtures without a network stack.
public enum ResponseMapping {
    // MARK: - Small value mappings

    /// Maps GraphQL's `PullRequestReviewDecision`.
    static func reviewDecision(_ raw: String?) -> ReviewDecision? {
        guard let value = raw?.uppercased() else { return nil }
        switch value {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .reviewRequired
        default: return nil
        }
    }

    /// Maps GraphQL's `MergeableState`.
    static func mergeable(_ raw: String?) -> Mergeable? {
        guard let value = raw?.uppercased() else { return nil }
        switch value {
        case "MERGEABLE": return .mergeable
        case "CONFLICTING": return .conflicting
        case "UNKNOWN": return .unknown
        default: return nil
        }
    }

    /// Maps REST's boolean `mergeable` plus `mergeable_state`.
    static func mergeable(restValue: Bool?, state: String?) -> Mergeable? {
        if let restValue {
            return restValue ? .mergeable : .conflicting
        }
        if let state, state.lowercased() == "dirty" { return .conflicting }
        return state == nil ? nil : .unknown
    }

    /// Maps GraphQL's `StatusState` onto a rollup state.
    static func rollupState(_ raw: String?) -> CheckRollup.State? {
        guard let value = raw?.uppercased() else { return nil }
        switch value {
        case "SUCCESS": return .success
        case "FAILURE", "ERROR": return .failure
        case "PENDING", "EXPECTED": return .pending
        default: return nil
        }
    }

    /// Maps GraphQL's `DiffSide`.
    static func diffSide(_ raw: String?) -> DiffSide {
        raw?.uppercased() == "LEFT" ? .left : .right
    }

    /// Parses `https://api.github.com/repos/o/r/pulls/42` into its repository and number.
    static func repoAndNumber(fromSubjectURL string: String?) -> (RepoRef?, Int?) {
        guard let string, let url = URL(string: string) else { return (nil, nil) }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let reposIndex = components.firstIndex(of: "repos"),
              components.count > reposIndex + 2
        else { return (nil, nil) }
        let repo = RepoRef(
            owner: components[reposIndex + 1],
            name: components[reposIndex + 2]
        )
        let number = components.last.flatMap { Int($0) }
        return (repo, number)
    }

    // MARK: - Actors

    /// Builds an ``ShepherdCore/Actor`` from a GraphQL actor fragment.
    static func makeActor(
        from dto: GraphQLActorDTO?,
        detector: AgentDetector,
        branchName: String? = nil,
        commitTrailers: [String] = []
    ) -> ShepherdCore.Actor {
        let signal = AuthorSignal(
            login: dto?.login ?? "ghost",
            isBotAccount: dto?.isBot ?? false,
            displayName: nil,
            avatarURL: dto?.avatarUrl.flatMap { URL(string: $0) }
        )
        return detector.resolveActor(
            author: signal,
            branchName: branchName,
            commitTrailers: commitTrailers
        )
    }

    /// Builds an ``ShepherdCore/Actor`` from a REST user object.
    static func makeActor(
        from dto: RESTUserDTO?,
        detector: AgentDetector,
        branchName: String? = nil,
        commitTrailers: [String] = []
    ) -> ShepherdCore.Actor {
        let signal = AuthorSignal(
            login: dto?.login ?? "ghost",
            isBotAccount: dto?.isBot ?? false,
            displayName: dto?.name,
            avatarURL: dto?.avatarUrl.flatMap { URL(string: $0) }
        )
        return detector.resolveActor(
            author: signal,
            branchName: branchName,
            commitTrailers: commitTrailers
        )
    }

    // MARK: - Inbox sweep

    /// Maps one search node onto an inbox row.
    ///
    /// Returns `nil` for nodes that are not pull requests or that are missing a field the
    /// inbox cannot do without — a malformed row is dropped, never faked.
    /// - Parameters:
    ///   - node: The search node.
    ///   - relations: The relations implied by the facet query that returned the node.
    ///   - detector: The agent detector to classify the author with.
    static func pullRequestSummary(
        from node: SearchNodeDTO,
        relations: Set<Relation>,
        detector: AgentDetector
    ) -> PullRequestSummary? {
        guard node.typename == nil || node.typename == "PullRequest" else { return nil }
        guard let id = node.id,
              let number = node.number,
              let repoName = node.repository?.name,
              let repoOwner = node.repository?.owner?.login,
              let updatedAt = node.updatedAt.flatMap(GitHubTimestamp.parse),
              let createdAt = node.createdAt.flatMap(GitHubTimestamp.parse)
        else { return nil }

        let headRefName = node.headRefName ?? ""
        let rollupDTO = node.commits?.nodes?
            .compactMap { $0 }
            .first?
            .commit?
            .statusCheckRollup
        let rollup = rollupState(rollupDTO?.state).map { state in
            CheckRollup(state: state, total: rollupDTO?.contexts?.totalCount ?? 0)
        }

        return PullRequestSummary(
            id: id,
            repo: RepoRef(owner: repoOwner, name: repoName),
            number: number,
            title: node.title ?? "",
            author: makeActor(from: node.author, detector: detector, branchName: headRefName),
            updatedAt: updatedAt,
            createdAt: createdAt,
            isDraft: node.isDraft ?? false,
            additions: node.additions ?? 0,
            deletions: node.deletions ?? 0,
            changedFiles: node.changedFiles ?? 0,
            headRefName: headRefName,
            headRefOid: node.headRefOid ?? "",
            baseRefName: node.baseRefName ?? "",
            reviewDecision: reviewDecision(node.reviewDecision),
            checkRollup: rollup,
            myRelation: relations,
            labels: (node.labels?.nodes ?? []).compactMap { $0?.name },
            mergeable: mergeable(node.mergeable)
        )
    }

    /// Merges the same pull request seen through several facet queries, unioning relations.
    ///
    /// The result is sorted by ``InboxGrouper/sorted(_:)`` so callers get a stable list
    /// regardless of the order the facet queries completed in.
    /// - Parameter summaries: All rows returned by all facet queries.
    static func mergeFacetResults(_ summaries: [PullRequestSummary]) -> [PullRequestSummary] {
        var merged: [String: PullRequestSummary] = [:]
        for summary in summaries {
            if var existing = merged[summary.id] {
                existing.myRelation.formUnion(summary.myRelation)
                // Prefer the freshest copy of the mutable fields.
                if summary.updatedAt > existing.updatedAt {
                    var newest = summary
                    newest.myRelation = existing.myRelation
                    merged[summary.id] = newest
                } else {
                    merged[summary.id] = existing
                }
            } else {
                merged[summary.id] = summary
            }
        }
        return InboxGrouper.sorted(Array(merged.values))
    }

    // MARK: - Detail

    /// Maps `GET /pulls/{number}` onto an inbox row.
    ///
    /// Used when a pull request is opened directly rather than found by a sweep; relations
    /// and the check rollup are supplied by the caller because REST cannot report them.
    static func pullRequestSummary(
        from dto: RESTPullRequestDTO,
        repo: RepoRef,
        relations: Set<Relation>,
        reviewDecisionValue: ReviewDecision?,
        rollup: CheckRollup?,
        detector: AgentDetector,
        commitTrailers: [String]
    ) -> PullRequestSummary? {
        guard let number = dto.number,
              let id = dto.nodeId,
              let updatedAt = dto.updatedAt.flatMap(GitHubTimestamp.parse),
              let createdAt = dto.createdAt.flatMap(GitHubTimestamp.parse)
        else { return nil }
        let headRefName = dto.head?.ref ?? ""
        return PullRequestSummary(
            id: id,
            repo: repo,
            number: number,
            title: dto.title ?? "",
            author: makeActor(
                from: dto.user,
                detector: detector,
                branchName: headRefName,
                commitTrailers: commitTrailers
            ),
            updatedAt: updatedAt,
            createdAt: createdAt,
            isDraft: dto.draft ?? false,
            additions: dto.additions ?? 0,
            deletions: dto.deletions ?? 0,
            changedFiles: dto.changedFiles ?? 0,
            headRefName: headRefName,
            headRefOid: dto.head?.sha ?? "",
            baseRefName: dto.base?.ref ?? "",
            reviewDecision: reviewDecisionValue,
            checkRollup: rollup,
            myRelation: relations,
            labels: (dto.labels ?? []).compactMap(\.name),
            mergeable: mergeable(restValue: dto.mergeable, state: dto.mergeableState)
        )
    }

    /// Maps one entry of the files listing.
    static func changedFile(from dto: RESTFileDTO) -> ChangedFile? {
        guard let path = dto.filename else { return nil }
        return ChangedFile(
            path: path,
            previousPath: dto.previousFilename,
            status: FileChangeStatus.fromAPI(dto.status ?? "modified"),
            additions: dto.additions ?? 0,
            deletions: dto.deletions ?? 0,
            patch: dto.patch,
            isViewed: false
        )
    }

    /// Maps one entry of the commits listing.
    static func commit(from dto: RESTCommitDTO, detector: AgentDetector) -> CommitInfo? {
        guard let oid = dto.sha else { return nil }
        let message = dto.commit?.message ?? ""
        let split = CommitInfo.splitMessage(message)
        let date = dto.commit?.author?.date.flatMap(GitHubTimestamp.parse)
            ?? dto.commit?.committer?.date.flatMap(GitHubTimestamp.parse)
            ?? Date(timeIntervalSince1970: 0)
        let author: ShepherdCore.Actor? = dto.author.map {
            makeActor(from: $0, detector: detector)
        }
        return CommitInfo(
            oid: oid,
            messageHeadline: split.headline,
            messageBody: split.body,
            author: author,
            committedDate: date
        )
    }

    /// Maps one check run.
    static func checkRun(from dto: RESTCheckRunsDTO.Run) -> CheckRun? {
        guard let name = dto.name else { return nil }
        let identifier = dto.nodeId ?? dto.id.map { String($0) } ?? name
        return CheckRun(
            id: identifier,
            name: name,
            status: CheckRun.Status.fromAPI(dto.status ?? ""),
            conclusion: dto.conclusion.map(CheckRun.Conclusion.fromAPI),
            detailsURL: dto.detailsUrl.flatMap { URL(string: $0) },
            startedAt: dto.startedAt.flatMap(GitHubTimestamp.parse),
            completedAt: dto.completedAt.flatMap(GitHubTimestamp.parse),
            summary: dto.output?.summary ?? dto.output?.title
        )
    }

    /// Maps one review thread, including its comments.
    static func reviewThread(from dto: ReviewThreadDTO, detector: AgentDetector) -> ReviewThread? {
        guard let id = dto.id else { return nil }
        let comments: [ReviewComment] = (dto.comments?.nodes ?? [])
            .compactMap { $0 }
            .compactMap { commentDTO in
                guard let commentID = commentDTO.id else { return nil }
                return ReviewComment(
                    id: commentID,
                    databaseID: commentDTO.databaseId,
                    author: makeActor(from: commentDTO.author, detector: detector),
                    bodyMarkdown: commentDTO.body ?? "",
                    createdAt: commentDTO.createdAt.flatMap(GitHubTimestamp.parse)
                        ?? Date(timeIntervalSince1970: 0),
                    pendingLocalID: nil
                )
            }
        // `line` is deliberately *not* backfilled from `originalLine`. GraphQL nulls `line`
        // precisely when the thread no longer maps onto the current diff; `originalLine`
        // points into an older commit's diff, so falling back to it anchors the thread to a
        // line that today holds unrelated code. It is carried separately, for display only.
        return ReviewThread(
            id: id,
            path: dto.path,
            line: dto.line,
            originalLine: dto.originalLine,
            side: diffSide(dto.diffSide),
            isResolved: dto.isResolved ?? false,
            isOutdated: dto.isOutdated ?? false,
            comments: comments
        )
    }

    /// Builds a condensed timeline from the commits and reviews of a pull request.
    ///
    /// Shepherd does not mirror GitHub's full timeline API: two cheap listings it already
    /// fetches carry everything a reviewer needs to read the conversation.
    static func timeline(
        commits: [CommitInfo],
        reviews: [RESTReviewDTO],
        detector: AgentDetector
    ) -> [TimelineEvent] {
        var events: [TimelineEvent] = commits.map { commit in
            TimelineEvent(
                id: "commit:\(commit.oid)",
                kind: .commit,
                author: commit.author
                    ?? ShepherdCore.Actor(login: "ghost", kind: .human),
                createdAt: commit.committedDate,
                summary: commit.messageHeadline,
                commitOid: commit.oid
            )
        }

        for review in reviews {
            guard let submittedAt = review.submittedAt.flatMap(GitHubTimestamp.parse) else {
                continue
            }
            let kind: TimelineEvent.Kind
            switch review.state?.uppercased() ?? "" {
            case "APPROVED": kind = .reviewApproved
            case "CHANGES_REQUESTED": kind = .reviewChangesRequested
            case "COMMENTED": kind = .reviewCommented
            default: kind = .other
            }
            let summary: String
            switch kind {
            case .reviewApproved: summary = "Approved"
            case .reviewChangesRequested: summary = "Requested changes"
            case .reviewCommented: summary = "Commented"
            default: summary = review.state ?? "Reviewed"
            }
            events.append(
                TimelineEvent(
                    id: "review:\(review.nodeId ?? String(review.id ?? 0))",
                    kind: kind,
                    author: makeActor(from: review.user, detector: detector),
                    createdAt: submittedAt,
                    summary: summary,
                    // The head the review was submitted against. Carried so that a review
                    // submitted outside Shepherd can still become an interdiff baseline while
                    // the pull request is still on that commit (ADR 0028).
                    commitOid: review.commitId
                )
            )
        }

        return events.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Notifications

    /// Maps one notification thread.
    static func notification(from dto: RESTNotificationDTO) -> NotificationItem? {
        guard let id = dto.id else { return nil }
        let parsed = repoAndNumber(fromSubjectURL: dto.subject?.url)
        let repo: RepoRef? = parsed.0
            ?? dto.repository.flatMap { (repository: RESTRepositoryDTO) -> RepoRef? in
                guard let name = repository.name, let owner = repository.owner?.login else {
                    return nil
                }
                return RepoRef(owner: owner, name: name)
            }
        return NotificationItem(
            id: id,
            reason: NotificationReason.fromAPI(dto.reason ?? ""),
            isUnread: dto.unread ?? true,
            updatedAt: dto.updatedAt.flatMap(GitHubTimestamp.parse)
                ?? Date(timeIntervalSince1970: 0),
            subjectTitle: dto.subject?.title ?? "",
            subjectType: dto.subject?.type ?? "",
            repo: repo,
            pullRequestNumber: dto.subject?.type == "PullRequest" ? parsed.1 : nil
        )
    }
}
