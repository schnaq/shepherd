import Foundation

/// One line of an issue's acceptance criteria.
///
/// The text is the bullet's prose with its Markdown decoration removed, because it is both what
/// the card shows and what the matcher tokenises — a bullet that kept its backticks would match
/// on a token nobody wrote.
public struct AcceptanceBullet: Sendable, Codable, Hashable, Identifiable {
    /// The bullet's prose, decoration stripped and trimmed.
    public var text: String
    /// Whether the issue's author had ticked the box, or `nil` for a bullet that is not a checkbox.
    ///
    /// Read but deliberately **not** acted on: a ticked box means somebody said the work is done,
    /// which is a claim of the same kind as the pull request's own and not evidence about this
    /// diff. It travels with the bullet so a later feature — or a reader of the fixture tests —
    /// can see what the issue said.
    public var isChecked: Bool?

    /// Creates a bullet.
    /// - Parameters:
    ///   - text: The prose.
    ///   - isChecked: The checkbox state, when the bullet had a box.
    public init(text: String, isChecked: Bool? = nil) {
        self.text = text
        self.isChecked = isChecked
    }

    /// A bullet is identified by its text, which is unique within one extraction.
    public var id: String { text }
}

/// Reads the acceptance criteria out of an issue body with three documented passes (ADR 0026's
/// amendment, plan §2.A).
///
/// **Why three passes and not one pattern.** Issues are written by people, and the shape they
/// write acceptance criteria in falls into three populations that need different rules. Trying to
/// serve all three with one pattern would either find a checklist in every issue that happens to
/// contain a bullet, or find one in none.
///
/// 1. **Checkboxes, wherever they are.** `- [ ]` / `- [x]` is the one shape that says "this is a
///    list of things that have to be true" and cannot mean anything else, so it wins outright and
///    the heading above it is irrelevant.
/// 2. **The first list under an acceptance-ish heading.** With no checkbox, a heading (or a
///    `…:` label line) containing `acceptance`, `criteria`, `done`, `todo` or `requirements` is
///    the author saying where the criteria are, and the list under it is them.
/// 3. **The first list in the body.** With neither, the first list is the best available guess —
///    and it is a *guess*, which is why an unmentioned bullet is never a contradiction
///    (``EvidenceChecker``): the card may be reading a list of "files touched" as criteria, and a
///    ✗ over that would be Shepherd's mistake shown as the author's.
///
/// An issue with no list at all yields no bullets, and that is a real answer: the card then says
/// the criteria were not checked rather than reporting a checklist of nothing.
public enum AcceptanceCriteria {
    /// How many bullets one issue may contribute.
    ///
    /// Twelve is well past every acceptance list in this repository's own issues and short enough
    /// that the card stays a card. A longer list is truncated rather than refused, because the
    /// first twelve bullets of a twenty-bullet issue are still worth matching.
    public static let maximumBullets = 12

    /// The words a heading needs one of before the list under it counts as acceptance criteria.
    ///
    /// Matched case-insensitively against the heading's stripped text, as a substring, so
    /// "Acceptance criteria", "Definition of done", "TODO" and "Requirements" all qualify —
    /// and so does "Criteria" on its own, which is what half of them are actually called.
    public static let headingKeywords: [String] = [
        "acceptance", "criteria", "done", "todo", "requirements",
    ]

    /// Reads the acceptance bullets out of an issue body.
    /// - Parameter body: The issue body, as Markdown source.
    /// - Returns: The bullets in reading order, at most ``maximumBullets`` of them, empty when the
    ///   body holds no list Shepherd is willing to read as criteria.
    public static func bullets(from body: String) -> [AcceptanceBullet] {
        let lines = AcceptanceCriteria.lines(of: body)

        let checkboxes = lines.compactMap { line -> AcceptanceBullet? in
            guard let rest = listBody(of: line), let checked = checkboxMark(of: rest) else {
                return nil
            }
            return bullet(from: line, isChecked: checked)
        }
        if !checkboxes.isEmpty { return capped(checkboxes) }

        if let headed = headedList(in: lines), !headed.isEmpty { return capped(headed) }

        return capped(firstList(in: lines))
    }

    // MARK: - Passes

    /// The first list that follows a heading or label line naming acceptance criteria.
    private static func headedList(in lines: [String]) -> [AcceptanceBullet]? {
        for (index, line) in lines.enumerated() where isAcceptanceHeading(line) {
            let list = collectList(in: lines, from: index + 1, stoppingAtHeading: true)
            if !list.isEmpty { return list }
        }
        return nil
    }

    /// The first list anywhere in the body.
    private static func firstList(in lines: [String]) -> [AcceptanceBullet] {
        for index in lines.indices where listBody(of: lines[index]) != nil {
            return collectList(in: lines, from: index, stoppingAtHeading: false)
        }
        return []
    }

    /// Collects the run of list items starting at or after `start`.
    ///
    /// Blank lines inside the run are tolerated — a Markdown "loose" list has one between every
    /// item — but any other non-list line ends it, so the paragraph after a list is never read as
    /// part of it.
    /// - Parameters:
    ///   - lines: The body's lines.
    ///   - start: Where to begin looking.
    ///   - stoppingAtHeading: Whether a heading ends the run before any item has been found. Used
    ///     by the headed pass so a heading with no list under it does not borrow the next
    ///     section's list.
    /// - Returns: The bullets, in order.
    private static func collectList(
        in lines: [String],
        from start: Int,
        stoppingAtHeading: Bool
    ) -> [AcceptanceBullet] {
        var found: [AcceptanceBullet] = []
        var index = start
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if let rest = listBody(of: line) {
                found.append(bullet(from: line, isChecked: checkboxMark(of: rest)))
                index += 1
                continue
            }
            if stoppingAtHeading, found.isEmpty, isHeading(line) { return [] }
            break
        }
        return found
    }

    // MARK: - Line shapes

    private static func capped(_ bullets: [AcceptanceBullet]) -> [AcceptanceBullet] {
        var seen: Set<String> = []
        var result: [AcceptanceBullet] = []
        for bullet in bullets where !bullet.text.isEmpty {
            guard seen.insert(bullet.text).inserted else { continue }
            result.append(bullet)
            if result.count == maximumBullets { break }
        }
        return result
    }

    /// One bullet from one raw line: ``ClaimText/stripped(_:)`` for the markers, then the inline
    /// decoration.
    private static func bullet(from line: String, isChecked: Bool?) -> AcceptanceBullet {
        AcceptanceBullet(text: strippedInline(ClaimText.stripped(line)), isChecked: isChecked)
    }

    /// The body's lines, with everything inside a fenced code block blanked.
    ///
    /// An issue that quotes Markdown — a template, a "write it like this" example — has `- [ ]`
    /// lines in it that are about the *syntax*, and the checkbox pass would otherwise let them
    /// win outright over the real list. A fenced line becomes an empty one rather than
    /// disappearing, so a fence between two lists still ends the first (a blank line is what
    /// ends a list here) and nothing in the passes below has to know fences exist.
    private static func lines(of text: String) -> [String] {
        var fenceMarker: Character?
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { raw -> String in
                let line = String(raw)
                let trimmed = line.drop(while: { $0 == " " })
                if let marker = fenceMarker {
                    // Closing fence: the same character, at least three of them, nothing after.
                    if trimmed.hasPrefix(String(repeating: marker, count: 3)),
                       trimmed.allSatisfy({ $0 == marker || $0 == " " }) {
                        fenceMarker = nil
                    }
                    return ""
                }
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    fenceMarker = trimmed.first
                    return ""
                }
                return line
            }
    }

    /// The text after a `-` / `*` / `+` / `1.` / `1)` marker, or `nil` when the line is not a
    /// list item.
    ///
    /// Only a marker followed by whitespace counts, so `well-known` and `-42` are prose.
    static func listBody(of line: String) -> Substring? {
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            rest = rest.dropFirst()
        }
        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            let probe = rest.dropFirst()
            guard let next = probe.first, next == " " || next == "\t" else { return nil }
            return probe.drop(while: { $0 == " " || $0 == "\t" })
        }
        guard let first = rest.first, first.isNumber else { return nil }
        var probe = rest
        while let digit = probe.first, digit.isNumber {
            probe = probe.dropFirst()
        }
        guard let marker = probe.first, marker == "." || marker == ")" else { return nil }
        let after = probe.dropFirst()
        guard let next = after.first, next == " " || next == "\t" else { return nil }
        return after.drop(while: { $0 == " " || $0 == "\t" })
    }

    /// The checkbox state of a list item's body, or `nil` when it carries no box.
    static func checkboxMark(of rest: Substring) -> Bool? {
        guard rest.first == "[" else { return nil }
        let box = rest.dropFirst()
        guard let mark = box.first else { return nil }
        let checked: Bool
        switch mark {
        case " ": checked = false
        case "x", "X": checked = true
        default: return nil
        }
        let closing = box.dropFirst()
        guard closing.first == "]" else { return nil }
        let after = closing.dropFirst()
        // A box has to be followed by something: `- []` is not a checkbox and `- [x]` with no
        // text is a bullet with nothing to match.
        guard let next = after.first, next == " " || next == "\t" else { return nil }
        return checked
    }

    /// Whether a line is a Markdown ATX heading.
    static func isHeading(_ line: String) -> Bool {
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            rest = rest.dropFirst()
        }
        var hashes = 0
        while rest.first == "#", hashes < 6 {
            rest = rest.dropFirst()
            hashes += 1
        }
        guard hashes > 0, let next = rest.first, next == " " || next == "\t" else { return false }
        return true
    }

    /// Whether a line announces acceptance criteria.
    ///
    /// A heading, or a short line ending in `:` — `**Acceptance criteria:**` is written at least
    /// as often as `## Acceptance criteria`, and both are the author pointing at the list below.
    /// A line ending in `:` that is also a list item is not a label: it is the first bullet.
    static func isAcceptanceHeading(_ line: String) -> Bool {
        guard listBody(of: line) == nil else { return false }
        let text = strippedInline(ClaimText.stripped(line))
        guard !text.isEmpty else { return false }
        guard isHeading(line) || text.hasSuffix(":") else { return false }
        let lowered = text.lowercased()
        return headingKeywords.contains { lowered.contains($0) }
    }

    // MARK: - Inline decoration

    /// A bullet's text with the two bits of Markdown decoration that get in the matcher's way
    /// removed: a link's target, and code / bold markers.
    ///
    /// A lone `_` or `*` is deliberately **left alone**. `test_helper` and `*.spec.ts` occur in
    /// acceptance bullets a good deal more often than italics do, and removing the character
    /// would glue two tokens into one that appears nowhere in the pull request.
    /// - Parameter text: The bullet's prose, markers already stripped.
    /// - Returns: The prose, trimmed.
    static func strippedInline(_ text: String) -> String {
        var result = linkRewrite.applied(to: text)
        result = codeRewrite.applied(to: result)
        result = boldRewrite.applied(to: result)
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// `[text](url)` becomes `text`.
    private static let linkRewrite = InlineRewrite(#"\[([^\]\n]+)\]\([^)\n]*\)"#, template: "$1")
    /// Backticks come off.
    private static let codeRewrite = InlineRewrite("`", template: "")
    /// `**` and `__` come off; a single one of either does not.
    private static let boldRewrite = InlineRewrite(#"\*\*|__"#, template: "")
}

/// A compiled `NSRegularExpression` replacement, for the Markdown decoration a bullet loses.
///
/// The same three decisions ``ClaimPattern`` documents, for the same two runners: one engine that
/// behaves identically on Darwin and on `swift-corelibs-foundation`, compiled once into a static,
/// and a pattern that fails to compile leaves the text alone rather than crashing a card that
/// opens on every pull request.
struct InlineRewrite: @unchecked Sendable {
    private let regex: NSRegularExpression?
    private let template: String

    /// Compiles a replacement.
    /// - Parameters:
    ///   - pattern: The ICU regular expression.
    ///   - template: The replacement template, `$1` for the first capture group.
    init(_ pattern: String, template: String) {
        regex = try? NSRegularExpression(pattern: pattern, options: [])
        self.template = template
    }

    /// Applies the replacement everywhere it matches.
    /// - Parameter text: The text to rewrite.
    /// - Returns: The rewritten text, or `text` unchanged when the pattern did not compile.
    func applied(to text: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: whole,
            withTemplate: template
        )
    }
}

/// The on-device embeddings one acceptance match may use, when this Mac has them.
///
/// Passed in rather than computed here for the reason ADR 0019 gives for every split of this
/// shape: `ShepherdCore` may not import `NaturalLanguage`, so the *decision* is a pure function
/// and the app supplies the vectors. With no vectors the matcher is exactly the keyword pass,
/// which is the whole behaviour on a Mac without the model — a degraded state that is the same
/// code path rather than a second one.
public struct AcceptanceVectors: Sendable, Hashable {
    /// The vector of the pull request's evidence text.
    public var evidence: SearchVector
    /// One vector per bullet, keyed by ``AcceptanceBullet/text``.
    ///
    /// Keyed rather than parallel to the bullet array, so a bullet the model had nothing to say
    /// about is simply absent instead of shifting every vector after it by one.
    public var byBulletText: [String: SearchVector]

    /// Creates a vector set.
    /// - Parameters:
    ///   - evidence: The evidence text's vector.
    ///   - byBulletText: The bullets' vectors, keyed by their text.
    public init(evidence: SearchVector, byBulletText: [String: SearchVector]) {
        self.evidence = evidence
        self.byBulletText = byBulletText
    }
}

/// What one acceptance bullet is matched to, and why.
///
/// Two states, not three: **mentioned** or **not mentioned**. There is deliberately no
/// "contradicted" — Shepherd matched words, and the absence of a word is not evidence that the
/// work was not done (ADR 0026's amendment). The reason is an English sentence, like every other
/// evidence fact.
public struct AcceptanceMatch: Sendable, Codable, Hashable, Identifiable {
    /// The bullet.
    public var bullet: AcceptanceBullet
    /// Whether the pull request mentions it.
    public var mentioned: Bool
    /// Why, as one sentence — already ends in a full stop.
    public var reason: String

    /// Creates a match.
    /// - Parameters:
    ///   - bullet: The bullet.
    ///   - mentioned: Whether the pull request mentions it.
    ///   - reason: The one-sentence reason.
    public init(bullet: AcceptanceBullet, mentioned: Bool, reason: String) {
        self.bullet = bullet
        self.mentioned = mentioned
        self.reason = reason
    }

    /// A match is identified by its bullet.
    public var id: String { bullet.id }
}

/// Decides whether a pull request *mentions* an acceptance bullet — pure, deterministic, and
/// testable without a Mac (ADR 0026's amendment).
///
/// **Mentioned is not done.** The strongest claim this type makes is that the pull request talks
/// about the same thing the bullet does, and the whole reason the card can afford to run it
/// unattended is that the weakest answer it can give ("not mentioned") is a *question* rather
/// than an accusation. Two passes, in order:
///
/// 1. **Keyword overlap.** The bullet's distinctive words — lower-cased
///    ``SearchText/tokens(in:)`` of at least ``minimumTokenLength`` characters, minus
///    ``stopWords`` — against the tokens of the pull request's body, changed paths and commit
///    messages. At least ``minimumOverlap`` of them have to be there.
/// 2. **Cosine over the on-device embeddings**, when the app supplied vectors: at least
///    ``minimumSimilarity``. This is the pass that catches "the upload retries on a 503" against
///    "network failures are retried", where no word is shared at all.
///
/// **The thresholds, and why they are these numbers.**
///
/// - ``minimumOverlap`` is `0.4`. Acceptance bullets are short — four to eight words after the
///   stop list — so demanding a majority would need three of five words to be in a description
///   that legitimately paraphrases, and demanding one would let a single shared word like
///   "upload" mark every bullet of an upload issue as mentioned. Two of five is the point where
///   the answer stops being about one incidental word.
/// - ``minimumSimilarity`` is `0.6`, higher than the saved-reply suggester's `0.45`
///   (``SavedReplySuggester/minimumSimilarity``) and for the opposite reason. There, a shortlist
///   of two out of many replies only has to be *better* than the rest; here every bullet is
///   judged on its own, and a floor that low would mark two pieces of software-engineering prose
///   as related simply because they are both software-engineering prose.
/// - ``minimumTokenLength`` is `4`. Below it the tokens are `the`, `and`, `for`, `api`, `ci` —
///   either noise or so common in a diff that they match everything. Digits are dropped with
///   them, because `#142` appears in the description of every pull request that references the
///   issue and matching on it would mark every bullet as mentioned.
public enum AcceptanceMatcher {
    // MARK: - Thresholds

    /// The shortest word the matcher will look for.
    public static let minimumTokenLength = 4
    /// The share of a bullet's distinctive words that has to appear.
    public static let minimumOverlap = 0.4
    /// The cosine a bullet needs before the embeddings alone call it mentioned.
    public static let minimumSimilarity = 0.6
    /// How much of a pull request the evidence text may be.
    ///
    /// Twenty kilobytes is a long description plus a hundred paths plus a fix round of commit
    /// messages. The ceiling exists because the text is also what gets embedded, and one enormous
    /// pull request must not decide how long a card takes to appear.
    public static let evidenceBudgetBytes = 20_000
    /// How many of a bullet's matched words one reason names.
    static let namedWordLimit = 4

    /// The words that are dropped before matching even though they clear ``minimumTokenLength``.
    ///
    /// Short on purpose. This is not a general English stop list: it is the words that occur in
    /// nearly every acceptance bullet *and* in nearly every pull-request description, which is
    /// exactly the population that produces a match carrying no information. A word that is
    /// merely common ("upload", "parser") stays, because in a repository about uploads it is
    /// still what the bullet is about.
    public static let stopWords: Set<String> = [
        "about", "above", "after", "again", "also", "always", "been", "before", "being",
        "below", "both", "case", "cases", "code", "could", "does", "done", "each", "else",
        "even", "ever", "every", "from", "have", "here", "into", "just", "least", "less",
        "like", "made", "make", "many", "more", "most", "much", "must", "need", "needs",
        "only", "other", "over", "same", "shall", "should", "since", "some", "still",
        "such", "than", "that", "them", "then", "there", "these", "they", "this", "those",
        "thing", "things", "under", "upon", "used", "using", "very", "well", "were",
        "what", "when", "where", "which", "while", "will", "with", "within", "without",
        "would",
    ]

    // MARK: - Inputs

    /// The text one pull request is matched against: its description, its changed paths and its
    /// commit messages.
    ///
    /// Those three and not the hunks. A bullet is a *requirement*, and the words a requirement is
    /// written in appear in the prose an author writes about the change and in the paths they
    /// touched — a diff's added lines are code, where the same requirement is spelled in
    /// identifiers the bullet does not contain. Feeding the hunks in would raise the token count
    /// by two orders of magnitude and mark every bullet mentioned.
    /// - Parameter detail: The pull request.
    /// - Returns: The text, clamped to ``evidenceBudgetBytes``.
    public static func evidenceText(for detail: PullRequestDetail) -> String {
        var parts: [String] = [detail.summary.title, detail.bodyMarkdown]
        for file in detail.files {
            parts.append(file.path)
            if let previous = file.previousPath { parts.append(previous) }
        }
        for commit in detail.commits {
            parts.append(commit.messageHeadline)
            parts.append(commit.messageBody)
        }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        return SearchText.clamped(joined, toBytes: evidenceBudgetBytes)
    }

    /// A bullet's distinctive words, in order, without duplicates.
    /// - Parameter text: The bullet's prose.
    /// - Returns: The lower-cased tokens of at least ``minimumTokenLength`` letters that are not
    ///   in ``stopWords`` and are not all digits.
    public static func distinctiveWords(in text: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for token in SearchText.tokens(in: text) {
            guard token.count >= minimumTokenLength else { continue }
            guard !stopWords.contains(token) else { continue }
            guard token.contains(where: { !$0.isNumber }) else { continue }
            guard seen.insert(token).inserted else { continue }
            result.append(token)
        }
        return result
    }

    // MARK: - Matching

    /// Matches every bullet against one pull request's evidence text.
    /// - Parameters:
    ///   - bullets: The issue's acceptance bullets, in reading order.
    ///   - evidenceText: What the pull request says about itself — see ``evidenceText(for:)``.
    ///   - vectors: The on-device embeddings, when this Mac has them. `nil` runs the keyword pass
    ///     alone, which is the complete behaviour without the model.
    /// - Returns: One match per bullet, in the bullets' order.
    public static func match(
        bullets: [AcceptanceBullet],
        against evidenceText: String,
        vectors: AcceptanceVectors? = nil
    ) -> [AcceptanceMatch] {
        guard !bullets.isEmpty else { return [] }
        let haystack = Set(SearchText.tokens(in: evidenceText))

        return bullets.map { bullet -> AcceptanceMatch in
            let words = distinctiveWords(in: bullet.text)
            let present = words.filter { haystack.contains($0) }
            let similarity = vectors.flatMap { set in
                set.byBulletText[bullet.text].flatMap { set.evidence.cosineSimilarity(to: $0) }
            }

            if !words.isEmpty, Double(present.count) / Double(words.count) >= minimumOverlap {
                return AcceptanceMatch(
                    bullet: bullet,
                    mentioned: true,
                    reason: overlapReason(present: present, total: words.count)
                )
            }
            if let similarity, similarity >= minimumSimilarity {
                return AcceptanceMatch(
                    bullet: bullet,
                    mentioned: true,
                    reason: "The pull request reads as being about this (similarity \(formatted(similarity)))."
                )
            }
            if words.isEmpty {
                return AcceptanceMatch(
                    bullet: bullet,
                    mentioned: false,
                    reason: "This bullet has no distinctive word Shepherd could look for."
                )
            }
            return AcceptanceMatch(
                bullet: bullet,
                mentioned: false,
                reason: missReason(present: present, total: words.count, similarity: similarity)
            )
        }
    }

    // MARK: - Reasons

    /// "3 of 4 words in this bullet appear in the pull request: “retry”, “upload”, “timeout”."
    private static func overlapReason(present: [String], total: Int) -> String {
        let named = present.prefix(namedWordLimit).map { "“\($0)”" }.joined(separator: ", ")
        let ellipsis = present.count > namedWordLimit ? "\(named), …" : named
        return "\(present.count) of \(worded(total)) in this bullet \(appears(present.count)) in the pull request: \(ellipsis)."
    }

    /// "None of the 4 words in this bullet appear in the pull request."
    private static func missReason(present: [String], total: Int, similarity: Double?) -> String {
        let head: String
        if present.isEmpty, total == 1 {
            head = "The one distinctive word in this bullet does not appear in the pull request."
        } else if present.isEmpty {
            head = "None of the \(worded(total)) in this bullet appear in the pull request."
        } else {
            head = "Only \(present.count) of the \(worded(total)) in this bullet \(appears(present.count)) in the pull request."
        }
        guard let similarity else { return head }
        return "\(head) On-device similarity is \(formatted(similarity))."
    }

    /// "1 word" / "4 words" — so a reason reads as English at both ends of the range.
    private static func worded(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count) words"
    }

    /// The verb that agrees with a count of words.
    private static func appears(_ count: Int) -> String {
        count == 1 ? "appears" : "appear"
    }

    /// Two decimals, and always with a leading digit, so `0.60` never renders as `.6`.
    private static func formatted(_ similarity: Double) -> String {
        String(format: "%.2f", similarity)
    }
}
