import ShepherdCore
import SwiftUI

/// The hops a diagnosis took, as rows that expand to show exactly what the model saw (plan §3.F).
///
/// This view is the whole reason a generated diagnosis is allowed on the review screen at all.
/// A hypothesis with a confidence label on it is a guess; a hypothesis with *"last 42 of 1,320
/// lines of App build (macOS)"* under it, expandable to those 42 lines, is a claim a reviewer can
/// check in five seconds. So three things about it are deliberate:
///
/// - **Every step is expandable, including the boring ones.** A refused call and a check list are
///   as much part of "what was it allowed to see" as the log is, and a card that only showed the
///   interesting reads would be curating the evidence.
/// - **The content is shown verbatim and monospaced.** It is a log tail and a diff window — the
///   reviewer is looking for a line, not reading prose — and it is selectable, because the next
///   thing anybody does with a failing line is paste it somewhere.
/// - **Nothing in here links anywhere or acts.** The file link lives on the diagnosis itself,
///   once; a trace row is the record of a read that already happened.
struct CIDiagnosisTraceView: View {
    /// The trace to render, in the order the hops happened.
    let trace: IntelligenceTrace

    /// Which steps are expanded, by ``ShepherdCore/IntelligenceTraceStep/order``.
    ///
    /// A set rather than one open row: comparing the log the model read with the diff it read
    /// afterwards is exactly what a reviewer opens this for.
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(String(localized: "WHAT IT READ · \(trace.count)"))
            ForEach(trace.orderedSteps, id: \.order) { step in
                row(for: step)
            }
        }
    }

    @ViewBuilder
    private func row(for step: IntelligenceTraceStep) -> some View {
        let isExpanded = expanded.contains(step.order)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if isExpanded {
                    expanded.remove(step.order)
                } else {
                    expanded.insert(step.order)
                }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CIDiagnosisTraceView.label(for: step.toolName))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                        if !step.argumentsDisplay.isEmpty {
                            Text(step.argumentsDisplay)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(step.summaryLine)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content(of: step)
            }
        }
    }

    /// What the model was handed for one step.
    ///
    /// Empty is a real answer — a step recorded without content, which is what a scripted tier
    /// produces — and it says so rather than opening onto nothing.
    @ViewBuilder
    private func content(of step: IntelligenceTraceStep) -> some View {
        if step.resultContent.isEmpty {
            Text(String(localized: "This step recorded no content."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, 16)
        } else {
            ScrollView([.horizontal, .vertical]) {
                Text(step.resultContent)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(6)
            .background(
                Theme.background,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .padding(.leading, 16)
        }
    }

    /// What one tool did, in the reviewer's words.
    ///
    /// One phrase per tool rather than the tool's raw name: `jobLogTail` is the contract's word
    /// for it and means nothing to somebody reading a card. The arguments are shown beside the
    /// phrase, verbatim from the trace, so the row says both what was read and which one.
    /// - Parameter tool: The tool that ran.
    /// - Returns: The already-localized phrase.
    static func label(for tool: IntelligenceToolName) -> String {
        switch tool {
        case .failingChecks:
            return String(localized: "Read the failing checks")
        case .jobLogTail:
            return String(localized: "Read the last lines of a job log")
        case .fileDiff:
            return String(localized: "Read the diff of one file")
        }
    }
}
