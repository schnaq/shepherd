import ShepherdCore
import SwiftUI

/// What the pull request says, beside what Shepherd found — above the description (ADR 0026).
///
/// Five things it draws are decisions rather than layout:
///
/// - **One line per claim, and no total.** There is no score, no ratio and no summary sentence,
///   because any of those would be the verdict this card refuses to give. The reviewer reads four
///   short lines and decides; ADR 0007's "hints, never verdicts", applied to a card with no model
///   behind it at all.
/// - **The claim is quoted, the finding is named.** The left half is the author's own sentence —
///   Shepherd's category label above it exists only so the four lines are scannable — and the
///   right half is facts with paths, never an adjective.
/// - **Every ✗ fact with a path is a link into the diff.** One click to check, which is the
///   difference between a card that is read and a card that is trusted. Facts come from changed
///   files, so the file is always in the diff; ``ReviewModel/reveal(path:line:)`` is the second
///   gate regardless.
/// - **"Turn into a comment" appears only on a contradicted line, and it writes into a field.**
///   It puts the claim and the facts into the review summary — asking first when the reviewer has
///   already written something there — and stops. There is no path from this card to
///   `submitReview`, to the outbox or to a saved draft comment.
/// - **Collapsed for people, expanded for agents.** ADR 0008's provenance facet: on a human pull
///   request the card is a header the reviewer can open, on an agent's it is the first thing they
///   read.
struct ClaimsEvidenceCard: View {
    /// What to draw and what the buttons do.
    let model: ClaimsEvidenceModel
    /// Opens a file — and a line, when the fact names one — in the diff viewer.
    let onOpenFile: (String, Int?) -> Void
    /// The review summary as it stands, read at click time.
    ///
    /// A closure rather than a value on purpose: the card only needs the field's contents when a
    /// button is pressed, and reading the observable property in `body` instead would make the
    /// whole conversation tab re-render on every keystroke in the submit sheet.
    let currentSummary: () -> String
    /// Writes the review summary. The only thing this card produces.
    let onWriteSummary: (String) -> Void

    /// Which lines have their facts open, by line id.
    ///
    /// A set rather than one open row: comparing the evidence for two claims is exactly what a
    /// reviewer opens this for. View state, not model state — it is about this screen, and it is
    /// thrown away with it, like ``CIDiagnosisTraceView``'s.
    @State private var openFacts: Set<String> = []

    var body: some View {
        if !model.state.isHidden {
            Card(tint: Theme.accent.opacity(0.06)) {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    if model.state.isExpanded {
                        ForEach(model.state.lines) { line in
                            row(line)
                        }
                        if model.state.pendingInsertion != nil {
                            replaceQuestion
                        } else if model.state.didInsertIntoSummary {
                            insertedConfirmation
                        }
                        footnote
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            model.state.toggleExpansion()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.state.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 10)
                CardTitle(
                    String(localized: "WHAT IT SAYS · WHAT SHEPHERD FOUND"),
                    tint: Theme.accentText
                )
                Spacer(minLength: 4)
                ForEach(statusCounts) { entry in
                    HStack(spacing: 3) {
                        Image(systemName: ClaimsEvidenceCard.glyph(entry.status))
                            .font(.system(size: 10))
                        Text(entry.countText)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(ClaimsEvidenceCard.colour(entry.status))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(
            localized: "What the description claims, beside what the diff and CI show. It never says whether to trust this pull request."
        ))
    }

    /// One glyph and its count on the header, so the collapsed card still says what is in it.
    private struct StatusCount: Identifiable {
        var status: EvidenceVerdict.Status
        var count: Int

        var id: String { status.rawValue }
        /// The number as plain text — a count, never a translated string.
        var countText: String { "\(count)" }
    }

    /// The non-zero counts, in ``statusOrder``.
    private var statusCounts: [StatusCount] {
        ClaimsEvidenceCard.statusOrder.compactMap { status in
            let count = model.state.lines.filter { $0.verdict.status == status }.count
            return count > 0 ? StatusCount(status: status, count: count) : nil
        }
    }

    // MARK: - One claim

    @ViewBuilder
    private func row(_ line: ClaimsEvidenceReport.Line) -> some View {
        let isOpen = openFacts.contains(line.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: ClaimsEvidenceCard.glyph(line.verdict.status))
                    .font(.system(size: 11))
                    .foregroundStyle(ClaimsEvidenceCard.colour(line.verdict.status))
                    .frame(width: 13)
                    .accessibilityLabel(ClaimsEvidenceCard.statusLabel(line.verdict.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ClaimsEvidenceCard.claimLabel(line.claim.kind))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textStrong)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(line.claim.quote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }

            Button {
                if isOpen {
                    openFacts.remove(line.id)
                } else {
                    openFacts.insert(line.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(ClaimsEvidenceCard.evidenceLabel(line.verdict.facts.count))
                        .font(.system(size: 11))
                }
                .foregroundStyle(Theme.textMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 19)

            if isOpen {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(line.verdict.facts) { fact in
                        factRow(fact)
                    }
                }
                .padding(.leading, 19)
            }

            if line.verdict.status == .contradicted {
                Button(String(localized: "Turn into a comment")) {
                    turnIntoComment(line)
                }
                .buttonStyle(SecondaryButtonStyle(height: 24, tint: Theme.accentText))
                .padding(.leading, 19)
                .help(String(
                    localized: "Puts this claim and the facts under it into your review summary. Nothing is sent."
                ))
            }

            Divider().overlay(Theme.hairline)
        }
    }

    /// One fact: the sentence, then whatever there is to open.
    @ViewBuilder
    private func factRow(_ fact: EvidenceFact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fact.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let path = fact.path {
                Button {
                    onOpenFile(path, fact.line)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9))
                        Text(ClaimsEvidenceCard.locationText(path: path, line: fact.line))
                            .font(Theme.mono(10.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .foregroundStyle(Theme.accentText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open this line in the diff"))
            }
            if let url = fact.url {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9))
                        Text(url.absoluteString)
                            .font(Theme.mono(10.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Theme.accentText)
                }
                .help(String(localized: "Open the issue on GitHub"))
            }
        }
    }

    // MARK: - Writing into the summary

    private var replaceQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Replace the review summary you already wrote?"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(String(localized: "Discard")) { model.state.discardInsertion() }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
                Button(String(localized: "Append")) { resolve(.append) }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
                    .help(String(localized: "Add the finding after what you already wrote"))
                Button(String(localized: "Replace")) { resolve(.replace) }
                    .buttonStyle(SecondaryButtonStyle(height: 26, tint: Theme.accentText))
                    .help(String(localized: "Overwrite the review summary with the finding"))
            }
        }
        .padding(10)
        .background(
            Theme.accent.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var insertedConfirmation: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 10))
            Text(String(
                localized: "Added to your review summary — open Submit review to edit it."
            ))
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.accentText)
    }

    private var footnote: some View {
        Text(String(
            localized: "Claims come from the description; evidence comes from the diff and CI. There is no score."
        ))
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.textMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    @MainActor
    private func turnIntoComment(_ line: ClaimsEvidenceReport.Line) {
        switch model.state.turnIntoComment(line, existingSummary: currentSummary()) {
        case .write(let text):
            onWriteSummary(text)
        case .askFirst:
            break
        }
    }

    @MainActor
    private func resolve(_ choice: ClaimsEvidenceCardState.Choice) {
        guard let text = model.state.resolveInsertion(choice, existingSummary: currentSummary())
        else { return }
        onWriteSummary(text)
    }

    // MARK: - Copy

    /// The order the counts appear in the header: supported, contradicted, unclear.
    static let statusOrder: [EvidenceVerdict.Status] = [.ok, .contradicted, .unclear]

    /// ✓ / ✗ / ? as the three glyphs the rest of the app already uses for those meanings.
    /// - Parameter status: The line's status.
    static func glyph(_ status: EvidenceVerdict.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle"
        case .contradicted: return "xmark.octagon"
        case .unclear: return "questionmark.circle"
        }
    }

    /// The colour of a status.
    ///
    /// Green, red and amber — the same three CI uses, deliberately: a contradicted claim is the
    /// same kind of "look here" as a red check, and inventing a fourth palette for it would make
    /// the review screen harder to read rather than more precise.
    /// - Parameter status: The line's status.
    static func colour(_ status: EvidenceVerdict.Status) -> Color {
        switch status {
        case .ok: return Theme.success
        case .contradicted: return Theme.failure
        case .unclear: return Theme.pending
        }
    }

    /// What the glyph means, for VoiceOver.
    /// - Parameter status: The line's status.
    /// - Returns: The already-localized label.
    static func statusLabel(_ status: EvidenceVerdict.Status) -> String {
        switch status {
        case .ok: return String(localized: "supported by the evidence")
        case .contradicted: return String(localized: "contradicted by the evidence")
        case .unclear: return String(localized: "not enough evidence")
        }
    }

    /// Shepherd's own short name for a claim, above the author's sentence.
    ///
    /// Four sentences rather than one interpolation, for the reason
    /// ``AIDraftStatusView/draftingLine(_:)`` gives about tier badges: the four are different
    /// grammatical shapes and a translator handed one key could not fix that.
    /// - Parameter kind: The claim's shape.
    /// - Returns: The already-localized label.
    static func claimLabel(_ kind: Claim.Kind) -> String {
        switch kind {
        case .testsAdded:
            return String(localized: "Tests added or run")
        case .scopeLimited(let module) where module.isEmpty:
            return String(localized: "Nothing else changed")
        case .scopeLimited(let module):
            return String(localized: "Only \(module) changed")
        case .noBreakingChanges:
            return String(localized: "No breaking changes")
        case .fixesIssue(let number):
            return String(localized: "Fixes issue #\(number)")
        }
    }

    /// "1 fact" / "5 facts" on the disclosure.
    /// - Parameter count: How many facts the line carries.
    /// - Returns: The already-localized label.
    static func evidenceLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 fact")
            : String(localized: "\(count) facts")
    }

    /// `path:line`, or just the path when the fact names no line.
    /// - Parameters:
    ///   - path: The changed file.
    ///   - line: The head-side line, when there is one.
    /// - Returns: The text on the link.
    static func locationText(path: String, line: Int?) -> String {
        guard let line else { return path }
        return "\(path):\(line)"
    }
}
