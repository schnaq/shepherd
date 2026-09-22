import Foundation

/// What the model pointed at when a reviewer asked it to look closer at one claim (ADR 0026's
/// 2026-09-22 amendment, ADR 0038 item 2).
///
/// **Places, not a verdict.** A note is an excerpt of the diff and one sentence about it, and the
/// excerpt is the part that matters: ``verified(_:in:)`` keeps a note only when
/// ``DiffExcerpt/locate(_:inPatch:)`` finds it in that file's patch, so every line the card shows
/// under *Read by the model* is a line the reviewer can open and read themselves. The claim's
/// ✓ / ✗ / ? is untouched — it is still ``EvidenceChecker``'s, and nothing here can change it.
///
/// There is no confidence, no status and no aggregate on this type, for the reason
/// ``ClaimsEvidenceReport`` has none: a number beside a claim would be the first number on the card.
public struct ClaimCheck: Sendable, Hashable {
    /// One place in the diff and what the model said about it.
    public struct Note: Sendable, Hashable, Identifiable {
        /// The changed file, as the pull request spells it (the head-side path for a rename).
        public var path: String
        /// The lines of the diff the note is about, as the model copied them.
        public var excerpt: String
        /// One sentence about the excerpt, in the model's words.
        public var sentence: String
        /// The head-side line the excerpt starts at, or `nil` when that line was removed or the
        /// note has not been located yet.
        public var line: Int?
        /// The base-side line the excerpt starts at, once located — what tells two removed lines
        /// apart, since neither has a head-side line.
        public var baseLine: Int?

        public init(
            path: String,
            excerpt: String,
            sentence: String,
            line: Int? = nil,
            baseLine: Int? = nil
        ) {
            self.path = path
            self.excerpt = excerpt
            self.sentence = sentence
            self.line = line
            self.baseLine = baseLine
        }

        /// The place in the file: two notes about one place are one note, however the model
        /// spelled the excerpt.
        public var id: String {
            if let line { return "\(path):\(line)" }
            return "\(path):-\(baseLine ?? 0)"
        }
    }

    /// The most notes a card shows. Four places are something a reviewer opens one by one; a
    /// longer list is the model re-reading the diff aloud.
    public static let maximumNotes = 4

    /// The located notes, in the model's order.
    public var notes: [Note]
    /// Every read the model made, which the card shows beside the notes.
    public var trace: IntelligenceTrace

    public init(notes: [Note], trace: IntelligenceTrace = IntelligenceTrace()) {
        self.notes = notes
        self.trace = trace
    }

    /// The notes Shepherd could find in the diff itself, located, deduplicated and capped.
    ///
    /// A note is dropped — never repaired — when its file is not one this pull request changed,
    /// when its excerpt is not in that file's patch, or when it has no sentence. The file is found
    /// by its path or its previous path, and the kept note carries the head-side path.
    /// - Parameters:
    ///   - notes: What the model answered.
    ///   - files: The pull request's changed files, with their patches.
    /// - Returns: At most ``maximumNotes`` notes, each with ``Note/line`` set from the patch.
    public static func verified(_ notes: [Note], in files: [ChangedFile]) -> [Note] {
        var seen = Set<String>()
        var kept: [Note] = []
        for note in notes {
            guard kept.count < maximumNotes else { break }
            let sentence = note.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { continue }
            guard let file = files.first(where: { $0.path == note.path || $0.previousPath == note.path }),
                  let patch = file.patch,
                  let location = DiffExcerpt.locate(note.excerpt, inPatch: patch)
            else { continue }
            let located = Note(
                path: file.path,
                excerpt: DiffExcerpt.lines(of: note.excerpt).joined(separator: "\n"),
                sentence: sentence,
                line: location.line,
                baseLine: location.baseLine
            )
            guard seen.insert(located.id).inserted else { continue }
            kept.append(located)
        }
        return kept
    }
}

/// Finds lines a model quoted in a unified patch (ADR 0026's 2026-09-22 amendment).
///
/// The comparison is deliberately narrow: diff markers are ignored on both sides, runs of
/// whitespace count as one space, and **case counts** — code that differs in case is different
/// code. Every non-empty excerpt line has to match, in order, on consecutive rows of the patch
/// as ``PatchWalker`` reads it, because two lines that are each somewhere in the diff are not an
/// excerpt of it; blank lines are skipped on both sides, and a match never spans two hunks.
public enum DiffExcerpt {
    /// Where an excerpt starts.
    public struct Location: Sendable, Hashable {
        /// The head-side line of the first excerpt line, `nil` when it was removed.
        public var line: Int?
        /// The base-side line of the first excerpt line (for an added line, the base line it was
        /// inserted before).
        public var baseLine: Int

        public init(line: Int?, baseLine: Int) {
            self.line = line
            self.baseLine = baseLine
        }

        /// Whether the first excerpt line is a removed line.
        public var isRemoval: Bool { line == nil }
    }

    /// Where `excerpt` occurs in `patch`, or `nil` when it does not.
    /// - Parameters:
    ///   - excerpt: One or more lines, with or without their `+` / `-` markers.
    ///   - patch: A GitHub `files[].patch`.
    /// - Returns: The location of the first occurrence.
    public static func locate(_ excerpt: String, inPatch patch: String) -> Location? {
        let wanted = lines(of: excerpt).map(folded)
        guard !wanted.isEmpty else { return nil }
        let rows = PatchWalker.rows(in: patch)
        let hunk = hunkIndices(of: rows)
        // Blank rows are skipped on both sides: the excerpt's blank lines are dropped by
        // `lines(of:)`, so a blank row in the patch would otherwise break an excerpt that spans it.
        let candidates = rows.indices.filter { !folded(rows[$0].text).isEmpty }
        guard candidates.count >= wanted.count else { return nil }
        let contents = candidates.map { folded(rows[$0].text) }
        // Exact first, over the whole patch, and only then with a marker stripped — otherwise
        // `-1` quoted as code would match an earlier row reading `1`.
        for stripsMarker in [false, true] {
            for start in 0...(candidates.count - wanted.count) {
                let first = candidates[start]
                guard hunk[first] == hunk[candidates[start + wanted.count - 1]] else { continue }
                let matches = wanted.indices.allSatisfy { offset in
                    matchesLine(wanted[offset], contents[start + offset], strippingMarker: stripsMarker)
                }
                if matches {
                    let row = rows[first]
                    return Location(
                        line: row.kind == .removed ? nil : row.headLine,
                        baseLine: row.baseLine
                    )
                }
            }
        }
        return nil
    }

    /// Which hunk each row belongs to, from the line numbers alone: a row that does not continue
    /// the one before it starts a new hunk, because git never emits two hunks back to back.
    private static func hunkIndices(of rows: [PatchRow]) -> [Int] {
        var indices: [Int] = []
        var current = 0
        for (offset, row) in rows.enumerated() {
            if offset > 0 {
                let previous = rows[offset - 1]
                let base = previous.baseLine + (previous.kind == .added ? 0 : 1)
                let head = previous.headLine + (previous.kind == .removed ? 0 : 1)
                if row.baseLine != base || row.headLine != head { current += 1 }
            }
            indices.append(current)
        }
        return indices
    }

    /// The excerpt's non-empty lines, trimmed.
    static func lines(of excerpt: String) -> [String] {
        excerpt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether one folded excerpt line is one folded diff line — as written, or with a leading
    /// `+` / `-` the model copied from the diff stripped off.
    private static func matchesLine(
        _ wanted: String,
        _ target: String,
        strippingMarker: Bool
    ) -> Bool {
        guard strippingMarker else { return wanted == target }
        guard let marker = wanted.first, marker == "+" || marker == "-" else { return false }
        return folded(String(wanted.dropFirst())) == target
    }

    private static func folded(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}
