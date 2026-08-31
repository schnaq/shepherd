import GitHubKit
import ShepherdCore
import SwiftUI

/// The merge confirmation sheet (`m`).
///
/// Merging is the one action Shepherd cannot undo, so it is the one action that keeps a
/// confirmation step instead of the undo toast used everywhere else.
struct MergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The pull request to merge.
    let summary: PullRequestSummary
    /// The outbox-backed write actions.
    let actions: PullRequestActions

    @State private var method: MergeMethod = .squash
    @State private var deletesBranch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Merge \(summary.slug)"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                Text(summary.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(summary.headRefName) → \(summary.baseRefName)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
            }

            Picker(String(localized: "Method"), selection: $method) {
                Text(String(localized: "Merge commit")).tag(MergeMethod.merge)
                Text(String(localized: "Squash and merge")).tag(MergeMethod.squash)
                Text(String(localized: "Rebase and merge")).tag(MergeMethod.rebase)
            }
            .pickerStyle(.radioGroup)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(String(localized: "Delete the branch afterwards"), isOn: $deletesBranch)
                    .disabled(true)
                Text(String(
                    localized: "Branch deletion is not wired up yet — ShepherdKit's outbox does not model it, so Shepherd will not pretend to do it."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let warning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.pending)
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await actions.merge(summary, method: method)
                        dismiss()
                    }
                } label: {
                    Text(String(localized: "Merge"))
                }
                .buttonStyle(SuccessButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(summary.mergeable == .conflicting)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.panel)
    }

    private var warning: String? {
        switch summary.mergeable {
        case .conflicting:
            return String(localized: "GitHub reports conflicts with \(summary.baseRefName). Resolve them first.")
        case .unknown, nil:
            return String(localized: "GitHub has not finished computing mergeability. The merge may be refused.")
        case .mergeable:
            if summary.checkRollup?.state == .failure {
                return String(localized: "Checks are failing on the head commit.")
            }
            if summary.checkRollup?.state == .pending {
                return String(localized: "Checks are still running.")
            }
            return nil
        }
    }
}
