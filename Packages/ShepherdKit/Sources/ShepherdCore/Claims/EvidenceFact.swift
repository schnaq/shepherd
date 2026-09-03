import Foundation

/// One checkable fact about a pull request — as **data**, plus the English sentence it renders to.
///
/// A fact is never a judgement — "8 of 11 changed files are under “Sources/Parser”" is a fact,
/// "the scope claim is wrong" is not — because the whole point of the claims card is that the
/// reviewer draws the conclusion (ADR 0026, ADR 0007's "hints, never verdicts").
///
/// **The fact is a ``Kind``, not a string.** It was a pre-rendered English sentence until the
/// German catalog arrived (ADR 0022), and a sentence assembled in `ShepherdCore` is a sentence
/// no catalog can reach: this module is Foundation-only, has to keep compiling on Linux and may
/// not call `String(localized:)`. So the checker produces the *values* the sentence is made of —
/// counts, paths, an issue number, a code snippet, the matched words — and the two layers that
/// need prose render them:
///
/// - ``englishSentence`` here, pure and Linux-testable, which is what a log line, a test and the
///   *Turn into a comment* text (written to GitHub, in English) all use;
/// - `EvidenceFact.localizedSentence(bundle:)` in the app target, which is the same sentence
///   through `String(localized:)` with a German row.
///
/// The two are deliberately the same shape rather than the same code: the app's renderer may
/// split a sentence where German grammar needs it, and the English one may not drift, because it
/// is what a GitHub comment says.
///
/// ``path`` and ``line`` exist so a fact can be *checked in one click*: they are what the card
/// turns into a link into the diff viewer. A fact without a path is not a lesser fact; it is one
/// about the pull request as a whole ("CI is green: 7 of 7 checks passed").
public struct EvidenceFact: Sendable, Codable, Hashable, Identifiable {
    /// What the fact says, in the shape the sentence is derived from.
    public var kind: Kind
    /// The changed file the fact is about, when it is about one.
    public var path: String?
    /// The head-side line the fact is about, when it names one.
    ///
    /// Head-side, because that is the numbering the diff viewer and GitHub's review API speak
    /// (see ``PatchRow/headLine``). For a deleted line it is the line the deletion sits in front
    /// of, which is where a reviewer following the link needs to land.
    public var line: Int?
    /// A link out of the app, for a fact whose subject is not in the diff at all.
    ///
    /// Only the issue reference, which is a GitHub URL rather than a file: `#142`'s own page is
    /// where a reviewer checks what `#142` asked for, and it is the one place the card sends
    /// somebody outside the app.
    public var url: URL?
    /// Whether this fact is one item of a checklist Shepherd matched, and how it came out.
    ///
    /// `nil` for every fact about the diff and CI, and that is the distinction it exists to draw:
    /// those facts are statements about the pull request, while a marked fact is one *line of the
    /// referenced issue* with the answer to "is this mentioned" beside it. The card renders the
    /// mark as a glyph so a list of eight bullets reads as a list rather than as eight sentences
    /// (ADR 0026's amendment).
    ///
    /// There is deliberately no third case. A bullet nobody mentioned is not a contradiction —
    /// Shepherd matched words, and a missing word is a question, not a finding.
    public var mark: Mark?

    /// The two answers a matched checklist item can carry.
    public enum Mark: String, Sendable, Codable, Hashable, CaseIterable {
        /// The pull request mentions this item. ✓
        case mentioned
        /// It does not. ·
        case notMentioned
    }

    /// Every sentence the evidence checker can produce, with the values that fill it in.
    ///
    /// A closed set of templates, and that is the property both renderers depend on: a new fact
    /// is a new case, which fails to compile in the app until it has a sentence and a German row,
    /// rather than an English string that reaches a German screen unnoticed. The associated
    /// values are exactly what the sentence needs and nothing more — a path, a count, a token the
    /// author wrote, a snippet of somebody's code — and none of them are ever translated: they
    /// are quoted verbatim on both sides.
    ///
    /// Counts are carried as counts rather than as "1 file" / "3 files" strings, because that
    /// distinction is grammar and grammar belongs to the language: English needs two forms here
    /// and German needs two different ones (ADR 0022's plural rules).
    public enum Kind: Sendable, Codable, Hashable {
        // MARK: Tests

        /// No changed file matches a test naming convention.
        case noTestFileChanged
        /// `count` changed files do — the tally in front of the named ones.
        case testFilesChanged(count: Int)
        /// One named test file and its churn.
        case testFile(path: String, additions: Int, deletions: Int)
        /// A `-` row that removed an assertion, with the line and the code.
        case assertionRemoved(path: String, line: Int, snippet: String)
        /// A `+` row that added a skip, with the line and the code.
        case skippedTestAdded(path: String, line: Int, snippet: String)

        // MARK: CI

        /// The commit has no checks at all.
        case noChecksConfigured
        /// CI is green and the rollup carries no counts.
        case ciGreen
        /// CI is green, with the tally.
        case ciGreenCounted(passed: Int, total: Int)
        /// CI is red and the rollup carries no counts.
        case ciRed
        /// CI is red, with the tally.
        case ciRedCounted(failed: Int, total: Int)
        /// One named failing check.
        case checkFailed(name: String)
        /// CI has not finished and nothing is known about what is left.
        case ciUnfinished
        /// CI has not finished, with the number of checks still running.
        case ciUnfinishedRunning(count: Int)

        // MARK: Scope

        /// The pull request changes no file at all.
        case noChangedFiles
        /// The top-level paths the pull request touches: how many there are, and the first few.
        ///
        /// `paths` is already the limited, sorted prefix; `count` is the whole number of them, so
        /// a renderer knows to end the list in an ellipsis without being told twice.
        case topLevelPaths(count: Int, paths: [String])
        /// The scope claim named no module ("no other changes"), so there is nothing to match.
        case claimNamesNoModule
        /// No changed path contains the token the claim named.
        case noPathContainsToken(token: String)
        /// How many of the changed files are under the token the claim named.
        case filesUnderToken(inside: Int, total: Int, token: String)
        /// One named file outside the token the claim named.
        case fileOutsideToken(path: String, token: String)

        // MARK: Breaking changes

        /// A `-` row that removed or changed an exported declaration, with the line and the code.
        case exportedDeclarationChanged(path: String, line: Int, snippet: String)
        /// A manifest's version or dependency line changed.
        case manifestLineChanged(path: String)
        /// A schema definition or a migration changed.
        case schemaChanged(path: String)
        /// A CI workflow changed.
        case workflowChanged(path: String)
        /// A configuration file changed.
        case configurationChanged(path: String)
        /// Not one patch was readable, so nothing about declarations can be said.
        case noReadableDiff
        /// Nothing exported was removed or changed in the diff Shepherd did read.
        case noExportedDeclarationChanged

        // MARK: Classifications

        /// A dependency lockfile is in the diff.
        case lockfile(path: String)
        /// A generated or vendored file is in the diff.
        case generatedFile(path: String)
        /// A configuration file is in the diff.
        case configurationFile(path: String)

        // MARK: The referenced issue

        /// The reference itself: `#142` of `owner/repo`.
        case issueReferenced(number: Int, repo: String)
        /// The criteria were not checked, because the issue was not fetched.
        case issueNotFetched
        /// Why the issue could not be read, when it could not.
        case issueLookupFailed(IssueLookupFailure)
        /// `#N` turned out to be a pull request, which has no acceptance criteria.
        case referenceIsPullRequest(number: Int)
        /// The issue was read and its body holds no checklist Shepherd could use.
        case noAcceptanceChecklist
        /// The issue, its state and how many acceptance bullets it lists.
        ///
        /// "Issue #142 “Retry flaky uploads” is open and lists 3 acceptance bullets."
        ///
        /// `title` is empty when GitHub sent none, and ``IssueSummary/State/unknown`` is the state
        /// Shepherd does not model — both are rendered as *no state named* rather than as a
        /// sentence about Shepherd.
        case issueWithBullets(number: Int, title: String, state: IssueSummary.State, bulletCount: Int)
        /// Every acceptance bullet is mentioned.
        case everyBulletMentioned
        /// How many of the acceptance bullets are mentioned.
        case bulletsMentioned(mentioned: Int, total: Int)
        /// One acceptance bullet and why it came out mentioned or not.
        ///
        /// The bullet is the issue author's own line, quoted verbatim; the reason is the matcher's
        /// own structured answer, rendered by the same two renderers this type is.
        case acceptanceBullet(text: String, reason: AcceptanceMatch.Reason)
    }

    /// Creates a fact.
    /// - Parameters:
    ///   - kind: What the fact says.
    ///   - path: The changed file it is about, if any.
    ///   - line: The head-side line it names, if any.
    ///   - url: An external link, if any.
    ///   - mark: The checklist answer, for a fact that is one matched acceptance bullet.
    public init(
        kind: Kind,
        path: String? = nil,
        line: Int? = nil,
        url: URL? = nil,
        mark: Mark? = nil
    ) {
        self.kind = kind
        self.path = path
        self.line = line
        self.url = url
        self.mark = mark
    }

    /// The fact as one English sentence. Already ends in a full stop.
    ///
    /// The reading for logs, for tests and for a GitHub comment — never for the card, which reads
    /// the localised one. See ``Kind`` for why there are two.
    public var englishSentence: String { kind.englishSentence }

    /// A fact is identified by what it says and where.
    ///
    /// By the English sentence rather than by the case, because that is what it was before the
    /// fact became structured and it is still what makes two facts about the same file distinct:
    /// the identity has to change when the numbers in it do, and it is only ever a `ForEach` key.
    public var id: String {
        let lineKey: String
        if let line {
            lineKey = "\(line)"
        } else {
            lineKey = ""
        }
        return "\(englishSentence)|\(path ?? "")|\(lineKey)"
    }
}

extension EvidenceFact.Kind {
    /// The fact as one English sentence, assembled from its own values. Pure, and Linux-testable.
    ///
    /// This is the sentence the card showed before ADR 0022's follow-up and the sentence a
    /// *Turn into a comment* insertion still carries, because a review comment is written to
    /// GitHub and GitHub is read in English. It may therefore be *tested* word for word — and the
    /// app's German rendering of the same case may not be tested against it, because the two
    /// answer different questions.
    public var englishSentence: String {
        switch self {
        // MARK: Tests
        case .noTestFileChanged:
            return "No changed file matches a test naming convention."
        case .testFilesChanged(let count):
            return count == 1
                ? "1 changed file matches a test naming convention."
                : "\(count) changed files match a test naming convention."
        case .testFile(let path, let additions, let deletions):
            return "\(Self.quoted(path)) is a test file (+\(additions) −\(deletions))."
        case .assertionRemoved(let path, let line, let snippet):
            return "\(Self.quoted(path)) removes an assertion at line \(line): \(Self.quoted(snippet))."
        case .skippedTestAdded(let path, let line, let snippet):
            return "\(Self.quoted(path)) adds a skipped test at line \(line): \(Self.quoted(snippet))."

        // MARK: CI
        case .noChecksConfigured:
            return "No checks are configured for this commit."
        case .ciGreen:
            return "CI is green."
        case .ciGreenCounted(let passed, let total):
            return "CI is green: \(passed) of \(Self.counted(total)) passed."
        case .ciRed:
            return "CI is red."
        case .ciRedCounted(let failed, let total):
            return "CI is red: \(failed) of \(Self.counted(total)) failed."
        case .checkFailed(let name):
            return "Check \(Self.quoted(name)) failed."
        case .ciUnfinished:
            return "CI has not finished."
        case .ciUnfinishedRunning(let count):
            return count == 1
                ? "CI has not finished: 1 check is still running."
                : "CI has not finished: \(count) checks are still running."

        // MARK: Scope
        case .noChangedFiles:
            return "The pull request has no changed files."
        case .topLevelPaths(let count, let paths):
            let named = Self.list(paths, of: count)
            return count == 1
                ? "The pull request touches 1 top-level path: \(named)."
                : "The pull request touches \(count) top-level paths: \(named)."
        case .claimNamesNoModule:
            return "The claim names no module, so there is nothing to match the changed paths against."
        case .noPathContainsToken(let token):
            return "No changed path contains \(Self.quoted(token)), so the claim could not be matched to the diff."
        case .filesUnderToken(let inside, let total, let token):
            return "\(inside) of \(total) changed files are under \(Self.quoted(token))."
        case .fileOutsideToken(let path, let token):
            return "\(Self.quoted(path)) is outside \(Self.quoted(token))."

        // MARK: Breaking changes
        case .exportedDeclarationChanged(let path, let line, let snippet):
            return "\(Self.quoted(path)) removes or changes an exported declaration at line \(line): \(Self.quoted(snippet))."
        case .manifestLineChanged(let path):
            return "\(Self.quoted(path)) changes a version or dependency line."
        case .schemaChanged(let path):
            return "\(Self.quoted(path)) changes the database schema or a migration."
        case .workflowChanged(let path):
            return "\(Self.quoted(path)) changes a CI workflow."
        case .configurationChanged(let path):
            return "\(Self.quoted(path)) changes configuration."
        case .noReadableDiff:
            return "No diff was readable; GitHub sends no patch for binary files and for diffs it truncated."
        case .noExportedDeclarationChanged:
            return "No exported declaration is removed or changed in the diff Shepherd read."

        // MARK: Classifications
        case .lockfile(let path):
            return "\(Self.quoted(path)) is a dependency lockfile."
        case .generatedFile(let path):
            return "\(Self.quoted(path)) is a generated or vendored file."
        case .configurationFile(let path):
            return "\(Self.quoted(path)) is configuration."

        // MARK: The referenced issue
        case .issueReferenced(let number, let repo):
            return "Issue #\(number) of \(repo) is referenced."
        case .issueNotFetched:
            return "Acceptance criteria not checked — the issue is not fetched."
        case .issueLookupFailed(let failure):
            return failure.sentence
        case .referenceIsPullRequest(let number):
            return "#\(number) is a pull request rather than an issue, so it has no acceptance criteria."
        case .noAcceptanceChecklist:
            return "Acceptance criteria not checked — the issue body holds no checklist or list Shepherd could read."
        case .issueWithBullets(let number, let title, let state, let bulletCount):
            let listed = bulletCount == 1
                ? "lists 1 acceptance bullet"
                : "lists \(bulletCount) acceptance bullets"
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let named = trimmed.isEmpty
                ? "Issue #\(number)"
                : "Issue #\(number) \(Self.quoted(trimmed))"
            switch state {
            case .open:
                return "\(named) is open and \(listed)."
            case .closed:
                return "\(named) is closed and \(listed)."
            case .unknown:
                return "\(named) \(listed)."
            }
        case .everyBulletMentioned:
            return "Every acceptance bullet is mentioned in the pull request's description, changed paths or commit messages."
        case .bulletsMentioned(let mentioned, let total):
            return "\(mentioned) of \(total) acceptance bullets are mentioned in the pull request's description, changed paths or commit messages."
        case .acceptanceBullet(let text, let reason):
            return "\(Self.quoted(text)) — \(reason.englishSentence)"
        }
    }

    /// A fact quotes a path, a token or a line of code in typographic quotes.
    ///
    /// The same shape ``FilePrioritizer``'s reasons use, and not backticks: the card renders these
    /// as text, so a backtick would be a backtick on screen. The German rendering quotes the same
    /// values with „…“, which is why the quotation marks live in the *sentence* rather than
    /// around the value.
    /// - Parameter text: The value to quote, verbatim.
    /// - Returns: The value in typographic quotes.
    static func quoted(_ text: String) -> String { "“\(text)”" }

    /// "1 check" / "7 checks" — so a fact reads as English at both ends of the range.
    /// - Parameter checks: How many checks.
    /// - Returns: The count and the noun that agrees with it.
    static func counted(_ checks: Int) -> String {
        checks == 1 ? "1 check" : "\(checks) checks"
    }

    /// The named items of a capped list, ending in an ellipsis when there are more.
    /// - Parameters:
    ///   - items: The items to name — already the capped prefix.
    ///   - total: How many there are altogether.
    /// - Returns: The quoted items, comma-separated.
    static func list(_ items: [String], of total: Int) -> String {
        let named = items.map { quoted($0) }.joined(separator: ", ")
        return total > items.count ? "\(named), …" : named
    }
}
