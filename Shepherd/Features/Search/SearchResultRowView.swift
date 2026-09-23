import ShepherdCore
import SwiftUI

/// The words a ⌘K pull-request row uses for "why this came up" (ADR 0019).
///
/// A separate type from the row for the reason ``DigestPresentation`` is separate from the digest
/// card: the wording is the thing worth testing, and a view is the thing that cannot be. Every
/// case is one short line — the palette row has one line of space, and a snippet that wrapped
/// would push the next result off screen.
enum SearchResultPresentation {
    /// The "why it matched" line, or `nil` when there is nothing worth saying.
    ///
    /// A title match returns `nil` on purpose: the title is already the largest thing on the row,
    /// and "matched: the title" spends a line telling the reader what they can see.
    /// - Parameter reason: What the ranker reported.
    static func reasonLine(for reason: SearchMatchReason?) -> String? {
        // Unwrapped first rather than switched over the optional: an enum-case pattern against an
        // `Optional` needs a `?` on every case, and one forgotten `?` is a compile error that
        // reads as a missing enum member.
        guard let reason else { return nil }
        switch reason {
        case .exactReference:
            // The query named this pull request outright, and the row is showing its number.
            return nil
        case .label(let label):
            return String(localized: "label \(label)")
        case .filePath(let path):
            return path
        case .addedLine(let line):
            return trimmed(line)
        case .branch(let branch):
            return branch
        case .author(let author):
            return String(localized: "by \(author)")
        case .body:
            return String(localized: "in the description")
        case .semantic:
            return String(localized: "related by meaning")
        }
    }

    /// How long a snippet may be before it is cut.
    ///
    /// A single added line of a diff can be several hundred characters; the row has room for
    /// roughly this many before the trailing chips are pushed out.
    static let snippetLength = 90

    private static func trimmed(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > snippetLength else { return collapsed }
        return String(collapsed.prefix(snippetLength)) + "…"
    }
}

/// One pull-request row in the ⌘K palette.
///
/// Deliberately *not* an ``InboxRowView``: that row is 46 points tall, carries a tick column, a
/// diff-count pair and a relative date, and is designed for a list you scan. A palette row has to
/// fit six of itself into a 330-point scroll area beside the commands, so it keeps the four things
/// that identify a pull request — repo and number, title, who wrote it, CI state — and adds the
/// one thing the inbox never has to explain: why this row is an answer to what you typed.
struct SearchResultRowView: View {
    /// The ranked pull request.
    let result: PullRequestSearchResult
    /// Whether the keyboard cursor is on this row.
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            CheckDotView(state: result.summary.checkRollup?.state)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("\(result.summary.repo.name) #\(String(result.summary.number))")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                        .layoutPriority(1)
                    Text(result.summary.title)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Theme.textStrong : Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let reason = SearchResultPresentation.reasonLine(for: result.reason) {
                    Text(reason)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
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

    /// The row's spoken label: the pull request, why it matched, and the chips beside it.
    ///
    /// ``IssueSearchResultRowView``'s reasoning: an `.accessibilityLabel` replaces the combined
    /// children's labels, so the CI dot and the provenance chip were drawn and never spoken.
    private var accessibilityText: String {
        SpokenRow.sentence([
            CheckDotView.spokenState(result.summary.checkRollup?.state),
            "\(result.summary.slug): \(result.summary.title)",
            SearchResultPresentation.reasonLine(for: result.reason)
                .map { String(localized: "Matched: \($0)") },
            ProvenanceChip.spokenProvenance(of: result.summary.author),
        ])
    }
}
