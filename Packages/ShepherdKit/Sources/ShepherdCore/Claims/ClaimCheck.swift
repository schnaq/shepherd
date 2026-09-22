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

        public init(path: String, excerpt: String, sentence: String, line: Int? = nil) {
            self.path = path
            self.excerpt = excerpt
            self.sentence = sentence
            self.line = line
        }

        /// The file and line, or the file and the excerpt's first line for a removal — two notes
        /// about one place are one note.
        public var id: String {
            if let line { return "\(path):\(line)" }
            return "\(path):-:\(DiffExcerpt.lines(of: excerpt).first ?? "")"
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
                line: location.line
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
/// code. Every non-empty excerpt line has to match, in order, on consecutive lines of one hunk,
/// because two lines that are each somewhere in the diff are not an excerpt of it.
public enum DiffExcerpt {
    /// Where an excerpt starts.
    public struct Location: Sendable, Hashable {
        /// The head-side line of the first excerpt line, `nil` when it was removed.
        public var line: Int?
        /// Whether the first excerpt line is a removed line.
        public var isRemoval: Bool

        public init(line: Int?, isRemoval: Bool) {
            self.line = line
            self.isRemoval = isRemoval
        }
    }

    /// Where `excerpt` occurs in `patch`, or `nil` when it does not.
    /// - Parameters:
    ///   - excerpt: One or more lines, with or without their `+` / `-` markers.
    ///   - patch: A GitHub `files[].patch`.
    /// - Returns: The location of the first occurrence.
    public static func locate(_ excerpt: String, inPatch patch: String) -> Location? {
        let wanted = lines(of: excerpt)
        guard !wanted.isEmpty else { return nil }
        for hunk in UnifiedPatch.hunks(in: patch) {
            let rows = rows(of: hunk)
            guard rows.count >= wanted.count else { continue }
            for start in 0...(rows.count - wanted.count) {
                let matches = wanted.indices.allSatisfy { offset in
                    matchesLine(wanted[offset], rows[start + offset].content)
                }
                if matches {
                    let first = rows[start]
                    return Location(line: first.headLine, isRemoval: first.headLine == nil)
                }
            }
        }
        return nil
    }

    /// The excerpt's non-empty lines, trimmed.
    static func lines(of excerpt: String) -> [String] {
        excerpt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private struct Row {
        var content: String
        var headLine: Int?
    }

    private static func rows(of hunk: UnifiedPatch.Hunk) -> [Row] {
        var head = hunk.modifiedStart
        var rows: [Row] = []
        for line in hunk.lines {
            switch line.first {
            case "+":
                rows.append(Row(content: String(line.dropFirst()), headLine: head))
                head += 1
            case "-":
                rows.append(Row(content: String(line.dropFirst()), headLine: nil))
            case "\\":
                continue
            case nil:
                rows.append(Row(content: "", headLine: head))
                head += 1
            default:
                rows.append(Row(content: String(line.dropFirst()), headLine: head))
                head += 1
            }
        }
        return rows
    }

    /// Whether one excerpt line is one diff line. The excerpt line is tried as written first and
    /// then without a leading marker, so `- item` in a Markdown diff still matches itself.
    private static func matchesLine(_ wanted: String, _ content: String) -> Bool {
        let target = folded(content)
        guard !target.isEmpty else { return false }
        if folded(wanted) == target { return true }
        guard let marker = wanted.first, marker == "+" || marker == "-" else { return false }
        return folded(String(wanted.dropFirst())) == target
    }

    private static func folded(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}
