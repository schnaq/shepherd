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

    /// What the "Detect" button last found.
    private enum DetectState: Equatable {
        case idle
        case searching
        case found(String)
        case notFound
    }

    var body: some View {
        SettingsPage {
            agentCard
            guardrailCard
            checkoutCard
            automaticCard
            policyCard
        }
    }

    // MARK: - Agent CLI

    private var agentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "AGENT CLI"))
                Picker(String(localized: "Kind"), selection: kindBinding) {
                    ForEach(AgentCLIKindTag.allCases) { tag in
                        Text(tag.title).tag(tag)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch environment.settings.agentCLI.kind {
                case .claudeCode:
                    HStack(spacing: 8) {
                        LabeledField(
                            label: String(localized: "Path"),
                            placeholder: "/opt/homebrew/bin/claude",
                            text: executablePathBinding
                        )
                        Button(String(localized: "Detect")) { detect() }
                            .buttonStyle(SecondaryButtonStyle(height: 28))
                            .disabled(detectState == .searching)
                    }
                    detectResult
                    Text(String(
                        localized: "Leave the path empty to let Shepherd look in the usual places. Not installed? `npm install -g @anthropic-ai/claude-code`."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                case .custom:
                    LabeledField(
                        label: String(localized: "Command"),
                        placeholder: "/usr/local/bin/my-agent --cwd {worktree} --task {prompt}",
                        text: templateBinding
                    )
                    Text(String(
                        localized: "The template is split like a shell would, but no shell ever runs it: {prompt} always becomes exactly one argument, so a prompt cannot turn into a second command. {worktree} becomes the worktree path."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
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
                .font(Theme.mono(11))
                .foregroundStyle(Theme.success)
                .textSelection(.enabled)
        case .notFound:
            Label(
                String(localized: "Not found. Enter the full path to the executable."),
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.pending)
        }
    }

    // MARK: - Guardrails

    private var guardrailCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "GUARDRAILS"))
                Picker(String(localized: "Permission mode"), selection: permissionBinding) {
                    ForEach(AgentPermissionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(environment.settings.agentCLI.permissionMode.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Text(String(localized: "Max turns"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 74, alignment: .leading)
                    Stepper(value: turnsBinding, in: 1...200) {
                        Text("\(environment.settings.agentCLI.maxTurns)")
                            .font(Theme.mono(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                    }
                }

                HStack(spacing: 12) {
                    Text(String(localized: "Budget"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 74, alignment: .leading)
                    Toggle(String(localized: "Cap spend"), isOn: budgetEnabledBinding)
                        .toggleStyle(.checkbox)
                    if environment.settings.agentCLI.maxBudgetUSD != nil {
                        TextField("5", value: budgetBinding, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text(String(localized: "USD"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                }

                LabeledField(
                    label: String(localized: "Tools"),
                    placeholder: AgentCLIConfiguration.defaultAllowedTools,
                    text: allowedToolsBinding
                )
                Text(String(
                    localized: "Passed to --allowedTools. The default allows reading, editing and git, but no other shell command."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Local checkouts

    private var checkoutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "LOCAL CHECKOUTS"))
                Text(String(
                    localized: "A delegation runs in a detached git worktree built from your own clone. Shepherd never clones anything itself."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

                if environment.settings.localCheckouts.isEmpty {
                    Text(String(localized: "None configured yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }

                ForEach(sortedCheckouts, id: \.key) { entry in
                    HStack(spacing: 8) {
                        Text(entry.key)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .frame(width: 170, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(entry.value)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(entry.value)
                        Spacer(minLength: 6)
                        Button(String(localized: "Change")) { choose(repo: entry.key) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accentText)
                        Button(String(localized: "Remove")) {
                            environment.settings.setLocalCheckout(nil, forRepoNamed: entry.key)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.failure)
                    }
                }

                Divider().overlay(Theme.hairline)

                HStack(spacing: 8) {
                    TextField("owner/repo", text: $newRepoFullName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button(String(localized: "Choose folder…")) { addRepository() }
                        .buttonStyle(SecondaryButtonStyle(height: 28))
                }
                if let repoError {
                    Text(repoError)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.failure)
                }
            }
        }
    }

    // MARK: - Automatic delegation (ADR 0016)

    private var automaticCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                automaticSwitch
                Divider().overlay(Theme.hairline)
                automaticConditions
                Divider().overlay(Theme.hairline)
                automaticTemplate
                Divider().overlay(Theme.hairline)
                automaticCaps
            }
        }
    }

    private var automaticSwitch: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(String(localized: "AUTOMATIC DELEGATION"))
            Toggle(
                String(localized: "Start a delegation on its own when a rule matches"),
                isOn: autoEnabledBinding
            )
            Text(String(
                localized: "Off by default. A rule only ever starts the delegation you could have started yourself: it runs in an isolated worktree with the guardrails above, and it never pushes, approves or merges anything."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var automaticConditions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Run when, on a pull request of mine:"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Toggle(String(localized: "CI turns red"), isOn: triggerBinding(.checksFailed))
                .toggleStyle(.checkbox)
            Toggle(
                String(localized: "a reviewer requests changes"),
                isOn: triggerBinding(.changesRequested)
            )
            .toggleStyle(.checkbox)
            Text(String(
                localized: "\"Turns\" is meant literally: Shepherd has to have seen the change happen. A pull request that was already red when Shepherd first saw it never starts anything, and each pull request starts at most one run per commit."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var automaticTemplate: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Task for the agent"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            TextEditor(text: promptTemplateBinding)
                .font(Theme.mono(11.5))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 84, maxHeight: 120)
                .background(
                    Theme.control,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            Text(String(
                localized: "Placeholders: \(AutoDelegationPrompt.placeholders.joined(separator: " ")). Shepherd's own instructions — detached worktree, do not push, keep the change small — are prepended as usual."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Reset to the default task")) {
                environment.settings.autoDelegation.promptTemplate =
                    AutoDelegationRules.defaultPromptTemplate
            }
            .buttonStyle(SecondaryButtonStyle(height: 26))
        }
    }

    private var automaticCaps: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(String(localized: "At once"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 74, alignment: .leading)
                Stepper(value: concurrencyBinding, in: 1...5) {
                    Text("\(environment.settings.autoDelegation.concurrencyCap)")
                        .font(Theme.mono(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                }
            }
            HStack(spacing: 12) {
                Text(String(localized: "Per day"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 74, alignment: .leading)
                Stepper(value: dailyBinding, in: 1...50) {
                    Text("\(environment.settings.autoDelegation.dailyCap)")
                        .font(Theme.mono(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                }
            }
            Text(String(
                localized: "\(environment.autoDelegation.startsToday) of \(environment.autoDelegation.dailyCap) used today · \(environment.autoDelegation.runningCount) running now. When a cap is reached Shepherd notifies you instead of starting anything."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var policyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(String(localized: "WHAT DELEGATION NEVER DOES"))
                Text(String(
                    localized: "Shepherd never handles the agent's authentication: it runs your installed CLI and passes your environment through untouched, adding nothing and removing nothing. It never pushes on its own either — the agent works in an isolated worktree and you decide what is committed."
                ))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
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

    private func addRepository() {
        let name = newRepoFullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RepoRef.parse(fullName: name) != nil else {
            repoError = String(localized: "Enter the repository as owner/name.")
            return
        }
        repoError = nil
        choose(repo: name)
        newRepoFullName = ""
    }

    private func choose(repo: String) {
        guard let url = FolderPicker.choose(
            title: String(localized: "Choose the local clone of \(repo)")
        ) else { return }
        environment.settings.setLocalCheckout(url, forRepoNamed: repo)
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

    private var turnsBinding: Binding<Int> {
        Binding(
            get: { environment.settings.agentCLI.maxTurns },
            set: { environment.settings.agentCLI.maxTurns = $0 }
        )
    }

    private var budgetEnabledBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.agentCLI.maxBudgetUSD != nil },
            set: { isOn in
                environment.settings.agentCLI.maxBudgetUSD = isOn
                    ? AgentCLIConfiguration.defaultMaxBudgetUSD
                    : nil
            }
        )
    }

    private var budgetBinding: Binding<Double> {
        Binding(
            get: {
                environment.settings.agentCLI.maxBudgetUSD
                    ?? AgentCLIConfiguration.defaultMaxBudgetUSD
            },
            set: { environment.settings.agentCLI.maxBudgetUSD = max(0, $0) }
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

    private var concurrencyBinding: Binding<Int> {
        Binding(
            get: { environment.settings.autoDelegation.concurrencyCap },
            set: { environment.settings.autoDelegation.maxConcurrent = max(1, $0) }
        )
    }

    private var dailyBinding: Binding<Int> {
        Binding(
            get: { environment.settings.autoDelegation.dailyCap },
            set: { environment.settings.autoDelegation.maxPerDay = max(1, $0) }
        )
    }
}
