import Foundation
import ShepherdCore
import SwiftUI

/// One row of the issue detail panel's "Linked pull requests" section (ADR 0032).
///
/// Built from ``ShepherdCore/LinkedPullRequestReference`` — what the sweep saw in one nested
/// selection, stored by value — and from nothing else. The reference may name a pull request
/// that is **not** in the local inbox at all (somebody else's, or never fetched), which is what
/// the two ways of opening it are about:
///
/// - **In the local inbox** → ``AppEnvironment/openReview(prID:composing:)``, the same call the
///   inbox row, the menu-bar row and a ⌘K result make. A fifth way to open a review would be a
///   fifth place for the focus session's "did the user leave the queue" rule to be forgotten.
/// - **Not in the local inbox** → its page on github.com, handed to the browser. Shepherd does
///   not fetch it: the reference carries everything the row shows, and a detail fetch for a pull
///   request the user has not asked to review would be a request nobody pressed a button for.
///
/// ## Extension point — Sprint 3's CI and review-status badge
///
/// The trailing ``badge`` slot is deliberately empty here and is where the CI dot and the review
/// decision go. **Do not implement it in this file.** The plan (`docs/plans/issues-inbox.md`
/// §4.2) resolves both by *local join* — looking the `(repo, number)` up against the already
/// cached `pull_requests` table and showing its `checkRollup`/`reviewDecision` when the row is
/// there, omitting them silently otherwise — so the badge needs a database read this row must not
/// grow: a row that fetched its own state would make the panel depend on a store it otherwise
/// knows nothing about, which is the argument ``InboxRowView`` makes for taking its triage chip
/// as a parameter. Sprint 3 adds its own view in its own file and passes it in here.
struct IssueLinkedPullRequestRow<Badge: View>: View {
    /// The linked pull request, as the sweep saw it.
    let reference: LinkedPullRequestReference
    /// The pull request's node id when it is in the local inbox, `nil` when it is not.
    ///
    /// Resolved by the caller, which is the one place that has the inbox rows in memory.
    let localPullRequestID: String?
    /// Whether this row carries the section's single keystroke.
    var hasKeyboardShortcut = false
    /// Opens the row: the review screen when `localPullRequestID` is set, github.com otherwise.
    var onOpen: (LinkedPullRequestReference, String?) -> Void
    /// Sprint 3's status badge. Empty in this cut — see the note above.
    @ViewBuilder var badge: Badge

    var body: some View {
        if hasKeyboardShortcut {
            // The section's "one keystroke", and `l` because it is not in ``KeySequenceState``'s
            // vocabulary: the list returns `.ignored` for it, so the key travels on to this
            // button instead of being swallowed as a half-typed command.
            button.keyboardShortcut("l", modifiers: [])
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            onOpen(reference, localPullRequestID)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: stateSymbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(stateColor)
                    .frame(width: 12)
                Text("\(reference.repo.name) #\(reference.number)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .layoutPriority(1)
                Text(reference.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                badge
                ProvenanceChip(actor: reference.author, size: 10)
                    .layoutPriority(1)
                if hasKeyboardShortcut {
                    KeyCapView(keys: "l")
                }
            }
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(Text("\(reference.slug): \(reference.title)"))
    }

    /// The state glyph.
    ///
    /// Driven by ``ShepherdCore/LinkedPullRequestReference/state``, which is GitHub's raw word
    /// and is kept raw on purpose: an unfamiliar state falls through to the neutral glyph rather
    /// than costing a build, and the tolerant match is lowercased because the GraphQL enum is
    /// upper case while REST's is not.
    private var stateSymbol: String {
        switch reference.state.lowercased() {
        case "merged": return "arrow.triangle.merge"
        case "closed": return "xmark"
        case "open": return "arrow.triangle.pull"
        default: return "circle"
        }
    }

    private var stateColor: Color {
        switch reference.state.lowercased() {
        case "merged": return Theme.priority
        case "closed": return Theme.failure
        case "open": return Theme.success
        default: return Theme.textMuted
        }
    }

    /// What the tooltip says, and the two sentences differ because the click does.
    private var helpText: String {
        guard localPullRequestID != nil else {
            return String(
                localized: "Not in your inbox — opens \(reference.slug) on GitHub."
            )
        }
        return String(localized: "Open the review for \(reference.slug).")
    }
}

extension IssueLinkedPullRequestRow where Badge == EmptyView {
    /// Creates a row with no status badge — for previews and tests; the panel passes
    /// ``LinkedPullRequestStatusBadge`` into the slot.
    /// - Parameters:
    ///   - reference: The linked pull request.
    ///   - localPullRequestID: Its node id when it is in the local inbox.
    ///   - hasKeyboardShortcut: Whether this row carries the section's single keystroke.
    ///   - onOpen: Opens the row.
    init(
        reference: LinkedPullRequestReference,
        localPullRequestID: String?,
        hasKeyboardShortcut: Bool = false,
        onOpen: @escaping (LinkedPullRequestReference, String?) -> Void
    ) {
        self.init(
            reference: reference,
            localPullRequestID: localPullRequestID,
            hasKeyboardShortcut: hasKeyboardShortcut,
            onOpen: onOpen,
            badge: { EmptyView() }
        )
    }
}
