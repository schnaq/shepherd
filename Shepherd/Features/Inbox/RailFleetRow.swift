import SwiftUI

/// The fleet row pinned to the bottom of both left rails, directly above Settings (ADR 0035).
///
/// Extracted from the start rather than written twice, which is the lesson ``RailSettingsRow``
/// already records one file down: the pull-request rail and the issues rail draw the same pinned
/// footer, and two copies would be two places for a row height, an icon or a label to drift apart.
/// Both rails carry it because the fleet is not about either of them — it is about the agents whose
/// work fills both — so a reviewer who is looking at issues when the question occurs to them should
/// not have to go back to the pull requests to find the way in.
///
/// **Titled "Fleet" rather than "Agents", deliberately.** The pull-request rail already has an
/// AGENTS section a few rows further up, and every row in it *narrows this list to one agent*. A
/// pinned row with the same word on it would promise the same thing and do something else — leave
/// the inbox altogether — which is the one place in this rail where an ambiguous word actually
/// costs a wrong click. "Fleet" is the word the ⌘K command, the `shepherd fleet` verb and
/// `shepherd://fleet` all use, and the ⌘K title spells it out as *Show the agent fleet* for
/// somebody who searches for the other word.
struct RailFleetRow: View {
    @Environment(AppEnvironment.self) private var environment

    /// What the row promises, in the tooltip and in the spoken hint.
    ///
    /// One string in both places rather than two: a tooltip is invisible to a screen reader and a
    /// hint is invisible to a mouse, so a row explained in only one of them is explained to only
    /// half its readers (ADR 0033). The sentence names the scope — every agent, and what *became*
    /// of the work — because that is the fact that distinguishes this row from the AGENTS facet
    /// above it, which is about what is open right now.
    static var help: String {
        String(localized: "Every agent Shepherd has seen, and what became of its pull requests.")
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.border)
            Button {
                environment.openFleet()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.badge.gearshape")
                        .font(.system(size: 12))
                    Text(String(localized: "Fleet"))
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 34)
                // The whole row, not just the glyph and the word: a pinned control that only
                // takes a click on its text is a control people miss.
                .contentShape(Rectangle())
            }
            // `.plain` keeps it a row rather than a push button, and — the part that matters here
            // — it is still a `Button`, so Full Keyboard Access reaches it with Tab and ⌃F7 like
            // every other control in the rail. The fixed sizes match ``RailSettingsRow`` beside it
            // on purpose: the two are one pinned footer with one row height, and this surface is
            // not on the type scale yet (`Scripts/check-type-scale.py`, `docs/plans/accessibility.md`
            // §3), so moving one row of it alone would make the footer grow unevenly rather than
            // not at all.
            .buttonStyle(.plain)
            .help(RailFleetRow.help)
            .accessibilityHint(Text(RailFleetRow.help))
        }
        // No fill, for ``RailSettingsRow``'s reason: the sidebar's glass is the surface (ADR 0040).
    }
}
