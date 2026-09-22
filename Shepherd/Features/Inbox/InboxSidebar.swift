import ShepherdCore
import SwiftUI

/// The left rail: smart views, the LANES facet, the RISK facet, the AGENTS facet, the
/// REPOSITORIES facet, and the two pinned rows at the bottom — Fleet and Settings.
struct InboxSidebar: View {
    /// The inbox model.
    let model: InboxModel
    /// Opens the Settings window.
    var onOpenSettings: () -> Void
    /// Raises the "watch a repository" dialog.
    var onWatchRepository: () -> Void
    /// The repositories being watched, which are listed whether or not the current view holds a
    /// row from them.
    var watchedRepositories: [RepoRef] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                smartViews
                laneFacet
                riskFacet
                agentsFacet
                repositoriesFacet
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .columnHeight()
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Two pinned rows, the fleet above Settings. Above, because the fleet is a place a
            // reviewer goes *while* triaging and Settings is where they go when they have
            // stopped — and the bottom edge is the one anchor in this rail that does not move as
            // facets appear and disappear (ADR 0035).
            VStack(spacing: 0) {
                RailFleetRow()
                RailSettingsRow(action: onOpenSettings)
            }
        }
    }

    // MARK: - Sections

    private var smartViews: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SmartView.allCases) { view in
                RailRow(
                    title: view.title,
                    systemImage: view.systemImage,
                    count: model.count(for: view),
                    isSelected: model.smartView == view
                ) {
                    model.smartView = view
                }
                .help(helpText(for: view))
            }
        }
    }

    /// The LANES facet (ADR 0027).
    ///
    /// Directly under the smart views and above RISK, because it answers the question a
    /// maintainer with thirty agent pull requests asks first: which of these can I get through
    /// quickly. It is absent entirely when every row is in one lane — a rail row that filters to
    /// nothing is a dead control, which is the rule the three facets below it follow too.
    ///
    /// The tooltip is the honest part, and it is the same promise ADR 0027 makes: the gate is CI,
    /// size and sensitive paths, and a track record never moves a pull request between these two
    /// rows.
    @ViewBuilder
    private var laneFacet: some View {
        let facets = model.laneFacets
        if facets.count > 1 {
            VStack(alignment: .leading, spacing: 2) {
                RailSectionHeader(title: String(localized: "LANES"))
                ForEach(facets) { facet in
                    RailRow(
                        title: facet.lane.facetTitle,
                        dotColor: facet.lane.chipColor,
                        count: facet.count,
                        isSelected: model.laneFilter == facet.lane
                    ) {
                        model.laneFilter = model.laneFilter == facet.lane ? nil : facet.lane
                    }
                    .help(facet.lane.railHelp)
                }
            }
        }
    }

    /// The RISK facet (ADR 0023).
    ///
    /// Directly under the smart views, above the agents, because it answers the question a
    /// reviewer asks *after* "who is waiting on me": which of these can hurt. It is absent
    /// entirely when nothing has a risk — a fresh install, a Mac with the switch off, an inbox
    /// nobody has opened a pull request in — which is the same rule the two facets below follow
    /// and is what keeps the rail from carrying a section that filters to nothing.
    ///
    /// The tooltip is the honest part: with the on-device model off the counts come from the
    /// tier-1 hints, and the rail says so rather than passing heuristics off as verdicts.
    @ViewBuilder
    private var riskFacet: some View {
        let facets = model.riskFacets
        if !facets.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                RailSectionHeader(title: String(localized: "RISK"))
                ForEach(facets) { facet in
                    RailRow(
                        title: facet.risk.facetTitle,
                        dotColor: facet.risk.chipColor,
                        count: facet.count,
                        isSelected: model.riskFilter == facet.risk
                    ) {
                        model.riskFilter = model.riskFilter == facet.risk ? nil : facet.risk
                    }
                    .help(helpText(for: facet))
                }
            }
        }
    }

    @ViewBuilder
    private var agentsFacet: some View {
        let facets = model.provenanceFacets
        if !facets.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                RailSectionHeader(title: String(localized: "AGENTS"))
                ForEach(facets, id: \.filter) { facet in
                    RailRow(
                        title: facet.title,
                        dotColor: facet.color,
                        count: facet.count,
                        isSelected: model.provenanceFilter == facet.filter
                    ) {
                        model.provenanceFilter = model.provenanceFilter == facet.filter
                            ? nil
                            : facet.filter
                    }
                }
            }
        }
    }

    /// The repositories: the watched ones first, always, by name; then the rest of the inbox.
    ///
    /// Drawn even when it is empty, because watching a repository is how a pull request nobody
    /// named you on reaches the inbox at all, and an inbox with nothing in it is exactly when a
    /// reader needs the `+`. The watched block is the fixed part of the rail: its rows come from
    /// the watch list rather than from what the inbox holds, so a watched repository is listed in
    /// the same place under every smart view, at zero when the view holds nothing from it. The
    /// rest keep the whole inbox's order (``InboxModel/repositoryFacets``), so switching smart
    /// views changes their numbers and never their places.
    private var repositoriesFacet: some View {
        let others = unwatchedFacets
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                RailSectionHeader(title: String(localized: "REPOSITORIES"))
                Button(action: onWatchRepository) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Watch a repository, so every open pull request in it reaches the inbox (⇧⌘A)"))
                .accessibilityLabel(Text(String(localized: "Watch a repository")))
                .padding(.trailing, 10)
                .padding(.bottom, 6)
            }
            ForEach(watchedFacets, id: \.repo.fullName) { facet in
                RailRow(
                    title: facet.repo.fullName,
                    systemImage: "binoculars",
                    count: facet.count,
                    isSelected: model.repoFilter.map { $0.isSameRepository(as: facet.repo) } ?? false
                ) {
                    toggleRepoFilter(facet.repo)
                }
                .help(String(localized: "Watched: every open pull request in this repository reaches the inbox."))
            }
            ForEach(others.prefix(6), id: \.repo) { facet in
                RailRow(
                    title: facet.repo.fullName,
                    systemImage: "folder",
                    count: facet.count,
                    isSelected: model.repoFilter == facet.repo
                ) {
                    toggleRepoFilter(facet.repo)
                }
            }
            if others.count > 6 {
                Text(String(localized: "\(others.count - 6) more…"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
    }

    /// Filters to a repository, or clears the filter when it is already that one.
    private func toggleRepoFilter(_ repo: RepoRef) {
        let isActive = model.repoFilter.map { $0.isSameRepository(as: repo) } ?? false
        model.repoFilter = isActive ? nil : repo
    }

    /// The watch list by name, each with the current view's count — zero when it holds none.
    ///
    /// The repository is the inbox's own spelling when the inbox has it, because the filter
    /// compares `RepoRef`s and a watch list typed by hand may differ in case.
    private var watchedFacets: [(repo: RepoRef, count: Int)] {
        let facets = model.repositoryFacets
        return InboxSidebar.watchedFacets(watchedRepositories, facets: facets)
    }

    /// ``watchedFacets``, pure, so the order and the zeroes are testable.
    nonisolated static func watchedFacets(
        _ watched: [RepoRef],
        facets: [(repo: RepoRef, count: Int)]
    ) -> [(repo: RepoRef, count: Int)] {
        watched
            .map { repo in
                facets.first { $0.repo.isSameRepository(as: repo) } ?? (repo: repo, count: 0)
            }
            .sorted { $0.repo.fullName.lowercased() < $1.repo.fullName.lowercased() }
    }

    /// Every repository in the inbox that is not on the watch list, in the inbox's order.
    private var unwatchedFacets: [(repo: RepoRef, count: Int)] {
        model.repositoryFacets.filter { facet in
            !watchedRepositories.contains { $0.isSameRepository(as: facet.repo) }
        }
    }

    /// Says where a risk row's number came from, because the two sources are different claims.
    private func helpText(for facet: TriageRiskFacet) -> String {
        guard facet.classifiedCount > 0 else {
            return String(
                localized: "Risk hints from the changed files, worked out without a model."
            )
        }
        guard facet.classifiedCount < facet.count else {
            return String(localized: "Classified on this Mac by the on-device model.")
        }
        return String(
            localized: "\(facet.classifiedCount) of \(facet.count) classified on this Mac; the rest are risk hints from the changed files."
        )
    }

    private func helpText(for view: SmartView) -> String {
        switch view {
        case .needsMyReview:
            return String(localized: "Pull requests where your review was explicitly requested.")
        case .myPullRequests:
            return String(localized: "Pull requests you opened.")
        case .involved:
            return String(localized: "Everything Shepherd syncs for you.")
        case .watched:
            return String(
                localized: "Open pull requests in the repositories you watch that nobody has involved you in. Set them up in Settings → Sync."
            )
        case .approvedByMe:
            return String(localized: "Approximation: pull requests you were asked to review that now carry an approval.")
        }
    }
}

/// The Settings row pinned to the bottom of the left rail.
///
/// Extracted rather than duplicated when the issues rail arrived (ADR 0032): it is the same
/// control in the same place doing the same thing, and two copies would be two places for the
/// row height and the label to drift apart.
struct RailSettingsRow: View {
    /// Opens the Settings window.
    var action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.border)
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                    Text(String(localized: "Settings"))
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Theme.panel)
    }
}

/// One row of the left rail.
struct RailRow: View {
    /// The label.
    let title: String
    /// An optional leading SF Symbol.
    var systemImage: String?
    /// An optional leading colour dot (used by the agents facet).
    var dotColor: Color?
    /// The trailing count.
    var count: Int?
    /// Whether the row is the active facet.
    var isSelected: Bool
    /// What clicking does.
    var action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A row whose count is zero in the current view stays where it is and steps back instead of
    /// leaving (``InboxModel/stabilised(_:counts:key:zero:)``).
    private var isEmpty: Bool { count == 0 && !isSelected }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                        .frame(width: 15)
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                } else if let dotColor {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .frame(width: 15, alignment: .leading)
                }
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textMuted)
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count)))
                        .animation(reduceMotion ? nil : .snappy, value: count)
                }
            }
            .foregroundStyle(isSelected ? Theme.textStrong : Theme.textSecondary)
            .opacity(isEmpty ? 0.55 : 1)
            .padding(.horizontal, 10)
            // One height for every row. A row with an icon used to be 2 pt taller than one with a
            // dot, so a repository gaining or losing its binoculars moved everything below it.
            .frame(height: 30)
            .background(
                isSelected
                    ? Theme.selection
                    : (isHovering ? Theme.textMuted.opacity(0.08) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
