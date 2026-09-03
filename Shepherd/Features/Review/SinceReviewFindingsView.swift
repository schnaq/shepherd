import ShepherdCore
import SwiftUI

/// The findings strip under the round picker: what the reviewer said last round, and what
/// became of it (ADR 0028).
///
/// Every row is one published thread the reviewer started, with a state that is a statement
/// about *lines* — "addressed" means the anchored lines changed, never that the change is
/// right — and a jump into the file it is anchored to.
struct SinceReviewFindingsView: View {
    /// The review model.
    let model: ReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.findings) { finding in
                        row(finding)
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 108)
        }
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Your findings").uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(Theme.textSecondary)
            Text(String(localized: "· \(model.findings.count) from the round you reviewed"))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func row(_ finding: ReviewFinding) -> some View {
        Button {
            model.jump(to: finding)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: finding.state.systemImage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(finding.state.tint)
                    .frame(width: 14)
                Text(finding.state.localizedTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(finding.state.tint)
                    .frame(width: 74, alignment: .leading)
                Text(finding.excerpt)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(location(of: finding))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(finding.state.explanation)
    }

    /// The `file:line` label, with a note when the line is a number in the older head.
    private func location(of finding: ReviewFinding) -> String {
        guard let path = finding.path else {
            return String(localized: "conversation")
        }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let line = finding.line else { return name }
        return finding.isLineOutdated
            ? String(localized: "\(name), was line \(line)")
            : "\(name):\(line)"
    }
}

extension FindingState {
    /// The row label.
    var localizedTitle: String {
        switch self {
        case .addressed: return String(localized: "Addressed")
        case .unchanged: return String(localized: "Unchanged")
        case .moved: return String(localized: "Moved")
        case .replied: return String(localized: "Replied")
        }
    }

    /// The glyph in front of the label.
    var systemImage: String {
        switch self {
        case .addressed: return "checkmark.circle"
        case .unchanged: return "circle.dotted"
        case .moved: return "arrow.turn.down.right"
        case .replied: return "bubble.left.and.bubble.right"
        }
    }

    /// The row's tint.
    var tint: Color {
        switch self {
        case .addressed: return Theme.success
        case .unchanged: return Theme.pending
        case .moved: return Theme.accentText
        case .replied: return Theme.agent
        }
    }

    /// What the state does and does not claim, for the row's tooltip.
    var explanation: String {
        switch self {
        case .addressed:
            return String(localized: "The lines this comment is anchored to changed in the new round. It does not say the change is right — the thread stays open until you resolve it.")
        case .unchanged:
            return String(localized: "Neither the anchored lines nor the thread has changed since you reviewed.")
        case .moved:
            return String(localized: "The file was renamed, or the lines around this comment shifted.")
        case .replied:
            return String(localized: "Somebody answered in this thread after you wrote in it.")
        }
    }
}
