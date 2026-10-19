/// Syntax spans and word-level changes for every row of one file's diff, computed in one pass.
///
/// What a native renderer draws on top of ``PatchReconstructor/Reconstruction/rows``: the Mac's
/// list and the iPhone companion's diff (ADR 0044) both read it. ADR 0034 keeps syntax colour and
/// word diff outside the renderers' shared contract, so neither changes which lines take a
/// comment or what a comment means.
///
/// A whole-file value on purpose: the tokenizer carries state from line to line, so a row cannot
/// be coloured on its own. Build it once per (file, round) off the main thread — a typical file
/// costs well under a millisecond, the worst rewrite measured (2,044 rows) about 13 ms on an M4.
public struct DiffHighlighting: Sendable, Hashable {
    /// Per row, parallel to `rows`: the coloured runs (empty for a hunk header).
    public var syntax: [[SyntaxSpan]]
    /// Per row, parallel to `rows`: the byte ranges that changed within a paired removed/added
    /// line. Usually empty — only a line ``IntraLineDiff`` judged an edit of another has any.
    public var changes: [[Range<Int>]]

    /// Highlights one file's reconstructed rows.
    ///
    /// Each side carries its own state: a removed line continues the base file, an added line the
    /// head file, a context line both. At every hunk the state restarts — at ``SyntaxState/normal``
    /// when the hunk opens the file, otherwise from ``SyntaxHighlighter/initialState(forHunk:language:)``,
    /// since what precedes the hunk is not in the patch.
    /// - Parameters:
    ///   - rows: The file's rows, as ``PatchReconstructor/reconstruct(patch:)`` returns them.
    ///   - language: The file's language.
    public init(rows: [PatchReconstructor.DiffRow], language: SourceLanguage) {
        syntax = Array(repeating: [], count: rows.count)
        changes = Array(repeating: [], count: rows.count)
        var base = SyntaxState.normal
        var head = SyntaxState.normal
        var removedRun: [Int] = []
        var addedRun: [Int] = []

        func flushRun() {
            for (old, new) in IntraLineDiff.pair(removed: removedRun, added: addedRun, text: { Self.text(rows[$0]) }) {
                changes[old.row] = old.ranges
                changes[new.row] = new.ranges
            }
            removedRun.removeAll(keepingCapacity: true)
            addedRun.removeAll(keepingCapacity: true)
        }

        for (index, row) in rows.enumerated() {
            switch row {
            case .hunk(let originalStart, let modifiedStart):
                flushRun()
                // A hunk at the top of the file has nothing before it to be inside of.
                let start = originalStart <= 1 && modifiedStart <= 1 ? .normal : SyntaxHighlighter.initialState(
                    forHunk: rows[(index + 1)...].lazy.prefix { if case .line = $0 { true } else { false } }.map(Self.text),
                    language: language)
                base = start; head = start
            case .line(let line):
                switch line.kind {
                case .removed:
                    if !addedRun.isEmpty { flushRun() }
                    removedRun.append(index)
                    syntax[index] = SyntaxHighlighter.tokenize(line.text, language: language, state: &base)
                case .added:
                    addedRun.append(index)
                    syntax[index] = SyntaxHighlighter.tokenize(line.text, language: language, state: &head)
                case .context:
                    flushRun()
                    syntax[index] = SyntaxHighlighter.tokenize(line.text, language: language, state: &head)
                    base = head
                }
            }
        }
        flushRun()
    }

    static func text(_ row: PatchReconstructor.DiffRow) -> String {
        if case .line(let line) = row { return line.text }
        return ""
    }
}

/// GitHub-style word highlighting inside a changed line, from the standard library's diff.
///
/// The rules follow what a reviewer expects from github.com: a removed line is paired with the
/// added line it is an edit of, tokens (words, whitespace runs, single punctuation) are diffed
/// with `CollectionDifference`, and a pair that shares too little is left unpaired. No custom
/// Myers: trimming the shared head and tail and interning tokens to `Int`s made the stdlib's diff
/// fast enough (414 ms across 206k rows of this repository's history, measured on an M4).
public enum IntraLineDiff {
    /// Lines longer than this are not word-diffed: a minified line is noise either way.
    static let maxLineBytes = 1_000
    /// How far ahead in the added run a removed line looks for its partner.
    static let lookahead = 4
    /// Above this many token pairs in the changed middle, skip the diff and mark it all.
    static let maxDiffCells = 4_096
    /// Similarity (difflib ratio over the non-indent text) for the pair to count as an edit.
    static let minSimilarity = 0.5

    /// One side of a paired edit: the row index and its changed byte ranges.
    struct Side: Sendable, Hashable {
        var row: Int
        var ranges: [Range<Int>]
    }

    /// Pairs each removed line with an added line it is an edit of, in order, and returns the
    /// changed ranges on both. A pair below the similarity bar is left unpaired — the whole-line
    /// wash already says "this is new" and confetti on top of it says nothing.
    // ponytail: greedy in-order pairing, 4-line lookahead, 8·min(n,m) diffs per run; a real
    // alignment (LCS over line similarities) if moved-and-edited lines start pairing wrongly.
    static func pair(removed: [Int], added: [Int], text: (Int) -> String) -> [(Side, Side)] {
        guard !removed.isEmpty, !added.isEmpty else { return [] }
        var result: [(Side, Side)] = []
        var next = 0
        // A budget of diffs per run, so 472 removed lines against 4 added ones (a deleted block
        // beside a small edit) costs 32 comparisons, not 1,900.
        var budget = 2 * lookahead * min(removed.count, added.count)
        for old in removed {
            guard next < added.count, budget > 0 else { break }
            for candidate in next..<min(added.count, next + lookahead) {
                budget -= 1
                if let (o, n) = changedRanges(old: text(old), new: text(added[candidate])) {
                    result.append((Side(row: old, ranges: o), Side(row: added[candidate], ranges: n)))
                    next = candidate + 1
                    break
                }
            }
        }
        return result
    }

    /// The changed byte ranges of two versions of one line, or `nil` when they are not similar
    /// enough to be one line edited.
    ///
    /// Similarity is difflib's ratio, 2·common / (lenA + lenB), over the text after the
    /// indentation, and must reach 0.5. Lines over 1,000 bytes are never paired.
    /// - Parameters:
    ///   - old: The removed line's text.
    ///   - new: The added line's text.
    /// - Returns: The changed UTF-8 byte ranges on each side, or `nil` for an unrelated pair.
    public static func changedRanges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        let a = Array(old.utf8), b = Array(new.utf8)
        guard a.count <= maxLineBytes, b.count <= maxLineBytes, a != b else { return nil }
        // Cheap exact bound first: unchanged bytes can never exceed the shared byte multiset, so a
        // pair that fails on the bag fails on the diff too — and skips the O(N·D) diff entirely.
        let indentA = a.prefix(while: SyntaxHighlighter.isSpace).count
        let indentB = b.prefix(while: SyntaxHighlighter.isSpace).count
        // difflib's ratio, 2·common / (lenA + lenB): an append (`foo(a)` → `foo(a, b: c)`) is
        // still an edit of the same line, which common/longest would reject.
        let total = (a.count - indentA) + (b.count - indentB)
        guard total > 0 else { return nil }
        var bag = [Int](repeating: 0, count: 256)
        for c in a { bag[Int(c)] += 1 }
        var shared = 0
        for c in b where bag[Int(c)] > 0 { bag[Int(c)] -= 1; shared += 1 }
        guard 2 * Double(shared - min(indentA, indentB)) / Double(total) >= minSimilarity else { return nil }
        let ta = tokens(a), tb = tokens(b)
        // Interned to Ints: the stdlib diff compares elements a lot, and Int `==` is ~3× cheaper
        // than comparing byte slices (measured: 13 µs vs 39 µs on a 35-token line pair).
        var ids: [ArraySlice<UInt8>: Int] = [:]
        func intern(_ word: ArraySlice<UInt8>) -> Int {
            if let id = ids[word] { return id }
            ids[word] = ids.count
            return ids.count - 1
        }
        let wa = ta.map { intern(a[$0]) }, wb = tb.map { intern(b[$0]) }
        // Trim the shared head and tail first: a typical edit touches one spot in the line, and
        // the stdlib's Myers diff then runs on a handful of tokens instead of the whole line.
        var head = 0
        while head < wa.count, head < wb.count, wa[head] == wb[head] { head += 1 }
        var tail = 0
        while tail < wa.count - head, tail < wb.count - head, wa[wa.count - 1 - tail] == wb[wb.count - 1 - tail] { tail += 1 }
        let midA = head..<(wa.count - tail), midB = head..<(wb.count - tail)
        var removedTokens = Set<Int>(), insertedTokens = Set<Int>()
        if midA.count * midB.count > maxDiffCells {
            // ponytail: too big to diff cheaply — the whole middle counts as changed.
            removedTokens.formUnion(midA); insertedTokens.formUnion(midB)
        } else {
            for change in Array(wb[midB]).difference(from: Array(wa[midA])) {
                switch change {
                case .remove(let offset, _, _): removedTokens.insert(head + offset)
                case .insert(let offset, _, _): insertedTokens.insert(head + offset)
                }
            }
        }
        // Similarity over what is not indentation: a re-indented, rewritten line shares its
        // leading spaces with anything and is still a different line.
        // A changed indent token is already left out by subtracting `indentA`; counting its
        // bytes as changed too would sink every re-indented edit (`    foo(a)` → `        foo(b)`).
        let changedA = removedTokens.reduce(0) { ta[$1].lowerBound < indentA ? $0 : $0 + ta[$1].count }
        let unchanged = (a.count - changedA) - indentA
        guard 2 * Double(max(0, unchanged)) / Double(total) >= minSimilarity else { return nil }
        return (merge(ta, removedTokens, a), merge(tb, insertedTokens, b))
    }

    /// Words (identifier runs), whitespace runs, and single punctuation bytes; a non-ASCII run
    /// stays inside its word, so a range never cuts a scalar.
    static func tokens(_ bytes: [UInt8]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < bytes.count {
            var j = i + 1
            if SyntaxHighlighter.isWordByte(bytes[i]) {
                while j < bytes.count, SyntaxHighlighter.isWordByte(bytes[j]) { j += 1 }
            } else if SyntaxHighlighter.isSpace(bytes[i]) {
                while j < bytes.count, SyntaxHighlighter.isSpace(bytes[j]) { j += 1 }
            }
            out.append(i..<j); i = j
        }
        return out
    }

    /// Changed tokens as ranges, with a lone whitespace token between two changes absorbed so
    /// `foo bar` → `baz qux` lights up as one run rather than two with a gap.
    static func merge(_ tokens: [Range<Int>], _ changed: Set<Int>, _ bytes: [UInt8]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for (index, range) in tokens.enumerated() where changed.contains(index) {
            if let last = out.last,
                last.upperBound == range.lowerBound
                    || (index >= 2 && changed.contains(index - 2) && tokens[index - 1].lowerBound == last.upperBound
                        && SyntaxHighlighter.isSpace(bytes[tokens[index - 1].lowerBound]))
            {
                out[out.count - 1] = last.lowerBound..<range.upperBound
            } else {
                out.append(range)
            }
        }
        return out
    }
}
