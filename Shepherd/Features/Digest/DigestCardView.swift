import ShepherdCore
import SwiftUI

/// The morning digest as a card above the inbox list.
///
/// The quiet half of the feature. The notification is the announcement, and it happens once; this
/// is what is still there when the user actually sits down — one line per section, the first pull
/// request of each named so the card says something concrete rather than only counting, and a
/// *Show* that hands the section over to the inbox instead of trying to be a second list.
///
/// It is dismissible and it expires on its own when the day rolls over
/// (``DigestCoordinator/report``), because a permanent banner above the list would stop being read
/// within a week.
struct DigestCardView: View {
    /// What the digest found.
    let report: DigestReport
    /// Hands a section over to the inbox.
    var onShow: (DigestSectionKind) -> Void
    /// Hides the card for the rest of the day.
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    ForEach(report.sections) { section in
                        row(for: section)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                String(
                    localized: "\(DigestPresentation.greeting). \(DigestPresentation.summary(for: report))"
                )
            )
        )
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            CardTitle(DigestPresentation.greeting.uppercased(), tint: Theme.accentText)
            Text(DigestPresentation.windowDescription(for: report))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Dismiss the digest until tomorrow"))
            .accessibilityLabel(Text(String(localized: "Dismiss the digest")))
        }
    }

    private func row(for section: DigestReport.Section) -> some View {
        HStack(spacing: 8) {
            Image(systemName: DigestPresentation.systemImage(for: section.kind))
                .font(.system(size: 11))
                .foregroundStyle(DigestPresentation.tint(for: section.kind))
                .frame(width: 14)

            Text(DigestPresentation.line(for: section))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .layoutPriority(1)

            if let lead = section.items.first {
                // The leading pull request by name, so the card is concrete. One, not three: the
                // digest is a glance, and "Show" is right there for the rest.
                Text("\(lead.slug) \(lead.title)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Button(String(localized: "Show")) { onShow(section.kind) }
                .buttonStyle(SecondaryButtonStyle(height: 24))
                .help(DigestPresentation.help(for: section.kind))
                .layoutPriority(1)
        }
    }
}
