import ShepherdCore
import SwiftUI

/// One cell of the fleet's numbers, and the em-dash rule behind every one of them.
///
/// ADR 0027 makes ``ShepherdCore/TrackRecord/firstPushGreenRate`` `nil` rather than zero when its
/// denominator is empty, because "the first push was red" and "nothing is known about the first
/// push" are different facts and only one of them is an accusation. This is that rule applied to
/// the counts as well: a repository the agent has closed nothing in inside the window shows an
/// em-dash in every closed-side cell rather than a row of zeroes, contributes to no denominator,
/// and is never rendered as `0 %`.
///
/// `@MainActor` because ``TrackRecordBadge``'s two formatters are static members of a `View` and
/// inherit that isolation. Reusing them is the point: "78 %" and "1.5" are typographic decisions
/// the badge already made, and a second spelling of the same number on a second screen would be
/// two answers to one question.
@MainActor
enum FleetCell {
    /// What a fact nobody counted reads as.
    static let absent = "—"

    /// The same fact in words, for a tooltip and for a spoken row.
    ///
    /// A dash is a glyph, and a glyph is never the only carrier of a fact (ADR 0033) — so every
    /// place that draws ``absent`` says this beside it or in its label.
    static var absentSpoken: String {
        String(localized: "Nothing counted in the last 90 days")
    }

    /// One count, or the em-dash when the record counted nothing at all.
    ///
    /// The question is asked of the whole record rather than of the value: a record with four
    /// merges and no reverts genuinely has *zero* reverted, and printing an em-dash there would
    /// hide a fact rather than decline to invent one.
    /// - Parameters:
    ///   - value: The count to show.
    ///   - record: The record it came from.
    /// - Returns: The cell's text.
    static func count(_ value: Int, in record: TrackRecord) -> String {
        record.isEmpty ? absent : "\(value)"
    }

    /// The first-push rate as whole percent, or the em-dash when nothing said anything about it.
    /// - Parameter record: The record.
    /// - Returns: The cell's text.
    static func firstPush(_ record: TrackRecord) -> String {
        guard let percent = record.firstPushGreenPercent else { return absent }
        return TrackRecordBadge.percentText(percent)
    }

    /// The median number of change-requesting rounds, or the em-dash.
    /// - Parameter record: The record.
    /// - Returns: The cell's text.
    static func rounds(_ record: TrackRecord) -> String {
        guard let rounds = record.medianReviewRounds else { return absent }
        return TrackRecordBadge.roundsText(rounds)
    }
}

extension TrackRecordBadge {
    /// ``sentence(authorName:record:)`` with the scope named by the caller.
    ///
    /// An overload rather than a changed signature, so every existing call site keeps saying
    /// "this repo" — which is the truth on an inbox row, where the record beside a pull request
    /// is counted in that pull request's repository and nowhere else. The fleet's aggregate is
    /// the call `TrackRecord.compute(outcomes:subject:repo:since:)` was written for and nobody
    /// had ever made — `repo: nil`, every repository at once — and a sentence saying "this repo"
    /// over it would be describing a different number from the one it is attached to.
    ///
    /// The clauses are assembled again here rather than delegated to, because the base overload
    /// spells its scope in the middle of the list and there is no seam to hand a replacement
    /// through. What must not drift is *which* clauses appear and when, so that rule is repeated
    /// in full and in the same order: the merged count always, the reverted clause only when
    /// something was, the rate only when there is a denominator behind it.
    /// - Parameters:
    ///   - authorName: The agent's display name.
    ///   - record: The record to describe.
    ///   - scope: What the record was counted over, in the reader's words.
    /// - Returns: The sentence.
    static func sentence(authorName: String, record: TrackRecord, scope: String) -> String {
        var parts: [String] = [authorName, scope]
        parts.append(String(localized: "\(record.merged) merged"))
        if record.reverted > 0 {
            parts.append(String(localized: "\(record.reverted) reverted"))
        }
        if let percent = record.firstPushGreenPercent {
            parts.append(
                String(localized: "CI green first push \(TrackRecordBadge.percentText(percent))")
            )
        }
        return parts.joined(separator: " · ")
    }
}

/// One agent's page: the aggregate, what the counts say about it, the same counting one
/// repository at a time, and what of its is open right now (plan §2).
///
/// **The aggregate leads and the breakdown is never collapsed.** A rate over four repositories
/// can hide a single bad one, so an average is never shown without the rows it averages — which
/// is also why every notice names a repository: each of the three sentences is derivable from the
/// grid drawn underneath it, and a reader who doubts one can count that row themselves.
///
/// Like ``FleetAgentRow``, this page uses no ``ShepherdCore/TrackRecord/chipColor`` and no
/// `chipTone`. Nothing here is a grade, and nothing here can move a pull request between the
/// trust lanes: there is no code path from this file to ``ShepherdCore/TrustLane``.
struct FleetAgentDetail: View {
    @Environment(AppEnvironment.self) private var environment
    /// The screen's model — the source of the notices, the registry and the open rows.
    let model: FleetModel
    /// The agent this page is about.
    let agent: FleetAgent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                aggregateSection
                if !notices.isEmpty { noticeSection }
                repositorySection
                if !openGroups.isEmpty { openSection }
                provenanceFooter
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The list row's palette key, not a second spelling of it: the dot beside a name
                // in the list and the dot above the same name here have to be one colour.
                Circle()
                    .fill(AgentPalette.color(forAgentID: FleetAgentRow.paletteID(for: agent)))
                    .frame(width: 10, height: 10)
                Text(agent.displayName)
                    .font(Theme.type(.title3, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                    .accessibilityAddTraits(.isHeader)
            }
            if let detection = detectionLine {
                Text(detection)
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(String(localized: "Open Settings → Agents")) { openAgentSettings() }
                .buttonStyle(SecondaryButtonStyle(height: 24))
        }
    }

    /// How Shepherd recognises this agent, when the registry can say.
    ///
    /// `nil` for an agent with no registry id — one that only history knows, whose stored
    /// outcomes carry its display name and never its id — and `nil` again for an id the registry
    /// no longer has, which is what an agent the user has since deleted looks like. Both mean
    /// there is nothing truthful to say, and a line that guessed would be worse than no line:
    /// misdetection has to stay inspectable (ADR 0008), which it cannot be if the explanation is
    /// invented.
    private var detectionLine: String? {
        guard let entry = model.registryEntry(for: agent) else { return nil }
        return FleetAgentDetail.detectionLine(for: entry)
    }

    /// The detection line for one registry entry, or `nil` when the entry names no signal at all.
    ///
    /// Static and pure so the sentence a user reads is assertable without a registry on disk.
    /// The patterns themselves are literal syntax and are **not** translated (ADR 0022): a login
    /// glob and a branch prefix are values the user typed into Settings → Agents.
    /// - Parameter entry: The registry entry.
    /// - Returns: The line, or `nil`.
    static func detectionLine(for entry: AgentRegistryEntry) -> String? {
        var signals: [String] = []
        if !entry.loginPatterns.isEmpty {
            signals.append(String(localized: "logins \(joined(entry.loginPatterns))"))
        }
        if !entry.branchPrefixes.isEmpty {
            signals.append(String(localized: "branch prefixes \(joined(entry.branchPrefixes))"))
        }
        if !entry.commitTrailers.isEmpty {
            signals.append(String(localized: "commit trailers \(joined(entry.commitTrailers))"))
        }
        guard !signals.isEmpty else { return nil }
        return String(
            localized: "Shepherd recognises this agent by \(signals.joined(separator: " · "))."
        )
    }

    private static func joined(_ values: [String]) -> String {
        values.joined(separator: ", ")
    }

    /// Opens Settings on the agent registry.
    ///
    /// The route the deep-link router takes for `shepherd://settings/agents`, raised from here
    /// rather than presented here: the Settings sheet belongs to the inbox screen, and a second
    /// copy of it on the fleet would be a second place a tab can be open. One mechanism, and this
    /// screen owns no sheet of its own.
    private func openAgentSettings() {
        environment.route = .inbox
        environment.pendingSettingsTab = AppEnvironment.Pending(SettingsDeepLinkTab.agents)
    }

    // MARK: - Across every repository

    /// The counting this page leads with: `repo: nil`, every repository at once.
    private var record: TrackRecord { agent.overall }

    private var aggregateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(String(localized: "ACROSS EVERY REPOSITORY"))
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    if record.isEmpty {
                        // One sentence rather than five zeroes. "0 merged · 0 reverted" is a
                        // claim about an agent; "nothing was counted" is a statement about
                        // Shepherd, and only the second one is true here.
                        bullet(FleetCell.absentSpoken)
                    } else {
                        bullet(String(localized: "\(record.merged) merged"))
                        bullet(String(localized: "\(record.closedUnmerged) closed without merging"))
                        bullet(String(localized: "\(record.reverted) reverted"))
                        bullet(
                            String(
                                localized: "CI green on the first push: \(FleetCell.firstPush(record))"
                            )
                        )
                        bullet(
                            String(
                                localized: "Median rounds of changes requested: \(FleetCell.rounds(record))"
                            )
                        )
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(aggregateSpoken))
        }
    }

    /// The card as one sentence, in the badge's own words with the scope corrected.
    private var aggregateSpoken: String {
        guard !record.isEmpty else { return FleetCell.absentSpoken }
        return TrackRecordBadge.sentence(
            authorName: agent.displayName,
            record: record,
            scope: FleetAgentDetail.scopeText
        )
    }

    // MARK: - The notices

    private var notices: [FleetNotice] { model.notices(for: agent) }

    private var noticeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(String(localized: "WHAT THE COUNTS SAY"))
            // At most three, and the cap is the shape of `FleetNotices.detect` rather than a
            // number applied here: three rules, one sentence each, in a fixed order. Nothing on
            // this screen can turn one of them into an action.
            ForEach(notices, id: \.self) { notice in
                Card {
                    Text(FleetNoticeText.text(for: notice))
                        .font(Theme.type(.callout))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Repository by repository

    private var repositorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(String(localized: "REPOSITORY BY REPOSITORY"))
            // Never collapsed and never behind a disclosure: the aggregate above is only allowed
            // to exist because the rows it averages are on the same screen (plan §2).
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text(String(localized: "Repository"))
                    Text(String(localized: "Merged"))
                    Text(String(localized: "Closed"))
                    Text(String(localized: "Reverted"))
                    Text(String(localized: "First push"))
                    Text(String(localized: "Rounds"))
                    Text(String(localized: "Open"))
                }
                .font(Theme.type(.footnote, weight: .semibold))
                .foregroundStyle(Theme.textMuted)

                ForEach(agent.repositories) { entry in
                    GridRow {
                        repositoryName(entry)
                        cell(FleetCell.count(entry.record.merged, in: entry.record))
                        cell(FleetCell.count(entry.record.closedUnmerged, in: entry.record))
                        cell(FleetCell.count(entry.record.reverted, in: entry.record))
                        cell(FleetCell.firstPush(entry.record))
                        cell(FleetCell.rounds(entry.record))
                        // The open count is on the live side of the em-dash rule and stays a
                        // number: zero open pull requests is something Shepherd knows, not
                        // something it failed to count.
                        cell("\(entry.openCount)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(spokenRepository(entry)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func repositoryName(_ entry: FleetRepositoryRecord) -> some View {
        HStack(spacing: 6) {
            Text(entry.repo.fullName)
                .font(Theme.mono(.subheadline))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if entry.isHistoryOnly {
                Text(String(localized: "history only"))
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.textMuted)
                    .help(String(localized: "No open pull request in the inbox names this repository any more, so what is left here is history that outlived it."))
            }
        }
    }

    private func cell(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(.subheadline))
            .monospacedDigit()
            .foregroundStyle(Theme.textSecondary)
    }

    /// One grid row as one sentence: every cell it draws, with a word for every number.
    ///
    /// The em-dashes become ``FleetCell/absentSpoken`` rather than being read out as punctuation,
    /// and the clauses behind them are dropped instead of announced as gaps — a repository with
    /// nothing counted says so once.
    /// - Parameter entry: The repository's row.
    /// - Returns: The spoken label.
    private func spokenRepository(_ entry: FleetRepositoryRecord) -> String {
        let record = entry.record
        return SpokenRow.sentence([
            entry.repo.fullName,
            record.isEmpty ? FleetCell.absentSpoken : String(localized: "\(record.merged) merged"),
            record.isEmpty
                ? nil
                : String(localized: "\(record.closedUnmerged) closed without merging"),
            record.isEmpty ? nil : String(localized: "\(record.reverted) reverted"),
            record.firstPushGreenPercent.map {
                String(localized: "CI green on the first push: \(TrackRecordBadge.percentText($0))")
            },
            record.medianReviewRounds.map {
                String(
                    localized: "Median rounds of changes requested: \(TrackRecordBadge.roundsText($0))"
                )
            },
            String(localized: "\(entry.openCount) open"),
            entry.isHistoryOnly ? String(localized: "history only") : nil,
        ])
    }

    // MARK: - Open right now

    private var openGroups: [FleetOpenGroup] { model.openPullRequests(for: agent) }

    private var openSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(String(localized: "OPEN RIGHT NOW"))
            ForEach(openGroups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.repo.fullName)
                        .font(Theme.mono(.footnote))
                        .foregroundStyle(Theme.textMuted)
                    ForEach(group.rows) { row in
                        Button {
                            // The cursor moves to what was just opened, so a reader coming back
                            // and pressing Return re-opens the pull request they were reading
                            // rather than the top of the list.
                            model.selectOpenPullRequest(row.id)
                            environment.openReview(prID: row.id)
                        } label: {
                            openRowLabel(row)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Open this review"))
                    }
                }
            }
        }
    }

    private func openRowLabel(_ row: PullRequestSummary) -> some View {
        HStack(spacing: 8) {
            CheckDotView(state: row.checkRollup?.state)
            // `Text(_:)` over a `String` rather than a literal: this is a title somebody typed on
            // GitHub, and a literal here would become a catalog key (ADR 0022).
            Text(openRowTitle(row))
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if row.needsMyReview {
                ChipView(text: String(localized: "Review requested"), color: Theme.accentText)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            row.id == model.selectedOpenPullRequestID ? Theme.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private func openRowTitle(_ row: PullRequestSummary) -> String {
        "\(row.slug) · \(row.title)"
    }

    // MARK: - Provenance

    /// What the numbers on this page were counted over.
    ///
    /// ``TrackRecordPopover``'s line with its scope corrected, and the correction is the whole
    /// difference: the popover is attached to a record counted in one repository and this page's
    /// aggregate is counted in all of them. The other two answers — ninety days, this Mac — are
    /// unchanged, because the window is the same window and the history is device state that no
    /// second Mac has (ADR 0014, ADR 0027).
    static var scopeText: String {
        String(localized: "every repository Shepherd has counted · last 90 days · on this Mac")
    }

    private var provenanceFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Theme.hairline)
            Text(FleetAgentDetail.scopeText)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            // Verbatim from the popover, one key shared by both surfaces. Two spellings of "what
            // this counting is and what reads it" would drift, and the sentence is load-bearing:
            // it is where the screen says that nothing here decides a lane.
            Text(String(
                localized: "Counted from closed pull requests, and read by nothing but this badge and the order of the list. It never decides a lane."
            ))
            .font(Theme.type(.subheadline))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - Shared pieces

    private func sectionTitle(_ text: String) -> some View {
        CardTitle(text)
            .accessibilityAddTraits(.isHeader)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: "•").foregroundStyle(Theme.textMuted)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.type(.callout))
        .foregroundStyle(Theme.textSecondary)
    }
}
