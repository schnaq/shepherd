import Foundation

/// One thing a pull request's description *says about itself*.
///
/// A claim is not a judgement and not a finding: it is a quoted sentence plus which of the four
/// shapes the maintainer named in the interview it belongs to (`docs/plans/agent-fleet.md` §2.A).
/// The quote travels with the kind because the card shows the reviewer's colleague's own words —
/// "Tests added" is Shepherd's category, "`swift test` passes locally" is what was written, and
/// only the second one is checkable by a human reading the card.
public struct Claim: Sendable, Codable, Hashable, Identifiable {
    /// The four claim shapes Shepherd checks.
    ///
    /// A closed set, deliberately. Each case exists because there is a *deterministic* way to look
    /// for evidence of it in a diff and in CI (``EvidenceChecker``); a fifth shape without one
    /// would be a line on the card that could only ever say "?".
    public enum Kind: Sendable, Codable, Hashable {
        /// "Tests added", "all tests pass", "ran the suite".
        case testsAdded
        /// "Only the parser changed", "just `Sources/Uploader/`", "no other changes".
        ///
        /// The module is the token the sentence named, verbatim — a path, a file name, a type name
        /// or a bare word. It is **empty** for "no other changes", which limits the scope without
        /// naming anything; the evidence for that claim can only describe what *was* touched.
        case scopeLimited(module: String)
        /// "No breaking changes", "backwards compatible".
        case noBreakingChanges
        /// "Fixes #142", "closes #7", or a bare `#142` in the first paragraph.
        case fixesIssue(number: Int)

        /// The key two claims of the same shape are considered the same claim by.
        ///
        /// Not `Hashable` on the whole case, because ``scopeLimited(module:)`` carries a token:
        /// "Only `Sources/Parser/` changed" and "no other changes" are two sentences making one
        /// claim about scope, and a card with both would ask the reviewer to read the same
        /// evidence twice. Issue references are the opposite — `#4` and `#5` are two claims — so
        /// the number is part of the key.
        public var dedupKey: String {
            switch self {
            case .testsAdded: return "tests"
            case .scopeLimited: return "scope"
            case .noBreakingChanges: return "breaking"
            case .fixesIssue(let number): return "issue-\(number)"
            }
        }

        /// The order claims appear on the card: tests, scope, breaking changes, issues.
        ///
        /// The interview's own order of "claims to check first", so the card reads the same way on
        /// every pull request.
        public var sortIndex: Int {
            switch self {
            case .testsAdded: return 0
            case .scopeLimited: return 1
            case .noBreakingChanges: return 2
            case .fixesIssue: return 3
            }
        }
    }

    /// Which pass read the claim out of the description (ADR 0026's tier-2 amendment).
    ///
    /// A property of the *claim* rather than of the report, because it is what one line of the
    /// card says about itself: a claim the patterns found is the card's ordinary content, and a
    /// claim the optional on-device pass added carries a "read by the model" tag beside its
    /// quote. Two cases and no third — there is one tier-2 pass, and it is on-device only
    /// (ADR 0026), so "which model" is not a question this type can be asked.
    public enum Origin: String, Sendable, Codable, Hashable, CaseIterable {
        /// ``ClaimExtractor``'s documented patterns: tier 1, deterministic, always run.
        case pattern
        /// The optional on-device pass, which only ever *adds* claims (ADR 0026's amendment).
        case model
    }

    /// Which shape this claim has.
    public var kind: Kind
    /// The sentence the claim was read from, verbatim, Markdown decoration stripped.
    public var quote: String
    /// Which pass read it.
    ///
    /// Defaulted to ``Origin/pattern`` in the initialiser, so the deterministic path — every
    /// call site in ``ClaimExtractor`` and every test written before tier 2 existed — says
    /// nothing about origin and means the same thing it always did.
    public var origin: Origin

    /// Creates a claim.
    /// - Parameters:
    ///   - kind: The claim's shape.
    ///   - quote: The sentence it was read from.
    ///   - origin: Which pass read it. Defaults to ``Origin/pattern``.
    public init(kind: Kind, quote: String, origin: Origin = .pattern) {
        self.kind = kind
        self.quote = quote
        self.origin = origin
    }

    /// A claim is identified by its shape, which is unique within one extraction.
    public var id: String { kind.dedupKey }

    /// Stable keys, so the encoded shape is not an accident of the property order.
    private enum CodingKeys: String, CodingKey {
        case kind
        case quote
        case origin
    }

    /// Decodes a claim, tolerating an absent ``origin``.
    ///
    /// A claim written down before tier 2 existed is a claim the patterns read, which is exactly
    /// what ``Origin/pattern`` means — so the key is optional on the way in rather than a
    /// migration. ``kind`` and ``quote`` are required: they *are* the claim.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        quote = try container.decode(String.self, forKey: .quote)
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin) ?? .pattern
    }
}

/// Reads the four claim shapes out of a pull-request description with documented patterns
/// (tier 1 of ADR 0007: deterministic, local, testable without a Mac).
///
/// **Why patterns and not a model.** The body is short, the four shapes are formulaic — agents in
/// particular write them the same way every time — and a card that opens unattended on every pull
/// request must not make a model call to do it (ADR 0007, ADR 0026). A tier-2 pass over the same
/// body, on-device only, is an additive later step that can *add* claims the patterns missed; it
/// is not a replacement for this, and nothing here depends on it.
///
/// **The patterns, in full.** All case-insensitive, all matched against a single sentence
/// (``ClaimText/sentences(in:)``), so a verb from the next bullet cannot complete a claim:
///
/// | Kind | Requires |
/// | --- | --- |
/// | ``Claim/Kind/testsAdded`` | a test noun (`test`, `tests`, `spec`, `specs`, `coverage`) **and** a verb of adding or running (`add`, `added`, `pass`, `passing`, `green`, `run`, `ran`, …), **and not** a negation directly in front of the noun ("no tests were added") |
/// | ``Claim/Kind/scopeLimited(module:)`` | `only`, `just` or `solely` followed by a module token (see ``module(after:)``) — or the fixed phrase "no other changes", which limits scope without naming a module |
/// | ``Claim/Kind/noBreakingChanges`` | `no breaking`, `non-breaking`, `backward(s) compatible`, `backward(s) compatibility` |
/// | ``Claim/Kind/fixesIssue(number:)`` | `fixes`/`closes`/`resolves`/`fix`/`close`/`resolve` then `#N` anywhere, or a bare `#N` in the first paragraph |
///
/// **What it deliberately does not do.** It does not interpret, negate or weigh: "no breaking
/// changes *yet*" is still a `noBreakingChanges` claim, because the card's job is to put the
/// sentence next to the evidence and let the reviewer read both. The one exception is the tests
/// negation, and it is there because "no tests needed here" is *so* common in small pull requests
/// that reading it as a claim that tests were added would make the card wrong on the pull requests
/// it matters least on.
public enum ClaimExtractor {
    // MARK: - Patterns

    /// A test noun. Word-bounded, so `latest` and `contest` are not tests.
    private static let testNoun = ClaimPattern(#"\b(?:tests?|specs?|coverage)\b"#)
    /// A verb of adding or running tests.
    private static let testVerb = ClaimPattern(
        #"\b(?:add|adds|added|adding|pass|passes|passing|passed|green|run|runs|ran|running)\b"#
    )
    /// "no tests", "without new specs", "didn't run the tests" — a claim about the *absence*.
    private static let testNegation = ClaimPattern(
        #"\b(?:no|not|without|never|didn'?t|couldn'?t|cannot|can'?t)\b\s+(?:new\s+|additional\s+|more\s+)?(?:tests?|specs?|coverage)\b"#
    )

    /// The scope-limiting adverbs.
    private static let scopeAdverb = ClaimPattern(#"\b(?:only|just|solely)\b"#)
    /// "no other changes" and its close relatives.
    private static let noOtherChanges = ClaimPattern(
        #"\bno\s+other\s+(?:changes?|files?|edits?|modifications?)\b"#
    )

    /// A backticked code span: the most reliable module token an author can give.
    private static let moduleBacktick = ClaimPattern(#"`([^`\n]{2,})`"#)
    /// A path with a separator in it, e.g. `Sources/Parser/`.
    private static let modulePath = ClaimPattern(#"\b([A-Za-z0-9_.\-]+/[A-Za-z0-9_./\-]*)"#)
    /// A file name with an extension, e.g. `project.yml`.
    private static let moduleFileName = ClaimPattern(#"\b([A-Za-z0-9_\-]+\.[A-Za-z]{1,10})\b"#)
    /// A CamelCase identifier, e.g. `GitHubClient`. Case-sensitive on purpose.
    private static let moduleCamelCase = ClaimPattern(
        #"\b([A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+)\b"#,
        caseInsensitive: false
    )
    /// "the parser", "the CLI" — a bare noun, which needs the explicit article to be a name.
    private static let moduleArticle = ClaimPattern(#"\bthe\s+([A-Za-z][A-Za-z0-9_\-]{2,})\b"#)

    /// Words that follow "the" without naming a module.
    ///
    /// Without this, "only the same files as before" would name a module called `same`, and the
    /// evidence line under it would be nonsense rather than "?".
    private static let moduleStopWords: Set<String> = [
        "same", "other", "following", "rest", "above", "below", "way", "thing", "things",
        "file", "files", "code", "change", "changes", "diff", "test", "tests", "repo",
        "repository", "project", "branch", "pull", "request", "one", "two", "three", "new",
        "old", "existing", "first", "last", "whole", "entire",
    ]

    /// A statement that nothing breaks.
    private static let breakingClaim = ClaimPattern(
        #"\b(?:no\s+breaking|non[-\s]?breaking|backwards?[-\s]compatible|backwards?\s+compatibility)\b"#
    )
    /// A labelled issue reference — GitHub's own closing keywords, plus their bare imperatives.
    private static let issueLabelled = ClaimPattern(
        #"\b(?:fixes|closes|resolves|fix|close|resolve)\s+#(\d+)\b"#
    )
    /// A bare `#42`. Only trusted inside the first paragraph.
    private static let issueBare = ClaimPattern(#"#(\d+)\b"#)

    // MARK: - Extraction

    /// Reads every claim out of a description.
    ///
    /// Deduplicated by ``Claim/Kind/dedupKey`` — the first sentence making a claim is the one
    /// quoted — and ordered by ``Claim/Kind/sortIndex``, then by issue number, then by where the
    /// sentence was found. The order is total, so two runs over the same body cannot produce two
    /// different cards.
    /// - Parameter body: The pull request's description, as Markdown source.
    /// - Returns: The claims, at most one per shape (and one per referenced issue number).
    public static func extract(from body: String) -> [Claim] {
        let all = ClaimText.sentences(in: body)
        guard !all.isEmpty else { return [] }
        let firstParagraph = Set(ClaimText.sentences(in: ClaimText.firstParagraph(of: body)))

        var found: [(claim: Claim, order: Int)] = []
        var seen: Set<String> = []
        func add(_ kind: Claim.Kind, _ quote: String, _ order: Int) {
            guard !seen.contains(kind.dedupKey) else { return }
            seen.insert(kind.dedupKey)
            found.append((claim: Claim(kind: kind, quote: quote), order: order))
        }

        for (order, sentence) in all.enumerated() {
            if testNoun.matches(sentence),
               testVerb.matches(sentence),
               !testNegation.matches(sentence) {
                add(.testsAdded, sentence, order)
            }

            if let adverb = scopeAdverb.firstRange(in: sentence),
               let named = ClaimExtractor.module(after: String(sentence[adverb.upperBound...])) {
                add(.scopeLimited(module: named), sentence, order)
            } else if noOtherChanges.matches(sentence) {
                // Scope without a name: the claim is real, and the evidence for it can only
                // report what the diff touches rather than compare it with anything.
                add(.scopeLimited(module: ""), sentence, order)
            }

            if breakingClaim.matches(sentence) {
                add(.noBreakingChanges, sentence, order)
            }

            for number in issueLabelled.captures(in: sentence).compactMap({ Int($0) }) {
                add(.fixesIssue(number: number), sentence, order)
            }
            if firstParagraph.contains(sentence) {
                for number in issueBare.captures(in: sentence).compactMap({ Int($0) }) {
                    add(.fixesIssue(number: number), sentence, order)
                }
            }
        }

        return found
            .sorted { lhs, rhs in
                if lhs.claim.kind.sortIndex != rhs.claim.kind.sortIndex {
                    return lhs.claim.kind.sortIndex < rhs.claim.kind.sortIndex
                }
                if case .fixesIssue(let left) = lhs.claim.kind,
                   case .fixesIssue(let right) = rhs.claim.kind,
                   left != right {
                    return left < right
                }
                return lhs.order < rhs.order
            }
            // A tuple has no key path, so this is a closure rather than `\.claim`.
            .map { $0.claim }
    }

    /// The module token a scope claim names, from the text after `only` / `just` / `solely`.
    ///
    /// The order is a confidence order, most specific first: a backticked span is what the author
    /// chose to mark as code, a path with a `/` in it cannot be anything else, a file name with an
    /// extension is nearly as good, a CamelCase word is a type or a module by convention, and
    /// "the *word*" is the last resort — which is why it alone needs an article and a stop list.
    /// - Parameter text: The rest of the sentence after the scope adverb.
    /// - Returns: The token, trailing separators trimmed, or `nil` when the sentence limits
    ///   scope without naming anything Shepherd could match against a path.
    static func module(after text: String) -> String? {
        for pattern in [moduleBacktick, modulePath, moduleFileName, moduleCamelCase] {
            guard let raw = pattern.firstCapture(in: text) else { continue }
            let token = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if token.count >= 2 { return token }
        }
        guard let word = moduleArticle.firstCapture(in: text),
              !moduleStopWords.contains(word.lowercased())
        else { return nil }
        return word
    }
}
