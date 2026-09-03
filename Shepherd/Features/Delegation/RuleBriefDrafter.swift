import Foundation
import ShepherdCore

/// Turns a recurring finding into the delegation sheet's task text (ADR 0029).
///
/// The bridge between the review screen's card and ADR 0011's worktree flow, and it is
/// deliberately only *text*: it builds a ``DelegationContext`` and a prefilled task, hands both to
/// ``DelegationCenter/open(context:settings:toasts:onDidPush:onDidFinish:brief:)``, and stops.
/// Run is the reviewer's click, exactly as it is for every other delegation, and the pull request
/// the agent opens is reviewed in Shepherd like any other — Shepherd never commits to a
/// repository.
///
/// Two things it does *not* do are worth naming, because they are the whole shape of the feature:
///
/// - **It does not read the repository's instructions file.** `GitHubKit` has no file-content read
///   and this feature did not add one. The task quotes the three comments and names both
///   candidate filenames; the agent is already standing in a worktree of the repository, so it can
///   read `CLAUDE.md` or `AGENTS.md` itself — which is also the only way to write a rule "in the
///   file's existing voice" without Shepherd shipping the file through a prompt.
/// - **It does not touch the pull request the reviewer is on.** The context names that pull
///   request because that is the worktree the agent gets, and the task says in as many words that
///   the change belongs in the instructions file and nowhere else.
enum RecurringFindingRule {
    /// How many of the finding's comments the card and the task quote.
    ///
    /// Taken from the pure rule rather than restated, so the card's sentence ("three times") and
    /// the quotes under it cannot disagree.
    static let quotedCount = RecurringFindingDetector.maximumQuotes

    /// The comments the card shows and the task quotes, oldest first.
    /// - Parameter finding: The recurring finding.
    static func quotes(of finding: RecurringFinding) -> [RecurringFindingComment] {
        Array(finding.comments.prefix(quotedCount))
    }

    /// The delegation context for drafting a rule out of a finding.
    ///
    /// ``DelegationContext/Origin/pullRequest`` rather than ``DelegationContext/Origin/reviewFinding(path:line:)``,
    /// and that is not a shortcut: a rule is not anchored to a file or a line, and an origin that
    /// claimed it was would make ``DelegationPrompt/defaultTask(for:)`` and the drafted brief both
    /// talk about a place in the diff.
    ///
    /// The quoted comments travel as ``DelegationContext/findingComments`` with the reviewer's own
    /// login in ``DelegationContext/findingCommentAuthors`` — stated rather than left empty, so
    /// that "these are the reviewer's own words, so the cloud rung is allowed" is something
    /// ``AgentBriefRequest/requiresOnDevice(context:viewerLogin:)`` *decides* from matching data
    /// rather than something this call site got away with by omitting an author. And the claim is
    /// true by construction rather than by trust: a recurring finding's comments come out of a
    /// query that matched the viewer's login and returned nobody else's rows
    /// (``ShepherdPersistence/DatabaseManager/viewerReviewComments(login:since:)``), so there is no
    /// arrangement of this feature in which a colleague's sentence is one of these quotes.
    /// - Parameters:
    ///   - finding: The recurring finding.
    ///   - pullRequest: The pull request the reviewer is on — the worktree the agent gets.
    ///   - viewerLogin: The signed-in user's login, when there is one.
    static func context(
        finding: RecurringFinding,
        pullRequest: PullRequestSummary,
        viewerLogin: String?
    ) -> DelegationContext {
        let bodies = quotes(of: finding).map(\.body)
        return DelegationContext(
            prID: pullRequest.id,
            repo: pullRequest.repo,
            number: pullRequest.number,
            title: pullRequest.title,
            headRefName: pullRequest.headRefName,
            headRefOid: pullRequest.headRefOid,
            origin: .pullRequest,
            findingComments: bodies,
            findingCommentAuthors: viewerLogin.map { login in
                Array(repeating: login, count: bodies.count)
            } ?? []
        )
    }

    /// The task the sheet opens with when no model can draft one.
    ///
    /// The tier-1 answer, and the whole feature works without a model: three quotes, the two
    /// candidate filenames, and one sentence about length and voice. A reviewer who has never
    /// configured an endpoint gets a task they can read, edit and run — which is ADR 0007's rule
    /// ("no feature hard-depends on a model") applied to a card whose entire purpose is to save
    /// them from typing this out.
    /// - Parameter finding: The recurring finding.
    static func template(for finding: RecurringFinding) -> String {
        let quoted = blockQuote(quotes(of: finding).map(\.body))
        return String(
            localized: """
                Add a rule to the repository's agent instructions (CLAUDE.md or AGENTS.md, \
                whichever this repository has; if it has neither, say so in your final message \
                instead of creating one) that prevents this recurring review finding:

                \(quoted)

                Keep it to one paragraph, in the file's existing voice. Change nothing else in \
                this pull request.
                """
        )
    }

    /// Renders comment bodies as one Markdown block quote.
    ///
    /// Every line is prefixed, the way ``DelegationPrompt/defaultTask(for:)`` does it, because a
    /// comment can be several paragraphs and a block quote with unprefixed lines in it stops being
    /// a quote halfway through.
    /// - Parameter bodies: The comment bodies.
    static func blockQuote(_ bodies: [String]) -> String {
        var blocks: [String] = []
        for body in bodies {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            blocks.append(
                trimmed
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
            )
        }
        // A quoted blank line between the quotes, so three separate comments read as three
        // comments rather than as one run-on paragraph.
        return blocks.joined(separator: "\n>\n")
    }
}

/// The ✨ button's drafter, asked for a **rule** instead of a fix (ADR 0029, plan §2.D).
///
/// A variant of ``AgentBriefDrafter`` rather than a second drafting surface: the sheet, the field,
/// the streaming, the tier caption, the replace/append question and the "Run is the reviewer's
/// click" guarantee are all feature E's and are reused unchanged. What differs is one sentence of
/// steering, ``IntelligencePrompt/agentRuleBriefInstruction``.
///
/// **How the steering reaches the model, and why it is where it is.** An agent-brief request has
/// no instruction field — `Shepherd/Intelligence/` builds its own system prompt per request type —
/// so the sentence travels at the head of ``DelegationContext/findingComments``, which is the one
/// free-text channel the brief's prompt body presents as *the task*. It says what it is in its
/// first clause ("Shepherd's instruction, not a review comment"), so nothing pretends to be
/// something it is not, and it is paired with an empty author, which keeps
/// ``AgentBriefRequest/requiresOnDevice(context:viewerLogin:)`` reading exactly the three real
/// comments it is meant to read. The honest alternative — an instruction parameter on the request
/// and a branch in all three providers — is a change to the intelligence layer that one card does
/// not justify; if a second steered brief ever appears, that is the moment to make the hook real.
///
/// Everything else about the request is feature E's: the digest is built once at the on-device
/// tier's budget with the comments' share reserved first, the ladder refuses the cloud rung for a
/// colleague's comment, and an automatic delegation cannot receive any of it because
/// ``DelegationCenter/startAutomatically(context:task:settings:toasts:onDidPush:onDidFinish:)``
/// has no parameter for a drafter at all (ADR 0016).
enum RuleBriefDrafter {
    /// The steering sentence, as it appears in the request.
    ///
    /// Read from ``IntelligencePrompt`` rather than written here, so there is one copy of the
    /// wording and a test can assert that it is what travelled.
    static var steeringComment: String { IntelligencePrompt.agentRuleBriefInstruction }

    /// The live drafter: the router, the signed-in login, and a way to read the pull request.
    ///
    /// The same three seams ``AgentBriefDrafter/live(router:viewerLogin:detail:)`` takes, and the
    /// same digest arithmetic, so the two drafting paths cannot drift onto two different budgets.
    /// - Parameters:
    ///   - router: The tier ladder.
    ///   - viewerLogin: The signed-in user's login, when there is one.
    ///   - detail: Reads a pull request out of the local database by node id.
    /// - Returns: The drafter the sheet uses for a rule.
    static func live(
        router: IntelligenceRouter,
        viewerLogin: String?,
        detail: @escaping @Sendable (String) async -> PullRequestDetail?
    ) -> AgentBriefDrafter {
        AgentBriefDrafter(canDraft: router.canDraft) { context in
            guard let pullRequest = await detail(context.prID) else {
                return .unavailable(
                    String(
                        localized: "Shepherd has not fetched this pull request yet, so there is nothing to draft a rule from."
                    )
                )
            }
            let steered = steer(context)
            return await router.streamAgentBrief(
                for: steered,
                digest: AgentBriefRequest.digest(
                    for: pullRequest,
                    budget: OnDeviceProvider.budget
                ),
                viewerLogin: viewerLogin
            )
        }
    }

    /// Puts the steering sentence in front of the quoted comments.
    ///
    /// Prepended, not appended: ``AgentBriefRequest/findings(in:budget:)`` fills the comments'
    /// share of the budget from the front and stops at the first comment that does not fit, so a
    /// sentence at the end is the one a long finding would drop — and dropping it would turn a
    /// rule draft into an ordinary fix-this-pull-request brief with no visible sign that it had.
    ///
    /// The author list is extended by one empty entry so the positional pairing with
    /// ``DelegationContext/findingCommentAuthors`` still lines up (an empty author counts as the
    /// reviewer's own, which is what Shepherd's own sentence is closest to).
    /// - Parameter context: The context the card built.
    /// - Returns: The same context with the steering comment first.
    static func steer(_ context: DelegationContext) -> DelegationContext {
        var steered = context
        steered.findingComments = [steeringComment] + context.findingComments
        if !context.findingCommentAuthors.isEmpty {
            steered.findingCommentAuthors = [""] + context.findingCommentAuthors
        }
        return steered
    }
}
