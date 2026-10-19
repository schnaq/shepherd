import ShepherdCore
import SwiftUI

/// The iPhone's inbox (ADR 0044): the root of the signed-in navigation stack.
///
/// The Mac's `InboxModel`, unchanged, under a phone layout. The Mac's three panes become one list:
/// the rail's smart views are a row of pills at the top of it — they filter one list rather than
/// being separate places, so they are not tabs — and its facets move into the toolbar's filter
/// menu. Tapping a row pushes ``PhoneRoute/pullRequest(id:)``; the detail panel the Mac draws
/// beside the list is that screen.
///
/// Content only: the root owns the `NavigationStack` and registers the route's destination, so
/// this view can be dropped into it as the stack's first screen.
///
/// What it deliberately does not draw, and why:
///
/// - **No risk facet and no triage chip.** The phone builds no `TriageCoordinator` (ADR 0044's
///   composition-root line), so there is nothing to filter on or show.
/// - **No bulk selection.** Ticking rows is a pointer-and-keyboard way through a list; the phone's
///   way through it is one swipe per row.
/// - **No merge from the row.** Merging asks for a method and shows what will land, which is the
///   pull request screen's merge sheet; the row's context menu opens that screen instead.
struct PhoneInboxScreen: View {
    @Environment(PhoneEnvironment.self) private var environment
    /// The inbox model — the Mac's own.
    let model: InboxModel
    /// Opens the settings sheet, which the root owns.
    var onOpenSettings: () -> Void

    /// What is typed into the search field.
    @State private var query = ""
    /// The pull request the close confirmation is asking about.
    @State private var closeTarget: PullRequestSummary?
    /// Bumped when an approval reached the outbox, for the success haptic.
    @State private var approvalCount = 0
    /// Bumped when a refresh brought new rows, for the success haptic.
    @State private var arrivalCount = 0

    var body: some View {
        List {
            if !isSearching {
                smartViewPills
            }
            if let error = model.session.lastSyncError {
                PhoneSyncErrorStrip(message: error, lastSyncedAt: model.session.lastSyncedAt) {
                    Task { await refresh() }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        // While searching, the results span every smart view, so the title stops naming one.
        .navigationTitle(isSearching ? String(localized: "Search") : model.smartView.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbar }
        .searchable(
            text: $query,
            prompt: Text(String(localized: "Title, repository, author or branch"))
        )
        .refreshable { await refresh() }
        .task { model.startObserving() }
        .closePullRequestConfirmation($closeTarget, actions: actions)
        .sensoryFeedback(.selection, trigger: model.smartView)
        .sensoryFeedback(.success, trigger: approvalCount)
        .sensoryFeedback(.success, trigger: arrivalCount)
        .animation(.snappy, value: model.smartView)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isSearching {
            let results = searchResults
            if results.isEmpty {
                emptyRow { ContentUnavailableView.search(text: query) }
            } else {
                Section {
                    rows(results)
                } header: {
                    PhoneSectionHeader(title: String(localized: "All pull requests"), count: results.count)
                }
            }
        } else if !model.hasLoaded || isAwaitingFirstSweep {
            Section {
                ForEach(0..<6, id: \.self) { _ in
                    PhoneInboxPlaceholderRow()
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.hairline)
                }
            } header: {
                Text(String(localized: "Fetching your pull requests…"))
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.textMuted)
            }
        } else if model.filteredRows.isEmpty {
            emptyRow { emptyState }
        } else {
            ForEach(model.sections) { section in
                Section {
                    rows(section.items)
                } header: {
                    PhoneSectionHeader(section: section)
                }
            }
            if model.smartView == .approvedByMe {
                // The Mac's honesty about this view, said where the Mac says it in a tooltip.
                Text(String(localized: "Approximation: pull requests you were asked to review that now carry an approval."))
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.textMuted)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func rows(_ rows: [PullRequestSummary]) -> some View {
        ForEach(rows) { row in
            NavigationLink(value: PhoneRoute.pullRequest(id: row.id)) {
                PhoneInboxRow(
                    row: row,
                    rounds: model.reviewRounds(for: row.id),
                    hasSession: model.sessionReference(for: row.id) != nil,
                    trackRecord: model.trackRecord(for: row.id),
                    write: writeState(for: row)
                )
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.hairline)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    approve(row)
                } label: {
                    Label(String(localized: "Approve"), systemImage: "checkmark")
                }
                .tint(Theme.accent)
                .disabled(row.verdictBlocker != nil)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    hide(row)
                } label: {
                    Label(String(localized: "Hide"), systemImage: "eye.slash")
                }
                .tint(Theme.textMuted)
            }
            .contextMenu { rowMenu(for: row) }
        }
    }

    /// One full-width row holding an empty state, so the pills above it stay reachable.
    private func emptyRow(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// The three kinds of empty: the pile cleared, a filter matching nothing, a view with nothing
    /// in it — the Mac's distinction (`InboxModel.showsInboxZero`), in the phone's words.
    @ViewBuilder
    private var emptyState: some View {
        if model.showsInboxZero {
            PhoneInboxZeroView(message: inboxZeroMessage)
        } else if model.hasActiveFilter {
            ContentUnavailableView {
                Label(String(localized: "Nothing matches this filter"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(String(localized: "No pull request matches this filter. Clear it to see everything again."))
            } actions: {
                Button(String(localized: "Clear filter")) { model.clearFilter() }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
        } else {
            ContentUnavailableView {
                Label(String(localized: "Nothing to review"), systemImage: "checkmark.circle")
            } description: {
                Text(emptyMessage)
            }
        }
    }

    /// The caught-up line. The model's own says "⌘R checks now" when there is no work of the
    /// user's to point at; a phone has no ⌘R, it has pull to refresh.
    private var inboxZeroMessage: String {
        model.count(for: .myPullRequests) > 0
            ? model.inboxZeroMessage
            : String(localized: "New review requests land here on their own. Pull down to check now.")
    }

    /// What an empty smart view says — the Mac's sentences, minus the keyboard shortcuts.
    private var emptyMessage: String {
        switch model.smartView {
        case .needsMyReview:
            return String(localized: "No one is waiting on you. New review requests land here automatically.")
        case .myPullRequests:
            return String(localized: "You have no open pull requests.")
        case .involved:
            return String(localized: "Nothing synced yet. Pull down to sync now.")
        case .watched:
            return String(localized: "Pull requests in the repositories you watch, that nobody asked you about, appear here.")
        case .approvedByMe:
            return String(localized: "Nothing you reviewed is still open.")
        }
    }

    // MARK: - Smart views

    /// The rail's smart views as one row of pills, scrolling with the list.
    private var smartViewPills: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(SmartView.allCases) { view in
                        SmartViewPill(
                            view: view,
                            count: model.count(for: view),
                            isSelected: model.smartView == view
                        ) {
                            model.smartView = view
                        }
                        .id(view)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                // Capped: the large title above already names the selected view, and a pill wider
                // than the screen is a scroller with one visible stop.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .scrollIndicators(.hidden)
            // The selected pill is kept in view — "Watched" and "Approved by me" start off screen.
            .onAppear { proxy.scrollTo(model.smartView, anchor: .center) }
            .onChange(of: model.smartView) { _, view in
                withAnimation(.snappy) { proxy.scrollTo(view, anchor: .center) }
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: onOpenSettings) {
                AvatarView(
                    login: model.session.account.login,
                    url: model.session.account.avatarURL,
                    size: 32
                )
            }
            .accessibilityLabel(Text(String(localized: "Settings")))
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .topBarTrailing) {
            filterMenu
        }
    }

    /// The rail's facets and the list's grouping and order, as one menu.
    private var filterMenu: some View {
        Menu {
            Picker(selection: binding(\.groupBy)) {
                Text(String(localized: "Agent")).tag(InboxFacet.provenance)
                Text(String(localized: "Repository")).tag(InboxFacet.repository)
                Text(String(localized: "Review state")).tag(InboxFacet.reviewState)
            } label: {
                Label(String(localized: "Group"), systemImage: "square.grid.2x2")
            }
            .pickerStyle(.menu)

            Picker(selection: binding(\.sortOrder)) {
                ForEach(InboxSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            } label: {
                Label(String(localized: "Sort"), systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)

            Section {
                Picker(selection: Binding(
                    get: { model.provenanceFilter },
                    set: { model.provenanceFilter = $0 }
                )) {
                    Text(String(localized: "Everyone")).tag(ProvenanceFilter?.none)
                    ForEach(model.provenanceFacets, id: \.filter) { facet in
                        Text(verbatim: "\(facet.title) · \(facet.count)").tag(Optional(facet.filter))
                    }
                } label: {
                    Label(String(localized: "Author"), systemImage: "person.crop.circle")
                }
                .pickerStyle(.menu)

                Picker(selection: Binding(
                    get: { model.repoFilter },
                    set: { model.repoFilter = $0 }
                )) {
                    Text(String(localized: "All repositories")).tag(RepoRef?.none)
                    ForEach(model.repositoryFacets, id: \.repo) { facet in
                        Text(verbatim: "\(facet.repo.fullName) · \(facet.count)").tag(Optional(facet.repo))
                    }
                } label: {
                    Label(String(localized: "Repository"), systemImage: "folder")
                }
                .pickerStyle(.menu)

                Picker(selection: Binding(
                    get: { model.laneFilter },
                    set: { model.laneFilter = $0 }
                )) {
                    Text(String(localized: "Both lanes")).tag(TrustLane?.none)
                    ForEach(model.laneFacets) { facet in
                        Text(verbatim: "\(facet.lane.facetTitle) · \(facet.count)").tag(Optional(facet.lane))
                    }
                } label: {
                    Label(String(localized: "Lane"), systemImage: "road.lanes")
                }
                .pickerStyle(.menu)
            }

            if model.hasActiveFilter {
                Button(role: .destructive) {
                    model.clearFilter()
                } label: {
                    Label(String(localized: "Clear filter"), systemImage: "xmark.circle")
                }
            }
        } label: {
            Label(
                String(localized: "Filter"),
                systemImage: model.hasActiveFilter
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease"
            )
        }
        .accessibilityValue(model.hasActiveFilter ? String(localized: "Filter on") : "")
    }

    /// A binding to one of the list's settings.
    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0 }
        )
    }

    // MARK: - Row actions

    @ViewBuilder
    private func rowMenu(for row: PullRequestSummary) -> some View {
        Button {
            environment.router.path.append(.pullRequest(id: row.id))
        } label: {
            Label(String(localized: "Open review"), systemImage: "arrow.up.forward.square")
        }
        Button {
            approve(row)
        } label: {
            Label(String(localized: "Approve"), systemImage: "checkmark")
        }
        .disabled(row.verdictBlocker != nil)
        Divider()
        PullRequestMoreMenuItems(summary: row, actions: actions, onClose: { closeTarget = row })
        Divider()
        ShareLink(item: url(of: row)) {
            Label(String(localized: "Share…"), systemImage: "square.and.arrow.up")
        }
        Button {
            PlatformServices.copyToPasteboard(url(of: row).absoluteString)
            environment.toasts.info(String(localized: "Link copied"))
        } label: {
            Label(String(localized: "Copy link"), systemImage: "link")
        }
        Button {
            hide(row)
        } label: {
            Label(String(localized: "Hide this pull request"), systemImage: "eye.slash")
        }
    }

    /// Approves from the list — the Mac inbox panel's Approve, through the same path, so an
    /// existing draft's inline comments go with it and GitHub's refusals are refused here first.
    private func approve(_ row: PullRequestSummary) {
        Task {
            if await actions.submitReview(on: row, verdict: .approve) {
                approvalCount += 1
            }
        }
    }

    /// Puts one pull request away, with the Mac's undo toast instead of a confirmation.
    private func hide(_ row: PullRequestSummary) {
        let id = row.id
        model.ignore(row)
        environment.toasts.show(
            Toast(
                message: String(localized: "\(row.slug) hidden. A review request brings it back."),
                actionTitle: String(localized: "Undo"),
                action: { model.stopIgnoring(id: id) }
            )
        )
    }

    /// Runs a sweep and waits for it, so the spinner stops when the list is current.
    ///
    /// The success haptic only when new rows arrived: a refresh that changed nothing should feel
    /// like nothing happened.
    private func refresh() async {
        let before = Set(model.allRows.map(\.id))
        do {
            try await model.session.syncNow(awaitingInFlight: true)
        } catch {
            environment.toasts.failure(error, context: String(localized: "Sync failed"))
            return
        }
        // ponytail: compares right after the sweep returns; rows the database observation
        // delivers a hop later miss the haptic. Watch `allRows` during the refresh if that matters.
        if !Set(model.allRows.map(\.id)).isSubset(of: before) {
            arrivalCount += 1
        }
    }

    // MARK: - Helpers

    private var actions: PullRequestActions {
        environment.actions(for: model.session)
    }

    private func writeState(for row: PullRequestSummary) -> RowWriteState? {
        RowWriteState.make(
            items: model.outboxItems,
            for: row.id,
            isMerging: environment.activity.isRunning(row.id, .merge),
            wasMerged: model.session.mergedPullRequestIDs.contains(row.id)
        )
    }

    private func url(of row: PullRequestSummary) -> URL {
        AppConfig.pullRequestURL(owner: row.repo.owner, name: row.repo.name, number: row.number)
    }

    /// Whether the list is empty because Shepherd has not finished asking GitHub yet — the Mac
    /// list's test, on every row rather than the visible ones, so a filter that hides everything
    /// still says so instead of claiming the sync is running.
    private var isAwaitingFirstSweep: Bool {
        model.allRows.isEmpty && !model.session.hasCompletedFirstSweep
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Every row the search words match, across all smart views and facets, newest first.
    ///
    /// Words, not ranking: each typed word has to appear in the title, `owner/name#number`, the
    /// author's login, the branch or a label. The Mac's ranked search reads an index the phone
    /// does not build (ADR 0044).
    private var searchResults: [PullRequestSummary] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return model.allRows
            .filter { row in
                let haystack = ([row.slug, row.title, row.author.login, row.headRefName] + row.labels)
                    .joined(separator: " ")
                return words.allSatisfy { haystack.localizedStandardContains($0) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// One smart view as a pill: its symbol, its name and its count.
private struct SmartViewPill: View {
    let view: SmartView
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: view.systemImage)
                    .imageScale(.small)
                Text(view.title)
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .font(Theme.type(.subheadline, weight: .medium))
            .foregroundStyle(isSelected ? Theme.textOnFilled : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.accent : Theme.control, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(view.title), \(String(localized: "\(count) pull requests"))"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The sweep's last failure, inline at the top of the list.
///
/// Opaque, on the raised surface, rather than glass: it is content about the list, not a control
/// floating over it (ADR 0040).
private struct PhoneSyncErrorStrip: View {
    let message: String
    let lastSyncedAt: Date?
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.pending)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Couldn't reach GitHub"))
                    .font(Theme.type(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                Text(message)
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.textSecondary)
                if let lastSyncedAt {
                    HStack(spacing: 4) {
                        Text(String(localized: "Last synced"))
                        RelativeDateText(date: lastSyncedAt)
                    }
                    .font(Theme.type(.footnote))
                    .foregroundStyle(Theme.textMuted)
                }
            }
            Spacer(minLength: 0)
            Button(String(localized: "Retry"), action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The inbox actually being empty — the phone twin of the Mac's `InboxZeroView`.
///
/// The same quiet reward: a sealed check in the success colour, the headline, a useful second
/// line, and a quarter-second entrance that is off under Reduce Motion (ADR 0033).
private struct PhoneInboxZeroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: String
    @State private var hasEntered = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(Theme.type(.largeTitle, weight: .light))
                .foregroundStyle(Theme.success)
                .accessibilityHidden(true)
            Text(String(localized: "You are caught up."))
                .font(Theme.type(.title3, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text(message)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .opacity(hasEntered ? 1 : 0)
        .scaleEffect(hasEntered ? 1 : 0.96)
        .onAppear {
            guard !reduceMotion else {
                hasEntered = true
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { hasEntered = true }
        }
        .accessibilityElement(children: .combine)
    }
}
