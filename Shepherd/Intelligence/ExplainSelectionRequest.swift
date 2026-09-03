import Foundation
import ShepherdCore

/// Everything a provider is given to **explain** the lines a reviewer selected (plan §3.D).
///
/// The third drafting surface, and deliberately the cheapest one to have added: it carries the
/// *same* windowed diff excerpt an inline-comment draft carries, built by the same
/// ``InlineCommentDraftBuilder`` against the same budget, with the anchored lines the last thing
/// to be surrendered. That is why this type wraps an ``InlineCommentDraftRequest`` rather than
/// re-deriving a window of its own:
///
/// - **The privacy statement stays one statement.** ADR 0007's drafting amendment says a diff
///   excerpt travels for inline drafts; a second, differently-cut excerpt would be a second thing
///   to describe in `CONTRIBUTING.md`, and a reviewer who has read the sentence once would have to
///   read it again to know what an explanation sends.
/// - **The budget arithmetic is already tested.** The window, the character share and the
///   "anchored lines go last" rule are `AIDraftingTests`' subject, and an explanation inherits all
///   of it — including the on-device tier's hard ceiling — instead of growing a parallel set of
///   cases that could drift.
///
/// What *is* new is the instruction and the language: the answer is prose for a person to read
/// rather than a comment for them to send, and it is written in the reviewer's own language
/// (``currentLanguageName(of:)``) because an explanation nobody can read comfortably is worse than
/// no explanation.
///
/// The result is still only text: the popover shows it, and turning it into an inline comment is a
/// separate click that goes through ``AIDraftFieldState`` like every other draft (ADR 0007's
/// non-goal — nothing auto-submits).
struct ExplainSelectionRequest: Sendable, Hashable {
    /// The very same context an inline-comment draft would travel with, unchanged.
    var selection: InlineCommentDraftRequest
    /// The language the answer must be written in, named as the model reads it ("German").
    ///
    /// A *name* rather than a BCP-47 tag, because the prompt is English prose and "answer in de"
    /// is an instruction a small model follows unevenly, while "answer in German" is a sentence.
    var languageName: String

    /// The name used when the platform cannot say which language the reviewer reads.
    ///
    /// Model-facing English, like every prompt in this layer, so it is deliberately *not* a
    /// catalog key: it is a word the model reads, not a word the reviewer does.
    static let fallbackLanguageName = "English"

    /// Creates a request.
    /// - Parameters:
    ///   - selection: The windowed excerpt and its anchor.
    ///   - languageName: The language the answer is asked for in.
    init(selection: InlineCommentDraftRequest, languageName: String) {
        self.selection = selection
        self.languageName = languageName
    }

    /// Builds the request for one tier, reusing the inline-draft window unchanged.
    /// - Parameters:
    ///   - detail: The fetched pull request.
    ///   - anchor: The lines the reviewer selected.
    ///   - budget: The tier's token budget.
    ///   - languageName: The language to answer in. Defaults to the reviewer's own.
    /// - Returns: A request whose ``approximateTokenCount`` is inside the budget.
    static func build(
        detail: PullRequestDetail,
        anchor: InlineCommentAnchor,
        budget: TokenBudget,
        languageName: String = ExplainSelectionRequest.currentLanguageName()
    ) -> ExplainSelectionRequest {
        ExplainSelectionRequest(
            selection: InlineCommentDraftBuilder.build(
                detail: detail,
                anchor: anchor,
                budget: budget
            ),
            languageName: languageName
        )
    }

    /// The English name of a locale's language, for the instruction.
    ///
    /// Resolved against `en_US` rather than against the reviewer's own locale on purpose: the
    /// instruction around it is English, and a prompt that mixed "Write the whole answer in
    /// Deutsch" into an English sentence would be asking a small model to parse two languages at
    /// once to work out what one word means.
    /// - Parameter locale: The locale to read the language from. `Locale.current` outside tests.
    /// - Returns: The language's English name, or ``fallbackLanguageName`` when the platform
    ///   cannot name it.
    static func currentLanguageName(of locale: Locale = .current) -> String {
        guard let code = locale.language.languageCode?.identifier, !code.isEmpty else {
            return fallbackLanguageName
        }
        guard let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code),
              !name.isEmpty
        else { return code }
        return name
    }

    /// The instructions this request is sent with: the shared contract plus the language.
    ///
    /// Assembled here rather than at each provider so the three tiers cannot ask for the answer
    /// in three different languages — the whole point of the feature is that the sentence a German
    /// reviewer reads is German whichever tier answered.
    var instructions: String {
        IntelligencePrompt.explainSelectionInstructions
            + "\nWrite the whole answer in \(languageName)."
    }

    /// The file the selection is in.
    var path: String { selection.path }

    /// The lines the reviewer selected.
    var anchor: InlineCommentAnchor { selection.anchor }

    /// Whether there is any diff to explain at all.
    var hasExcerpt: Bool { selection.hasExcerpt }

    /// The approximate token count of the whole request.
    ///
    /// The selection's own figure: the language sentence is a handful of characters and the
    /// instructions are measured with the prompt by the on-device pre-flight anyway, so counting
    /// them twice would make the estimate a different estimate from the drafting path's for the
    /// same excerpt.
    var approximateTokenCount: Int { selection.approximateTokenCount }
}
