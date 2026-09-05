import Foundation
import ShepherdCore

// MARK: - Summary drafts

/// Everything a provider is given to draft a review **summary** (ADR 0007 amendment).
///
/// The context is the tier-1 ``ShepherdCore/PullRequestDigest`` — title, description excerpt,
/// prioritised file list, top hunks, already truncated to the tier's token budget — plus the
/// inline comments the reviewer has already written in this pass. Nothing else: a summary drafted
/// from more than the reviewer can see on screen would be a summary they cannot check.
///
/// The result of the request is a **suggestion**. It is written into the summary field for the
/// reviewer to edit, and no code path exists that submits it (ADR 0007 non-goal, `ROADMAP.md`).
struct ReviewSummaryDraftRequest: Sendable, Hashable {
    /// One inline comment that is already waiting in the pending review.
    ///
    /// Quoted so the drafted summary can point at what the reviewer found rather than
    /// re-deriving it from the diff — and so it does not repeat it word for word.
    struct Note: Sendable, Hashable {
        /// The file the comment is anchored to.
        var path: String
        /// The line the comment is anchored to.
        var line: Int
        /// The comment body, capped to ``ReviewSummaryDraftRequest/maximumNoteCharacters``.
        var body: String
    }

    /// At most this many pending comments are quoted, oldest first.
    ///
    /// A reviewer with forty comments has written the summary already; the first handful is what
    /// gives the draft its subject.
    static let maximumNotes = 8
    /// Each quoted comment is capped to this many characters.
    static let maximumNoteCharacters = 240
    /// Fraction of the tier's character budget the quoted comments may occupy in total.
    static let notesShare = 0.08
    /// The quoted comments may always use at least this many characters, however small the
    /// budget is — one short note is worth more than an empty section.
    static let minimumNotesCharacters = 400

    /// The digest the draft is written from, already inside the tier's budget.
    var digest: PullRequestDigest
    /// The reviewer's own pending inline comments, capped by ``notes(from:budget:)``.
    var notes: [Note]

    /// Creates a request.
    /// - Parameters:
    ///   - digest: The tier-1 digest.
    ///   - notes: The capped pending comments. Use ``notes(from:budget:)`` to build them.
    init(digest: PullRequestDigest, notes: [Note] = []) {
        self.digest = digest
        self.notes = notes
    }

    /// Builds the request for one tier.
    ///
    /// The digest and the quoted comments share one budget, so they are budgeted together: the
    /// room for the notes is reserved first (``digestBudget(in:)``) and the digest is built into
    /// what is left. Adding the notes on top of a digest that had already filled the context
    /// window would make a summary draft fail precisely when the reviewer has written the most —
    /// and tier 2's ceiling is a hard error, not a truncation (ADR 0007).
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - pendingComments: The inline comments already in the local draft.
    ///   - budget: The tier's token budget.
    /// - Returns: A request whose ``approximateTokenCount`` is inside `budget`.
    static func build(
        detail: PullRequestDetail,
        pendingComments: [DraftComment],
        budget: TokenBudget
    ) -> ReviewSummaryDraftRequest {
        ReviewSummaryDraftRequest(
            digest: PullRequestDigestBuilder.build(
                from: detail,
                budget: digestBudget(in: budget)
            ),
            notes: notes(from: pendingComments, budget: budget)
        )
    }

    /// How many characters the quoted comments may occupy inside a budget.
    /// - Parameter budget: The tier's token budget.
    static func notesCharacterLimit(in budget: TokenBudget) -> Int {
        max(minimumNotesCharacters, Int(Double(budget.maxCharacters) * notesShare))
    }

    /// The budget the digest is built against when notes travel with it.
    ///
    /// The tier's budget minus the room the notes may use, so the two together stay inside it.
    /// - Parameter budget: The tier's token budget.
    static func digestBudget(in budget: TokenBudget) -> TokenBudget {
        let reserved = budget.approximateTokens(characterCount: notesCharacterLimit(in: budget))
        return TokenBudget(
            maxTokens: max(1, budget.maxTokens - reserved),
            charactersPerToken: budget.charactersPerToken
        )
    }

    /// Caps the pending inline comments to what the tier can afford.
    ///
    /// Deterministic on purpose — three independent limits, none of them a guess about the
    /// tokenizer: a count cap, a per-comment character cap, and a share of the same character
    /// budget the digest was built against. So the on-device tier gets fewer and shorter notes
    /// than the cloud tier from exactly the same draft, and the arithmetic is unit-tested rather
    /// than discovered as a context-window error.
    /// - Parameters:
    ///   - comments: The pending inline comments, in the order they were written.
    ///   - budget: The tier's *full* token budget — the same one ``digestBudget(in:)`` was given.
    /// - Returns: The notes to quote, in the same order.
    static func notes(from comments: [DraftComment], budget: TokenBudget) -> [Note] {
        let totalLimit = notesCharacterLimit(in: budget)
        var used = 0
        var result: [Note] = []
        for comment in comments.prefix(maximumNotes) {
            let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let capped = body.count > maximumNoteCharacters
                ? String(body.prefix(maximumNoteCharacters)) + "…"
                : body
            // The path and the line number travel with the body, so they come out of the same
            // budget; the constant covers the separators the prompt puts between them.
            let cost = capped.count + comment.path.count + 16
            if used + cost > totalLimit, !result.isEmpty { break }
            used += cost
            result.append(Note(path: comment.path, line: comment.line, body: capped))
        }
        return result
    }

    /// How many characters the quoted comments occupy.
    var notesCharacterCount: Int {
        notes.reduce(0) { $0 + $1.body.count + $1.path.count + 16 }
    }

    /// The approximate token count of the whole request.
    ///
    /// The digest's own figure plus the notes, counted the same way the digest counts itself
    /// (``ShepherdCore/TokenBudget/approximateTokens(characterCount:)``) so the on-device
    /// preflight compares like with like.
    var approximateTokenCount: Int {
        digest.approximateTokenCount
            + digest.budget.approximateTokens(characterCount: notesCharacterCount)
    }
}

// MARK: - Inline comment drafts

/// Where an inline comment is anchored, as the intelligence layer sees it.
///
/// A small value of its own rather than `ReviewModel.ComposerRequest`: the drafting code has no
/// business knowing about sheets, and this is the whole of what it needs.
struct InlineCommentAnchor: Sendable, Hashable {
    /// The file being commented on.
    var path: String
    /// The (last) line the comment is anchored to.
    var line: Int
    /// Which side of the diff the line belongs to.
    var side: DiffSide
    /// The first line of a multi-line selection, when there is one.
    var startLine: Int?

    /// Creates an anchor.
    init(path: String, line: Int, side: DiffSide, startLine: Int? = nil) {
        self.path = path
        self.line = line
        self.side = side
        self.startLine = startLine
    }

    /// The lowest and highest line the comment covers.
    var lineRange: ClosedRange<Int> {
        let other = startLine ?? line
        return min(other, line)...max(other, line)
    }
}

/// Everything a provider is given to draft one **inline comment** (ADR 0007 amendment).
///
/// Deliberately *not* the whole digest: a comment on one line is answered by the lines around it,
/// and sending forty files of context to ask about three of them would spend the tier's budget on
/// everything except the question. The excerpt is built by ``InlineCommentDraftBuilder`` and is
/// already capped.
///
/// The result is a **suggestion**: it lands in the composer's text field, which the reviewer then
/// edits and saves by hand. Nothing here can reach GitHub on its own.
struct InlineCommentDraftRequest: Sendable, Hashable {
    /// `owner/name` of the repository.
    var repoFullName: String
    /// The pull request number.
    var number: Int
    /// The pull request title, capped to ``InlineCommentDraftBuilder/maximumTitleCharacters``.
    var pullRequestTitle: String
    /// The file being commented on.
    var path: String
    /// What happened to that file, when it is known.
    var fileStatus: FileChangeStatus?
    /// The anchor the comment hangs off.
    var anchor: InlineCommentAnchor
    /// The marked-up diff excerpt around the anchor. Empty when GitHub sent no patch.
    var excerpt: String
    /// Whether the excerpt is a window into a longer diff.
    var excerptWasTruncated: Bool
    /// The budget the excerpt was cut to fit.
    var budget: TokenBudget

    /// The approximate token count of the whole request, counted the way digests count
    /// themselves so the on-device preflight compares like with like.
    var approximateTokenCount: Int {
        budget.approximateTokens(
            characterCount: excerpt.count + path.count + pullRequestTitle.count + 64
        )
    }

    /// Whether there is any diff to draft from at all.
    var hasExcerpt: Bool { !excerpt.isEmpty }
}

/// Builds an ``InlineCommentDraftRequest`` from the fetched pull request and one anchor.
///
/// Pure and deterministic, like ``ShepherdCore/PullRequestDigestBuilder`` and for the same reason
/// (ADR 0007: prompting code budgets tokens explicitly rather than hoping a prompt fits). The
/// window is picked in *diff lines* first — a reviewer's question is answered by the lines they
/// can see — and only then trimmed to characters, so the excerpt of a 4,000-line patch is the
/// same excerpt whichever tier asks for it, modulo the tier's budget.
enum InlineCommentDraftBuilder {
    /// How many diff lines of context are kept on either side of the anchored line.
    static let contextLines = 24
    /// Fraction of the tier's character budget the excerpt may occupy.
    ///
    /// Half: the excerpt *is* the context, and the other half leaves room for the instructions,
    /// the header lines and the answer.
    static let excerptShare = 0.5
    /// The excerpt may always use at least this many characters.
    static let minimumExcerptCharacters = 600
    /// The pull request title is carried for orientation only, so it is capped short.
    static let maximumTitleCharacters = 120
    /// The prefix put in front of the line or lines the comment is anchored to.
    static let anchorMarker = ">> "
    /// The prefix put in front of every other excerpt line, so the columns line up.
    static let contextMarker = "   "

    /// Builds the request.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - anchor: Where the comment is anchored.
    ///   - budget: The tier's token budget.
    /// - Returns: A request whose ``InlineCommentDraftRequest/approximateTokenCount`` is inside
    ///   the budget. ``InlineCommentDraftRequest/excerpt`` is empty when GitHub sent no patch for
    ///   the file (binary, or a diff GitHub truncated).
    static func build(
        detail: PullRequestDetail,
        anchor: InlineCommentAnchor,
        budget: TokenBudget
    ) -> InlineCommentDraftRequest {
        let file = detail.files.first { $0.path == anchor.path }
        let limit = max(
            minimumExcerptCharacters,
            Int(Double(budget.maxCharacters) * excerptShare)
        )
        let window = InlineCommentDraftBuilder.excerpt(
            patch: file?.patch ?? "",
            anchor: anchor,
            limit: limit
        )
        return InlineCommentDraftRequest(
            repoFullName: detail.summary.repo.fullName,
            number: detail.summary.number,
            pullRequestTitle: String(detail.summary.title.prefix(maximumTitleCharacters)),
            path: anchor.path,
            fileStatus: file?.status,
            anchor: anchor,
            excerpt: window.text,
            excerptWasTruncated: window.truncated,
            budget: budget
        )
    }

    /// One rendered line of an excerpt.
    private struct Row {
        /// The diff line, marker character included.
        var text: String
        /// Whether the comment is anchored to this line.
        var isAnchored: Bool
    }

    /// Cuts the marked-up window out of a unified patch.
    ///
    /// Line numbers are tracked exactly the way ``PatchReconstructor`` tracks them — that is the
    /// same arithmetic GitHub's `comments[].line` is in, so the line the reviewer clicked is the
    /// line that gets marked.
    /// - Parameters:
    ///   - patch: The file's unified diff, as GitHub returns it.
    ///   - anchor: Where the comment is anchored.
    ///   - limit: The maximum number of characters the excerpt may use.
    /// - Returns: The excerpt and whether it is a window into something longer.
    static func excerpt(
        patch: String,
        anchor: InlineCommentAnchor,
        limit: Int
    ) -> (text: String, truncated: Bool) {
        guard limit > 0, !patch.isEmpty else { return ("", false) }

        let range = anchor.lineRange
        var rows: [Row] = []

        for hunk in UnifiedPatch.hunks(in: patch) {
            // Synthesised rather than copied: the header's line counts are re-derivable and the
            // section heading GitHub puts after the second `@@` is not context, it is noise.
            rows.append(
                Row(text: "@@ -\(hunk.originalStart) +\(hunk.modifiedStart) @@", isAnchored: false)
            )
            var originalLine = hunk.originalStart
            var modifiedLine = hunk.modifiedStart
            for line in hunk.lines {
                guard let marker = line.first else {
                    // An empty line inside a hunk is an unchanged empty line.
                    let number = anchor.side == .left ? originalLine : modifiedLine
                    rows.append(Row(text: " ", isAnchored: range.contains(number)))
                    originalLine += 1
                    modifiedLine += 1
                    continue
                }
                switch marker {
                case "+":
                    rows.append(
                        Row(
                            text: line,
                            isAnchored: anchor.side == .right && range.contains(modifiedLine)
                        )
                    )
                    modifiedLine += 1
                case "-":
                    rows.append(
                        Row(
                            text: line,
                            isAnchored: anchor.side == .left && range.contains(originalLine)
                        )
                    )
                    originalLine += 1
                case "\\":
                    // "\ No newline at end of file" — metadata, not content.
                    continue
                default:
                    // " " is context; anything else is treated as context too, which is the same
                    // safe failure mode the reconstructor picks.
                    let number = anchor.side == .left ? originalLine : modifiedLine
                    rows.append(Row(text: line, isAnchored: range.contains(number)))
                    originalLine += 1
                    modifiedLine += 1
                }
            }
        }

        guard !rows.isEmpty else { return ("", false) }

        func rendered(_ index: Int) -> String {
            (rows[index].isAnchored ? anchorMarker : contextMarker) + rows[index].text
        }
        func size(_ from: Int, _ through: Int) -> Int {
            (from...through).reduce(0) { $0 + rendered($1).count + 1 }
        }

        let firstAnchored = rows.firstIndex(where: \.isAnchored)
        let lastAnchored = rows.lastIndex(where: \.isAnchored)
        var start = 0
        var end = rows.count - 1
        var truncated = false
        if let firstAnchored, let lastAnchored {
            start = max(0, firstAnchored - contextLines)
            end = min(rows.count - 1, lastAnchored + contextLines)
            truncated = start > 0 || end < rows.count - 1
        }
        // The anchored block is what the question is about, so it is the last thing to go: the
        // window shrinks from its edges inwards and stops there. (With no anchored line — the
        // reviewer clicked a line the patch does not contain, which `validateAnchor` rejects
        // before this is ever reached — "the block" is the first row, so this still terminates.)
        let keepFrom = firstAnchored ?? 0
        let keepThrough = lastAnchored ?? 0
        while size(start, end) > limit, start < keepFrom || end > keepThrough {
            if end > keepThrough {
                end -= 1
            } else {
                start += 1
            }
            truncated = true
        }

        var text = (start...end).map(rendered).joined(separator: "\n")
        if text.count > limit {
            // A single anchored block longer than the whole budget: cut it, rather than send a
            // prompt the tier will refuse.
            text = String(text.prefix(limit))
            truncated = true
        }
        return (text, truncated)
    }
}
