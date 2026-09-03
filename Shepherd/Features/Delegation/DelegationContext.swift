import Foundation
import ShepherdCore

/// What a delegation is about: which pull request, and which finding (if any) started it.
///
/// The context is what turns a button press into a useful prompt. It is a plain value so the
/// prompt builder can be tested without a session, a database or a network.
struct DelegationContext: Sendable, Equatable, Identifiable {
    /// Where the delegation was started from.
    enum Origin: Sendable, Equatable {
        /// The whole pull request ("address the review").
        case pullRequest
        /// One review thread, anchored to a file and possibly a line.
        case reviewFinding(path: String, line: Int?)
    }

    /// The pull request's node id — also the identity that keeps one sheet per pull request.
    var prID: String
    /// The repository.
    var repo: RepoRef
    /// The pull request number.
    var number: Int
    /// The pull request title.
    var title: String
    /// The head branch, which is what a push would go to.
    var headRefName: String
    /// The head commit the worktree is created at.
    var headRefOid: String
    /// What started the delegation.
    var origin: Origin
    /// Review-priority reasons for the riskiest files, used to focus the prompt.
    var focusReasons: [String]
    /// The comments of the review thread, as Markdown source.
    var findingComments: [String]
    /// Who wrote each of ``findingComments``, positionally, when the caller knows.
    ///
    /// Empty, or shorter than ``findingComments``, is allowed and means "not known here" — the
    /// task text built by ``DelegationPrompt`` never needed an author, and a caller that only has
    /// bodies must not be forced to invent one. It exists for the *brief* (plan §3.E): a drafted
    /// brief quoting a colleague's comment may only be produced on-device (ADR 0020's reasoning),
    /// and that decision cannot be made from bodies alone. A comment with no author here counts
    /// as the reviewer's own, because that is what a pending review's comments are.
    var findingCommentAuthors: [String]

    /// The session this delegation answers, when it answers one (ADR 0030).
    ///
    /// A field beside ``origin`` rather than a fourth ``Origin`` case, on purpose: the origin of
    /// a session send *is* a review finding — the same path, the same line, the same commit
    /// message if it ever pushed — and a new case would have forced every exhaustive switch over
    /// `Origin` (the task text, the commit message, the CI diagnosis card, the brief) to answer
    /// a question it has no new answer for. What is genuinely new is only the *return address*,
    /// and that is what this holds.
    ///
    /// When it is set, two things change and nothing else: the command comes from the session
    /// templates (``AgentCLIConfiguration/sessionInvocation(message:session:worktree:executable:)``),
    /// and the prompt is the confirmed message with no preamble in front of it — see
    /// ``DelegationPrompt/full(for:task:)``.
    var session: SessionReference?

    /// One sheet per pull request.
    var id: String { prID }

    /// `owner/name#123`.
    var slug: String { "\(repo.fullName)#\(number)" }

    /// Creates a context.
    init(
        prID: String,
        repo: RepoRef,
        number: Int,
        title: String,
        headRefName: String,
        headRefOid: String,
        origin: Origin = .pullRequest,
        focusReasons: [String] = [],
        findingComments: [String] = [],
        findingCommentAuthors: [String] = [],
        session: SessionReference? = nil
    ) {
        self.prID = prID
        self.repo = repo
        self.number = number
        self.title = title
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.origin = origin
        self.focusReasons = focusReasons
        self.findingComments = findingComments
        self.findingCommentAuthors = findingCommentAuthors
        self.session = session
    }

    /// A context for a whole pull request.
    /// - Parameters:
    ///   - summary: The pull request.
    ///   - focusReasons: Review-priority reasons, `"path — reason"`, riskiest first.
    static func pullRequest(
        _ summary: PullRequestSummary,
        focusReasons: [String] = []
    ) -> DelegationContext {
        DelegationContext(
            prID: summary.id,
            repo: summary.repo,
            number: summary.number,
            title: summary.title,
            headRefName: summary.headRefName,
            headRefOid: summary.headRefOid,
            origin: .pullRequest,
            focusReasons: focusReasons
        )
    }

    /// A context for one review thread.
    /// - Parameters:
    ///   - summary: The pull request the thread belongs to.
    ///   - thread: The thread whose comments become the task.
    static func reviewFinding(
        _ summary: PullRequestSummary,
        thread: ReviewThread
    ) -> DelegationContext {
        DelegationContext(
            prID: summary.id,
            repo: summary.repo,
            number: summary.number,
            title: summary.title,
            headRefName: summary.headRefName,
            headRefOid: summary.headRefOid,
            origin: .reviewFinding(
                path: thread.path ?? String(localized: "the pull request"),
                line: thread.line ?? thread.originalLine
            ),
            findingComments: thread.comments.map(\.bodyMarkdown),
            // Positional, so the two arrays are read as pairs. Carried for the brief's privacy
            // rule only (see ``findingCommentAuthors``); the task text ignores it.
            findingCommentAuthors: thread.comments.map(\.author.login)
        )
    }

    /// A context for a finding addressed to the session that wrote the code (ADR 0030).
    ///
    /// The finding is the reviewer's own text, which is why ``findingCommentAuthors`` stays
    /// empty: an empty author means "the reviewer's own" everywhere it is read, and nobody
    /// else's words travel in a session send.
    /// - Parameters:
    ///   - summary: The pull request the finding is on.
    ///   - session: The return address from the head commits.
    ///   - path: The anchored file, or `nil` for a review summary.
    ///   - line: The anchored line, when there is one.
    ///   - text: Exactly what the reviewer typed.
    static func sessionFinding(
        _ summary: PullRequestSummary,
        session: SessionReference,
        path: String?,
        line: Int?,
        text: String
    ) -> DelegationContext {
        DelegationContext(
            prID: summary.id,
            repo: summary.repo,
            number: summary.number,
            title: summary.title,
            headRefName: summary.headRefName,
            headRefOid: summary.headRefOid,
            origin: .reviewFinding(
                path: path ?? String(localized: "the pull request"),
                line: line
            ),
            findingComments: [text],
            session: session
        )
    }
}

/// Builds the prompt handed to the agent CLI.
///
/// The prompt has two halves. The **preamble** is Shepherd's and is not editable: it tells the
/// agent where it is, that it must not push, and that the change should stay small (ADR 0011's
/// guardrails are not only flags). The **task** is the user's text, appended after it.
enum DelegationPrompt {
    /// The fixed, Shepherd-controlled part of the prompt.
    /// - Parameter context: What the delegation is about.
    static func preamble(for context: DelegationContext) -> String {
        let shortOid = String(context.headRefOid.prefix(12))
        return String(
            localized: """
                You are running inside a detached git worktree that Shepherd created for pull \
                request #\(context.number) of \(context.repo.fullName) — branch \
                \(context.headRefName), checked out at commit \(shortOid).

                Ground rules:
                - Do not push, do not create or switch branches, and do not open a pull \
                request. The reviewer reads your diff and pushes it themselves.
                - Keep the change as small as it can be. Do not reformat, rename or refactor \
                anything the task does not ask for.
                - Prefer the project's existing tests and tooling over adding new ones.
                - If the task is unclear or you would have to guess at intent, say so in your \
                final message instead of guessing.
                """
        )
    }

    /// The editable text the sheet is prefilled with.
    /// - Parameter context: What the delegation is about.
    static func defaultTask(for context: DelegationContext) -> String {
        switch context.origin {
        case .pullRequest:
            var lines = [
                String(localized: "Pull request: \(context.title)"),
                "",
                String(localized: "Address the open review feedback on this pull request."),
            ]
            if !context.focusReasons.isEmpty {
                lines.append("")
                lines.append(String(localized: "Shepherd ranked these files as the riskiest:"))
                lines.append(contentsOf: context.focusReasons.prefix(6).map { "- \($0)" })
            }
            return lines.joined(separator: "\n")

        case .reviewFinding(let path, let line):
            var lines: [String] = []
            if let line {
                lines.append(String(localized: "Review finding in \(path), line \(line):"))
            } else {
                lines.append(String(localized: "Review finding in \(path):"))
            }
            lines.append("")
            for comment in context.findingComments {
                let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lines.append(contentsOf: trimmed.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" })
                lines.append("")
            }
            lines.append(String(localized: "Fix this finding."))
            return lines.joined(separator: "\n")
        }
    }

    /// Joins the preamble and the user's task into the prompt that is actually sent.
    ///
    /// A delegation that answers a session (ADR 0030) gets **no preamble**: the message was
    /// shown to the reviewer verbatim in the confirmation sheet, and what is sent has to be that
    /// string and nothing else. The session it goes to already knows where it is — it wrote the
    /// branch — and Shepherd's ground rules reach that run as the run's own guardrails (the
    /// worktree it is spawned in, the transcript, the fact that nothing is ever pushed for it),
    /// not as sentences appended to somebody's review comment.
    /// - Parameters:
    ///   - context: What the delegation is about.
    ///   - task: The user's editable text.
    static func full(for context: DelegationContext, task: String) -> String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.session == nil else { return trimmed }
        return preamble(for: context) + "\n\n---\n\n" + String(localized: "Task from the reviewer:") + "\n" + trimmed
    }
}
