import Foundation
import Observation
import ShepherdCore

/// Everything ``ClaimsEvidenceCard`` draws and everything pressing a button on it does — as a
/// pure value, so the three rules worth getting right are unit-tested rather than inferred from a
/// screenshot (ADR 0026).
///
/// - **An empty report means no card.** A description that claims nothing has not asked a
///   question, so there is nothing to answer; ``isHidden`` is the whole of that rule.
/// - **Agent pull requests open expanded, human ones collapsed.** The provenance facet of
///   ADR 0008, applied to the one card whose reason for existing is the agent flood. The
///   reviewer's own toggle outranks it from then on (``didChooseExpansion``), because a
///   background refresh that re-collapsed the card the reviewer had just opened would be worse
///   than a wrong default.
/// - **A finding never silently overwrites the summary.** Same rule as ``AIDraftFieldState``'s,
///   for the same reason — but deliberately *not* the same code path: this text is not generated,
///   so it carries no tier, no "AI draft" caption and no sparkles. What it borrows is the
///   question, and ``ShepherdCore/SavedReply/inserting(_:into:)`` for the append, which is the
///   app's one documented answer to "how does text get added to a composer".
struct ClaimsEvidenceCardState: Equatable, Sendable {
    /// A finding waiting for the reviewer to answer replace-or-append.
    struct PendingInsertion: Equatable, Sendable {
        /// The text that will be written into the summary.
        var text: String
    }

    /// The reviewer's answer to that question.
    enum Choice: Equatable, Sendable {
        /// The finding takes the field.
        case replace
        /// The finding goes after what is already there.
        case append
    }

    /// What "Turn into a comment" asks the caller to do.
    enum Insertion: Equatable, Sendable {
        /// Write this into the review summary; the field was empty.
        case write(String)
        /// Nothing has been written: the field was not empty and the question is now up.
        case askFirst
    }

    /// The claims and their evidence.
    var report: ClaimsEvidenceReport
    /// Whether the rows are showing.
    var isExpanded: Bool
    /// Whether ``isExpanded`` is the reviewer's own decision rather than the provenance default.
    var didChooseExpansion: Bool
    /// The finding waiting for a replace-or-append answer, if any.
    var pendingInsertion: PendingInsertion?
    /// Whether a finding has been written into the summary on this screen.
    ///
    /// Only for the one line of confirmation the card shows: the summary field lives in the
    /// submit sheet, so a reviewer who presses the button and sees nothing move would reasonably
    /// conclude the button is broken.
    var didInsertIntoSummary: Bool

    /// Creates the state for one pull request.
    /// - Parameters:
    ///   - report: The claims and their evidence.
    ///   - provenance: The pull request author's detected kind. A recognised coding agent opens
    ///     the card; a human — and a bot that is *not* a recognised agent — leaves it collapsed.
    init(report: ClaimsEvidenceReport = .empty, provenance: ActorKind = .human) {
        self.report = report
        self.isExpanded = provenance.agentIdentity != nil
        self.didChooseExpansion = false
        self.pendingInsertion = nil
        self.didInsertIntoSummary = false
    }

    /// Whether to draw nothing at all.
    var isHidden: Bool { report.isEmpty }

    /// The rows, in the report's order.
    var lines: [ClaimsEvidenceReport.Line] { report.lines }

    /// The reviewer opening or closing the card, which also settles the default from then on.
    mutating func toggleExpansion() {
        isExpanded.toggle()
        didChooseExpansion = true
    }

    /// The text one contradicted line becomes in the review summary: the claim, then the facts.
    ///
    /// The claim's own sentence comes first because that is what the author will recognise, and
    /// the facts follow as the reason. Every fact is already a sentence
    /// (``ShepherdCore/EvidenceFact``), so joining them with a space produces prose rather than a
    /// list — the reviewer edits it in the composer anyway, and a bullet list would be a shape
    /// they have to undo before writing their own sentence.
    /// - Parameter line: The line the button was pressed on.
    /// - Returns: The text to insert.
    static func commentText(for line: ClaimsEvidenceReport.Line) -> String {
        let facts = line.verdict.facts.map(\.text).joined(separator: " ")
        let quote = line.claim.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !facts.isEmpty else { return quote }
        guard !quote.isEmpty else { return facts }
        return "\(quote) — \(facts)"
    }

    /// "Turn into a comment" on one line.
    /// - Parameters:
    ///   - line: The line the button was pressed on.
    ///   - existingSummary: What the review summary holds right now.
    /// - Returns: The text to write, or that the reviewer has to be asked first.
    mutating func turnIntoComment(
        _ line: ClaimsEvidenceReport.Line,
        existingSummary: String
    ) -> Insertion {
        let text = Self.commentText(for: line)
        guard existingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingInsertion = PendingInsertion(text: text)
            didInsertIntoSummary = false
            return .askFirst
        }
        pendingInsertion = nil
        didInsertIntoSummary = true
        return .write(text)
    }

    /// Applies the reviewer's answer to the replace-or-append question.
    /// - Parameters:
    ///   - choice: What they picked.
    ///   - existingSummary: What the review summary holds right now.
    /// - Returns: The text to write, or `nil` when nothing was waiting.
    mutating func resolveInsertion(_ choice: Choice, existingSummary: String) -> String? {
        guard let pending = pendingInsertion else { return nil }
        pendingInsertion = nil
        didInsertIntoSummary = true
        switch choice {
        case .replace:
            return pending.text
        case .append:
            return SavedReply.inserting(pending.text, into: existingSummary)
        }
    }

    /// Throws the waiting finding away. The summary is untouched, because it never was touched.
    mutating func discardInsertion() {
        pendingInsertion = nil
    }
}

/// Holds one pull request's claims card for as long as the review screen is open.
///
/// It exists for one reason: ``ShepherdCore/ClaimsEvidenceReport/build(detail:summary:)`` walks
/// every hunk of every file, and a SwiftUI `body` that computed it would do that on every redraw.
/// So the report is built when the pull request's data actually changes and cached until it does
/// — the equality check is on the whole ``ShepherdCore/PullRequestDetail``, which is exact and
/// (thanks to copy-on-write storage) cheap next to the work it avoids.
///
/// Nothing here is persisted. A card is a reading aid, like the CI diagnosis and the thread
/// digest, and it is recomputed from the database's own rows next time the screen opens.
@MainActor
@Observable
final class ClaimsEvidenceModel {
    /// What the card draws, and what its buttons act on.
    var state = ClaimsEvidenceCardState()

    /// The detail the current ``state`` was built from.
    private var builtFrom: PullRequestDetail?

    /// Creates an empty model. No report is built until ``refresh(detail:)`` is called.
    init() {}

    /// Rebuilds the report when the pull request's data changed, and does nothing when it did not.
    /// - Parameter detail: The pull request, or `nil` while it is still loading.
    func refresh(detail: PullRequestDetail?) {
        guard builtFrom != detail else { return }
        builtFrom = detail
        let report = detail.map { current in
            ClaimsEvidenceReport.build(detail: current, summary: current.summary)
        } ?? .empty
        var next = ClaimsEvidenceCardState(
            report: report,
            provenance: detail?.summary.author.kind ?? .human
        )
        // The reviewer's own toggle survives a background refresh; the provenance default does
        // not have to, because it is a default.
        if state.didChooseExpansion {
            next.isExpanded = state.isExpanded
            next.didChooseExpansion = true
        }
        state = next
    }
}
