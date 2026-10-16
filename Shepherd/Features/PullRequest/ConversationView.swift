import ShepherdCore
import SwiftUI

/// The review screen's second tab: GitHub's conversation, read in full and answered in place
/// (ADR 0043).
///
/// Top to bottom: the intelligence cards, which are read before the discussion; the description
/// as the first post; the stream — comments, reviews with their threads, commits, events — in
/// GitHub's order; the checks, where GitHub has them; and a comment field.
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    claimsCard
                    recurringFinding
                    closingIssues
                    stack
                    if let summary = model.summary {
                        descriptionPost(summary)
                        // Said where the stream starts when GitHub has older items than Shepherd
                        // read: the read keeps the newest ones, which are the ones a reviewer is
                        // here for.
                        if model.detail?.conversation?.hasEarlierItems == true {
                            StreamNoticeRow(
                                symbol: "clock.arrow.circlepath",
                                text: String(localized: "Earlier activity is on GitHub"),
                                buttonTitle: String(localized: "Open on GitHub")
                            ) { actions.openOnGitHub(summary) }
                        }
                        // Left out when empty rather than drawn empty, which would still take a
                        // place in this stack and double the gap around it.
                        if !model.conversationEntries.isEmpty {
                            ConversationStream(
                                entries: model.conversationEntries,
                                summary: summary,
                                model: model,
                                actions: actions,
                                translations: translations
                            )
                            .equatable()
                        }
                    }
                    checks
                    if let summary = model.summary {
                        ConversationComposer(model: model, actions: actions, summary: summary)
                            .id(Self.composerID)
                    }
                }
                .padding(18)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // *Quote reply* has just filled the field and asked for the keyboard; the field has to
            // be on screen to take it.
            .onChange(of: model.composerFocusRequest) {
                withAnimation { proxy.scrollTo(Self.composerID, anchor: .bottom) }
            }
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

    /// The pull request's GitHub stack, bottom to top, as far as the inbox holds it (ADR 0042).
    ///
    /// Beside the issues it closes, because both say what this pull request is part of. Built from
    /// the session's inbox rows minus the ignored ones — the rows the inbox itself holds
    /// (`InboxModel.allRows`), not the filtered list — and a click opens the other pull request's
    /// review, which is where a reader of this screen goes next.
    @ViewBuilder
    private var stack: some View {
        if let summary = model.summary, summary.stack != nil,
           let overview = PullRequestStackOverview.make(
               for: summary,
               in: environment.settings.ignoredPullRequests.filter(environment.session?.inboxRows ?? [])
           ) {
            PullRequestStackCard(overview: overview) { member in
                environment.openReview(prID: member.id)
            }
        }
    }

    // MARK: - The conversation (ADR 0043)

    /// What ``ScrollViewReader`` scrolls to when *Quote reply* fills the comment field.
    private static let composerID = "composer"

    /// The description, drawn as the conversation's first post.
    private func descriptionPost(_ summary: PullRequestSummary) -> some View {
        let conversation = model.detail?.conversation
        return ConversationPostView(
            model: model,
            actions: actions,
            translations: translations,
            subjectID: summary.id,
            author: summary.author,
            verb: String(localized: "opened this pull request"),
            date: summary.createdAt,
            markdown: model.detail?.bodyMarkdown ?? "",
            isEdited: conversation?.isDescriptionEdited ?? false,
            reactions: conversation?.descriptionReactions ?? [],
            url: AppConfig.pullRequestURL(
                owner: summary.repo.owner,
                name: summary.repo.name,
                number: summary.number
            )
        )
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
}
