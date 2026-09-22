import ShepherdCore
import SwiftUI

/// The review screen's second tab: description, commits, checks and unanchored threads.
struct ConversationView: View {
    @Environment(AppEnvironment.self) private var environment
    /// The review model.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions

    /// This tab's translation cache (ADR 0020): the description and every comment on it share one,
    /// so translating the description and then scrolling down does not re-translate anything, and
    /// leaving the pull request throws all of it away.
    @State private var translations = TranslationCoordinator()

    /// The state behind **Why?** on a red check (plan §3.F).
    ///
    /// One per review screen and created inert: no model session exists, and no card is drawn,
    /// until a reviewer clicks. It holds a log tail while the card is up and is thrown away with
    /// the screen — nothing about a diagnosis is persisted (ADR 0024).
    @State private var diagnosis = CIDiagnosisModel()

    /// The claims-vs-evidence card above the description (ADR 0026).
    ///
    /// One per review screen, holding the report so that walking every hunk of every file does not
    /// happen on every redraw; it draws nothing at all when the description claims nothing. It
    /// also owns the optional on-device pass over the same description, which is spent when the
    /// reviewer *opens* the card and never otherwise (ADR 0026's amendment).
    @State private var claims = ClaimsEvidenceModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                claimsCard
                recurringFinding
                closingIssues
                description
                timeline
                commits
                checks
                threads
            }
            .padding(18)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .onChange(of: model.detail, initial: true) { _, detail in
            claims.refresh(
                detail: detail,
                extractor: environment.claimExtractor,
                checker: environment.claimChecker
            )
        }
        // The tiers switched on or off while this pull request is open: the card's seams have to
        // follow at once, or a *Look closer* button would outlive the setting that allowed it.
        .onChange(of: environment.claimChecker == nil) {
            claims.refresh(
                detail: model.detail,
                extractor: environment.claimExtractor,
                checker: environment.claimChecker
            )
            Task { await claims.prepareCheckAvailability() }
        }
    }

    /// What the pull request says beside what Shepherd found (ADR 0026).
    ///
    /// The summary field is read and written straight through the model: this is a plain
    /// insertion into the composer the submit sheet shows, not generated text, so it carries no
    /// tier and does not go through ``AIDraftFieldState`` — what it does borrow is that type's
    /// rule, asked inside the card, that a non-empty field is never overwritten silently. It is
    /// read through a closure so that typing in that field does not re-render this tab.
    ///
    /// The one network read the card makes (ADR 0026's amendment) hangs here rather than inside
    /// the card: the fetcher is the signed-in session's client, which is what
    /// ``AppEnvironment/issueFetcher`` hands over — `nil` when signed out, and then the issue line
    /// says the criteria were not checked, exactly as it did before the read existed. The task's
    /// id is the model's own ``ClaimsEvidenceModel/acceptanceLoadKey``, so it starts when the
    /// reviewer opens the card and is cancelled when they move to another pull request, and a
    /// keystroke in the review summary does not restart it.
    @ViewBuilder
    private var claimsCard: some View {
        ClaimsEvidenceCard(
            model: claims,
            onOpenFile: { path, line in
                model.reveal(path: path, line: line)
            },
            editor: editorContext,
            currentSummary: { model.summaryText },
            onWriteSummary: { text in
                model.summaryText = text
            }
        )
        .task(id: claimsReadTrigger) {
            await claims.readWithModel(detail: model.detail)
        }
        .task(id: claims.acceptanceLoadKey) {
            await claims.loadAcceptanceCriteria(using: environment.issueFetcher)
        }
    }

    /// What has to change before the optional on-device pass is worth attempting again.
    ///
    /// `nil` while the card is collapsed, which is the whole of "the pass is attended": the
    /// reviewer expanding the card is what starts it, and there is no button because the
    /// expansion *is* the click (ADR 0026's amendment). A new pull request — or an edited
    /// description — is the other half; a routine refresh that changes neither does not restart
    /// the pass, and the model refuses a second pass for the same text itself, so a collapse and
    /// re-open costs nothing.
    private var claimsReadTrigger: String? {
        guard claims.state.isExpanded, let detail = model.detail else { return nil }
        return ClaimsEvidenceModel.readKey(for: detail)
    }

    /// "You have said this three times." — the feedback loop's card (ADR 0029).
    ///
    /// Under the claims card and above the description, which is where the reviewer is already
    /// reading before they look at the diff. It draws nothing at all when this repository has no
    /// undismissed recurring finding, which is the ordinary case; the coordinator that decides
    /// that is owned by ``AppEnvironment`` and shared by every window, because the pass is per
    /// account rather than per screen.
    ///
    /// Both buttons hand the *finding* back to the app layer. The card knows nothing about the
    /// delegation engine, and there is no path from it to a started run: ``AppEnvironment/startRuleDelegation(finding:pullRequest:)``
    /// opens a sheet with text in a field, and Run stays the reviewer's click (ADR 0011).
    @ViewBuilder
    private var recurringFinding: some View {
        if let summary = model.summary {
            RecurringFindingCard(
                finding: environment.recurringFindings.topFinding(for: summary.repo),
                onDraftRule: { finding in
                    environment.startRuleDelegation(finding: finding, pullRequest: summary)
                },
                onDismiss: { finding in
                    environment.recurringFindings.dismiss(finding)
                }
            )
        }
    }

    /// The issues this pull request closes, above the description (ADR 0032's Sprint 3
    /// amendment).
    ///
    /// Read straight off the cached `PullRequestDetail`: the closing references arrive on the
    /// same detail fetch as the review threads, so this section costs no request of its own and
    /// draws nothing at all when the list is empty.
    ///
    /// Activating a row opens the issue on github.com. There is no `DeepLink.issue` case in this
    /// build — the `shepherd://issue/…` grammar lands with the issues inbox — and this is the one
    /// call site to point at `AppEnvironment.openIssue` once that hook exists; the card hands the
    /// whole reference back for exactly that reason.
    @ViewBuilder
    private var closingIssues: some View {
        ClosingIssuesCard(
            issues: model.detail?.closingIssues ?? [],
            repo: model.summary?.repo,
            onOpen: { issue in ClosingIssuesCard.openOnGitHub(issue) }
        )
    }

    @ViewBuilder
    private var description: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "DESCRIPTION"))
                if let body = model.detail?.bodyMarkdown, !body.isEmpty {
                    TranslatableMarkdownText(markdown: body, translations: translations)
                } else {
                    Text(String(localized: "No description."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    /// The condensed activity list.
    ///
    /// Deliberately *not* translatable (ADR 0020). A `TimelineEvent.summary` is either one of
    /// Shepherd's own fixed words ("Approved", "Requested changes", "Commented") or a commit
    /// message headline — never a comment body, because `ResponseMapping.timeline(commits:…)`
    /// builds the list from commits and reviews rather than from GitHub's timeline API. There is no
    /// third-party prose here to offer a translation of; the comment bodies themselves are
    /// translatable where they are actually rendered, in ``ThreadCommentView``.
    @ViewBuilder
    private var timeline: some View {
        let events = model.detail?.timeline ?? []
        if !events.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "ACTIVITY"))
                    ForEach(events.suffix(12)) { event in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: symbol(for: event.kind))
                                .font(.system(size: 10))
                                .foregroundStyle(color(for: event.kind))
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.summary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 6) {
                                    Text(event.author.bestName)
                                    RelativeDateText(date: event.createdAt, style: .long)
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var commits: some View {
        let list = model.detail?.commits ?? []
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "COMMITS · \(list.count)"))
                if list.isEmpty {
                    Text(String(localized: "No commits fetched yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(list) { commit in
                        HStack(alignment: .top, spacing: 8) {
                            Text(String(commit.oid.prefix(7)))
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.accentText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.messageHeadline)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(2)
                                if !commit.trailers.isEmpty {
                                    Text(commit.trailers.joined(separator: " · "))
                                        .font(Theme.mono(10.5))
                                        .foregroundStyle(Theme.textMuted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            RelativeDateText(date: commit.committedDate)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var checks: some View {
        let list = (model.detail?.checks ?? []).sorted {
            Self.rank(for: $0) < Self.rank(for: $1)
        }
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(String(localized: "CHECKS · \(list.count)"))
                if list.isEmpty {
                    Text(String(localized: "No checks configured for this commit."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(list) { check in
                        HStack(spacing: 8) {
                            CheckRowView(check: check)
                            if let url = check.detailsURL {
                                Link(destination: url) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 10))
                                }
                                .help(String(localized: "Open the check on GitHub"))
                            }
                            if canDiagnose(check) {
                                Button(String(localized: "Why?")) { ask(check) }
                                    .buttonStyle(SecondaryButtonStyle(height: 22))
                                    .disabled(diagnosis.isAsking)
                                    .help(String(
                                        localized: "Asks a model why this check is red. It can only read — the checks, the log, the diff."
                                    ))
                            }
                        }
                    }
                }
            }
        }
        if let state = diagnosis.state {
            diagnosisCard(state)
        }
    }

    /// Where a check sorts in the CHECKS card: the one thing worth reading first is which ones
    /// are red, then which ones are still running, then everything that already passed — a long
    /// list of green checks should not be able to push the one failing check off the bottom.
    ///
    /// Built on ``CheckRun/rollupContribution`` rather than a parallel switch over `status` and
    /// `conclusion`: that is the same red/running/green split the rollup dot and ``canDiagnose(_:)``
    /// already use, so a check cannot rank as "red" here while reading as green everywhere else in
    /// the panel. `sorted(by:)` on `Array` has been a stable sort since Swift 5, so checks that
    /// share a rank keep GitHub's own order.
    /// - Parameter check: The check to rank.
    /// - Returns: `0` for a failed, cancelled or timed-out check, `1` for one still queued or
    ///   running, `2` for everything else.
    private static func rank(for check: CheckRun) -> Int {
        switch check.rollupContribution {
        case .failure: return 0
        case .pending: return 1
        case .success: return 2
        }
    }

    // MARK: - "Why is CI red?" (plan §3.F)

    /// Whether the **Why?** button is drawn on one check.
    ///
    /// Only on a red one, and only when a tier could take the question at all
    /// (``IntelligenceRouter/canDiagnose``) — a button that is always there and always fails would
    /// be worse than no button (ADR 0007: no feature hard-depends on a tier). A cancelled or
    /// timed-out check counts as red, because that is what a reviewer is looking at when they ask.
    ///
    /// Not ``IntelligenceRouter/canDraft``, which is the *drafting* buttons' question: that one is
    /// satisfied by a configured key alone, and a diagnosis starts on-device. On a Mac with
    /// Apple Intelligence off and a key configured this button is still drawn — the card asks
    /// before anything is sent — and on a Mac with neither it is not drawn at all.
    /// - Parameter check: The check the row is drawing.
    private func canDiagnose(_ check: CheckRun) -> Bool {
        check.rollupContribution == .failure && model.intelligence.canDiagnose
    }

    /// Asks a tier why one check is red.
    ///
    /// The router and the log reader are read *here*, at click time, rather than captured when
    /// the screen was built: the router is a value snapshot that a settings change replaces, and
    /// a card must not ask a tier the user switched off since.
    /// - Parameters:
    ///   - check: The red check.
    ///   - preferCloud: `true` only from the card's own "ask <provider> with the full log?"
    ///     button. ADR 0024: this is the one click that lets a CI log leave the Mac.
    private func ask(_ check: CheckRun, preferCloud: Bool = false) {
        guard let detail = model.detail, let summary = model.summary else { return }
        Task {
            await diagnosis.diagnose(
                check: check,
                detail: detail,
                summary: summary,
                router: model.intelligence,
                jobLog: model.session.github,
                preferCloud: preferCloud
            )
        }
    }

    /// "Open in …" for the `path:line` links of the two cards on this tab (ADR 0039), or `nil`
    /// before the pull request's summary has loaded and there is no repository to resolve against.
    private var editorContext: EditorContext? {
        guard let repo = model.summary?.repo else { return nil }
        return EditorContext(
            opener: EditorOpener(settings: environment.settings, toasts: environment.toasts),
            repo: repo
        )
    }

    /// The card under the checks list.
    @ViewBuilder
    private func diagnosisCard(_ state: CIDiagnosisState) -> some View {
        CIDiagnosisCard(
            state: state,
            checkName: diagnosis.checkName,
            isFileInDiff: { path in
                model.detail?.files.contains { $0.path == path } == true
            },
            cloudBadge: model.intelligence.cloudBadge,
            onOpenFile: { path, line in
                model.reveal(path: path, line: line)
            },
            editor: editorContext,
            onAskCloud: {
                // The same check, found again by name: the card holds the name rather than the
                // run, and the second rung must be about the check the reviewer asked about.
                guard let name = diagnosis.checkName,
                      let check = model.detail?.checks.first(where: { $0.name == name })
                else { return }
                ask(check, preferCloud: true)
            },
            onDraftBrief: {
                guard let summary = model.summary,
                      let context = diagnosis.briefContext(
                          summary: summary,
                          focusReasons: model.delegationFocusReasons
                      )
                else { return }
                // Opens the sheet — with feature E's drafter attached — and stops there. Run is
                // the reviewer's click (ADR 0011's amendment).
                environment.startDelegation(context)
            },
            onClose: { diagnosis.dismiss() }
        )
    }

    @ViewBuilder
    private var threads: some View {
        let list = model.unanchoredThreads
        if !list.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    // Pull-request-level threads, threads whose anchor GitHub reports as lost,
                    // and outdated ones — an outdated thread's line points into an older
                    // commit's diff, so it cannot be drawn on the current one.
                    CardTitle(String(localized: "CONVERSATIONS NOT ON THE CURRENT DIFF"))
                    ForEach(list) { thread in
                        VStack(alignment: .leading, spacing: 8) {
                            threadAnchorLabel(thread)
                            ForEach(thread.comments) { comment in
                                ThreadCommentView(comment: comment, translations: translations)
                            }
                            if let summary = model.summary {
                                HStack(spacing: 8) {
                                    Button {
                                        Task {
                                            await actions.setThread(
                                                on: summary,
                                                threadID: thread.id,
                                                resolved: !thread.isResolved
                                            )
                                        }
                                    } label: {
                                        Text(
                                            thread.isResolved
                                                ? String(localized: "Unresolve")
                                                : String(localized: "Resolve")
                                        )
                                    }
                                    .buttonStyle(SecondaryButtonStyle(height: 26))
                                    // Keyed by the thread, so a card showing a dozen
                                    // conversations spins the one button that was pressed.
                                    .busy(actions.activity.isRunning(thread.id, .thread))

                                    Button(String(localized: "Delegate this finding…")) {
                                        environment.startDelegation(
                                            .reviewFinding(summary, thread: thread)
                                        )
                                    }
                                    .buttonStyle(SecondaryButtonStyle(height: 26, tint: Theme.agent))
                                }
                            }
                        }
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
        }
    }

    /// Where a thread that cannot be drawn on the diff used to point.
    ///
    /// Outdated threads keep an `originalLine` from the commit they were written against. It
    /// is shown, never used to position anything: the current diff no longer has that line.
    @ViewBuilder
    private func threadAnchorLabel(_ thread: ReviewThread) -> some View {
        if let path = thread.path {
            HStack(spacing: 6) {
                Text(path)
                    .font(Theme.mono(11))
                    .lineLimit(1)
                    .truncationMode(.head)
                if let original = thread.originalLine {
                    Text(String(localized: "· was line \(original)"))
                        .font(.system(size: 11))
                }
                if thread.isOutdated {
                    ChipView(text: String(localized: "outdated"), color: Theme.pending, size: 10)
                }
                if thread.isResolved {
                    ChipView(text: String(localized: "resolved"), color: Theme.success, size: 10)
                }
            }
            .foregroundStyle(Theme.textMuted)
        }
    }

    private func symbol(for kind: TimelineEvent.Kind) -> String {
        switch kind {
        case .commit: return "circle.fill"
        case .reviewApproved: return "checkmark.circle"
        case .reviewChangesRequested: return "exclamationmark.circle"
        case .reviewCommented, .comment: return "bubble.left"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        case .reopened: return "arrow.clockwise.circle"
        case .readyForReview: return "eye"
        case .other: return "circle"
        }
    }

    private func color(for kind: TimelineEvent.Kind) -> Color {
        switch kind {
        case .reviewApproved, .merged: return Theme.success
        case .reviewChangesRequested, .closed: return Theme.failure
        case .commit: return Theme.textMuted
        default: return Theme.accentText
        }
    }
}
