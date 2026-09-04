import ShepherdCore
import SwiftUI

extension TriageVerdict.Kind {
    /// The chip's first half — lower case, because it reads as a tag rather than as a sentence.
    var chipTitle: String {
        switch self {
        case .feature: return String(localized: "feature")
        case .fix: return String(localized: "fix")
        case .chore: return String(localized: "chore")
        case .dependencyBump: return String(localized: "dependency")
        case .docs: return String(localized: "docs")
        case .refactor: return String(localized: "refactor")
        }
    }
}

extension TriageVerdict.Risk {
    /// The chip's second half.
    var chipTitle: String {
        switch self {
        case .low: return String(localized: "risk low")
        case .medium: return String(localized: "risk medium")
        case .high: return String(localized: "risk high")
        }
    }

    /// The rail's label for this level.
    var facetTitle: String {
        switch self {
        case .low: return String(localized: "Low risk")
        case .medium: return String(localized: "Medium risk")
        case .high: return String(localized: "High risk")
        }
    }

    /// The colour, from the existing design tokens rather than from three new ones.
    ///
    /// The same three colours the CI dot and the check chips use, which is deliberate: a reviewer
    /// has already learnt that red is "look at this" and amber is "not settled" everywhere else
    /// in the app, and a fourth palette would make them learn it again. Low risk is *muted* on
    /// purpose — it is the answer that asks for no attention, so it may not compete with the
    /// title beside it.
    var chipColor: Color {
        switch self {
        case .low: return Theme.textMuted
        case .medium: return Theme.pending
        case .high: return Theme.failure
        }
    }
}

/// The triage chip on an inbox row, plus its "why?" popover (ADR 0023).
///
/// Two states, and the row renders whichever it has:
///
/// - **A verdict**: `fix · risk high`, and the popover carries the model's one sentence plus the
///   line that makes the privacy claim where the user is standing — the verdict was made on this
///   Mac and went nowhere.
/// - **No verdict, but tier-1 hints**: `risk high` on its own, muted, with the
///   ``ShepherdCore/FilePrioritizer`` sentences in the popover. That is the state on a Mac with
///   Apple Intelligence off, and it is the whole of the degraded mode: the risk column stays, it
///   simply stops claiming a *kind*, because nothing without a model can say what kind of change
///   something is.
///
/// The chip is never a button that does anything: clicking it opens the popover and nothing else
/// (ADR 0023's rule — it sorts, it does not approve).
struct TriageChip: View {
    /// What the coordinator knows about this row.
    let summary: TriageRowSummary

    @State private var isShowingReason = false

    var body: some View {
        // Only ever rendered for a row that has something to say; the list checks first, and
        // this guard is what keeps the chip honest if a future caller forgets.
        if let risk = summary.risk {
            Button {
                isShowingReason.toggle()
            } label: {
                ChipView(text: title(for: risk), color: risk.chipColor)
            }
            .buttonStyle(.plain)
            .help(helpText)
            // The chip's own text, which is already two localised words: a separate spoken
            // phrase would be a second string saying the same thing in a slightly different way.
            .accessibilityLabel(Text(title(for: risk)))
            .popover(isPresented: $isShowingReason, arrowEdge: .bottom) {
                TriageReasonPopover(summary: summary)
            }
        }
    }

    private func title(for risk: TriageVerdict.Risk) -> String {
        TriageChip.spokenTitle(for: summary) ?? risk.chipTitle
    }

    /// The chip's two words, for a row that announces itself as one element.
    ///
    /// `nil` when there is nothing to say — no verdict and no risk — so a row can leave the part
    /// out rather than announce an absence, which is what the chip does on screen too.
    /// - Parameter summary: What the coordinator knows about the row.
    static func spokenTitle(for summary: TriageRowSummary) -> String? {
        guard let risk = summary.risk else { return nil }
        guard let verdict = summary.verdict else { return risk.chipTitle }
        return "\(verdict.kind.chipTitle) · \(risk.chipTitle)"
    }

    private var helpText: String {
        summary.isClassified
            ? String(localized: "Why this pull request was classified this way")
            : String(localized: "Why Shepherd flagged this risk")
    }
}

/// The "why?" popover behind the chip.
struct TriageReasonPopover: View {
    /// What the coordinator knows about this row.
    let summary: TriageRowSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let verdict = summary.verdict {
                CardTitle(String(localized: "WHY THIS VERDICT"))
                Text(reasonText(for: verdict))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                // The provenance line, and it is the point of the popover as much as the reason
                // is: the one question a generated classification raises is "where did this go",
                // and the answer is nowhere.
                Text(String(localized: "Classified on this Mac. Nothing was sent anywhere."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                CardTitle(String(localized: "WHY THIS RISK"))
                Text(String(
                    localized: "Worked out from the changed files without a model, so there is no kind and no sentence — just what the paths and the diff say."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !summary.riskHints.isEmpty {
                Divider().overlay(Theme.hairline)
                CardTitle(String(localized: "RISK HINTS"))
                // The AI summary card's bullet shape (``InboxDetailPanel``), reused rather than
                // re-invented: one catalog key for the bullet, and the hint itself is runtime
                // text that never becomes one.
                ForEach(summary.riskHints, id: \.self) { hint in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(Theme.textMuted)
                        Text(hint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    /// The model's sentence, or an honest stand-in for the one case it can be empty.
    ///
    /// ``ShepherdCore/TriageVerdict``'s decoding tolerates a missing reason on purpose — a model
    /// that classified correctly and forgot to explain itself has still produced something the
    /// facet can sort by — so the popover has to be able to finish the sentence anyway.
    private func reasonText(for verdict: TriageVerdict) -> String {
        guard !verdict.reason.isEmpty else {
            return String(localized: "The model gave no reason for this one.")
        }
        return verdict.reason
    }
}
