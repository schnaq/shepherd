import AppKit
import ShepherdCore
import SwiftUI

/// The delegation sheet: write the task, watch the agent work, decide what happens to the diff.
struct DelegationSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings

    /// The delegation.
    let model: DelegationModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            content
            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 720, height: 620)
        .background(Theme.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.context.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(model.context.slug)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                    ChipView(text: model.context.headRefName, color: Theme.accentText, size: 10.5)
                    ChipView(text: model.agentName, color: Theme.agent, size: 10.5)
                    if model.isAutomatic {
                        // A run nobody pressed a button for has to say so wherever it shows up
                        // (ADR 0016).
                        ChipView(
                            text: String(localized: "Automatic"),
                            color: Theme.priority,
                            size: 10.5
                        )
                        .help(String(
                            localized: "Started by an automatic delegation rule. Nothing is pushed — you still review and push the diff."
                        ))
                    }
                    if case .reviewFinding(let path, _) = model.context.origin {
                        ChipView(text: path, color: Theme.priority, size: 10.5)
                    }
                }
            }
            Spacer(minLength: 8)
            Button {
                environment.delegation.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "Close")))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.panel)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch model.readiness {
        case .missingCLI:
            missingCLI
        case .missingCheckout(let repo):
            missingCheckout(repo: repo)
        case .ready:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    promptCard
                    guardrailRow
                    if !model.transcript.isEmpty {
                        transcriptCard
                    }
                    resultCard
                }
                .padding(18)
            }
            .background(Theme.background)
        }
    }

    private var promptCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "TASK FOR THE AGENT"))
                TextEditor(text: taskBinding)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 120, maxHeight: 190)
                    .background(
                        Theme.control,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .disabled(model.isBusy)
                    .opacity(model.isBusy ? 0.6 : 1)
                Text(String(
                    localized: "Shepherd prepends its own instructions: the agent is told it works in a detached worktree, must not push, and should keep the change minimal."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var guardrailRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Text(model.guardrailSummary)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
            Text("· \(model.configuration.allowedTools)")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Change the guardrails in Settings → Delegation"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var transcriptCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    CardTitle(String(localized: "TRANSCRIPT"))
                    Spacer(minLength: 4)
                    if case .running = model.state {
                        ProgressView().controlSize(.small)
                        Text(model.elapsedText)
                            .font(Theme.mono(11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.transcript) { entry in
                                transcriptRow(entry).id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 210)
                    .onChange(of: model.transcript.count) { _, _ in
                        guard let last = model.transcript.last else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ entry: DelegationModel.TranscriptEntry) -> some View {
        switch entry.kind {
        case .note:
            Text(entry.text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        case .assistant:
            Text(entry.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .tool:
            HStack(spacing: 5) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 9))
                Text(entry.text)
                    .font(Theme.mono(10.5))
            }
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Theme.chipBackground(Theme.accentText),
                in: Capsule(style: .continuous)
            )
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        switch model.state {
        case .failed(let message):
            Card(tint: Theme.failure.opacity(0.08)) {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(String(localized: "DELEGATION FAILED"), tint: Theme.failure)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .cancelled:
            Card {
                Text(String(localized: "Cancelled. The worktree is still on disk — you can inspect or discard it below."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .finished(let result, let diffStat):
            VStack(alignment: .leading, spacing: 14) {
                resultSummary(result)
                diffStatBlock(diffStat)
            }
        case .idle, .preparingWorktree, .running:
            EmptyView()
        }
    }

    private func resultSummary(_ result: AgentRunResult) -> some View {
        Card(tint: result.isError ? Theme.failure.opacity(0.08) : nil) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: result.isError
                        ? "exclamationmark.triangle"
                        : "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(result.isError ? Theme.failure : Theme.success)
                    Text(result.isError
                        ? String(localized: "The agent stopped with an error")
                        : String(localized: "The agent finished"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                    if let subtype = result.subtype, !subtype.isEmpty {
                        ChipView(
                            text: subtype,
                            color: result.isError ? Theme.failure : Theme.success,
                            size: 10.5
                        )
                    }
                    Spacer(minLength: 4)
                }
                HStack(spacing: 12) {
                    if let cost = result.totalCostUSD {
                        metric(
                            String(localized: "cost"),
                            String(format: "$%.4f", cost)
                        )
                    }
                    if let turns = result.numTurns {
                        metric(String(localized: "turns"), String(turns))
                    }
                    if let duration = result.durationMS {
                        metric(
                            String(localized: "duration"),
                            RelativeDate.duration(Double(duration) / 1_000)
                        )
                    }
                }
                if let text = result.resultText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(Theme.mono(11.5))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder
    private func diffStatBlock(_ diffStat: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "CHANGES IN THE WORKTREE"))
                if diffStat.isEmpty {
                    Text(String(localized: "The agent changed nothing that is tracked by git."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    ScrollView(.horizontal) {
                        Text(diffStat)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxHeight: 150)
                }
                if let status = model.worktreeStatus, status.isDirty {
                    Text(String(localized: "\(status.changedPaths.count) files are uncommitted in the worktree."))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    // MARK: - Empty states

    private var missingCLI: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                systemImage: "terminal",
                title: String(localized: "No agent CLI found"),
                message: AgentCLILocator.installHint
            )
            HStack(spacing: 8) {
                Button(String(localized: "Open Settings → Delegation")) { openSettings() }
                    .buttonStyle(PrimaryButtonStyle())
                if let url = AgentCLILocator.documentationURL {
                    Link(String(localized: "Read the docs"), destination: url)
                        .font(.system(size: 12))
                }
            }
            Text(String(
                localized: "Shepherd runs your own installation and never handles its authentication."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func missingCheckout(repo: String) -> some View {
        VStack(spacing: 14) {
            EmptyStateView(
                systemImage: "folder.badge.questionmark",
                title: String(localized: "No local checkout for \(repo)"),
                message: String(
                    localized: "Delegation runs in a git worktree built from your own clone. Set the local checkout path in Settings → Delegation."
                )
            )
            HStack(spacing: 8) {
                Button(String(localized: "Choose folder…")) { chooseCheckout(repo: repo) }
                    .buttonStyle(PrimaryButtonStyle())
                Button(String(localized: "Open Settings → Delegation")) { openSettings() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let worktree = model.worktree {
                Text(worktree.directory.path)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(worktree.directory.path)
            }
            Spacer(minLength: 8)
            footerActions
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var footerActions: some View {
        switch model.state {
        case .preparingWorktree:
            ProgressView().controlSize(.small)
            Text(String(localized: "Preparing the worktree…"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Button(String(localized: "Cancel")) { model.cancel() }
                .buttonStyle(SecondaryButtonStyle(height: 30))

        case .running:
            Text(model.elapsedText)
                .font(Theme.mono(11.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
            Button(String(localized: "Cancel")) { model.cancel() }
                .buttonStyle(SecondaryButtonStyle(height: 30, tint: Theme.failure))

        case .finished, .cancelled:
            Button(String(localized: "Reveal in Finder")) { model.revealWorktreeInFinder() }
                .buttonStyle(SecondaryButtonStyle(height: 30))
            Button(String(localized: "Discard worktree")) { model.discardWorktree() }
                .buttonStyle(SecondaryButtonStyle(height: 30, tint: Theme.failure))
                .disabled(model.isPublishing)
            Button(String(localized: "Run again")) { model.start() }
                .buttonStyle(SecondaryButtonStyle(height: 30))
                .disabled(!model.canStart)
            Button(
                model.hasPushed
                    ? String(localized: "Pushed")
                    : String(localized: "Commit & push to PR branch")
            ) {
                model.commitAndPush()
            }
            .buttonStyle(SuccessButtonStyle(height: 30))
            .disabled(model.isPublishing || model.hasPushed || !model.hasChanges)
            .help(String(localized: "Pushes with your own git credentials to \(model.context.headRefName)"))

        case .failed:
            Button(String(localized: "Reveal in Finder")) { model.revealWorktreeInFinder() }
                .buttonStyle(SecondaryButtonStyle(height: 30))
            Button(String(localized: "Try again")) { model.start() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canStart)

        case .idle:
            Button(String(localized: "Start")) { model.start() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canStart)
        }
    }

    // MARK: - Plumbing

    private var taskBinding: Binding<String> {
        Binding(get: { model.task }, set: { model.task = $0 })
    }

    private func chooseCheckout(repo: String) {
        guard let url = FolderPicker.choose(
            title: String(localized: "Choose the local clone of \(repo)")
        ) else { return }
        environment.settings.setLocalCheckout(url, forRepoNamed: repo)
        // The model was built without a worktree, so it is rebuilt with one; nothing is
        // running (the sheet would not be showing this state otherwise).
        environment.startDelegation(model.context)
    }
}

/// A folder picker used by the delegation settings and the sheet's empty state.
enum FolderPicker {
    /// Asks the user for a directory.
    /// - Parameter title: The panel's message.
    /// - Returns: The chosen directory, or `nil` when the user cancelled.
    @MainActor
    static func choose(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = title
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
