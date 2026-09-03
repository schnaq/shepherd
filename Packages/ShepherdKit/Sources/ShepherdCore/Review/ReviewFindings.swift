import Foundation

/// What became of one finding a reviewer left in the previous round (ADR 0028).
///
/// Every state is a statement about *lines and comments*, never about correctness: a fix round
/// that touched the lines a finding was anchored to is ``addressed`` whether or not it fixed
/// anything, and the thread stays open until the reviewer resolves it themselves.
public enum FindingState: String, Sendable, Codable, Hashable, CaseIterable {
    /// The anchored lines changed in the new round.
    case addressed
    /// Neither the lines nor the thread moved.
    case unchanged
    /// The file was renamed, or the lines around the anchor shifted.
    case moved
    /// Somebody other than the reviewer wrote in the thread after the reviewer did.
    case replied

    /// Classifies one thread against an interdiff.
    ///
    /// The order of the checks *is* the rule: a rename and a changed anchor are facts about the
    /// code and outrank a reply, and a reply outranks "unchanged" — an answer in the thread is
    /// the one thing that makes a finding whose lines were left alone worth reading again.
    ///
    /// Which anchor is used depends on the thread: a thread GitHub still maps onto the current
    /// diff is looked up by ``ReviewThread/line`` on the current side, and an outdated one by
    /// ``ReviewThread/originalLine`` on the side that was reviewed. `line` is never backfilled
    /// from `originalLine` — they are numbers in different documents.
    /// - Parameters:
    ///   - thread: The published thread the finding lives in.
    ///   - interdiff: What changed between the reviewed head and the current one.
    ///   - viewerLogin: The signed-in user's login; a comment by anyone else counts as a reply.
    /// - Returns: The state to show beside the finding.
    public static func classify(
        thread: ReviewThread,
        interdiff: [InterdiffFile],
        viewerLogin: String
    ) -> FindingState {
        let replied = hasReply(in: thread, viewerLogin: viewerLogin)
        guard let path = thread.path else {
            // A pull-request-level conversation has no anchor to map, so only the thread itself
            // can have moved on.
            return replied ? .replied : .unchanged
        }
        guard let file = interdiff.first(where: { $0.path == path || $0.previousPath == path })
        else {
            return replied ? .replied : .unchanged
        }
        if file.kind == .renamed { return .moved }
        if !thread.isOutdated, let line = thread.line {
            if file.touchesCurrentLine(line) { return .addressed }
            if file.shift(aboveCurrentLine: line) != 0 { return .moved }
        } else if let original = thread.originalLine {
            if file.touchesReviewedLine(original) { return .addressed }
            if file.shift(aboveReviewedLine: original) != 0 { return .moved }
        }
        return replied ? .replied : .unchanged
    }

    /// Whether somebody other than the viewer wrote in the thread after the viewer last did.
    private static func hasReply(in thread: ReviewThread, viewerLogin: String) -> Bool {
        let mine = thread.comments
            .filter { $0.author.login.caseInsensitiveCompare(viewerLogin) == .orderedSame }
        guard let last = mine.map(\.createdAt).max() else { return false }
        return thread.comments.contains {
            $0.author.login.caseInsensitiveCompare(viewerLogin) != .orderedSame
                && $0.createdAt > last
        }
    }
}

/// One of the reviewer's findings from the round they reviewed, with what became of it.
public struct ReviewFinding: Sendable, Codable, Hashable, Identifiable {
    /// The published thread's node id.
    public var threadID: String
    /// The file the finding is anchored to, when it has one.
    public var path: String?
    /// The line to jump to — the current line when GitHub still maps the thread, otherwise the
    /// line it was written against.
    public var line: Int?
    /// Whether ``line`` refers to the head that was reviewed rather than the current one.
    public var isLineOutdated: Bool
    /// What became of the finding.
    public var state: FindingState
    /// The first line of what the reviewer wrote, for the list.
    public var excerpt: String

    /// Creates a finding.
    /// - Parameters:
    ///   - threadID: The thread's node id.
    ///   - path: The anchored file.
    ///   - line: The line to jump to.
    ///   - isLineOutdated: Whether the line is in the reviewed head's numbering.
    ///   - state: The computed state.
    ///   - excerpt: A one-line excerpt of the reviewer's comment.
    public init(
        threadID: String,
        path: String? = nil,
        line: Int? = nil,
        isLineOutdated: Bool = false,
        state: FindingState,
        excerpt: String
    ) {
        self.threadID = threadID
        self.path = path
        self.line = line
        self.isLineOutdated = isLineOutdated
        self.state = state
        self.excerpt = excerpt
    }

    /// `ReviewFinding` is identified by its thread.
    public var id: String { threadID }
}

/// Builds the "your findings from that round" list (ADR 0028).
public enum ReviewFindings {
    /// How much later than the snapshot a comment may be stamped and still count as that round's.
    ///
    /// The snapshot is written when the outbox drain gets GitHub's acknowledgement, while the
    /// comments carry GitHub's own `createdAt`; the two are seconds apart in the good case and
    /// minutes apart when the drain ran after an offline spell. Five minutes is generous enough
    /// to keep a round together and short enough that the *next* round's findings do not join it.
    public static let submissionGrace: TimeInterval = 300

    /// The reviewer's own findings from the reviewed round, each with its state.
    ///
    /// Only threads the reviewer *started* are findings: a reply of theirs inside somebody
    /// else's thread is a conversation, not a review finding. Resolved threads are left out —
    /// the reviewer closed them, and ADR 0028's rule is that resolving stays a human act.
    /// - Parameters:
    ///   - threads: Every published thread of the pull request.
    ///   - interdiff: What changed since the reviewed head.
    ///   - viewerLogin: The signed-in user's login.
    ///   - reviewedAt: When the review was submitted; findings written later are a later round's.
    /// - Returns: The findings, oldest first.
    public static func compute(
        threads: [ReviewThread],
        interdiff: [InterdiffFile],
        viewerLogin: String,
        reviewedAt: Date? = nil
    ) -> [ReviewFinding] {
        let cutoff = reviewedAt?.addingTimeInterval(submissionGrace)
        return threads
            .filter { thread in
                guard !thread.isResolved, let root = thread.rootComment else { return false }
                guard root.author.login.caseInsensitiveCompare(viewerLogin) == .orderedSame else {
                    return false
                }
                guard let cutoff else { return true }
                return root.createdAt <= cutoff
            }
            .sorted { lhs, rhs in
                let left = lhs.rootComment?.createdAt ?? Date(timeIntervalSince1970: 0)
                let right = rhs.rootComment?.createdAt ?? Date(timeIntervalSince1970: 0)
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
            .map { thread in
                let isOutdated = thread.isOutdated || thread.line == nil
                return ReviewFinding(
                    threadID: thread.id,
                    path: thread.path,
                    line: isOutdated ? thread.originalLine : thread.line,
                    isLineOutdated: isOutdated,
                    state: FindingState.classify(
                        thread: thread,
                        interdiff: interdiff,
                        viewerLogin: viewerLogin
                    ),
                    excerpt: excerpt(of: thread)
                )
            }
    }

    /// The first non-empty line of the thread's first comment, trimmed for a one-line row.
    private static func excerpt(of thread: ReviewThread) -> String {
        let body = thread.rootComment?.bodyMarkdown ?? ""
        let line = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let trimmed = (line.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 120 else { return trimmed }
        return String(trimmed.prefix(119)) + "…"
    }
}
