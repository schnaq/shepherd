import AppIntents
import Foundation
import ShepherdCore

/// One summarise-intent run's material, in the shape both Siri's sentence and the snippet need
/// (plan §3.H).
///
/// A plain value with the identity in it rather than a bare ``PRSummary``, for the reason ADR 0021
/// gives about ``PullRequestEntity``: an entity is a *handle*, so the slug and title a voice answer
/// reads out must come from the row the database holds **now** rather than from whatever a stored
/// shortcut remembered. The summary itself is deliberately not on the entity and is not written
/// anywhere — it is the result of one user-invoked intent, spoken and shown once.
enum PullRequestSummaryAnswer: Sendable, Hashable {
    /// The on-device model answered.
    case summary(SummarizedPullRequest)
    /// Nothing ran, and this is what Siri says instead.
    case refusal(PullRequestSummaryRefusal)

    /// What Siri reads out.
    ///
    /// Built at `perform()` time rather than declared, so it is not one of the literals the App
    /// Intents metadata processor extracts at build time (those are the static `title` and the
    /// `@Parameter` title, and they are literals — ADR 0022). The copy still lives in exactly one
    /// place per sentence: ``PullRequestSummaryRefusal/sentence``, which the snippet shows too, so
    /// the spoken and the drawn answer cannot drift apart.
    var dialog: IntentDialog {
        switch self {
        case .summary(let summarized):
            // The overview only. The risk notes are on the card: a voice answer that recited
            // three of them would talk over the person who asked a one-sentence question.
            return IntentDialog(stringLiteral: summarized.overview)
        case .refusal(let refusal):
            return IntentDialog(stringLiteral: refusal.sentence)
        }
    }
}

/// A pull request and what the on-device model said about it (plan §3.H).
struct SummarizedPullRequest: Sendable, Hashable {
    /// How many risk notes travel at most.
    ///
    /// A cap on the *value* rather than on the view, so the number is one constant a test can
    /// read: a Siri snippet is a small card, and a model that returned seven notes would push the
    /// overview — the part that was actually asked for — off it.
    static let maximumRiskNotes = 3

    /// `owner/repo#123`, from today's row.
    var slug: String
    /// The pull-request title, from today's row.
    var title: String
    /// The two-or-three-sentence overview, which is also what Siri speaks.
    var overview: String
    /// Up to ``maximumRiskNotes`` short risk notes.
    var riskNotes: [String]

    /// Creates a summarised pull request, capping the risk notes.
    /// - Parameters:
    ///   - slug: `owner/repo#123`.
    ///   - title: The pull-request title.
    ///   - overview: The overview sentences.
    ///   - riskNotes: The risk notes; only the first ``maximumRiskNotes`` are kept.
    init(slug: String, title: String, overview: String, riskNotes: [String]) {
        self.slug = slug
        self.title = title
        self.overview = overview
        self.riskNotes = Array(riskNotes.prefix(SummarizedPullRequest.maximumRiskNotes))
    }

    /// Creates a summarised pull request from the row the digest was built from.
    /// - Parameters:
    ///   - detail: The cached pull request, whose own ``ShepherdCore/PullRequestDetail/summary``
    ///     carries the current slug and title.
    ///   - summary: What the tier produced.
    init(detail: PullRequestDetail, summary: PRSummary) {
        self.init(
            slug: detail.summary.slug,
            title: detail.summary.title,
            overview: summary.overview,
            riskNotes: summary.riskNotes
        )
    }
}

/// Why a summarise run produced no summary (plan §3.H).
///
/// Each case is a *sentence*, because an intent's answer is frequently the only feedback a voice
/// request gets — the same reasoning ``IntentFailure`` is written under. They are refusals rather
/// than thrown errors for one reason: a refusal still has a card to draw, and "Shepherd has not
/// fetched this pull request yet" is an answer to the question rather than a broken shortcut.
enum PullRequestSummaryRefusal: Sendable, Hashable {
    /// Intelligence is switched off in Settings, so no tier was asked.
    case intelligenceOff
    /// The on-device model cannot answer on this Mac right now.
    ///
    /// One sentence for all three of ``OnDeviceProvider``'s reasons (ineligible hardware, Apple
    /// Intelligence off, model not downloaded). Those reasons are written for the card that sits
    /// next to the toggle that fixes them; spoken, with no screen and no Settings pane in reach,
    /// the honest answer is the short one. The cloud rung is *never* the fallback here — an intent
    /// has no reviewer in front of it (ADR 0007, plan §3.H).
    case modelUnavailable
    /// The pull request is in the inbox, but its detail has never been fetched.
    case notFetched
    /// The review queue is empty, so there was no "next review" to summarise.
    case nothingWaiting
    /// The tier answered with nothing readable.
    case emptyAnswer
    /// The tier failed, with the reason the router formatted.
    case failed(String)

    /// The sentence Siri speaks and the snippet shows.
    var sentence: String {
        switch self {
        case .intelligenceOff:
            return String(localized: "Intelligence is switched off in Shepherd's settings.")
        case .modelUnavailable:
            return String(localized: "Apple Intelligence is not available on this Mac.")
        case .notFetched:
            return String(
                localized: "Shepherd has not fetched this pull request yet — open it once in the app."
            )
        case .nothingWaiting:
            return String(localized: "Nothing needs your review.")
        case .emptyAnswer:
            return String(localized: "The on-device model had nothing to say about this one.")
        case .failed(let reason):
            return reason
        }
    }
}

/// How ``SummarizePullRequestIntent`` reaches the intelligence layer (plan §3.H).
///
/// One `Sendable` value with one closure in it, for the same three reasons ``AgentBriefDrafter``
/// is one:
///
/// - **The rule is structural.** The closure the app layer builds is the only one that exists, and
///   it asks the router with `onDeviceOnly: true`. There is no parameter an intent could pass to
///   widen that, so "an intent never reaches the cloud rung" is a shape rather than a check.
/// - **The intent stays testable.** A test scripts the tiers and drives the whole answer without
///   Siri, a window, a database or Apple Intelligence.
/// - **The intent knows nothing about persistence.** The pull request arrives through the
///   ``live(router:detail:)`` closure the app layer supplies, exactly as the delegation sheet's
///   drafter takes its database as a seam.
///
/// It produces one sentence and one card. Nothing is stored on the entity, exported to Spotlight
/// or written to the database (ADR 0021 amendment).
struct PullRequestSummarizer: Sendable {
    /// Summarises one pull request, named by its GraphQL node id.
    let summarize: @Sendable (String) async -> PullRequestSummaryAnswer

    /// Creates a summarizer.
    /// - Parameter summarize: Summarises one pull request by node id.
    init(summarize: @escaping @Sendable (String) async -> PullRequestSummaryAnswer) {
        self.summarize = summarize
    }

    /// The live summarizer: the tier ladder, pinned to tier 2, over the local database.
    /// - Parameters:
    ///   - router: The tier ladder. It is asked with `onDeviceOnly: true` and there is no way to
    ///     ask it otherwise from here.
    ///   - detail: Reads a pull request out of the local database by node id, answering `nil` when
    ///     there is nothing a digest could be built from. **Never a fetch**: an intent may run on
    ///     a five-minute automation and from a voice request, and neither may spend rate limit or
    ///     wake the network (ADR 0021's rule for the read-only intents).
    /// - Returns: The summarizer the intent uses.
    static func live(
        router: IntelligenceRouter,
        detail: @escaping @Sendable (String) async -> PullRequestDetail?
    ) -> PullRequestSummarizer {
        PullRequestSummarizer { prID in
            guard let pullRequest = await detail(prID) else {
                return .refusal(.notFetched)
            }
            switch await router.summary(for: pullRequest, onDeviceOnly: true) {
            case .value(let output):
                let overview = output.value.overview
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // An empty overview is the one failure that would otherwise be silent: Siri would
                // say nothing at all and the card would be blank, which reads as a broken app
                // rather than as a bad day for the model.
                guard !overview.isEmpty else { return .refusal(.emptyAnswer) }
                return .summary(
                    SummarizedPullRequest(
                        detail: pullRequest,
                        summary: PRSummary(overview: overview, riskNotes: output.value.riskNotes)
                    )
                )
            case .disabled:
                return .refusal(.intelligenceOff)
            case .unavailable:
                return .refusal(.modelUnavailable)
            case .failed(let reason):
                return .refusal(.failed(reason))
            }
        }
    }
}
