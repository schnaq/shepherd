import ShepherdCore
import SwiftUI

/// What an inbox row says about its pull request in words — the one status chip, and the sentence
/// VoiceOver reads for the whole row — and the dot in front of its section's header.
///
/// Both apps draw an inbox row — the Mac's `InboxRowView` and the iPhone's `PhoneInboxRow`
/// (ADR 0044) — and the two rows are laid out differently, for a pointer and for a thumb. What
/// they must not do is *disagree*: which chip wins when CI is red and a merge is queued, and what a
/// listener hears, are decisions about the pull request rather than about the screen. So they live
/// here, in a file both targets compile, and not in `InboxListView.swift`, which the phone cannot
/// compile (it is bound to `AppEnvironment` and the keyboard).
enum InboxRowText {
    /// The one status chip a row shows, or `nil` when there is nothing to say.
    ///
    /// One chip, in a fixed order of what needs the reviewer most: a write on its way or stuck
    /// (``RowWriteState``) takes the chip's place while it lasts, because "your merge is on its way"
    /// is what the reviewer who just pressed it is looking for; then a conflict with the base
    /// branch, which no green suite or approval can merge past; then red CI, running CI, the review
    /// decision, and finally a review request nobody has answered yet.
    /// - Parameters:
    ///   - row: The pull request.
    ///   - write: What the outbox is doing for it, or `nil` when nothing is on its way.
    /// - Returns: The chip's words and colour.
    static func statusChip(for row: PullRequestSummary, write: RowWriteState?) -> (text: String, color: Color)? {
        if let write {
            return (write.text, write.color)
        }
        if row.mergeable == .conflicting {
            return (String(localized: "Conflicts"), Theme.failure)
        }
        if let rollup = row.checkRollup, rollup.state == .failure {
            let count = max(1, rollup.failureCount)
            return (String(localized: "\(count) checks failing"), Theme.failure)
        }
        if let rollup = row.checkRollup, rollup.state == .pending {
            return (String(localized: "CI running"), Theme.pending)
        }
        if let decision = row.reviewDecision {
            return (decision.chipTitle, decision.chipColor)
        }
        if row.myRelation.contains(.reviewRequested) {
            return (String(localized: "Review requested"), Theme.accentText)
        }
        return nil
    }

    /// The row's spoken label: everything the row shows, in the order it shows it.
    ///
    /// `.accessibilityElement(children: .combine)` would concatenate the siblings' own labels, and
    /// the `.accessibilityLabel` beside it *replaces* that — so this has to say the whole row or
    /// the row says only its number and title. The checks, which pull request, its title, who
    /// opened it, whether it answers a session, what triage made of it, whether it is a draft,
    /// where it sits in a stack, how many rounds it has been reviewed in, its status chip, its
    /// size and its age. Each part comes from the same value the view draws, through the
    /// components' own spoken forms, so a row cannot describe itself differently from its chips.
    /// - Parameters:
    ///   - row: The pull request.
    ///   - selection: Said first — the Mac's "Selected" / "Not selected" while a bulk selection is
    ///     under way — or `nil`.
    ///   - hasSession: Whether its head commits carry a session to answer to (ADR 0030).
    ///   - triage: The triage chip's spoken title (ADR 0023), or `nil` where there is none.
    ///   - rounds: What the row says about its review rounds (ADR 0028).
    ///   - write: What the outbox is doing for it.
    /// - Returns: The sentence.
    static func spokenLabel(
        for row: PullRequestSummary,
        selection: String? = nil,
        hasSession: Bool,
        triage: String? = nil,
        rounds: ReviewRoundsSummary?,
        write: RowWriteState?
    ) -> String {
        SpokenRow.sentence([
            selection,
            CheckDotView.spokenState(row.checkRollup?.state),
            "\(row.slug): \(row.title)",
            ProvenanceChip.spokenProvenance(of: row.author),
            hasSession ? String(localized: "Has a session to answer to") : nil,
            triage,
            row.isDraft ? String(localized: "Draft") : nil,
            row.stack?.chipHelp,
            rounds?.chipText,
            statusChip(for: row, write: write)?.text,
            DiffCountsView.spokenCounts(additions: row.additions, deletions: row.deletions),
            RelativeDate.long(row.updatedAt),
        ])
    }

    /// The coloured square in front of a section header, or `nil` when the section has none.
    ///
    /// Only the provenance grouping has one — an agent's palette colour, the accent for people,
    /// the muted secondary for bots — because only there does the colour repeat something the
    /// rows below it already say with their chips.
    /// - Parameter section: The section.
    /// - Returns: The dot's colour.
    static func sectionDot(for section: InboxSection) -> Color? {
        guard section.facet == .provenance else { return nil }
        if section.id.hasPrefix("agent:") {
            return AgentPalette.color(forAgentID: String(section.id.dropFirst("agent:".count)))
        }
        return section.id == "human" ? Theme.accent : Theme.textSecondary
    }
}
