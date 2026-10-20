import ShepherdCore
import SwiftUI

/// The colours of syntax highlighting, for both native renderers (ADR 0044).
///
/// Monaco's palette (`web/diff-viewer/src/viewer/themes.ts`, GitHub's colours), so the Mac's two
/// renderers mostly agree on what a keyword looks like — with the light keyword, type, comment
/// and annotation colours and the dark comment colour darkened or lifted until every kind reads
/// at **4.5:1 or better** (ADR 0033) on every background a native row can have: the window
/// background, the added and removed row washes, the selection, and each of those under a
/// word highlight. Measured, compositing exactly what the rows draw
/// (`Theme.background` → wash `tint × 0.13 × 0.6` or `Theme.selection` → word `tint ×`
/// ``wordHighlightOpacity``): the worst pair is 4.86:1 in light mode (tag green in a word
/// highlight on a selected removed row) and 4.56:1 in dark (keyword red in a word highlight on a
/// selected added row). A colour changed here has to be measured again against those layers.
///
/// Plain text is not in the table: it keeps whatever foreground the row's `Text` already has,
/// which is `Theme.text`.
extension Theme {
    /// The colour of one kind of token.
    /// - Parameter kind: What the tokenizer called the run.
    static func syntax(_ kind: SyntaxKind) -> Color {
        switch kind {
        case .keyword: return .shepherd(dark: 0xFF7B72, light: 0xA0111F)
        case .type: return .shepherd(dark: 0xFFA657, light: 0x7A3500)
        case .string: return .shepherd(dark: 0xA5D6FF, light: 0x0A3069)
        case .comment: return .shepherd(dark: 0xA8AFBF, light: 0x4A515B)
        case .literal, .property: return .shepherd(dark: 0x79C0FF, light: 0x0550AE)
        case .annotation: return .shepherd(dark: 0xD2A8FF, light: 0x6534B0)
        case .tag: return .shepherd(dark: 0x7EE787, light: 0x116329)
        }
    }

    /// How strongly a changed word is tinted, on top of its row's wash.
    ///
    /// The highest value at which the palette above still holds 4.5:1 with some margin; GitHub's
    /// own word tint is stronger, but GitHub's code colours are lighter than the contrast bar
    /// allows on these backgrounds.
    static let wordHighlightOpacity = 0.18
}

/// One file's diff rows, coloured: syntax spans and word-level changes turned into one
/// `AttributedString` per line (ADR 0044).
///
/// Built once per file off the main thread (``build(rows:path:)``) — tokenizing a whole file is
/// a single pass because the tokenizer carries state from line to line
/// (``ShepherdCore/DiffHighlighting``) — and kept with the rows it was built from. A renderer asks
/// ``lines(for:path:)`` with the rows and the path it is about to draw and gets `nil` for anything
/// else, so a highlight can never be painted onto a different file or round whose rows merely
/// happen to be as many — or the same rows in another language, two new files with one line each. Not part of `DiffListContent`: that
/// value is `Hashable` and compared on every body pass, and comparing span arrays there would
/// cost more than drawing the rows.
struct HighlightedDiff: Sendable {
    /// The rows this was built from.
    let rows: [PatchReconstructor.DiffRow]
    /// The path this was built for, which picked the language.
    let path: String
    /// One coloured line per row, `nil` for a hunk header.
    private let attributed: [AttributedString?]

    /// Files longer than this stay plain: the colour is a nicety, and a file this long is a
    /// generated one or a rewrite nobody reads line by line — not worth a long pass and the
    /// memory of a coloured copy per row (the iPhone keeps one per file it has shown).
    static let rowLimit = 4_000

    /// Colours a file's rows off the caller's actor, so a renderer awaits it from its `.task`
    /// and a file switch — which cancels that task — stops the pass rather than leaving it to
    /// run to the end (the Mac's j/k walks through files faster than a long file colours).
    /// - Parameters:
    ///   - rows: The rows to colour.
    ///   - path: The file's path, which picks the language.
    /// - Returns: The coloured rows, or `nil` for a file over ``rowLimit`` and for a pass that
    ///   was cancelled.
    @concurrent
    static func build(rows: [PatchReconstructor.DiffRow], path: String) async -> HighlightedDiff? {
        guard rows.count <= rowLimit else { return nil }
        let highlighting = DiffHighlighting(rows: rows, language: SourceLanguage(path: path))
        // The tokenizer is one uninterruptible pass; the per-line strings after it are the other
        // half of the cost, and a cancelled file need not pay it.
        guard !Task.isCancelled else { return nil }
        return HighlightedDiff(rows: rows, path: path, highlighting: highlighting)
    }

    private init(rows: [PatchReconstructor.DiffRow], path: String, highlighting: DiffHighlighting) {
        self.rows = rows
        self.path = path
        attributed = rows.indices.map { index in
            guard case .line(let row) = rows[index] else { return nil }
            return SyntaxStyle.attributed(
                row.text,
                syntax: highlighting.syntax[index],
                changes: highlighting.changes[index],
                tint: SyntaxStyle.tint(for: row.kind)
            )
        }
    }

    /// The coloured lines, when these are the rows and the file they were built from.
    /// - Parameters:
    ///   - rows: The rows about to be drawn.
    ///   - path: The file they belong to.
    /// - Returns: One line per row, or `nil` for any other rows or file.
    func lines(for rows: [PatchReconstructor.DiffRow], path: String) -> [AttributedString?]? {
        // Equal arrays that share a buffer compare in O(1), which is the common case: the rows
        // come out of `ReviewModel`'s reconstruction memo.
        self.path == path && self.rows == rows ? attributed : nil
    }
}

/// Turns one line's spans into an `AttributedString`.
enum SyntaxStyle {
    /// The colour that marks a row's kind, `nil` for a context row. The same pair the native
    /// rows' marker and wash use, so a word highlight is a stronger shade of its row.
    /// - Parameter kind: The row's kind.
    static func tint(for kind: PatchRow.Kind) -> Color? {
        switch kind {
        case .added: return Theme.success
        case .removed: return Theme.failure
        case .context: return nil
        }
    }

    /// One line, coloured.
    ///
    /// The line is cut at the union of span and change boundaries — both are UTF-8 byte offsets
    /// into the same text, and neither ever cuts a scalar — and each piece takes its token's
    /// colour and, inside a changed range, the word tint. Comments are italic through
    /// `inlinePresentationIntent` rather than a font, so the row's own font (and its Dynamic Type
    /// size) stays in charge.
    /// - Parameters:
    ///   - text: The line's text, without its diff marker.
    ///   - syntax: The coloured runs.
    ///   - changes: The byte ranges that changed within a paired edit.
    ///   - tint: The row's tint, or `nil` for a context row, which never has changes.
    /// - Returns: The line.
    static func attributed(
        _ text: String,
        syntax: [SyntaxSpan],
        changes: [Range<Int>],
        tint: Color?
    ) -> AttributedString {
        guard !syntax.isEmpty || !changes.isEmpty else { return AttributedString(text) }
        let bytes = Array(text.utf8)
        var cuts = Set([0, bytes.count])
        for span in syntax { cuts.insert(span.range.lowerBound); cuts.insert(span.range.upperBound) }
        for change in changes { cuts.insert(change.lowerBound); cuts.insert(change.upperBound) }
        let points = cuts.filter { $0 <= bytes.count }.sorted()
        var result = AttributedString()
        var spanIndex = 0
        for (start, end) in zip(points, points.dropFirst()) {
            var piece = AttributedString(String(decoding: bytes[start..<end], as: UTF8.self))
            // Spans are sorted and disjoint, so one forward cursor finds each piece's span.
            while spanIndex < syntax.count, syntax[spanIndex].range.upperBound <= start { spanIndex += 1 }
            if spanIndex < syntax.count, syntax[spanIndex].range.contains(start) {
                let kind = syntax[spanIndex].kind
                piece.foregroundColor = Theme.syntax(kind)
                if kind == .comment { piece.inlinePresentationIntent = .emphasized }
            }
            if let tint, changes.contains(where: { $0.contains(start) }) {
                piece.backgroundColor = tint.opacity(Theme.wordHighlightOpacity)
            }
            result.append(piece)
        }
        return result
    }
}
