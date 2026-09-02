import Foundation

/// An embedding of one search document or one query (ADR 0019).
///
/// The *only* embedding-shaped thing in `Packages/ShepherdKit`, and deliberately so: the vector
/// is a value — a list of `Float`s, a cosine, and its byte representation — while everything that
/// *produces* one is Apple-only (`NaturalLanguage`) and therefore lives in the app target behind
/// `EmbeddingProviding`. That split is what lets the ranker, the byte encoding and the similarity
/// arithmetic be tested by `swift test` on the Linux runner, where no embedding model exists.
///
/// `Float` rather than `Double`: at 512 dimensions a stored vector is 2 KB instead of 4 KB, and
/// the difference is invisible in a cosine that is only ever compared against other cosines. A
/// four-hundred-row inbox is therefore under a megabyte of BLOB.
public struct SearchVector: Sendable, Hashable {
    /// The components.
    public let values: [Float]

    /// Creates a vector.
    /// - Parameter values: The components.
    public init(_ values: [Float]) {
        self.values = values
    }

    /// How many dimensions the vector has.
    public var dimensions: Int { values.count }

    /// Whether the vector carries anything.
    public var isEmpty: Bool { values.isEmpty }

    // MARK: - Bytes

    /// The vector as a `Float32` BLOB, host byte order.
    ///
    /// Host byte order is deliberate and safe here for one reason: the bytes never leave the Mac
    /// that wrote them. The index is device state — it is not in the encrypted settings document
    /// (ADR 0014), it is not uploaded anywhere, and it is dropped with the rest of the local data
    /// on sign-out — so there is no reader with a different endianness and no format to keep
    /// compatible. An index that somehow *did* arrive from elsewhere would be re-embedded anyway,
    /// because the model identifier and the document hash are stored beside it.
    public var data: Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Reads a vector back from a `Float32` BLOB.
    ///
    /// The copy is alignment-safe on purpose: `Data`'s bytes carry no guarantee of 4-byte
    /// alignment, so binding them to `Float` in place is undefined behaviour that happens to work
    /// most of the time. Copying into an array that Swift allocated cannot be misaligned.
    /// - Parameter data: The stored bytes.
    /// - Returns: The vector, or `nil` when the blob is empty or not a whole number of `Float`s.
    public init?(data: Data) {
        let stride = MemoryLayout<Float>.size
        guard !data.isEmpty, data.count % stride == 0 else { return nil }
        var values = [Float](repeating: 0, count: data.count / stride)
        let copied = values.withUnsafeMutableBufferPointer { buffer in
            data.copyBytes(to: buffer)
        }
        guard copied == data.count else { return nil }
        self.values = values
    }

    // MARK: - Arithmetic

    /// The cosine similarity between two vectors, in `-1...1`.
    ///
    /// `nil` rather than `0` when the two cannot be compared — different dimensions, or a
    /// zero-length vector — because "these are unrelated" and "this question has no answer" have
    /// to be distinguishable: the ranker falls back to its lexical half for the second one
    /// instead of scoring the document as a semantic mismatch.
    /// - Parameter other: The other vector.
    /// - Returns: The similarity, or `nil`.
    public func cosineSimilarity(to other: SearchVector) -> Double? {
        guard !values.isEmpty, values.count == other.values.count else { return nil }
        var dot = 0.0
        var leftNorm = 0.0
        var rightNorm = 0.0
        for index in values.indices {
            let left = Double(values[index])
            let right = Double(other.values[index])
            dot += left * right
            leftNorm += left * left
            rightNorm += right * right
        }
        guard leftNorm > 0, rightNorm > 0 else { return nil }
        return dot / (leftNorm.squareRoot() * rightNorm.squareRoot())
    }

    /// The vector scaled to unit length, or itself when it has none.
    ///
    /// Stored normalised so that a cosine is a dot product and a mean of chunk vectors is not
    /// dominated by whichever chunk happened to have the largest magnitude.
    public var normalized: SearchVector {
        var norm = 0.0
        for value in values { norm += Double(value) * Double(value) }
        guard norm > 0 else { return self }
        let scale = Float(1 / norm.squareRoot())
        return SearchVector(values.map { $0 * scale })
    }

    /// The component-wise mean of several vectors, normalised.
    ///
    /// How a document longer than the embedding model's window becomes one vector (ADR 0019):
    /// mean-pooling rather than max-pooling, because a mean keeps a long document *about* its
    /// contents while a max makes it about its most extreme dimension in each axis — two
    /// unrelated pull requests that each mention one alarming word end up neighbours.
    /// - Parameter vectors: The chunk vectors. Empty ones and mismatched dimensions are dropped.
    /// - Returns: The pooled vector, or `nil` when nothing usable was given.
    public static func meanPooled(_ vectors: [SearchVector]) -> SearchVector? {
        let usable = vectors.filter { !$0.isEmpty }
        guard let first = usable.first else { return nil }
        let dimensions = first.dimensions
        var sums = [Double](repeating: 0, count: dimensions)
        var count = 0
        for vector in usable where vector.dimensions == dimensions {
            for index in 0..<dimensions {
                sums[index] += Double(vector.values[index])
            }
            count += 1
        }
        guard count > 0 else { return nil }
        let divisor = Double(count)
        return SearchVector(sums.map { Float($0 / divisor) }).normalized
    }
}

/// One row of the local search index: a document hash, its vector, and what produced it
/// (ADR 0019).
///
/// A `ShepherdCore` value even though only `ShepherdPersistence` stores it, for the same reason
/// ``OutboxItem`` is: the table is a place to put the value, not the definition of it, and the
/// coordinator in the app target compares entries without importing GRDB.
public struct SearchIndexEntry: Sendable, Hashable, Identifiable {
    /// The pull request's GraphQL node id.
    public var prID: String
    /// ``SearchDocument/documentHash`` at the time the vector was made — the re-embed gate.
    ///
    /// The *only* staleness key that is persisted. ``SearchDocument/sourceFingerprint`` — the
    /// cheaper gate, the one that decides whether a diff has to be read out of SQLite at all —
    /// deliberately is not: it guards an in-memory corpus that is rebuilt at launch anyway, so a
    /// stored copy would have no reader and would be one more field that could disagree with
    /// something.
    public var documentHash: String
    /// Which embedding model produced ``vector``.
    ///
    /// Stored beside the vector rather than assumed, because vectors from two models are not
    /// comparable: a macOS update that changes the sentence embedding, or a future switch to a
    /// contextual one, must invalidate the index instead of silently ranking against a mixture.
    public var modelIdentifier: String
    /// The document's embedding, or `nil` when the document was indexed lexically only.
    ///
    /// `nil` is a normal state, not a failure: it is what a Mac without the embedding model has
    /// for every row, and the palette still ranks those documents with the lexical half.
    public var vector: SearchVector?
    /// When this row was written.
    public var indexedAt: Date

    /// `SearchIndexEntry` shares the pull request's identity.
    public var id: String { prID }

    /// Creates an entry.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - documentHash: The document hash the vector belongs to.
    ///   - modelIdentifier: What produced the vector.
    ///   - vector: The embedding, if there is one.
    ///   - indexedAt: When the row was written.
    public init(
        prID: String,
        documentHash: String,
        modelIdentifier: String,
        vector: SearchVector?,
        indexedAt: Date
    ) {
        self.prID = prID
        self.documentHash = documentHash
        self.modelIdentifier = modelIdentifier
        self.vector = vector
        self.indexedAt = indexedAt
    }

    /// Whether this entry's vector can be reused for a freshly composed document.
    ///
    /// Both halves have to match: the same text *and* the same model. Either one differing means
    /// the stored vector describes something else.
    /// - Parameters:
    ///   - document: The freshly composed document.
    ///   - modelIdentifier: The model that would embed it now.
    public func isUsable(for document: SearchDocument, modelIdentifier: String) -> Bool {
        vector != nil
            && self.documentHash == document.documentHash
            && self.modelIdentifier == modelIdentifier
    }
}
