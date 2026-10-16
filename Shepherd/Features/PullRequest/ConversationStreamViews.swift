import AppKit
import ShepherdCore
import SwiftUI

// The conversation tab's stream (ADR 0043) and its rows, one view per kind of entry. They draw what
// the model already holds and fetch nothing; the only writes are the thread reply bar's, through
// `PullRequestActions`.

/// Every entry after the description, in GitHub's order.
///
/// A view of its own, compared by what it draws, so it is re-diffed when the entries change and at
/// no other time: the tab around it is re-evaluated for the claims card, for *Quote reply*'s focus
/// request and for every inbox emission the stack card reads, and each of those used to walk every
/// post and thread of a long conversation again. The model, the actions and the translation cache
/// are what the rows act through rather than what they show, so they stay out of the comparison.
///
/// A plain `VStack`, not a lazy one: a lazy container may drop a thread card's `@State` — a reply
/// half written, a fold the reviewer flipped — once the card scrolls away. Every entry keeps its
/// stable ``ShepherdCore/ConversationEntry/id`` for the same reason.
struct ConversationStream: View, Equatable {
    /// The entries, oldest first.
    let entries: [ConversationEntry]
    /// The pull request, for the threads' writes.
    let summary: PullRequestSummary
    /// The review model, for *Quote reply* and *Show in diff*.
    let model: ReviewModel
    /// The write actions, for the threads' reply bars.
    let actions: PullRequestActions
    /// The tab's translation cache.
    let translations: TranslationCoordinator

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.summary.id == rhs.summary.id && lhs.entries == rhs.entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(entries) { entry in
                self.entry(entry)
            }
        }
    }

    /// One entry of the stream.
    @ViewBuilder
    private func entry(_ entry: ConversationEntry) -> some View {
        switch entry {
        case .comment(let comment):
            ConversationPostView(
                model: model,
                translations: translations,
                author: comment.author,
                verb: String(localized: "commented"),
                date: comment.createdAt,
                markdown: comment.bodyMarkdown,
                isEdited: comment.isEdited,
                reactions: comment.reactions,
                url: comment.url,
                isMinimized: comment.isMinimized,
                minimizedReason: comment.minimizedReason
            )
        case .review(let review, let threads):
            ConversationReviewView(
                model: model,
                actions: actions,
                summary: summary,
                translations: translations,
                review: review,
                threads: threads
            )
        case .thread(let thread):
            ConversationThreadView(
                model: model,
                actions: actions,
                summary: summary,
                translations: translations,
                thread: thread
            )
        case .commits(let commits):
            ConversationCommitsView(commits: commits)
        case .event(let event):
            ConversationEventRow(item: event)
        }
    }
}

/// One post of the conversation, header and all: the description or a comment.
///
/// One view for both, so the two cannot drift into two looks. The words a reviewer wrote above a
/// verdict are the same ``PostBody`` in a card of the review's own, under the review's row.
struct ConversationPostView: View {
    /// The review model, for *Quote reply*.
    let model: ReviewModel
    /// The tab's translation cache.
    let translations: TranslationCoordinator
    /// Who wrote it.
    let author: ShepherdCore.Actor
    /// What they did, after their name: "opened this pull request", "commented".
    let verb: String
    /// When.
    let date: Date
    /// The post as Markdown source. Empty only for a description nobody wrote: GitHub refuses an
    /// empty comment.
    let markdown: String
    /// Whether it was edited after it was posted.
    var isEdited = false
    /// The reactions anybody left on it.
    var reactions: [ReactionGroup] = []
    /// The post on github.com.
    var url: URL?
    /// Whether a maintainer hid it (off-topic, outdated, spam …).
    var isMinimized = false
    /// GitHub's word for why it is hidden, or `nil` when it gave none.
    var minimizedReason: String?

    /// Whether the reviewer asked to see a hidden post anyway.
    @State private var isRevealed = false

    var body: some View {
        if isMinimized && !isRevealed {
            StreamNoticeRow(
                symbol: "eye.slash",
                text: Self.hiddenSentence(reason: minimizedReason),
                buttonTitle: String(localized: "Show")
            ) { isRevealed = true }
        } else {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    PostHeader(
                        model: model,
                        author: author,
                        verb: verb,
                        date: date,
                        isEdited: isEdited,
                        markdown: markdown,
                        url: url
                    )
                    PostBody(markdown: markdown, reactions: reactions, translations: translations)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: PostHeader.spokenLabel(author: author, verb: verb, date: date)))
        }
    }

    /// "Hidden — off-topic", in GitHub's word for why; "Hidden comment" for a reason this build
    /// does not know, or for none.
    /// - Parameter reason: ``ShepherdCore/ConversationComment/minimizedReason``.
    /// - Returns: The line.
    static func hiddenSentence(reason: String?) -> String {
        let why: String
        switch reason {
        case "off-topic": why = String(localized: "off-topic")
        case "outdated": why = String(localized: "outdated")
        case "resolved": why = String(localized: "resolved")
        case "duplicate": why = String(localized: "duplicate")
        case "spam": why = String(localized: "spam")
        case "abuse": why = String(localized: "abuse")
        default: return String(localized: "Hidden comment")
        }
        return String(localized: "Hidden — \(why)")
    }
}

/// What a post says — the description, a comment, or a reviewer's words above the verdict — and
/// the reactions under it. The card around it is the caller's.
struct PostBody: View {
    /// The post as Markdown source; empty only for a description nobody wrote.
    let markdown: String
    /// The reactions anybody left on it.
    let reactions: [ReactionGroup]
    /// The tab's translation cache.
    let translations: TranslationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if markdown.isEmpty {
                Text(String(localized: "No description."))
                    .font(Theme.type(.callout))
                    .foregroundStyle(Theme.textMuted)
            } else {
                TranslatableMarkdownText(markdown: markdown, translations: translations)
            }
            if !reactions.isEmpty {
                ReactionSummaryView(reactions: reactions)
            }
        }
    }
}

/// A one-line notice in the stream where a post would be — a hidden comment, the earlier activity
/// that is only on GitHub — with the one button that does something about it.
struct StreamNoticeRow: View {
    /// The SF Symbol in front.
    let symbol: String
    /// The line.
    let text: String
    /// The button's title.
    let buttonTitle: String
    /// What the button does.
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 4)
            Button(buttonTitle, action: action)
                .buttonStyle(SecondaryButtonStyle(height: 22))
        }
        .padding(.horizontal, 12)
    }
}

/// Who wrote a post, what they did and when, and the post's menu — *Quote reply*, *Copy link*,
/// *Open on GitHub*. Above a post's body, and as a review's own row.
private struct PostHeader: View {
    /// The review model, for *Quote reply*.
    let model: ReviewModel
    /// Who.
    let author: ShepherdCore.Actor
    /// What, after the name.
    let verb: String
    /// The verdict's symbol in front of the verb, for a review; `nil` for a post.
    var symbol: String?
    /// The verb's colour: muted for a post, the verdict's own for a review.
    var tint = Theme.textMuted
    /// When.
    let date: Date
    /// Whether the post was edited after it was posted.
    var isEdited = false
    /// What *Quote reply* quotes; empty leaves the item out.
    var markdown = ""
    /// The post on github.com, for the other two items.
    var url: URL?

    var body: some View {
        HStack(spacing: 8) {
            AuthorLine(author: author, verb: verb, symbol: symbol, tint: tint, date: date, isEdited: isEdited)
            Spacer(minLength: 4)
            if !markdown.isEmpty || url != nil {
                menu
            }
        }
    }

    private var menu: some View {
        Menu {
            if !markdown.isEmpty {
                Button(String(localized: "Quote reply")) { model.quote(markdown) }
            }
            if let url {
                Button(String(localized: "Copy link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Button(String(localized: "Open on GitHub")) { NSWorkspace.shared.open(url) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "More actions"))
        .accessibilityLabel(String(localized: "More actions"))
    }

    /// What a post — or a review — is announced as: who, what, when.
    static func spokenLabel(author: ShepherdCore.Actor, verb: String, date: Date) -> String {
        SpokenRow.sentence([author.bestName, verb, RelativeDate.long(date)])
    }
}

/// Who wrote something and when — the avatar, the name, the agent chip, how long ago, and
/// "· edited" — with what they did between the name and the time, as GitHub writes it.
///
/// The line above a post, a review and a thread comment, in the stream and in the diff's popover,
/// so the three cannot drift into three looks.
struct AuthorLine: View {
    /// Who.
    let author: ShepherdCore.Actor
    /// What they did, after the name — "commented", "approved these changes" — or `nil` for a
    /// thread comment, which says only who and when.
    var verb: String?
    /// The verdict's symbol in front of the verb, for a review.
    var symbol: String?
    /// The verb's colour: muted for a post, the verdict's own for a review.
    var tint = Theme.textMuted
    /// When.
    let date: Date
    /// Whether it was edited after it was posted.
    var isEdited = false

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(actor: author, size: 24)
            Text(author.bestName)
                .font(Theme.type(.callout, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
                .lineLimit(1)
            if let identity = author.kind.agentIdentity {
                ChipView(text: identity.displayName, color: Theme.agent, size: 10)
            }
            if let verb {
                HStack(spacing: 4) {
                    if let symbol {
                        Image(systemName: symbol)
                            .accessibilityHidden(true)
                    }
                    Text(verb)
                }
                .font(Theme.type(.callout))
                .foregroundStyle(tint)
            }
            HStack(spacing: 4) {
                RelativeDateText(date: date, style: .long)
                if isEdited {
                    Text(verbatim: "· " + String(localized: "edited"))
                }
            }
            .font(Theme.type(.subheadline))
            .foregroundStyle(Theme.textMuted)
        }
    }
}

/// The reactions under a post, the way GitHub draws them: one capsule per emoji with its count,
/// filled when one of them is yours. Read-only until phase B adds the buttons (ADR 0043).
struct ReactionSummaryView: View {
    /// The groups somebody used.
    let reactions: [ReactionGroup]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(reactions, id: \.content) { group in
                Text(verbatim: "\(group.content.emoji) \(group.count)")
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        group.viewerHasReacted ? Theme.chipBackground(Theme.accentText) : Theme.control,
                        in: Capsule(style: .continuous)
                    )
                    .overlay(Capsule(style: .continuous).stroke(Theme.border, lineWidth: 1))
                    .accessibilityLabel(Text(verbatim: Self.spokenLabel(for: group)))
            }
        }
    }

    /// One capsule in words — "Thumbs up. 2 reactions. including yours." — because the fill is
    /// what marks your own, and colour is never the only carrier.
    static func spokenLabel(for group: ReactionGroup) -> String {
        let count = group.count
        return SpokenRow.sentence([
            Self.name(of: group.content),
            String(localized: "\(count) reactions"),
            group.viewerHasReacted ? String(localized: "including yours") : nil,
        ])
    }

    /// GitHub's name for a reaction. The emoji alone would be read out by its Unicode name.
    static func name(of content: ReactionContent) -> String {
        switch content {
        case .thumbsUp: return String(localized: "Thumbs up")
        case .thumbsDown: return String(localized: "Thumbs down")
        case .laugh: return String(localized: "Laugh")
        case .hooray: return String(localized: "Hooray")
        case .confused: return String(localized: "Confused")
        case .heart: return String(localized: "Heart")
        case .rocket: return String(localized: "Rocket")
        case .eyes: return String(localized: "Eyes")
        }
    }
}

/// A review in the stream: who gave which verdict and when, the words above it, and the threads
/// its comments started, indented under it as GitHub draws them.
struct ConversationReviewView: View {
    /// The review model.
    let model: ReviewModel
    /// The write actions, for the threads' reply bars.
    let actions: PullRequestActions
    /// The pull request.
    let summary: PullRequestSummary
    /// The tab's translation cache.
    let translations: TranslationCoordinator
    /// The review.
    let review: ConversationReview
    /// The threads its comments started, in GitHub's order.
    let threads: [ReviewThread]

    var body: some View {
        let verdict = Self.verdict(review.state)
        VStack(alignment: .leading, spacing: 8) {
            PostHeader(
                model: model,
                author: review.author,
                verb: verdict.sentence,
                symbol: verdict.symbol,
                tint: verdict.tint,
                date: review.createdAt,
                isEdited: review.isEdited,
                markdown: review.hasBody ? review.bodyMarkdown : "",
                url: review.url
            )
            .padding(.horizontal, 12)
            // The words under the review's own row, which already says who and when and carries
            // the menu — so no header here, and no spoken label of the card's own either.
            if review.hasBody {
                Card {
                    PostBody(markdown: review.bodyMarkdown, reactions: review.reactions, translations: translations)
                }
            }
            ForEach(threads) { thread in
                ConversationThreadView(
                    model: model,
                    actions: actions,
                    summary: summary,
                    translations: translations,
                    thread: thread
                )
                .padding(.leading, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: PostHeader.spokenLabel(
            author: review.author,
            verb: verdict.sentence,
            date: review.createdAt
        )))
    }

    /// The verdict as the review's row says it, with its symbol and colour. The words carry it;
    /// the colour only repeats them.
    /// - Parameter state: The review's state.
    /// - Returns: The sentence after the name, an SF Symbol and its tint.
    static func verdict(_ state: ConversationReview.State) -> (sentence: String, symbol: String, tint: Color) {
        switch state {
        case .approved:
            return (String(localized: "approved these changes"), "checkmark.circle.fill", Theme.success)
        case .changesRequested:
            return (String(localized: "requested changes"), "exclamationmark.circle.fill", Theme.failure)
        case .commented:
            return (String(localized: "reviewed"), "eye", Theme.accentText)
        case .dismissed:
            return (String(localized: "reviewed — dismissed"), "eye.slash", Theme.textMuted)
        case .pending:
            return (String(localized: "has a pending review"), "clock", Theme.pending)
        }
    }
}

/// A review thread in the stream — under the review that started it, or on its own when that
/// review is not in the timeline. Resolved and outdated threads start collapsed, as on GitHub, and
/// the reply bar is the diff popover's own (``ThreadReplyBar``).
struct ConversationThreadView: View {
    /// The review model, for *Show in diff*.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions
    /// The pull request.
    let summary: PullRequestSummary
    /// The tab's translation cache.
    let translations: TranslationCoordinator
    /// The thread.
    let thread: ReviewThread

    /// Whether the reviewer flipped the thread away from how it starts. A flip rather than an
    /// "is expanded" flag, so a thread resolved from its own reply bar folds away by itself.
    @State private var isFlipped = false
    /// What is typed in the reply bar. Held here, on the card that stays on screen, rather than in
    /// the bar: folding the thread away — by hand, or because it was just resolved — removes the
    /// bar, and must not take a half-written reply with it.
    @State private var replyText = ""

    private var isExpanded: Bool {
        Self.isExpanded(thread, isFlipped: isFlipped)
    }

    /// Whether a thread shows its comments and its reply bar: an open one does until the reviewer
    /// folds it, a resolved or outdated one only once they unfold it — so a thread resolved from
    /// its own bar folds by itself.
    /// - Parameters:
    ///   - thread: The thread.
    ///   - isFlipped: Whether the reviewer flipped it away from how it starts.
    /// - Returns: `true` when the thread is drawn open.
    static func isExpanded(_ thread: ReviewThread, isFlipped: Bool) -> Bool {
        isFlipped == (thread.isResolved || thread.isOutdated)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header
                if isExpanded {
                    ForEach(thread.comments) { comment in
                        ThreadCommentView(comment: comment, translations: translations)
                    }
                    ThreadReplyBar(thread: thread, summary: summary, actions: actions, replyText: $replyText)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: spokenLabel))
    }

    /// The thread as the screen reader names it — where it is, and whether it is settled — so a
    /// folded thread is more than a "Show" button among others (ADR 0033).
    private var spokenLabel: String {
        SpokenRow.sentence([
            thread.path ?? String(localized: "Pull request conversation"),
            anchor,
            thread.isOutdated ? String(localized: "outdated") : nil,
            thread.isResolved ? String(localized: "resolved") : nil,
        ])
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                isFlipped.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.type(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(chevronLabel)
            .accessibilityLabel(chevronLabel)
            Image(systemName: "doc.text")
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            Text(thread.path ?? String(localized: "Pull request conversation"))
                .font(Theme.mono(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            if let anchor {
                Text(anchor)
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.textMuted)
            }
            if thread.isOutdated {
                ChipView(text: String(localized: "outdated"), color: Theme.pending, size: 10)
            }
            if thread.isResolved {
                ChipView(text: String(localized: "resolved"), color: Theme.success, size: 10)
            }
            Spacer(minLength: 4)
            if thread.isAnchoredInCurrentDiff, let path = thread.path {
                Button(String(localized: "Show in diff")) {
                    model.reveal(path: path, line: thread.line)
                }
                .buttonStyle(SecondaryButtonStyle(height: 22))
            }
        }
    }

    /// What the chevron does, in words: it shows or hides the comments and the reply bar.
    private var chevronLabel: String {
        isExpanded ? String(localized: "Hide conversation") : String(localized: "Show conversation")
    }

    /// Where the thread points, in words, for the header and the spoken label alike: its line on
    /// the current diff, or — once the diff has moved on — the line it was written against, which
    /// is shown and never used to position anything. `nil` for a thread on no line.
    private var anchor: String? {
        if let line = thread.line, !thread.isOutdated {
            return String(localized: "line \(line)")
        }
        if let original = thread.originalLine {
            return String(localized: "was line \(original)")
        }
        return nil
    }
}

/// Commits pushed with nothing else between them: a compact group rather than a card, because a
/// run of commits is not something somebody wrote to the reviewer.
struct ConversationCommitsView: View {
    /// The commits, oldest first. Never empty.
    let commits: [CommitInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(Theme.type(.footnote))
                    .imageScale(.small)
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(Self.title(for: commits))
                    .font(Theme.type(.callout))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(commits) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: commit.shortOid)
                        .font(Theme.mono(.subheadline))
                        .foregroundStyle(Theme.accentText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.messageHeadline)
                            .font(Theme.type(.callout))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                        if !commit.trailers.isEmpty {
                            Text(commit.trailers.joined(separator: " · "))
                                .font(Theme.mono(.footnote))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    RelativeDateText(date: commit.committedDate)
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.textMuted)
                }
                // Under the heading's text, past the dot.
                .padding(.leading, 22)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 12)
    }

    /// "Claude Code added 3 commits" when one author pushed them all, "3 commits" otherwise.
    /// - Parameter commits: The group.
    /// - Returns: The heading.
    static func title(for commits: [CommitInfo]) -> String {
        let count = commits.count
        if Set(commits.map(\.author?.login)).count == 1, let name = commits.first?.author?.bestName {
            return String(localized: "\(name) added \(count) commits")
        }
        return String(localized: "\(count) commits")
    }
}

/// Something that happened between the posts — a label, a force-push, a merge — in one line.
///
/// A mention from another pull request or issue is a button that opens it; everything else is
/// read, not clicked.
struct ConversationEventRow: View {
    /// The event.
    let item: ConversationEventItem

    var body: some View {
        if case .crossReferenced(let reference, _) = item.event, let url = reference.url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                row
            }
            .buttonStyle(RowButtonStyle())
            .help(String(localized: "Open on GitHub"))
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ConversationEventText.symbol(for: item.event))
                .font(Theme.type(.subheadline))
                .foregroundStyle(ConversationEventText.tint(for: item.event))
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(ConversationEventText.sentence(for: item))
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            RelativeDateText(date: item.createdAt)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
