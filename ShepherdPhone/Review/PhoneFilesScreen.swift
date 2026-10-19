import ShepherdCore
import SwiftUI
import UIKit

/// The pull request's Files tab on the iPhone: the changed files in the Mac's priority buckets,
/// how many of them are viewed, and a way into each file's diff (ADR 0044).
///
/// Everything it shows is a reading of the Mac's `ReviewModel` — the buckets and their order
/// (``ReviewModel/buckets``), the viewed set, the "Since your review" round and its findings, and
/// the same empty-state order as the Mac's file list (`ReviewFileListView.emptyState`) — so a
/// reviewer sees the same queue on both devices. Only the layout is the phone's own: a grouped
/// list, one row per file with its name over its folder, chips that wrap rather than truncate,
/// and Viewed on a swipe and on the leading check.
///
/// Tapping a file pushes ``PhoneDiffView`` through a destination this screen registers itself.
/// The screen is itself the pull request screen's pushed destination (`PhoneFilesDestination`),
/// not a value on the router's path: that path is `[PhoneRoute]` and cannot carry a file, and the
/// diff has to share this pull request's ``ReviewModel``. A push that starts somewhere else — the
/// conversation's "Show in diff" — pushes `PhoneDiffView(model:path:revealing:)` itself.
struct PhoneFilesScreen: View {
    /// The review model of the pull request on screen.
    let model: ReviewModel

    @Environment(PhoneEnvironment.self) private var environment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    /// The file whose diff is pushed.
    @State private var openedPath: String?
    /// The line to scroll the pushed diff to: a finding's, or `nil` for a file opened from its row.
    @State private var openedLine: Int?
    /// Bumped by every Viewed toggle on this screen, for the haptic — a tap rather than the
    /// viewed set, which also changes when it loads and when the diff above toggles it.
    @State private var viewedToggles = 0
    /// Whether the Generated bucket is open. It starts closed: lockfiles and snapshots are the
    /// part of a pull request nobody reads line by line.
    @State private var showsGenerated = false

    /// The chips' and counts' sizes, scaled with the text but capped where the rows are
    /// (`accessibility3`): a `@ScaledMetric` here would be resolved outside that cap and grow on.
    private var chipSize: CGFloat { dynamicTypeSize.scaled(12, relativeTo: .caption1, upTo: .accessibility3) }
    private var countSize: CGFloat { dynamicTypeSize.scaled(13, relativeTo: .footnote, upTo: .accessibility3) }

    var body: some View {
        Group {
            if model.visiblePriorities.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Theme.background)
        .navigationTitle(String(localized: "Files"))
        // How far through the files, under the title — where a row of its own above the list
        // cost a band of blank space and a third left edge.
        .navigationSubtitle(model.visiblePriorities.isEmpty ? "" : progressText)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedPath) { path in
            PhoneDiffView(model: model, path: path, revealing: openedLine)
        }
        .sensoryFeedback(.selection, trigger: viewedToggles)
    }

    // MARK: - List

    private var list: some View {
        List {
            if model.isSinceReviewOffered {
                Section {
                    Picker(String(localized: "Round"), selection: roundBinding) {
                        ForEach(RoundView.allCases) { round in
                            Text(round.title).tag(round)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            if model.isSinceReviewOffered, !model.findings.isEmpty {
                findingsSection
            }
            ForEach(model.buckets, id: \.bucket) { group in
                Section {
                    if group.bucket != .generated || showsGenerated {
                        ForEach(group.files) { priority in
                            fileRow(priority)
                        }
                    }
                } header: {
                    bucketHeader(group.bucket, count: group.files.count)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(.compact)
        .contentMargins(.top, 4, for: .scrollContent)
    }

    /// "4 of 12 viewed", or "All 12 viewed" once there is nothing left.
    private var progressText: String {
        let total = model.visiblePriorities.count
        let viewed = model.visiblePriorities.filter { model.viewedPaths.contains($0.file.path) }.count
        return viewed == total
            ? String(localized: "All \(total) viewed")
            : String(localized: "\(viewed) of \(total) viewed")
    }

    private func bucketHeader(_ bucket: PriorityBucket, count: Int) -> some View {
        // The bucket is named as well as tinted (ADR 0033): colour is never the only carrier.
        // No-break spaces, so the count never wraps onto a line of its own.
        let title = Text(verbatim: "\(bucket.localizedTitle.uppercased())\u{00A0}·\u{00A0}\(count)")
            .font(Theme.type(.footnote, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(bucket == .generated ? Theme.textMuted : bucket.tint)
        return Group {
            if bucket == .generated {
                Button {
                    withAnimation(.snappy) { showsGenerated.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        title
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(Theme.type(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .rotationEffect(.degrees(showsGenerated ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(showsGenerated ? String(localized: "Expanded") : String(localized: "Collapsed")))
            } else {
                title
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Findings

    /// What the reviewer said last round and what became of it (ADR 0028), as list rows rather
    /// than the Mac's fixed-height strip.
    private var findingsSection: some View {
        Section {
            ForEach(model.findings) { finding in
                Button {
                    model.jump(to: finding)
                    // `jump` selects the file and the line when the anchor still exists, and
                    // sends a lost anchor to the conversation instead — only the first is a diff.
                    // The conversation is the pull request screen under this one, which shows
                    // the thread `jump` opened (`activeThreadID`), so going back is the jump.
                    if model.tab == .files, let path = finding.path, model.selectedPath == path {
                        openedLine = finding.line
                        openedPath = path
                    } else if model.tab == .conversation {
                        dismiss()
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: finding.state.systemImage)
                            .foregroundStyle(finding.state.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.excerpt)
                                .font(Theme.type(.subheadline))
                                .foregroundStyle(Theme.text)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(finding.state.localizedTitle)
                                    .font(Theme.type(.caption, weight: .semibold))
                                    .foregroundStyle(finding.state.tint)
                                if let path = finding.path {
                                    Text(verbatim: finding.line.map { "\(Self.fileName(path)):\($0)" } ?? Self.fileName(path))
                                        .font(Theme.mono(.caption))
                                        .foregroundStyle(Theme.textMuted)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.panel)
            }
        } header: {
            Text(String(localized: "Your findings").uppercased())
                .font(Theme.type(.footnote, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: - Rows

    private func fileRow(_ priority: FilePriority) -> some View {
        let file = priority.file
        let isViewed = model.viewedPaths.contains(file.path)
        let comments = commentCount(for: file.path)
        return Button {
            model.selectedPath = file.path
            openedLine = nil
            openedPath = file.path
        } label: {
            HStack(alignment: .top, spacing: 4) {
                viewedToggle(path: file.path, isViewed: isViewed)
                    // Pulled up and in, so the larger tap area keeps the check beside the name.
                    .padding(.top, -8)
                    .padding(.leading, -8)
                VStack(alignment: .leading, spacing: 4) {
                    // The counts sit beside the name while there is room and drop under it at
                    // the accessibility sizes, where beside it they would squeeze the name to a
                    // few letters.
                    let nameLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                    nameLayout {
                        Text(verbatim: Self.breakable(file.fileName))
                            .font(Theme.type(.body, weight: .medium))
                            .foregroundStyle(isViewed ? Theme.textMuted : Theme.textStrong)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        DiffCountsView(additions: file.additions, deletions: file.deletions, size: countSize)
                            .fixedSize()
                    }
                    if let directory = Self.directory(of: file.path) {
                        Text(verbatim: directory)
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    chips(for: priority, comments: comments)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .listRowBackground(Theme.panel)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                toggleViewed(file.path)
            } label: {
                Label(
                    isViewed ? String(localized: "Mark unviewed") : String(localized: "Mark viewed"),
                    systemImage: isViewed ? "eye.slash" : "eye"
                )
            }
            .tint(isViewed ? Theme.textSecondary : Theme.accent)
        }
        .contextMenu {
            Button {
                toggleViewed(file.path)
            } label: {
                Label(
                    isViewed ? String(localized: "Mark unviewed") : String(localized: "Mark viewed"),
                    systemImage: isViewed ? "eye.slash" : "eye"
                )
            }
            Button {
                PlatformServices.copyToPasteboard(file.path)
            } label: {
                Label(String(localized: "Copy path"), systemImage: "doc.on.doc")
            }
        }
        // One element per file, saying every fact the row draws (ADR 0033).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenRow(priority, isViewed: isViewed, comments: comments)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(isViewed ? String(localized: "Mark unviewed") : String(localized: "Mark viewed"))) {
            toggleViewed(file.path)
        }
    }

    /// The leading check: tap to mark the file viewed without opening it.
    private func viewedToggle(path: String, isViewed: Bool) -> some View {
        Button {
            toggleViewed(path)
        } label: {
            Image(systemName: isViewed ? "checkmark.circle.fill" : "circle")
                .font(Theme.type(.title3))
                .foregroundStyle(isViewed ? Theme.success : Theme.controlBorder)
                .contentTransition(.symbolEffect(.replace))
                // The minimum touch target; the symbol stays its size, its tap area does not.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(environment.activity.isRunning(model.prID, .viewed))
    }

    /// The change kind, the first two prioritiser reasons and the comment count, wrapping onto a
    /// second line rather than truncating a reason into nonsense.
    private func chips(for priority: FilePriority, comments: Int) -> some View {
        let isViewed = model.viewedPaths.contains(priority.file.path)
        return PhoneChipFlow {
            PhoneChip(
                text: PhoneFilesScreen.statusText(priority.file.status),
                color: PhoneFilesScreen.statusColor(priority.file.status),
                size: chipSize
            )
            if !isViewed {
                ForEach(priority.reasons.prefix(2), id: \.self) { reason in
                    PhoneChip(text: reason.localizedText(), color: priority.bucket.tint, size: chipSize)
                }
            }
            if comments > 0 {
                PhoneChip(text: "\(comments)", systemImage: "bubble.left.fill", color: Theme.accentText, size: chipSize)
            }
        }
    }

    // MARK: - Empty states

    /// The Mac file list's order (`ReviewFileListView.emptyState`): a failed load, files GitHub
    /// claimed but did not send, nothing new since the reviewed head, then nothing at all.
    @ViewBuilder
    private var emptyState: some View {
        if let error = model.detailLoadErrorCard {
            ContentUnavailableView {
                Label(String(localized: "Could not load this pull request"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(String(localized: "Try again")) { model.load() }
                    .buttonStyle(.glassProminent)
            }
        } else if let card = model.filesNotArrivedCard {
            ContentUnavailableView(card.title, systemImage: card.systemImage, description: Text(card.message))
        } else if model.roundView == .sinceReview {
            ContentUnavailableView {
                Label(String(localized: "Nothing new"), systemImage: "checkmark.circle")
            } description: {
                Text(String(localized: "No file changed since the head you reviewed."))
            } actions: {
                Button(RoundView.all.title) { model.setRoundView(.all) }
            }
        } else if model.isRefreshing || model.detail == nil {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text(String(localized: "Fetching the diff…"))
            }
        } else {
            ContentUnavailableView(
                String(localized: "No files yet"),
                systemImage: "doc.on.doc",
                description: Text(String(localized: "This pull request has no changed files."))
            )
        }
    }

    // MARK: - Facts

    private var roundBinding: Binding<RoundView> {
        Binding(get: { model.roundView }, set: { model.setRoundView($0) })
    }

    private func toggleViewed(_ path: String) {
        let actions = environment.actions(for: model.session)
        viewedToggles += 1
        Task { await model.toggleViewed(path: path, actions: actions) }
    }

    /// Published threads still anchored in the diff, plus the reviewer's own pending comments.
    private func commentCount(for path: String) -> Int {
        let threads = model.detail?.threads.filter { $0.path == path && $0.isAnchoredInCurrentDiff }.count ?? 0
        let drafts = model.draft?.comments.filter { $0.path == path }.count ?? 0
        return threads + drafts
    }

    private func spokenRow(_ priority: FilePriority, isViewed: Bool, comments: Int) -> String {
        let file = priority.file
        return SpokenRow.sentence([
            file.fileName,
            Self.directory(of: file.path),
            Self.statusText(file.status),
            isViewed ? nil : priority.reasons.prefix(2).map { $0.localizedText() }.joined(separator: ", "),
            DiffCountsView.spokenCounts(additions: file.additions, deletions: file.deletions),
            comments > 0 ? String(localized: "\(comments) comments") : nil,
            isViewed ? String(localized: "Viewed") : nil,
        ])
    }

    /// A file name with places a line may break: before a capital that follows a small letter and
    /// before every dot, as zero-width spaces. Without them a long name wrapped at the largest
    /// text sizes was hyphenated mid-word ("SignedInSes-sion.swift"), with a hyphen the name does
    /// not have. VoiceOver reads the row's own label, which keeps the name as it is.
    static func breakable(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for character in name {
            if let previous, character == "." || (character.isUppercase && previous.isLowercase) {
                result.append("\u{200B}")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    /// The last path component.
    static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Everything before the last path component, or `nil` at the repository root.
    static func directory(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }

    /// The change kind in the Mac file header's words (`ReviewFileHeader.statusText`), so the
    /// catalog's German rows apply.
    static func statusText(_ status: FileChangeStatus) -> String {
        switch status {
        case .added: return String(localized: "new")
        case .modified: return String(localized: "modified")
        case .removed: return String(localized: "deleted")
        case .renamed: return String(localized: "renamed")
        }
    }

    /// The change kind's colour, the Mac file header's (`ReviewFileHeader.statusColor`).
    static func statusColor(_ status: FileChangeStatus) -> Color {
        switch status {
        case .added: return Theme.success
        case .modified: return Theme.accentText
        case .removed: return Theme.failure
        case .renamed: return Theme.pending
        }
    }
}

/// A rounded pill on the type scale: the Mac's `ChipView`, with a size the caller scales.
///
/// `ChipView` takes its size in points and is drawn with `.system(size:)`, which is right for the
/// Mac's dense rows and wrong under Dynamic Type; this passes a `@ScaledMetric` through instead,
/// so a chip grows with the text around it.
struct PhoneChip: View {
    /// The text.
    let text: String
    /// An optional glyph before the text.
    var systemImage: String?
    /// The foreground colour; the background is the same colour at 13 %.
    var color: Color = Theme.accentText
    /// The point size, already scaled by the caller, or `nil` for `.caption`'s 12 points scaled
    /// here.
    var size: CGFloat?

    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12

    var body: some View {
        let size = size ?? captionSize
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(verbatim: text)
        }
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        // A capsule while the chip is one line; a rounded rectangle, not a tall stadium, when a
        // long reason wraps at the accessibility sizes (``PhoneChipFlow`` proposes the row's width).
        .background(Theme.chipBackground(color), in: RoundedRectangle(cornerRadius: size * 0.75, style: .continuous))
    }
}

extension DynamicTypeSize {
    /// `value` scaled for `style` as `@ScaledMetric(relativeTo:)` scales it, but no further than
    /// `cap` — for a size handed to a view that sits under a `.dynamicTypeSize(...cap)`, which a
    /// metric declared above that cap does not see.
    func scaled(_ value: CGFloat, relativeTo style: UIFont.TextStyle, upTo cap: DynamicTypeSize) -> CGFloat {
        let category = UIContentSizeCategory(Swift.min(self, cap))
        return UIFontMetrics(forTextStyle: style)
            .scaledValue(for: value, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }
}

/// Lays chips out left to right and wraps to a new line when the next one does not fit.
struct PhoneChipFlow: Layout {
    /// The gap between chips, in both directions.
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(Self.proposal(width: bounds.width))
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
                )
                x += min(size.width, bounds.width) + spacing
            }
        }
    }

    /// At most the row's width, so a chip longer than the row wraps its text onto a second line
    /// instead of being cut to fit.
    private static func proposal(width: CGFloat) -> ProposedViewSize {
        ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(Self.proposal(width: width))
            let chipWidth = min(size.width, width)
            if !current.indices.isEmpty, current.width + spacing + chipWidth > width {
                let y = current.y + current.height + spacing
                rows.append(current)
                current = Row(y: y)
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + chipWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
