import Foundation

/// Reduces a CI job log to the region that explains the failure (plan §3.F).
///
/// This is the tier-1 half of "why is CI red?" and the reason the feature is possible on an
/// 8,192-token model at all: a `xcodebuild` log is a megabyte of compile lines with twenty
/// characters of answer in it, and the whole design problem is picking those twenty characters
/// without a model reading the megabyte first. So the reduction is deterministic, pure, and lives
/// here rather than in the tool that calls it — a rule about which lines matter can be wrong in a
/// way nobody notices (a digest that quietly drops the one `error:` line still looks plausible),
/// and it must be checkable on Linux against real log fixtures.
///
/// Five decisions, in the order they are applied:
///
/// 1. **Lines are cleaned before anything looks at them.** ANSI colour escapes and GitHub
///    Actions' per-line `2026-…Z ` timestamps carry no information for a model and cost a
///    quarter of the budget; a coloured `error:` would also fail a substring test that an
///    uncoloured one passes, which is the kind of bug that only shows up on somebody's real log.
/// 2. **The failing region is what matters, not the tail.** A `swift test` run prints the failure
///    in the middle and a summary afterwards, so "the last 200 lines" is the wrong window;
///    ``isFailureLine(_:)`` picks the lines that name a failure and ``contextLines`` lines on
///    either side come with them.
/// 3. **Repeats are dropped.** A compiler emits the same `error:` once per target and a test
///    runner repeats its assertion in its own summary. Keeping the first occurrence of each line
///    is what makes six identical errors cost one line instead of six.
/// 4. **When nothing matches, the end of the log is the honest answer.** A job killed by the
///    runner, or one whose tool nobody taught this type about, still has to produce something —
///    the last ``fallbackTailLines`` lines, and ``Result/matchedLines`` says `0` so a caller can
///    tell a *found* failure from a *shown* tail.
/// 5. **Over budget, the last matches win.** A build that failed twice failed for the reason it
///    printed last as often as not, and the first failure is usually the same message from a
///    different target. So lines are given up from the front.
///
/// The output is model-facing text and is therefore never localised — like every prompt in this
/// layer. What a reviewer reads about it is the tool's own summary line, built in the app target.
public enum LogDigest {
    // MARK: - Tunables

    /// How many lines that carry something are kept on either side of a failure line.
    ///
    /// Three, from the plan. It is what a compiler error needs — the source line it quotes and
    /// the caret under it — and small enough that ten scattered failures still fit.
    ///
    /// *Lines that carry something*: blank lines are selected along with their neighbours but do
    /// not count against the three, because a runner that pads its output with empty lines (npm's
    /// does, pytest's does) would otherwise spend a reviewer's context on nothing. This is the
    /// one place the rule differs from the plan's wording, and it only ever keeps *more* of the
    /// failing region than counting raw lines would.
    public static let contextLines = 3

    /// How many lines are shown when no line in the log names a failure.
    public static let fallbackTailLines = 40

    /// The share of a tier's characters one log digest may occupy.
    ///
    /// A fifth, which on the on-device tier is exactly the plan's cap: 20 % of
    /// ``TokenBudget/onDevice``'s 6,000 tokens is ~1,200 tokens of log. Expressing it as a share
    /// rather than as a constant is what lets the cloud rung — the one a reviewer explicitly asks
    /// for when the log did not fit — actually see more of the log rather than the same digest
    /// through a larger window.
    public static let budgetShare = 0.2

    /// A digest may always use this many characters, however small the tier's budget is.
    public static let minimumCharacters = 1_200

    /// The substrings that mark a line as naming a failure.
    ///
    /// Substring tests rather than a regular expression, deliberately: the set is the one the plan
    /// names, every member of it is a literal, and a pure `contains` walk needs no regex engine,
    /// no compilation, no `Sendable` gymnastics around a shared `NSRegularExpression`, and cannot
    /// behave differently on Linux than on a Mac. `** TEST FAILED **` is not listed because
    /// `FAILED` already matches it, and `Test Case … failed` cannot be a substring test at all —
    /// it is the one two-part case, handled in ``isFailureLine(_:)``.
    ///
    /// Case-sensitive, and both `error:` and `Error:` are listed, because that is the difference
    /// between a compiler diagnostic and a runner's own message and both are wanted — while a
    /// case-insensitive `error` would match every `--no-error-on-unmatched-pattern` flag in a
    /// command line.
    public static let failureMarkers = [
        "error:",
        "Error:",
        "FAILED",
        "FAIL ",
        "npm ERR!",
        "AssertionError",
        "Traceback",
        "panic:",
        "✘",
        "✗",
    ]

    // MARK: - The result

    /// A reduced log: the text a model gets, and what it cost.
    ///
    /// The three counts beside the text exist so that no reduction is silent. ``matchedLines``
    /// distinguishes "the log named a failure and here it is" from "nothing matched, so this is
    /// the end of the log"; ``totalLines`` is what the reviewer's summary line reports the
    /// reduction against; ``wasTruncated`` is `true` whenever the digest is not the whole log,
    /// which for any real CI log it is not.
    public struct Result: Sendable, Hashable {
        /// The reduced log, lines joined with newlines. Empty when there was nothing to show.
        public var text: String
        /// How many lines ``text`` holds.
        public var lineCount: Int
        /// How many of those lines name a failure. `0` means nothing matched and this is the tail.
        public var matchedLines: Int
        /// How many lines the log had.
        public var totalLines: Int
        /// Whether anything at all was left out — a dropped repeat included.
        public var wasTruncated: Bool

        /// Creates a result.
        /// - Parameters:
        ///   - text: The reduced log.
        ///   - lineCount: How many lines it holds.
        ///   - matchedLines: How many of them name a failure.
        ///   - totalLines: How many lines the log had.
        ///   - wasTruncated: Whether anything was left out.
        public init(
            text: String,
            lineCount: Int,
            matchedLines: Int,
            totalLines: Int,
            wasTruncated: Bool
        ) {
            self.text = text
            self.lineCount = lineCount
            self.matchedLines = matchedLines
            self.totalLines = totalLines
            self.wasTruncated = wasTruncated
        }

        /// Whether there is any log to show.
        public var isEmpty: Bool { text.isEmpty }

        /// Nothing at all — an empty log, or a caller with no budget.
        public static let empty = Result(
            text: "",
            lineCount: 0,
            matchedLines: 0,
            totalLines: 0,
            wasTruncated: false
        )
    }

    // MARK: - Reducing

    /// The characters one digest may use on a tier.
    /// - Parameter budget: The answering tier's budget.
    /// - Returns: The character limit, never below ``minimumCharacters``.
    public static func characterLimit(for budget: TokenBudget) -> Int {
        max(minimumCharacters, Int(Double(budget.maxCharacters) * budgetShare))
    }

    /// Reduces a log to the share of one tier's budget a log may have.
    /// - Parameters:
    ///   - log: The raw job log, as GitHub served it.
    ///   - budget: The answering tier's budget.
    /// - Returns: The digest.
    public static func reduce(_ log: String, budget: TokenBudget) -> Result {
        reduce(log, characterLimit: characterLimit(for: budget))
    }

    /// Reduces a log to a hard character limit.
    /// - Parameters:
    ///   - log: The raw job log, as GitHub served it.
    ///   - characterLimit: The most characters the digest may use. Zero or less yields
    ///     ``Result/empty`` rather than a negative-sized window.
    /// - Returns: The digest.
    public static func reduce(_ log: String, characterLimit: Int) -> Result {
        guard characterLimit > 0 else { return .empty }
        let raw = lines(in: log)
        guard !raw.isEmpty else { return .empty }
        let cleaned = raw.map { cleaning($0) }
        let total = cleaned.count

        var isMatch = [Bool](repeating: false, count: total)
        var isSelected = [Bool](repeating: false, count: total)
        for index in cleaned.indices where isFailureLine(cleaned[index]) {
            isMatch[index] = true
        }

        if isMatch.contains(true) {
            for index in isMatch.indices where isMatch[index] {
                isSelected[index] = true
                select(contextBefore: index, in: cleaned, into: &isSelected)
                select(contextAfter: index, in: cleaned, into: &isSelected)
            }
        } else {
            // Nothing named a failure: the end of the log is where a killed job's last words are.
            for index in max(0, total - fallbackTailLines)..<total { isSelected[index] = true }
        }

        var keptText: [String] = []
        var keptIsMatch: [Bool] = []
        var seen = Set<String>()
        var didDropAnything = false
        for index in cleaned.indices {
            // A blank line and a line already kept both cost a line of budget and carry nothing;
            // dropping them is what "deduplicates repeated lines" means in practice.
            guard isSelected[index], !cleaned[index].isEmpty, seen.insert(cleaned[index]).inserted
            else {
                didDropAnything = true
                continue
            }
            keptText.append(cleaned[index])
            keptIsMatch.append(isMatch[index])
        }
        guard !keptText.isEmpty else {
            return Result(
                text: "",
                lineCount: 0,
                matchedLines: 0,
                totalLines: total,
                wasTruncated: true
            )
        }

        // Over budget, the front goes: see decision 5 in the type's own documentation.
        var size = keptText.reduce(0) { $0 + $1.count + 1 }
        var start = 0
        while size > characterLimit, start < keptText.count - 1 {
            size -= keptText[start].count + 1
            start += 1
            didDropAnything = true
        }

        var text = keptText[start...].joined(separator: "\n")
        if text.count > characterLimit {
            // One line longer than the whole budget — a minified bundle, or a log with no
            // newlines in it at all. Its head is the half that says what happened.
            text = String(text.prefix(characterLimit))
            didDropAnything = true
        }
        return Result(
            text: text,
            lineCount: keptText.count - start,
            matchedLines: keptIsMatch[start...].filter { $0 }.count,
            totalLines: total,
            wasTruncated: didDropAnything
        )
    }

    // MARK: - The rules, one function each

    /// Selects up to ``contextLines`` lines that carry something *before* a failure line.
    /// - Parameters:
    ///   - index: The failure line's index.
    ///   - cleaned: Every cleaned line.
    ///   - isSelected: The selection to grow.
    private static func select(
        contextBefore index: Int,
        in cleaned: [String],
        into isSelected: inout [Bool]
    ) {
        var remaining = contextLines
        var cursor = index - 1
        while cursor >= 0, remaining > 0 {
            isSelected[cursor] = true
            if !cleaned[cursor].isEmpty { remaining -= 1 }
            cursor -= 1
        }
    }

    /// Selects up to ``contextLines`` lines that carry something *after* a failure line.
    /// - Parameters:
    ///   - index: The failure line's index.
    ///   - cleaned: Every cleaned line.
    ///   - isSelected: The selection to grow.
    private static func select(
        contextAfter index: Int,
        in cleaned: [String],
        into isSelected: inout [Bool]
    ) {
        var remaining = contextLines
        var cursor = index + 1
        while cursor < cleaned.count, remaining > 0 {
            isSelected[cursor] = true
            if !cleaned[cursor].isEmpty { remaining -= 1 }
            cursor += 1
        }
    }

    /// Whether one line names a failure.
    /// - Parameter line: The line, already cleaned.
    /// - Returns: `true` when the line is one of the ones worth keeping.
    public static func isFailureLine(_ line: String) -> Bool {
        for marker in failureMarkers where line.contains(marker) {
            return true
        }
        // `Test Case '…' failed (0.006 seconds).` — XCTest's own wording, and the one rule that
        // needs two parts: `Test Case` alone matches every passing test in the run.
        return line.contains("Test Case ") && line.contains("failed")
    }

    /// Splits a log into lines.
    ///
    /// `isNewline` rather than a split on `"\n"`, because a CI log arrives with all three line
    /// endings in it — `\r\n` from a Windows-built tool, and a bare `\r` from every progress
    /// spinner. Swift reads `\r\n` as one `Character`, so this handles all three, and a spinner's
    /// overwritten fragments become separate lines that deduplication then collapses.
    /// - Parameter log: The raw log.
    /// - Returns: The lines, without their terminators, and without the empty final element a
    ///   trailing newline would otherwise add.
    private static func lines(in log: String) -> [String] {
        var result = log
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        if result.last?.isEmpty == true { result.removeLast() }
        return result
    }

    /// Cleans one line: no escape sequences, no timestamp, no trailing whitespace.
    /// - Parameter line: The raw line.
    /// - Returns: The cleaned line.
    private static func cleaning(_ line: String) -> String {
        var text = strippingActionsTimestamp(strippingANSIEscapes(line))
        // Trailing only: leading indentation is how a test runner shows structure, and a diff of
        // a Python traceback without it is unreadable.
        while let last = text.last, last == " " || last == "\t" || last == "\r" {
            text.removeLast()
        }
        return text
    }

    /// Removes ANSI escape sequences.
    ///
    /// Written as a scanner rather than a regular expression for ``failureMarkers``' reason, and
    /// it handles the three shapes a CI log actually contains: `CSI` sequences (`ESC [ … m`, the
    /// colours), `OSC` sequences (`ESC ] … BEL`, which is how a runner sets the terminal title),
    /// and two-character escapes (`ESC ( B`).
    /// - Parameter line: The raw line.
    /// - Returns: The line with escape sequences removed.
    public static func strippingANSIEscapes(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        var result = ""
        result.reserveCapacity(line.count)
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            guard character == "\u{1B}" else {
                result.append(character)
                index = line.index(after: index)
                continue
            }
            index = line.index(after: index)
            guard index < line.endIndex else { break }
            switch line[index] {
            case "[":
                index = line.index(after: index)
                // A CSI sequence ends at its first byte in `@`–`~`; everything before that is
                // parameters and intermediates. A non-ASCII byte means the sequence was never
                // one, so scanning stops rather than eating the rest of the line.
                while index < line.endIndex {
                    guard let ascii = line[index].asciiValue else { break }
                    index = line.index(after: index)
                    if (0x40...0x7E).contains(ascii) { break }
                }
            case "]":
                index = line.index(after: index)
                while index < line.endIndex {
                    let terminator = line[index] == "\u{07}"
                    index = line.index(after: index)
                    if terminator { break }
                }
            default:
                index = line.index(after: index)
            }
        }
        return result
    }

    /// Removes GitHub Actions' per-line timestamp prefix.
    ///
    /// Every line of a downloaded Actions log starts with `2026-09-02T09:14:22.1234567Z ` — 29
    /// characters of no information, which on a 1,200-token budget is most of the budget. The
    /// shape is checked digit by digit rather than parsed as a date: a line that merely *starts*
    /// with something date-like (a test asserting on an ISO string, say) must keep its text.
    /// - Parameter line: The raw line.
    /// - Returns: The line without its timestamp, or unchanged when there is none.
    public static func strippingActionsTimestamp(_ line: String) -> String {
        guard let space = line.firstIndex(of: " ") else { return line }
        let head = line[line.startIndex..<space]
        // `2026-09-02T09:14:22Z` is the shortest form Actions writes, at exactly 20 characters.
        guard head.count >= 20, head.hasSuffix("Z"), head.contains("T") else { return line }
        let date = Array(head.prefix(10))
        guard date.count == 10,
              date[0].isNumber, date[1].isNumber, date[2].isNumber, date[3].isNumber,
              date[4] == "-", date[5].isNumber, date[6].isNumber,
              date[7] == "-", date[8].isNumber, date[9].isNumber
        else { return line }
        return String(line[line.index(after: space)...])
    }
}
