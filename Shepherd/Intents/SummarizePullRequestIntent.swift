import AppIntents
import Foundation
import ShepherdCore
import SwiftUI

/// Reads out the on-device summary of one pull request (plan §3.H, ADR 0021 amendment).
///
/// The second read-only intent, and the first that runs a *model*. "Hey Siri, summarise my next
/// review in Shepherd" answers with the overview sentences and shows a card; in Shortcuts,
/// `Get Review Queue` → `Summarise Pull Request` → `Show Result` composes, because the parameter
/// is the same ``PullRequestEntity`` the queue action returns.
///
/// Four properties of it are decisions rather than details.
///
/// **Tier 2, and there is no rung below or above it.** An intent has no review screen in front of
/// anybody and, from Siri, no screen at all — which is exactly the situation ADR 0007 answers with
/// "unattended means on-device only". So the router is asked with
/// ``IntelligenceRouter/summary(for:onDeviceOnly:)``, the cloud rung is never *offered* the
/// request even when the user has a key configured, and a Mac without Apple Intelligence gets one
/// sentence saying so instead of a quiet upgrade to somebody's endpoint.
///
/// **The summary is a result, not a property.** It is spoken once and drawn once. It is not stored
/// on the entity (which stays metadata-only, ADR 0021), not written to the database, and not
/// exported to Spotlight — so "a shortcut that mails my pull-request summaries somewhere" is not
/// assemblable out of Shepherd's own actions for the same structural reason a shortcut that mails
/// diffs is not.
///
/// **It reads, it never fetches.** The digest is built from the cached pull request. A row whose
/// detail has never been fetched gets a sentence saying so rather than a GitHub call, because a
/// voice request and a five-minute automation are the two callers here and neither may spend rate
/// limit (ADR 0021).
///
/// **It does not open the app.** Like ``GetReviewQueueIntent``, and for the same reason: a
/// question answered by putting a window on screen has answered a different question. The cost is
/// the same one, stated rather than papered over — Shepherd has to be running.
struct SummarizePullRequestIntent: AppIntent {
    static var title: LocalizedStringResource { "Summarise Pull Request" }

    /// False: an answer that is read out must not steal the user's focus. See the type's
    /// discussion.
    static var openAppWhenRun: Bool { false }

    /// Which pull request to summarise. Nothing means the top of the review queue.
    ///
    /// Optional on purpose, and it is what makes the one phrase and the one Shortcuts action the
    /// same intent: "summarise my next review" supplies nothing and gets the queue's first row,
    /// while a shortcut wired up from `Get Review Queue` supplies the entity it is iterating.
    @Parameter(title: "Pull Request")
    var pullRequest: PullRequestEntity?

    /// Required by `AppIntent`: the system creates intents with no arguments.
    init() {}

    /// Creates a pre-filled intent, for ``ShepherdShortcuts``.
    /// - Parameter pullRequest: The pull request, or `nil` for the top of the review queue.
    init(pullRequest: PullRequestEntity?) {
        self.pullRequest = pullRequest
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        // Throws rather than answering "nothing needs your review": "Shepherd is not running" and
        // "no account is signed in" are different facts from an empty queue, and a shortcut told
        // the last one when one of the first two is true would quietly stop reporting real work
        // (ADR 0021). The three refusals *below* are answers to the question that was asked.
        let summarizer = try IntentBridge.requireSummarizer()
        let answer = await Self.answer(
            for: Self.target(
                parameter: pullRequest,
                // One row, because only the first is ever used. The queue itself is borrowed, not
                // restated: ``PullRequestEntity/reviewQueue(limit:)`` is what the badge, the focus
                // session, the morning digest and `Get Review Queue` all read.
                queue: PullRequestEntity.reviewQueue(limit: 1)
            ),
            summarizer: summarizer
        )
        return .result(dialog: answer.dialog, view: SummarySnippetView(answer: answer))
    }

    /// Which pull request a run is about.
    ///
    /// Pure, and separate from ``perform()`` so the rule is testable without the review queue
    /// having to exist: the parameter wins when a shortcut supplied one, otherwise the queue's
    /// first row is "my next review".
    /// - Parameters:
    ///   - parameter: What the shortcut or Siri supplied, if anything.
    ///   - queue: The review queue, most urgent first.
    /// - Returns: The pull request to summarise, or `nil` when nothing is waiting.
    static func target(
        parameter: PullRequestEntity?,
        queue: [PullRequestEntity]
    ) -> PullRequestEntity? {
        parameter ?? queue.first
    }

    /// One run's answer.
    ///
    /// Also pure over its two inputs, which is what lets a test drive every branch — spoken
    /// summary, unavailable model, unfetched detail, empty queue — with no window and no Siri.
    /// - Parameters:
    ///   - target: The pull request to summarise, or `nil` when nothing is waiting.
    ///   - summarizer: The seam onto the tier ladder.
    /// - Returns: What Siri says and the snippet shows.
    static func answer(
        for target: PullRequestEntity?,
        summarizer: PullRequestSummarizer
    ) async -> PullRequestSummaryAnswer {
        guard let target else { return .refusal(.nothingWaiting) }
        return await summarizer.summarize(target.id)
    }
}

/// The card Siri and Shortcuts draw beside the spoken answer (plan §3.H).
///
/// Deliberately styled with the system's own semantic fonts and hierarchical foreground styles
/// rather than with ``Theme``: a snippet is drawn inside Siri's chrome, on Siri's material, next
/// to other apps' snippets — not inside Shepherd's window — so following the system there is
/// correct rather than merely convenient, and it keeps this view free of the app's design tokens.
///
/// It shows exactly what the answer carries: the title, the slug, the overview, up to
/// ``SummarizedPullRequest/maximumRiskNotes`` risk notes, and a caption saying where the summary
/// came from. The caption is fixed because it cannot be wrong — the intent asks the router with
/// `onDeviceOnly: true`, so the on-device tier is the only rung that can have answered.
struct SummarySnippetView: View {
    /// What the run produced.
    let answer: PullRequestSummaryAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch answer {
            case .summary(let summarized):
                Text(summarized.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(summarized.slug)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(summarized.overview)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(summarized.riskNotes, id: \.self) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Text(String(localized: "Summarised on-device"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .refusal(let refusal):
                Text(refusal.sentence)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
