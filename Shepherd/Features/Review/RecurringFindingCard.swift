import ShepherdCore
import SwiftUI

/// "You have said this three times." — the feedback loop's one card (ADR 0029).
///
/// It sits on the review screen's conversation tab, under the claims card and above the
/// description, and it appears only when the repository the reviewer is looking at has an
/// undismissed recurring finding.
///
/// Four things it draws are decisions rather than layout:
///
/// - **It quotes the reviewer, and says nothing about the pull request.** The card is about a
///   habit in the repository's agent output, not about the change on screen: no line of it refers
///   to this pull request, and the pull request numbers beside the quotes are the *other* ones the
///   reviewer wrote them on. A card that looked like a finding about the open pull request would
///   be read as one.
/// - **Three quotes, in the reviewer's own words, untranslated and unsummarised.** There is no
///   model behind this card and nothing here paraphrases anything — the whole claim it makes is
///   "you wrote these", so showing anything other than what they wrote would break it.
/// - **Two buttons and no third.** *Draft a rule* opens the delegation sheet; *Dismiss for this
///   repository* hides the card on this Mac. There is deliberately no "add a rule" that writes
///   anything: Shepherd never commits to a repository, so the only thing this card can produce is
///   a task in a field the reviewer then runs themselves (ADR 0011's guarantee, unchanged).
/// - **Dismissing is per repository and it is undoable.** The button says which scope it means,
///   and the finding stays visible under Settings → Replies with a *Show again* beside it — a
///   dismissal that could not be taken back would make this a button nobody dares press.
struct RecurringFindingCard: View {
    /// The finding to draw, or `nil` when this repository has none.
    let finding: RecurringFinding?
    /// Opens the delegation sheet with a drafted rule task.
    let onDraftRule: (RecurringFinding) -> Void
    /// Hides this finding on this repository.
    let onDismiss: (RecurringFinding) -> Void

    var body: some View {
        if let finding = finding, !finding.comments.isEmpty {
            Card(tint: Theme.priority.opacity(0.07)) {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(
                        String(localized: "A RECURRING FINDING"),
                        tint: Theme.prioritySecondary
                    )
                    Text(String(
                        localized: "You have said this \(finding.count) times on this repository."
                    ))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)

                    ForEach(RecurringFindingRule.quotes(of: finding)) { comment in
                        quote(comment)
                    }

                    Text(String(
                        localized: "Shepherd can draft a rule for this repository's agent instructions — CLAUDE.md or AGENTS.md — and open it as a pull request through your local agent. You review that pull request like any other."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button(String(localized: "Draft a rule")) {
                            onDraftRule(finding)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        Button(String(localized: "Dismiss for this repository")) {
                            onDismiss(finding)
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 32))
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// One quoted comment: the pull request it was written on, then what was written.
    @ViewBuilder
    private func quote(_ comment: RecurringFindingComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Not localised: a pull request number is a number with a `#` in front of it in every
            // language Shepherd speaks.
            Text(verbatim: "#\(comment.number)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .frame(minWidth: 42, alignment: .leading)
            // The reviewer's own text, so the non-localising `Text` overload: this is content,
            // never a key. Clipped rather than wrapped without end — three quotes have to stay
            // scannable, and the full comment is one click away on GitHub.
            Text(comment.body)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
