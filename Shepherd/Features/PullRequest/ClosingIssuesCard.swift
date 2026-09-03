import AppKit
import ShepherdCore
import SwiftUI

/// The "Closes" section above a pull request's description (ADR 0032's Sprint 3 amendment).
///
/// One row per issue GitHub resolved out of the description's `closes #123` keywords, with the
/// number, the title and a state glyph, and a click — or ⇧⌘I on the first one — opens it. The
/// whole card draws **nothing** when the list is empty, which is both "this pull request closes
/// nothing" and "that one field of the detail fetch was tolerated" (see
/// ``ShepherdCore/PullRequestDetail/closingIssues``): a reader cannot act on the difference, so
/// the screen does not invent one.
///
/// The rows are read out of the local `PullRequestDetail` and nothing here fetches: the issues
/// arrive on the same detail read as the review threads.
struct ClosingIssuesCard: View {
    /// The issues the pull request will close, in GitHub's own order.
    let issues: [LinkedIssueReference]
    /// The pull request's own repository, so a cross-repository reference can say so.
    ///
    /// `closes owner/repo#1` is a reference GitHub resolves, so an issue in the list may live
    /// somewhere else entirely — and a row that showed a bare `#1` for it would name the wrong
    /// issue to a reader.
    let repo: RepoRef?
    /// What to do when a row is activated.
    ///
    /// A closure rather than a call into the app container, so this view has no opinion about
    /// *where* an issue opens: today ``ConversationView`` hands it
    /// ``openOnGitHub(_:)``, and `AppEnvironment.openIssue` — the hook the issues inbox adds — is
    /// a change to that one call site and to nothing here.
    let onOpen: (LinkedIssueReference) -> Void

    var body: some View {
        if !ClosingIssuesCard.isHidden(for: issues) {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(ClosingIssuesCard.title(for: issues.count))
                    // Enumerated rather than plain, because the *first* row is the one that
                    // carries the keystroke; `id:` keeps SwiftUI's identity on the issue.
                    ForEach(Array(issues.enumerated()), id: \.element.id) { entry in
                        row(entry.element, isFirst: entry.offset == 0)
                    }
                }
            }
        }
    }

    /// One issue.
    ///
    /// The first row carries the keystroke, because a pull request closes one issue in almost
    /// every case and "one keystroke opens the issue" is the roadmap item's own wording. It is a
    /// `KeyboardShortcut?` rather than a branch in the view tree so that both rows are the same
    /// view with the same layout.
    @ViewBuilder
    private func row(_ issue: LinkedIssueReference, isFirst: Bool) -> some View {
        Button {
            onOpen(issue)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: ClosingIssuesCard.symbol(for: issue.state))
                    .font(.system(size: 11))
                    .foregroundStyle(ClosingIssuesCard.color(for: issue.state))
                    .frame(width: 14)
                Text(ClosingIssuesCard.label(for: issue))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.accentText)
                Text(issue.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let repo, issue.repo != repo {
                    ChipView(text: issue.repo.fullName, color: Theme.textSecondary, size: 10)
                }
                Spacer(minLength: 4)
                Text(ClosingIssuesCard.stateTitle(for: issue.state))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(
            isFirst ? KeyboardShortcut("i", modifiers: [.command, .shift]) : nil
        )
        .help(String(localized: "Open the issue on GitHub"))
        .accessibilityLabel(Text(ClosingIssuesCard.accessibilityLabel(for: issue)))
    }

    // MARK: - The rules and the text, as pure functions

    /// Whether the card draws nothing at all.
    ///
    /// A named rule rather than a bare `isEmpty` in the body, for
    /// ``ClaimsEvidenceCardState/isHidden``'s reason: it is the one thing about this section a
    /// test can assert without a window, and "hidden when there are none" is the requirement.
    /// - Parameter issues: The issues the pull request closes.
    /// - Returns: `true` when there is no section.
    static func isHidden(for issues: [LinkedIssueReference]) -> Bool {
        issues.isEmpty
    }

    /// The card's heading, which carries the count.
    ///
    /// A plural variation rather than a `·` and a number (`COMMITS · 4`'s shape), because German
    /// needs agreement here and the count is the sentence's only argument (ADR 0022). The review
    /// vocabulary GitHub keeps in English stays English inside it.
    /// - Parameter count: How many issues the pull request closes. Never zero — the card is not
    ///   drawn then.
    /// - Returns: The heading.
    static func title(for count: Int) -> String {
        String(localized: "CLOSES \(count) ISSUES")
    }

    /// The `Closes #142` label of one row.
    ///
    /// The number is bound to a local first so that the derived catalog key is `%lld` — see
    /// `Scripts/check-localization.py`'s hand-checked type table, which is keyed by the
    /// interpolated expression's text.
    /// - Parameter issue: The issue.
    /// - Returns: The label.
    static func label(for issue: LinkedIssueReference) -> String {
        let number = issue.number
        return String(localized: "Closes #\(number)")
    }

    /// The whole row as one sentence, for the screen reader.
    /// - Parameter issue: The issue.
    /// - Returns: The sentence.
    static func accessibilityLabel(for issue: LinkedIssueReference) -> String {
        "\(label(for: issue)): \(issue.title) · \(stateTitle(for: issue.state))"
    }

    /// The glyph in front of a row.
    ///
    /// GitHub's own two shapes — a ring for an open issue, a tick for a closed one — and a
    /// question mark for a state this build does not know, which is a state and not an error.
    /// - Parameter state: The issue's state.
    /// - Returns: The SF Symbol name.
    static func symbol(for state: IssueSummary.State) -> String {
        switch state {
        case .open: return "smallcircle.filled.circle"
        case .closed: return "checkmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// The glyph's colour.
    ///
    /// The design tokens the rest of the app already uses for the same three meanings: green for
    /// "done", the accent for "still open" — an open issue is not a warning — and the muted
    /// secondary for "no opinion".
    /// - Parameter state: The issue's state.
    /// - Returns: The colour.
    static func color(for state: IssueSummary.State) -> Color {
        switch state {
        case .open: return Theme.accentText
        case .closed: return Theme.success
        case .unknown: return Theme.textSecondary
        }
    }

    /// The state as a word.
    /// - Parameter state: The issue's state.
    /// - Returns: The word, localised.
    static func stateTitle(for state: IssueSummary.State) -> String {
        switch state {
        case .open: return String(localized: "Open")
        case .closed: return String(localized: "Closed")
        case .unknown: return String(localized: "State unknown")
        }
    }

    // MARK: - Opening

    /// Opens one issue on github.com.
    ///
    /// The default action, and today the only one: there is no `DeepLink.issue` case in this
    /// build — the `shepherd://issue/…` grammar lands with the issues inbox itself — and an issue
    /// Shepherd has no screen for is best opened where a reviewer can act on it. This is also the
    /// single call site that changes when `AppEnvironment.openIssue` exists.
    /// - Parameter issue: The issue to open.
    static func openOnGitHub(_ issue: LinkedIssueReference) {
        NSWorkspace.shared.open(githubURL(for: issue))
    }

    /// The issue's page on github.com.
    ///
    /// Built here rather than in `AppConfig` beside the pull request's URL, deliberately: the
    /// issues inbox is landing in parallel and wants an issue URL of its own, so one builder in
    /// each place is a duplicate for one release, while two declarations of the same helper in
    /// one type is a build failure for whichever of the two lands second.
    /// - Parameter issue: The issue.
    /// - Returns: `https://github.com/owner/name/issues/142`.
    static func githubURL(for issue: LinkedIssueReference) -> URL {
        AppConfig.webBaseURL
            .appendingPathComponent(issue.repo.owner)
            .appendingPathComponent(issue.repo.name)
            .appendingPathComponent("issues")
            .appendingPathComponent(String(issue.number))
    }
}
