import Foundation
import ShepherdCore

/// The German half of the claims card's evidence: one localised sentence per
/// ``ShepherdCore/EvidenceFact/Kind`` (ADR 0026's facts, ADR 0022's catalog).
///
/// This file exists because the two rules it sits between are both absolute.
/// `ShepherdCore` may not call `String(localized:)` — it is Foundation-only, it has to keep
/// compiling and testing on Linux, and it has no bundle to look a catalog up in — and every
/// user-visible string in Shepherd has to be a catalog key with a German row, or a German user
/// reads an English sentence and cannot tell it was not meant. So the checker produces
/// ``ShepherdCore/EvidenceFact/Kind`` values and this is the one place that turns them into prose
/// for the screen. Four properties of the translation are decisions rather than wording:
///
/// - **Paths, repository names, issue numbers, quoted words and code snippets are interpolated
///   verbatim.** They are somebody's file, somebody's identifier or somebody's line of code; a
///   translated path would be a wrong path.
/// - **The quotation marks belong to the sentence, not to the value.** Every key carries its own
///   `“…”`, so the German row can write „…“ (ADR 0022's typography) without any code deciding
///   what a quote looks like. The one key that is *nothing but* quotation marks
///   (`quoted(_:bundle:)`) exists for the one place a *list* of quoted paths is assembled.
/// - **Counts go through the catalog's plural rules where the count is the string's only
///   argument, and through two keys where it is not.** ADR 0022's rule: a top-level
///   `variations.plural` cannot say which argument it varies on, so a sentence with a count *and*
///   a path picks its key on `count == 1` instead — the shape
///   `DigestPresentation.line(for:)` already uses.
/// - **The review vocabulary stays English inside the German sentences**: pull request, review,
///   CI, check, commit, diff, merge, lockfile, Issue.
///
/// The English reading of the same fact lives in `ShepherdCore`
/// (``ShepherdCore/EvidenceFact/englishSentence``) and is *not* this: it is what a test asserts
/// on and what *Turn into a comment* writes into a review comment, because a comment is written
/// to GitHub and read in English. Where German grammar wants a different sentence shape, this
/// renderer is free to take it.
extension EvidenceFact {
    /// The fact as one localised sentence, ready to draw.
    /// - Parameter bundle: Where to look the catalog up. `Bundle.main` in the app; a test passes
    ///   the compiled `de.lproj` so that what it asserts cannot depend on the runner's language
    ///   (see `LocalizationTests`).
    /// - Returns: The sentence, in the bundle's language.
    func localizedSentence(bundle: Bundle = .main) -> String {
        kind.localizedSentence(bundle: bundle)
    }
}

extension EvidenceFact.Kind {
    /// The fact as one localised sentence.
    /// - Parameter bundle: Where to look the catalog up.
    /// - Returns: The sentence, in the bundle's language.
    func localizedSentence(bundle: Bundle = .main) -> String {
        switch self {
        // MARK: - Tests

        case .noTestFileChanged:
            return String(
                localized: "No changed file matches a test naming convention.",
                bundle: bundle
            )
        case .testFilesChanged(let count):
            return String(
                localized: "\(count) changed files match a test naming convention.",
                bundle: bundle
            )
        case .testFile(let path, let additions, let deletions):
            return String(
                localized: "“\(path)” is a test file (+\(additions) −\(deletions)).",
                bundle: bundle
            )
        case .assertionRemoved(let path, let line, let snippet):
            return String(
                localized: "“\(path)” removes an assertion at line \(line): “\(snippet)”.",
                bundle: bundle
            )
        case .skippedTestAdded(let path, let line, let snippet):
            return String(
                localized: "“\(path)” adds a skipped test at line \(line): “\(snippet)”.",
                bundle: bundle
            )

        // MARK: - CI

        case .noChecksConfigured:
            return String(localized: "No checks are configured for this commit.", bundle: bundle)
        case .ciGreen:
            return String(localized: "CI is green.", bundle: bundle)
        case .ciGreenCounted(let passedCount, let total):
            // Two keys rather than one plural entry: the sentence has two arguments, and a
            // top-level plural variation cannot say which of them it agrees with (ADR 0022).
            return total == 1
                ? String(localized: "CI is green: \(passedCount) of 1 check passed.", bundle: bundle)
                : String(
                    localized: "CI is green: \(passedCount) of \(total) checks passed.",
                    bundle: bundle
                )
        case .ciRed:
            return String(localized: "CI is red.", bundle: bundle)
        case .ciRedCounted(let failedCount, let total):
            return total == 1
                ? String(localized: "CI is red: \(failedCount) of 1 check failed.", bundle: bundle)
                : String(
                    localized: "CI is red: \(failedCount) of \(total) checks failed.",
                    bundle: bundle
                )
        case .checkFailed(let name):
            return String(localized: "Check “\(name)” failed.", bundle: bundle)
        case .ciUnfinished:
            return String(localized: "CI has not finished.", bundle: bundle)
        case .ciUnfinishedRunning(let count):
            return String(
                localized: "CI has not finished: \(count) checks are still running.",
                bundle: bundle
            )

        // MARK: - Scope

        case .noChangedFiles:
            return String(localized: "The pull request has no changed files.", bundle: bundle)
        case .topLevelPaths(let count, let paths):
            let named = Self.list(paths, of: count, bundle: bundle)
            return count == 1
                ? String(
                    localized: "The pull request touches 1 top-level path: \(named).",
                    bundle: bundle
                )
                : String(
                    localized: "The pull request touches \(count) top-level paths: \(named).",
                    bundle: bundle
                )
        case .claimNamesNoModule:
            return String(
                localized:
                    "The claim names no module, so there is nothing to match the changed paths against.",
                bundle: bundle
            )
        case .noPathContainsToken(let token):
            return String(
                localized:
                    "No changed path contains “\(token)”, so the claim could not be matched to the diff.",
                bundle: bundle
            )
        case .filesUnderToken(let insideCount, let total, let token):
            return String(
                localized: "\(insideCount) of \(total) changed files are under “\(token)”.",
                bundle: bundle
            )
        case .fileOutsideToken(let path, let token):
            return String(localized: "“\(path)” is outside “\(token)”.", bundle: bundle)

        // MARK: - Breaking changes

        case .exportedDeclarationChanged(let path, let line, let snippet):
            return String(
                localized:
                    "“\(path)” removes or changes an exported declaration at line \(line): “\(snippet)”.",
                bundle: bundle
            )
        case .manifestLineChanged(let path):
            return String(
                localized: "“\(path)” changes a version or dependency line.",
                bundle: bundle
            )
        case .schemaChanged(let path):
            return String(
                localized: "“\(path)” changes the database schema or a migration.",
                bundle: bundle
            )
        case .workflowChanged(let path):
            return String(localized: "“\(path)” changes a CI workflow.", bundle: bundle)
        case .configurationChanged(let path):
            return String(localized: "“\(path)” changes configuration.", bundle: bundle)
        case .noReadableDiff:
            return String(
                localized:
                    "No diff was readable; GitHub sends no patch for binary files and for diffs it truncated.",
                bundle: bundle
            )
        case .noExportedDeclarationChanged:
            return String(
                localized: "No exported declaration is removed or changed in the diff Shepherd read.",
                bundle: bundle
            )

        // MARK: - Classifications

        case .lockfile(let path):
            return String(localized: "“\(path)” is a dependency lockfile.", bundle: bundle)
        case .generatedFile(let path):
            return String(localized: "“\(path)” is a generated or vendored file.", bundle: bundle)
        case .configurationFile(let path):
            return String(localized: "“\(path)” is configuration.", bundle: bundle)

        // MARK: - The referenced issue

        case .issueReferenced(let number, let repo):
            return String(localized: "Issue #\(number) of \(repo) is referenced.", bundle: bundle)
        case .issueNotFetched:
            return String(
                localized: "Acceptance criteria not checked — the issue is not fetched.",
                bundle: bundle
            )
        case .issueLookupFailed(let failure):
            return Self.sentence(for: failure, bundle: bundle)
        case .referenceIsPullRequest(let number):
            return String(
                localized:
                    "#\(number) is a pull request rather than an issue, so it has no acceptance criteria.",
                bundle: bundle
            )
        case .noAcceptanceChecklist:
            return String(
                localized:
                    "Acceptance criteria not checked — the issue body holds no checklist or list Shepherd could read.",
                bundle: bundle
            )
        case .issueWithBullets(let number, let title, let state, let bulletCount):
            return Self.sentence(
                issue: number,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                state: state,
                bulletCount: bulletCount,
                bundle: bundle
            )
        case .everyBulletMentioned:
            return String(
                localized:
                    "Every acceptance bullet is mentioned in the pull request's description, changed paths or commit messages.",
                bundle: bundle
            )
        case .bulletsMentioned(let mentionedCount, let total):
            return String(
                localized:
                    "\(mentionedCount) of \(total) acceptance bullets are mentioned in the pull request's description, changed paths or commit messages.",
                bundle: bundle
            )
        case .acceptanceBullet(let text, let reason):
            // The bullet is the issue author's line and the reason is a whole sentence of its
            // own; the key is the dash between them, so German can quote the bullet its own way.
            // Named `reasonSentence` rather than `sentence` so the local does not shadow the
            // two `sentence(…)` helpers below.
            let reasonSentence = reason.localizedSentence(bundle: bundle)
            return String(localized: "“\(text)” — \(reasonSentence)", bundle: bundle)
        }
    }

    // MARK: - The failed read

    /// Which of ``ShepherdCore/IssueLookupFailure``'s four answers the card shows.
    ///
    /// Four keys rather than one interpolated one, for the reason ``ClaimsEvidenceCard/claimLabel(_:)``
    /// gives: they are four different sentences, and a translator handed one key could not fix
    /// that.
    /// - Parameters:
    ///   - failure: Why the read failed.
    ///   - bundle: Where to look the catalog up.
    /// - Returns: The sentence.
    private static func sentence(
        for failure: IssueLookupFailure,
        bundle: Bundle
    ) -> String {
        switch failure {
        case .notFound:
            return String(
                localized:
                    "The issue could not be read: GitHub has no issue with that number in this repository.",
                bundle: bundle
            )
        case .noPermission:
            return String(
                localized: "The issue could not be read: this account cannot see it.",
                bundle: bundle
            )
        case .offline:
            return String(
                localized: "The issue could not be read: GitHub could not be reached.",
                bundle: bundle
            )
        case .failed:
            return String(localized: "The issue could not be read.", bundle: bundle)
        }
    }

    // MARK: - The issue that was read

    /// "Issue #142 “Retry flaky uploads” is open and lists 3 acceptance bullets."
    ///
    /// Twelve keys, because there are twelve sentences: three states (the third is *no state
    /// named*, for a state GitHub reported and Shepherd does not model — "was read" would be a
    /// sentence about Shepherd rather than about the issue), a titled and an untitled form for an
    /// issue GitHub sent no title for, and singular and plural for the bullets. The count cannot
    /// go through a plural variation here because it shares the sentence with the number and the
    /// title (ADR 0022), so the singular is a key of its own — which is also the only way the
    /// German genitive comes out right.
    /// - Parameters:
    ///   - issue: The issue number.
    ///   - title: The issue title, already trimmed. Empty when GitHub sent none.
    ///   - state: Whether it is open, closed, or a state Shepherd does not model.
    ///   - bulletCount: How many acceptance bullets it lists.
    ///   - bundle: Where to look the catalog up.
    /// - Returns: The sentence.
    private static func sentence(
        issue number: Int,
        title: String,
        state: IssueSummary.State,
        bulletCount count: Int,
        bundle: Bundle
    ) -> String {
        // A `switch` on the state with the two counts inside it, rather than one over a tuple:
        // three cases the compiler can see are all of them.
        switch state {
        case .open:
            if title.isEmpty {
                return count == 1
                    ? String(
                        localized: "Issue #\(number) is open and lists 1 acceptance bullet.",
                        bundle: bundle
                    )
                    : String(
                        localized: "Issue #\(number) is open and lists \(count) acceptance bullets.",
                        bundle: bundle
                    )
            }
            return count == 1
                ? String(
                    localized: "Issue #\(number) “\(title)” is open and lists 1 acceptance bullet.",
                    bundle: bundle
                )
                : String(
                    localized:
                        "Issue #\(number) “\(title)” is open and lists \(count) acceptance bullets.",
                    bundle: bundle
                )
        case .closed:
            if title.isEmpty {
                return count == 1
                    ? String(
                        localized: "Issue #\(number) is closed and lists 1 acceptance bullet.",
                        bundle: bundle
                    )
                    : String(
                        localized:
                            "Issue #\(number) is closed and lists \(count) acceptance bullets.",
                        bundle: bundle
                    )
            }
            return count == 1
                ? String(
                    localized:
                        "Issue #\(number) “\(title)” is closed and lists 1 acceptance bullet.",
                    bundle: bundle
                )
                : String(
                    localized:
                        "Issue #\(number) “\(title)” is closed and lists \(count) acceptance bullets.",
                    bundle: bundle
                )
        case .unknown:
            if title.isEmpty {
                return count == 1
                    ? String(
                        localized: "Issue #\(number) lists 1 acceptance bullet.",
                        bundle: bundle
                    )
                    : String(
                        localized: "Issue #\(number) lists \(count) acceptance bullets.",
                        bundle: bundle
                    )
            }
            return count == 1
                ? String(
                    localized: "Issue #\(number) “\(title)” lists 1 acceptance bullet.",
                    bundle: bundle
                )
                : String(
                    localized: "Issue #\(number) “\(title)” lists \(count) acceptance bullets.",
                    bundle: bundle
                )
        }
    }

    // MARK: - Quoting

    /// One value in the quotation marks the language uses.
    ///
    /// The only key in the app that is nothing but punctuation, and it exists because a *list* of
    /// quoted paths cannot carry its quotation marks in the sentence key the way every other fact
    /// does.
    /// - Parameters:
    ///   - value: The path, token or word — interpolated verbatim, never translated.
    ///   - bundle: Where to look the catalog up.
    /// - Returns: The quoted value.
    static func quoted(_ value: String, bundle: Bundle) -> String {
        String(localized: "“\(value)”", bundle: bundle)
    }

    /// The named items of a capped list, ending in an ellipsis when there are more.
    ///
    /// The comma and the ellipsis are punctuation and are the same in both languages, so they are
    /// assembled here rather than being a key of their own.
    /// - Parameters:
    ///   - items: The items to name — already the capped prefix.
    ///   - total: How many there are altogether.
    ///   - bundle: Where to look the catalog up.
    /// - Returns: The quoted items, comma-separated.
    static func list(_ items: [String], of total: Int, bundle: Bundle) -> String {
        let named = items.map { quoted($0, bundle: bundle) }.joined(separator: ", ")
        return total > items.count ? "\(named), …" : named
    }
}

extension AcceptanceMatch.Reason {
    /// Why one acceptance bullet came out mentioned or not, as one localised sentence.
    ///
    /// The word counts pick their key on the count rather than going through a plural variation:
    /// each of these sentences carries the matched words or a second number beside the count, and
    /// the English needs its verb to agree as well ("1 of 4 words … appears").
    /// - Parameter bundle: Where to look the catalog up.
    /// - Returns: The sentence, in the bundle's language.
    func localizedSentence(bundle: Bundle = .main) -> String {
        switch self {
        case .wordsAppear(let present, let total):
            let listed = EvidenceFact.Kind.list(
                Array(present.prefix(AcceptanceMatcher.namedWordLimit)),
                of: present.count,
                bundle: bundle
            )
            if present.count == 1, total == 1 {
                return String(
                    localized: "1 of 1 word in this bullet appears in the pull request: \(listed).",
                    bundle: bundle
                )
            }
            if present.count == 1 {
                return String(
                    localized:
                        "1 of \(total) words in this bullet appears in the pull request: \(listed).",
                    bundle: bundle
                )
            }
            let count = present.count
            return String(
                localized:
                    "\(count) of \(total) words in this bullet appear in the pull request: \(listed).",
                bundle: bundle
            )
        case .readsAsAbout(let similarity):
            let similarityText = AcceptanceMatch.Reason.formatted(similarity)
            return String(
                localized:
                    "The pull request reads as being about this (similarity \(similarityText)).",
                bundle: bundle
            )
        case .noDistinctiveWord:
            return String(
                localized: "This bullet has no distinctive word Shepherd could look for.",
                bundle: bundle
            )
        case .wordsMissing(let present, let total, let similarity):
            let head = Self.missed(present: present.count, total: total, bundle: bundle)
            guard let similarity else { return head }
            let similarityText = AcceptanceMatch.Reason.formatted(similarity)
            let tail = String(
                localized: "On-device similarity is \(similarityText).",
                bundle: bundle
            )
            // Two whole sentences, so the join is a space rather than a key: neither half is a
            // fragment the other one completes.
            return "\(head) \(tail)"
        }
    }

    /// The half of a missed bullet's reason that is about the words.
    /// - Parameters:
    ///   - present: How many of the bullet's distinctive words appeared.
    ///   - total: How many it has.
    ///   - bundle: Where to look the catalog up.
    /// - Returns: The sentence.
    private static func missed(present presentCount: Int, total: Int, bundle: Bundle) -> String {
        if presentCount == 0, total == 1 {
            return String(
                localized: "The one distinctive word in this bullet does not appear in the pull request.",
                bundle: bundle
            )
        }
        if presentCount == 0 {
            // `total` is at least two here — the single-word case is the key above — so this key
            // needs no singular form.
            return String(
                localized: "None of the \(total) words in this bullet appear in the pull request.",
                bundle: bundle
            )
        }
        if presentCount == 1 {
            return String(
                localized: "Only 1 of the \(total) words in this bullet appears in the pull request.",
                bundle: bundle
            )
        }
        return String(
            localized: "Only \(presentCount) of the \(total) words in this bullet appear in the pull request.",
            bundle: bundle
        )
    }
}
