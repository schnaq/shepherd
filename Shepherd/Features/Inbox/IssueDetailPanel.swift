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
/// - **No review actions.** Approve, request changes and merge are pull-request verbs; the issue
///   writes (label, assign, close, comment) are a later sprint's outbox actions, and a button
///   here that queued nothing would be worse than no button.
struct IssueDetailPanel: View {
    @Environment(AppEnvironment.self) private var environment
    /// The issues model.
    let model: IssueInboxModel

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
                        )
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func actionBar(_ row: IssueRowSummary) -> some View {
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
        .padding(16)
        .background(Theme.panel)
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
