import ShepherdCore
import SwiftUI

/// One pull request in the iPhone's inbox (ADR 0044): the Mac row's facts, laid out for a thumb.
///
/// Three lines where the Mac has two, and no fixed height: on a 390 pt screen the title needs a
/// line of its own and may need two, and a row that pinned its height would clip it the moment
/// Dynamic Type grew. Line one places the pull request — repository, number and age — line two is
/// the title, line three is the chips. The author's avatar leads the row, with the CI dot set into
/// its corner the way Messages badges a contact, so the two things a reviewer scans for first —
/// who opened it and whether it is green — sit together at the edge of the thumb's reach.
///
/// What the row *says* is not decided here: the status chip and the spoken sentence are
/// ``InboxRowText``'s, which the Mac's `InboxRowView` reads as well, so the two apps cannot
/// disagree about a pull request. Every fact is passed in rather than read from the model, for the
/// Mac row's reason: a row is a value renderer.
struct PhoneInboxRow: View {
    /// The pull request.
    let row: PullRequestSummary
    /// What it says about its review rounds, or `nil` when it has none (ADR 0028).
    var rounds: ReviewRoundsSummary?
    /// Whether its head commits carry a session to answer to (ADR 0030).
    var hasSession = false
    /// The author's track record here, which tints the provenance chip (ADR 0027).
    var trackRecord: TrackRecord?
    /// What the outbox is doing for it, or `nil` when nothing is on its way.
    var write: RowWriteState?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The shared chips take a point size rather than a text style, so the phone scales the size
    /// it hands them: they grow with Dynamic Type instead of staying Mac-small beside large text.
    @ScaledMetric(relativeTo: .caption) private var chipSize: CGFloat = 12
    /// The diff counts' size, scaled for the chips' reason.
    @ScaledMetric(relativeTo: .footnote) private var countsSize: CGFloat = 12
    /// The avatar's diameter.
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 40
    /// The CI dot's diameter.
    @ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 11

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // At the accessibility sizes the avatar goes, as Mail drops its pictures there: a
                // leading column — or one beside the place line — left a few words per line. The
                // CI dot it carried leads the place line instead, which is one wrapping sentence,
                // then the title and the chips take the whole width.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CheckDotView(state: row.checkRollup?.state, size: min(dotSize, 16))
                        placeAndAge
                    }
                    title
                    chips
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            place
                            Spacer(minLength: 4)
                            age
                        }
                        title
                        chips
                            .padding(.top, 2)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        // Combined and relabelled, as the Mac row is: one element that says everything it draws.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(InboxRowText.spokenLabel(
            for: row,
            hasSession: hasSession,
            rounds: rounds,
            write: write
        )))
    }

    /// Which pull request: repository and number, shortened in the middle as the Mac shortens it —
    /// the number is the half that tells two rows of one repository apart.
    private var place: some View {
        Text(verbatim: "\(row.repo.name) #\(row.number)")
            .font(Theme.mono(.footnote))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .truncationMode(.middle)
    }

    /// Place and age as one wrapping sentence, for the accessibility sizes: two views side by side
    /// stacked "shepherd", "#412" and "24 m" on three lines.
    private var placeAndAge: some View {
        let place = Text(verbatim: "\(row.repo.name) #\(row.number)")
            .font(Theme.mono(.footnote))
            .foregroundStyle(Theme.textSecondary)
        // No-break spaces in "· 24 m", so the dot never ends a line apart from its age.
        let age = Text(verbatim: "·\u{00A0}" + RelativeDate.short(row.updatedAt).replacingOccurrences(of: " ", with: "\u{00A0}"))
            .font(Theme.type(.footnote))
            .foregroundStyle(Theme.textMuted)
        return Text("\(place) \(age)")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var age: some View {
        RelativeDateText(date: row.updatedAt)
            .font(Theme.type(.footnote))
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
            .fixedSize()
    }

    private var title: some View {
        Text(row.title)
            .font(Theme.type(.body, weight: .medium))
            .foregroundStyle(Theme.textStrong)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The author's picture with the CI dot set into its lower corner.
    private var avatar: some View {
        AvatarView(
            login: row.author.login,
            displayName: row.author.displayName,
            url: row.author.avatarURL,
            // Capped: past this a picture only takes width from the words beside it.
            size: min(avatarSize, 56)
        )
        .overlay(alignment: .bottomTrailing) {
            CheckDotView(state: row.checkRollup?.state, size: min(dotSize, 16))
                .padding(2)
                .background(Theme.background, in: Circle())
                .offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
    }

    /// The chip line.
    ///
    /// On one line while it fits, dropping the chips a reviewer needs least first — rounds, then
    /// the stack, then the draft tag — because a chip line that wraps on a phone pushes the next
    /// pull request off the screen. At the accessibility sizes nothing fits on one line anyway, so
    /// the chips stack instead of being dropped: a larger text size must not mean less information.
    @ViewBuilder
    private var chips: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                chipItems(draft: true, stack: true, rounds: true)
                diffCounts
            }
        } else {
            ViewThatFits(in: .horizontal) {
                chipLine(draft: true, stack: true, rounds: true)
                chipLine(draft: true, stack: true, rounds: false)
                chipLine(draft: true, stack: false, rounds: false)
                chipLine(draft: false, stack: false, rounds: false)
            }
        }
    }

    private func chipLine(draft: Bool, stack: Bool, rounds: Bool) -> some View {
        HStack(spacing: 6) {
            chipItems(draft: draft, stack: stack, rounds: rounds)
            Spacer(minLength: 4)
            diffCounts
        }
    }

    @ViewBuilder
    private func chipItems(draft: Bool, stack: Bool, rounds showsRounds: Bool) -> some View {
        ProvenanceChip(actor: row.author, size: chipSize, tint: trackRecord?.chipColor)

        if hasSession {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(Theme.type(.caption))
                .foregroundStyle(Theme.agent)
        }

        if let status = InboxRowText.statusChip(for: row, write: write) {
            ChipView(text: status.text, color: status.color, size: chipSize)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .snappy, value: status.text)
        }

        if draft, row.isDraft {
            ChipView(text: String(localized: "Draft"), color: Theme.textMuted, size: chipSize)
        }

        if stack, let stackInfo = row.stack {
            ChipView(text: stackInfo.chipText, color: Theme.textSecondary, size: chipSize)
        }

        if showsRounds, let text = rounds?.chipText {
            ChipView(
                text: text,
                color: (rounds?.unchangedFindingCount ?? 0) > 0 ? Theme.pending : Theme.textSecondary,
                size: chipSize
            )
        }
    }

    private var diffCounts: some View {
        DiffCountsView(additions: row.additions, deletions: row.deletions, size: countsSize)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A grey stand-in for a row, for the seconds before the first sweep has answered.
///
/// Shaped like ``PhoneInboxRow`` so the list does not jump when the real rows arrive, and
/// redacted text rather than drawn bars so it scales with Dynamic Type exactly as they will.
struct PhoneInboxPlaceholderRow: View {
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 40

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Theme.control)
                .frame(width: avatarSize, height: avatarSize)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "repository #1234")
                    .font(Theme.mono(.footnote))
                Text(verbatim: "A pull request title that needs most of a line")
                    .font(Theme.type(.body))
                Text(verbatim: "author-login · status")
                    .font(Theme.type(.caption))
            }
            .redacted(reason: .placeholder)
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}

/// The pinned header of one inbox section: the provenance dot, the title in small capitals, and
/// how many rows it holds.
struct PhoneSectionHeader: View {
    /// The header text, in the user's language.
    let title: String
    /// How many rows the section holds.
    let count: Int
    /// The dot in front of the title, or `nil` for none (``InboxRowText/sectionDot(for:)``).
    var dot: Color?

    /// A header for one of the model's sections.
    /// - Parameter section: The section.
    init(section: InboxSection) {
        self.init(title: section.localizedTitle, count: section.count, dot: InboxRowText.sectionDot(for: section))
    }

    /// A header with its own title, for the search results.
    /// - Parameters:
    ///   - title: The header text.
    ///   - count: How many rows it holds.
    ///   - dot: The dot's colour, or `nil` for none.
    init(title: String, count: Int, dot: Color? = nil) {
        self.title = title
        self.count = count
        self.dot = dot
    }

    var body: some View {
        HStack(spacing: 8) {
            if let dot {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(dot)
                    .frame(width: 8, height: 8)
            }
            // One `Text`, so the count stays with the title rather than floating beside a wrapped
            // one; shrunk a little before it is cut, never wrapped.
            Text("\(Text(title.uppercased()).font(Theme.type(.footnote, weight: .semibold)).kerning(0.5).foregroundStyle(Theme.textSecondary)) \(Text(verbatim: "· \(count)").font(Theme.type(.footnote)).foregroundStyle(Theme.textMuted).monospacedDigit())")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // Cut in the middle, so a long repository or German title keeps its count.
                .truncationMode(.middle)
        }
        // Tighter than the plain list's own header padding, which left the header floating
        // between the smart-view pills and its rows (the space above it is the list's and stays).
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        .accessibilityElement(children: .ignore)
        // The title as written rather than in capitals, which VoiceOver may spell out letter by
        // letter, and the count in words.
        .accessibilityLabel(Text(verbatim: "\(title), \(String(localized: "\(count) pull requests"))"))
        .accessibilityAddTraits(.isHeader)
    }
}
