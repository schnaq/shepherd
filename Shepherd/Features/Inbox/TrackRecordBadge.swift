import Foundation
import ShepherdCore
import SwiftUI

extension TrustLane {
    /// The rail's label for this lane.
    var facetTitle: String {
        switch self {
        case .shortLook: return String(localized: "Short look")
        case .fullReview: return String(localized: "Full review")
        }
    }

    /// The rail row's tooltip, which is where the gate is spelled out.
    ///
    /// It names the three conditions and nothing else, because the one thing a reviewer must be
    /// able to trust about this facet is that a badge cannot have moved a pull request into it
    /// (ADR 0027).
    var railHelp: String {
        switch self {
        case .shortLook:
            return String(
                localized: "Green CI, a small diff and no sensitive path. A track record never puts a pull request in this lane."
            )
        case .fullReview:
            return String(
                localized: "Everything else: a red or running build, a diff over the thresholds, or a workflow, auth, secret, migration or deleted-test file."
            )
        }
    }

    /// The dot beside the rail row.
    ///
    /// The design tokens the CI dot already uses, for ``ShepherdCore/TriageVerdict/Risk``'s
    /// reason: green means "nothing is asking for you" everywhere else in the app, and a fourth
    /// palette would make a reviewer learn it again. The wide lane is *muted* rather than red —
    /// it is the ordinary case, not a warning.
    var chipColor: Color {
        switch self {
        case .shortLook: return Theme.success
        case .fullReview: return Theme.textSecondary
        }
    }
}

/// The track-record badge on an inbox row's provenance chip, and its popover (ADR 0027).
///
/// One chip, two facts: how much of this author's recent work in this repository was merged, and
/// how much of it was taken back out again. The popover carries the rest — the first-push rate,
/// the median number of rounds, and the line that says where the numbers come from.
///
/// The badge is never a control that does anything: clicking it opens the popover, exactly as the
/// triage chip beside it does. And it never moves a row between lanes — that is ADR 0027's rule,
/// and there is no code path from this view to ``ShepherdCore/TrustLane``.
struct TrackRecordBadge: View {
    @Environment(AppEnvironment.self) private var environment
    /// The author the record belongs to, as the row shows them.
    let authorName: String
    /// The agent-registry id behind that name, or `nil` when the author is not an agent.
    ///
    /// The fourth structural gate between the fleet and a page about a person (ADR 0035). The
    /// first three are in ShepherdCore — membership is `agentName != nil`, ``FleetAgent`` has no
    /// login field, and `shepherd://fleet/<id>` resolves registry ids — and this is the one on the
    /// surface a reviewer actually clicks: **`nil` means the popover's way into the fleet is not
    /// drawn at all**, so there is no button to press on a human's badge rather than a button that
    /// leads somewhere apologetic.
    ///
    /// Defaulted, and the default is the closed direction on purpose. A call site that forgets to
    /// pass it loses a button; one that could accidentally pass a login would open a page about
    /// somebody. Derive it with ``fleetAgentID(for:)`` rather than by hand.
    var agentID: String?
    /// The record. Rows with none do not render this view at all.
    let record: TrackRecord

    @State private var isShowingDetail = false

    var body: some View {
        Button {
            isShowingDetail.toggle()
        } label: {
            ChipView(text: TrackRecordBadge.chipText(for: record), color: record.chipColor)
        }
        .buttonStyle(.plain)
        .help(TrackRecordBadge.sentence(authorName: authorName, record: record))
        .accessibilityLabel(
            Text(TrackRecordBadge.sentence(authorName: authorName, record: record))
        )
        .popover(isPresented: $isShowingDetail, arrowEdge: .bottom) {
            TrackRecordPopover(authorName: authorName, agentID: agentID, record: record) {
                // Closed before the window changes underneath it. A popover is anchored to a row
                // in a list the fleet is about to replace, and one left standing would be a panel
                // floating over a screen that no longer contains the thing it points at.
                isShowingDetail = false
                environment.openFleet(agentID: agentID)
            }
        }
    }

    /// The id to hand this badge for one row's author.
    ///
    /// One expression, in one place, because it is a *rule* rather than an accessor: only an
    /// author the registry matched has an id, so a human and a plain bot both answer `nil` and the
    /// fleet is unreachable from their badge. Spelling it at each call site would make that rule a
    /// habit; spelling it here makes it a function with a test (ADR 0035).
    /// - Parameter author: The row's author, as provenance detection labelled them (ADR 0008).
    /// - Returns: The agent-registry id, or `nil` for a person or a generic bot.
    static func fleetAgentID(for author: ShepherdCore.Actor) -> String? {
        author.kind.agentIdentity?.id
    }

    /// The chip's own short text: the merged count, plus the reverted count when there is one.
    ///
    /// Deliberately the two *counts* rather than a rate: a percentage on a row would be a score,
    /// and a score is the one thing this feature refuses to be. "23 merged · 2 reverted" is two
    /// facts a reviewer can check on GitHub.
    /// - Parameter record: The record to describe.
    /// - Returns: The chip text.
    static func chipText(for record: TrackRecord) -> String {
        let merged = String(localized: "\(record.merged) merged")
        guard record.reverted > 0 else { return merged }
        return "\(merged) · \(String(localized: "\(record.reverted) reverted"))"
    }

    /// The whole badge as one sentence, for the tooltip and the screen reader.
    ///
    /// `Claude Code · this repo · 23 merged · 2 reverted · CI green first push 78 %` — the shape
    /// the interview asked for. Clauses with nothing to say are left out rather than printed as a
    /// zero: an author nobody reverted has no reverted clause, and an author whose first pushes
    /// nothing is known about has no rate clause, because a rate with an empty denominator would
    /// be invented.
    /// - Parameters:
    ///   - authorName: The agent's display name, or the author's login.
    ///   - record: The record to describe.
    /// - Returns: The sentence.
    static func sentence(authorName: String, record: TrackRecord) -> String {
        var parts: [String] = [authorName, String(localized: "this repo")]
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

    /// A percentage as text.
    ///
    /// Interpolated outside ``String(localized:)`` on purpose: `78 %` is the same in both
    /// languages, and a catalog key of `%lld %` would put a bare `%` into a format string.
    /// - Parameter percent: Whole percent.
    /// - Returns: The text.
    static func percentText(_ percent: Int) -> String {
        "\(percent) %"
    }

    /// The median rounds as text, without a pointless `.0`.
    /// - Parameter rounds: The median.
    /// - Returns: The text.
    static func roundsText(_ rounds: Double) -> String {
        rounds == rounds.rounded() ? "\(Int(rounds))" : String(format: "%.1f", rounds)
    }
}

extension TrackRecord {
    /// The colour the badge — and, through it, the provenance chip — is tinted with.
    ///
    /// Three states and no score:
    ///
    /// - something was **reverted**: amber, because a merge that had to be taken out again is the
    ///   one fact here worth interrupting a reading for;
    /// - a **settled** record — at least five merged pull requests and most first pushes green —
    ///   green;
    /// - anything else: the muted secondary, which is also what a thin record looks like. Three
    ///   merges are not evidence of anything, and a colour that implied they were would be the
    ///   feature quietly becoming a grade.
    var chipColor: Color {
        switch chipTone {
        case .reverted: return Theme.pending
        case .settled: return Theme.success
        case .muted: return Theme.textSecondary
        }
    }

    /// The three states behind ``chipColor``, so a test can assert the decision rather than compare
    /// two dynamic colours that are never the same instance.
    enum ChipTone: Equatable {
        case reverted, settled, muted
    }

    /// Which of the three states this record is in.
    var chipTone: ChipTone {
        if reverted > 0 { return .reverted }
        if merged >= TrackRecord.settledMergeCount,
           let rate = firstPushGreenRate,
           rate >= TrackRecord.settledFirstPushRate {
            return .settled
        }
        return .muted
    }

    /// How many merged pull requests a record needs before its colour says anything.
    static var settledMergeCount: Int { 5 }
    /// How green the first pushes have to be alongside that.
    static var settledFirstPushRate: Double { 0.7 }
}

/// The popover behind the badge: the numbers, where they come from, and — for an agent — the way
/// out of "this repo" into every repository (ADR 0035).
///
/// The way out matters more than it looks. The fleet's numbers are the same numbers this popover
/// already shows, counted over `repo: nil` instead of over one repository, so the reviewer who
/// wants them is exactly the reviewer who has just opened this popover and thought "and
/// elsewhere?". A screen nobody can get to from the moment they want it is a screen with a rail
/// row and no readers.
struct TrackRecordPopover: View {
    /// The author the record belongs to.
    let authorName: String
    /// The agent-registry id behind that name, or `nil` when the author is not an agent.
    ///
    /// See ``TrackRecordBadge/agentID``: `nil` removes the footer button rather than disabling it.
    let agentID: String?
    /// The record.
    let record: TrackRecord
    /// Opens this agent's fleet page. Never called while ``agentID`` is `nil`.
    let onOpenFleet: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(String(localized: "TRACK RECORD"))
            Text(authorName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textStrong)
            line(String(localized: "\(record.merged) merged"))
            line(String(localized: "\(record.closedUnmerged) closed without merging"))
            line(String(localized: "\(record.reverted) reverted"))
            if let percent = record.firstPushGreenPercent {
                line(
                    String(
                        localized: "CI green on the first push: \(TrackRecordBadge.percentText(percent))"
                    )
                )
            }
            if let rounds = record.medianReviewRounds {
                line(
                    String(
                        localized: "Median rounds of changes requested: \(TrackRecordBadge.roundsText(rounds))"
                    )
                )
            }
            Divider().overlay(Theme.hairline)
            // The provenance line, and it is the point of the popover as much as the numbers are:
            // the three questions a count like this raises are "counted where", "counted when"
            // and "counted by whom", and the answers are this repository, ninety days, and this
            // Mac — the history is not synced (ADR 0014, ADR 0027).
            Text(String(localized: "this repo · last 90 days · on this Mac"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(
                localized: "Counted from closed pull requests, and read by nothing but this badge and the order of the list. It never decides a lane."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            if TrackRecordPopover.offersFleet(agentID: agentID) {
                // Under the provenance line rather than above it, because it answers the question
                // that line raises: it says "this repo", and this is where the reader goes when
                // that is not the scope they wanted.
                Button(String(localized: "See every repository")) { onOpenFleet() }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    /// Whether the popover offers its way into the fleet.
    ///
    /// A named decision rather than an `if let` buried in the body, so the gate that keeps a
    /// person's badge from having a route to a track-record page is a line a test can assert
    /// (ADR 0035) — the same reason ``TrackRecord/chipTone`` exists beside ``TrackRecord/chipColor``.
    /// - Parameter agentID: The badge's agent id, or `nil` for a person or a generic bot.
    /// - Returns: `true` only for an agent.
    static func offersFleet(agentID: String?) -> Bool { agentID != nil }

    private func line(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(Theme.textMuted)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
    }
}
