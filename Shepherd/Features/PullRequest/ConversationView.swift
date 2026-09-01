import ShepherdCore
import SwiftUI

/// The review screen's second tab: description, commits, checks and unanchored threads.
struct ConversationView: View {
    @Environment(AppEnvironment.self) private var environment
    /// The review model.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
    }

    @ViewBuilder
    private var description: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "DESCRIPTION"))
                if let body = model.detail?.bodyMarkdown, !body.isEmpty {
                    MarkdownText(markdown: body)
                } else {
                    Text(String(localized: "No description."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

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
        let list = model.detail?.checks ?? []
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
                        }
                    }
                }
            }
        }
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
                                ThreadCommentView(comment: comment)
                            }
                            if let summary = model.summary {
                                HStack(spacing: 8) {
                                    Button(
                                        thread.isResolved
                                            ? String(localized: "Unresolve")
                                            : String(localized: "Resolve")
                                    ) {
                                        Task {
                                            await actions.setThread(
                                                on: summary,
                                                threadID: thread.id,
                                                resolved: !thread.isResolved
                                            )
                                        }
                                    }
                                    .buttonStyle(SecondaryButtonStyle(height: 26))

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
