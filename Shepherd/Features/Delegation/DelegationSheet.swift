import AppKit
import ShepherdCore
import SwiftUI

/// The delegation sheet: write the task, watch the agent work, decide what happens to the diff.
struct DelegationSheet: View {
    @Environment(AppEnvironment.self) private var environment

    /// The delegation.
    let model: DelegationModel

    /// The task field's AI-drafting state (plan §3.E, the ADR 0011 amendment).
    ///
    /// The same value the two review composers use, so the rules the reviewer has already learned
    /// there hold here: the replace-or-append question is asked *before* the request, a keystroke
    /// takes the field back, what arrived stays and stays labelled, and every failure is one line
    /// of the tier's own words.
    @State private var briefDraft = AIDraftFieldState()
    /// The task producing the streamed brief, while one runs.
    ///
    /// Held because a stream has three ways to end that are not "the model stopped talking": the
    /// stop button, Escape, and the reviewer typing. All three have to end the *request* as well
    /// as the field's claim on it — cancelling this task cancels the router's relay, which cancels
    /// the provider's own work.
    @State private var briefTask: Task<Void, Never>?

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
        .onChange(of: model.task) { _, text in
            let wasStreaming = briefDraft.streamingDraft != nil
            briefDraft.fieldChanged(to: text)
            // The reviewer's keystroke won the field, so the request has to stop too: snapshots
            // that would be refused anyway are tokens a Mac is still generating.
            if wasStreaming, briefDraft.streamingDraft == nil {
                briefTask?.cancel()
                briefTask = nil
            }
        }
        // The sheet closing is a stop as well. There is no field left to write into, and an
        // on-device session that outlives its window is battery spent on nothing.
        .onDisappear {
            briefTask?.cancel()
            briefTask = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                // A repository task has no title of its own — its "title" is the repository,
                // which the line below already shows — so the header says what the sheet is for.
                Text(model.context.isRepositoryTask
                    ? String(localized: "New agent task")
                    : model.context.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(model.context.slug)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                    if model.branchName.isEmpty {
                        // A repository task's branch is named after the task when the run starts.
                        ChipView(
                            text: String(localized: "new branch"),
                            color: Theme.textMuted,
                            size: 10.5
                        )
                        .help(String(
                            localized: "Shepherd names the branch after the first line of the task when the run starts, and creates it from the tip of the default branch."
                        ))
                    } else {
                        ChipView(text: model.branchName, color: Theme.accentText, size: 10.5)
                    }
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
                HStack(spacing: 8) {
                    CardTitle(String(localized: "TASK FOR THE AGENT"))
                    Spacer(minLength: 4)
                    if model.canDraftBrief {
                        // Absent rather than disabled when no tier could answer: with
                        // intelligence off, this card is exactly the card it was before the
                        // brief existed (ADR 0007: no feature hard-depends on a model).
                        AIDraftButton(
                            isDrafting: briefDraft.isDrafting,
                            isStreaming: briefDraft.streamingDraft != nil
                        ) {
                            toggleBriefDraft()
                        }
                    }
                }
                TextEditor(text: taskBinding)
                    .font(.system(size: 12.5))
                    // The growing brief is drawn in the caption colour, so the reviewer can see
                    // which words are the model's while they are still arriving.
                    .foregroundStyle(briefDraft.streamingDraft == nil ? Theme.text : Theme.accentText)
                    // The instructions handed to the agent are prose the user writes under time
                    // pressure, so proofreading and rewriting belong here too (ADR 0020). Nothing
                    // is sent by Writing Tools; the text still waits for the Run button.
                    .writingToolsBehavior(.complete)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 120, maxHeight: 190)
                    .background(
                        Theme.control,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .disabled(model.isBusy)
                    .opacity(model.isBusy ? 0.6 : 1)
                    // A `TextEditor` has no title to borrow a name from, unlike a `TextField`
                    // with a label, so without this a screen reader announces "text view" and
                    // the reviewer has to infer what they are typing into.
                    .accessibilityLabel(Text(String(localized: "Task for the agent")))
                AIDraftStatusView(
                    state: briefDraft,
                    confirmationTitle: String(localized: "Replace the task for the agent?"),
                    onReplace: { resolveBriefDraft(.replace) },
                    onAppend: { resolveBriefDraft(.append) },
                    onDiscard: { briefDraft.discardPendingDraft() }
                )
                Text(promptFootnote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What Shepherd tells the agent before the task, in one sentence.
    ///
    /// Three answers because there are three preambles (``DelegationPrompt``), and the sentence
    /// has to describe the one that will actually be sent: new work may be committed and
    /// published by the run itself, which "must not push" would misstate.
    private var promptFootnote: String {
        if model.context.isRepositoryTask {
            return String(
                localized: "The first line names the branch. Shepherd prepends its own instructions: the agent works on a new branch from the default branch, may commit and open a pull request with its own credentials, and should keep the change minimal."
            )
        }
        if model.context.isIssue {
            return String(
                localized: "Shepherd prepends its own instructions: the agent works on a new branch from the default branch, may commit and open a pull request with its own credentials, and should keep the change minimal."
            )
        }
        return String(
            localized: "Shepherd prepends its own instructions: the agent is told it works in a detached worktree, must not push, and should keep the change minimal."
        )
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
                environment.showSettings(.delegation)
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
                Button(String(localized: "Open Settings → Delegation")) {
                    environment.showSettings(.delegation)
                }
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
                Button(String(localized: "Open Settings → Delegation")) {
                    environment.showSettings(.delegation)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isWorktreeDirectoryKnown, let worktree = model.worktree {
                Text(worktree.directory.path)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(worktree.directory.path)
            }
            Spacer(minLength: 8)
            if briefDraft.isDrafting {
                // Escape, while text is arriving, means *stop the draft* — not "throw the sheet
                // away". This is the only control carrying `.cancelAction`, and it exists only
                // while there is a draft to stop, so there is nothing ambiguous about where the
                // key goes; everything the brief produced stays in the field.
                Button(String(localized: "Stop drafting")) { stopBriefDraft() }
                    .buttonStyle(SecondaryButtonStyle(height: 30))
                    .keyboardShortcut(.cancelAction)
            }
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
            // Both need a directory: a repository task cancelled before its branch was chosen
            // has none yet.
            Button(String(localized: "Reveal in Finder")) { model.revealWorktreeInFinder() }
                .buttonStyle(SecondaryButtonStyle(height: 30))
                .disabled(!model.isWorktreeDirectoryKnown)
            Button(String(localized: "Discard worktree")) { model.discardWorktree() }
                .buttonStyle(SecondaryButtonStyle(height: 30, tint: Theme.failure))
                .disabled(model.isPublishing || !model.isWorktreeDirectoryKnown)
            Button(String(localized: "Run again")) { model.start() }
                .buttonStyle(SecondaryButtonStyle(height: 30))
                .disabled(!model.canStart)
            Button(
                model.hasPushed
                    ? String(localized: "Pushed")
                    : (model.context.isNewWork
                        // New work has no pull request yet; the branch is Shepherd's.
                        ? String(localized: "Commit & push branch")
                        : String(localized: "Commit & push to PR branch"))
            ) {
                model.commitAndPush()
            }
            .buttonStyle(SuccessButtonStyle(height: 30))
            .disabled(model.isPublishing || model.hasPushed || !model.hasChanges)
            .help(String(localized: "Pushes with your own git credentials to \(model.branchName)"))

        case .failed:
            Button(String(localized: "Reveal in Finder")) { model.revealWorktreeInFinder() }
                .buttonStyle(SecondaryButtonStyle(height: 30))
                .disabled(!model.isWorktreeDirectoryKnown)
            Button(String(localized: "Try again")) { model.start() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canStart)

        case .idle:
            Button(String(localized: "Start")) { model.start() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canStart)
                // The primary action of every other sheet in the app is the default one, and
                // this one was the exception: Return did nothing here and a keyboard-only
                // reviewer had to find the button by tabbing. Return inside the task editor
                // still inserts a line, because a `TextEditor` consumes it first.
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Drafting the task (plan §3.E)

    /// The ✨ button, and ⇧⌘D: start a brief, or stop the one that is running.
    ///
    /// One entry point for both directions so the button and the shortcut cannot disagree about
    /// what they do.
    @MainActor
    private func toggleBriefDraft() {
        if briefDraft.isDrafting {
            stopBriefDraft()
        } else {
            requestBriefDraft()
        }
    }

    /// Asks the intelligence layer for a brief, streamed.
    ///
    /// Its only effect is on the text field. The Run button reads ``DelegationModel/task`` when it
    /// is pressed and nothing else, so a brief that is arriving, stopped, appended or discarded
    /// changes what a run *would* say and never whether one happens (ADR 0011's amendment).
    /// When the field already holds text this only *asks*: the request is made by
    /// ``resolveBriefDraft(_:)`` once the reviewer has said replace or append, so a discarded
    /// question sends nothing to any provider.
    @MainActor
    private func requestBriefDraft() {
        switch briefDraft.prepareStream(existingText: model.task) {
        case .askFirst:
            break
        case .ready(let base):
            briefTask = Task { await runBriefStream(base: base) }
        }
    }

    /// Stops the running draft, keeping every word that arrived.
    ///
    /// The field is settled here rather than in the task, so a stop is *immediate*. Everything it
    /// touches is idempotent, so the task doing the same thing again when it wakes is a no-op.
    @MainActor
    private func stopBriefDraft() {
        briefTask?.cancel()
        briefTask = nil
        // Exactly one of these two does anything: the first before the first token has arrived,
        // the second once text is in the field.
        briefDraft.cancelDrafting()
        applyBriefDraft(briefDraft.cancelStream())
    }

    /// Applies the reviewer's answer to the replace-or-append question.
    @MainActor
    private func resolveBriefDraft(_ choice: AIDraftFieldState.Choice) {
        switch briefDraft.resolve(choice, existingText: model.task) {
        case .write(let text):
            model.task = text
        case .startStream(let base):
            briefTask = Task { await runBriefStream(base: base) }
        case .nothing:
            break
        }
    }

    /// Runs one streamed brief into the task field.
    ///
    /// Every element is the whole brief so far, so each one is simply written; the state decides
    /// whether it may be (it may not, once the reviewer has typed).
    /// - Parameter base: What the brief grows after — empty, or the reviewer's own text plus a
    ///   blank line when they chose *append*.
    @MainActor
    private func runBriefStream(base: String) async {
        let outcome = await model.streamBrief()
        // Stopped while the ladder was still choosing a tier: ``stopBriefDraft()`` has already put
        // the field back, and reporting this outcome would answer a question nobody is asking.
        guard !Task.isCancelled else { return }
        guard let stream = outcome.stream else {
            applyBriefDraft(
                briefDraft.finish(outcome.failure ?? .disabled, existingText: model.task)
            )
            return
        }
        briefDraft.streamStarted(kind: stream.kind, servedBy: stream.servedBy, base: base)
        do {
            for try await partial in stream.text {
                applyBriefDraft(briefDraft.streamed(partial))
            }
            // A cancelled task ends the iteration *without* an error, so a stop has to be
            // recognised here as well, or a stopped stream would file itself as one that ran to
            // completion — which, with nothing arrived, puts a failure line under a field the
            // reviewer just stopped.
            if Task.isCancelled {
                applyBriefDraft(briefDraft.cancelStream())
            } else {
                applyBriefDraft(briefDraft.finishStream())
            }
        } catch is CancellationError {
            applyBriefDraft(briefDraft.cancelStream())
        } catch {
            applyBriefDraft(briefDraft.failStream(AIDraftFailure.describe(error)))
        }
    }

    /// Writes text the drafting state produced into the field, when it produced any.
    @MainActor
    private func applyBriefDraft(_ text: String?) {
        guard let text else { return }
        model.task = text
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
        // The typed task travels into the rebuilt model: a repository task's field starts empty,
        // and whatever the user wrote before noticing the missing clone is theirs.
        environment.startDelegation(model.context, task: model.task)
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
