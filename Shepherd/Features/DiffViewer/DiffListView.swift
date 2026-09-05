import ShepherdCore
import SwiftUI

/// The file a ``DiffListView`` is showing: the walkable rows, and the two sets that decide which
/// of them may carry a comment.
///
/// The same shape as ``DiffViewerContent`` and for the same reason — a renderer is handed a value
/// rather than reaching into the model — with one difference that matters. The sets are `Set<Int>`
/// here and sorted arrays there, because the bridge's JSON is defined in terms of arrays and a
/// list asks `contains` once per drawn row. They are the *same* sets: `ReviewModel`'s
/// `commentableLineSets(in:)` is where both come from, which is the first item of the contract in
/// `docs/plans/accessible-diff.md`. A padding line the reconstruction inserted between hunks is
/// unclickable in both renderers, because GitHub rejects a comment on one and rejects the whole
/// review along with it.
struct DiffListContent: Hashable, Sendable {
    /// The repository-relative path.
    var path: String
    /// The diff as hunk headers and lines, in reading order.
    var rows: [PatchReconstructor.DiffRow]
    /// Commentable base-side lines, already narrowed for the round being shown.
    var commentableLeft: Set<Int>
    /// Commentable head-side lines, already narrowed for the round being shown.
    var commentableRight: Set<Int>

    /// Which of the two numbers a row carries are the row's *own*.
    ///
    /// ``ShepherdCore/PatchRow`` fills both in on every row, and on a changed row one of them
    /// belongs to a different line: an added row's ``ShepherdCore/PatchRow/baseLine`` names the
    /// base line it sits *in front of*, and a removed row's ``ShepherdCore/PatchRow/headLine``
    /// the head line the deletion sits in front of. Both are useful facts about a *neighbour*,
    /// and neither is this row's number.
    ///
    /// Everything downstream is a reading of this one value: ``identity`` anchors a comment and
    /// names the line out loud, and ``DiffListView`` fills its two gutter columns from ``base``
    /// and ``head``. So the number a row shows, the number it announces and the number a comment
    /// on it lands on cannot come apart — which matters most in the last of the three, because a
    /// comment on a line outside the diff is one GitHub refuses along with the entire review.
    enum LineNumbers: Hashable, Sendable {
        /// An added row: it exists on the head side only, where it now is.
        case headOnly(Int)
        /// A removed row: it existed on the base side only, where it used to be.
        case baseOnly(Int)
        /// A context row: unchanged, so it is the same line on both sides and owns both numbers.
        case both(base: Int, head: Int)

        /// The row's own base-side number, or `nil` when it has none.
        var base: Int? {
            switch self {
            case .headOnly: return nil
            case .baseOnly(let line): return line
            case .both(let line, _): return line
            }
        }

        /// The row's own head-side number, or `nil` when it has none.
        var head: Int? {
            switch self {
            case .headOnly(let line): return line
            case .baseOnly: return nil
            case .both(_, let line): return line
            }
        }

        /// The one side the row *is*, and its number there.
        ///
        /// The head side whenever the row has a head-side number of its own: an added row is the
        /// line it now exists at, and a context row is read as the file as it will be, which is
        /// the document a review is written against. A removed row is the only row without one,
        /// and the base side is where it is.
        var identity: (side: DiffSide, line: Int) {
            switch self {
            case .headOnly(let line): return (.right, line)
            case .baseOnly(let line): return (.left, line)
            case .both(_, let head): return (.right, head)
            }
        }
    }

    /// Which of a row's two numbers are its own.
    ///
    /// The one switch. The rule is short and every case of it is load-bearing:
    ///
    /// | row | base | head |
    /// | --- | --- | --- |
    /// | added | none — it did not exist before | the line it now is |
    /// | removed | the line it used to be | none — it no longer exists |
    /// | context | the line it was | the line it still is |
    /// - Parameter row: The line.
    /// - Returns: The numbers it owns.
    static func lineNumbers(of row: PatchRow) -> LineNumbers {
        switch row.kind {
        case .added: return .headOnly(row.headLine)
        case .removed: return .baseOnly(row.baseLine)
        case .context: return .both(base: row.baseLine, head: row.headLine)
        }
    }

    /// Which side's line number a row *is*, before asking whether it may carry a comment.
    ///
    /// Kept as its own name because it is what a *comment* is anchored with and what the spoken
    /// sentence names the line by, and both read better for asking that question rather than for
    /// the pair; the answer itself comes from ``lineNumbers(of:)``, so there is still one switch
    /// deciding which of a row's two numbers belongs to it.
    /// - Parameter row: The line.
    /// - Returns: The side it lives on and its number there.
    static func lineIdentity(of row: PatchRow) -> (side: DiffSide, line: Int) {
        lineNumbers(of: row).identity
    }

    /// Where a comment on a row would be anchored, or `nil` when the row takes none.
    /// - Parameter row: The row the cursor is on.
    /// - Returns: The anchor, or `nil` for a hunk header and for a line this round does not
    ///   accept a comment on.
    func anchor(for row: PatchReconstructor.DiffRow) -> (side: DiffSide, line: Int)? {
        guard case .line(let patchRow) = row else { return nil }
        let identity = Self.lineIdentity(of: patchRow)
        let commentable = identity.side == .left ? commentableLeft : commentableRight
        return commentable.contains(identity.line) ? identity : nil
    }
}

/// The native diff: one row per line, walkable with the keyboard and announced one row at a time.
///
/// The second renderer beside Monaco (`docs/plans/accessible-diff.md`), not a replacement for it
/// and not a reimplementation of it. Syntax highlighting, word-level intra-line diffs, the
/// side-by-side layout, folding and the minimap are Monaco's and stay Monaco's; this earns its
/// place by being a linear, announced list of lines, which is the thing a `WKWebView` full of
/// canvas is worst at.
///
/// The construction is the inbox list's, deliberately: `ScrollViewReader` + `LazyVStack`, the
/// selection as a model property rather than a `List(selection:)` binding, `.focusable()` and
/// `.onKeyPress`. That is the house pattern for keyboard navigation, and following it means the
/// app's keyboard vocabulary needs no second definition here.
struct DiffListView: View {
    /// The review model — the selection, the threads and the draft all live there.
    let model: ReviewModel
    /// The file being drawn.
    let content: DiffListContent
    /// The monospaced size from Settings → Appearance → DIFF VIEWER.
    var fontSize: Double
    /// Whether a long line wraps rather than scrolling inside its row.
    var wraps: Bool
    /// The token that asks for the keyboard, raised by `c`, `[` and `]` on the native screen.
    ///
    /// The same counter Monaco's `focusRequest` reads, for the same reason: handing the focus over
    /// is an event, so asking twice has to arrive twice. `focusEditorSide` is not read — the list
    /// is one column and has no pane to name.
    var focusRequest: Int
    /// Hands the keyboard back to the file list, on escape.
    var onExit: () -> Void

    @FocusState private var isFocused: Bool

    /// A line on one side of the diff: what a thread or a draft comment hangs on.
    private struct LineKey: Hashable {
        var side: DiffSide
        var line: Int
    }

    var body: some View {
        // Counted once for the whole list rather than once per row: both are walks over the
        // file's threads and the reviewer's draft, and a diff has far more rows than either.
        let threads = threadCounts
        let drafts = draftCounts
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(content.rows.indices, id: \.self) { index in
                        row(at: index, threads: threads, drafts: drafts)
                            .id(index)
                    }
                }
            }
            .onChange(of: model.selectedDiffRow) { _, index in
                guard let index else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .background(Theme.background)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down) { press in
            handle(press)
        }
        // Deliberately no `.onAppear { isFocused = true }`, unlike the inbox list: the review
        // screen puts the keyboard in the file list when it opens, and a diff that grabbed the
        // focus from under it would break `j`/`k` on the files. The focus arrives when it is
        // asked for, which is what this token is.
        .onChange(of: focusRequest) { _, _ in
            isFocused = true
            // The first `c` hands the keyboard over and lands on a row; the second comments on
            // it — the same two steps the Monaco path has, so the key means one thing in the app.
            if model.selectedDiffRow == nil {
                model.moveDiffRowSelection(by: 1)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(at index: Int, threads: [LineKey: Int], drafts: [LineKey: Int]) -> some View {
        let value = content.rows[index]
        let isSelected = model.selectedDiffRow == index
        let counts = commentCounts(for: value, threads: threads, drafts: drafts)
        // Only a *published* thread is opened by clicking the indicator. The count beside it also
        // counts the reviewer's own drafts, and those are reached by the double-click below, which
        // opens the composer with the draft already in it — so a draft-only indicator has nothing
        // of its own to do and lets the click fall through to the row rather than eating it.
        let opensThreadAt: Int? = counts.threads > 0 ? index : nil
        Group {
            switch value {
            case .hunk(let originalStart, let modifiedStart):
                hunkRow(
                    originalStart: originalStart,
                    modifiedStart: modifiedStart,
                    isSelected: isSelected
                )
            case .line(let patchRow):
                lineRow(
                    patchRow,
                    isSelected: isSelected,
                    commentCount: counts.threads + counts.drafts,
                    opensThreadAt: opensThreadAt
                )
            }
        }
        .contentShape(Rectangle())
        // One tap picks the row, two open the composer on it: the inbox list's split, where a
        // click selects and a double-click opens what was selected. It is the mouse's way to the
        // composer, which the list otherwise had none of — Monaco has the gutter "+", and a
        // hover affordance here would be a second mechanism for a job this one already does.
        //
        // Declared before the single tap, as in the inbox list. The order is not cosmetic: the
        // gesture attached first is the one closer to the view, and a single tap recognised there
        // would end the sequence before a second click could arrive.
        .onTapGesture(count: 2) { comment(at: index) }
        .onTapGesture { select(index) }
        // One element per row, and the whole sentence as its label. Left alone, `.combine` reads
        // out two line numbers, a lone "+" and the code as separate things — and an
        // `.accessibilityLabel` beside it *replaces* what `.combine` produced rather than adding
        // to it, which is the trap ADR 0033 is about. So the label says the whole row.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                value.spokenSentence(
                    threadCount: counts.threads,
                    draftCount: counts.drafts,
                    // A hunk header takes no comment either, and its sentence says nothing about
                    // that: it is a place rather than a line, so there is nothing to explain.
                    takesComment: content.anchor(for: value) != nil
                )
            )
        )
        .accessibilityAddTraits(traits(isSelected: isSelected))
    }

    /// What hangs on the row's own line: published threads and the reviewer's own drafts.
    /// - Parameters:
    ///   - row: The row.
    ///   - threads: Threads by line.
    ///   - drafts: Draft comments by line.
    /// - Returns: The two counts, both zero for a hunk header.
    private func commentCounts(
        for row: PatchReconstructor.DiffRow,
        threads: [LineKey: Int],
        drafts: [LineKey: Int]
    ) -> (threads: Int, drafts: Int) {
        guard case .line(let patchRow) = row else { return (0, 0) }
        // The row's own side and number, from the same rule that anchors a comment on it: a
        // thread on a deleted line is a base-side thread, and looking it up on the head side
        // would quietly show none.
        let identity = DiffListContent.lineIdentity(of: patchRow)
        let key = LineKey(side: identity.side, line: identity.line)
        return (threads[key] ?? 0, drafts[key] ?? 0)
    }

    /// Says "selected" as well as showing it, because the tint and the accent bar are not facts
    /// a screen reader can see.
    /// - Parameter isSelected: Whether the cursor is on this row.
    /// - Returns: The traits to add.
    private func traits(isSelected: Bool) -> AccessibilityTraits {
        isSelected ? .isSelected : []
    }

    private func hunkRow(originalStart: Int, modifiedStart: Int, isSelected: Bool) -> some View {
        // The conventional `@@` form on screen, where it is a landmark a reader skims past; the
        // spoken label says the same thing in prose, because "at at minus twelve plus twelve" is
        // not a sentence.
        Text(verbatim: "@@ -\(originalStart) +\(modifiedStart) @@")
            .font(Theme.mono(smallSize, weight: .semibold))
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.selection : Theme.raised)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(Theme.accent).frame(width: 2)
                }
            }
    }

    private func lineRow(
        _ row: PatchRow,
        isSelected: Bool,
        commentCount: Int,
        opensThreadAt threadRow: Int?
    ) -> some View {
        // Top-aligned rather than baseline-aligned: a non-wrapping row's code sits inside its
        // own scroll view, which has no text baseline to align to, and a gutter a point smaller
        // than the code is what a code editor looks like anyway.
        HStack(alignment: .top, spacing: 0) {
            // A removed line has no head-side number of its own and an added line no base-side
            // one — `PatchRow` fills those in with the line the change sits *in front of*, which
            // is a useful fact and a different line, so the column stays blank rather than
            // printing somebody else's number as if it were this row's. Which is which is asked
            // rather than restated: it is the same rule that anchors a comment on the row, and a
            // second spelling of it here could quietly stop agreeing with the first.
            let numbers = DiffListContent.lineNumbers(of: row)
            number(numbers.base)
            number(numbers.head)
            Text(verbatim: marker(for: row.kind))
                .font(Theme.mono(CGFloat(fontSize), weight: .semibold))
                .foregroundStyle(markerTint(for: row.kind) ?? Theme.textMuted)
                .frame(width: 14, alignment: .center)
            code(row.text)
            commentIndicator(commentCount, opensThreadAt: threadRow)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(for: row.kind, isSelected: isSelected))
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.accent).frame(width: 2)
            }
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map { String($0) } ?? " ")
            .font(Theme.mono(smallSize))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 6)
    }

    @ViewBuilder
    private func code(_ text: String) -> some View {
        let line = Text(verbatim: text)
            .font(Theme.mono(CGFloat(fontSize)))
            .foregroundStyle(Theme.text)
        if wraps {
            line
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // The row scrolls, not the page: a four-hundred-character line must not widen the
            // review screen and push the file list off the window. `diffUsesInlineMode` has no
            // meaning here at all — a list of lines is already inline — so it is read by the
            // Monaco branch and ignored by this one rather than being given some second meaning.
            ScrollView(.horizontal) {
                line.fixedSize()
            }
            .scrollIndicators(.never)
            // A scroll view takes every point it is offered along its cross axis; this makes it
            // take the height of the one line it holds, so a row stays a row.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func commentIndicator(_ count: Int, opensThreadAt threadRow: Int?) -> some View {
        if count > 0 {
            let indicator = HStack(spacing: 3) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 9))
                Text(verbatim: "\(count)")
                    .font(Theme.mono(smallSize))
            }
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, 8)
            if let threadRow {
                // The indicator gets its own tap target rather than the row being made to mean two
                // things: clicking the bubble opens the conversation it is announcing. Attached
                // here, on a child of the row, so it takes the click ahead of the row's own
                // gestures — and only when there is a thread to open, so the rest of the time the
                // click falls through to selecting the row like any other part of it.
                indicator
                    .contentShape(Rectangle())
                    .onTapGesture { openThread(at: threadRow) }
            } else {
                indicator
            }
        }
    }

    // MARK: - Appearance

    /// The gutter's size: a step below the code, and never below nine points however far the
    /// diff's own size is turned down.
    private var smallSize: CGFloat { CGFloat(max(9, fontSize - 1)) }

    /// The character that carries the row's kind.
    ///
    /// Colour is never the only carrier (ADR 0033): the tint below says the same thing again for
    /// everyone who can see it, and this says it for everyone else — including a reviewer who
    /// simply cannot tell this app's green from its red.
    private func marker(for kind: PatchRow.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func markerTint(for kind: PatchRow.Kind) -> Color? {
        switch kind {
        case .added: return Theme.success
        case .removed: return Theme.failure
        case .context: return nil
        }
    }

    private func rowBackground(for kind: PatchRow.Kind, isSelected: Bool) -> Color {
        if isSelected { return Theme.selection }
        guard let tint = markerTint(for: kind) else { return .clear }
        return Theme.chipBackground(tint).opacity(0.6)
    }

    // MARK: - What hangs on a line

    /// Published threads by the line they are anchored to.
    ///
    /// Read from ``ReviewModel/threadsForSelectedFile`` rather than from `bridgeThreads`: that
    /// property renders every comment body into sanitised HTML for a web view, and a native row
    /// needs a count. Not going through it is one fewer HTML path in the app, which is a security
    /// simplification as much as a simpler view.
    private var threadCounts: [LineKey: Int] {
        var counts: [LineKey: Int] = [:]
        for thread in model.threadsForSelectedFile {
            guard let line = thread.line, line >= 1 else { continue }
            counts[LineKey(side: thread.side, line: line), default: 0] += 1
        }
        return counts
    }

    /// The reviewer's own unsent comments, by the line they are anchored to.
    private var draftCounts: [LineKey: Int] {
        var counts: [LineKey: Int] = [:]
        for comment in (model.draft?.comments ?? []) where comment.path == content.path {
            guard comment.line >= 1 else { continue }
            counts[LineKey(side: comment.side, line: comment.line), default: 0] += 1
        }
        return counts
    }

    // MARK: - Mouse

    /// A click picks the row *and* takes the keyboard, so the next `c` acts on what was clicked.
    /// - Parameter index: The row that was clicked.
    private func select(_ index: Int) {
        model.selectDiffRow(index)
        isFocused = true
    }

    /// What a double-click does: pick the row, then comment on it — the two steps `c` takes, in
    /// one gesture, so a reviewer with a mouse reaches the composer the way one with a keyboard
    /// does. A row that takes no comment does nothing, exactly as `c` does on it.
    /// - Parameter index: The row that was double-clicked.
    private func comment(at index: Int) {
        select(index)
        // The rows the list was drawn from can be replaced by a background refresh between the
        // draw and the click, and `selectDiffRow` refuses an index the new rows do not have.
        // Acting anyway would open the composer on whatever row the cursor was left standing on
        // rather than the one under the pointer.
        guard model.selectedDiffRow == index else { return }
        model.requestCommentOnSelectedRow()
    }

    /// What a click on the comment indicator does: pick the row, then open its thread.
    /// - Parameter index: The row whose indicator was clicked.
    private func openThread(at index: Int) {
        select(index)
        // The same stale-index guard as above, for the same reason: a thread opened here must be
        // the one belonging to the row that was clicked.
        guard model.selectedDiffRow == index else { return }
        model.openThreadOnSelectedRow()
    }

    // MARK: - Keyboard

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // "Open what is selected", which is what Return means in the inbox list — there a pull
        // request, here the conversation already hanging on the line. Without it a row announced
        // a thread it offered no way of reaching, which is the worse half of a missing feature.
        //
        // ⌘ is excluded for the inbox list's reason: ⇧⌘⏎ is "Start Review Session" in the Review
        // menu, and this must not read a menu shortcut as "open the row".
        //
        // Ignored rather than handled when the row carries no thread, so the key travels on
        // instead of being eaten by a view that had no answer for it — the same call the brackets
        // make below.
        if press.matches(.return), !press.modifiers.contains(.command) {
            return model.openThreadOnSelectedRow() ? .handled : .ignored
        }
        if press.matches(.downArrow) {
            model.moveDiffRowSelection(by: 1)
            return .handled
        }
        if press.matches(.upArrow) {
            model.moveDiffRowSelection(by: -1)
            return .handled
        }
        if press.matches(.escape) {
            onExit()
            return .handled
        }
        guard press.modifiers.isEmpty, let character = press.characters.first else {
            return .ignored
        }
        switch character {
        case "j":
            model.moveDiffRowSelection(by: 1)
            return .handled
        case "k":
            model.moveDiffRowSelection(by: -1)
            return .handled
        case "c":
            model.requestCommentOnSelectedRow()
            return .handled
        case "[", "]":
            // They mean "cross to the other pane", and a single-column list has no other pane.
            // Ignored rather than swallowed: a key this view has no answer for is better let go
            // of than eaten silently, which is the same call Monaco makes for the brackets in
            // inline mode (ADR 0033's third amendment).
            return .ignored
        default:
            return .ignored
        }
    }
}
