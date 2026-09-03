import Foundation

/// Everything the on-device model is given to summarise one review thread (plan §3.G).
///
/// Pure, `Sendable`, and here rather than beside the digester because of ADR 0007's rule: what a
/// prompt may contain is arithmetic over strings, so it is decided in a target that builds and
/// tests on Linux, and only the model call itself is Apple-only.
///
/// **The whole type is one budget decision.** A thread has no upper length — a design argument on
/// a migration runs to fifty comments, one of them a pasted stack trace — and tier 2's context
/// ceiling is a hard error rather than a truncation (ADR 0007). So the request is built by giving
/// up the **oldest** comments first until what is left fits, which is the eviction pattern the
/// pending-comment quotes already use (`ReviewSummaryDraftRequest.notes(from:budget:)`), and it
/// records how many comments survived. The card then says "Covers the last 8 of 23 comments"
/// instead of presenting a partial digest as a whole one.
///
/// Newest-last is deliberate, and it is *not* the choice the quotes make. A digest answers "where
/// does this thread stand **now**", so the newest comments are the ones that may not be given up,
/// and a model reading a conversation forwards arrives at the end of it holding the present
/// state.
///
/// Three properties fall out of the constants below and are worth stating, because the tests
/// assert them rather than the numbers:
///
/// - ``maximumCommentCharacters`` is smaller than ``minimumTotalCharacters``, so **one** comment
///   always fits: however small the budget and however long the newest comment, the request is
///   never empty for a thread that has text in it.
/// - a comment whose body is only whitespace is dropped before budgeting (there is nothing in it
///   to summarise) but still counts towards ``totalCount``, because that count is the length of
///   the thread as the reviewer counts it in front of them;
/// - the order of ``comments`` is the order of the thread, always, whether or not anything was
///   evicted — a digest built from a reversed conversation would get "who is waiting on whom"
///   exactly backwards.
public struct ThreadDigestRequest: Sendable, Hashable {
    /// One comment of the thread, reduced to what a digest can use.
    ///
    /// Not ``ReviewComment``: the node id, the database id, the pending-draft marker and the
    /// author's avatar are all things a summary has no business seeing, and a request that
    /// carried them would make the prompt's input harder to reason about than it needs to be.
    public struct Comment: Sendable, Hashable {
        /// Who wrote it, spelled the way the thread spells it on screen.
        public var author: String
        /// The comment body as Markdown source, capped by
        /// ``ThreadDigestRequest/build(comments:isResolved:budget:)``.
        public var body: String
        /// When it was posted.
        ///
        /// Carried into the prompt because "who is waiting on whom" is partly a question about
        /// time: a question asked three weeks ago and never answered reads differently from one
        /// asked an hour ago.
        public var createdAt: Date

        /// Creates a comment.
        /// - Parameters:
        ///   - author: Who wrote it.
        ///   - body: The Markdown body.
        ///   - createdAt: When it was posted.
        public init(author: String, body: String, createdAt: Date) {
            self.author = author
            self.body = body
            self.createdAt = createdAt
        }

        /// The digest's view of a fetched review comment.
        ///
        /// ``Actor/bestName`` rather than the login, because the prompt is about a conversation
        /// between people and the reviewer reads the same names two lines below the card.
        /// - Parameter comment: The fetched comment.
        public init(_ comment: ReviewComment) {
            self.init(
                author: comment.author.bestName,
                body: comment.bodyMarkdown,
                createdAt: comment.createdAt
            )
        }
    }

    /// How many comments a thread needs before a digest is offered at all.
    ///
    /// Six. Below that the thread *is* the digest — a reviewer reads five comments faster than
    /// they read a summary of them and then the five anyway — so the button would cost a model
    /// run to save nothing. The number lives here, next to the budgeting, so the view and the
    /// tests cannot disagree about it.
    public static let minimumCommentCount = 6

    /// Each quoted comment is capped to this many characters.
    ///
    /// The per-entry cut, and the one that matters most in practice: the newest comment in a
    /// review thread is very often a pasted log or a stack trace, and without this one comment
    /// would fill the whole budget and push the human sentences — the ones a digest is actually
    /// about — out of the prompt.
    public static let maximumCommentCharacters = 500

    /// Fraction of the tier's character budget the comments may occupy in total.
    ///
    /// Half. Unlike a summary draft, a digest carries no diff and no file list, so the
    /// conversation is the whole input; the other half is left for the instructions, the schema
    /// the framework injects and the answer, all of which share one window.
    public static let commentsShare = 0.5

    /// The comments may always use at least this many characters, however small the budget is.
    public static let minimumTotalCharacters = 1_200

    /// What the scaffolding around one comment costs: the index, the em dash, the timestamp and
    /// the newlines ``promptText`` puts between them.
    static let commentOverheadCharacters = 32

    /// The comments that fit, in the order of the thread — oldest first, newest last.
    public var comments: [Comment]
    /// Whether GitHub has the thread marked resolved.
    ///
    /// Said in the prompt because it changes what "still open" can mean, and for no other
    /// reason: the digest never suggests resolving a thread and cannot resolve one — "Resolve
    /// thread" stays the reviewer's own button (plan §3.G).
    public var isResolved: Bool
    /// How many comments the prompt covers.
    public var coveredCount: Int
    /// How many comments the thread has.
    public var totalCount: Int
    /// The budget the comments were cut to fit.
    public var budget: TokenBudget

    /// Creates a request.
    ///
    /// Prefer ``build(comments:isResolved:budget:)``, which is what applies the caps; this
    /// initialiser exists so a test can state an already-budgeted request by hand.
    /// - Parameters:
    ///   - comments: The covered comments, oldest first.
    ///   - isResolved: Whether the thread is marked resolved.
    ///   - coveredCount: How many comments the prompt covers.
    ///   - totalCount: How many comments the thread has.
    ///   - budget: The budget the comments fit.
    public init(
        comments: [Comment],
        isResolved: Bool = false,
        coveredCount: Int,
        totalCount: Int,
        budget: TokenBudget
    ) {
        self.comments = comments
        self.isResolved = isResolved
        self.coveredCount = coveredCount
        self.totalCount = totalCount
        self.budget = budget
    }

    /// Builds the request for one tier, dropping the oldest comments until it fits.
    ///
    /// Deterministic on purpose, like every other prompt-building function in this layer: three
    /// independent limits and not one guess about a tokenizer — a per-comment character cap, a
    /// share of the tier's character budget, and the eviction order. The same thread therefore
    /// produces the same prompt on every run, and the arithmetic is unit-tested rather than
    /// discovered as a context-window error.
    /// - Parameters:
    ///   - comments: The thread's comments, oldest first, as the thread holds them.
    ///   - isResolved: Whether the thread is marked resolved.
    ///   - budget: The tier's token budget.
    /// - Returns: A request whose ``comments`` are the newest ones that fit.
    public static func build(
        comments: [Comment],
        isResolved: Bool = false,
        budget: TokenBudget
    ) -> ThreadDigestRequest {
        let limit = charactersLimit(in: budget)
        var kept: [Comment] = []
        var used = 0
        // Walked newest-first *while budgeting* and reversed afterwards: the loop gives up what a
        // digest can most afford to lose, and the prompt still reads forwards.
        for comment in comments.reversed() {
            let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let capped = body.count > maximumCommentCharacters
                ? String(body.prefix(maximumCommentCharacters)) + "…"
                : body
            let cost = capped.count + comment.author.count + commentOverheadCharacters
            // The newest comment is kept whatever it costs — see the note on the type about why
            // the caps make that safe — and everything older than the first comment that does
            // not fit is given up with it.
            if used + cost > limit, !kept.isEmpty { break }
            used += cost
            kept.append(
                Comment(author: comment.author, body: capped, createdAt: comment.createdAt)
            )
        }
        return ThreadDigestRequest(
            comments: Array(kept.reversed()),
            isResolved: isResolved,
            coveredCount: kept.count,
            totalCount: comments.count,
            budget: budget
        )
    }

    /// How many characters the comments may occupy inside a budget.
    /// - Parameter budget: The tier's token budget.
    public static func charactersLimit(in budget: TokenBudget) -> Int {
        max(minimumTotalCharacters, Int(Double(budget.maxCharacters) * commentsShare))
    }

    /// Whether the digest covers less than the whole thread.
    ///
    /// What the card's coverage line is drawn from. A digest of part of a conversation is still
    /// worth having; one that does not say so is not.
    public var wasTruncated: Bool { coveredCount < totalCount }

    /// Whether there is anything to summarise at all.
    ///
    /// True for a thread with no comments and for one whose comments are all whitespace. The
    /// caller asks before spending a model run, because an empty prompt would come back as a
    /// confident summary of nothing.
    public var isEmpty: Bool { comments.isEmpty }

    /// The prompt body, oldest comment first.
    ///
    /// The coverage note comes *before* the comments and says how many are missing, because a
    /// truncated conversation a model believes is complete is a conversation it will happily
    /// describe the beginning of.
    public var promptText: String {
        var text = "A review thread on a pull request, \(totalCount) comments in total."
        if isResolved {
            text += " The thread is already marked resolved on GitHub."
        }
        guard !comments.isEmpty else {
            return text + "\n\nNone of the comments has any text to summarise."
        }
        if wasTruncated {
            text += "\n\nOnly the last \(coveredCount) comments are included below."
                + " The \(totalCount - coveredCount) older ones are not,"
                + " so do not describe how the thread began."
        }
        text += "\n\nComments, oldest first:"
        for (index, comment) in comments.enumerated() {
            text += "\n\n[\(index + 1)] \(comment.author)"
                + " — \(ThreadDigestRequest.stamp(for: comment.createdAt))\n\(comment.body)"
        }
        return text
    }

    /// The chars-÷-4 estimate of ``promptText``.
    ///
    /// The fallback measurement, used where the platform cannot count tokens against the real
    /// tokenizer — the same arrangement every other request type has
    /// (``TokenBudget/measured(_:using:)``).
    public var approximateTokenCount: Int {
        budget.approximateTokens(of: promptText)
    }

    /// A `yyyy-MM-dd HH:mm UTC` stamp.
    ///
    /// Built from date components and plain string padding rather than from a `DateFormatter`,
    /// for ``AutoDelegationLedger/dayStamp(for:timeZone:)``'s reasons: no locale can turn this
    /// into a Japanese calendar, nothing differs between macOS and Linux, and the same comment
    /// therefore produces the same prompt on every machine. UTC because the model is being told
    /// how far apart two comments are, not what time it was where the reviewer sits.
    /// - Parameter date: The moment to stamp.
    static func stamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        // Never `nil` for a fixed offset; the fallback keeps the type non-optional rather than
        // naming a platform constant this target cannot check.
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year = padded(parts.year ?? 0, to: 4)
        let month = padded(parts.month ?? 0, to: 2)
        let day = padded(parts.day ?? 0, to: 2)
        let hour = padded(parts.hour ?? 0, to: 2)
        let minute = padded(parts.minute ?? 0, to: 2)
        return "\(year)-\(month)-\(day) \(hour):\(minute) UTC"
    }

    /// Left-pads a non-negative number with zeros.
    private static func padded(_ value: Int, to width: Int) -> String {
        let digits = String(max(0, value))
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}

/// A thread digest together with how much of the thread it covers (plan §3.G).
///
/// The pair is the point. ``ThreadDigest`` is what the model wrote; the two counts are what
/// Shepherd knows about the thread the model was *not* shown, and the card cannot be honest
/// without both. Keeping them in one value means no caller can store a digest and forget its
/// coverage — the failure mode would be a summary of eight comments presented as a summary of
/// twenty-three.
public struct ThreadDigestResult: Sendable, Hashable {
    /// What the model made of the thread.
    public var digest: ThreadDigest
    /// How many comments the digest covers.
    public var coveredCount: Int
    /// How many comments the thread has.
    public var totalCount: Int

    /// Creates a result.
    /// - Parameters:
    ///   - digest: What the model made of the thread.
    ///   - coveredCount: How many comments it covers.
    ///   - totalCount: How many comments the thread has.
    public init(digest: ThreadDigest, coveredCount: Int, totalCount: Int) {
        self.digest = digest
        self.coveredCount = coveredCount
        self.totalCount = totalCount
    }

    /// Whether the digest covers less than the whole thread.
    public var wasTruncated: Bool { coveredCount < totalCount }
}
