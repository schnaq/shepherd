import Foundation
import ShepherdCore

/// What a delegation is about: which pull request or issue, and which finding (if any) started it.
///
/// The context is what turns a button press into a useful prompt. It is a plain value so the
/// prompt builder can be tested without a session, a database or a network.
///
/// The fields are named after the pull request they were written for and are read **generically**
/// when the origin is an issue (ADR 0032's 2026-09-04 amendment): ``prID`` is then the issue's
/// node id, ``number`` its number, and ``headRefName`` the branch Shepherd is about to create for
/// it. Renaming them would have touched every pull-request call site for no behavioural change,
/// which is the trade the outbox already made for the same reason.
struct DelegationContext: Sendable, Equatable, Identifiable {
    /// Where the delegation was started from.
    enum Origin: Sendable, Equatable {
        /// The whole pull request ("address the review").
        case pullRequest
        /// One review thread, anchored to a file and possibly a line.
        case reviewFinding(path: String, line: Int?)
        /// An issue handed over as new work (ADR 0032's 2026-09-04 amendment).
        ///
        /// A genuine third case rather than a flag on the two above, because the ground rules
        /// differ: the other two stand on an existing pull request's commit and must not move a
        /// branch, while this one has nothing to stand on and its whole point is work that does
        /// not exist yet. Every switch over this enum answers a different question for it — the
        /// preamble, the default task, the commit message and the worktree's own shape — which
        /// is exactly the test for whether a case has earned itself.
        case issue
        /// A free-text task on a repository, with no pull request or issue behind it (ADR 0011's
        /// 2026-09-23 amendment).
        ///
        /// The fourth case, and it earns itself by the issue case's own test: it is new work
        /// like an issue — a branch Shepherd names, started from the default branch's tip — but
        /// there is no number, no title and no thread. Its branch is named after the *task
        /// text*, which only exists once somebody has typed it into the sheet, so the context
        /// leaves ``headRefName`` empty and ``DelegationModel`` picks the branch when the run
        /// starts. There is nothing on GitHub to report back to either, which is why the
        /// `delegation.finished` webhook is not sent for it (see ``AppEnvironment``).
        case repository
    }

    /// The pull request's node id — also the identity that keeps one sheet per target.
    ///
    /// The **issue's** node id when ``origin`` is ``Origin/issue``. GitHub's node ids are unique
    /// across both, so the one-run-per-target rule holds without knowing which kind it is.
    var prID: String
    /// The repository.
    var repo: RepoRef
    /// The pull request number.
    var number: Int
    /// The pull request title.
    var title: String
    /// The head branch, which is what a push would go to.
    ///
    /// For ``Origin/issue`` this is the branch Shepherd assigned the work — it does not exist
    /// yet, and creating it is the first thing the worktree does.
    var headRefName: String
    /// The head commit the worktree is created at.
    ///
    /// Empty for ``Origin/issue``, and that is not a missing value: new work has no commit to be
    /// pinned to, so the worktree starts at the default branch's tip instead. Only the two
    /// pull-request origins read this field.
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

    /// The template the task text was rendered from, for an issue handover.
    ///
    /// `nil` for the pull-request origins, which have no template: their task text is built from
    /// the pull request and the thread. It is carried rather than derived because the outbound
    /// handover event reports **which** template was used (ADR 0012's envelope) and because the
    /// sheet's own default has to render the same one the caller did — one template, read twice,
    /// rather than two that agree until somebody changes one.
    var taskTemplate: String?

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

    /// `owner/name#123`, or just `owner/name` for a repository task, which has no number.
    var slug: String {
        isRepositoryTask ? repo.fullName : "\(repo.fullName)#\(number)"
    }

    /// Whether this context is about an issue.
    ///
    /// A property rather than a comparison at each call site, because two of the three readers
    /// are about *where the work happens* rather than about the origin as such: the worktree
    /// directory an issue gets and the git entry point that creates it.
    var isIssue: Bool {
        if case .issue = origin { return true }
        return false
    }

    /// Whether this context is a free-text task on a repository.
    var isRepositoryTask: Bool {
        if case .repository = origin { return true }
        return false
    }

    /// Whether the run starts new work on a branch of Shepherd's rather than standing on an
    /// existing pull request's commit.
    ///
    /// The question the worktree entry point and the sheet's wording actually ask: an issue and
    /// a repository task both start from the default branch's tip on an `agent/…` branch
    /// (``GitWorktree/addForNewWork(branch:)``), and both may be finished by the run itself.
    var isNewWork: Bool { isIssue || isRepositoryTask }

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
        taskTemplate: String? = nil,
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
        self.taskTemplate = taskTemplate
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

    /// A context for an issue handed over as new work (ADR 0032's 2026-09-04 amendment).
    ///
    /// The branch is Shepherd's, from ``GitWorktree/branchName(issueNumber:)``, and there is no
    /// commit: see ``headRefOid``. Nothing here reads the issue body — the *task text* does, and
    /// it is rendered by ``ShepherdCore/IssueDelegationPrompt`` and handed to the run the way an
    /// automatic delegation hands in its own rendered template (ADR 0016), so a caller with only
    /// a row can still assign and one with the body can say more.
    /// - Parameters:
    ///   - row: The issue.
    ///   - template: The task template to render, defaulting to the built-in one.
    static func issue(
        _ row: IssueRowSummary,
        template: String = IssueDelegationPrompt.defaultTemplate
    ) -> DelegationContext {
        DelegationContext(
            prID: row.id,
            repo: row.repo,
            number: row.number,
            title: row.title,
            headRefName: GitWorktree.branchName(issueNumber: row.number),
            headRefOid: "",
            origin: .issue,
            taskTemplate: template
        )
    }

    /// A context for a free-text task on a repository (ADR 0011's 2026-09-23 amendment).
    ///
    /// Everything a pull request would fill in is empty, on purpose rather than for want of a
    /// value: there is no number, no head commit and — until the run starts and the task text
    /// names it — no branch. The identity is the repository, so a second "Start an agent…" on the
    /// same repository while a run is going reveals that run instead of starting a rival one
    /// (the one-run-per-target rule, ``DelegationCenter``). A finished run's branch and worktree
    /// are left alone by the next task, which gets a slug of its own.
    /// - Parameter repo: The repository, which must have a linked local checkout to run.
    static func repository(_ repo: RepoRef) -> DelegationContext {
        DelegationContext(
            prID: repositoryID(repo),
            repo: repo,
            number: 0,
            title: repo.fullName,
            headRefName: "",
            headRefOid: "",
            origin: .repository
        )
    }

    /// The identity a repository task is kept under: `repository:owner/name`, lowercased.
    ///
    /// Not a node id, and it cannot collide with one: GitHub's ids never contain a colon.
    /// Lowercased because GitHub treats the two names case-insensitively, and a rail row and a
    /// ⌘K command spelling the repository differently must still find the same run.
    /// - Parameter repo: The repository.
    static func repositoryID(_ repo: RepoRef) -> String {
        "repository:\(repo.fullName.lowercased())"
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
/// agent where it is, what it may do with the result, and that the change should stay small
/// (ADR 0011's guardrails are not only flags). The **task** is the user's text, appended after it.
///
/// There are two preambles, chosen by the origin, and what differs is the ground rules rather
/// than the wording (ADR 0011's 2026-09-04 amendment). Addressing a pull request forbids a
/// branch, a push and a pull request, because the reviewer reads the diff and publishes it. An
/// issue is the opposite situation: there is nothing to review yet, so the work belongs on a
/// branch and the run may finish the job with the credentials its own tool already has.
enum DelegationPrompt {
    /// The fixed, Shepherd-controlled part of the prompt.
    /// - Parameter context: What the delegation is about.
    static func preamble(for context: DelegationContext) -> String {
        if context.isIssue { return issuePreamble(for: context) }
        if context.isRepositoryTask { return repositoryPreamble(for: context) }
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

    /// The preamble for an issue handed over as new work.
    ///
    /// Three things are said that the other preamble does not say, and each is a decision rather
    /// than a nicety. The **branch is Shepherd's**, named after the issue, so the run never has
    /// to invent a name and the app can find the work again. The worktree starts at the
    /// repository's **default branch**, so a commit made here belongs to something. And the run
    /// **may finish the job** — commit, publish, open a pull request — with whatever git and
    /// GitHub credentials its own tool already has, which is ADR 0011's standing rule that
    /// Shepherd inherits that tool's authentication and never touches it. Shepherd's own code
    /// still transmits nothing: the only push it performs is the one a person presses.
    /// - Parameter context: What the delegation is about.
    private static func issuePreamble(for context: DelegationContext) -> String {
        String(
            localized: """
                You are running inside a git worktree that Shepherd created for issue \
                #\(context.number) of \(context.repo.fullName). It is checked out on a new \
                branch, \(context.headRefName), started from the tip of the repository's \
                default branch. Shepherd named that branch; do not rename it and do not switch \
                to another one.

                Ground rules:
                - The work is yours to finish on this branch. When it is ready you may commit \
                it, publish the branch and open a pull request, using the git and GitHub \
                credentials you already have. If you cannot publish, commit anyway and say so \
                in your final message: the reviewer can publish the worktree from Shepherd.
                - Solve the issue and nothing else. Do not reformat, rename or refactor \
                anything the issue does not ask for.
                - Read the repository before you write: its tests, its conventions and its \
                contribution notes are the specification, not a suggestion.
                - Prefer the project's existing tests and tooling over adding new ones.
                - If the issue is unclear or you would have to guess at intent, say so in your \
                final message instead of guessing.
                """
        )
    }

    /// The preamble for a free-text task on a repository (ADR 0011's 2026-09-23 amendment).
    ///
    /// The issue preamble's ground rules, word for word where they apply, because the situation
    /// is the same one: new work on a branch Shepherd named, started from the default branch,
    /// which the run may finish with its own credentials. Where the issue preamble names the
    /// issue, this one names the repository and the branch; the task itself follows under "Task
    /// from the reviewer", exactly as it does for the other origins.
    /// - Parameter context: What the delegation is about, with ``DelegationContext/headRefName``
    ///   set to the branch the run was given.
    private static func repositoryPreamble(for context: DelegationContext) -> String {
        String(
            localized: """
                You are running inside a git worktree that Shepherd created for a task on \
                \(context.repo.fullName). It is checked out on a new branch, \
                \(context.headRefName), started from the tip of the repository's default branch. \
                Shepherd named that branch; do not rename it and do not switch to another one.

                Ground rules:
                - The work is yours to finish on this branch. When it is ready you may commit \
                it, publish the branch and open a pull request, using the git and GitHub \
                credentials you already have. If you cannot publish, commit anyway and say so \
                in your final message: the reviewer can publish the worktree from Shepherd.
                - Do what the task asks and nothing else. Do not reformat, rename or refactor \
                anything the task does not ask for.
                - Read the repository before you write: its tests, its conventions and its \
                contribution notes are the specification, not a suggestion.
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

        case .issue:
            // Rendered from the same template the panel renders, with the two things a context
            // does not carry left out: an assignment started from the issues section hands in
            // its own task text (labels and body included) exactly as an automatic delegation
            // hands in its rendered rule template, and this is what the sheet shows when nobody
            // did — a link, a test, a context built from a row nobody had read.
            return IssueDelegationPrompt.render(
                template: context.taskTemplate ?? IssueDelegationPrompt.defaultTemplate,
                number: context.number,
                repo: context.repo,
                title: context.title
            )

        case .repository:
            // Nothing to prefill: the task *is* what the user types, and a placeholder sentence
            // would have to be deleted before every run — or, worse, would be run.
            return ""

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
