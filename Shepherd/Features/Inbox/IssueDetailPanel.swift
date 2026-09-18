import AppKit
import Foundation
import ShepherdCore
import SwiftUI

/// The right-hand preview panel while the issues section is showing (ADR 0032).
///
/// ``InboxDetailPanel``'s shape with the pull-request cards taken out: an issue has no checks, no
/// changed files and no diff, so what is left is what the plan names — title, provenance, state
/// and reason, labels, age, the body, and the pull requests that would close it.
///
/// Two things it deliberately does *not* have:
///
/// - **No comments and no timeline.** Out of scope by decision (ADR 0032): the panel shows the
///   body, and there is no `PullRequestDetail.timeline` twin to keep in step with a table nobody
///   asked for. The row's comment *count* is the whole of what the section says about the
///   conversation.
/// - **No review actions.** Approve, request changes and merge are pull-request verbs. The issue
///   *triage* writes are here since ADR 0032's Sprint 4a amendment — comment, label, assign to
///   me, close as completed or not planned, reopen — and every one of them is an ordinary outbox
///   row (ADR 0006): queued locally, sent by the drain, re-validated against the issue's
///   `updatedAt` before it goes out. Nothing in this file calls `GitHubClient`. *Assign to
///   agent…* joined them on 2026-09-04 and is the one action that is not itself a write: it
///   opens the delegation sheet, and the comment recording the handover is queued through the
///   same path as every other one.
struct IssueDetailPanel: View {
    @Environment(AppEnvironment.self) private var environment
    /// The issues model.
    let model: IssueInboxModel

    /// Whether the comment composer is up, and what is in it.
    ///
    /// A sheet rather than a field in the panel, because an issue comment is prose and the panel
    /// is 320 points wide — the same argument the merge sheet makes for not being a button.
    @State private var isCommentSheetPresented = false
    @State private var commentBody = ""

    var body: some View {
        Group {
            if let row = model.selectedRow {
                content(for: row)
            } else {
                EmptyStateView(
                    systemImage: "sidebar.right",
                    title: String(localized: "No issue selected"),
                    message: String(localized: "Pick a row with j / k, or click one.")
                )
            }
        }
        .background(Theme.panel)
        // One per issue actually looked at (ADR 0036), keyed on the row so that re-rendering the
        // same issue does not count again. This is the event that says whether the second inbox
        // citizen is read at all, which is the open question ADR 0032 left.
        .task(id: model.selectedRow?.id) {
            guard model.selectedRow != nil else { return }
            environment.telemetry?.record(.issuesInboxUsed(action: .viewed))
        }
    }

    private func content(for row: IssueRowSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(row)
                    labelsCard(row)
                    descriptionCard
                    linkedPullRequestsCard(row)
                }
                .padding(18)
            }
            Divider().overlay(Theme.border)
            actionBar(row)
        }
        .sheet(isPresented: $isCommentSheetPresented) {
            IssueCommentSheet(row: row, text: $commentBody) { text in
                Task {
                    let queued = await model.comment(text, on: row)
                    report(queued: queued, success: String(localized: "Comment queued."), action: .commented)
                }
            }
        }
    }

    // MARK: - Header

    private func header(_ row: IssueRowSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // The unchanged chip: an issue's author comes from the same `AgentDetector` the
                // pull-request sweep uses, so there is no new detection logic here (ADR 0008).
                ProvenanceChip(actor: row.author)
                Text(String(localized: "opened \(RelativeDate.long(row.createdAt))"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Text(row.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(row.slug)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ChipView(text: stateText(row), color: stateColor(row), size: 10)
                if let reason = stateReasonText(row) {
                    // GitHub's own word, printed rather than translated and never branched on:
                    // `stateReason` is raw and tolerant (ADR 0032), so a vocabulary GitHub grows
                    // costs nothing here.
                    ChipView(text: reason, color: Theme.textSecondary, size: 10)
                }
                ChipView(
                    text: IssueAgeBucket
                        .bucket(createdAt: row.createdAt, now: model.referenceDate)
                        .facetTitle,
                    color: Theme.textMuted,
                    size: 10
                )
                .help(IssueAgeBucket.railHelp)
            }
        }
    }

    private func stateText(_ row: IssueRowSummary) -> String {
        switch row.state {
        case .open: return String(localized: "Open")
        case .closed: return String(localized: "Closed")
        case .unknown: return String(localized: "Unknown state")
        }
    }

    private func stateColor(_ row: IssueRowSummary) -> Color {
        switch row.state {
        case .open: return Theme.success
        case .closed: return Theme.priority
        case .unknown: return Theme.textMuted
        }
    }

    /// GitHub's raw `stateReason`, made readable without being translated.
    ///
    /// `NOT_PLANNED` becomes `not planned`: a mechanical transformation of a server word, which
    /// is why it is not a catalog key. The review vocabulary GitHub keeps in English stays
    /// English (ADR 0022).
    private func stateReasonText(_ row: IssueRowSummary) -> String? {
        guard let reason = row.stateReason?.trimmingCharacters(in: .whitespaces),
              !reason.isEmpty
        else { return nil }
        return reason.replacingOccurrences(of: "_", with: " ").lowercased()
    }

    // MARK: - Cards

    @ViewBuilder
    private func labelsCard(_ row: IssueRowSummary) -> some View {
        if !row.labels.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(String(localized: "LABELS"))
                    // A flow of chips rather than one line: labels are somebody else's words and
                    // there may be a dozen of them.
                    LabelChipFlow(labels: row.labels)
                }
            }
        }
    }

    private var descriptionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "DESCRIPTION"))
                if let body = model.detail?.bodyMarkdown, !body.isEmpty {
                    // The same renderer the pull-request description uses: `AttributedString`,
                    // not the Monaco bridge — an issue has no diff.
                    MarkdownText(markdown: body)
                } else {
                    Text(
                        model.isFetchingBody
                            ? String(localized: "Fetching the body…")
                            : String(localized: "No description.")
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    /// The "Linked pull requests" section.
    ///
    /// Built from ``ShepherdCore/IssueRowSummary/linkedPullRequests`` — what the sweep already
    /// saw, at zero extra GitHub calls. `first: 5` in the sweep's own selection is the honest
    /// ceiling: an issue with a sixth linked pull request shows five, and the facet built on the
    /// same data can therefore only ever understate (ADR 0032).
    ///
    /// **Sprint 3's extension point lives in the row, not here**
    /// (``IssueLinkedPullRequestRow``): the CI dot and the review decision are resolved by a
    /// local join against `pull_requests` and arrive as a view passed into the row's `badge`
    /// slot, in a file of their own. Nothing in this file has to change for them.
    @ViewBuilder
    private func linkedPullRequestsCard(_ row: IssueRowSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(String(localized: "LINKED PULL REQUESTS"))
                if row.linkedPullRequests.isEmpty {
                    Text(String(localized: "No pull request references this issue yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(row.linkedPullRequests.enumerated()), id: \.element.id) { pair in
                        IssueLinkedPullRequestRow(
                            reference: pair.element,
                            localPullRequestID: localPullRequestID(for: pair.element),
                            // The section's one keystroke goes to the first row, which is
                            // GitHub's own order — the sweep stores it as `sortIndex` because it
                            // is stable across fetches.
                            hasKeyboardShortcut: pair.offset == 0,
                            onOpen: open(reference:localPullRequestID:)
                        ) {
                            // The CI dot and the review decision, resolved by a local join
                            // against `pull_requests`; the badge draws nothing when the pull
                            // request is not cached, and this row never reads the database.
                            LinkedPullRequestStatusBadge(
                                reference: pair.element,
                                database: environment.session?.database
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func actionBar(_ row: IssueRowSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            queueStatus(row)
            triageRow(row)
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(
                        AppConfig.issueURL(
                            owner: row.repo.owner,
                            name: row.repo.name,
                            number: row.number
                        )
                    )
                } label: {
                    Text(String(localized: "Open on GitHub"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.slug, forType: .string)
                    environment.toasts.info(String(localized: "Copied \(row.slug)"))
                } label: {
                    Text(String(localized: "Copy reference"))
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .background(Theme.panel)
    }

    /// The triage writes, in the order a triage pass performs them.
    ///
    /// No keyboard shortcuts. `r a`, `m` and `x` are pull-request verbs and the issues section
    /// refuses them (ADR 0032's Sprint 2 amendment); giving the issue writes global keys of their
    /// own would be a second verb vocabulary, which is a decision nobody has made.
    private func triageRow(_ row: IssueRowSummary) -> some View {
        // Two rows rather than one: five controls do not fit on one line at the panel's 320 pt
        // width without clipping their labels. Split by kind — the writes you make *about* the
        // issue (comment, assign) on top, the writes that change its *state* (label,
        // close/reopen) below.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    commentBody = ""
                    isCommentSheetPresented = true
                } label: {
                    Text(String(localized: "Comment…"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .modifier(issueWrite(row, .issueComment))

                if let login = model.viewerLogin, !login.isEmpty {
                    Button {
                        Task {
                            let queued = await model.assignToMe(row)
                            report(
                                queued: queued,
                                success: String(localized: "Assignment queued."),
                                action: .assigned
                            )
                        }
                    } label: {
                        Text(String(localized: "Assign to me"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .modifier(issueWrite(
                        row,
                        .issueAssign,
                        alsoDisabledWhen: row.myRelation.contains(.assigned)
                    ))
                    .help(
                        row.myRelation.contains(.assigned)
                            ? String(localized: "This issue is already assigned to you")
                            : String(localized: "Add yourself as an assignee, without removing anyone")
                    )
                }

                assignToAgentButton(row)

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                labelMenu(row)

                stateMenu(row)

                Spacer(minLength: 0)
            }
        }
    }

    /// Hands the issue to the configured assistant (ADR 0032's 2026-09-04 amendment).
    ///
    /// The sheet that opens is the one a pull-request delegation opens, with the task text
    /// prefilled from the issue — title, labels and the body when the panel has read it — and the
    /// reviewer still presses Run. What the run may do with the result is decided by the preamble
    /// the origin selects, not here.
    ///
    /// The handover is also recorded **on GitHub**, as an ordinary queued comment, so a colleague
    /// looking at the issue can see that somebody is on it. It is queued when the run actually
    /// starts rather than on this click: a comment saying an assistant is working on the issue is
    /// a claim, and the click is too early to make it — a missing checkout or a branch git
    /// refuses would leave the claim standing with nothing behind it.
    @ViewBuilder
    private func assignToAgentButton(_ row: IssueRowSummary) -> some View {
        Button {
            environment.startIssueDelegation(
                row,
                body: model.detail?.bodyMarkdown ?? "",
                onDidStart: { start in
                    Task {
                        // The one write in this panel nobody pressed a button for, and the one
                        // that used to be thrown away: a handover comment the outbox refused left
                        // the issue looking untouched to every colleague reading it, with nothing
                        // anywhere saying so. Same sentence as every other refused issue write.
                        let queued = await model.comment(
                            String(
                                localized: "Handed to \(start.agent) via Shepherd, on branch `\(GitWorktree.branchName(issueNumber: row.number))`."
                            ),
                            on: row
                        )
                        if !queued { reportQueueFailure() }
                    }
                }
            )
        } label: {
            Text(String(localized: "Assign to agent…"))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        // ``ActionActivity/Kind/issueComment``, because that is what this button eventually
        // writes: the handover is recorded as a comment when the run starts.
        .modifier(issueWrite(row, .issueComment, alsoDisabledWhen: row.state == .closed))
        .help(
            row.state == .closed
                ? String(localized: "This issue is closed")
                : String(
                    localized: "Open a delegation sheet with this issue as the task. Shepherd creates a worktree on its own branch and runs the assistant you configured; the handover is queued as a comment on the issue."
                )
        )
    }

    /// The label picker, fed by the labels the section has already seen.
    @ViewBuilder
    private func labelMenu(_ row: IssueRowSummary) -> some View {
        let candidates = model.availableLabels(for: row)
        Menu {
            if candidates.isEmpty {
                Text(String(localized: "No other label in this repository yet"))
            } else {
                ForEach(candidates, id: \.self) { label in
                    Button(label) {
                        Task {
                            let queued = await model.addLabel(label, on: row)
                            report(
                                queued: queued,
                                success: String(localized: "Label queued."),
                                action: .labeled
                            )
                        }
                    }
                }
            }
        } label: {
            Text(String(localized: "Label"))
                .frame(maxWidth: .infinity)
        }
        // `.button` — styled through ``SecondaryButtonStyle`` like every neighbouring control,
        // which is also what lets ``View/busy(_:)`` reach this menu. The borderless menu style
        // this used to have draws its own label and never runs it through a `ButtonStyle` at all.
        .menuStyle(.button)
        .buttonStyle(SecondaryButtonStyle())
        .modifier(issueWrite(row, .issueLabel))
        .help(
            String(
                localized: "The labels Shepherd has already seen in this repository. A label nothing here carries is a click away on GitHub."
            )
        )
    }

    /// Close (with a reason) or reopen — whichever the issue's state allows.
    @ViewBuilder
    private func stateMenu(_ row: IssueRowSummary) -> some View {
        if row.state == .closed {
            Button {
                Task {
                    let queued = await model.reopen(row)
                    report(queued: queued, success: String(localized: "Reopen queued."))
                }
            } label: {
                Text(String(localized: "Reopen"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .modifier(issueWrite(row, .issueState))
        } else {
            Menu {
                Button(String(localized: "Close as completed")) {
                    Task {
                        let queued = await model.close(.completed, on: row)
                        report(queued: queued, success: String(localized: "Close queued."), action: .closed)
                    }
                }
                Button(String(localized: "Close as not planned")) {
                    Task {
                        let queued = await model.close(.notPlanned, on: row)
                        report(queued: queued, success: String(localized: "Close queued."), action: .closed)
                    }
                }
            } label: {
                Text(String(localized: "Close"))
                    .frame(maxWidth: .infinity)
            }
            // Same reason as ``labelMenu(_:)``: `.button` runs the label through
            // ``SecondaryButtonStyle``, which is what lets ``View/busy(_:)`` show a spinner here
            // instead of the inline opacity/overlay trick a borderless menu needed.
            .menuStyle(.button)
            .buttonStyle(SecondaryButtonStyle())
            .modifier(issueWrite(row, .issueState))
        }
    }

    /// What the outbox is holding for this issue.
    ///
    /// This panel said all three states first, and ``InboxDetailPanel/queueStatus(_:)`` is the
    /// same line on the pull-request side since (ADR 0006's 2026-09-04 amendment).
    ///
    /// The third of them is not a theoretical state here: an issue row is failed non-retriably
    /// whenever the engine was built without an `IssueWriting` port, and GitHub's own 4xx answers
    /// end the same way; a row in it is neither waiting nor parked, so without this line the click
    /// simply looked as though it had worked.
    private func queueStatus(_ row: IssueRowSummary) -> some View {
        QueueStatusLine(
            queued: model.queuedWriteCount(for: row),
            parked: model.parkedWriteCount(for: row),
            failed: model.failedWriteCount(for: row),
            target: .issue
        )
    }

    /// One toast per queued write, which is the confirmation of the click.
    private func report(queued: Bool, success: String, action: IssuesAction? = nil) {
        if queued {
            environment.toasts.success(success)
            // Counted here rather than at the button, because here is where the write is known to
            // have reached the outbox — an event recorded on the click would measure clicking
            // (ADR 0036). `nil` for reopening: the allow-list has no case for it, and inventing
            // one to avoid a gap would widen the payload past what ADR 0036 decided.
            if let action {
                environment.telemetry?.record(.issuesInboxUsed(action: action))
            }
        } else {
            reportQueueFailure()
        }
    }

    /// The sentence every refused issue write says.
    ///
    /// Its own method because one of them has no success half to pair with: the handover comment
    /// is queued by the delegation starting rather than by a click, so there is nothing to
    /// confirm — only something to say when it did not happen.
    private func reportQueueFailure() {
        environment.toasts.show(
            Toast(
                message: String(localized: "Could not queue that — nothing was sent."),
                kind: .failure
            )
        )
    }

    /// The four verbs this panel can write, which is what the row's buttons go quiet on
    /// together.
    private static let issueWrites: [ActionActivity.Kind] = [
        .issueComment, .issueAssign, .issueLabel, .issueState,
    ]

    /// Whether *this verb* is on its way to the outbox for this issue — the spinner's question.
    /// - Parameters:
    ///   - row: The issue.
    ///   - kind: Which verb.
    /// - Returns: `true` while that write runs.
    private func isWriting(_ row: IssueRowSummary, _ kind: ActionActivity.Kind) -> Bool {
        environment.activity.isRunning(row.id, kind)
    }

    /// Whether *any* of the four is on its way — the disable's question.
    ///
    /// Only the button that started the write spins, so the reviewer can see which one they
    /// pressed; all six stop answering, because an issue write is re-validated against the
    /// `updatedAt` the write in flight is about to move (ADR 0032).
    /// - Parameter row: The issue.
    /// - Returns: `true` while any triage write runs.
    private func isWritingAnything(_ row: IssueRowSummary) -> Bool {
        environment.activity.isRunningAny(row.id, Self.issueWrites)
    }

    /// What every triage button on this panel wears: its own spinner, and the whole row's writes
    /// locking each other out.
    ///
    /// The pair was written by hand six times, and the pair is the rule — one button spins so the
    /// reviewer can see which one they pressed, all six go quiet because the write in flight is
    /// about to move the `updatedAt` the others would be re-validated against. Two lines that
    /// have to stay together are better as one call than as six chances to keep only the first.
    /// - Parameters:
    ///   - row: The issue the button acts on.
    ///   - kind: Which verb this button writes, so only its own spinner turns.
    ///   - extra: A further reason this button is dark — already assigned, already closed. It is
    ///     ORed with the row's writes, never instead of them.
    /// - Returns: The modifier to apply to the button.
    private func issueWrite(
        _ row: IssueRowSummary,
        _ kind: ActionActivity.Kind,
        alsoDisabledWhen extra: Bool = false
    ) -> IssueWriteModifier {
        IssueWriteModifier(
            isBusy: isWriting(row, kind),
            isDisabled: extra || isWritingAnything(row)
        )
    }

    /// The node id of a linked pull request that is in the local inbox, or `nil`.
    ///
    /// Read off the session's own inbox rows — the same in-memory source the menu-bar quick inbox
    /// uses — rather than with a query of its own: they are already there, and the comparison is
    /// ``AppEnvironment/pullRequestID(repo:number:in:)``, so "is this pull request one of mine"
    /// has one implementation.
    private func localPullRequestID(for reference: LinkedPullRequestReference) -> String? {
        guard let rows = environment.session?.inboxRows else { return nil }
        return AppEnvironment.pullRequestID(
            repo: reference.repo,
            number: reference.number,
            in: rows
        )
    }

    private func open(reference: LinkedPullRequestReference, localPullRequestID: String?) {
        if let localPullRequestID {
            environment.openReview(prID: localPullRequestID)
            return
        }
        NSWorkspace.shared.open(
            AppConfig.pullRequestURL(
                owner: reference.repo.owner,
                name: reference.repo.name,
                number: reference.number
            )
        )
    }
}

/// ``IssueDetailPanel/issueWrite(_:_:alsoDisabledWhen:)``'s two modifiers, as one.
///
/// A ``ViewModifier`` rather than a `View` extension because the two values it needs come off the
/// panel — the activity tracker it reads lives in the environment — and a `View` extension cannot
/// ask the panel anything.
private struct IssueWriteModifier: ViewModifier {
    /// Whether *this* button's own write is in flight.
    let isBusy: Bool
    /// Whether this button is dark: any of the row's writes, plus the caller's own reason.
    let isDisabled: Bool

    func body(content: Content) -> some View {
        content
            .busy(isBusy)
            .disabled(isDisabled)
    }
}

/// A wrapping row of label chips.
///
/// Its own small view because `Layout`-free wrapping in SwiftUI needs a container that measures,
/// and because the issue panel is the only place in the app that draws an unbounded number of
/// somebody else's words side by side.
struct LabelChipFlow: View {
    /// The label names, in GitHub's order.
    let labels: [String]

    var body: some View {
        // `ViewThatFits` would pick one of a fixed set of layouts; a flexible grid wraps at
        // whatever width the panel has, which is what an unbounded label list needs.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 70, maximum: 200), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(labels, id: \.self) { label in
                ChipView(text: label, color: Theme.textSecondary, size: 10)
            }
        }
    }
}
