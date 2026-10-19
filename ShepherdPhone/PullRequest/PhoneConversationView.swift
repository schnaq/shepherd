import ShepherdCore
import SwiftUI

// The pull request screen's conversation, drawn for a phone (ADR 0044): the same stream the Mac's
// conversation tab draws (`ConversationStreamViews.swift`, ADR 0043) — comments, reviews with their
// threads, commit runs, events, reactions, edits and deletes — from the same `ReviewModel` state,
// in cards that fit 393 points and grow with Dynamic Type. The Mac's rows cannot be shared: they
// live in an AppKit file and are laid out for a pointer. What is shared is everything they *read*:
// `conversationEntries` with the reviewer's edits and deletes already laid over them,
// `conversationOverlay` for the reaction clicks, `PostEditing` for what may be changed, and the
// model's own write paths, so a rule fixed on the Mac is fixed here.

// MARK: - Small shared pieces

extension View {
    /// The phone's content card: opaque ``Theme/panel`` with a hairline, 12 pt continuous corners
    /// (ADR 0040 — content stays opaque; glass is the control layer's).
    func phoneCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    /// A text field standing on the sheet's ``Theme/background``: the card's opaque fill and
    /// hairline, so the field reads as a field in light mode, where ``Theme/raised`` is the
    /// background's own grey.
    func phoneInputField() -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

/// The uppercase caption at the top of a phone card — ``CardTitle``'s look on the type scale.
struct PhoneCardTitle: View {
    /// The caption, already uppercased by the caller.
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.type(.caption, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Theme.textMuted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The saved replies a field can take, as a menu beside it, or nothing when there are none.
///
/// The Mac's `SavedReplyMenu` is hover-driven and ranks suggestions with embeddings the phone does
/// not run; this is its plain list, inserted with the same rule
/// (``ShepherdCore/SavedReply/inserting(_:into:)``).
struct PhoneSavedReplyMenu: View {
    /// The replies, in the user's own order.
    let replies: [SavedReply]
    /// Called with the chosen reply's body.
    let onInsert: (String) -> Void

    var body: some View {
        if !replies.isEmpty {
            Menu {
                ForEach(replies) { reply in
                    Button(reply.trimmedName) { onInsert(reply.body) }
                }
            } label: {
                Label(String(localized: "Insert a saved reply"), systemImage: "text.bubble")
            }
        }
    }
}

// MARK: - The stream

/// Every entry after the description, in GitHub's order — the phone's `ConversationStream`.
///
/// A plain `VStack` for the Mac's reason: a lazy container may drop a row's `@State` once it
/// scrolls away, and a hidden comment the reviewer asked to see would hide again.
struct PhoneConversationStream: View {
    /// The entries, oldest first (``ReviewModel/conversationEntries``).
    let entries: [ConversationEntry]
    /// The pull request, for the threads' writes.
    let summary: PullRequestSummary
    /// The review model.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions
    /// *Show in diff* on a thread: the file and the line.
    let onShowInDiff: (String, Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(entries) { entry in
                switch entry {
                case .comment(let comment):
                    PhonePostView(
                        model: model,
                        actions: actions,
                        subjectID: comment.id,
                        author: comment.author,
                        verb: String(localized: "commented"),
                        date: comment.createdAt,
                        markdown: comment.bodyMarkdown,
                        isEdited: comment.isEdited,
                        reactions: comment.reactions,
                        url: comment.url,
                        isMinimized: comment.isMinimized,
                        minimizedReason: comment.minimizedReason,
                        editing: PostEditing.comment(comment)
                    )
                case .review(let review, let threads):
                    PhoneReviewView(
                        model: model,
                        actions: actions,
                        summary: summary,
                        review: review,
                        threads: threads,
                        onShowInDiff: onShowInDiff
                    )
                case .thread(let thread):
                    PhoneThreadView(
                        model: model,
                        actions: actions,
                        summary: summary,
                        thread: thread,
                        onShowInDiff: onShowInDiff
                    )
                case .commits(let commits):
                    PhoneCommitsRow(commits: commits)
                case .event(let event):
                    PhoneEventRow(item: event)
                }
            }
        }
    }
}

// MARK: - Posts

/// One post — the description or a comment — header, body and reactions in one card.
struct PhonePostView: View {
    /// The review model, for *Quote reply*, the reactions and the edits.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions
    /// The post's node id — the pull request's own for the description.
    let subjectID: String
    /// Who wrote it.
    let author: ShepherdCore.Actor
    /// What they did: "opened this pull request", "commented".
    let verb: String
    /// When.
    let date: Date
    /// The post as Markdown; empty only for a description nobody wrote.
    let markdown: String
    /// Whether it was edited after it was posted.
    var isEdited = false
    /// The reactions anybody left on it, as stored.
    var reactions: [ReactionGroup] = []
    /// The post on github.com.
    var url: URL?
    /// Whether a maintainer hid it.
    var isMinimized = false
    /// GitHub's word for why it is hidden.
    var minimizedReason: String?
    /// What the viewer may change about it (ADR 0043, C).
    var editing: PostEditing?

    /// Whether the reviewer asked to see a hidden post anyway.
    @State private var isRevealed = false

    var body: some View {
        if isMinimized && !isRevealed {
            PhoneStreamNotice(
                symbol: "eye.slash",
                text: Self.hiddenSentence(reason: minimizedReason),
                buttonTitle: String(localized: "Show")
            ) { isRevealed = true }
        } else {
            PhonePostCard(
                model: model,
                actions: actions,
                author: author,
                date: date,
                markdown: markdown,
                url: url,
                editing: editing
            ) {
                PhoneAuthorLine(author: author, verb: verb, date: date, isEdited: isEdited)
            } content: {
                if let editing, PhonePostEditor.isOpen(for: editing, in: model) {
                    PhonePostEditor(model: model, actions: actions, editing: editing, markdown: markdown)
                } else {
                    PhonePostBody(
                        markdown: markdown,
                        reactions: PhonePostReactions(subjectID: subjectID, stored: reactions, model: model, actions: actions)
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: Self.spokenLabel(author: author, verb: verb, date: date, isEdited: isEdited)))
        }
    }

    /// "Hidden — off-topic", in GitHub's word for why; "Hidden comment" otherwise. The Mac's
    /// sentence (`ConversationPostView.hiddenSentence`), in the same catalog keys.
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

    /// Who, what, when, and "edited" — what a post is announced as (ADR 0033).
    static func spokenLabel(author: ShepherdCore.Actor, verb: String?, date: Date, isEdited: Bool) -> String {
        SpokenRow.sentence([
            author.bestName,
            verb,
            RelativeDate.long(date),
            isEdited ? String(localized: "edited") : nil,
        ])
    }
}

/// A card with a header line, the post's ⋯ menu beside it, and a body — and the same menu on a
/// long press of the whole card, which is where an iPhone user looks for it.
struct PhonePostCard<Header: View, Content: View>: View {
    let model: ReviewModel
    let actions: PullRequestActions
    let author: ShepherdCore.Actor
    let date: Date
    let markdown: String
    var quotes = true
    let url: URL?
    let editing: PostEditing?
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    /// Whether *Delete…* has asked and is waiting for an answer.
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                header
                Spacer(minLength: 4)
                if hasMenu {
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(Theme.type(.body))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(minWidth: 32, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(String(localized: "More actions"))
                }
            }
            content
        }
        .phoneCard()
        // Not while the post's editor is open: the menu wraps the whole card, so a long press in
        // the editor's field would open Quote reply / Edit / Delete instead of select and paste.
        .contextMenu {
            if hasMenu && !isEditorOpen { menuItems }
        }
        .confirmationDialog(
            String(localized: "Delete this comment?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let editing { model.delete(editing, actions: actions) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(Self.deleteQuestion(author: author, date: date))
        }
    }

    private var offersQuote: Bool { quotes && !markdown.isEmpty }

    private var hasMenu: Bool { offersQuote || url != nil || editing != nil }

    private var isEditorOpen: Bool { editing.map { PhonePostEditor.isOpen(for: $0, in: model) } ?? false }

    /// *Quote reply*, *Edit*, *Delete…*, *Copy link*, *Share*, *Open on GitHub* — each only where it
    /// applies, as on the Mac (`PostMenu`).
    @ViewBuilder
    private var menuItems: some View {
        if offersQuote {
            Button(String(localized: "Quote reply"), systemImage: "quote.bubble") { model.quote(markdown) }
        }
        if let editing, editing.canEdit {
            Button(String(localized: "Edit"), systemImage: "pencil") {
                model.beginEditing(editing.postID, markdown: markdown)
            }
        }
        if let url {
            Button(String(localized: "Copy link"), systemImage: "link") {
                PlatformServices.copyToPasteboard(url.absoluteString)
            }
            ShareLink(item: url)
            Button(String(localized: "Open on GitHub"), systemImage: "safari") { PlatformServices.open(url) }
        }
        if let editing, editing.canDelete {
            Divider()
            Button(String(localized: "Delete…"), systemImage: "trash", role: .destructive) {
                isConfirmingDelete = true
            }
        }
    }

    /// What a delete asks first: whose comment, from when, and that it cannot be undone — the
    /// Mac's question (`PostMenu.deleteQuestion`), in the same catalog key.
    static func deleteQuestion(author: ShepherdCore.Actor, date: Date) -> String {
        let name = author.bestName
        let when = RelativeDate.long(date)
        return String(localized: "\(name) wrote this comment \(when). It is deleted on GitHub, and that cannot be undone.")
    }
}

/// Who wrote something and when, in two lines: the avatar beside the name and agent chip, and
/// what they did with how long ago under it.
struct PhoneAuthorLine: View {
    let author: ShepherdCore.Actor
    /// What they did — "commented", "approved these changes" — or `nil` for a thread comment.
    var verb: String?
    /// The verdict's symbol in front of the verb, for a review.
    var symbol: String?
    /// The verb's colour: muted for a post, the verdict's own for a review.
    var tint = Theme.textSecondary
    let date: Date
    var isEdited = false

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 30
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At the accessibility sizes the avatar goes above the words rather than beside them:
        // beside them it took a third of the width and broke "commented" into syllables.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            AvatarView(actor: author, size: min(avatarSize, 48))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { nameAndAgent }
                    VStack(alignment: .leading, spacing: 4) { nameAndAgent }
                }
                HStack(spacing: 4) {
                    if let verb {
                        if let symbol {
                            Image(systemName: symbol)
                                .foregroundStyle(tint)
                                .accessibilityHidden(true)
                        }
                        Text(verb)
                            .foregroundStyle(tint)
                        Text(verbatim: "·")
                            .foregroundStyle(Theme.textMuted)
                    }
                    RelativeDateText(date: date, style: verb == nil ? .long : .short)
                        .foregroundStyle(Theme.textMuted)
                    if isEdited {
                        Text(verbatim: "· " + String(localized: "edited"))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .font(Theme.type(.footnote))
            }
        }
    }

    @ViewBuilder
    private var nameAndAgent: some View {
        Text(author.bestName)
            .font(Theme.type(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.textStrong)
            .lineLimit(2)
        if let identity = author.kind.agentIdentity {
            PhoneChip(text: identity.displayName, color: Theme.agent)
        }
    }
}

/// What a post says and the reactions under it.
struct PhonePostBody: View {
    let markdown: String
    let reactions: PhonePostReactions

    /// The body text size, scaled from `.body` so the post grows with Dynamic Type —
    /// ``MarkdownText`` takes a point size and derives its headings and code from it.
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if markdown.isEmpty {
                Text(String(localized: "No description."))
                    .font(Theme.type(.callout))
                    .foregroundStyle(Theme.textMuted)
            } else {
                MarkdownText(markdown: markdown, size: bodySize)
            }
            if reactions.isDrawn {
                reactions
            }
        }
    }
}

/// A one-line notice where a post would be — a hidden comment, earlier activity that is only on
/// GitHub — with the one button that does something about it.
struct PhoneStreamNotice: View {
    let symbol: String
    let text: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .font(Theme.type(.subheadline))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Editing (ADR 0043, C)

/// The editor that takes a post's text's place while the viewer edits it: its Markdown in a
/// growing field, with *Cancel* and *Update comment*.
///
/// In place rather than in a sheet, because the model's editing state is per post and survives the
/// screen: an edit that could not be sent reopens its editor with its own text
/// (``ReviewModel/reopensEditor(of:with:overlay:editing:)``), and an editor that *is* the post's
/// body shows that without any presenting of its own. It draws from its own copy of the text and
/// writes every change to ``ReviewModel/postEditDrafts`` — the Mac `PostEditor`'s arrangement.
struct PhonePostEditor: View {
    let model: ReviewModel
    let actions: PullRequestActions
    let editing: PostEditing
    /// The text the post shows now — an unchanged text sends nothing.
    let markdown: String

    @State private var text = ""
    @FocusState private var isFocused: Bool

    /// Whether a post's editor is open; asks the model only for a post the viewer may edit.
    static func isOpen(for editing: PostEditing, in model: ReviewModel) -> Bool {
        editing.canEdit && model.postsBeingEdited.contains(editing.postID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(String(localized: "Edit comment"), text: draft, axis: .vertical)
                .font(Theme.type(.body))
                .lineLimit(3...14)
                .focused($isFocused)
                .padding(10)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(String(localized: "Edit comment"))
            HStack(spacing: 10) {
                Spacer()
                Button(String(localized: "Cancel")) { model.endEditing(editing.postID) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(String(localized: "Cancel editing"))
                Button(String(localized: "Update comment")) {
                    model.edit(editing, body: text, shown: markdown, actions: actions)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            text = model.postEditDrafts[editing.postID] ?? ""
            isFocused = true
        }
    }

    private var draft: Binding<String> {
        Binding(
            // The editor's copy read first, so SwiftUI tracks it: the model's is not observed.
            get: {
                let own = text
                return model.postEditDrafts[editing.postID] ?? own
            },
            set: { new in
                text = new
                model.postEditDrafts[editing.postID] = new
            }
        )
    }
}

// MARK: - Reactions (ADR 0043, B)

/// One post's reaction bar: the stored groups with the reviewer's clicks laid over them, taking a
/// tap where GitHub lets the viewer react — the Mac's `PostReactions`, and the only view that reads
/// the clicks, so a tap re-runs the bars and not the posts around them.
struct PhonePostReactions: View {
    let subjectID: String
    let stored: [ReactionGroup]
    /// The review the post belongs to, or `nil` for the description and a comment. A post of the
    /// viewer's pending review takes no reaction.
    var review: String?
    let model: ReviewModel
    let actions: PullRequestActions

    @State private var taps = 0

    /// Whether the post draws a bar at all.
    var isDrawn: Bool { !stored.isEmpty || canReact }

    private var canReact: Bool {
        model.canReact && !(review.map(model.pendingReviewIDs.contains) ?? false)
    }

    var body: some View {
        PhoneReactionBar(
            groups: model.conversationOverlay.reactions(stored, on: subjectID),
            canReact: canReact,
            onToggle: { content, isOn in
                taps += 1
                model.toggleReaction(subjectID: subjectID, content: content, currentlyReacted: isOn, actions: actions)
            }
        )
        .sensoryFeedback(.selection, trigger: taps)
    }
}

/// The reactions under a post: one capsule per emoji with its count, filled when one of them is
/// yours, and a smiley that offers all eight — GitHub's bar, sized for a thumb and scrolled
/// sideways when a post carries more than fit.
struct PhoneReactionBar: View {
    let groups: [ReactionGroup]
    let canReact: Bool
    let onToggle: @MainActor (ReactionContent, Bool) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups, id: \.content) { group in
                    Group {
                        if canReact {
                            Button {
                                onToggle(group.content, group.viewerHasReacted)
                            } label: {
                                capsule(group)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text(verbatim: Self.action(for: group)))
                        } else {
                            capsule(group)
                        }
                    }
                    .accessibilityLabel(Text(verbatim: Self.spokenLabel(for: group)))
                }
                if canReact {
                    Menu {
                        ForEach(ReactionContent.allCases, id: \.self) { content in
                            let isOn = groups.contains { $0.content == content && $0.viewerHasReacted }
                            Toggle(isOn: Binding(get: { isOn }, set: { _ in onToggle(content, isOn) })) {
                                Text(verbatim: "\(content.emoji)  \(Self.name(of: content))")
                            }
                        }
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(Theme.type(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                            .reactionCapsule(fill: Theme.control, stroke: Theme.border)
                    }
                    .accessibilityLabel(String(localized: "Add a reaction"))
                }
            }
        }
        .scrollClipDisabled()
    }

    private func capsule(_ group: ReactionGroup) -> some View {
        Text(verbatim: "\(group.content.emoji) \(group.count)")
            .font(Theme.type(.subheadline))
            .monospacedDigit()
            .foregroundStyle(group.viewerHasReacted ? Theme.accentText : Theme.text)
            .reactionCapsule(
                fill: group.viewerHasReacted ? Theme.chipBackground(Theme.accentText) : Theme.control,
                stroke: group.viewerHasReacted ? Theme.accent.opacity(0.5) : Theme.border
            )
    }

    /// What tapping a capsule does, in words.
    static func action(for group: ReactionGroup) -> String {
        group.viewerHasReacted
            ? String(localized: "Remove your reaction")
            : String(localized: "Add your reaction")
    }

    /// One capsule in words — the fill marks your own, and colour is never the only carrier.
    static func spokenLabel(for group: ReactionGroup) -> String {
        let count = group.count
        return SpokenRow.sentence([
            name(of: group.content),
            String(localized: "\(count) reactions"),
            group.viewerHasReacted ? String(localized: "including yours") : nil,
        ])
    }

    /// GitHub's name for a reaction; the emoji alone would be read out by its Unicode name.
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

private extension View {
    /// The capsule a reaction and the smiley beside them are drawn in.
    func reactionCapsule(fill: Color, stroke: Color) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 32)
            .background(fill, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).stroke(stroke, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
    }
}

// MARK: - Reviews and threads

/// A review in the stream: who gave which verdict and when, the words above it, and the threads
/// its comments started, indented under it.
struct PhoneReviewView: View {
    let model: ReviewModel
    let actions: PullRequestActions
    let summary: PullRequestSummary
    let review: ConversationReview
    let threads: [ReviewThread]
    let onShowInDiff: (String, Int?) -> Void

    var body: some View {
        let verdict = Self.verdict(review.state)
        let reactions = PhonePostReactions(
            subjectID: review.id,
            stored: review.reactions,
            review: review.id,
            model: model,
            actions: actions
        )
        let editing = PostEditing.review(review)
        VStack(alignment: .leading, spacing: 10) {
            if review.hasBody {
                PhonePostCard(
                    model: model,
                    actions: actions,
                    author: review.author,
                    date: review.createdAt,
                    markdown: review.bodyMarkdown,
                    url: review.url,
                    editing: editing
                ) {
                    authorLine(verdict)
                } content: {
                    if let editing, PhonePostEditor.isOpen(for: editing, in: model) {
                        PhonePostEditor(model: model, actions: actions, editing: editing, markdown: review.bodyMarkdown)
                    } else {
                        PhonePostBody(markdown: review.bodyMarkdown, reactions: reactions)
                    }
                }
            } else {
                // A verdict without words is a line in the stream, not a card: nothing was written
                // to the reviewer, the way a commit run is not.
                VStack(alignment: .leading, spacing: 8) {
                    authorLine(verdict)
                    if !review.reactions.isEmpty {
                        reactions
                    }
                }
                .padding(.horizontal, 14)
            }
            ForEach(threads) { thread in
                PhoneThreadView(model: model, actions: actions, summary: summary, thread: thread, onShowInDiff: onShowInDiff)
                    .padding(.leading, 14)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: PhonePostView.spokenLabel(
            author: review.author,
            verb: verdict.sentence,
            date: review.createdAt,
            isEdited: review.isEdited
        )))
    }

    private func authorLine(_ verdict: (sentence: String, symbol: String, tint: Color)) -> some View {
        PhoneAuthorLine(
            author: review.author,
            verb: verdict.sentence,
            symbol: verdict.symbol,
            tint: verdict.tint,
            date: review.createdAt,
            isEdited: review.isEdited
        )
    }

    /// The verdict as the review's line says it, with its symbol and colour — the Mac's words
    /// (`ConversationReviewView.verdict`). The words carry it; the colour only repeats them.
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

/// A review thread: where it points, whether it is settled, its comments and a reply field with
/// *Resolve* — the phone's `ConversationThreadView` and `ThreadReplyBar` in one card.
///
/// Resolved and outdated threads start folded, as on GitHub; the fold and the half-written reply
/// are the model's (``ReviewModel/threadFoldFlips``, ``ReviewModel/threadReplyDrafts``), so they
/// outlive the card. Also the body of ``PhoneThreadSheet``, which the diff opens.
struct PhoneThreadView: View {
    let model: ReviewModel
    let actions: PullRequestActions
    let summary: PullRequestSummary
    let thread: ReviewThread
    /// *Show in diff*, or `nil` where the diff is what is already showing.
    var onShowInDiff: ((String, Int?) -> Void)?
    /// Whether the thread is always open — in ``PhoneThreadSheet``, which exists to show it.
    var isAlwaysExpanded = false

    @State private var replyText = ""
    @State private var replies = 0
    @FocusState private var isReplyFocused: Bool

    private var isExpanded: Bool {
        if isAlwaysExpanded { return true }
        // The Mac's rule (`ConversationThreadView.isExpanded`): a flip is relative to how the
        // thread starts.
        return model.threadFoldFlips.contains(thread.id) == (thread.isResolved || thread.isOutdated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isExpanded {
                ForEach(thread.comments) { comment in
                    PhoneThreadComment(comment: comment, model: model, actions: actions)
                }
                replyBar
            }
        }
        .phoneCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: spokenLabel))
        .onAppear { replyText = model.threadReplyDrafts[thread.id] ?? "" }
        .sensoryFeedback(.success, trigger: replies)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                guard !isAlwaysExpanded else { return }
                withAnimation(.snappy) { model.threadFoldFlips.formSymmetricDifference([thread.id]) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !isAlwaysExpanded {
                        Image(systemName: "chevron.right")
                            .font(Theme.type(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(thread.path ?? String(localized: "Pull request conversation"))
                            .font(Theme.mono(.footnote))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        HStack(spacing: 6) {
                            if let anchor {
                                Text(anchor)
                                    .font(Theme.type(.footnote))
                                    .foregroundStyle(Theme.textMuted)
                            }
                            if thread.isOutdated {
                                PhoneChip(text: String(localized: "outdated"), color: Theme.pending)
                            }
                            if thread.isResolved {
                                PhoneChip(text: String(localized: "resolved"), color: Theme.success)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // What the thread is about, as the card announces it; what a tap does is the hint.
            .accessibilityLabel(Text(verbatim: spokenLabel))
            .accessibilityHint(isAlwaysExpanded ? ""
                : isExpanded ? String(localized: "Hide conversation") : String(localized: "Show conversation"))
            if let onShowInDiff, thread.isAnchoredInCurrentDiff, let path = thread.path {
                Button(String(localized: "Show in diff")) { onShowInDiff(path, thread.line) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(String(localized: "Reply…"), text: reply, axis: .vertical)
                .font(Theme.type(.body))
                .lineLimit(1...6)
                .focused($isReplyFocused)
                .padding(10)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Side by side while the two words fit, stacked at the accessibility sizes, where side
            // by side broke "Resolve" into syllables.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    resolveButton
                    Spacer(minLength: 0)
                    replyButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    resolveButton
                    replyButton
                }
            }
        }
    }

    private var resolveButton: some View {
        Button {
            guard !isTogglingThread else { return }
            Task { await actions.setThread(on: summary, threadID: thread.id, resolved: !thread.isResolved) }
        } label: {
            Label(
                thread.isResolved ? String(localized: "Unresolve") : String(localized: "Resolve"),
                systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark"
            )
            .busyLabel(isBusy: isTogglingThread)
        }
        .buttonStyle(.bordered)
    }

    private var replyButton: some View {
        Button {
            guard !isReplying else { return }
            Task { await sendReply() }
        } label: {
            Text(String(localized: "Reply"))
                .busyLabel(isBusy: isReplying)
        }
        .buttonStyle(.borderedProminent)
        .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replyTargetID == nil)
    }

    /// The reply field's text, written to this card's copy and to the model's at once — the Mac's
    /// arrangement, so a reply that finishes after the card has gone still clears what it sent.
    private var reply: Binding<String> {
        Binding(
            get: {
                let own = replyText
                return model.threadReplyDrafts[thread.id] ?? own
            },
            set: { text in
                replyText = text
                model.threadReplyDrafts[thread.id] = text.isEmpty ? nil : text
            }
        )
    }

    private var replyTargetID: Int? { thread.comments.compactMap(\.databaseID).last }

    private var isReplying: Bool { actions.activity.isRunning(summary.id, .reply) }

    private var isTogglingThread: Bool { actions.activity.isRunning(thread.id, .thread) }

    /// Queues the reply, and empties the field only once the row is on disk and only when nothing
    /// else was typed meanwhile (`ThreadReplyBar.sendReply()`).
    private func sendReply() async {
        guard let target = replyTargetID else { return }
        let typed = reply.wrappedValue
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch await actions.reply(on: summary, commentDatabaseID: target, body: text) {
        case .sent?, .queued?, .parked?:
            if reply.wrappedValue == typed { reply.wrappedValue = "" }
            isReplyFocused = false
            replies += 1
        case .failed?, nil:
            break
        }
    }

    /// Where the thread points: its line on the current diff, or the line it was written against.
    private var anchor: String? {
        if let line = thread.line, !thread.isOutdated {
            return String(localized: "line \(line)")
        }
        if let original = thread.originalLine {
            return String(localized: "was line \(original)")
        }
        return nil
    }

    private var spokenLabel: String {
        SpokenRow.sentence([
            thread.path ?? String(localized: "Pull request conversation"),
            anchor,
            thread.isOutdated ? String(localized: "outdated") : nil,
            thread.isResolved ? String(localized: "resolved") : nil,
        ])
    }
}

/// One comment inside a thread: author line, menu, body or editor, reactions.
struct PhoneThreadComment: View {
    let comment: ReviewComment
    let model: ReviewModel
    let actions: PullRequestActions

    @State private var isConfirmingDelete = false

    var body: some View {
        let editing = PostEditing.threadComment(comment)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                PhoneAuthorLine(author: comment.author, date: comment.createdAt, isEdited: comment.isEdited)
                Spacer(minLength: 4)
                // Visible as well as on a long press, as on the Mac's stream, so VoiceOver finds it.
                if editing != nil || comment.url != nil {
                    Menu {
                        menuItems(editing)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(Theme.type(.body))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(minWidth: 32, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(String(localized: "More actions"))
                }
            }
            if let editing, PhonePostEditor.isOpen(for: editing, in: model) {
                PhonePostEditor(model: model, actions: actions, editing: editing, markdown: comment.bodyMarkdown)
            } else {
                PhonePostBody(
                    markdown: comment.bodyMarkdown,
                    reactions: PhonePostReactions(
                        subjectID: comment.id,
                        stored: comment.reactions,
                        review: comment.reviewID,
                        model: model,
                        actions: actions
                    )
                )
            }
        }
        .contentShape(Rectangle())
        // Not while the editor is open, for ``PhonePostCard``'s reason: the field's own long press.
        .contextMenu {
            if !(editing.map { PhonePostEditor.isOpen(for: $0, in: model) } ?? false) { menuItems(editing) }
        }
        .confirmationDialog(
            String(localized: "Delete this comment?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let editing { model.delete(editing, actions: actions) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(PhonePostCard<EmptyView, EmptyView>.deleteQuestion(author: comment.author, date: comment.createdAt))
        }
    }

    /// *Edit*, *Copy link*, *Share*, *Open on GitHub* and *Delete…* — no *Quote reply*: a thread's
    /// answer is its own reply field.
    @ViewBuilder
    private func menuItems(_ editing: PostEditing?) -> some View {
        if let editing, editing.canEdit {
            Button(String(localized: "Edit"), systemImage: "pencil") {
                model.beginEditing(editing.postID, markdown: comment.bodyMarkdown)
            }
        }
        if let url = comment.url {
            Button(String(localized: "Copy link"), systemImage: "link") {
                PlatformServices.copyToPasteboard(url.absoluteString)
            }
            ShareLink(item: url)
            Button(String(localized: "Open on GitHub"), systemImage: "safari") { PlatformServices.open(url) }
        }
        if let editing, editing.canDelete {
            Divider()
            Button(String(localized: "Delete…"), systemImage: "trash", role: .destructive) {
                isConfirmingDelete = true
            }
        }
    }
}

// MARK: - Commits and events

/// Commits pushed with nothing else between them: a compact group rather than a card.
struct PhoneCommitsRow: View {
    let commits: [CommitInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Self.title(for: commits))
                    .foregroundStyle(Theme.textSecondary)
            } icon: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Theme.textMuted)
            }
            .font(Theme.type(.subheadline))
            ForEach(commits) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: commit.shortOid)
                        .font(Theme.mono(.footnote))
                        .foregroundStyle(Theme.accentText)
                    Text(commit.messageHeadline)
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RelativeDateText(date: commit.committedDate)
                        .font(Theme.type(.footnote))
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.leading, 28)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14)
    }

    /// "Claude Code added 3 commits" when one author pushed them all, "3 commits" otherwise.
    static func title(for commits: [CommitInfo]) -> String {
        let count = commits.count
        if Set(commits.map(\.author?.login)).count == 1, let name = commits.first?.author?.bestName {
            return String(localized: "\(name) added \(count) commits")
        }
        return String(localized: "\(count) commits")
    }
}

/// Something that happened between the posts — a label, a force-push, a merge — in one line, in
/// the Mac's words (``ConversationEventText``). A mention from elsewhere opens it.
struct PhoneEventRow: View {
    let item: ConversationEventItem

    /// The symbol's column, scaled with the text so a large symbol does not run into it.
    @ScaledMetric(relativeTo: .subheadline) private var symbolWidth: CGFloat = 18

    @Environment(\.openURL) private var openURL

    var body: some View {
        if case .crossReferenced(let reference, _) = item.event, let url = reference.url {
            Button { openURL(url) } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "Open on GitHub"))
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ConversationEventText.symbol(for: item.event))
                .foregroundStyle(ConversationEventText.tint(for: item.event))
                .frame(width: symbolWidth)
                .accessibilityHidden(true)
            Text("\(Text(ConversationEventText.sentence(for: item)).foregroundStyle(Theme.textSecondary))  \(Text(RelativeDate.short(item.createdAt)).foregroundStyle(Theme.textMuted))")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Theme.type(.subheadline))
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
