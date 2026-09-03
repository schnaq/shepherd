import Foundation
import ShepherdCore

/// Everything a provider is given to draft the **task for a coding agent** (plan §3.E, the ADR
/// 0011 amendment).
///
/// Two halves, budgeted together. The first is what Shepherd already knows about *this*
/// delegation — which pull request, which branch and commit the worktree is at, whether a review
/// finding started it, and the review comments that finding is made of. The second is the tier-1
/// ``ShepherdCore/PullRequestDigest``, which is what tells a model what the change actually is.
/// Nothing else: a brief drafted from more than the reviewer can see in the sheet is a brief they
/// cannot check before pressing Run.
///
/// The finding comments get their share of the budget reserved *before* the digest is built, the
/// same way ``ReviewSummaryDraftRequest`` reserves it for the reviewer's notes and for the same
/// reason — adding them on top of a digest that had already filled the window would make the
/// brief fail precisely on the pull requests with the most review on them, and tier 2's ceiling
/// is a hard error rather than a truncation (ADR 0007).
///
/// A flat value rather than the ``DelegationContext`` itself, exactly like
/// ``InlineCommentAnchor``: the drafting code has no business knowing about sheets, and this is
/// the whole of what it needs.
///
/// The result is a **suggestion**. It streams into the sheet's task field, the reviewer edits it,
/// and Run is still their click — there is no code path from a drafted brief to a started agent.
struct AgentBriefRequest: Sendable, Hashable {
    /// One comment of the review finding the delegation started from.
    struct Finding: Sendable, Hashable {
        /// Who wrote it, when the caller knows.
        ///
        /// `nil` means the reviewer's own — see ``AgentBriefRequest/onDeviceOnly``.
        var author: String?
        /// The comment body, capped to ``AgentBriefRequest/maximumFindingCharacters``.
        var body: String
    }

    /// At most this many finding comments are quoted, oldest first.
    ///
    /// A thread with twenty comments has an argument in it, not a task; the first few are what
    /// the agent has to act on.
    static let maximumFindings = 6
    /// Each quoted comment is capped to this many characters.
    static let maximumFindingCharacters = 400
    /// Fraction of the tier's character budget the quoted comments may occupy in total.
    ///
    /// A little more than ``ReviewSummaryDraftRequest/notesShare``: for a summary the comments are
    /// context for prose about the diff, while here they frequently *are* the task.
    static let findingsShare = 0.12
    /// The quoted comments may always use at least this many characters, however small the budget
    /// is — one short finding is the whole brief on a one-line review.
    static let minimumFindingsCharacters = 500
    /// At most this many priority reasons are listed.
    ///
    /// The same six the sheet's prefilled task lists, so the brief is drafted from what the
    /// reviewer can already read in the field it replaces.
    static let maximumFocusReasons = 6
    /// Each listed reason is capped to this many characters.
    static let maximumFocusReasonCharacters = 120
    /// What the delegation's own facts are allowed to cost, in characters.
    ///
    /// Reserved alongside the comments' share rather than hoped for: the slug, the title, the
    /// branch, the commit, the finding's anchor and up to
    /// ``maximumFocusReasons`` × ``maximumFocusReasonCharacters`` of ranking reasons are the one
    /// part of this prompt that is *not* built against a budget, and a digest that had already
    /// filled the window would push them over the tier's ceiling — which is a hard error, not a
    /// truncation (ADR 0007).
    static let headerCharacters = 1_000

    /// `owner/name#123`.
    var slug: String
    /// The pull request title.
    var pullRequestTitle: String
    /// The head branch the worktree is built from.
    var headRefName: String
    /// The head commit the worktree is checked out at, already shortened.
    var headRefOid: String
    /// The file a review finding is anchored to, when one started the delegation.
    var findingPath: String?
    /// The line the finding is anchored to, when it had one.
    var findingLine: Int?
    /// Review-priority reasons for the riskiest files, `"path — reason"`, riskiest first.
    var focusReasons: [String]
    /// The finding's comments, capped by ``findings(in:budget:)``.
    var findings: [Finding]
    /// The digest the brief is written from, already inside the tier's budget.
    var digest: PullRequestDigest
    /// Whether this brief may only be answered by the on-device tier.
    ///
    /// True as soon as one quoted comment was written by somebody who is not the signed-in user.
    /// A colleague's sentence has an author who never chose the reviewer's BYOK endpoint, and
    /// there is no version of "your colleague's comment reached the endpoint you configured" that
    /// is an informed choice by the person who wrote it (ADR 0020's reasoning, ADR 0007's host
    /// list). The router refuses the cloud rung for such a request rather than trusting a prompt
    /// to keep it out.
    var onDeviceOnly: Bool

    /// How many characters the quoted comments occupy, authors included.
    var findingsCharacterCount: Int {
        findings.reduce(0) { $0 + $1.body.count + ($1.author?.count ?? 0) + 8 }
    }

    /// The approximate token count of the whole request.
    ///
    /// The digest's own figure plus everything this type adds, counted the way the digest counts
    /// itself (``ShepherdCore/TokenBudget/approximateTokens(characterCount:)``) so the on-device
    /// pre-flight compares like with like.
    var approximateTokenCount: Int {
        let header = slug.count + pullRequestTitle.count + headRefName.count + headRefOid.count
            + (findingPath?.count ?? 0) + 96
        let reasons = focusReasons.reduce(0) { $0 + $1.count + 4 }
        return digest.approximateTokenCount
            + digest.budget.approximateTokens(
                characterCount: header + reasons + findingsCharacterCount
            )
    }

    // MARK: - Budgeting

    /// How many characters the quoted comments may occupy inside a budget.
    /// - Parameter budget: The tier's token budget.
    static func findingsCharacterLimit(in budget: TokenBudget) -> Int {
        max(minimumFindingsCharacters, Int(Double(budget.maxCharacters) * findingsShare))
    }

    /// Everything except the digest, in characters: the comments' share plus the header's.
    /// - Parameter budget: The tier's token budget.
    static func reservedCharacters(in budget: TokenBudget) -> Int {
        findingsCharacterLimit(in: budget) + headerCharacters
    }

    /// The budget the digest is built against when a brief's own material travels with it.
    ///
    /// The tier's budget minus everything else the prompt carries, so all of it together stays
    /// inside the tier's window.
    /// - Parameter budget: The tier's token budget.
    static func digestBudget(in budget: TokenBudget) -> TokenBudget {
        let reserved = budget.approximateTokens(characterCount: reservedCharacters(in: budget))
        return TokenBudget(
            maxTokens: max(1, budget.maxTokens - reserved),
            charactersPerToken: budget.charactersPerToken
        )
    }

    /// Builds the digest a brief is drafted from.
    ///
    /// Named here rather than spelled out at the call site, because the reservation above is the
    /// whole point: a caller that built a plain digest would hand the tier a prompt that fits and
    /// then add the review comments to it.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - budget: The tier's *full* token budget.
    /// - Returns: A digest built inside ``digestBudget(in:)``.
    static func digest(for detail: PullRequestDetail, budget: TokenBudget) -> PullRequestDigest {
        PullRequestDigestBuilder.build(from: detail, budget: digestBudget(in: budget))
    }

    /// Every finding comment of a context, uncapped, paired with its author.
    ///
    /// The pairing is positional (``DelegationContext/findingCommentAuthors``) and tolerates a
    /// shorter or empty author list: a caller that only has bodies produces comments with no
    /// author, which count as the reviewer's own.
    /// - Parameter context: What the delegation is about.
    /// - Returns: The comments, oldest first.
    static func comments(in context: DelegationContext) -> [Finding] {
        context.findingComments.enumerated().map { pair in
            let author = pair.offset < context.findingCommentAuthors.count
                ? context.findingCommentAuthors[pair.offset]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            return Finding(author: author.isEmpty ? nil : author, body: pair.element)
        }
    }

    /// Caps the finding comments to what the tier can afford.
    ///
    /// Deterministic, and by the same three independent limits
    /// ``ReviewSummaryDraftRequest/notes(from:budget:)`` uses — a count cap, a per-comment
    /// character cap, and a share of the same character budget the digest was built against — so
    /// the on-device tier gets fewer and shorter comments than a cloud tier from the same finding,
    /// and the arithmetic is a unit test rather than a context-window error.
    /// - Parameters:
    ///   - context: What the delegation is about.
    ///   - budget: The tier's *full* token budget — the one ``digestBudget(in:)`` was given.
    /// - Returns: The comments to quote, in the order they were written.
    static func findings(in context: DelegationContext, budget: TokenBudget) -> [Finding] {
        let totalLimit = findingsCharacterLimit(in: budget)
        var used = 0
        var result: [Finding] = []
        for comment in comments(in: context).prefix(maximumFindings) {
            let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let capped = body.count > maximumFindingCharacters
                ? String(body.prefix(maximumFindingCharacters)) + "…"
                : body
            // The author travels with the body, so it comes out of the same budget; the constant
            // covers the separators the prompt puts between them.
            let cost = capped.count + (comment.author?.count ?? 0) + 8
            if used + cost > totalLimit, !result.isEmpty { break }
            used += cost
            result.append(Finding(author: comment.author, body: capped))
        }
        return result
    }

    /// Whether a brief drafted from a context may only be answered on-device.
    ///
    /// Read from the **uncapped** comments on purpose: whether a colleague wrote one of them is a
    /// fact about the finding, and a privacy rule that flipped because the character cap happened
    /// to drop the colleague's sentence would be no rule at all.
    /// - Parameters:
    ///   - context: What the delegation is about.
    ///   - viewerLogin: The signed-in user's login, when there is one.
    /// - Returns: `true` when a cloud tier must not see this request.
    static func requiresOnDevice(context: DelegationContext, viewerLogin: String?) -> Bool {
        requiresOnDevice(comments(in: context), viewerLogin: viewerLogin)
    }

    /// Whether a set of comments pins a brief to the on-device tier.
    ///
    /// A comment with no author counts as the reviewer's own — the bodies a delegation carries
    /// come from the review the reviewer is writing. A comment with an author and *no* signed-in
    /// login to compare it against counts as somebody else's, because that is the answer that
    /// cannot leak: an unknown viewer is not evidence of ownership.
    /// - Parameters:
    ///   - findings: The comments, capped or not.
    ///   - viewerLogin: The signed-in user's login, when there is one.
    /// - Returns: `true` when a cloud tier must not see this request.
    static func requiresOnDevice(_ findings: [Finding], viewerLogin: String?) -> Bool {
        findings.contains { finding in
            guard let author = finding.author, !author.isEmpty else { return false }
            guard let viewerLogin = viewerLogin?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !viewerLogin.isEmpty
            else { return true }
            return author.caseInsensitiveCompare(viewerLogin) != .orderedSame
        }
    }

    /// Builds the request for one tier.
    /// - Parameters:
    ///   - context: What the delegation is about.
    ///   - digest: The digest, built with ``digest(for:budget:)``.
    ///   - budget: The tier's *full* token budget.
    ///   - viewerLogin: The signed-in user's login, when there is one.
    /// - Returns: A request whose ``approximateTokenCount`` is inside `budget`.
    static func build(
        context: DelegationContext,
        digest: PullRequestDigest,
        budget: TokenBudget,
        viewerLogin: String? = nil
    ) -> AgentBriefRequest {
        var path: String?
        var line: Int?
        if case .reviewFinding(let findingPath, let findingLine) = context.origin {
            path = findingPath
            line = findingLine
        }
        return AgentBriefRequest(
            slug: context.slug,
            pullRequestTitle: context.title,
            headRefName: context.headRefName,
            // The same twelve characters ``DelegationPrompt/preamble(for:)`` puts in front of the
            // agent, so the brief and the preamble cannot name two different commits.
            headRefOid: String(context.headRefOid.prefix(12)),
            findingPath: path,
            findingLine: line,
            focusReasons: context.focusReasons.prefix(maximumFocusReasons).map {
                $0.count > maximumFocusReasonCharacters
                    ? String($0.prefix(maximumFocusReasonCharacters)) + "…"
                    : $0
            },
            findings: findings(in: context, budget: budget),
            digest: digest,
            onDeviceOnly: requiresOnDevice(context: context, viewerLogin: viewerLogin)
        )
    }
}
