import Foundation

/// One row of the conversation tab, in the order it is drawn (ADR 0043).
public enum ConversationEntry: Sendable, Hashable, Identifiable {
    /// A comment on the conversation.
    case comment(ConversationComment)
    /// A review, with the threads its comments started, in GitHub's thread order.
    case review(ConversationReview, threads: [ReviewThread])
    /// A thread whose review is not in the timeline, drawn at the time of its first comment.
    case thread(ReviewThread)
    /// Consecutive commits with nothing else between them, oldest first. Never empty.
    case commits([CommitInfo])
    /// Anything else that happened.
    case event(ConversationEventItem)

    /// Unique within one stream: the kind, then the node id (a commit group's first commit).
    public var id: String {
        switch self {
        case .comment(let comment): return "comment:\(comment.id)"
        case .review(let review, _): return "review:\(review.id)"
        case .thread(let thread): return "thread:\(thread.id)"
        case .commits(let commits): return "commits:\(commits.first?.oid ?? "")"
        case .event(let event): return "event:\(event.id)"
        }
    }
}

/// Puts GitHub's timeline, the commits and the review threads into one stream, the way GitHub's
/// own conversation tab reads (ADR 0043).
///
/// Pure, so the order is asserted by tests rather than inferred from a screenshot.
public enum ConversationTimeline {
    /// Builds the stream.
    ///
    /// - The timeline's items keep GitHub's order; nothing inside it is re-sorted.
    /// - Commits come from the REST list the detail fetch already reads, are slotted in by date,
    ///   and run together into one group until something else happens.
    /// - A thread is drawn under the review its first comment was submitted in. A thread whose
    ///   review is not in the timeline stands on its own at the time of its first comment.
    /// - A `COMMENT` review with no words and no thread of its own says nothing and is left out;
    ///   a verdict without words is kept, because the verdict is what it says.
    /// - A close from the merge on is left out. GitHub records a `ClosedEvent` with every merge,
    ///   by the same person and within a second of it, and its own page shows only the merge; a
    ///   merged pull request cannot be reopened, so every later close is that echo. A close and
    ///   reopen before the merge stay. Here rather than in the read, so a conversation stored
    ///   before this rule is drawn by it too.
    /// - When the conversation was cut (``PullRequestConversation/hasEarlierItems``), commits and
    ///   threads older than its first item are left out with the items they sat between.
    /// - Parameters:
    ///   - conversation: The timeline, or `nil` when none has been read.
    ///   - commits: The head branch's commits, oldest first.
    ///   - threads: Every review thread, in GitHub's order.
    /// - Returns: The stream, oldest first.
    public static func entries(
        conversation: PullRequestConversation?,
        commits: [CommitInfo],
        threads: [ReviewThread]
    ) -> [ConversationEntry] {
        let items = conversation?.items ?? []
        let reviewIDs = Set(items.compactMap { item -> String? in
            if case .review(let review) = item { return review.id }
            return nil
        })

        var threadsByReview: [String: [ReviewThread]] = [:]
        var orphans: [(date: Date, entry: ConversationEntry)] = []
        for thread in threads {
            guard let first = thread.comments.first else { continue }
            if let reviewID = first.reviewID, reviewIDs.contains(reviewID) {
                threadsByReview[reviewID, default: []].append(thread)
            } else {
                orphans.append((first.createdAt, .thread(thread)))
            }
        }

        let mergedAt = items.lazy.compactMap { item -> Date? in
            guard case .event(let event) = item, case .merged = event.event else { return nil }
            return event.createdAt
        }.first

        let timeline: [(date: Date, entry: ConversationEntry)] = items.compactMap { item in
            switch item {
            case .comment(let comment):
                return (comment.createdAt, .comment(comment))
            case .review(let review):
                let started = threadsByReview[review.id] ?? []
                let isSilent = review.state == .commented && !review.hasBody && started.isEmpty
                return isSilent ? nil : (review.createdAt, .review(review, threads: started))
            case .event(let event):
                if case .closed = event.event, let mergedAt, event.createdAt >= mergedAt { return nil }
                return (event.createdAt, .event(event))
            }
        }

        let cutoff = conversation?.hasEarlierItems == true ? items.first?.createdAt : nil
        let isInWindow: (Date) -> Bool = { date in cutoff.map { date >= $0 } ?? true }
        let commitEntries = commits.enumerated()
            .sorted { ($0.element.committedDate, $0.offset) < ($1.element.committedDate, $1.offset) }
            .map { (date: $0.element.committedDate, entry: ConversationEntry.commits([$0.element])) }
            .filter { isInWindow($0.date) }
        let orphanEntries = orphans
            .enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
            .filter { isInWindow($0.date) }

        return grouped(merge([timeline, commitEntries, orphanEntries]))
    }

    /// Merges lists that are each in order, taking the earliest head each time; on a tie the
    /// earlier list wins, so GitHub's items come before a commit or a thread of the same second.
    private static func merge(_ lists: [[(date: Date, entry: ConversationEntry)]]) -> [ConversationEntry] {
        var heads = Array(repeating: 0, count: lists.count)
        var merged: [ConversationEntry] = []
        merged.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        while true {
            var pick: Int?
            for list in lists.indices where heads[list] < lists[list].count {
                guard let current = pick else {
                    pick = list
                    continue
                }
                if lists[list][heads[list]].date < lists[current][heads[current]].date {
                    pick = list
                }
            }
            guard let list = pick else { return merged }
            merged.append(lists[list][heads[list]].entry)
            heads[list] += 1
        }
    }

    /// Runs consecutive single-commit entries together into one group.
    private static func grouped(_ entries: [ConversationEntry]) -> [ConversationEntry] {
        var result: [ConversationEntry] = []
        for entry in entries {
            if case .commits(let next) = entry, case .commits(let previous)? = result.last {
                result[result.count - 1] = .commits(previous + next)
            } else {
                result.append(entry)
            }
        }
        return result
    }
}
