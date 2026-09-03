import Foundation

/// One stored row of `triage_verdicts`: a verdict, and what it was made from (plan §3.A).
///
/// The shape is ``SearchIndexEntry``'s deliberately, because the two rows answer the same two
/// questions about the same pull request — "does this still describe the current text" and "did
/// the same model make it" — and a second answer to either of those would be a second thing that
/// could disagree. What is stored is the verdict plus its provenance; what is *not* stored is
/// anything a rules engine could read as permission (ADR 0023).
public struct TriageVerdictEntry: Sendable, Hashable, Identifiable {
    /// The pull request's GraphQL node id.
    public var prID: String
    /// ``SearchDocument/documentHash`` of the text the verdict was made from — the re-classify
    /// gate, and the same invalidation rule the vector beside it uses.
    public var documentHash: String
    /// What the model said.
    public var verdict: TriageVerdict
    /// Which model said it.
    ///
    /// Stored beside the verdict rather than assumed, for ``SearchIndexEntry/modelIdentifier``'s
    /// reason: Apple ships model updates with the OS, and a verdict from a model that no longer
    /// exists has to be re-made rather than silently presented as the current one's opinion.
    public var modelIdentifier: String
    /// When the row was written.
    public var classifiedAt: Date

    /// `TriageVerdictEntry` shares the pull request's identity.
    public var id: String { prID }

    /// Creates an entry.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - documentHash: The hash of the text the verdict was made from.
    ///   - verdict: The verdict.
    ///   - modelIdentifier: What produced it.
    ///   - classifiedAt: When the row was written.
    public init(
        prID: String,
        documentHash: String,
        verdict: TriageVerdict,
        modelIdentifier: String,
        classifiedAt: Date
    ) {
        self.prID = prID
        self.documentHash = documentHash
        self.verdict = verdict
        self.modelIdentifier = modelIdentifier
        self.classifiedAt = classifiedAt
    }

    /// Whether this row can be shown for a freshly composed input instead of classifying again.
    ///
    /// Both halves have to match: the same text *and* the same model. Either one differing means
    /// the stored verdict is about something else, which is the whole of the invalidation rule.
    /// - Parameters:
    ///   - input: The freshly composed input.
    ///   - modelIdentifier: The model that would classify it now.
    public func isUsable(for input: TriageInput, modelIdentifier: String) -> Bool {
        documentHash == input.documentHash && self.modelIdentifier == modelIdentifier
    }
}
