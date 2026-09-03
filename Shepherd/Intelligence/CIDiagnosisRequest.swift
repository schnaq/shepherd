import Foundation
import ShepherdCore

/// Everything a provider is given to answer "why is CI red?" (plan §3.F).
///
/// Deliberately thin, and that is the whole difference between this request and the drafting ones.
/// A summary draft carries its context *in* the request, because the model gets one shot at it; a
/// diagnosis carries only what the model needs to decide **what to read**, and the reading is done
/// by tools it calls (``LocalToolExecutor``). So this value is an orientation: which pull request,
/// which checks are red, which files exist, and how much room the answering tier has. The check
/// summaries and the diff arrive later, budgeted by the tool that produced them.
///
/// The changed-file paths are here for two jobs at once: they are the list the model may pick a
/// path from, and — through ``ShepherdCore/IntelligenceToolRegistry`` — the list a `fileDiff` call
/// is validated against. A model that names a file this pull request does not touch is refused
/// rather than answered, which is the plan's rule that no free text a model wrote reaches GitHub.
struct CIDiagnosisRequest: Sendable, Hashable {
    /// One red check, as the model is told about it.
    ///
    /// The conclusion travels as the model-facing string rather than as
    /// ``ShepherdCore/CheckRun/Conclusion``, because the prompt is where it is read and a raw
    /// value is what a prompt can carry; the summary is capped here so the request cannot grow
    /// with a talkative workflow.
    struct Check: Sendable, Hashable {
        /// The check name, exactly as GitHub reports it — the string `jobLogTail` takes.
        var name: String
        /// What GitHub concluded, e.g. `failure` or `timedOut`.
        var conclusion: String
        /// The check's own summary text, capped to ``maximumCheckSummaryCharacters``.
        var summary: String?

        /// Creates a check.
        /// - Parameters:
        ///   - name: The check name.
        ///   - conclusion: The conclusion's raw value.
        ///   - summary: The check's summary text, already capped.
        init(name: String, conclusion: String, summary: String? = nil) {
            self.name = name
            self.conclusion = conclusion
            self.summary = summary
        }
    }

    /// At most this many red checks are named in the prompt.
    ///
    /// A pull request with thirty red checks has one broken thing in it, and the first handful
    /// names it; the tool can still list them all when the model asks.
    static let maximumChecks = 8
    /// Each check's summary is capped to this many characters in the prompt.
    ///
    /// Short, because the prompt's job is only to say what to look at — the full (still capped)
    /// summary is what `failingChecks` answers with.
    static let maximumCheckSummaryCharacters = 160
    /// The pull request title is carried for orientation only, so it is capped short.
    static let maximumTitleCharacters = 120
    /// At most this many changed-file paths are listed in the prompt.
    ///
    /// The *registry* keeps every path, so a model that names one further down the list is still
    /// allowed to read it. This cap is only about not spending a pull request's whole context on
    /// a file tree.
    static let maximumListedPaths = 60

    /// `owner/name` of the repository.
    var repoFullName: String
    /// The pull request number.
    var number: Int
    /// The pull request title, capped to ``maximumTitleCharacters``.
    var pullRequestTitle: String
    /// The red checks, capped to ``maximumChecks``.
    var failingChecks: [Check]
    /// Every path this pull request changed — the list a `fileDiff` call is validated against.
    ///
    /// Built by ``changedPaths(in:)``, which is the only place it may come from: this list and the
    /// executor's registry have to hold the same paths or the prompt promises a read the executor
    /// refuses.
    var changedFilePaths: [String]
    /// The answering tier's token budget.
    var budget: TokenBudget

    /// Creates a request.
    /// - Parameters:
    ///   - repoFullName: `owner/name`.
    ///   - number: The pull request number.
    ///   - pullRequestTitle: The title, capped.
    ///   - failingChecks: The red checks, capped.
    ///   - changedFilePaths: Every changed path.
    ///   - budget: The tier's budget.
    init(
        repoFullName: String,
        number: Int,
        pullRequestTitle: String,
        failingChecks: [Check],
        changedFilePaths: [String],
        budget: TokenBudget
    ) {
        self.repoFullName = repoFullName
        self.number = number
        self.pullRequestTitle = pullRequestTitle
        self.failingChecks = failingChecks
        self.changedFilePaths = changedFilePaths
        self.budget = budget
    }

    /// `owner/name#number`, the way every other surface writes a pull request.
    var slug: String { "\(repoFullName)#\(number)" }

    /// The registry a provider validates this turn's tool calls against.
    ///
    /// Derived rather than stored so it cannot disagree with ``changedFilePaths``.
    var registry: IntelligenceToolRegistry {
        IntelligenceToolRegistry(changedFilePaths: Set(changedFilePaths))
    }

    /// The paths a `fileDiff` call may name, in the order the prompt lists them.
    ///
    /// **Derived from the registry, not from the file list, and that is the whole point.**
    /// ``LocalToolExecutor`` validates against `IntelligenceToolRegistry(changedFiles:)`, which
    /// keeps a renamed file's *previous* path as well — both are in the diff, so a log naming the
    /// old one is not the model inventing anything. Mapping `files` to `path` here left the two
    /// disagreeing: the model was told about one list and refused against another, and the
    /// refusal it read ("not one of the files this pull request changed") named a path the diff
    /// does contain. One derivation, one answer.
    ///
    /// The order is `files`' own, with a rename's previous path directly behind its new one,
    /// because the registry is a `Set` and a prompt whose file list is shuffled between runs is a
    /// prompt nobody can compare two answers from.
    /// - Parameter detail: The fetched pull request.
    /// - Returns: Every readable path, each once, in a stable order.
    static func changedPaths(in detail: PullRequestDetail) -> [String] {
        let readable = IntelligenceToolRegistry(changedFiles: detail.files).changedFilePaths
        var ordered: [String] = []
        var seen = Set<String>()
        for file in detail.files {
            for path in [file.path, file.previousPath].compactMap({ $0 }) {
                guard readable.contains(path), seen.insert(path).inserted else { continue }
                ordered.append(path)
            }
        }
        return ordered
    }

    /// The approximate token count of the prompt this request renders to.
    ///
    /// Counted the way the digests count themselves, so the on-device pre-flight compares like
    /// with like. It is an under-estimate of the *turn* — the tool results are not in it, because
    /// they do not exist yet — and it is the honest number for the one thing the pre-flight can
    /// decide: whether the opening prompt fits at all.
    var approximateTokenCount: Int {
        budget.approximateTokens(characterCount: IntelligencePrompt.body(for: self).count)
    }

    /// Builds the request from the fetched pull request.
    ///
    /// Takes the summary separately from the detail because the two can disagree: the inbox row
    /// is refreshed by the sync loop while a detail sits open, so the title and the number the
    /// reviewer is looking at are the row's. Everything the model reads — checks, files — comes
    /// from the detail, which is the snapshot the tools answer from.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - summary: The inbox row the reviewer opened.
    ///   - budget: The answering tier's token budget.
    /// - Returns: The request.
    static func build(
        detail: PullRequestDetail,
        summary: PullRequestSummary,
        budget: TokenBudget
    ) -> CIDiagnosisRequest {
        let checks = LocalToolExecutor.failingChecks(in: detail)
            .prefix(maximumChecks)
            .map { run in
                Check(
                    name: run.name,
                    conclusion: run.conclusion?.rawValue ?? "no conclusion",
                    summary: capped(run.summary)
                )
            }
        return CIDiagnosisRequest(
            repoFullName: summary.repo.fullName,
            number: summary.number,
            pullRequestTitle: String(summary.title.prefix(maximumTitleCharacters)),
            failingChecks: checks,
            changedFilePaths: changedPaths(in: detail),
            budget: budget
        )
    }

    /// One check summary, trimmed, capped and flattened onto a single line.
    ///
    /// Flattened because a check's summary is somebody else's Markdown: a rendered report with
    /// blank lines in it would otherwise reshape the prompt around it.
    /// - Parameter summary: The check's summary text, if it published one.
    /// - Returns: The capped summary, or `nil` when there is nothing to say.
    private static func capped(_ summary: String?) -> String? {
        guard let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        let flattened = trimmed
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return flattened.count > maximumCheckSummaryCharacters
            ? String(flattened.prefix(maximumCheckSummaryCharacters)) + "…"
            : flattened
    }
}
