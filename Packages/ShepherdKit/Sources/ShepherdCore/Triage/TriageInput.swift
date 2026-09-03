import Foundation

/// Everything the structured-triage classifier is shown about one pull request (plan §3.A).
///
/// Pure, and in a target that builds on Linux, for the reason every generated shape's contract is
/// (ADR 0007): what goes into the prompt is a *decision* about privacy and about cost, so it is
/// composed by a tested function rather than assembled at a call site next to a model.
///
/// It carries no diff of its own. The text is the ADR 0019 search document — already composed,
/// already byte-budgeted, already built once per pull request for the search index — plus the
/// tier-1 risk hints that ``FilePrioritizer`` works out without any model. Two consequences worth
/// naming:
///
/// - **Nothing is read from GitHub to classify a pull request.** The document is made of rows the
///   sweep and the review screen already stored, so a classification pass is CPU and SQLite and
///   nothing else.
/// - **The budget is inherited rather than re-invented.** A document is ~6 KB of text, so an
///   input is roughly 1,500 tokens, and the pre-flight that measures it against the on-device
///   context window is the provider's (ADR 0007 makes that ceiling a hard error).
public struct TriageInput: Sendable, Hashable {
    /// The pull request's GraphQL node id.
    public var prID: String
    /// ``SearchDocument/documentHash`` of the text below — the re-classify gate.
    ///
    /// The same hash the search index stores beside a vector, and for the same reason: a verdict
    /// describes one particular text, so a stored verdict is reusable exactly while the text it
    /// was made from is unchanged.
    public var documentHash: String
    /// The pull-request title, verbatim.
    public var title: String
    /// The search document's text — title, identity, author, labels, branch, description,
    /// changed-file paths and added diff lines, each already capped.
    public var documentText: String
    /// The tier-1 risk hints, in priority order: what ``FilePrioritizer`` says about the files
    /// without a model being involved at all.
    public var riskHints: [String]

    /// Creates an input.
    /// - Parameters:
    ///   - prID: The pull request's node id.
    ///   - documentHash: The hash of ``documentText``.
    ///   - title: The title.
    ///   - documentText: The search document's text.
    ///   - riskHints: The tier-1 hints.
    public init(
        prID: String,
        documentHash: String,
        title: String,
        documentText: String,
        riskHints: [String]
    ) {
        self.prID = prID
        self.documentHash = documentHash
        self.title = title
        self.documentText = documentText
        self.riskHints = riskHints
    }

    /// Composes the input for one pull request.
    /// - Parameters:
    ///   - document: The search document the index already built.
    ///   - riskHints: The tier-1 hints, from ``TriageRiskHints/hints(for:limit:)``.
    /// - Returns: The input.
    public static func make(document: SearchDocument, riskHints: [String]) -> TriageInput {
        TriageInput(
            prID: document.prID,
            documentHash: document.documentHash,
            title: document.title,
            documentText: document.embeddingText,
            riskHints: riskHints
        )
    }

    /// The prompt body, in a fixed order.
    ///
    /// The order is the order of confidence: the title is what a human would read first, the
    /// tier-1 hints are facts about the diff that a deterministic function established, and the
    /// document is the raw material underneath both. A model that ignores everything after the
    /// first two sections still produces a defensible verdict.
    public var promptText: String {
        var text = "Pull request: \(title)"
        if !riskHints.isEmpty {
            text += "\n\nRisk hints, worked out from the diff without a model:"
            for hint in riskHints {
                text += "\n- \(hint)"
            }
        }
        text += "\n\nWhat the change is:\n\(documentText)"
        return text
    }

    /// The chars-÷-4 estimate of ``promptText``.
    ///
    /// The fallback measurement, used where the platform cannot count tokens against the real
    /// tokenizer — the same arrangement every other request type has
    /// (``TokenBudget/measured(_:using:)``).
    public var approximateTokenCount: Int {
        TokenBudget.onDevice.approximateTokens(of: promptText)
    }
}

/// The tier-1 half of structured triage: what Shepherd can say about a change's risk with no
/// model at all (ADR 0007, tier 1).
///
/// Two outputs from the same deterministic ranking, and they have two different jobs:
///
/// - ``hints(for:limit:)`` produces the sentences that go *into* the prompt, so the classifier
///   starts from established facts ("deletes a test file", "touches a security-sensitive path")
///   rather than having to infer them from a diff excerpt.
/// - ``heuristicRisk(for:)`` produces a risk level for a pull request that has **no** verdict,
///   which is what makes the inbox's risk facet degrade to tier 1 instead of vanishing when the
///   on-device model is off or unavailable (plan §3.A's guardrail).
///
/// Both are pure functions over ``FilePrioritizer``, which means the tier-1 answer the facet shows
/// and the tier-1 answer the review screen already shows come from one place and cannot disagree.
public enum TriageRiskHints {
    /// How many hint lines an input carries at most.
    ///
    /// Six, because the hints are the *summary* of the tier-1 analysis and not a copy of it: a
    /// pull request touching eighty files has eighty reason lists, and the prompt's job is to
    /// name the handful that would make a reviewer sit up. The order is the prioritiser's, so the
    /// six that survive are the six highest-ranked files.
    public static let maximumHints = 6

    /// The tier-1 risk hints for a set of changed files, highest priority first.
    ///
    /// Only the reasons that say something *about the risk* are kept: the prioritiser's first
    /// reason is always the file's category ("Source file"), which is visible from the path and
    /// would spend prompt budget on nothing. A file whose only reason is its category contributes
    /// no line at all.
    /// - Parameters:
    ///   - files: The changed files, as the detail fetch stored them. Empty for a pull request
    ///     nobody has opened, which yields no hints — Shepherd has no diff to judge yet, and
    ///     inventing a hint from a title would be worse than saying nothing.
    ///   - limit: How many lines at most. Defaults to ``maximumHints``.
    /// - Returns: The hints, in priority order.
    public static func hints(for files: [ChangedFile], limit: Int = TriageRiskHints.maximumHints) -> [String] {
        guard !files.isEmpty, limit > 0 else { return [] }
        let priorities = FilePrioritizer.prioritize(files)
        var result: [String] = []
        // The aggregate hint goes first, and it is the one hint that is about the *set* rather
        // than about a file: "every changed file is generated" is what separates a dependency
        // bump from a change to the code, and no per-file reason can say it.
        if priorities.allSatisfy({ $0.category == .generated }) {
            result.append("Every changed file is generated or vendored (a lockfile, a snapshot or a bundle).")
        }
        for priority in priorities {
            guard result.count < limit else { break }
            let notes = priority.reasons.filter { $0 != priority.category.reasonLabel }
            guard !notes.isEmpty else { continue }
            result.append("\(priority.file.path) — \(notes.joined(separator: ", "))")
        }
        return result
    }

    /// The risk level Shepherd assigns without a model.
    ///
    /// Read straight off ``FilePrioritizer``'s buckets rather than re-derived, so the tier-1
    /// answer cannot drift from the review screen's file ordering:
    ///
    /// | Tier-1 signal | Risk |
    /// | --- | --- |
    /// | any file in ``PriorityBucket/reviewFirst`` — auth, CI workflow, entitlements, a deleted test, a dominating change | high |
    /// | any file in ``PriorityBucket/standard`` — ordinary source, tests, configuration | medium |
    /// | only skimmable or generated files — docs, lockfiles, vendored trees | low |
    ///
    /// - Parameter files: The changed files, as the detail fetch stored them.
    /// - Returns: The risk, or `nil` when there is no diff to judge — which is the honest answer
    ///   for a pull request nobody has opened, and the reason the facet counts fewer rows than
    ///   the inbox holds.
    public static func heuristicRisk(for files: [ChangedFile]) -> TriageVerdict.Risk? {
        guard !files.isEmpty else { return nil }
        let priorities = FilePrioritizer.prioritize(files)
        if priorities.contains(where: { $0.bucket == .reviewFirst }) { return .high }
        if priorities.contains(where: { $0.bucket == .standard }) { return .medium }
        return .low
    }
}
