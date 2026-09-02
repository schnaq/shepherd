import Foundation
import Observation
import ShepherdCore

/// Spends the on-device embeddings that put two saved replies at the top of the insert menu.
///
/// The app half of the saved-reply suggestion, and the counterpart of ``SearchIndexCoordinator``:
/// every *decision* is a pure value in `ShepherdCore` (``ShepherdCore/SavedReplySuggester``), and
/// this type supplies the inputs, spends the embeddings and holds the cache. It is created inert —
/// no model is loaded and no vector exists until a reviewer actually opens the menu on a thread.
///
/// Five things about it are decisions rather than mechanics:
///
/// - **It reuses ADR 0019's embedder and adds nothing.** The dependency is
///   ``EmbeddingProviding``, whose only production implementation is `NaturalLanguageEmbedder`.
///   There is no `IntelligenceRouter` here, no base URL, no key and no language model, so the
///   structural rule ADR 0019 states for `Features/Search/` holds for this feature too: the BYOK
///   endpoint is unreachable from here, and it is unreachable by construction rather than by a
///   setting somebody could flip.
/// - **One vector per reply *body*, cached under a hash of that body.** Editing a reply in
///   Settings changes its ``ShepherdCore/SavedReplySuggester/bodyKey(for:)`` and therefore costs
///   exactly one new embedding, while a rename costs none — the id is deliberately stable across
///   edits, so it would have been the wrong key (see that function's note).
/// - **The thread's vector is computed when the menu is about to open**, not while the reviewer
///   types. A reply field changes on every keystroke and the thread it belongs to does not; an
///   embedding per keystroke would be paying, all day, for an answer that cannot have changed.
/// - **Availability is asked once and remembered for the life of the app.** Whether this Mac has
///   the sentence-embedding model is a property of the Mac, and the first ask is also what loads
///   it. When the answer is "no", every call returns an empty list and the menu is exactly the
///   plain list it has always been — the degraded state is the same code path, as it is for
///   search.
/// - **It offers, it never inserts.** The only thing this type produces is a list of ids that a
///   menu may put in a section. There is no path from here to a composer's text, to the pending
///   review or to the outbox: insertion stays the reviewer's click on a menu row, which is the
///   guardrail the plan states for this feature.
@MainActor
@Observable
final class SavedReplySuggestionCoordinator {
    /// How many saved replies must exist before a shortlist means anything.
    ///
    /// Taken from the pure rule rather than restated, so the early exit that avoids spending the
    /// embeddings and the rule that decides what may be shown cannot drift apart.
    static let minimumReplyCount = SavedReplySuggester.minimumCandidateCount

    private let embedder: any EmbeddingProviding
    private let budget: SavedReplyThreadBudget

    /// One vector per saved-reply body, keyed by ``ShepherdCore/SavedReplySuggester/bodyKey(for:)``.
    private var replyVectors: [String: SearchVector] = [:]
    /// The model's answer about this Mac, once it has been asked.
    private var cachedAvailability: EmbeddingAvailability?
    /// How many calls are between their first and last `await` right now.
    ///
    /// Only the pruning below reads it. Two menus cannot be open at once, but two hovers over the
    /// same button can overlap, and the prune must not throw away a vector a call still running
    /// beside it has just paid for.
    private var inFlightCount = 0

    /// Creates a coordinator.
    /// - Parameters:
    ///   - embedder: The embedding seam. The default is the on-device model — the same actor ⌘K
    ///     search uses, and the reason a test can drive this type without Apple's model being
    ///     present or its output being stable.
    ///   - budget: How much of a thread may be embedded.
    init(
        embedder: any EmbeddingProviding = NaturalLanguageEmbedder(),
        budget: SavedReplyThreadBudget = .standard
    ) {
        self.embedder = embedder
        self.budget = budget
    }

    /// How many reply bodies currently have a cached vector.
    ///
    /// `internal` rather than private so `ShepherdTests` can assert the invalidation rule
    /// directly — the same kind of seam ``SearchIndexCoordinator/passTask`` is. Nothing in the app
    /// reads it.
    var cachedBodyCount: Int { replyVectors.count }

    // MARK: - Suggesting

    /// Ranks the saved replies against a thread's conversation.
    ///
    /// The entry point the composers use: it does the byte trimming
    /// (``ShepherdCore/SavedReplySuggester/threadText(from:budget:)``) so that no view has to know
    /// what a thread may cost.
    /// - Parameters:
    ///   - comments: The thread's comment bodies, oldest first.
    ///   - replies: The saved replies the menu is about to show.
    /// - Returns: At most two ids, best first, and empty whenever there is nothing worth
    ///   suggesting.
    func suggestions(
        forThreadComments comments: [String],
        replies: [SavedReply]
    ) async -> [SavedReply.ID] {
        await suggestions(
            for: SavedReplySuggester.threadText(from: comments, budget: budget),
            replies: replies
        )
    }

    /// Ranks the saved replies against a piece of thread text.
    ///
    /// Empty is a normal answer with a single meaning everywhere it can occur — no thread text, no
    /// model on this Mac, too few replies, or nothing that clears the similarity floor — and that
    /// meaning is "show the plain list". There is deliberately no error to report and nothing to
    /// print: a menu that opened with a warning in it because an embedding did not happen would be
    /// a worse menu than the one Shepherd shipped with.
    /// - Parameters:
    ///   - threadText: The conversation to match against.
    ///   - replies: The saved replies the menu is about to show.
    /// - Returns: At most two ids, best first.
    func suggestions(for threadText: String, replies: [SavedReply]) async -> [SavedReply.ID] {
        let candidates = replies.filter(\.isUsable)
        // Checked before anything is spent, and again inside `rank`: here it saves the
        // embeddings, there it is the rule about what may be shown.
        guard candidates.count >= Self.minimumReplyCount else { return [] }
        // Clamped as well as trimmed, because this method is also reachable with text a caller
        // composed itself; `threadText(from:budget:)` has already done the work for the other
        // entry point and clamping an already-short string costs a length check.
        let text = SearchText.clamped(
            threadText.trimmingCharacters(in: .whitespacesAndNewlines),
            toBytes: budget.totalBytes
        )
        guard !text.isEmpty else { return [] }

        inFlightCount += 1
        defer { inFlightCount -= 1 }

        // Written as a plain `if let` over a non-optional local rather than as a comparison
        // against an optional: the pattern match below then has exactly one meaning.
        let availability: EmbeddingAvailability
        if let cached = cachedAvailability {
            availability = cached
        } else {
            availability = await embedder.availability()
            cachedAvailability = availability
        }
        guard case .available = availability else { return [] }

        guard let threadVector = await embedder.vector(for: text) else { return [] }
        guard !Task.isCancelled else { return [] }

        var scored: [(id: SavedReply.ID, vector: SearchVector)] = []
        var liveKeys: Set<String> = []
        for reply in candidates {
            let key = SavedReplySuggester.bodyKey(for: reply.trimmedBody)
            liveKeys.insert(key)
            if let cached = replyVectors[key] {
                scored.append((id: reply.id, vector: cached))
                continue
            }
            // A body the model has nothing to say about is skipped rather than stored as a zero
            // vector: a zero would be comparable to everything and rank as related to nothing.
            guard let vector = await embedder.vector(for: reply.trimmedBody) else { continue }
            guard !Task.isCancelled else { return [] }
            replyVectors[key] = vector
            scored.append((id: reply.id, vector: vector))
        }
        // An edited body has a new key, so the vector under its old one is unreachable. Dropping
        // it here is what keeps the cache the size of the reply list rather than the size of the
        // reviewer's edit history — and it is done only when this call is the last one running,
        // so it cannot discard what an overlapping call just paid for.
        if inFlightCount == 1 {
            replyVectors = replyVectors.filter { liveKeys.contains($0.key) }
        }

        return SavedReplySuggester.rank(threadVector: threadVector, replies: scored)
    }
}
