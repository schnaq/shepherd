import Foundation
import NaturalLanguage
import ShepherdCore

/// Why the on-device embedding model cannot be used, or that it can.
///
/// A value rather than a `Bool` for the reason ``UpdateProblem`` is one: "search is only matching
/// words on this Mac" is a sentence Settings has to be able to finish, and a missing feature with
/// no explanation reads as a bug.
enum EmbeddingAvailability: Sendable, Equatable {
    /// The model answered.
    case available
    /// It did not, with a reason to show the user.
    case unavailable(String)

    /// The reason, when there is one.
    var reason: String? {
        switch self {
        case .available: return nil
        case .unavailable(let reason): return reason
        }
    }
}

/// How a search document or a query becomes a vector (ADR 0019).
///
/// The seam the whole feature is tested through — the ``WebhookPosting`` / ``AutoMergeWriting``
/// pattern once more. In the app it is ``NaturalLanguageEmbedder``, which is the only type in
/// Shepherd that imports `NaturalLanguage`; in `ShepherdTests` it is a closure that returns
/// vectors a test wrote by hand, so the coordinator's "when is an embedding spent" rules are
/// asserted without Apple's model being present or its output being stable.
///
/// **There is deliberately no cloud implementation of this protocol, and there may not be one.**
/// Search runs on every keystroke and over every pull request in the inbox; sending that to a
/// configured BYOK endpoint would send the whole inbox — titles, descriptions, diffs — to a third
/// party as a side effect of typing, which is the opposite of "AI runs only when you ask"
/// (ADR 0007, and the host list in `CONTRIBUTING.md`). That is a fixed rule of the design, not a
/// setting: no type in this folder takes an `IntelligenceRouter`, a base URL or a key.
protocol EmbeddingProviding: Sendable {
    /// Identifies the model, so vectors from two different ones are never compared.
    ///
    /// Stored beside every vector (``ShepherdCore/SearchIndexEntry/modelIdentifier``). Changing
    /// this string is how a model change invalidates the index.
    var modelIdentifier: String { get }

    /// Whether the model can answer, and why not when it cannot.
    func availability() async -> EmbeddingAvailability

    /// Embeds one text.
    /// - Parameter text: The document or the query.
    /// - Returns: A unit-length vector, or `nil` when the model is unavailable or could not
    ///   answer for this text. `nil` is a normal outcome, never an error to report: the ranker
    ///   falls back to its lexical half.
    func vector(for text: String) async -> SearchVector?
}

/// Apple's on-device sentence embedding, and the only importer of `NaturalLanguage` (ADR 0019).
///
/// An `actor`, and that is forced rather than stylistic: `NLEmbedding` is a reference type Apple
/// does not declare `Sendable`, so it may be reached from exactly one isolation domain. Keeping it
/// behind an actor also keeps the per-keystroke query embedding off the main actor, which is where
/// the palette's text field lives.
///
/// **Why the sentence embedding and not `NLContextualEmbedding`.** The contextual embeddings
/// (macOS 14+) are stronger on long text, but they are shipped as *assets*: the app has to check
/// `hasAvailableAssets`, request a download, and wait for it before `load()` succeeds — a
/// multi-megabyte download triggered by a search box, which is not a thing Shepherd may do
/// quietly. `NLEmbedding.sentenceEmbedding(for: .english)` is part of the OS, is `nil` when it is
/// not, and answers synchronously in well under a millisecond, which is what a ranking on every
/// keystroke needs. The trade is documented in ADR 0019 with the upgrade left as a follow-up.
actor NaturalLanguageEmbedder: EmbeddingProviding {
    nonisolated let modelIdentifier = "apple.nl.sentence.en.1"

    private var embedding: NLEmbedding?
    private var hasAttemptedLoad = false

    /// Creates an embedder. Nothing is loaded here.
    ///
    /// The model is fetched on first use rather than at launch, so a Mac with the toggle switched
    /// off never pays for it — the same shape as ``DiagnosticsReporter``, which subscribes to
    /// nothing until it is asked to (ADR 0017).
    init() {}

    func availability() async -> EmbeddingAvailability {
        guard loadedEmbedding() != nil else {
            return .unavailable(
                String(
                    localized: "This Mac has no on-device sentence-embedding model, so search matches words rather than meaning."
                )
            )
        }
        return .available
    }

    func vector(for text: String) async -> SearchVector? {
        guard let embedding = loadedEmbedding() else { return nil }
        let chunks = EmbeddingChunker.chunks(in: text)
        var vectors: [SearchVector] = []
        for chunk in chunks {
            // A chunk the model has nothing to say about is skipped rather than treated as a
            // zero vector: a zero would drag the pooled mean towards the origin and make the
            // document look unrelated to everything.
            guard let values = embedding.vector(for: chunk) else { continue }
            vectors.append(SearchVector(values.map { Float($0) }).normalized)
        }
        return SearchVector.meanPooled(vectors)
    }

    private func loadedEmbedding() -> NLEmbedding? {
        if !hasAttemptedLoad {
            hasAttemptedLoad = true
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
        }
        return embedding
    }
}

/// Cuts a search document into pieces the sentence embedding can be asked about (ADR 0019).
///
/// A type of its own rather than a method on the actor, for two reasons: it is pure text logic
/// with no model in it — so the app-target tests drive it directly, with no isolation and no
/// `NLEmbedding` — and the two ceilings below are the ones that bound what one enormous pull
/// request may cost, which is a decision worth having a named home.
enum EmbeddingChunker {
    /// How many characters go into one chunk.
    ///
    /// The sentence embedding is trained on sentences, and its quality falls off long before it
    /// starts refusing input. Roughly a paragraph per chunk, mean-pooled afterwards
    /// (``ShepherdCore/SearchVector/meanPooled(_:)``), is the shape that keeps a long pull request
    /// *about* its contents.
    static let chunkCharacters = 600

    /// How many chunks one document may cost.
    ///
    /// The ceiling that stops one enormous pull request spending fifty embeddings while every
    /// other row waits. Together with ``ShepherdCore/SearchDocumentBudget`` the worst case for a
    /// document is bounded twice: by its bytes and by its chunks.
    static let maximumChunks = 8

    /// Splits a document into chunks.
    ///
    /// Cuts at the last whitespace inside the window so a chunk never ends mid-word; a "word"
    /// longer than the window (a minified line, a base64 blob) is cut hard, which is the correct
    /// answer for something that is not prose anyway.
    /// - Parameters:
    ///   - text: The document text.
    ///   - maximumCharacters: The chunk size. Defaults to ``chunkCharacters``.
    ///   - maximumChunks: How many chunks at most. Defaults to ``maximumChunks``.
    /// - Returns: The chunks, in order, without empty ones.
    static func chunks(
        in text: String,
        maximumCharacters: Int = EmbeddingChunker.chunkCharacters,
        maximumChunks: Int = EmbeddingChunker.maximumChunks
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maximumCharacters > 0, maximumChunks > 0 else { return [] }
        var chunks: [String] = []
        var rest = Substring(trimmed)
        while !rest.isEmpty, chunks.count < maximumChunks {
            if rest.count <= maximumCharacters {
                chunks.append(String(rest))
                break
            }
            let hardEnd = rest.index(rest.startIndex, offsetBy: maximumCharacters)
            var end = hardEnd
            // When the window happens to end on a word boundary, the hard cut *is* the clean cut;
            // looking for the last space inside it would throw the final word away. Safe to index:
            // the branch above returned for a `rest` that fits, so `hardEnd` is not the end.
            if !rest[hardEnd].isWhitespace {
                let window = rest[rest.startIndex..<hardEnd]
                // `startIndex` would mean "no progress", so the hard cut wins in that one case —
                // which is what happens to a "word" longer than the window.
                if let lastSpace = window.lastIndex(where: { $0.isWhitespace }),
                   lastSpace != rest.startIndex {
                    end = lastSpace
                }
            }
            let chunk = String(rest[rest.startIndex..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            rest = rest[end...]
            while let first = rest.first, first.isWhitespace {
                rest = rest.dropFirst()
            }
        }
        return chunks
    }
}
