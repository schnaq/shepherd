import ShepherdCore
import SwiftUI

/// The answer to **Why?** on a red check, under the checks list (plan §3.F).
///
/// Six things about what it draws are decisions rather than layout:
///
/// - **The failing test, the file and the line come before the hypothesis.** A reviewer opening
///   this wants the location first; the sentence explaining it is what they read second, and the
///   confidence is what they read last. Every one of those fields is optional on
///   ``ShepherdCore/CIDiagnosis`` and the card simply omits what the log did not name — a
///   diagnosis that had to invent a file to be renderable would be worse than one that admits it
///   does not know.
/// - **The file:line is a link only when the file is in the diff.** Clicking it selects that file
///   in the viewer and reveals the line. When CI failed in a file this pull request never
///   touched — which happens, and is exactly when a diagnosis is most useful — the same text is
///   shown without a link rather than as a button that would open nothing.
/// - **The tier caption is a statement about privacy, not a badge.** *Diagnosed on-device* is the
///   answer to "did my log leave this Mac?", and it is the same wording the explain popover and
///   the draft captions use, for the same reason (ADR 0007, ADR 0024).
/// - **The trace is not decoration.** ``CIDiagnosisTraceView`` is what turns a hypothesis into a
///   claim a reviewer can check; it is part of the card rather than a detail sheet somewhere else.
/// - **There is exactly one way to the cloud, and it is a question.** *Ask <provider> with the
///   full log?* appears only after the on-device tier said the content did not fit — or said it
///   is not available on this Mac at all, which asks the same question with the other sentence
///   in front of it — **and** only when a key is configured; otherwise the card says what
///   happened and offers nothing. Pressing it is the only thing in Shepherd that lets a CI log
///   reach a configured endpoint (ADR 0024, `CONTRIBUTING.md`'s host list).
/// - **Nothing in it acts.** *Draft an agent brief* opens the delegation sheet with the finding
///   filled in — and Run is still the reviewer's click (ADR 0011's amendment). There is no
///   *comment this*, no *re-run CI*, and no path from this card to the outbox.
struct CIDiagnosisCard: View {
    /// What to draw.
    let state: CIDiagnosisState
    /// The check the reviewer asked about, when it is known.
    let checkName: String?
    /// Whether the file the diagnosis names is one this pull request changed.
    ///
    /// Answered by the caller, which is the only place that knows the diff.
    let isFileInDiff: (String) -> Bool
    /// The configured cloud tier's name, for the one question that offers it.
    let cloudBadge: String?
    /// Opens the named file — and line, when there is one — in the diff viewer.
    let onOpenFile: (String, Int?) -> Void
    /// Asks the cloud tier with the full log. Only ever called from the button that says so.
    let onAskCloud: () -> Void
    /// Opens the delegation sheet with the diagnosis as the finding.
    let onDraftBrief: () -> Void
    /// Closes the card.
    let onClose: () -> Void

    var body: some View {
        Card(tint: Theme.accent.opacity(0.06)) {
            VStack(alignment: .leading, spacing: 8) {
                header
                switch state {
                case .asking:
                    asking
                case .diagnosed(let kind, let run):
                    diagnosed(kind: kind, run: run)
                case .cloudRung(let reason, let message, let canAskCloud):
                    cloudRung(reason: reason, message: message, canAskCloud: canAskCloud)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "stethoscope")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accentText)
            CardTitle(String(localized: "WHY IS CI RED?"), tint: Theme.accentText)
            if let checkName {
                Text(checkName)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if case .diagnosed(_, let run) = state {
                ChipView(
                    text: CIDiagnosisCard.confidenceLabel(run.value.confidence),
                    color: CIDiagnosisCard.confidenceColour(run.value.confidence),
                    size: 10
                )
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Close the diagnosis"))
        }
    }

    // MARK: - The three bodies

    /// The spinner while a tier reads.
    ///
    /// One line and no fake steps: the trace exists when the turn ends, and inventing *"reading
    /// the log…"* before knowing whether the model asked for the log would be a lie that usually
    /// happens to be true.
    private var asking: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "Asking the model…"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder
    private func diagnosed(
        kind: IntelligenceKind,
        run: IntelligenceToolRun<CIDiagnosis>
    ) -> some View {
        let diagnosis = run.value
        if let test = diagnosis.failingTest {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.octagon")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.failure)
                    .frame(width: 12)
                Text(test)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.textStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let file = diagnosis.file {
            location(file: file, line: diagnosis.line)
        }
        Text(diagnosis.hypothesis)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(CIDiagnosisCard.tierLine(kind))
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textMuted)
        if !run.trace.isEmpty {
            Divider().overlay(Theme.hairline)
            CIDiagnosisTraceView(trace: run.trace)
        }
        HStack(spacing: 8) {
            Button(String(localized: "Draft an agent brief"), action: onDraftBrief)
                .buttonStyle(SecondaryButtonStyle(height: 26, tint: Theme.agent))
                .help(String(
                    localized: "Opens the delegation sheet with this finding — you still press Run"
                ))
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    /// `path:line`, as a link into the diff when the diff has that file.
    @ViewBuilder
    private func location(file: String, line: Int?) -> some View {
        let text = CIDiagnosisCard.locationText(file: file, line: line)
        if isFileInDiff(file) {
            Button {
                onOpenFile(file, line)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                    Text(text)
                        .font(Theme.mono(11))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .foregroundStyle(Theme.accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open this line in the diff"))
        } else {
            HStack(spacing: 4) {
                Text(text)
                    .font(Theme.mono(11))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(String(localized: "· not in this diff"))
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(Theme.textMuted)
        }
    }

    /// The two refusals with a way out of them — and the honest sentence when there is none.
    ///
    /// `message` is always the tier's *own* words: the log that did not fit, or the reason macOS
    /// gives for the on-device model being unavailable (*"…is turned off in System Settings"* is
    /// a different thing to do about it than *"this Mac does not support…"*). The question under
    /// it is Shepherd's, and pressing it is the only thing in the app that can send a CI log to a
    /// configured endpoint.
    @ViewBuilder
    private func cloudRung(
        reason: CIDiagnosisState.CloudRungReason,
        message: String,
        canAskCloud: Bool
    ) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        if canAskCloud, let cloudBadge {
            Button(
                CIDiagnosisCard.cloudRungQuestion(reason, provider: cloudBadge),
                action: onAskCloud
            )
            .buttonStyle(SecondaryButtonStyle(height: 26, tint: Theme.accentText))
            .help(String(
                localized: "Sends the reduced log, the failing checks and the diff Shepherd reads to the endpoint you configured"
            ))
        } else if reason == .tooLargeForDevice {
            // Only reachable for this reason: with no on-device model *and* no key the **Why?**
            // button is never drawn (``IntelligenceRouter/canDiagnose``), so the other reason
            // only ever arrives here with a tier to offer — and its sentence above is the whole
            // answer on its own anyway.
            Text(String(
                localized: "The log did not fit the on-device model, and no cloud provider is configured."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Copy

    /// The question on the card's one button, for the refusal it is an answer to.
    ///
    /// Both halves are load-bearing. The *provider* is named rather than "the cloud", because
    /// what a reviewer agrees to is one endpoint they configured themselves. The *reason* picks
    /// the sentence: "with the full log?" answers a log that did not fit, and it would be a
    /// strange thing to read on a Mac whose on-device model was never asked at all — there the
    /// question a reviewer has is why the button is there, so the button says.
    /// - Parameters:
    ///   - reason: Why the on-device tier could not answer.
    ///   - provider: The configured tier's badge — "Anthropic", "custom endpoint".
    /// - Returns: The label for the button that spends the one click.
    static func cloudRungQuestion(
        _ reason: CIDiagnosisState.CloudRungReason,
        provider: String
    ) -> String {
        switch reason {
        case .tooLargeForDevice:
            return String(localized: "Ask \(provider) with the full log?")
        case .onDeviceUnavailable:
            return String(
                localized: "Apple Intelligence is not available on this Mac. Ask \(provider) instead?"
            )
        }
    }

    /// `path:line`, or just the path when the log named no line.
    /// - Parameters:
    ///   - file: The file the diagnosis names.
    ///   - line: The line, when there is one.
    /// - Returns: The text on the link.
    static func locationText(file: String, line: Int?) -> String {
        guard let line else { return file }
        return "\(file):\(line)"
    }

    /// "Diagnosed on-device" or "Diagnosed by <provider>".
    ///
    /// Two sentences rather than one interpolation of ``IntelligenceKind/badge``, for the reason
    /// ``AIDraftStatusView/draftingLine(_:)`` gives: the badges are not all nouns that can follow
    /// "by", and a translator handed one key could not fix that either.
    /// - Parameter kind: The tier that answered.
    /// - Returns: The already-localized caption.
    static func tierLine(_ kind: IntelligenceKind) -> String {
        switch kind {
        case .onDevice:
            return String(localized: "Diagnosed on-device")
        case .anthropic, .openAICompatible:
            return String(localized: "Diagnosed by \(kind.badge)")
        }
    }

    /// The chip's word for how sure the model says it is.
    /// - Parameter confidence: What the model answered.
    /// - Returns: The already-localized word.
    static func confidenceLabel(_ confidence: CIDiagnosis.Confidence) -> String {
        switch confidence {
        case .high: return String(localized: "high confidence")
        case .medium: return String(localized: "medium confidence")
        case .low: return String(localized: "low confidence")
        }
    }

    /// The chip's colour for a confidence.
    ///
    /// Never green and never red: a confident diagnosis is not good news and an unsure one is not
    /// a failure. Red in this app means a check that failed, and it is already on the row above.
    /// - Parameter confidence: What the model answered.
    static func confidenceColour(_ confidence: CIDiagnosis.Confidence) -> Color {
        switch confidence {
        case .high: return Theme.accentText
        case .medium: return Theme.pending
        case .low: return Theme.textMuted
        }
    }
}
