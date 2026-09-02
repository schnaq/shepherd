import Foundation

/// How much of a thread's conversation may become the text a saved-reply suggestion is ranked
/// against.
///
/// The same reasoning as ``SearchDocumentBudget``, applied to a smaller input: a review thread has
/// no upper bound either — a design argument on a migration can run to fifty comments, one of them
/// a pasted stack trace — and without an explicit ceiling the cost of opening the insert menu
/// would grow with whichever thread happens to be the longest in the repository.
///
/// The numbers are deliberately small. The embedder chunks its input at ~600 characters and stops
/// after eight chunks (`EmbeddingChunker` in the app target), so anything past a couple of
/// kilobytes is thrown away one layer down anyway; spending the trimming here rather than
/// discovering it there is what makes the cost predictable and the vector reproducible.
/// ``totalBytes`` matches ``SearchDocumentBudget/bodyBytes`` for the same reason — both are "as
/// much prose as describes the subject", and having the two agree means one number to reason
/// about.
public struct SavedReplyThreadBudget: Sendable, Hashable {
    /// How many bytes of thread conversation are embedded, across all comments.
    public var totalBytes: Int
    /// How many bytes of a *single* comment are embedded.
    ///
    /// The per-entry cut, and it is the one that matters most in practice: a thread's newest
    /// comment is very often a pasted log or a diff, and without this one comment would fill the
    /// whole budget and push the human sentences — the ones a saved reply actually answers — out
    /// of the vector. ``SearchDocumentBudget/maximumAddedLineLength`` exists for the same reason.
    public var commentBytes: Int

    /// Creates a budget.
    /// - Parameters:
    ///   - totalBytes: Bytes across all comments.
    ///   - commentBytes: Bytes of any single comment.
    public init(totalBytes: Int = 2_000, commentBytes: Int = 700) {
        self.totalBytes = totalBytes
        self.commentBytes = commentBytes
    }

    /// The budget the app suggests with.
    public static let standard = SavedReplyThreadBudget()
}

/// Which saved replies fit a review thread, decided from vectors alone.
///
/// The pure half of the saved-reply suggestion: it takes a thread's embedding and one embedding
/// per saved reply and answers with at most two ids, in order. Everything Apple-only — the
/// embedding model itself, its availability, the cache that keeps a vector per reply body — lives
/// in the app target behind `EmbeddingProviding`, exactly as ADR 0019 split ``SearchVector`` from
/// `NaturalLanguageEmbedder`. That split is what lets the ranking rules below be tested by
/// `swift test` on the Linux runner, where no embedding model exists.
///
/// Three rules are decisions rather than mechanics, and each one is here so it has a single home:
///
/// - **A hard similarity floor, not a relative "best two".** Every reply has a cosine with every
///   thread, so a relative ranking always has an answer — which is failure mode 2 of ADR 0019
///   ("a palette that always has an answer") wearing different clothes. A suggestion the reviewer
///   has to read and reject is worse than no suggestion, because it costs attention on every
///   single comment they write.
/// - **A shortlist or nothing.** With fewer than ``minimumCandidateCount`` saved replies the
///   "Suggested" section would be the whole list with a header on it, which teaches the reviewer
///   that the section means nothing.
/// - **A total order.** Similarity descending, then id ascending, so two replies that score
///   identically — easy, since a reply body is short and two of them can embed to the same
///   direction — cannot swap places between two openings of the same menu. The promise
///   `SearchRanker` makes about the palette, made here about the menu.
///
/// Nothing in this type is a language model, a network call or a setting. It is arithmetic over
/// vectors the user's own Mac produced.
public enum SavedReplySuggester {
    /// The version of the suggestion rules.
    ///
    /// Part of ``bodyKey(for:)``, so changing what is embedded for a reply invalidates every
    /// cached vector by construction rather than leaving a cache two different Shepherds filled.
    public static let schemaVersion = 1

    /// How many replies the "Suggested" section may hold.
    ///
    /// Two, because the section's whole value is that it is *shorter* than the list below it: a
    /// reviewer scanning five suggestions is reading the menu they already had.
    public static let defaultLimit = 2

    /// The cosine a reply must reach before it may be called a suggestion.
    ///
    /// **Why 0.45 and not ADR 0019's 0.35.** The search cut-off is applied to a query against a
    /// corpus of hundreds of pull requests whose documents contain titles, paths and diff lines —
    /// text of many different registers, so an unrelated document really does score low. A saved
    /// reply is the opposite: a handful of candidates, all of them short review prose written in
    /// the same voice ("please add a test for this branch", "nit: naming"), which puts their
    /// cosines against *any* review thread systematically higher and closer together. The floor
    /// therefore has to sit above the band that short same-register prose reaches by accident,
    /// and 0.45 is that point. It is a documented judgement, not a measurement — which is why it
    /// is one named constant with tests around it rather than a number inlined in a comparison.
    public static let minimumSimilarity = 0.45

    /// How many saved replies must exist before any of them may be suggested.
    public static let minimumCandidateCount = 3

    // MARK: - Ranking

    /// Picks the saved replies nearest to a thread.
    ///
    /// - Parameters:
    ///   - threadVector: The thread's embedding.
    ///   - replies: One entry per candidate saved reply, with the embedding of its body. Order is
    ///     irrelevant: the result's order is the ranking's.
    ///   - limit: How many ids to return at most. Defaults to ``defaultLimit``.
    ///   - minimumSimilarity: The floor a candidate must reach. Defaults to
    ///     ``minimumSimilarity``.
    /// - Returns: The best ids, best first, and **empty** when nothing clears the floor, when
    ///   there are too few candidates, or when the thread has no usable vector. Empty is the
    ///   normal answer and the menu's plain list is what it means.
    public static func rank(
        threadVector: SearchVector,
        replies: [(id: SavedReply.ID, vector: SearchVector)],
        limit: Int = SavedReplySuggester.defaultLimit,
        minimumSimilarity: Double = SavedReplySuggester.minimumSimilarity
    ) -> [SavedReply.ID] {
        guard limit > 0, !threadVector.isEmpty else { return [] }
        // Enforced here as well as by the caller that avoids spending the embeddings: the rule is
        // about what may be *shown*, so it belongs where the shown list is decided.
        guard replies.count >= minimumCandidateCount else { return [] }

        var scored: [(id: SavedReply.ID, similarity: Double)] = []
        for candidate in replies {
            // `nil` — mismatched dimensions, or a zero-length vector — is "this question has no
            // answer", not "these are unrelated", and a candidate with no answer is simply not a
            // candidate. Never coerced to 0, which would make it comparable to a real mismatch.
            guard let similarity = threadVector.cosineSimilarity(to: candidate.vector) else {
                continue
            }
            guard similarity >= minimumSimilarity else { continue }
            scored.append((id: candidate.id, similarity: similarity))
        }
        scored.sort { left, right in
            if left.similarity != right.similarity { return left.similarity > right.similarity }
            // `uuidString` rather than the `UUID` itself, which Foundation does not make
            // `Comparable`. Any stable total order will do; this one is also readable in a test.
            return left.id.uuidString < right.id.uuidString
        }
        return scored.prefix(limit).map { $0.id }
    }

    // MARK: - Thread text

    /// Composes the text of a thread, trimmed to a byte budget.
    ///
    /// **Newest comments are the last to be dropped.** A thread is a conversation, and what a
    /// reviewer is about to reply to is its *end*: the opening comment may be three weeks and two
    /// force-pushes old, while the last one is the question on the screen. So the budget is filled
    /// from the newest comment backwards and the oldest ones fall off — the mirror image of
    /// ``SearchDocument``'s file paths, which are filled from the front because there the *first*
    /// entries are the most telling.
    ///
    /// What survives is always the newest contiguous run of comments, in chronological order: the
    /// loop stops at the first comment that does not fit rather than skipping it to pick up a
    /// smaller older one, because a conversation with a hole in the middle is not a summary of
    /// anything. Only the newest comment may be cut mid-way, and only when it alone exceeds the
    /// whole budget — returning nothing for a thread whose last comment is a pasted log would
    /// silently disable the feature on exactly the threads that have the most to match against.
    ///
    /// - Parameters:
    ///   - comments: The comment bodies, **oldest first** — the order ``ReviewThread/comments``
    ///     is documented to be in.
    ///   - budget: The byte ceilings. Defaults to ``SavedReplyThreadBudget/standard``.
    /// - Returns: The comments that fit, oldest first, separated by a blank line; `""` when there
    ///   is nothing to embed.
    public static func threadText(
        from comments: [String],
        budget: SavedReplyThreadBudget = .standard
    ) -> String {
        guard budget.totalBytes > 0, budget.commentBytes > 0 else { return "" }
        var kept: [String] = []
        var used = 0
        for comment in comments.reversed() {
            let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let capped = SearchText.clamped(trimmed, toBytes: budget.commentBytes)
            let size = capped.utf8.count
            if used + size <= budget.totalBytes {
                kept.append(capped)
                used += size
            } else if kept.isEmpty {
                // The newest comment on its own is over budget. Cutting it is the only answer
                // that leaves the feature working; nothing older can fit behind it anyway.
                let fitted = SearchText.clamped(capped, toBytes: budget.totalBytes)
                if !fitted.isEmpty { kept.append(fitted) }
                break
            } else {
                break
            }
        }
        return kept.reversed().joined(separator: "\n\n")
    }

    // MARK: - Cache keys

    /// The cache key for one saved reply's body.
    ///
    /// The invalidation rule of the whole feature, in one function: a reply's vector is cached
    /// under a hash of the text that produced it, so *editing the body is what invalidates it* —
    /// there is no timestamp to compare, no notification to miss, and no way for a stale vector
    /// to survive an edit. Keying on the reply's ``SavedReply/id`` instead would do the opposite:
    /// the id is stable across edits on purpose (renaming keeps the row), so an edited body would
    /// keep ranking as the text it used to be.
    ///
    /// FNV-1a, and not `Hasher`, for the reason ``SearchDocument/documentHash`` is not: `Hasher`
    /// is seeded per process. Nothing here is a security boundary — the property being bought is
    /// change detection.
    ///
    /// - Parameter body: The reply body. Surrounding whitespace is ignored, because it is trimmed
    ///   out of the text that gets embedded too (``SavedReply/trimmedBody``) and two bodies that
    ///   embed identically must not cost two embeddings.
    /// - Returns: A lower-case hex key.
    public static func bodyKey(for body: String) -> String {
        SearchContentHash.hex([
            "v\(schemaVersion)",
            body.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
    }
}
