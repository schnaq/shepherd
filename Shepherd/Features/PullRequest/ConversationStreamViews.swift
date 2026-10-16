import AppKit
import ShepherdCore
import SwiftUI

// The rows of the conversation tab's stream (ADR 0043), one view per kind of entry. They draw what
// the model already holds and fetch nothing; the only writes are the thread reply bar's, through
// `PullRequestActions`.

/// One post of the conversation: the description, a comment, or the words above a review.
///
/// One view for all three, so the description and a comment cannot drift into two looks. Under a
/// review the header is left out — the review's own row already says who and when, and carries
/// the menu — and so is the spoken label that header would give the card.
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
    /// empty comment, and a review without words draws no post.
    let markdown: String
    /// Whether it was edited after it was posted.
    var isEdited = false
    /// The reactions anybody left on it.
    var reactions: [ReactionGroup] = []
    /// The post on github.com.
    var url: URL?
    /// Whether to draw who, what and when above the body.
    var showsHeader = true
    /// Whether a maintainer hid it (off-topic, outdated, spam …).
    var isMinimized = false
    /// GitHub's word for why it is hidden, or `nil` when it gave none.
    var minimizedReason: String?

    /// Whether the reviewer asked to see a hidden post anyway.
    @State private var isRevealed = false

    var body: some View {
        if isMinimized && !isRevealed {
            hiddenRow
        } else if showsHeader {
            card
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(verbatim: PostHeader.spokenLabel(author: author, verb: verb, date: date)))
        } else {
            card
        }
    }

    private var card: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                if showsHeader {
                    PostHeader(
                        model: model,
                        author: author,
                        verb: verb,
                        date: date,
                        isEdited: isEdited,
                        markdown: markdown,
                        url: url
                    )
                }
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

    /// A hidden comment: one line saying why, and the button that shows it anyway.
    private var hiddenRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(Self.hiddenSentence(reason: minimizedReason))
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 4)
            Button(String(localized: "Show")) { isRevealed = true }
                .buttonStyle(SecondaryButtonStyle(height: 22))
        }
        .padding(.horizontal, 12)
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
            AvatarView(actor: author, size: 24)
            Text(author.bestName)
                .font(Theme.type(.callout, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
                .lineLimit(1)
            if let identity = author.kind.agentIdentity {
                ChipView(text: identity.displayName, color: Theme.agent, size: 10)
            }
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .accessibilityHidden(true)
                }
                Text(verb)
            }
            .font(Theme.type(.callout))
            .foregroundStyle(tint)
            RelativeDateText(date: date, style: .long)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
            if isEdited {
                Text(verbatim: "· " + String(localized: "edited"))
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.textMuted)
            }
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

    /// What a post — or a review — is announced as: "<name>, <verb>, <when>".
    static func spokenLabel(author: ShepherdCore.Actor, verb: String, date: Date) -> String {
        "\(author.bestName), \(verb), \(RelativeDate.long(date))"
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

    /// One capsule in words — "Thumbs up, 2 reactions, including yours" — because the fill is
    /// what marks your own, and colour is never the only carrier.
    static func spokenLabel(for group: ReactionGroup) -> String {
        let reaction = Self.name(of: group.content)
        let count = group.count
        let total = String(localized: "\(count) reactions")
        let yours = group.viewerHasReacted ? String(localized: ", including yours") : ""
        return "\(reaction), \(total)\(yours)"
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
        let hasBody = !review.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            PostHeader(
                model: model,
                author: review.author,
                verb: verdict.sentence,
                symbol: verdict.symbol,
                tint: verdict.tint,
                date: review.createdAt,
                isEdited: review.isEdited,
                markdown: hasBody ? review.bodyMarkdown : "",
                url: review.url
            )
            .padding(.horizontal, 12)
            if hasBody {
                ConversationPostView(
                    model: model,
                    translations: translations,
                    author: review.author,
                    verb: verdict.sentence,
                    date: review.createdAt,
                    markdown: review.bodyMarkdown,
                    reactions: review.reactions,
                    showsHeader: false
                )
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
    /// The review model, for *Show in diff* and the re-read after a write.
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

    private var isExpanded: Bool {
        isFlipped != (thread.isResolved || thread.isOutdated)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header
                if isExpanded {
                    ForEach(thread.comments) { comment in
                        ThreadCommentView(comment: comment, translations: translations)
                    }
                    ThreadReplyBar(thread: thread, summary: summary, actions: actions) { outcome in
                        // A write that reached GitHub is read back at once, so it shows without
                        // waiting for the next sweep. A queued one is the toast's news: a re-read
                        // then would only put a failure banner over the tab.
                        if case .sent? = outcome { model.load() }
                    }
                }
            }
        }
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
            .help(isExpanded ? String(localized: "Hide") : String(localized: "Show"))
            .accessibilityLabel(isExpanded ? String(localized: "Hide") : String(localized: "Show"))
            Image(systemName: "doc.text")
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            Text(thread.path ?? String(localized: "Pull request conversation"))
                .font(Theme.mono(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            anchor
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

    /// Where the thread points: its line on the current diff, or — once the diff has moved on —
    /// the line it was written against, which is shown and never used to position anything.
    @ViewBuilder
    private var anchor: some View {
        if let line = thread.line, !thread.isOutdated {
            Text(String(localized: "line \(line)"))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
        } else if let original = thread.originalLine {
            Text(String(localized: "· was line \(original)"))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
        }
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
                    Text(verbatim: String(commit.oid.prefix(7)))
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
