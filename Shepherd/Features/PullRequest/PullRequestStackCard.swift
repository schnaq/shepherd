import ShepherdCore
import SwiftUI

/// The "Stack" section of the inbox's detail panel and the review screen's conversation tab
/// (ADR 0042).
///
/// Lists the part of the pull request's GitHub stack that the inbox holds, bottom to top, which is
/// the order the stack merges in: whatever is above a row builds on it. The shown pull request is
/// marked, and every other row opens its own pull request. Positions the inbox does not hold are
/// counted in one line underneath rather than invented — the sweep only knows the pull requests it
/// found, and a stack can hold somebody else's.
///
/// Built from ``ShepherdCore/PullRequestStackOverview`` and nothing else, so it fetches nothing:
/// the rows are the ones the inbox already has in memory.
struct PullRequestStackCard: View {
    /// The stack, as far as the inbox holds it.
    let overview: PullRequestStackOverview
    /// What a click on another member does. The caller decides: the inbox selects the row, the
    /// review screen opens it.
    let onOpen: (PullRequestSummary) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    CardTitle(String(localized: "STACK"))
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.triangle.branch")
                        .font(Theme.type(.footnote))
                        .foregroundStyle(Theme.textMuted)
                        .accessibilityHidden(true)
                    Text(verbatim: overview.stack.baseRefName)
                        .font(Theme.mono(.subheadline))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(String(localized: "The branch the stack merges into"))
                }
                ForEach(overview.members) { member in
                    row(member)
                }
                if let missing = overview.missingSentence {
                    Text(missing)
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One member. The shown pull request is drawn as plain text rather than as a disabled
    /// button: a disabled button dims its label, which would undo the marking.
    @ViewBuilder
    private func row(_ member: PullRequestSummary) -> some View {
        if member.id == overview.currentID {
            label(member, isCurrent: true)
                .help(String(localized: "The pull request you are looking at"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(member.slug): \(member.title)"))
                .accessibilityAddTraits(.isSelected)
        } else {
            Button {
                onOpen(member)
            } label: {
                label(member, isCurrent: false)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open \(member.slug)"))
            .accessibilityLabel(Text(verbatim: "\(member.slug): \(member.title)"))
        }
    }

    private func label(_ member: PullRequestSummary, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: member.stack.map { String($0.position) } ?? "")
                .font(Theme.mono(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .frame(minWidth: 12, alignment: .trailing)
            Text(verbatim: "#\(member.number)")
                .font(Theme.mono(.callout, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Theme.textStrong : Theme.accentText)
            Text(member.title)
                .font(Theme.type(.callout, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Theme.textStrong : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if isCurrent {
                Text(String(localized: "this one"))
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isCurrent ? Theme.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}

extension PullRequestStack {
    /// The row chip's words: "Stack 2/3".
    ///
    /// The size is bound to `total` first so the derived catalog key is `%lld` —
    /// `Scripts/check-localization.py` types interpolations by the expression's text.
    var chipText: String {
        let total = size
        return String(localized: "Stack \(position)/\(total)")
    }

    /// The row chip's tooltip: "Part of a GitHub stack: 2 of 3, on main".
    var chipHelp: String {
        let total = size
        return String(localized: "Part of a GitHub stack: \(position) of \(total), on \(baseRefName)")
    }
}

extension PullRequestStackOverview {
    /// "2 more are not in your inbox", or `nil` when the inbox holds the whole stack.
    var missingSentence: String? {
        switch missingCount {
        case 0: return nil
        case 1: return String(localized: "One more is not in your inbox.")
        default:
            let count = missingCount
            return String(localized: "\(count) more are not in your inbox.")
        }
    }

    /// What merges along with the shown pull request, for the merge sheet — or `nil` at the
    /// bottom of a stack, where nothing does.
    ///
    /// The numbers are named only when the inbox holds *every* pull request below: naming the two
    /// it knows of three would understate what the merge takes along, so then it is the count.
    /// Singular and plural are separate sentences rather than a plural variation because the
    /// singular one has no number to agree with, and position 2 — one pull request below — is the
    /// commonest stacked merge there is.
    var alsoMergesSentence: String? {
        let count = belowCount
        guard count > 0 else { return nil }
        if knowsEveryPullRequestBelow {
            // Built as plain strings, `#` and the digits, the way a slug is: a number formatted by
            // the locale would read `#1.024` on a German Mac.
            let names = below.map { "#" + String($0.number) }.formatted(.list(type: .and))
            return count == 1
                ? String(localized: "Also merges \(names), the pull request below it in the stack.")
                : String(localized: "Also merges \(names), the pull requests below it in the stack.")
        }
        return count == 1
            ? String(localized: "Also merges the pull request below it in the stack.")
            : String(localized: "Also merges the \(count) pull requests below it in the stack.")
    }
}
