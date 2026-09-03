import Foundation
import ShepherdCore
import SwiftUI

// MARK: - Rail vocabulary

extension IssueAgeBucket {
    /// The rail's label for this bucket.
    ///
    /// The words are here rather than in `ShepherdCore` because `ShepherdCore` has no
    /// user-visible strings by decision (ADR 0022): the *bucketing* is pure and Linux-tested,
    /// the wording is the app's.
    var facetTitle: String {
        switch self {
        case .today: return String(localized: "Today")
        case .thisWeek: return String(localized: "This week")
        case .thisMonth: return String(localized: "This month")
        case .older: return String(localized: "Older")
        }
    }

    /// The tooltip every age row shares.
    ///
    /// One sentence for all four, because the honest part is the same for all four and it is the
    /// thing a reader gets wrong: the bucket is about when the issue was *opened*, so an issue
    /// somebody commented on this morning has not become a new issue.
    static var railHelp: String {
        String(
            localized: "Bucketed by when the issue was opened, not when it was last touched."
        )
    }
}

extension IssueAgentPullRequestFilter {
    /// The rail's label for this half.
    var facetTitle: String {
        switch self {
        case .hasAgentPullRequest: return String(localized: "Has an agent pull request")
        case .hasNone: return String(localized: "Nothing started yet")
        }
    }

    /// The tooltip both halves share, and it says what the facet can and cannot see.
    static var railHelp: String {
        String(
            localized: "Whether a machine wrote any of the pull requests GitHub says would close the issue. Only the ones the sweep saw count, so this can understate and never overstate."
        )
    }
}

// MARK: - The picker

/// The content-kind picker at the top of the rail (ADR 0032).
///
/// A segmented control rather than a second top-level route, which is the decision ``ContentKind``
/// records: `j`/`k`, ⌘K, the focus session and the menu-bar item all address the model that owns
/// the selection rather than a screen, so a route would duplicate the toolbar, the digest card,
/// the Settings sheet and the palette overlay for one control's worth of difference.
struct ContentKindPicker: View {
    /// Which kind is showing.
    @Binding var selection: ContentKind

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "Section"), selection: $selection) {
                ForEach(ContentKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)
            Divider().overlay(Theme.hairline)
        }
        .background(Theme.panel)
    }
}

// MARK: - The issues rail

/// The left rail while the issues section is showing: the agent-pull-request facet, LABELS, AGE,
/// REPOSITORIES, Settings (ADR 0032).
///
/// A view of its own rather than a `ContentKind` branch inside ``InboxSidebar``, because the two
/// rails share no section: there is no smart view, no lane, no risk and no agent facet here, and
/// a single view carrying both sets would be one `if` per section with nothing in common
/// underneath. What *is* shared is the row (``RailRow``), the section header
/// (``RailSectionHeader``) and the Settings row (``RailSettingsRow``), which is where the
/// consistency actually has to live.
///
/// The section order is the order a triage pass reads them in: what nobody has started on first,
/// then what it is about, then how long it has been sitting there, then where it lives.
struct IssueSidebar: View {
    /// The issues model.
    let model: IssueInboxModel
    /// Opens the Settings window.
    var onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                agentPullRequestFacet
                labelFacet
                ageFacet
                repositoriesFacet
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RailSettingsRow(action: onOpenSettings)
        }
    }

    // MARK: - Sections

    /// The "nothing started yet / has an agent pull request" facet.
    ///
    /// Absent entirely unless both halves are populated — the LANES facet's `facets.count > 1`
    /// rule, and for its reason: one populated half would filter to everything or to nothing,
    /// which is a dead control the user has to click to discover.
    @ViewBuilder
    private var agentPullRequestFacet: some View {
        let facets = model.agentPullRequestFacets
        if facets.count > 1 {
            VStack(alignment: .leading, spacing: 2) {
                RailSectionHeader(title: String(localized: "AGENT PULL REQUESTS"))
                ForEach(facets) { facet in
                    RailRow(
                        title: facet.filter.facetTitle,
                        dotColor: facet.filter == .hasAgentPullRequest
                            ? Theme.agent
                            : Theme.textSecondary,
                        count: facet.count,
                        isSelected: model.agentPullRequestFilter == facet.filter
                    ) {
                        model.agentPullRequestFilter = model.agentPullRequestFilter == facet.filter
                            ? nil
                            : facet.filter
                    }
                    .help(IssueAgentPullRequestFilter.railHelp)
                }
            }
        }
    }

    @ViewBuilder
    private var labelFacet: some View {
        let facets = model.labelFacets
        if !facets.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                RailSectionHeader(title: String(localized: "LABELS"))
                ForEach(facets.facets) { facet in
                    RailRow(
                        title: facet.name,
                        count: facet.count,
                        isSelected: model.labelFilter == facet.name
                    ) {
                        model.labelFilter = model.labelFilter == facet.name ? nil : facet.name
                    }
                }
                // The cap is visible rather than silent, exactly as the REPOSITORIES facet's is:
                // a ninth label the rail simply did not draw would be undiscoverable.
                if facets.hiddenCount > 0 {
                    Text(String(localized: "\(facets.hiddenCount) more…"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var ageFacet: some View {
        let facets = model.ageFacets
        if facets.count > 1 {
            VStack(alignment: .leading, spacing: 2) {
                RailSectionHeader(title: String(localized: "AGE"))
                ForEach(facets) { facet in
                    RailRow(
                        title: facet.bucket.facetTitle,
                        count: facet.count,
                        isSelected: model.ageFilter == facet.bucket
                    ) {
                        model.ageFilter = model.ageFilter == facet.bucket ? nil : facet.bucket
                    }
                    .help(IssueAgeBucket.railHelp)
                }
            }
        }
    }

    @ViewBuilder
    private var repositoriesFacet: some View {
        let facets = model.repositoryFacets
        if !facets.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                RailSectionHeader(title: String(localized: "REPOSITORIES"))
                ForEach(facets.prefix(6), id: \.repo) { facet in
                    RailRow(
                        title: facet.repo.fullName,
                        count: facet.count,
                        isSelected: model.repoFilter == facet.repo
                    ) {
                        model.repoFilter = model.repoFilter == facet.repo ? nil : facet.repo
                    }
                }
                if facets.count > 6 {
                    Text(String(localized: "\(facets.count - 6) more…"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}
