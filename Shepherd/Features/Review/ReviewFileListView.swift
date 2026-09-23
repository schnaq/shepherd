import ShepherdCore
import SwiftUI

/// The left column of the review screen: files grouped by priority bucket.
struct ReviewFileListView: View {
    /// The review model.
    let model: ReviewModel
    /// "Open in …" on each row's context menu (ADR 0039); `nil` until the summary has loaded.
    var editor: EditorContext?

    var body: some View {
        VStack(spacing: 0) {
            if model.visiblePriorities.isEmpty {
                let state = emptyState
                EmptyStateView(
                    systemImage: state.systemImage,
                    title: state.title,
                    message: state.message
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
        // Not up through the session bar into the toolbar (``View/ownFrameBackground(_:)``).
        .ownFrameBackground(Theme.panel)
    }

    /// What an empty file list means, in the order ``ReviewScreen/diffOrPlaceholder`` uses.
    ///
    /// The three claims the diff area makes about *the diff* — it could not be loaded, GitHub
    /// claims files it did not send, nothing changed since the reviewed head — one line each,
    /// because the two panes are read together: a list saying "This pull request has no changed
    /// files" beside a diff that failed to load is how the live test's empty Monaco went
    /// unexplained. The screen's ``ReviewScreen/missingFromInbox`` state is deliberately *not*
    /// mirrored: it replaces the whole diff area with its own way out, and the file list beside
    /// it says "No files yet", which is true of a pruned pull request.
    ///
    /// The first two lines and the diff area's two cards share one predicate each
    /// (``ReviewModel/detailLoadErrorCard``, ``ReviewModel/filesNotArrivedCard``) rather than
    /// each pane spelling out when a failure is worth showing, which is the part that would
    /// otherwise drift — and the second carries its wording too, so the two panes cannot end up
    /// reporting a different number of missing files.
    private var emptyState: (systemImage: String, title: String, message: String) {
        if let error = model.detailLoadErrorCard {
            return (
                "exclamationmark.triangle",
                String(localized: "Could not load this pull request"),
                error
            )
        }
        if let card = model.filesNotArrivedCard {
            return card
        }
        if model.roundView == .sinceReview {
            return (
                "doc.on.doc",
                String(localized: "Nothing new"),
                String(localized: "No file changed since the head you reviewed.")
            )
        }
        return (
            "doc.on.doc",
            String(localized: "No files yet"),
            model.isRefreshing
                ? String(localized: "Fetching the diff…")
                : String(localized: "This pull request has no changed files.")
        )
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
                        ForEach(displayReasons(for: priority), id: \.self) { reason in
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
        // Not for a deleted file: the head has no such path, so the menu could only ever open
        // the checkout's folder and say the file is missing, which the row already says.
        .openInEditorMenu(
            priority.file.status == .removed ? nil : editor,
            path: priority.file.path,
            line: nil
        )
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

    /// The reason chips shown on a file row: the first two, in the reader's language.
    private func displayReasons(for priority: FilePriority) -> [String] {
        priority.reasons.prefix(2).map { $0.localizedText() }
    }
}

/// The bar above the diff: path, status chip, layout toggle, "mark viewed".
struct ReviewFileHeader: View {
    /// The review model.
    let model: ReviewModel
    /// The write actions.
    let actions: PullRequestActions
    /// "Open in …" for the file on screen (ADR 0039); `nil` until the summary has loaded.
    var editor: EditorContext?
    /// Live, and read for the same reason ``ReviewScreen`` reads it: it is half of what
    /// ``DiffRenderer/automatic`` means, so turning VoiceOver on mid-review has to change this
    /// bar as well as the renderer under it.
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled

    var body: some View {
        HStack(spacing: 10) {
            Picker(String(localized: "Tab"), selection: tabBinding) {
                ForEach(ReviewModel.Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

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
                .fixedSize()
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
                // Side by side is Monaco's. The native list draws one unified column — there is
                // no second pane to put the original in — so in that renderer this control took
                // a click, moved its highlight and changed nothing on screen. It is hidden
                // rather than disabled for the reason the round picker above it is absent when
                // there is no baseline: a segmented control whose segments do the same thing is
                // a dead control, and this bar already appears and disappears around the file.
                if !model.settings.diffRenderer.usesNativeList(
                    voiceOverEnabled: isVoiceOverEnabled
                ) {
                    Picker(String(localized: "Layout"), selection: layoutBinding) {
                        Text(String(localized: "Side by side")).tag(false)
                        Text(String(localized: "Inline")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // `fixedSize` rather than a width in points: a segmented control draws at
                    // its intrinsic width whatever frame it is given, so a frame that is too
                    // small does not clip it — it lets it overflow *over the next control*.
                    // 170 fitted "Side by side | Inline" and not "Nebeneinander | Inline", and
                    // the eye of "Mark viewed" ended up drawn inside the Inline segment.
                    .fixedSize()
                }

                if let file = model.selectedFile, file.status != .removed, let editor {
                    openInEditorButton(file: file, editor: editor)
                }

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
                        // Applied to the label rather than left to ``View/busy(_:)``: this is the
                        // one write button in the app on `.plain` rather than on one of the three
                        // styles, and the styles are where that modifier's spinner lives. The
                        // spinner itself is the shared one, so it matches theirs.
                        .busyLabel(isBusy: isWriting)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        model.viewedPaths.contains(file.path) ? Theme.success : Theme.textSecondary
                    )
                    // `v` does not come through this button — it is a character the screen
                    // handles (``ReviewScreen``) — so the key is refused by the funnel rather
                    // than by the disable. This is here so the click and `v` show one state.
                    .busy(isWriting)
                    .help(String(localized: "Toggle viewed (v) — or accept and go to the next file (a)"))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        // The top of the diff column, directly under the toolbar (``View/ownFrameBackground(_:)``).
        .ownFrameBackground(Theme.panel)
    }

    /// The header's "Open in …": an icon, because the bar already carries a path, a chip and two
    /// segmented controls, with the editor's name in the tooltip and the spoken label. Without a
    /// linked clone it links one first, exactly like the file list's menu item.
    ///
    /// No line: the diff's cursor lives on the far side of the bridge, and this task does not
    /// widen the bridge for it. The claims and CI cards pass the line they name.
    private func openInEditorButton(file: ChangedFile, editor: EditorContext) -> some View {
        let hasCheckout = editor.opener.hasCheckout(for: editor.repo)
        let title = hasCheckout
            ? editor.opener.openTitle
            : String(localized: "Link a Local Checkout…")
        return Button {
            if hasCheckout {
                editor.opener.open(repo: editor.repo, path: file.path, line: nil)
            } else {
                editor.opener.linkCheckoutAndOpen(repo: editor.repo, path: file.path, line: nil)
            }
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .help(hasCheckout ? title + " — " + EditorOpener.openHelp : title)
        .accessibilityLabel(Text(title))
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
