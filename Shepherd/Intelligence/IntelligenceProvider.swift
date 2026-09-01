import Foundation
import ShepherdCore

/// Which tier produced a piece of intelligence (ADR 0007).
enum IntelligenceKind: String, Sendable, Hashable, Codable {
    /// Apple's on-device Foundation Model.
    case onDevice
    /// The Anthropic API, with the user's own key.
    case anthropic
    /// A user-configured OpenAI-compatible endpoint.
    case openAICompatible

    /// The badge shown on hint cards, so the user always knows where a hint came from.
    var badge: String {
        switch self {
        case .onDevice: return String(localized: "on-device")
        case .anthropic: return String(localized: "Anthropic")
        case .openAICompatible: return String(localized: "custom endpoint")
        }
    }
}

/// A short, human-readable summary of a pull request.
struct PRSummary: Sendable, Hashable, Codable {
    /// Two or three sentences describing what the pull request does.
    var overview: String
    /// Short risk notes, each a single sentence.
    var riskNotes: [String]

    /// Creates a summary.
    init(overview: String, riskNotes: [String] = []) {
        self.overview = overview
        self.riskNotes = riskNotes
    }
}

/// A suggestion about where to look first.
///
/// Hints are always *additional* to the deterministic ``ShepherdCore/FilePrioritizer`` output
/// and are never auto-applied (ADR 0007).
struct FocusHint: Sendable, Hashable, Codable, Identifiable {
    /// The file the hint is about.
    var file: String
    /// Why it deserves attention.
    var reason: String

    /// `FocusHint` is identified by the pair it carries.
    var id: String { "\(file)|\(reason)" }

    /// Creates a hint.
    init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

/// The abstraction over intelligence tiers 2 and 3 (`docs/ARCHITECTURE.md`).
protocol IntelligenceProvider: Sendable {
    /// Which tier this is.
    var kind: IntelligenceKind { get }
    /// Whether the provider can serve a request right now.
    var isAvailable: Bool { get async }
    /// Summarises a pull request from a pre-digested view of it.
    func summarizePullRequest(_ digest: PullRequestDigest) async throws -> PRSummary
    /// Suggests where a reviewer should look first.
    func suggestReviewFocus(_ digest: PullRequestDigest) async throws -> [FocusHint]
}

/// Failures the intelligence layer can produce.
///
/// Every one of them degrades to "no hint card" in the UI — the app is fully usable with
/// intelligence off.
enum IntelligenceError: Error, LocalizedError, Equatable {
    /// The selected provider is not available on this machine or not configured.
    case unavailable(String)
    /// The endpoint is missing a base URL, model or key.
    case notConfigured(String)
    /// The endpoint answered with an error.
    case http(status: Int, message: String)
    /// The answer could not be understood.
    case malformedResponse
    /// The endpoint's model list was well-formed but empty.
    case noModelsListed
    /// The digest did not fit the provider's context window.
    case digestTooLarge(tokens: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return String(localized: "Intelligence unavailable: \(reason)")
        case .notConfigured(let field):
            return String(localized: "Missing configuration: \(field)")
        case .http(let status, let message):
            return String(localized: "The model endpoint returned \(status): \(message)")
        case .malformedResponse:
            return String(localized: "The model returned something Shepherd could not read.")
        case .noModelsListed:
            return String(localized: "The endpoint did not list any models. Type the model name instead.")
        case .digestTooLarge(let tokens, let limit):
            return String(localized: "This pull request needs ~\(tokens) tokens, over the \(limit) token budget.")
        }
    }
}

// MARK: - The shared prompt contract

/// Builds the prompts every provider sends, so the three tiers stay comparable.
enum IntelligencePrompt {
    /// The system/instructions text for summarisation.
    static let summaryInstructions = """
        You review pull requests for a senior engineer. Summarise the change factually in \
        two or three sentences, then list at most three short risk notes. Never invent files, \
        APIs or behaviour that the input does not mention. If the input is too thin to judge, \
        say so plainly.
        """

    /// The system/instructions text for focus hints.
    static let focusInstructions = """
        You triage pull requests for a senior engineer. Name at most four files from the input \
        that deserve the closest reading and give a one-line reason for each. Only use file \
        paths that appear verbatim in the input.
        """

    /// The JSON shape the cloud providers are asked for (summaries).
    static let summaryJSONContract = """
        Answer with JSON only, no prose and no code fence: \
        {"overview": string, "riskNotes": [string]}
        """

    /// The JSON shape the cloud providers are asked for (focus hints).
    static let focusJSONContract = """
        Answer with JSON only, no prose and no code fence: \
        {"hints": [{"file": string, "reason": string}]}
        """

    /// Renders a digest as the plain-text body of a prompt.
    /// - Parameter digest: The tier-1 digest.
    static func body(for digest: PullRequestDigest) -> String {
        var text = """
            Repository: \(digest.repoFullName)
            Pull request: #\(digest.number) — \(digest.title)
            Author: \(digest.authorLogin) (\(digest.authorProvenance))
            Base branch: \(digest.baseRefName)
            Size: \(digest.changedFileCount) files, +\(digest.totalAdditions) −\(digest.totalDeletions)
            """
        if !digest.bodyExcerpt.isEmpty {
            text += "\n\nDescription:\n\(digest.bodyExcerpt)"
        }
        if !digest.files.isEmpty {
            text += "\n\nFiles (highest review priority first):"
            for file in digest.files {
                let reasons = file.reasons.isEmpty ? "" : " — \(file.reasons.joined(separator: ", "))"
                text += "\n- \(file.path) [\(file.status.rawValue), \(file.bucket.rawValue)]"
                    + " +\(file.additions) −\(file.deletions)\(reasons)"
            }
        }
        if !digest.topHunks.isEmpty {
            text += "\n\nDiff excerpts:"
            for hunk in digest.topHunks {
                text += "\n\n--- \(hunk.path)\(hunk.truncated ? " (truncated)" : "")\n\(hunk.text)"
            }
        }
        if digest.wasTruncated {
            text += "\n\n(Note: this digest was truncated to fit the token budget.)"
        }
        return text
    }
}

// MARK: - Lenient JSON parsing

/// Parses the JSON the cloud providers are asked for, tolerating the ways models get it wrong.
enum IntelligenceJSON {
    private struct SummaryPayload: Decodable {
        var overview: String?
        var riskNotes: [String]?
    }

    private struct HintsPayload: Decodable {
        struct Hint: Decodable {
            var file: String?
            var reason: String?
        }
        var hints: [Hint]?
    }

    /// Extracts the outermost `{…}` from a model answer that may be wrapped in prose or a fence.
    /// - Parameter text: The raw answer.
    /// - Returns: The JSON substring, or `nil` when there is no brace pair.
    static func extractObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end
        else { return nil }
        return String(text[start...end])
    }

    /// Parses a summary answer, falling back to treating the whole text as the overview.
    /// - Parameter text: The raw answer.
    static func summary(from text: String) -> PRSummary {
        if let object = extractObject(from: text),
           let payload = try? JSONDecoder().decode(SummaryPayload.self, from: Data(object.utf8)),
           let overview = payload.overview, !overview.isEmpty {
            return PRSummary(
                overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
                riskNotes: (payload.riskNotes ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        return PRSummary(overview: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Parses a focus-hint answer.
    /// - Parameter text: The raw answer.
    /// - Returns: The hints, or an empty array when nothing usable came back.
    static func hints(from text: String) -> [FocusHint] {
        guard let object = extractObject(from: text),
              let payload = try? JSONDecoder().decode(HintsPayload.self, from: Data(object.utf8))
        else { return [] }
        return (payload.hints ?? []).compactMap { hint in
            guard let file = hint.file?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !file.isEmpty,
                  let reason = hint.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reason.isEmpty
            else { return nil }
            return FocusHint(file: file, reason: reason)
        }
    }
}
