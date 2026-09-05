import SwiftUI

/// What a focus session did, as the one thing on screen when it ends.
///
/// Finishing a queue of twenty agent pull requests and failing to copy a branch name used to look
/// identical: both were a toast, both faded, and the one that reported an achievement faded a
/// little more slowly. This is the replacement, and it is deliberately not a celebration — no
/// sound, no confetti — because the reward for clearing a review queue is a quiet screen. It is a
/// small sheet on the inbox the session returns to
/// (``AppEnvironment/endReviewSession(announcing:)``), with the counts as rows, the elapsed time
/// under them, and one button.
///
/// Both keys close it. Return, because *Done* is the sheet's default action, which is the rule
/// every sheet in the app follows (ADR 0033); Escape, through `onExitCommand`, because a sheet
/// with only a default action does not otherwise answer it — and a summary nobody can dismiss
/// with the key they dismiss everything else with is a modal dead end over a list.
///
/// The counts are not broken down by verdict, and that is a gap rather than a decision: the
/// session records *that* the pull request under the cursor was acted on, never which verdict was
/// queued (``ReviewSession/completeCurrent(present:)``), and the seam that would carry one —
/// ``PullRequestActions/onDidQueueVerdict`` — passes a node id and nothing else. Adding
/// "3 approved · 1 changes requested" means widening that callback, which is a change to the
/// write helper rather than to this view.
struct ReviewSessionSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the finished session did.
    let summary: ReviewSession.Summary

    /// Whether the entrance has run. `false` for exactly one frame.
    @State private var hasEntered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 6) {
                // Only the counts that happened. A session with nothing skipped should not have
                // to read a zero to find that out, which is the same rule ``ReviewSession/Summary``
                // applies to its own sentence.
                countRow(String(localized: "Reviewed"), value: summary.reviewed)
                if summary.skipped > 0 {
                    countRow(String(localized: "Skipped"), value: summary.skipped)
                }
                if summary.vanished > 0 {
                    countRow(String(localized: "Merged or closed meanwhile"), value: summary.vanished)
                }
                if summary.remaining > 0 {
                    countRow(String(localized: "Left in the queue"), value: summary.remaining)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(Theme.background)
        .onExitCommand { dismiss() }
        .opacity(hasEntered ? 1 : 0)
        .scaleEffect(hasEntered ? 1 : 0.96)
        .onAppear {
            // Off when the system asks for less motion (ADR 0033): the flag is set outside
            // `withAnimation`, so the view arrives at its final opacity and scale in one frame
            // rather than animating a shorter distance. ``InboxZeroView`` does the same thing for
            // the same reason — these are the app's only two entrance animations.
            guard !reduceMotion else {
                hasEntered = true
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { hasEntered = true }
        }
        // One element with the numbers in it, and *Done* still reachable inside — the same
        // arrangement ``DigestCardView`` uses. The sentence is ``ReviewSession/Summary/message``,
        // which is what the toast used to say, so the spoken form cannot drift from the rows
        // above: both are assembled from the same six fields.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(summary.message))
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.title)
                .font(Theme.type(.title3, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text(RelativeDate.duration(summary.duration))
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
    }

    /// One "Reviewed … 9" row, with the number right-aligned so the column reads as a column.
    private func countRow(_ label: String, value: Int) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Text("\(value)")
                .font(Theme.mono(.callout))
                .monospacedDigit()
                .foregroundStyle(Theme.textStrong)
        }
    }
}
