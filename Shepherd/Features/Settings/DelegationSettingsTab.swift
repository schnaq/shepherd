import ShepherdCore
import SwiftUI

/// Settings → Delegation: which agent CLI to run, with which guardrails, against which clones.
///
/// There is no credential field anywhere on this tab, and that is the point: Shepherd invokes
/// the user's own installation and inherits whatever authentication it already has (ADR 0011).
struct DelegationSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var detectState: DetectState = .idle
    @State private var newRepoFullName = ""
    @State private var repoError: String?
    /// What "By name" did when it could only do half: linked, but the watch list was full.
    @State private var repoNotice: String?
    /// The folder "Add a local repository…" is confirming, while its sheet is up.
    ///
    /// This window's own rather than ``AppEnvironment/localRepositoryDraft``: Settings is a
    /// window of its own, and the sheet belongs in front of the window the click came from.
    @State private var localRepositoryDraft: LocalRepositoryDraft?
    /// Which editors this Mac has, read when the tab appears rather than on every redraw.
    @State private var installedEditors: Set<EditorKind> = []
    /// The *Extra arguments* field as typed. Stored only once it splits, so an unclosed quote
    /// mid-typing neither snaps the field back nor saves half an argument.
    @State private var extraArgumentsText = ""
    /// Why the typed extra arguments cannot be split, while they cannot.
    @State private var extraArgumentsError: String?
    /// The spend cap "Cap spend" brings back, so unticking and reticking it keeps the amount.
    @State private var lastBudgetUSD = AgentCLIConfiguration.suggestedMaxBudgetUSD

    /// What the "Detect" button last found.
    private enum DetectState: Equatable {
        case idle
        case searching
        case found(String)
        case notFound
    }

    var body: some View {
        SettingsPage {
            agentSection
            guardrailSection
            sessionSection
            checkoutSection
            addCheckoutSection
            editorSection
            automaticSection
            triggerSection
            taskSection
            capSection
        }
        .sheet(item: $localRepositoryDraft) { draft in
            AddLocalRepositorySheet(
                draft: draft,
                settings: environment.settings,
                toasts: environment.toasts,
                onChooseAnother: { chooseLocalRepository() }
            )
        }
    }

    /// Picks a clone and puts the confirmation up in this window.
    private func chooseLocalRepository() {
        Task { @MainActor in
            localRepositoryDraft = await LocalRepositoryDraft.choose()
        }
    }

    // MARK: - Agent CLI

    /// The CLI, and — as its footer — the promise the whole pane rests on: Shepherd runs the
    /// user's own installation untouched and never pushes.
    private var agentSection: some View {
        Section {
            Picker(String(localized: "Agent"), selection: kindBinding) {
                ForEach(AgentCLIKindTag.allCases) { tag in
                    Text(tag.title).tag(tag)
                }
            }
            .pickerStyle(.segmented)

            switch environment.settings.agentCLI.kind {
            case .claudeCode:
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField(
                            String(localized: "Path"),
                            text: executablePathBinding,
                            prompt: Text(verbatim: "/opt/homebrew/bin/claude")
                        )
                        .labelsHidden()
                        Button(String(localized: "Detect")) { detect() }
                            .disabled(detectState == .searching)
                        InfoButton(String(
                            localized: "Not installed? Run npm install -g @anthropic-ai/claude-code in Terminal."
                        ))
                    }
                } label: {
                    Text(String(localized: "Path"))
                    Text(String(localized: "Leave empty to look in the usual places."))
                }
                detectResult

                LabeledContent {
                    TextField(
                        String(localized: "Model"),
                        text: agentCLIBinding(\.model),
                        prompt: Text(String(localized: "CLI default"))
                    )
                    .labelsHidden()
                } label: {
                    Text(String(localized: "Model"))
                    Text(String(localized: "An alias such as opus, sonnet or haiku, or a full model name."))
                }

                Picker(String(localized: "Effort"), selection: agentCLIBinding(\.effort)) {
                    Text(String(localized: "CLI default")).tag(AgentEffort?.none)
                    ForEach(AgentEffort.allCases) { effort in
                        Text(verbatim: effort.rawValue).tag(Optional(effort))
                    }
                }

            case .custom:
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField(
                            String(localized: "Command"),
                            text: templateBinding,
                            prompt: Text(verbatim: "/usr/local/bin/my-agent --task {prompt}")
                        )
                        .labelsHidden()
                        InfoButton(String(
                            localized: "The template is split like a shell would, but no shell ever runs it: {prompt} always becomes exactly one argument, so a prompt cannot turn into a second command."
                        ))
                    }
                } label: {
                    Text(String(localized: "Command"))
                    Text(String(localized: "{prompt} is the task, {worktree} the path."))
                }
            }

            LabeledContent {
                TextField(
                    String(localized: "Extra arguments"),
                    text: $extraArgumentsText,
                    // No `~`: the words reach the CLI as argv, and no shell expands it.
                    prompt: Text(verbatim: "--add-dir /Users/me/shared")
                )
                .labelsHidden()
                .onChange(of: extraArgumentsText) { _, text in
                    do {
                        // Only a real change is written: `onAppear` filling the field must not
                        // rewrite (and re-sync) the stored settings.
                        let words = try ShellWords.split(text)
                        if words != environment.settings.agentCLI.extraArguments {
                            environment.settings.agentCLI.extraArguments = words
                        }
                        extraArgumentsError = nil
                    } catch {
                        extraArgumentsError = error.userFacingDescription
                    }
                }
            } label: {
                Text(String(localized: "Extra arguments"))
                Text(extraArgumentsError ?? String(localized: "Appended to every run, split like a shell would."))
                    .foregroundStyle(extraArgumentsError == nil ? Color.secondary : Theme.failure)
            }
            .onAppear {
                extraArgumentsText = ShellWords.join(environment.settings.agentCLI.extraArguments)
            }
        } header: {
            Text(String(localized: "Agent CLI"))
        } footer: {
            SettingsNote(String(
                localized: "Shepherd runs your installed CLI with your environment untouched and holds no login for it. It never pushes: you decide what is committed."
            ))
        }
    }

    @ViewBuilder
    private var detectResult: some View {
        switch detectState {
        case .idle:
            EmptyView()
        case .searching:
            ProgressView().controlSize(.small)
        case .found(let path):
            Label(path, systemImage: "checkmark.circle")
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.success)
                .textSelection(.enabled)
        case .notFound:
            Label(
                String(localized: "Not found. Enter the full path to the executable."),
                systemImage: "exclamationmark.triangle"
            )
            .font(Theme.type(.caption))
            .foregroundStyle(Theme.pending)
        }
    }

    // MARK: - Guardrails

    private var guardrailSection: some View {
        Section(String(localized: "Guardrails")) {
            Picker(selection: permissionBinding) {
                ForEach(AgentPermissionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text(String(localized: "Permission mode"))
                Text(environment.settings.agentCLI.permissionMode.explanation)
            }

            LabeledContent(String(localized: "Max turns")) {
                // `0` is the stored form of "no limit", which ``AgentCLIConfiguration`` has
                // always read that way (it only passes a positive cap).
                limitRow(
                    agentCLIBinding(\.maxTurns),
                    suggested: AgentCLIConfiguration.suggestedMaxTurns,
                    range: 1...500
                )
                .help(String(
                    localized: "Runs until the agent is done. The spend cap below still applies when it is on."
                ))
            }

            LabeledContent(String(localized: "Budget")) {
                HStack(spacing: 8) {
                    if environment.settings.agentCLI.maxBudgetUSD != nil {
                        TextField(
                            String(localized: "Budget"),
                            value: budgetBinding,
                            format: .number,
                            prompt: Text(verbatim: "5")
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        Text(String(localized: "USD"))
                            .foregroundStyle(.secondary)
                    }
                    Toggle(String(localized: "Cap spend"), isOn: budgetEnabledBinding)
                        .toggleStyle(.checkbox)
                }
            }

            LabeledContent {
                TextField(
                    String(localized: "Tools"),
                    text: allowedToolsBinding,
                    prompt: Text(verbatim: AgentCLIConfiguration.defaultAllowedTools)
                )
                .labelsHidden()
                .disabled(!environment.settings.agentCLI.permissionMode.usesAllowedTools)
                .help(String(
                    localized: "Passed to --allowedTools. The default allows reading, editing, any shell command and the web."
                ))
            } label: {
                Text(String(localized: "Tools"))
                if environment.settings.agentCLI.permissionMode.usesAllowedTools {
                    Text(String(localized: "Passed to --allowedTools."))
                } else {
                    Text(String(localized: "Does not apply while every tool is allowed."))
                }
            }
        }
    }

    // MARK: - The session back-channel (ADR 0030)

    private var sessionSection: some View {
        Section {
            TextField(
                String(localized: "Local"),
                text: sessionResumeBinding,
                prompt: Text(verbatim: AgentCLIConfiguration.defaultSessionResumeTemplate)
            )
            TextField(
                String(localized: "Remote"),
                text: remoteSessionBinding,
                prompt: Text(String(localized: "empty — the button opens the session instead"))
            )
        } header: {
            SettingsSectionHeader(String(localized: "Session back-channel"), info: String(
                localized: "Runs your own installed CLI with its own login; Shepherd holds no token for it and never pushes what the session changes. {message} is always exactly one argument, {sessionID} and {sessionURL} come from the trailer, {worktree} is the worktree path. Write a full path unless the command is the CLI above, or leave a field empty to switch that button off.\n\nGuardrails do not apply to a resumed session: add --max-turns and --max-budget-usd to cap it."
            ))
        } footer: {
            SettingsNote(String(
                localized: "Sends a review finding to the session named in a commit's Claude-Session: trailer."
            ))
        }
    }

    // MARK: - Local checkouts

    private var checkoutSection: some View {
        Section {
            if environment.settings.localCheckouts.isEmpty {
                Text(String(localized: "None configured yet."))
                    .foregroundStyle(.secondary)
            }

            ForEach(sortedCheckouts, id: \.key) { entry in
                LabeledContent {
                    HStack(spacing: 8) {
                        Button(String(localized: "Change")) { choose(repo: entry.key) }
                            .buttonStyle(.borderless)
                        Button(String(localized: "Remove")) {
                            environment.settings.setLocalCheckout(nil, forRepoNamed: entry.key)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.failure)
                    }
                } label: {
                    Text(entry.key)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.value)
                        .font(Theme.mono(.caption))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(entry.value)
                }
            }
        } header: {
            Text(String(localized: "Local checkouts"))
        } footer: {
            SettingsNote(String(
                localized: "A delegation runs in a git worktree of your own clone. Shepherd never clones anything itself."
            ))
        }
    }

    /// The two ways to add a checkout. The one-step way first: the repository is read from the
    /// clone's `origin`, and watching it comes in the same confirmation. The typed row stays for
    /// a clone whose remote does not say (ADR 0011's 2026-09-23 amendment).
    private var addCheckoutSection: some View {
        Section {
            LabeledContent {
                Button(String(localized: "Add a local repository…")) { chooseLocalRepository() }
            } label: {
                Text(String(localized: "From a folder"))
                Text(String(localized: "Reads the repository from the clone's origin; can watch it too."))
            }

            LabeledContent {
                HStack(spacing: 8) {
                    TextField(
                        String(localized: "Repository"),
                        text: $newRepoFullName,
                        prompt: Text(verbatim: "owner/repo")
                    )
                    .labelsHidden()
                    Button(String(localized: "Choose folder…")) { addRepository() }
                }
            } label: {
                Text(String(localized: "By name"))
                Text(String(localized: "For a clone whose origin does not say."))
            }

            if let repoError {
                Text(repoError)
                    .foregroundStyle(Theme.failure)
            }
            if let repoNotice {
                Text(repoNotice)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: - Editor (ADR 0039)

    private var editorSection: some View {
        Section {
            Picker(selection: editorKindBinding) {
                ForEach(EditorKind.allCases) { kind in
                    Text(editorTitle(kind)).tag(kind)
                }
            } label: {
                Text(String(localized: "Open in editor"))
                Text(String(localized: "Opens a review's file in your checkout, at the line."))
            }

            if environment.settings.editor.kind == .custom {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField(
                            String(localized: "Command"),
                            text: editorCommandBinding,
                            prompt: Text(verbatim: EditorConfiguration.exampleCustomCommandTemplate)
                        )
                        .labelsHidden()
                        InfoButton(String(
                            localized: "Split like a shell would, but no shell ever runs it; {file} is always exactly one argument. Start with the full path to the program: apps opened from the Dock do not see your shell's PATH."
                        ))
                    }
                } label: {
                    Text(String(localized: "Command"))
                    Text(String(localized: "{file} is the path, {line} the line (or 1)."))
                }
            }
        } header: {
            SettingsSectionHeader(String(localized: "Editor"), info: String(
                localized: "Lines are counted on the pull request's head, so they match when your checkout is on that commit."
            ))
        }
        .onAppear { installedEditors = EditorOpener.installedKinds() }
    }

    /// The picker row for one editor, with a note when this Mac does not have it.
    private func editorTitle(_ kind: EditorKind) -> String {
        guard !installedEditors.contains(kind) else { return kind.title }
        return String(localized: "\(kind.title) (not found on this Mac)")
    }

    // MARK: - Automatic delegation (ADR 0016)

    private var automaticSection: some View {
        Section(String(localized: "Automatic delegation")) {
            Toggle(isOn: autoEnabledBinding) {
                Text(String(localized: "Start a delegation on its own when a rule matches"))
                Text(String(localized: "Same worktree and guardrails; never pushes, approves or merges."))
            }
        }
    }

    private var triggerSection: some View {
        Section {
            Toggle(String(localized: "CI turns red"), isOn: triggerBinding(.checksFailed))
            Toggle(
                String(localized: "A reviewer requests changes"),
                isOn: triggerBinding(.changesRequested)
            )
        } header: {
            SettingsSectionHeader(String(localized: "Run on my pull requests when"), info: String(
                localized: "“Turns” is meant literally: Shepherd has to have seen the change happen. A pull request that was already red when Shepherd first saw it never starts anything, and each pull request starts at most one run per commit."
            ))
        }
    }

    private var taskSection: some View {
        Section {
            TextEditor(text: promptTemplateBinding)
                .font(Theme.mono(.callout))
                // `.limited`, not `.complete`: this is a template with `{{…}}` placeholders that
                // `AutoDelegationPrompt` substitutes, and a rewrite that "improved" a placeholder
                // away would break the automatic run silently. Proofreading is welcome; a full
                // rewrite panel is not (ADR 0020).
                .writingToolsBehavior(.limited)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 84, maxHeight: 120)
            Button(String(localized: "Reset to the default task")) {
                environment.settings.autoDelegation.promptTemplate =
                    AutoDelegationRules.defaultPromptTemplate
            }
        } header: {
            Text(String(localized: "Task for the agent"))
        } footer: {
            SettingsNote(String(
                localized: "Placeholders: \(AutoDelegationPrompt.placeholders.joined(separator: " ")). Shepherd's own rules (worktree, no push) come first."
            ))
        }
    }

    private var capSection: some View {
        Section {
            LabeledContent(String(localized: "At once")) {
                limitRow(
                    autoDelegationBinding(\.maxConcurrent),
                    suggested: AutoDelegationRules.defaultMaxConcurrent,
                    range: 1...20
                )
            }
            LabeledContent(String(localized: "Per day")) {
                limitRow(
                    autoDelegationBinding(\.maxPerDay),
                    suggested: AutoDelegationRules.defaultMaxPerDay,
                    range: 1...500
                )
            }
        } header: {
            Text(String(localized: "Limits"))
        } footer: {
            SettingsNote(capFooter)
        }
    }

    /// "3 of 5 used today", or just "3 used today" with no daily cap — never `Int.max`.
    private var capFooter: String {
        guard environment.autoDelegation.dailyCap != .max else {
            return String(
                localized: "\(environment.autoDelegation.startsToday) started today · \(environment.autoDelegation.runningCount) running now. At a cap, Shepherd notifies you instead."
            )
        }
        return String(
            localized: "\(environment.autoDelegation.startsToday) of \(environment.autoDelegation.dailyCap) used today · \(environment.autoDelegation.runningCount) running now. At a cap, Shepherd notifies you instead."
        )
    }

    /// A limit's stepper with a "No limit" box: `0` is stored for no limit.
    ///
    /// While the limit is off the disabled stepper shows `suggested` rather than a `0` outside
    /// its own range, and unticking the box restores exactly that number.
    private func limitRow(
        _ stored: Binding<Int>,
        suggested: Int,
        range: ClosedRange<Int>
    ) -> some View {
        let isOff = stored.wrappedValue <= 0
        return HStack(spacing: 12) {
            StepperValue(
                value: Binding(
                    get: { isOff ? suggested : stored.wrappedValue },
                    set: { stored.wrappedValue = max(1, $0) }
                ),
                range: range
            )
            .disabled(isOff)
            .opacity(isOff ? 0.5 : 1)
            Toggle(String(localized: "No limit"), isOn: Binding(
                get: { isOff },
                set: { stored.wrappedValue = $0 ? 0 : suggested }
            ))
            .toggleStyle(.checkbox)
        }
    }

    // MARK: - Behaviour

    private var sortedCheckouts: [(key: String, value: String)] {
        environment.settings.localCheckouts
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { (key: $0.key, value: $0.value) }
    }

    private func detect() {
        detectState = .searching
        let configuration = environment.settings.agentCLI
        Task {
            let found = await AgentCLILocator.detect(configuration: configuration)
            guard let found else {
                detectState = .notFound
                return
            }
            environment.settings.agentCLI.executablePath = found.path
            detectState = .found(found.path)
        }
    }

    /// "By name": the same add as the folder route, so the repository is watched as well as
    /// linked — a clone whose pull requests never reach the inbox is not what "add" means. Only
    /// "Change" on an existing entry re-links without touching the watch list.
    private func addRepository() {
        let name = newRepoFullName.trimmingCharacters(in: .whitespacesAndNewlines)
        repoNotice = nil
        guard let repo = RepoRef.parse(fullName: name) else {
            repoError = String(localized: "Enter the repository as owner/name.")
            return
        }
        repoError = nil
        guard let url = chooseClone(of: name) else { return }
        // A full watch list still links: the checkout is what this row is for, so it says what
        // happened instead of reporting the half that could not as a failure.
        let isListFull = environment.settings.localRepositoryLink(repo, folder: url).watch == .listFull
        repoError = environment.settings.addLocalRepository(repo, folder: url, link: true, watch: !isListFull)
        if isListFull {
            repoNotice = String(
                localized: "Linked \(repo.fullName), but did not watch it: the watch list is full. Its pull requests reach the inbox only when they involve you."
            )
        }
        newRepoFullName = ""
    }

    private func choose(repo: String) {
        guard let url = chooseClone(of: repo) else { return }
        environment.settings.setLocalCheckout(url, forRepoNamed: repo)
    }

    private func chooseClone(of repo: String) -> URL? {
        FolderPicker.choose(title: String(localized: "Choose the local clone of \(repo)"))
    }

    // MARK: - Bindings

    private var kindBinding: Binding<AgentCLIKindTag> {
        Binding(
            get: { environment.settings.agentCLI.kind.tag },
            set: { tag in
                switch tag {
                case .claudeCode:
                    environment.settings.agentCLI.kind = .claudeCode
                case .custom:
                    let existing = environment.settings.agentCLI.kind.commandTemplate
                    environment.settings.agentCLI.kind = .custom(commandTemplate: existing)
                }
            }
        )
    }

    private var templateBinding: Binding<String> {
        Binding(
            get: { environment.settings.agentCLI.kind.commandTemplate },
            set: { environment.settings.agentCLI.kind = .custom(commandTemplate: $0) }
        )
    }

    private var executablePathBinding: Binding<String> {
        Binding(
            get: { environment.settings.agentCLI.executablePath },
            set: { environment.settings.agentCLI.executablePath = $0 }
        )
    }

    private var permissionBinding: Binding<AgentPermissionMode> {
        Binding(
            get: { environment.settings.agentCLI.permissionMode },
            set: { environment.settings.agentCLI.permissionMode = $0 }
        )
    }

    private func agentCLIBinding<Value>(_ field: WritableKeyPath<AgentCLIConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { environment.settings.agentCLI[keyPath: field] },
            set: { environment.settings.agentCLI[keyPath: field] = $0 }
        )
    }

    private func autoDelegationBinding(_ field: WritableKeyPath<AutoDelegationRules, Int>) -> Binding<Int> {
        Binding(
            get: { environment.settings.autoDelegation[keyPath: field] },
            set: { environment.settings.autoDelegation[keyPath: field] = $0 }
        )
    }

    private var editorKindBinding: Binding<EditorKind> {
        Binding(
            get: { environment.settings.editor.kind },
            set: { environment.settings.editor.kind = $0 }
        )
    }

    private var editorCommandBinding: Binding<String> {
        Binding(
            get: { environment.settings.editor.customCommandTemplate },
            set: { environment.settings.editor.customCommandTemplate = $0 }
        )
    }

    private var budgetEnabledBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.agentCLI.maxBudgetUSD != nil },
            set: { isOn in
                if !isOn, let current = environment.settings.agentCLI.maxBudgetUSD {
                    lastBudgetUSD = current
                }
                environment.settings.agentCLI.maxBudgetUSD = isOn ? lastBudgetUSD : nil
            }
        )
    }

    private var budgetBinding: Binding<Double> {
        Binding(
            get: { environment.settings.agentCLI.maxBudgetUSD ?? lastBudgetUSD },
            set: { environment.settings.agentCLI.maxBudgetUSD = max(0, $0) }
        )
    }

    private var sessionResumeBinding: Binding<String> {
        Binding(
            get: { environment.settings.agentCLI.sessionResumeTemplate },
            set: { environment.settings.agentCLI.sessionResumeTemplate = $0 }
        )
    }

    private var remoteSessionBinding: Binding<String> {
        Binding(
            get: { environment.settings.agentCLI.remoteSessionTemplate },
            set: { environment.settings.agentCLI.remoteSessionTemplate = $0 }
        )
    }

    private var allowedToolsBinding: Binding<String> {
        Binding(
            get: { environment.settings.agentCLI.allowedTools },
            set: { environment.settings.agentCLI.allowedTools = $0 }
        )
    }

    private var autoEnabledBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.autoDelegation.isEnabled },
            set: { environment.settings.autoDelegation.isEnabled = $0 }
        )
    }

    private func triggerBinding(_ trigger: AutoDelegationTrigger) -> Binding<Bool> {
        Binding(
            get: { environment.settings.autoDelegation.triggers.contains(trigger) },
            set: { isOn in
                var triggers = environment.settings.autoDelegation.triggers
                if isOn {
                    triggers.insert(trigger)
                } else {
                    triggers.remove(trigger)
                }
                environment.settings.autoDelegation.triggers = triggers
            }
        )
    }

    private var promptTemplateBinding: Binding<String> {
        Binding(
            get: { environment.settings.autoDelegation.promptTemplate },
            set: { environment.settings.autoDelegation.promptTemplate = $0 }
        )
    }
}
