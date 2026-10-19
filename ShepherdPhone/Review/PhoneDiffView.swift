import ShepherdCore
import SwiftUI

/// One file's diff on the iPhone: a unified list of lines with syntax colour and word-level
/// changes, the review threads under the lines they hang on, and a way to comment on a line or
/// on a range of lines (ADR 0044).
///
/// It is the third native rendering of ADR 0034's contract and holds it the same way the Mac's
/// list does, by asking rather than restating:
///
/// - **Which lines take a comment** comes from ``ReviewModel/selectedListContent`` — the
///   model's `commentableLineSets(in:)` — and a range is bounded by ``ShepherdCore/DiffLineRange``
///   on top of it, because `validateAnchor` checks only the two ends and a touch list can pick
///   two rows anywhere.
/// - **What a comment means** is one call: ``ReviewModel/handle(_:)`` with `.addComment`, the
///   event Monaco's gutter sends and the Mac list's `c` sends.
/// - **Which round shows** is the model's ``ReviewModel/roundView``; this view never picks one.
///
/// Syntax colour and the word diff are outside the contract, as ADR 0034 allows. They are
/// computed once per file off the main thread (``HighlightedDiff``), kept per path while the
/// screen is up so stepping back to a file costs nothing, and only ever drawn onto the rows they
/// were built from.
///
/// The touch grammar: a tap picks a line, a second tap in the same hunk and on the same side
/// stretches the pick into a range, and the floating bar at the bottom comments on what is
/// picked. A long press offers the same on one line, without picking first. Rows a second tap
/// could not reach are dimmed while something is picked, so the rule is visible before it is
/// refused.
struct PhoneDiffView: View {
    /// The review model of the pull request.
    let model: ReviewModel
    /// The file to open with. Next and previous move the model's selection, and the screen
    /// follows the model from then on.
    let path: String

    @Environment(PhoneEnvironment.self) private var environment

    /// Whether long lines wrap. On by default: a phone is narrower than most lines.
    @AppStorage("phoneDiffWrapsLines") private var wraps = true
    /// The reader's own multiplier on the code size, on top of Dynamic Type.
    @AppStorage("phoneDiffTextScale") private var textScale = 1.0

    @ScaledMetric(relativeTo: .footnote) private var baseCodeSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var gutterSize: CGFloat = 11
    @ScaledMetric(relativeTo: .subheadline) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var chipSize: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var avatarSize: CGFloat = 22

    /// Highlighting per path, for the files this screen has shown.
    @State private var highlights: [String: HighlightedDiff] = [:]
    /// The picked rows: where the pick started and where it ends now. Both are row indices.
    @State private var pick: Pick?
    /// Threads the reader opened or closed against their default (resolved and outdated start
    /// closed, the rest open).
    @State private var flippedThreads: Set<String> = []
    /// Whether the initial path has been handed to the model.
    @State private var hasSelectedInitialPath = false
    /// Bumped when a tap is refused, for the warning haptic.
    @State private var refusals = 0
    /// The width of the scroll view, so an unwrapped row still fills the screen.
    @State private var viewportWidth: CGFloat = 0

    /// A pick on the list: one row, or a range from `anchor` to `end` (either order).
    struct Pick: Hashable {
        var anchor: Int
        var end: Int
    }

    var body: some View {
        content
            .background(Theme.background)
            .navigationTitle(Self.fileName(model.selectedPath ?? path))
            .navigationSubtitle(PhoneFilesScreen.directory(of: model.selectedPath ?? path) ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackgroundVisibility(.visible, for: .bottomBar)
            .task {
                guard !hasSelectedInitialPath else { return }
                hasSelectedInitialPath = true
                if model.selectedPath != path { model.selectedPath = path }
            }
            .onChange(of: model.selectedPath) { _, _ in pick = nil }
            .sheet(item: composerBinding) { request in
                PhoneInlineCommentSheet(model: model, request: request)
            }
            .sensoryFeedback(.selection, trigger: pick)
            .sensoryFeedback(.warning, trigger: refusals)
    }

    @ViewBuilder
    private var content: some View {
        if let content = model.selectedListContent, content.path == (model.selectedPath ?? path) {
            diff(content)
                .task(id: content) { await highlight(content) }
        } else if let file = model.selectedFile, file.path == (model.selectedPath ?? path), !file.hasPatch {
            ContentUnavailableView(
                String(localized: "No diff available (binary or truncated)"),
                systemImage: "doc.questionmark",
                description: Text(String(localized: "Open the file on GitHub to see it."))
            )
        } else if model.detail == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                String(localized: "No files yet"),
                systemImage: "doc.on.doc",
                description: Text(String(localized: "This pull request has no changed files."))
            )
        }
    }

    // MARK: - The list

    private func diff(_ content: DiffListContent) -> some View {
        // Counted once per draw rather than per row: walks over the threads and the draft.
        let notes = LineNotes(model: model, content: content)
        let lines = highlights[content.path]?.lines(for: content.rows)
        let window = pick.flatMap { reachableWindow(from: $0.anchor, in: content) }
        let picked = pick.flatMap { span(of: $0, in: content) }
        let digits = String(content.rows.reduce(0) { max($0, Self.ownNumber(of: $1) ?? 0) }).count
        return ScrollViewReader { proxy in
            ScrollView(wraps ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(content.rows.indices, id: \.self) { index in
                        row(
                            at: index,
                            content: content,
                            line: lines?[index],
                            notes: notes,
                            isPicked: pick.map { min($0.anchor, $0.end)...max($0.anchor, $0.end) }?.contains(index) ?? false,
                            isDimmed: window.map { !$0.contains(index) } ?? false,
                            digits: max(digits, 2)
                        )
                        .id(index)
                    }
                }
                .padding(.bottom, picked == nil ? 12 : 88)
                // Dense rows stop growing at the third accessibility size, as every list row in
                // the app does (ADR 0044): beyond it a line of code is a word per row.
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            }
            .id(content.path)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .overlay(alignment: .bottom) {
                if let picked {
                    pickBar(picked)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: picked)
            .task(id: content.path) { reveal(in: content, proxy: proxy) }
            .onChange(of: model.revealLine) { _, _ in reveal(in: content, proxy: proxy) }
        }
    }

    @ViewBuilder
    private func row(
        at index: Int,
        content: DiffListContent,
        line: AttributedString?,
        notes: LineNotes,
        isPicked: Bool,
        isDimmed: Bool,
        digits: Int
    ) -> some View {
        switch content.rows[index] {
        case .hunk(let originalStart, let modifiedStart):
            hunkRow(originalStart: originalStart, modifiedStart: modifiedStart)
                .frame(minWidth: wraps ? nil : viewportWidth, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(content.rows[index].spokenSentence(takesComment: false)))
                .accessibilityAddTraits(.isHeader)
        case .line(let patchRow):
            let identity = DiffListContent.lineIdentity(of: patchRow)
            let key = LineNotes.Key(side: identity.side, line: identity.line)
            let threads = notes.threads[key] ?? []
            let drafts = notes.drafts[key] ?? []
            VStack(alignment: .leading, spacing: 0) {
                lineRow(
                    patchRow,
                    index: index,
                    content: content,
                    line: line,
                    noteCount: threads.count + drafts.count,
                    isPicked: isPicked,
                    isDimmed: isDimmed,
                    digits: digits
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(spokenSentence(for: content.rows[index], content: content, threads: threads.count, drafts: drafts.count)))
                .accessibilityAddTraits(isPicked ? [.isSelected, .isButton] : .isButton)
                .accessibilityActions { lineActions(index: index, content: content) }
                ForEach(threads) { thread in
                    threadCard(thread)
                }
                ForEach(drafts, id: \.localID) { draft in
                    draftCard(draft)
                }
            }
            .frame(minWidth: wraps ? nil : viewportWidth, alignment: .leading)
        }
    }

    private func hunkRow(originalStart: Int, modifiedStart: Int) -> some View {
        Text(verbatim: "@@ -\(originalStart) +\(modifiedStart) @@")
            .font(Theme.mono(gutterSize, weight: .semibold))
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised)
            .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }

    private func lineRow(
        _ row: PatchRow,
        index: Int,
        content: DiffListContent,
        line: AttributedString?,
        noteCount: Int,
        isPicked: Bool,
        isDimmed: Bool,
        digits: Int
    ) -> some View {
        let tint = SyntaxStyle.tint(for: row.kind)
        let identity = DiffListContent.lineIdentity(of: row)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            // One gutter, with the row's own number — the same number its comment would anchor
            // to and its sentence announces (`DiffListContent.lineIdentity(of:)`). Sized by a
            // hidden run of eights so it grows with Dynamic Type and fits the widest number.
            ZStack(alignment: .trailing) {
                Text(verbatim: String(repeating: "8", count: digits)).hidden()
                Text(verbatim: String(identity.line))
                    .foregroundStyle(row.kind == .context ? Theme.textMuted : tint ?? Theme.textMuted)
            }
            .font(Theme.mono(gutterSize))
            .fixedSize()
            .padding(.leading, 8)
            .padding(.trailing, 4)
            // The marker says added or removed in a glyph as well as a colour (ADR 0033).
            Text(verbatim: Self.marker(for: row.kind))
                .font(Theme.mono(codeSize, weight: .semibold))
                .foregroundStyle(tint ?? Theme.textMuted)
                .fixedSize()
                .padding(.trailing, 4)
            code(row.text, attributed: line)
            if noteCount > 0 {
                Label("\(noteCount)", systemImage: "bubble.left.fill")
                    .labelStyle(.titleAndIcon)
                    .font(Theme.type(.caption2, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.chipBackground(Theme.accent), in: Capsule())
                    .padding(.horizontal, 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .modifier(RowWidth(wraps: wraps, viewportWidth: viewportWidth))
        .opacity(isDimmed ? 0.45 : 1)
        .background(rowBackground(tint: tint, isPicked: isPicked))
        // The change bar: the row's kind at the edge, and the accent while it is picked.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isPicked ? Theme.accent : tint ?? .clear)
                .frame(width: 3)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(index, in: content) }
        .contextMenu { lineMenu(row, index: index, content: content) }
    }

    @ViewBuilder
    private func code(_ text: String, attributed: AttributedString?) -> some View {
        let line = Group {
            if let attributed {
                Text(attributed)
            } else {
                Text(verbatim: text)
            }
        }
        .font(Theme.mono(codeSize))
        .foregroundStyle(Theme.text)
        if wraps {
            line
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        } else {
            line
                .fixedSize()
                .padding(.trailing, 16)
        }
    }

    private func rowBackground(tint: Color?, isPicked: Bool) -> Color {
        // The Mac list's wash, so a word highlight measured against it holds its contrast
        // (``Theme/wordHighlightOpacity``).
        if isPicked { return Theme.selection }
        guard let tint else { return .clear }
        return Theme.chipBackground(tint).opacity(0.6)
    }

    // MARK: - Threads and drafts

    private func threadCard(_ thread: ReviewThread) -> some View {
        let startsClosed = thread.isResolved || thread.isOutdated
        let isExpanded = flippedThreads.contains(thread.id) ? startsClosed : !startsClosed
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) {
                    if flippedThreads.contains(thread.id) {
                        flippedThreads.remove(thread.id)
                    } else {
                        flippedThreads.insert(thread.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let root = thread.rootComment {
                        AvatarView(actor: root.author, size: avatarSize)
                        Text(verbatim: root.author.displayName ?? root.author.login)
                            .font(Theme.type(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.textStrong)
                            .lineLimit(1)
                        RelativeDateText(date: root.createdAt)
                            .font(Theme.type(.footnote))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 4)
                    if thread.isResolved {
                        PhoneChip(text: String(localized: "Resolved"), color: Theme.success, size: chipSize)
                    } else if thread.isOutdated {
                        PhoneChip(text: String(localized: "Outdated"), color: Theme.pending, size: chipSize)
                    }
                    Image(systemName: "chevron.down")
                        .font(Theme.type(.caption, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")))

            if isExpanded {
                ForEach(Array(thread.comments.enumerated()), id: \.element.id) { offset, comment in
                    if offset > 0 {
                        Divider().overlay(Theme.hairline)
                        HStack(spacing: 8) {
                            AvatarView(actor: comment.author, size: avatarSize)
                            Text(verbatim: comment.author.displayName ?? comment.author.login)
                                .font(Theme.type(.subheadline, weight: .semibold))
                                .foregroundStyle(Theme.textStrong)
                                .lineLimit(1)
                            RelativeDateText(date: comment.createdAt)
                                .font(Theme.type(.footnote))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    MarkdownText(markdown: comment.bodyMarkdown, size: bodySize)
                }
            } else if thread.comments.count > 1 {
                Text(String(localized: "\(thread.comments.count) comments"))
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: wraps ? .infinity : viewportWidth, alignment: .leading)
    }

    private func draftCard(_ draft: DraftComment) -> some View {
        Button {
            model.handle(.commentClicked(.draft(draft.localID.uuidString)))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    PhoneChip(text: String(localized: "Pending"), systemImage: "clock", color: Theme.agent, size: chipSize)
                    if let start = draft.startLine, start != draft.line {
                        Text(String(localized: "Lines \(start)–\(draft.line)"))
                            .font(Theme.type(.footnote))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "pencil")
                        .font(Theme.type(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .accessibilityHidden(true)
                }
                Text(draft.body)
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.agent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: wraps ? .infinity : viewportWidth, alignment: .leading)
        .accessibilityHint(Text(String(localized: "Edit comment")))
    }

    // MARK: - Picking lines

    private func tap(_ index: Int, in content: DiffListContent) {
        guard content.anchor(for: content.rows[index]) != nil else {
            // A padding line, or the base side in "Since your review": nothing to comment on.
            refusals += 1
            return
        }
        if let current = pick {
            if current.anchor == index, current.end == index {
                pick = nil
                return
            }
            if span(of: Pick(anchor: current.anchor, end: index), in: content) != nil {
                pick?.end = index
                return
            }
        }
        pick = Pick(anchor: index, end: index)
        model.selectDiffRow(index)
    }

    private func span(of pick: Pick, in content: DiffListContent) -> DiffLineRange.Span? {
        DiffLineRange.span(
            in: content.rows,
            from: pick.anchor,
            to: pick.end,
            identity: DiffListContent.lineIdentity(of:),
            isCommentable: { side, line in
                (side == .left ? content.commentableLeft : content.commentableRight).contains(line)
            }
        )
    }

    private func reachableWindow(from anchor: Int, in content: DiffListContent) -> ClosedRange<Int>? {
        DiffLineRange.window(
            in: content.rows,
            around: anchor,
            identity: DiffListContent.lineIdentity(of:),
            isCommentable: { side, line in
                (side == .left ? content.commentableLeft : content.commentableRight).contains(line)
            }
        )
    }

    /// Opens the composer on a span, through the model's one door for it (ADR 0034's second
    /// agreement): the same `.addComment` event Monaco's gutter and the Mac list send.
    private func comment(on span: DiffLineRange.Span) {
        model.handle(.addComment(line: span.line, side: span.side == .left ? .left : .right, startLine: span.startLine))
    }

    /// The floating bar over the bottom of the diff while lines are picked — the one piece of
    /// glass laid over content, because it is a control over the content rather than content.
    private func pickBar(_ span: DiffLineRange.Span) -> some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.linesTitle(span))
                        .font(Theme.type(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                    Text(span.side == .left ? String(localized: "base") : String(localized: "head"))
                        .font(Theme.type(.caption))
                        .foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                Button {
                    pick = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.type(.body, weight: .semibold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel(Text(String(localized: "Cancel")))
                Button {
                    comment(on: span)
                } label: {
                    // The word while it fits, the glyph alone when large text leaves no room.
                    ViewThatFits(in: .horizontal) {
                        Label(String(localized: "Comment"), systemImage: "text.bubble")
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: "text.bubble")
                    }
                    .font(Theme.type(.body, weight: .semibold))
                }
                .accessibilityLabel(Text(String(localized: "Comment")))
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    @ViewBuilder
    private func lineMenu(_ row: PatchRow, index: Int, content: DiffListContent) -> some View {
        if let anchor = content.anchor(for: content.rows[index]) {
            if let pick, let span = span(of: pick, in: content), span.startLine != nil,
                (min(pick.anchor, pick.end)...max(pick.anchor, pick.end)).contains(index)
            {
                Button {
                    comment(on: span)
                } label: {
                    Label(Self.commentTitle(span), systemImage: "text.bubble")
                }
            }
            Button {
                comment(on: DiffLineRange.Span(side: anchor.side, startLine: nil, line: anchor.line))
            } label: {
                Label(String(localized: "Comment on line \(anchor.line)"), systemImage: "text.bubble")
            }
            Button {
                pick = Pick(anchor: index, end: index)
            } label: {
                Label(String(localized: "Select lines…"), systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }
        Button {
            PlatformServices.copyToPasteboard(row.text)
        } label: {
            Label(String(localized: "Copy line"), systemImage: "doc.on.doc")
        }
    }

    /// VoiceOver's way to everything a tap and a long press do.
    @ViewBuilder
    private func lineActions(index: Int, content: DiffListContent) -> some View {
        if let anchor = content.anchor(for: content.rows[index]) {
            Button(String(localized: "Comment on this line")) {
                comment(on: DiffLineRange.Span(side: anchor.side, startLine: nil, line: anchor.line))
            }
            Button(String(localized: "Start selection here")) {
                pick = Pick(anchor: index, end: index)
            }
            if let pick, pick.anchor != index, span(of: Pick(anchor: pick.anchor, end: index), in: content) != nil {
                Button(String(localized: "End selection here")) {
                    self.pick?.end = index
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle(isOn: $wraps) {
                    Label(String(localized: "Wrap lines"), systemImage: "text.word.spacing")
                }
                ControlGroup {
                    Button {
                        textScale = max(0.7, textScale - 0.1)
                    } label: {
                        Label(String(localized: "Smaller"), systemImage: "textformat.size.smaller")
                    }
                    Button {
                        textScale = 1
                    } label: {
                        Label(String(localized: "Default size"), systemImage: "textformat.size")
                    }
                    Button {
                        textScale = min(2, textScale + 0.1)
                    } label: {
                        Label(String(localized: "Larger"), systemImage: "textformat.size.larger")
                    }
                } label: {
                    Text(String(localized: "Text size"))
                }
                Divider()
                if let selected = model.selectedPath {
                    Button {
                        PlatformServices.copyToPasteboard(selected)
                    } label: {
                        Label(String(localized: "Copy path"), systemImage: "doc.on.doc")
                    }
                    if let url = filesURL {
                        Link(destination: url) {
                            Label(String(localized: "Open on GitHub"), systemImage: "safari")
                        }
                    }
                }
            } label: {
                Label(String(localized: "More"), systemImage: "ellipsis")
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            let paths = filePaths
            let position = model.selectedPath.flatMap { paths.firstIndex(of: $0) }
            Button {
                model.moveFileSelection(by: -1)
            } label: {
                Label(String(localized: "Previous file"), systemImage: "chevron.up")
            }
            .disabled(position == nil || position == 0)
            Button {
                model.moveFileSelection(by: 1)
            } label: {
                Label(String(localized: "Next file"), systemImage: "chevron.down")
            }
            .disabled(position == nil || position == paths.count - 1)
            if let position {
                Text(String(localized: "\(position + 1) of \(paths.count)"))
                    .font(Theme.type(.footnote, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Spacer()
            if let selected = model.selectedPath {
                let isViewed = model.viewedPaths.contains(selected)
                Button {
                    let actions = environment.actions(for: model.session)
                    Task { await model.toggleViewed(path: selected, actions: actions) }
                } label: {
                    // An HStack rather than a `Label`: a bottom bar draws a label as its icon
                    // alone, and an empty circle by itself does not say "viewed".
                    HStack(spacing: 6) {
                        Image(systemName: isViewed ? "checkmark.circle.fill" : "circle")
                            .contentTransition(.symbolEffect(.replace))
                        Text(isViewed ? String(localized: "Viewed") : String(localized: "Mark viewed"))
                    }
                    .fixedSize()
                }
                .tint(isViewed ? Theme.success : nil)
                .disabled(environment.activity.isRunning(model.prID, .viewed))
                .sensoryFeedback(.selection, trigger: isViewed)
            }
        }
    }

    // MARK: - Helpers

    private var codeSize: CGFloat { baseCodeSize * textScale }

    /// The files in the list's order — the order next and previous walk.
    private var filePaths: [String] {
        model.buckets.flatMap { $0.files.map(\.file.path) }
    }

    private var composerBinding: Binding<ReviewModel.ComposerRequest?> {
        Binding(get: { model.composerRequest }, set: { model.composerRequest = $0 })
    }

    /// The pull request's Files tab on github.com. Not the file itself: GitHub's per-file anchor
    /// is a hash of the path, and a link that lands on the tab is better than a guessed anchor.
    private var filesURL: URL? {
        guard let summary = model.summary else { return nil }
        let base = AppConfig.pullRequestURL(owner: summary.repo.owner, name: summary.repo.name, number: summary.number)
        return URL(string: base.absoluteString + "/files")
    }

    /// Highlights the file off the main thread, once per (path, rows).
    private func highlight(_ content: DiffListContent) async {
        if highlights[content.path]?.lines(for: content.rows) != nil { return }
        let rows = content.rows, path = content.path
        let built = await Task.detached(priority: .userInitiated) {
            HighlightedDiff(rows: rows, path: path)
        }.value
        guard !Task.isCancelled else { return }
        highlights[path] = built
    }

    /// Scrolls to the line ``ReviewModel/revealLine`` names, when it is in this file.
    private func reveal(in content: DiffListContent, proxy: ScrollViewProxy) {
        guard let line = model.revealLine else { return }
        let index = content.rows.firstIndex {
            guard case .line(let row) = $0 else { return false }
            return DiffListContent.lineNumbers(of: row).head == line
        }
        guard let index else { return }
        proxy.scrollTo(index, anchor: .center)
    }

    /// The row's sentence, with the conversation phrased for a touch screen.
    ///
    /// The shared sentence (`DiffRowText.swift`) tells a keyboard reader to press Return to open a
    /// thread, which a phone has no key for, so the thread count is said here instead and the
    /// threads themselves are their own elements right after the row.
    private func spokenSentence(
        for row: PatchReconstructor.DiffRow,
        content: DiffListContent,
        threads: Int,
        drafts: Int
    ) -> String {
        SpokenRow.sentence([
            row.spokenSentence(draftCount: drafts, takesComment: content.anchor(for: row) != nil),
            threads == 0
                ? nil
                : threads == 1
                    ? String(localized: "1 comment thread.")
                    : String(localized: "\(threads) comment threads."),
        ])
    }

    private static func linesTitle(_ span: DiffLineRange.Span) -> String {
        if let start = span.startLine {
            return String(localized: "Lines \(start)–\(span.line)")
        }
        return String(localized: "Line \(span.line)")
    }

    private static func commentTitle(_ span: DiffLineRange.Span) -> String {
        if let start = span.startLine {
            return String(localized: "Comment on lines \(start)–\(span.line)")
        }
        return String(localized: "Comment on line \(span.line)")
    }

    private static func fileName(_ path: String) -> String {
        PhoneFilesScreen.fileName(path)
    }

    private static func ownNumber(of row: PatchReconstructor.DiffRow) -> Int? {
        guard case .line(let line) = row else { return nil }
        return DiffListContent.lineIdentity(of: line).line
    }

    private static func marker(for kind: PatchRow.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }
}

/// A row's width: the screen's when lines wrap, and at least the screen's — as wide as its
/// longest line — when they scroll sideways, so the wash and the change bar reach the edge.
private struct RowWidth: ViewModifier {
    var wraps: Bool
    var viewportWidth: CGFloat

    func body(content: Content) -> some View {
        if wraps {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: viewportWidth, alignment: .leading)
        }
    }
}

/// What hangs on each line of the file on screen: published threads and the reviewer's own
/// pending comments, by the side and line they are anchored to.
private struct LineNotes {
    struct Key: Hashable {
        var side: DiffSide
        var line: Int
    }

    var threads: [Key: [ReviewThread]] = [:]
    var drafts: [Key: [DraftComment]] = [:]

    @MainActor
    init(model: ReviewModel, content: DiffListContent) {
        // In "Since your review" only the head lines that changed between the rounds are real
        // lines of this document; a thread anywhere else would sit on padding. The Mac's
        // `bridgeThreads` draws the same line.
        let visible = model.roundView == .sinceReview ? model.selectedReconstruction?.commentableModifiedLines : nil
        for thread in model.threadsForSelectedFile {
            guard let line = thread.line, line >= 1 else { continue }
            if let visible, thread.side == .left || !visible.contains(line) { continue }
            threads[Key(side: thread.side, line: line), default: []].append(thread)
        }
        for draft in model.draft?.comments ?? [] where draft.path == content.path && draft.line >= 1 {
            drafts[Key(side: draft.side, line: draft.line), default: []].append(draft)
        }
    }
}
