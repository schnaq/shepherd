import Foundation
import ShepherdCore
import SwiftUI

/// The words a ⌘K issue row uses for "why this came up" (ADR 0032).
///
/// ``SearchResultPresentation``'s twin over four cases instead of nine, and every one of them
/// reuses that type's wording — an issue that matched on a label says the same thing a pull
/// request that matched on a label says. A palette that explained the same match in two different
/// sentences depending on which corpus answered would be worse than one that explained nothing.
enum IssueSearchResultPresentation {
    /// The "why it matched" line, or `nil` when there is nothing worth saying.
    ///
    /// A title match is not in the enum at all here (``ShepherdCore/IssueSearchMatchReason`` has
    /// four cases) for the reason the pull-request presenter returns `nil` for one: the title is
    /// the biggest thing on the row.
    /// - Parameter reason: What the ranker reported.
    static func reasonLine(for reason: IssueSearchMatchReason?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case .exactReference:
            // The query named this issue outright, and the row is showing its number.
            return nil
        case .label(let label):
            return String(localized: "label \(label)")
        case .body:
            return String(localized: "in the description")
        case .semantic:
            return String(localized: "related by meaning")
        }
    }
}

/// One issue row in the ⌘K palette (ADR 0032).
///
/// ``SearchResultRowView``'s twin, same height and same four columns, with the two a pull request
/// has and an issue has not — the CI dot and the diff counts — replaced by the one an issue has
/// and a pull request has not: whether a machine already has a pull request for it. That is the
/// single thing a reader deciding *what to assign next* wants off a search result.
struct IssueSearchResultRowView: View {
    /// The ranked issue.
    let result: IssueSearchMatch
    /// Whether the keyboard cursor is on this row.
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.summary.hasAgentPullRequest
                ? "arrow.triangle.pull"
                : "smallcircle.circle")
                .font(.system(size: 11))
                .foregroundStyle(
                    result.summary.hasAgentPullRequest ? Theme.agent : Theme.textMuted
                )
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("\(result.summary.repo.name) #\(result.summary.number)")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                        .layoutPriority(1)
                    Text(result.summary.title)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Theme.textStrong : Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let reason = IssueSearchResultPresentation.reasonLine(for: result.reason) {
                    Text(reason)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if result.summary.state == .closed {
                // A closed issue stays in the index for the retention window (ADR 0032), and the
                // click lands: the section observes the retained rows and the reveal widens its
                // state facet to show this one (that ADR's 2026-09-04 amendment). The chip is
                // still worth its width — whether an issue is already dealt with is the first
                // thing a reader wants off a search result — it is simply no longer a warning.
                ChipView(text: String(localized: "Closed"), color: Theme.textMuted)
                    .layoutPriority(1)
            }
            ProvenanceChip(actor: result.summary.author, size: 10)
                .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            isSelected ? Theme.accent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        let base = "\(result.summary.slug): \(result.summary.title)"
        guard let reason = IssueSearchResultPresentation.reasonLine(for: result.reason) else {
            return base
        }
        return String(localized: "\(base). Matched: \(reason)")
    }
}
