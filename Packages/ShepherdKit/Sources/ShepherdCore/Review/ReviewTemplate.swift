import Foundation

/// A review summary the composer starts from, for the repositories a pattern matches.
///
/// Teams that review the same kind of change over and over want the same checklist every time —
/// "did the migration run backwards?", "is the changelog entry there?" — and typing it out is
/// exactly the sort of work Shepherd is supposed to remove. A template is therefore a *starting
/// point*, never a rewrite: it is only ever used to fill an empty draft (see
/// ``prefill(templates:repo:draft:summaryText:)``), and once the user has written anything at all
/// the template stays out of the way for good.
///
/// ``pattern`` is matched against ``RepoRef/fullName`` with ``GlobPattern``, so both shapes the
/// user reaches for work: `schnaq/review` for one repository and `schnaq/*` for everything an
/// owner has.
public struct ReviewTemplate: Sendable, Codable, Hashable, Identifiable {
    /// Stable identity, so editing the pattern keeps it the same row in Settings.
    public let id: UUID
    /// The `owner/name` pattern, with `*` and `?` as wildcards.
    public var pattern: String
    /// The Markdown source used as the summary of a new, empty review.
    public var body: String

    /// Creates a template.
    /// - Parameters:
    ///   - id: Stable identity. A fresh one by default.
    ///   - pattern: The `owner/name` pattern (`*` and `?` are wildcards).
    ///   - body: The Markdown summary to start from.
    public init(id: UUID = UUID(), pattern: String, body: String) {
        self.id = id
        self.pattern = pattern
        self.body = body
    }

    /// The pattern without surrounding whitespace.
    public var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The body without surrounding whitespace.
    public var trimmedBody: String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the template can ever do anything: it has a pattern to match and a body to insert.
    public var isUsable: Bool {
        !trimmedPattern.isEmpty && !trimmedBody.isEmpty
    }

    /// Whether the pattern names exactly one repository — no wildcard in it at all.
    public var isExact: Bool {
        !trimmedPattern.contains("*") && !trimmedPattern.contains("?")
    }

    /// How specific the pattern is: how many characters of it are literal rather than wildcard.
    ///
    /// The tie-breaker between two matching wildcard patterns, and the reason `schnaq/rev*` beats
    /// `schnaq/*` for `schnaq/review`: it says more about the repository it matched.
    public var specificity: Int {
        trimmedPattern.filter { $0 != "*" && $0 != "?" }.count
    }

    /// Whether this template applies to a repository.
    ///
    /// Case-insensitive, like every other repository comparison in the app: GitHub treats owner and
    /// repository names case-insensitively while preserving the casing it was given
    /// (``RepoRef/isSameRepository(as:)``), so `Schnaq/*` has to match `schnaq/review`.
    /// - Parameter repo: The repository under review.
    public func matches(_ repo: RepoRef) -> Bool {
        guard isUsable else { return false }
        return GlobPattern(trimmedPattern).matches(repo.fullName)
    }

    /// The one template that applies to a repository.
    ///
    /// Several patterns can match one repository (`schnaq/review`, `schnaq/*` and `*` all match
    /// `schnaq/review`), so the rule has to be stated rather than left to whatever the array order
    /// happens to be. In order:
    ///
    /// 1. **An exact pattern wins.** A template written for one repository beats any wildcard —
    ///    it is the more deliberate statement of the two.
    /// 2. **Otherwise the more specific wildcard wins**, measured as ``specificity``: the number of
    ///    literal characters in the pattern. `schnaq/rev*` beats `schnaq/*` beats `*`.
    /// 3. **Otherwise the one listed first wins.** The list order is the user's own — Settings lets
    ///    them move rows — so "the first one you put there" is an answer they can act on, and it is
    ///    stable across launches, unlike a dictionary order or an id comparison.
    ///
    /// Unusable templates (no pattern, or no body) never match at all.
    /// - Parameters:
    ///   - templates: The user's templates, in their own order.
    ///   - repo: The repository under review.
    /// - Returns: The winning template, or `nil` when none matches.
    public static func matching(_ templates: [ReviewTemplate], repo: RepoRef) -> ReviewTemplate? {
        var best: ReviewTemplate?
        for template in templates where template.matches(repo) {
            guard let current = best else {
                best = template
                continue
            }
            // Strictly better only — an equal candidate leaves the earlier one in place, which is
            // what makes rule 3 hold.
            if isBetter(template, than: current) {
                best = template
            }
        }
        return best
    }

    /// Rules 1 and 2 of ``matching(_:repo:)``, as one comparison.
    private static func isBetter(_ candidate: ReviewTemplate, than current: ReviewTemplate) -> Bool {
        if candidate.isExact != current.isExact { return candidate.isExact }
        return candidate.specificity > current.specificity
    }

    /// The summary text a *new* review should open with, if any.
    ///
    /// The whole safety property of the feature is in this function: a template may only ever fill
    /// something that is empty. Three conditions, all of which have to hold:
    ///
    /// - the composer's summary field is blank — the user has not typed anything, and a template
    ///   arriving on top of half a sentence would be a data-loss bug rather than a convenience;
    /// - there is no draft on disk, or the draft carries nothing at all (``ReviewDraft/isEmpty``):
    ///   no verdict, no inline comment, no summary. A draft with a single inline comment in it is a
    ///   review in progress and is left strictly alone, even though its summary happens to be
    ///   empty — the user may have deleted the template text on purpose;
    /// - a template matches this repository and has a body.
    ///
    /// It is a pure function of those values so that "can this overwrite my work?" is answered by a
    /// unit test rather than by reading the review screen's task ordering.
    /// - Parameters:
    ///   - templates: The user's templates.
    ///   - repo: The repository under review.
    ///   - draft: The locally stored draft for this pull request, if any.
    ///   - summaryText: What the composer's summary field holds right now.
    /// - Returns: The text to prefill, or `nil` when nothing may be prefilled.
    public static func prefill(
        templates: [ReviewTemplate],
        repo: RepoRef,
        draft: ReviewDraft?,
        summaryText: String
    ) -> String? {
        guard summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let draft, !draft.isEmpty { return nil }
        guard let template = matching(templates, repo: repo) else { return nil }
        let body = template.trimmedBody
        return body.isEmpty ? nil : body
    }
}
