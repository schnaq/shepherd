import Foundation
import ShepherdCore

/// The three sentences the fleet states unprompted, in words (plan §3).
///
/// Static functions on a type of their own rather than methods on a view, which is
/// ``TrackRecordProgressLine``'s arrangement and its reason: an app test can assert the sentence
/// a user reads without building a screen. And it is here rather than in ShepherdCore because a
/// user-visible string is localised (ADR 0022) and that package has no such strings by decision —
/// ``ShepherdCore/FleetNotice`` therefore carries counts, denominators and a repository, and no
/// wording at all.
///
/// **The percentages are computed here, from the counts the notice carries.** That is the second
/// half of the same decision: a notice has to be checkable against the per-repository grid drawn
/// underneath it, so what travels out of the detector is the two numbers a rate was made of and
/// what is formatted here is the rate. A case that carried a finished percentage could quietly
/// stop matching the grid, and nobody would be able to tell by reading it.
///
/// Nothing here is a verdict and nothing here can act. A notice is a sentence: it names no pull
/// request to fix, it offers no button, and there is no code path from one to a write.
///
/// `@MainActor` because ``TrackRecordBadge/percentText(_:)`` is a static member of a `View` and
/// inherits that isolation — and reusing it is the point, because "78 %" with its non-breaking
/// space is a typographic decision this screen must not make a second time.
@MainActor
enum FleetNoticeText {
    /// One notice as one sentence.
    ///
    /// Every sentence names its repository, which is what makes it checkable: the reader who
    /// doubts it can find that repository's row in the grid below and count it themselves.
    /// - Parameter notice: The notice to word.
    /// - Returns: The sentence.
    static func text(for notice: FleetNotice) -> String {
        switch notice {
        case .reworkStreak(let agent, let repo, let streak):
            return String(
                localized: "The last \(streak) pull requests \(agent) closed in \(repo.fullName) all had changes requested at least once."
            )
        case .greenRateGap(
            let agent,
            let repo,
            let greenHere,
            let totalHere,
            let greenElsewhere,
            let totalElsewhere,
            let otherRepositoryCount
        ):
            let here = percentText(greenHere, of: totalHere)
            let elsewhere = percentText(greenElsewhere, of: totalElsewhere)
            // The repository count is its own clause rather than a number inside the sentence,
            // and that is a localisation decision rather than a stylistic one: a count that has
            // to agree with its noun goes through the catalog's plural variations (ADR 0022),
            // and a variation can only be selected for a string whose *one* argument is that
            // count. So the phrase carrying the count is looked up on its own and lands in the
            // sentence as one more `%@`, which a translator can move wherever their grammar
            // wants it.
            let others = String(
                localized: "the other \(otherRepositoryCount) repositories Shepherd has counted"
            )
            return String(
                localized: "\(agent)'s first push is green in \(here) of its pull requests to \(repo.fullName), and in \(elsewhere) across \(others)."
            )
        case .revertShareGap(let repo, let higher, let lower):
            // Counts on both sides rather than the two shares the detector compared: "3 of 24"
            // and "0 of 19" are four numbers a reader can look up on GitHub, while "12 % against
            // 0 %" is a pair of derived figures that reads like a scoreboard — which is the one
            // thing the fleet's single cross-agent sentence must not be.
            return String(
                localized: "In \(repo.fullName), \(higher.reverted) of \(higher.agent)'s \(higher.merged) merges were reverted; \(lower.reverted) of \(lower.agent)'s \(lower.merged) were."
            )
        }
    }

    /// A share as whole percent, from the two counts it was made of.
    ///
    /// An empty denominator answers with the em-dash rather than with `0 %`, which is ADR 0027's
    /// rule for ``ShepherdCore/TrackRecord/firstPushGreenRate`` written out for a caller that has
    /// the counts instead of the rate: "nothing is known" and "it was never green" are different
    /// facts and only one of them is an accusation. ``FleetNotices`` cannot actually produce an
    /// empty denominator — its smallest is five on each side — so this branch is a property of
    /// the function rather than a case the screen reaches, and it is written down because a
    /// threshold is a number somebody may lower.
    /// - Parameters:
    ///   - part: The numerator.
    ///   - total: The denominator.
    /// - Returns: The percentage, or the em-dash.
    static func percentText(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return FleetCell.absent }
        return TrackRecordBadge.percentText(Int((Double(part) / Double(total) * 100).rounded()))
    }
}
