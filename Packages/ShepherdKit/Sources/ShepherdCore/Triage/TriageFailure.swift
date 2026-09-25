import Foundation

/// A classification that failed, remembered so the unattended pass does not repeat it.
///
/// The pass runs on every inbox write, and before this existed a failure simply forgot the
/// pull request's fingerprint so the next pass would "try again". For a guardrail refusal or a
/// document that does not fit the context window, trying again is the same request with the same
/// answer: the model was asked about one pull request every couple of minutes for as long as it
/// stayed in the inbox. The memory is keyed the way a verdict is — the document hash and the
/// model — so new text or a new model is always asked, and it lives in memory only: a relaunch is
/// a fresh chance, which is cheap and keeps the table's meaning ("a verdict") unchanged.
public struct TriageFailure: Sendable, Hashable {
    /// Why the classification failed, as far as retrying is concerned.
    public enum Kind: Sendable, Hashable {
        /// The model answered "not this text" — a refusal, or an input it cannot hold. Asking
        /// again about the same document gets the same answer.
        case content
        /// Something about the moment — the model was busy, unloaded or errored. Worth asking
        /// again, after ``TriageFailure/transientBackoff``.
        case transient
    }

    /// How long a transient failure waits before the same document is asked about again.
    ///
    /// Longer than the two-minute sweep interval on purpose, so a model that stays unavailable
    /// is asked a few times an hour rather than on every sweep.
    public static let transientBackoff: TimeInterval = 5 * 60

    /// ``SearchDocument/documentHash`` of the text that failed.
    public var documentHash: String
    /// The model that failed on it.
    public var modelIdentifier: String
    /// Why it failed.
    public var kind: Kind
    /// When it failed.
    public var failedAt: Date

    /// Creates a failure record.
    /// - Parameters:
    ///   - documentHash: The hash of the text that failed.
    ///   - modelIdentifier: The model that failed on it.
    ///   - kind: Why it failed.
    ///   - failedAt: When it failed.
    public init(documentHash: String, modelIdentifier: String, kind: Kind, failedAt: Date) {
        self.documentHash = documentHash
        self.modelIdentifier = modelIdentifier
        self.kind = kind
        self.failedAt = failedAt
    }

    /// Whether a document may be classified again despite this failure.
    /// - Parameters:
    ///   - documentHash: The hash of the text that would be classified now.
    ///   - modelIdentifier: The model that would classify it now.
    ///   - now: The current time.
    /// - Returns: `true` for a different document or model, or a transient failure whose backoff
    ///   has run out.
    public func allowsRetry(documentHash: String, modelIdentifier: String, now: Date) -> Bool {
        guard documentHash == self.documentHash, modelIdentifier == self.modelIdentifier else {
            return true
        }
        switch kind {
        case .content: return false
        case .transient: return now >= failedAt.addingTimeInterval(Self.transientBackoff)
        }
    }
}
