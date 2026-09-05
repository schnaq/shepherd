import ShepherdCore
import SwiftUI

/// One agent's row in the fleet list: what is on your plate from it, and what became of the rest.
///
/// **There is no ``ShepherdCore/TrackRecord/chipColor`` and no `chipTone` on this screen, and
/// that is a rule rather than an omission.** Those two exist so an inbox row can be interrupted
/// for the one fact worth interrupting a reading for — something this author merged was taken
/// back out — and they are read there beside a single pull request somebody is about to open. A
/// *list of agents*, each tinted by how its own history has gone, is a ranking whatever the
/// surrounding words say: green rows and amber rows sort themselves in the reader's eye without
/// anybody having written a sort. So this row prints counts and the agent's own palette colour,
/// which says *which agent* and nothing about how it has done, and there is no code path from
/// here to either property.
///
/// Every number has a word beside it (ADR 0033), and the closed-side facts read as an em-dash
/// rather than as a zero when nothing was counted: "0 merged" is a claim about an agent, and an
/// agent whose work all closed before the window is not one Shepherd has anything to say about.
struct FleetAgentRow: View {
    /// The agent this row is about.
    let agent: FleetAgent
    /// Whether the cursor is on this row.
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // The palette dot carries no meaning the name does not: it is the colour the
                // provenance chip beside this agent's pull requests already uses, so the two
                // surfaces are recognisably about one agent. The word beside the colour
                // (ADR 0033) is the agent's name, right next to it.
                Circle()
                    .fill(AgentPalette.color(forAgentID: FleetAgentRow.paletteID(for: agent)))
                    .frame(width: 8, height: 8)
                Text(agent.displayName)
                    .font(Theme.type(.body, weight: .medium))
                    .foregroundStyle(Theme.textStrong)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            Text(FleetAgentRow.openText(for: agent))
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(FleetAgentRow.closedText(for: agent))
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(
                        agent.overall.isEmpty
                            ? FleetCell.absentSpoken
                            : FleetAgentRow.closedText(for: agent)
                    )
                Spacer(minLength: 8)
                lastClosed
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.selection : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Theme.accent).frame(width: 2)
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(FleetAgentRow.spokenSentence(for: agent)))
    }

    @ViewBuilder
    private var lastClosed: some View {
        if let date = agent.lastClosedAt {
            RelativeDateText(date: date)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .layoutPriority(1)
        } else {
            Text(FleetCell.absent)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .help(FleetCell.absentSpoken)
                .layoutPriority(1)
        }
    }

    // MARK: - What the row says
    //
    // `static` and internal, for the reason `CheckDotView.spokenState(_:)` and
    // `TrackRecordBadge.sentence(authorName:record:)` are: the row draws these strings and
    // announces them, and one definition is the only arrangement in which the two cannot drift.
    // It is also what lets a test assert that the spoken order is the drawn order rather than
    // somebody listening to a window.

    /// The id the palette colours an agent by.
    ///
    /// The registry id when a live pull request carried one, and otherwise the row's own
    /// identity — the lower-cased display name. ``AgentPalette/color(forAgentID:)`` answers an
    /// unknown id out of its deterministic bucket fallback, so an agent only history knows gets
    /// one stable colour instead of none, and keeps it across launches.
    /// - Parameter agent: The agent.
    /// - Returns: The palette key.
    static func paletteID(for agent: FleetAgent) -> String {
        agent.registryID ?? agent.id
    }

    /// The live half: how much of this agent's work is open, and how much of that is yours.
    /// - Parameter agent: The agent.
    /// - Returns: The line.
    static func openText(for agent: FleetAgent) -> String {
        [
            String(localized: "\(agent.openCount) open"),
            String(localized: "\(agent.openAwaitingReviewCount) waiting on you"),
        ].joined(separator: " · ")
    }

    /// The counted half, plus how many repositories this agent shows up in at all.
    ///
    /// The repository count is on the live side of the em-dash rule and stays a number: it is the
    /// union of the repositories the agent has closed something in and the ones it has something
    /// open in, so it means something even when nothing has been counted.
    /// - Parameter agent: The agent.
    /// - Returns: The line.
    static func closedText(for agent: FleetAgent) -> String {
        [countsText(for: agent), String(localized: "\(agent.repositories.count) repositories")]
            .joined(separator: " · ")
    }

    private static func countsText(for agent: FleetAgent) -> String {
        let record = agent.overall
        guard !record.isEmpty else { return FleetCell.absent }
        return [
            String(localized: "\(record.merged) merged"),
            String(localized: "\(record.reverted) reverted"),
        ].joined(separator: " · ")
    }

    /// The row's spoken label: everything the row draws, in the order it draws it (ADR 0033).
    ///
    /// `.accessibilityElement(children: .combine)` would concatenate the siblings' own labels and
    /// the `.accessibilityLabel` beside it *replaces* that, so this has to say the whole row or
    /// the row says only its name. Six facts are drawn and six are spoken: the agent, what is
    /// open and what of that is yours, the merges, the reverts, the repositories and the last
    /// close.
    ///
    /// The em-dashes become words here rather than being read out as punctuation — a dash is a
    /// glyph, and a glyph is never the only carrier of a fact.
    /// - Parameter agent: The agent.
    /// - Returns: The sentence.
    static func spokenSentence(for agent: FleetAgent) -> String {
        let record = agent.overall
        return SpokenRow.sentence([
            agent.displayName,
            openText(for: agent),
            record.isEmpty ? FleetCell.absentSpoken : String(localized: "\(record.merged) merged"),
            record.isEmpty ? nil : String(localized: "\(record.reverted) reverted"),
            String(localized: "\(agent.repositories.count) repositories"),
            agent.lastClosedAt.map {
                String(localized: "last closed \(RelativeDate.long($0))")
            },
        ])
    }
}
