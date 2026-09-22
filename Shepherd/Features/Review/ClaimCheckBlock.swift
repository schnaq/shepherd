import ShepherdCore
import SwiftUI

/// What *Look closer* found under one line of the claims card (ADR 0026's 2026-09-22 amendment).
///
/// Three things about it are deliberate, and each follows from the line above it keeping its
/// ✓ / ✗ / ?:
///
/// - **It is tagged, every time.** *Read by the model on this Mac* sits over the block, so the
///   reviewer never mistakes a model's pointer for one of Shepherd's own facts.
/// - **The excerpt leads, the sentence follows.** Every excerpt was found in the patch by
///   ``ShepherdCore/DiffExcerpt`` before it got here, and it links into the diff; the model's
///   sentence is the caption under the code, not the other way round.
/// - **The reads are shown.** ``CIDiagnosisTraceView`` lists every tool call, so "it pointed at
///   nothing" can be told apart from "it read nothing".
struct ClaimCheckBlock: View {
    let state: ClaimCheckState
    let onOpenFile: (String, Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .checking:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Reading the diff on this Mac…"))
                }
                .font(Theme.type(.caption))
                .foregroundStyle(Theme.textMuted)
            case .done(let check):
                tag
                if check.notes.isEmpty {
                    Text(ClaimCheckBlock.nothingFoundText(count: check.trace.count))
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(check.notes) { note in
                        noteRow(note)
                    }
                }
                if !check.trace.isEmpty {
                    CIDiagnosisTraceView(trace: check.trace)
                }
            case .failed(let reason):
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.circle")
                    Text(reason)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.type(.caption))
                .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.textMuted.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    private var tag: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
            Text(String(localized: "Read by the model on this Mac"))
        }
        .font(Theme.type(.caption, weight: .medium))
        .foregroundStyle(Theme.textMuted)
        .help(String(
            localized: "Places the on-device model pointed at. Shepherd found each excerpt in the diff itself; the claim's mark above is still Shepherd's own."
        ))
    }

    private func noteRow(_ note: ClaimCheck.Note) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.excerpt)
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.textStrong)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(note.sentence)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onOpenFile(note.path, note.line)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(ClaimsEvidenceCard.locationText(path: note.path, line: note.line))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open this line in the diff"))
        }
    }

    static func nothingFoundText(count: Int) -> String {
        count == 1
            ? String(localized: "The model read 1 time and pointed at nothing Shepherd could find in the diff.")
            : String(localized: "The model read \(count) times and pointed at nothing Shepherd could find in the diff.")
    }
}
