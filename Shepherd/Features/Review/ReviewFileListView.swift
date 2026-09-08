import ShepherdCore
import SwiftUI

/// The left column of the review screen: files grouped by priority bucket.
struct ReviewFileListView: View {
    /// The review model.
    let model: ReviewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.visiblePriorities.isEmpty {
                EmptyStateView(
                    systemImage: "doc.on.doc",
                    title: model.roundView == .sinceReview
                        ? String(localized: "Nothing new")
                        : String(localized: "No files yet"),
                    message: emptyMessage
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.buckets, id: \.bucket) { group in
                            bucketHeader(group.bucket, count: group.files.count)
                            ForEach(group.files) { priority in
                                fileRow(priority)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            focusHintFooter
        }
        .background(Theme.panel)
    }

    private var emptyMessage: String {
        if model.roundView == .sinceReview {
            return String(localized: "No file changed since the head you reviewed.")
        }
        return model.isRefreshing
            ? String(localized: "Fetching the diff…")
            : String(localized: "This pull request has no changed files.")
    }

    private func bucketHeader(_ bucket: PriorityBucket, count: Int) -> some View {
        Text("\(bucket.localizedTitle.uppercased()) · \(count)")
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.7)
            .foregroundStyle(bucket.tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)
    }

    private func fileRow(_ priority: FilePriority) -> some View {
        let isSelected = model.selectedPath == priority.file.path
        let isViewed = model.viewedPaths.contains(priority.file.path)
        return Button {
            model.selectedPath = priority.file.path
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isViewed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.success)
                            .frame(width: 12)
                    } else {
                        Color.clear.frame(width: 12, height: 1)
                    }
                    Text(priority.file.fileName)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(rowColor(isSelected: isSelected, isViewed: isViewed))
                        .strikethrough(isViewed, color: Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DiffCountsView(
                        additions: priority.file.additions,
                        deletions: priority.file.deletions,
                        size: 10.5
                    )
                }
                if !priority.reasons.isEmpty, !isViewed {
                    HStack(spacing: 4) {
                        ForEach(priority.reasons.prefix(2), id: \.self) { reason in
                            ChipView(text: reason, color: priority.bucket.tint, size: 10)
                        }
                    }
                    .padding(.leading, 18)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isSelected ? Theme.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(Theme.accent).frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help(priority.file.path)
    }

    @ViewBuilder
    private var focusHintFooter: some View {
        if let hint = firstHint {
            VStack(alignment: .leading, spacing: 4) {
                (
                    Text(String(localized: "Focus hint: "))
                        .foregroundStyle(Theme.accentText)
                        .fontWeight(.semibold)
                    + Text(hint.reason)
                        .foregroundStyle(Theme.textSecondary)
                )
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
                Text(hint.file)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.accent.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.accent.opacity(0.22), lineWidth: 1)
            )
            .padding(14)
        }
    }

    private var firstHint: FocusHint? {
        model.focusOutcome.output?.value.first
    }

    private func rowColor(isSelected: Bool, isViewed: Bool) -> Color {
        if isViewed { return Theme.textMuted }
        return isSelected ? Theme.textStrong : Theme.text
    }
}

/// The bar above the diff: path, status chip, layout toggle, "mark viewed".
struct ReviewFileHeader: View {
    /// The review model.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions

    var body: some View {
        HStack(spacing: 10) {
            Picker(String(localized: "Tab"), selection: tabBinding) {
                ForEach(ReviewModel.Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            // Offered only when there is a stored baseline *and* the head has moved past it,
            // so a first review looks exactly as it always has (ADR 0028).
            if model.tab == .files, model.isSinceReviewOffered {
                Picker(String(localized: "Round"), selection: roundBinding) {
                    ForEach(RoundView.allCases) { round in
                        Text(round.title).tag(round)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 214)
                .help(
                    String(localized: "Show only the files and hunks that changed since the head you reviewed")
                )
            }

            if model.tab == .files, let file = model.selectedFile {
                Text(file.path)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                ChipView(text: statusText(file.status), color: statusColor(file.status), size: 10.5)
            }

            Spacer(minLength: 8)

            if model.tab == .files {
                Picker(String(localized: "Layout"), selection: layoutBinding) {
                    Text(String(localized: "Side by side")).tag(false)
                    Text(String(localized: "Inline")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)

                if let file = model.selectedFile {
                    let isWriting = actions.activity.isRunning(model.prID, .viewed)
                    Button {
                        Task { await model.toggleViewed(path: file.path, actions: actions) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: model.viewedPaths.contains(file.path)
                                ? "eye.fill" : "eye")
                            Text(model.viewedPaths.contains(file.path)
                                ? String(localized: "Viewed")
                                : String(localized: "Mark viewed"))
                        }
                        .font(.system(size: 11.5))
                        // Spelled out here rather than left to ``View/busy(_:)``: this is the one
                        // write button in the app on `.plain` rather than on one of the three
                        // styles, and the styles are where that modifier's spinner lives.
                        .opacity(isWriting ? 0 : 1)
                        .overlay { if isWriting { ProgressView().controlSize(.small) } }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        model.viewedPaths.contains(file.path) ? Theme.success : Theme.textSecondary
                    )
                    // `v` does not come through this button — it is a character the screen
                    // handles (``ReviewScreen``) — so the key is refused by the funnel rather
                    // than by the disable. This is here so the click and `v` show one state.
                    .busy(isWriting)
                    .help(String(localized: "Toggle viewed (v)"))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Theme.panel)
    }

    private var tabBinding: Binding<ReviewModel.Tab> {
        Binding(get: { model.tab }, set: { model.setTab($0) })
    }

    private var roundBinding: Binding<RoundView> {
        Binding(get: { model.roundView }, set: { model.setRoundView($0) })
    }

    private var layoutBinding: Binding<Bool> {
        Binding(
            get: { model.settings.diffUsesInlineMode },
            set: { model.settings.diffUsesInlineMode = $0 }
        )
    }

    private func statusText(_ status: FileChangeStatus) -> String {
        switch status {
        case .added: return String(localized: "new")
        case .modified: return String(localized: "modified")
        case .removed: return String(localized: "deleted")
        case .renamed: return String(localized: "renamed")
        }
    }

    private func statusColor(_ status: FileChangeStatus) -> Color {
        switch status {
        case .added: return Theme.success
        case .modified: return Theme.accentText
        case .removed: return Theme.failure
        case .renamed: return Theme.pending
        }
    }
}
