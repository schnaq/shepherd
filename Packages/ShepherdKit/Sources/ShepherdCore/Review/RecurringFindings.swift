import Foundation

/// One review comment the signed-in user wrote, as the local database holds it.
///
/// The input side of the feedback loop (plan §2.D): the reviewer's *own* review comments, per
/// repository, read out of `review_comments` and nothing else. It carries the pull request's
/// number as well as its node id because the card quotes "you said this on #128" and the number
/// is the only half of that a person recognises — while the node id is what the "≥ 2 different
/// pull requests" rule counts.
///
/// Nobody else's comment is ever one of these. That is not a filter applied late for tidiness: a
/// colleague's sentence has an author who never chose this Mac's endpoints (ADR 0020's reasoning),
/// and a feature that clustered *their* words would be describing them rather than the reviewer.
public struct ViewerReviewComment: Sendable, Hashable, Identifiable {
    /// The comment's node id.
    public var id: String
    /// The repository the pull request belongs to.
    public var repo: RepoRef
    /// The pull request's node id.
    public var prID: String
    /// The pull request's number, for the quote's `#128`.
    public var number: Int
    /// The comment body, as Markdown source.
    public var body: String
    /// When it was written.
    public var createdAt: Date

    /// Creates a comment.
    /// - Parameters:
    ///   - id: The comment's node id.
    ///   - repo: The repository.
    ///   - prID: The pull request's node id.
    ///   - number: The pull request's number.
    ///   - body: The Markdown source.
    ///   - createdAt: When it was written.
    public init(
        id: String,
        repo: RepoRef,
        prID: String,
        number: Int,
        body: String,
        createdAt: Date
    ) {
        self.id = id
        self.repo = repo
        self.prID = prID
        self.number = number
        self.body = body
        self.createdAt = createdAt
    }
}

/// One comment of a recurring finding — a quote the card can show and the draft can cite.
public struct RecurringFindingComment: Sendable, Hashable, Identifiable {
    /// The comment's node id.
    public var id: String
    /// The comment body, as Markdown source.
    public var body: String
    /// The pull request's node id — what the distinct-pull-request rule counts.
    public var prID: String
    /// The pull request's number, for the quote's `#128`.
    public var number: Int
    /// When it was written.
    public var createdAt: Date

    /// Creates a comment.
    /// - Parameters:
    ///   - id: The comment's node id.
    ///   - body: The Markdown source.
    ///   - prID: The pull request's node id.
    ///   - number: The pull request's number.
    ///   - createdAt: When it was written.
    public init(id: String, body: String, prID: String, number: Int, createdAt: Date) {
        self.id = id
        self.body = body
        self.prID = prID
        self.number = number
        self.createdAt = createdAt
    }
}

/// A finding the reviewer has written again and again on one repository's pull requests.
///
/// The value the card is drawn from and the rule draft is written from. It is a *suggestion to a
/// person*: it names no pull request to fix, carries no verdict, and cannot start anything. The
/// only thing it can turn into is text in the delegation sheet's task field, which the reviewer
/// then edits and runs themselves (ADR 0029, amending ADR 0011).
public struct RecurringFinding: Sendable, Hashable, Identifiable {
    /// The repository whose pull requests the comments were written on.
    public var repo: RepoRef
    /// The comment that stands for the cluster — the shortest one (see ``exemplar(of:)``).
    public var exemplar: String
    /// Every comment in the cluster, oldest first.
    public var comments: [RecurringFindingComment]

    /// Creates a finding.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - exemplar: The comment that stands for the cluster.
    ///   - comments: The cluster's comments, oldest first.
    public init(repo: RepoRef, exemplar: String, comments: [RecurringFindingComment]) {
        self.repo = repo
        self.exemplar = exemplar
        self.comments = comments
    }

    /// How many times the reviewer said it.
    ///
    /// Derived rather than stored, so a finding whose comments were filtered by a caller cannot
    /// claim a count its quotes do not support.
    public var count: Int { comments.count }

    /// How many different pull requests the comments are spread across.
    public var distinctPullRequestCount: Int { Set(comments.map(\.prID)).count }

    /// The finding's identity, which is also the key a dismissal is remembered under.
    public var id: String { dismissalKey }

    /// The key a per-repository dismissal is stored under.
    ///
    /// A hash of the repository and the exemplar rather than of every comment in the cluster, and
    /// that is the interesting choice: the *next* pull request adds a fourth comment to the same
    /// cluster, and a key that covered the whole cluster would let the same dismissed card come
    /// back the moment the reviewer said the thing once more. Keying on the exemplar means "I have
    /// decided about *this sentence* on *this repository*" stays decided — while a genuinely
    /// different finding, whose shortest comment is a different sentence, is a different key and
    /// therefore a card the reviewer has never seen.
    ///
    /// FNV-1a through ``SearchContentHash``, for ``SavedReplySuggester/bodyKey(for:)``'s reason:
    /// `Hasher` is seeded per process, and this key has to mean the same thing after a relaunch.
    /// Nothing here is a security boundary — the property being bought is a stable name.
    public var dismissalKey: String {
        RecurringFindingDetector.dismissalKey(repo: repo, exemplar: exemplar)
    }
}

/// Which of the reviewer's own review comments they have now written three times (plan §2.D).
///
/// The pure half of the feedback loop, and the whole of its judgement. It takes one embedding per
/// comment — produced by the app's on-device embedder behind `EmbeddingProviding`, exactly as
/// ``SavedReplySuggester`` takes one per saved reply — and answers with clusters. Everything
/// Apple-only stays in the app target, which is what lets these rules be tested by `swift test`
/// on the Linux runner where no embedding model exists (ADR 0019's split).
///
/// Five things are decisions rather than mechanics, and each one has a named constant here so it
/// has a single home and a test around it:
///
/// - **A count *and* a spread.** ``minimumCount`` comments are not enough on their own: three
///   comments on one pull request are one conversation about one mistake, not a pattern in the
///   repository's agent output. ``minimumDistinctPullRequests`` is what turns "I argued about
///   this once" into "this keeps happening", and it is the reason a card cannot appear on the
///   strength of a single long thread.
/// - **A window, so the past expires.** A rule drafted from comments the reviewer wrote in March
///   would describe a habit the agent may have lost. ``defaultWindow`` is the interview's thirty
///   days, and it is applied to the comment's own timestamp rather than to the sweep that read
///   it, so an old pull request re-entering the inbox brings no old finding with it.
/// - **A similarity floor above the register's own noise.** ``minimumSimilarity`` is 0.6, well
///   above ADR 0019's search cut-off (0.35) and above the saved-reply floor (0.45), because this
///   corpus is the narrowest of the three: every candidate is short review prose written by one
///   person in one voice, so *any* two of them score high against each other. The floor has to
///   sit above the band that "nit: naming" and "please add a test" reach by accident, or every
///   reviewer with thirty comments would have one enormous cluster called "review".
/// - **Greedy, seeded by the oldest comment.** Each unassigned comment in a fixed order becomes a
///   seed and every remaining comment near *it* joins. Not k-means, not average-linkage: those
///   need a `k`, or a merge order, and both would make the answer depend on arithmetic nobody can
///   check by hand. The cost is that a chain of comments drifting in meaning is cut where the
///   seed's neighbourhood ends, which is the honest behaviour for a card that quotes three
///   sentences and claims they are the same sentence.
/// - **A total order, twice over.** The clusters come back largest first and the comments inside
///   one come back oldest first, with every tie broken by something stable (see ``detect``). Two
///   sweeps that read the same comments must produce the same card in the same order — a card
///   that reshuffled its quotes between sweeps would look like new information.
///
/// Nothing in this type is a language model, a network call or a setting. It is arithmetic over
/// vectors the reviewer's own Mac produced, over sentences the reviewer wrote themselves.
public enum RecurringFindingDetector {
    /// The version of the detection rules.
    ///
    /// Part of ``dismissalKey(repo:exemplar:)``, so changing what a cluster means also retires
    /// every dismissal made under the old rules instead of silently honouring them.
    public static let schemaVersion = 1

    /// How far back a comment may have been written and still count: thirty days.
    ///
    /// The interview's number ("the third time in a month"). Expressed in seconds rather than in
    /// calendar months on purpose — a month is not a fixed length, and a rule whose window grew
    /// in March would be a rule nobody could predict.
    public static let defaultWindow: TimeInterval = 30 * 24 * 60 * 60

    /// How many comments a cluster needs before it is a recurring finding.
    public static let minimumCount = 3

    /// How many *different* pull requests those comments must be spread across.
    public static let minimumDistinctPullRequests = 2

    /// The cosine two comments must reach before they count as the same finding.
    ///
    /// See the type's note for why it is higher than both other floors in the app.
    public static let minimumSimilarity = 0.6

    /// How many comments the card and the rule draft quote.
    ///
    /// Three, which is also ``minimumCount``: the card's sentence is "you have said this three
    /// times", and a card that quoted eleven comments would be a thread, not a prompt to act.
    public static let maximumQuotes = 3

    /// The key a per-repository dismissal is remembered under.
    /// - Parameters:
    ///   - repo: The repository the finding belongs to.
    ///   - exemplar: The finding's exemplar comment.
    /// - Returns: A lower-case hex key, stable across launches.
    public static func dismissalKey(repo: RepoRef, exemplar: String) -> String {
        SearchContentHash.hex([
            "v\(schemaVersion)",
            repo.fullName.lowercased(),
            exemplar.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
    }

    /// The comment that stands for a cluster: the shortest one.
    ///
    /// The shortest, because the reviewer's shortest phrasing of a thing they have written three
    /// times is the one closest to the *rule* — "please add a test for the error path" rather than
    /// the same request wrapped in two paragraphs about this particular function. Ties are broken
    /// by the older comment and then by the id, so the exemplar of a given set of comments never
    /// depends on the order they arrived in.
    ///
    /// - Parameter comments: The cluster's comments. Must not be empty.
    /// - Returns: The exemplar body, trimmed.
    public static func exemplar(of comments: [RecurringFindingComment]) -> String {
        let best = comments.min { left, right in
            let leftBody = left.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let rightBody = right.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if leftBody.count != rightBody.count { return leftBody.count < rightBody.count }
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
            return left.id < right.id
        }
        return (best?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Detection

    /// Finds the recurring findings among one repository's comments.
    ///
    /// Called once per repository, because a finding *is* about a repository: the rule it would
    /// become goes into that repository's instructions file, and "you keep asking for tests" is
    /// not a statement about a Mac.
    ///
    /// The order of the answer is fixed and total: cluster size descending, then the newest
    /// comment descending, then the exemplar ascending. Inside a finding, comments are oldest
    /// first, ties by id ascending.
    ///
    /// - Parameters:
    ///   - repo: The repository whose comments these are.
    ///   - comments: One entry per comment of the reviewer's own, with its embedding. Order is
    ///     irrelevant: this function imposes its own. An entry with an empty body or an empty
    ///     vector is dropped rather than treated as a cluster of one — a comment the model had
    ///     nothing to say about is not evidence of anything.
    ///   - now: The clock, so the window is testable.
    ///   - window: How far back a comment may have been written. Defaults to ``defaultWindow``.
    ///   - minimumCount: How many comments a cluster needs. Defaults to ``minimumCount``.
    ///   - minimumDistinctPullRequests: How many different pull requests they must be spread
    ///     across. Defaults to ``minimumDistinctPullRequests``.
    ///   - similarity: The cosine floor. Defaults to ``minimumSimilarity``.
    /// - Returns: The findings, largest first, and **empty** whenever nothing recurs. Empty is
    ///   the normal answer and "no card" is what it means.
    public static func detect(
        repo: RepoRef,
        comments: [(
            id: String,
            body: String,
            prID: String,
            number: Int,
            createdAt: Date,
            vector: SearchVector
        )],
        now: Date,
        window: TimeInterval = RecurringFindingDetector.defaultWindow,
        minimumCount: Int = RecurringFindingDetector.minimumCount,
        minimumDistinctPullRequests: Int = RecurringFindingDetector.minimumDistinctPullRequests,
        similarity: Double = RecurringFindingDetector.minimumSimilarity
    ) -> [RecurringFinding] {
        guard minimumCount > 0, window > 0 else { return [] }

        // The window is applied to the comment's own timestamp. A comment dated in the future —
        // a skewed clock on the machine that wrote it — is inside the window rather than
        // discarded: it is still something the reviewer said, and the alternative is a card that
        // silently disappears because of somebody else's clock.
        let cutoff = now.addingTimeInterval(-window)
        var candidates = comments.filter { candidate in
            guard !candidate.vector.isEmpty else { return false }
            guard !candidate.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return candidate.createdAt > cutoff
        }
        guard candidates.count >= minimumCount else { return [] }

        // The seeding order, and therefore the whole answer, is fixed here: oldest first, ties by
        // id. Without this the greedy pass would depend on the order the database happened to
        // return, which is not something a card may depend on.
        candidates.sort { left, right in
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
            return left.id < right.id
        }

        var isTaken = [Bool](repeating: false, count: candidates.count)
        var findings: [RecurringFinding] = []
        for seedIndex in candidates.indices where !isTaken[seedIndex] {
            isTaken[seedIndex] = true
            var members = [candidates[seedIndex]]
            var memberIndices: [Int] = []
            for index in candidates.indices where index > seedIndex && !isTaken[index] {
                // `nil` — mismatched dimensions, or a zero-length vector — is "this question has
                // no answer", never "these are unrelated"; such a comment simply does not join
                // this cluster and stays available as a seed of its own.
                guard let cosine = candidates[seedIndex].vector
                    .cosineSimilarity(to: candidates[index].vector)
                else { continue }
                guard cosine >= similarity else { continue }
                memberIndices.append(index)
                members.append(candidates[index])
            }

            // A seed that attracted too few comments claims none of them: a comment that matched
            // this seed by chance may be the first of a real cluster further down, and locking it
            // here would leave that cluster one short of the count the whole feature is about.
            guard members.count >= minimumCount else { continue }
            for index in memberIndices { isTaken[index] = true }
            let clusterComments = members.map {
                RecurringFindingComment(
                    id: $0.id,
                    body: $0.body.trimmingCharacters(in: .whitespacesAndNewlines),
                    prID: $0.prID,
                    number: $0.number,
                    createdAt: $0.createdAt
                )
            }
            let finding = RecurringFinding(
                repo: repo,
                exemplar: exemplar(of: clusterComments),
                // Already in seed order, which is oldest-first with ids breaking ties; sorted
                // again so the promise holds whatever a future seeding order does.
                comments: clusterComments.sorted { left, right in
                    if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
                    return left.id < right.id
                }
            )
            guard finding.distinctPullRequestCount >= minimumDistinctPullRequests else { continue }
            findings.append(finding)
        }

        findings.sort { left, right in
            if left.count != right.count { return left.count > right.count }
            let leftLatest = left.comments.last?.createdAt ?? .distantPast
            let rightLatest = right.comments.last?.createdAt ?? .distantPast
            if leftLatest != rightLatest { return leftLatest > rightLatest }
            return left.exemplar < right.exemplar
        }
        return findings
    }
}
