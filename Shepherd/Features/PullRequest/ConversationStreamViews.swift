import AppKit
import ShepherdCore
import SwiftUI

// The conversation tab's stream (ADR 0043) and its rows, one view per kind of entry. They draw what
// the model already holds and fetch nothing; the writes are the thread reply bars', the reaction
// bars' and the posts' own edits and deletes, through `PullRequestActions`.

/// Every entry after the description, in GitHub's order.
///
/// A view of its own, compared by what it draws, so it is re-diffed when the entries change and at
/// no other time: the tab around it is re-evaluated for the claims card, for *Quote reply*'s focus
/// request and for every inbox emission the stack card reads, and each of those used to walk every
/// post and thread of a long conversation again. The model, the actions and the translation cache
/// are what the rows act through rather than what they show, so they stay out of the comparison;
/// what a row does read off the model reaches it through observation — a thread's fold reaches
/// that card, the reviewer's reaction clicks only the reaction bars (``PostReactions``), whether a
/// post is being edited only the posts the viewer may edit — and a reply or an edit being typed
/// redraws that card alone. The reviewer's edits and deletes are already in the entries
/// (``ReviewModel/conversationEntries``).
///
/// A plain `VStack`, not a lazy one: a lazy container may drop a row's `@State` once it scrolls
/// away, and a hidden comment the reviewer asked to see would hide again. A thread's reply and
/// fold are the model's (``ReviewModel/threadReplyDrafts``, ``ReviewModel/threadFoldFlips``) and
/// outlive their card either way. Every entry keeps its stable
/// ``ShepherdCore/ConversationEntry/id`` so that `@State` stays with the row it belongs to.
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
                actions: actions,
                translations: translations,
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
    /// The review model, for *Quote reply* and the reactions.
    let model: ReviewModel
    /// The write actions, for the reactions.
    let actions: PullRequestActions
    /// The tab's translation cache.
    let translations: TranslationCoordinator
    /// The post's node id, which is what a reaction is addressed to — the pull request's own for
    /// the description.
    let subjectID: String
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
    /// What the viewer may change about it, or `nil` for nothing (ADR 0043, C).
    var editing: PostEditing?

    /// Whether the reviewer asked to see a hidden post anyway.
    @State private var isRevealed = false

    var body: some View {
        if isMinimized && !isRevealed {
            StreamNoticeRow(
                symbol: "eye.slash",
                text: ConversationEventText.hiddenSentence(reason: minimizedReason),
                buttonTitle: String(localized: "Show")
            ) { isRevealed = true }
        } else {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    PostHeader(
                        model: model,
                        actions: actions,
                        author: author,
                        verb: verb,
                        date: date,
                        isEdited: isEdited,
                        markdown: markdown,
                        url: url,
                        editing: editing
                    )
                    if let editing, PostEditor.isOpen(for: editing, in: model) {
                        PostEditor(model: model, actions: actions, editing: editing, markdown: markdown)
                    } else {
                        PostBody(
                            markdown: markdown,
                            reactions: PostReactions(subjectID: subjectID, stored: reactions, model: model, actions: actions),
                            translations: translations
                        )
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: PostHeader.spokenLabel(
                author: author,
                verb: verb,
                date: date,
                isEdited: isEdited
            )))
        }
    }

}

/// What a post says — the description, a comment, or a reviewer's words above the verdict — and
/// the reactions under it. The card around it is the caller's.
struct PostBody: View {
    /// The post as Markdown source; empty only for a description nobody wrote.
    let markdown: String
    /// The reactions under it.
    let reactions: PostReactions
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
            if reactions.isDrawn {
                reactions
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

/// Who wrote a post, what they did and when, and the post's menu (``PostMenu``). Above a post's
/// body, and as a review's own row.
private struct PostHeader: View {
    /// The review model, for the menu.
    let model: ReviewModel
    /// The write actions, for the menu's delete.
    let actions: PullRequestActions
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
    /// The post's Markdown, for *Quote reply* and *Edit*; empty for a verdict without words.
    var markdown = ""
    /// The post on github.com.
    var url: URL?
    /// What the viewer may change about the post, or `nil` for nothing.
    var editing: PostEditing?

    var body: some View {
        HStack(spacing: 8) {
            AuthorLine(author: author, verb: verb, symbol: symbol, tint: tint, date: date, isEdited: isEdited)
            Spacer(minLength: 4)
            PostMenu(
                model: model,
                actions: actions,
                author: author,
                date: date,
                markdown: markdown,
                url: url,
                editing: editing
            )
        }
    }

    /// What a post — or a review — is announced as: who, what, when, and "edited" where the line
    /// above it says so.
    static func spokenLabel(author: ShepherdCore.Actor, verb: String, date: Date, isEdited: Bool) -> String {
        SpokenRow.sentence([
            author.bestName,
            verb,
            RelativeDate.long(date),
            isEdited ? String(localized: "edited") : nil,
        ])
    }
}

/// A post's ⋯ menu — *Quote reply*, *Edit*, *Delete…*, *Copy link*, *Open on GitHub*, each only
/// where it applies — and the question a delete asks before anything is written. Draws nothing
/// when no item applies.
struct PostMenu: View {
    /// The review model, for *Quote reply*, *Edit* and the delete.
    let model: ReviewModel
    /// The write actions, for the delete.
    let actions: PullRequestActions
    /// Who wrote the post, for the delete's question.
    let author: ShepherdCore.Actor
    /// When, for the same.
    let date: Date
    /// The post's Markdown: what *Quote reply* quotes and *Edit* starts from. *Quote reply* is left
    /// out while it is empty.
    var markdown = ""
    /// Whether the menu offers *Quote reply* at all — not on a thread's comment, whose answer is the
    /// thread's own reply bar.
    var quotes = true
    /// The post on github.com, for *Copy link* and *Open on GitHub*.
    var url: URL?
    /// What the viewer may change about the post, or `nil` for nothing.
    var editing: PostEditing?

    /// Whether *Delete…* has asked and is waiting for an answer.
    @State private var isConfirmingDelete = false

    private var offersQuote: Bool { quotes && !markdown.isEmpty }

    var body: some View {
        if offersQuote || url != nil || editing != nil {
            Menu {
                if offersQuote {
                    Button(String(localized: "Quote reply")) { model.quote(markdown) }
                }
                if let editing, editing.canEdit {
                    Button(String(localized: "Edit")) { model.beginEditing(editing.postID, markdown: markdown) }
                }
                if let editing, editing.canDelete {
                    Button(String(localized: "Delete…"), role: .destructive) { isConfirmingDelete = true }
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
            .confirmationDialog(
                String(localized: "Delete this comment?"),
                isPresented: $isConfirmingDelete
            ) {
                Button(String(localized: "Delete"), role: .destructive) {
                    if let editing { model.delete(editing, actions: actions) }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(Self.deleteQuestion(author: author, date: date))
            }
        }
    }

    /// What a delete asks before anything is written — ``ConversationEventText/deleteQuestion(author:date:now:)``.
    static func deleteQuestion(author: ShepherdCore.Actor, date: Date, now: Date = Date()) -> String {
        ConversationEventText.deleteQuestion(author: author, date: date, now: now)
    }
}

/// The editor that takes a post's text's place while the viewer edits it (ADR 0043, C): its
/// Markdown in the app's comment field, with *Cancel* and *Update comment*.
///
/// It draws from its own copy of the text, for ``ConversationThreadView``'s reason, and writes
/// every change to the model's (``ReviewModel/postEditDrafts``), which outlives the tab. ⌘⏎ is
/// *Update comment* while this field has the keyboard, and the toolbar's *Review* otherwise
/// (``ReviewModel/focusedPostEditor``).
struct PostEditor: View {
    /// The review model, which holds the draft and writes the edit.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions
    /// The post and where its edit is sent.
    let editing: PostEditing
    /// The text the post shows now — what *Update comment* is compared with, so an unchanged text
    /// sends nothing.
    let markdown: String

    /// What is typed — the copy this editor draws from.
    @State private var text = ""
    /// Bumped once the editor is on screen, so the keyboard goes into it.
    @State private var focusRequest = 0

    /// Whether a post's editor is open. Asks the model only for a post the viewer may edit, so the
    /// others do not redraw when an editor opens.
    static func isOpen(for editing: PostEditing, in model: ReviewModel) -> Bool {
        editing.canEdit && model.postsBeingEdited.contains(editing.postID)
    }

    var body: some View {
        let isFocused = model.focusedPostEditor == editing.postID
        VStack(alignment: .leading, spacing: 8) {
            ComposerTextEditor(
                text: draft,
                height: 96,
                imageUpload: model.summary.map { ImageUploadTarget(repo: $0.repo, actions: actions) },
                focusRequest: focusRequest,
                onFocusChange: { focused in
                    if focused {
                        model.focusedPostEditor = editing.postID
                    } else if model.focusedPostEditor == editing.postID {
                        model.focusedPostEditor = nil
                    }
                }
            )
            .accessibilityLabel(String(localized: "Edit comment"))
            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "Cancel")) { model.endEditing(editing.postID) }
                    .buttonStyle(SecondaryButtonStyle())
                    .help(String(localized: "Close the editor and keep the comment as it is"))
                    .accessibilityLabel(String(localized: "Cancel editing"))
                Button(String(localized: "Update comment")) {
                    model.edit(editing, body: text, shown: markdown, actions: actions)
                }
                .buttonStyle(PrimaryButtonStyle())
                // The composer's rule: ⌘⏎ is this button's only while its field has the keyboard.
                .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .disabled(!PastedImage.isSendable(text))
                .help(String(localized: "Update the comment (⌘⏎ while you type)"))
            }
        }
        .onAppear {
            text = model.postEditDrafts[editing.postID] ?? ""
            focusRequest += 1
        }
        // The field can leave with the keyboard in it — *Update comment*, a switch of tab — and
        // then reports no focus change of its own; ⌘⏎ has to go back to *Review* regardless.
        .onDisappear {
            if model.focusedPostEditor == editing.postID { model.focusedPostEditor = nil }
        }
    }

    /// The field's text, written to this editor's copy and to the model's at once, and read from
    /// the model's first — ``ConversationThreadView``'s reply binding, for its reasons.
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
/// filled when one of them is yours, and a smiley that offers all eight (ADR 0043, B).
///
/// Where the viewer may react a capsule is a button that adds or takes back the viewer's own, as
/// on GitHub, and so is an emoji in the smiley's menu. Where GitHub says they may not — a locked
/// conversation, an archived repository — the capsules are only read and the smiley is not drawn.
/// A menu rather than a popover, because the bar also sits in the diff's thread popover, and a
/// popover opened from inside another one is a thing nobody here could check by eye.
struct ReactionBar: View {
    /// The groups to draw, in GitHub's order — the stored ones with the reviewer's clicks laid
    /// over them (``ConversationOverlay/reactions(_:on:)``).
    let groups: [ReactionGroup]
    /// Whether the viewer may react here.
    let canReact: Bool
    /// A click on an emoji, with whether the viewer's reaction is on it now.
    let onToggle: @MainActor (ReactionContent, Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(groups, id: \.content) { group in
                Group {
                    if canReact {
                        Button {
                            onToggle(group.content, group.viewerHasReacted)
                        } label: {
                            Self.capsule(group)
                        }
                        .buttonStyle(.plain)
                        .help(Self.action(for: group))
                        .accessibilityHint(Text(verbatim: Self.action(for: group)))
                    } else {
                        Self.capsule(group)
                    }
                }
                .accessibilityLabel(Text(verbatim: Self.spokenLabel(for: group)))
            }
            if canReact {
                Menu {
                    // The eight, in GitHub's order, each with its name; one the viewer already
                    // used is checked, and choosing it takes it back, as on GitHub.
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
                        .reactionChip(fill: Theme.control)
                }
                // `.button` runs the label through the button style, so the capsule is drawn as
                // written; the borderless style draws a label of its own.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "Add a reaction"))
                .accessibilityLabel(String(localized: "Add a reaction"))
            }
        }
    }

    /// One capsule: the emoji and its count, filled when one of them is the viewer's.
    private static func capsule(_ group: ReactionGroup) -> some View {
        Text(verbatim: "\(group.content.emoji) \(group.count)")
            .font(Theme.type(.subheadline))
            .foregroundStyle(Theme.text)
            .reactionChip(fill: group.viewerHasReacted ? Theme.chipBackground(Theme.accentText) : Theme.control)
    }

    /// What pressing a capsule does — its tooltip, and what a screen reader says after its label.
    static func action(for group: ReactionGroup) -> String { ConversationEventText.reactionAction(for: group) }

    /// One capsule in words — "Thumbs up. 2 reactions. including yours."
    static func spokenLabel(for group: ReactionGroup) -> String { ConversationEventText.reactionSpokenLabel(for: group) }

    /// GitHub's name for a reaction. The emoji alone would be read out by its Unicode name.
    static func name(of content: ReactionContent) -> String { ConversationEventText.reactionName(of: content) }
}

private extension View {
    /// The capsule a reaction is drawn in, and the smiley beside them in the same one, so the two
    /// cannot drift into two looks.
    /// - Parameter fill: The capsule's background.
    func reactionChip(fill: Color) -> some View {
        padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(fill, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).stroke(Theme.border, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
    }
}

/// One post's reaction bar on the review screen: the stored groups with the reviewer's clicks laid
/// over them, taking a click where GitHub lets the viewer react.
///
/// A view of its own, and the only one that reads the clicks (``ReviewModel/conversationOverlay``), so
/// a click re-runs the bars and not the posts around them. A post asks ``isDrawn`` instead, which
/// reads what the post already shows and two flags a sweep rarely changes.
struct PostReactions: View {
    /// The post's node id — the pull request's own for the description.
    let subjectID: String
    /// The post's groups as stored.
    let stored: [ReactionGroup]
    /// The review the post belongs to — a review's own row, a thread comment — or `nil` for the
    /// description and a comment. A post of the viewer's pending review takes no reaction:
    /// GitHub's page does not show it yet.
    var review: String?
    /// The review model, which holds the clicks and writes them.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions

    /// Whether the post draws a bar at all: one with reactions on it, or one the viewer may react
    /// to. Off the stored groups rather than the shown ones, which would make every post read the
    /// clicks.
    var isDrawn: Bool { !stored.isEmpty || canReact }

    /// Whether the viewer may react to this post.
    private var canReact: Bool {
        model.canReact && !(review.map(model.pendingReviewIDs.contains) ?? false)
    }

    var body: some View {
        ReactionBar(
            // ponytail: every bar reads the whole overlay, so one click re-runs every bar on the
            // screen (the posts around them stay put); a per-post slice of it if a long
            // conversation ever stutters.
            groups: model.conversationOverlay.reactions(stored, on: subjectID),
            canReact: canReact,
            onToggle: { content, isOn in
                model.toggleReaction(subjectID: subjectID, content: content, currentlyReacted: isOn, actions: actions)
            }
        )
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
        let verdict = ConversationEventText.verdict(review.state)
        let reactions = PostReactions(
            subjectID: review.id,
            stored: review.reactions,
            review: review.id,
            model: model,
            actions: actions
        )
        let editing = PostEditing.review(review)
        VStack(alignment: .leading, spacing: 8) {
            PostHeader(
                model: model,
                actions: actions,
                author: review.author,
                verb: verdict.sentence,
                symbol: verdict.symbol,
                tint: verdict.tint,
                date: review.createdAt,
                isEdited: review.isEdited,
                markdown: review.hasBody ? review.bodyMarkdown : "",
                url: review.url,
                editing: editing
            )
            .padding(.horizontal, 12)
            // The words under the review's own row, which already says who and when and carries
            // the menu — so no header here, and no spoken label of the card's own either.
            if review.hasBody {
                Card {
                    if let editing, PostEditor.isOpen(for: editing, in: model) {
                        PostEditor(model: model, actions: actions, editing: editing, markdown: review.bodyMarkdown)
                    } else {
                        PostBody(markdown: review.bodyMarkdown, reactions: reactions, translations: translations)
                    }
                }
            } else if !review.reactions.isEmpty {
                // A verdict without words has no card to carry its reactions, so they sit under
                // the row, past the avatar — and still take a click. No smiley without them.
                reactions
                    .padding(.leading, 44)
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
            date: review.createdAt,
            isEdited: review.isEdited
        )))
    }

}

/// A review thread in the stream — under the review that started it, or on its own when that
/// review is not in the timeline. Resolved and outdated threads start collapsed, as on GitHub, and
/// the reply bar is the diff popover's own (``ThreadReplyBar``).
struct ConversationThreadView: View {
    /// The review model, for *Show in diff* and for what the card keeps beyond its own life: the
    /// reply being typed and the reviewer's fold.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions
    /// The pull request.
    let summary: PullRequestSummary
    /// The tab's translation cache.
    let translations: TranslationCoordinator
    /// The thread.
    let thread: ReviewThread

    /// What is typed in the reply bar — the copy this card draws from, so a keystroke redraws this
    /// card and not the stream. The one that outlives the card is the model's
    /// (``ReviewModel/threadReplyDrafts``), taken when the card appears and written with every
    /// change (``reply``): the tab is rebuilt whenever it is shown, and folding the thread away —
    /// by hand, or because it was just resolved — takes the bar off screen as well.
    @State private var replyText = ""

    private var isExpanded: Bool {
        Self.isExpanded(thread, isFlipped: model.threadFoldFlips.contains(thread.id))
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
                        ThreadCommentView(
                            comment: comment,
                            translations: translations,
                            model: model,
                            actions: actions,
                            hasMenu: true
                        )
                    }
                    ThreadReplyBar(thread: thread, summary: summary, actions: actions, replyText: reply)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: spokenLabel))
        .onAppear { replyText = model.threadReplyDrafts[thread.id] ?? "" }
    }

    /// The reply bar's text, written to this card's copy and to the model's at once — not through
    /// an `onChange` of the copy, which a card already gone never runs: a reply that finishes
    /// sending after *Show in diff* has to clear the draft it sent, or the tab would offer it
    /// again. Read from the model's first for the same reason: the bar compares what it sent with
    /// what the field holds before it clears it, and a card already gone has no copy to compare.
    private var reply: Binding<String> {
        Binding(
            // The card's copy read first, so SwiftUI tracks it: the model's is not observed.
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

    /// The thread's row: everything up to *Show in diff* is one button that folds the thread, so
    /// the whole row is the target rather than the 12-point chevron in front of it.
    private var header: some View {
        HStack(spacing: 6) {
            Button {
                model.threadFoldFlips.formSymmetricDifference([thread.id])
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Theme.type(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 12)
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(chevronLabel)
            .accessibilityLabel(chevronLabel)
            if thread.isAnchoredInCurrentDiff, let path = thread.path {
                Button(String(localized: "Show in diff")) {
                    model.reveal(path: path, line: thread.line)
                }
                .buttonStyle(SecondaryButtonStyle(height: 22))
            }
        }
    }

    /// What the row does, in words: it shows or hides the comments and the reply bar.
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
    static func title(for commits: [CommitInfo]) -> String { ConversationEventText.commitsTitle(for: commits) }
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
