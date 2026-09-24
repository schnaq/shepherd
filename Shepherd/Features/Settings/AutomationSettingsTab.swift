import GitHubKit
import ShepherdCore
import ShepherdSync
import SwiftUI

/// Settings → Automation: the outbound webhook (ADR 0012), automatic merging (ADR 0018) and the
/// trust lanes with their track record (ADR 0027).
///
/// The webhook half is one URL, a set of events, an optional signing secret, and a button that
/// proves the whole thing works. There is no inbound half and no "connect account" step —
/// Shepherd has no server to receive anything (ADR 0005), so automation is strictly
/// one-directional.
///
/// Automatic merging sits below it rather than beside auto-delegation on the Delegation tab,
/// because it is not a delegation: it writes to GitHub, it never runs an agent, and the event it
/// emits is one of the webhook events listed above. It is also the only section in Settings whose
/// subtitle is a warning rather than an explanation: everything above it can be misconfigured,
/// this one can merge.
struct AutomationSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    /// The settings model, which owns the secret editor and the test state.
    let model: SettingsModel

    @State private var saveError: String?
    /// The comma-separated repository allow-list, while it is being typed.
    ///
    /// The field's own state rather than a computed binding onto the parsed list: a binding whose
    /// getter re-rendered `["a"]` as `"a"` would delete the comma the user just typed before they
    /// could type the next entry. Seeded from the settings when the tab appears, parsed into them
    /// on every keystroke.
    @State private var repositoryField = ""
    /// The comma-separated required labels, while they are being typed.
    @State private var labelField = ""

    var body: some View {
        SettingsPage {
            webhookSection
            eventsSection
            signingSection
            deliverySection
            autoMergeSection
            autoMergeLogSection
            trustLaneSection
            trackRecordSection
        }
        .task {
            model.loadWebhookSecret(store: environment.secretStore)
            loadAutoMergeFields()
            await environment.refreshTrackRecordCount()
        }
        // The stored count is the one number on this tab that a *finished run* changes, and a
        // finished run changes no row anywhere else — so it is re-read off the coordinator's
        // history counter rather than polled (ADR 0027).
        .onChange(of: environment.trackRecord.historyVersion) { _, _ in
            Task { await environment.refreshTrackRecordCount() }
        }
    }

    // MARK: - Destination

    private var webhookSection: some View {
        Section {
            Toggle(String(localized: "Send events to a webhook"), isOn: enabledBinding)
            TextField(
                String(localized: "URL"),
                text: urlBinding,
                prompt: Text(verbatim: "https://n8n.example.com/webhook/shepherd")
            )
            if let problem = urlProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.pending)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(String(localized: "Outbound webhook"))
        } footer: {
            SettingsNote(String(
                localized: "Any endpoint that takes a JSON POST, such as n8n. https, or http on this Mac. Nothing is sent anywhere else."
            ))
        }
    }

    // MARK: - Events

    private var eventsSection: some View {
        Section {
            ForEach(WebhookEventKind.userSelectable) { kind in
                Toggle(isOn: eventBinding(kind)) {
                    Text(kind.title)
                    Text(kind.explanation)
                }
            }
        } header: {
            SettingsSectionHeader(String(localized: "Events"), info: String(
                localized: "Each event says what happened — repository, number, title, author, provenance, verdict — and nothing more. It fires only after the action really succeeded."
            ))
        } footer: {
            SettingsNote(String(
                localized: "Webhooks never carry review text, comments, diffs or agent output."
            ))
        }
    }

    // MARK: - Signing

    private var signingSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField(
                        String(localized: "Secret"),
                        text: secretBinding,
                        prompt: Text(String(localized: "leave empty for unsigned"))
                    )
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    Button(String(localized: "Save secret")) {
                        saveError = model.saveWebhookSecret(store: environment.secretStore)
                    }
                }
            } label: {
                SettingsSectionHeader(String(localized: "Secret"), info: String(
                    localized: "With a secret set, every request carries X-Shepherd-Signature: sha256=<HMAC-SHA256 of the body> — the same shape as GitHub's X-Hub-Signature-256. The secret is stored in your Keychain."
                ))
                if model.hasStoredWebhookSecret {
                    Text(String(localized: "A secret is stored."))
                }
            }
            if let saveError {
                Text(saveError)
                    .foregroundStyle(Theme.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(String(localized: "Signing secret"))
        } footer: {
            SettingsNote(String(localized: "Optional. Lets the receiver check that a request came from Shepherd."))
        }
    }

    // MARK: - Delivery

    private var deliverySection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if model.webhookTestState == .running {
                        ProgressView().controlSize(.small)
                    }
                    Button(String(localized: "Send test event")) {
                        let coordinator = environment.webhookCoordinator
                        Task { await model.sendTestWebhook(coordinator: coordinator) }
                    }
                    .disabled(model.webhookTestState == .running || !isURLUsable)
                }
            } label: {
                Text(String(localized: "Test event"))
                if let delivery = environment.webhooks.lastDelivery {
                    Label(
                        delivery.summary,
                        systemImage: delivery.isSuccess
                            ? "checkmark.circle"
                            : "exclamationmark.triangle"
                    )
                    .foregroundStyle(delivery.isSuccess ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.pending))
                }
            }
            if model.webhookTestState.hasResult {
                AsyncActionStatusLine(state: model.webhookTestState)
            }
        } header: {
            Text(String(localized: "Delivery"))
        } footer: {
            SettingsNote(String(
                localized: "A failing webhook never blocks a review, merge or sync: Shepherd tries twice, then gives up quietly."
            ))
        }
    }

    // MARK: - Automatic merging (ADR 0018)

    private var autoMergeSection: some View {
        Section {
            Toggle(isOn: autoMergeEnabledBinding) {
                Text(String(localized: "Merge green, approved agent pull requests automatically"))
                Label(
                    String(localized: "No confirmation click: pull requests already waiting can merge on the next sweep."),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(Theme.pending)
            }
            LabeledContent {
                TextField(
                    String(localized: "Repos"),
                    text: $repositoryField,
                    prompt: Text(verbatim: "schnaq/review, schnaq/*")
                )
                .labelsHidden()
                .frame(maxWidth: 240)
            } label: {
                Text(String(localized: "Repos"))
                Text(String(localized: "Comma-separated, * and ? as wildcards. Empty means all."))
            }
            LabeledContent {
                TextField(
                    String(localized: "Labels"),
                    text: $labelField,
                    prompt: Text(verbatim: "automerge")
                )
                .labelsHidden()
                .frame(maxWidth: 240)
            } label: {
                Text(String(localized: "Labels"))
                Text(String(localized: "A pull request must carry all of them. Empty means none."))
            }
            MergeMethodPicker(settings: environment.settings)
        } header: {
            SettingsSectionHeader(String(localized: "Automatic merging"), info: String(
                localized: "Shepherd queues the same merge the merge sheet would, through the same outbox, pinned to the commit it checked. Each pull request is queued at most once per commit; one that could not be sent waits for you in Settings → Sync. The method is shared with the merge sheet and bulk triage."
            ))
        } footer: {
            SettingsNote(autoMergeSentence)
        }
        .onChange(of: repositoryField) { _, text in
            environment.settings.autoMerge.allowedRepositories = AutoMergeRules.list(from: text)
        }
        .onChange(of: labelField) { _, text in
            environment.settings.autoMerge.requiredLabels = AutoMergeRules.list(from: text)
        }
    }

    private var autoMergeLogSection: some View {
        Section {
            if environment.autoMerge.auditEntries.isEmpty {
                Text(String(localized: "Nothing yet. The log stays on this Mac."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(environment.autoMerge.auditEntries) { entry in
                    Text(auditLine(for: entry))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            HStack {
                Text(String(localized: "What Shepherd merged"))
                Spacer(minLength: 8)
                if environment.autoMerge.auditEntryCount > 0 {
                    Button(String(localized: "Clear")) {
                        environment.autoMergeStore.clear()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    /// One audit line: what was merged, which commit it was pinned to, and why.
    ///
    /// Assembled in steps rather than as one interpolation, both for the type-checker's sake and
    /// because the "because" half is conditional: a rule with no required labels has nothing to
    /// say about labels.
    private func auditLine(for entry: AutoMergeAuditEntry) -> String {
        let stamp = GitHubTimestamp.string(from: entry.queuedAt)
        var because = [
            String(localized: "\(entry.authorLogin) is a recognised agent"),
            String(localized: "\(entry.checkCount) checks green"),
            String(localized: "approved"),
        ]
        if !entry.matchedLabels.isEmpty {
            because.append(String(localized: "labelled \(entry.matchedLabels.joined(separator: ", "))"))
        }
        let reason = because.joined(separator: ", ")
        let what = String(
            localized: "Queued a \(entry.mergeMethod) merge of \(entry.slug) at \(entry.shortHead) on \(stamp)"
        )
        return String(localized: "\(what) — \(reason).")
    }

    /// The rules as one plain-language sentence, so nobody has to infer them from four controls.
    private var autoMergeSentence: String {
        let rules = environment.settings.autoMerge
        var conditions = [
            String(localized: "a recognised agent opened it"),
            String(localized: "every check on the head commit passed"),
            String(localized: "somebody approved it"),
            String(localized: "it is not a draft"),
            String(localized: "GitHub reports it as mergeable"),
        ]
        let repositories = rules.usableRepositories
        if !repositories.isEmpty {
            let list = repositories.joined(separator: " or ")
            conditions.append(String(localized: "it is in \(list)"))
        }
        let labels = rules.usableLabels
        if !labels.isEmpty {
            let list = labels.joined(separator: " and ")
            conditions.append(String(localized: "it carries \(list)"))
        }
        let joined = conditions.joined(separator: ", ")
        return String(
            localized: "Shepherd will \(autoMergeMethodName) a pull request by itself only when \(joined). Everything else is left for you."
        )
    }

    /// The merge method in the words the picker above uses.
    private var autoMergeMethodName: String {
        switch environment.settings.autoMergeMethod {
        case .merge: return String(localized: "create a merge commit for")
        case .squash: return String(localized: "squash and merge")
        case .rebase: return String(localized: "rebase and merge")
        }
    }

    /// Fills the two text fields from the stored rules.
    private func loadAutoMergeFields() {
        let rules = environment.settings.autoMerge
        repositoryField = AutoMergeRules.text(from: rules.allowedRepositories)
        labelField = AutoMergeRules.text(from: rules.requiredLabels)
    }

    // MARK: - Trust lanes (ADR 0027)

    private var trustLaneSection: some View {
        Section {
            LabeledContent(String(localized: "Files")) {
                StepperValue(value: trustLaneFilesBinding, range: Self.fileRange, font: Theme.mono(.callout))
            }
            LabeledContent(String(localized: "Lines")) {
                StepperValue(value: trustLaneLinesBinding, range: Self.lineRange, font: Theme.mono(.callout))
            }
        } header: {
            SettingsSectionHeader(String(localized: "Trust lanes"), info: String(
                localized: "Sensitive means a workflow, auth, secret, migration or deleted-test file. A track record never moves a pull request between the lanes; it only colours the chip and orders rows. Both limits travel to your other Macs."
            ))
        } footer: {
            SettingsNote(trustLaneSentence)
        }
    }

    /// The range the file stepper may move in — the configuration's own clamp, so the control
    /// cannot produce a value the pure type would then silently change.
    private static let fileRange = ClosedRange(
        uncheckedBounds: (
            lower: TrustLaneConfiguration.minimumThreshold,
            upper: TrustLaneConfiguration.maximumFiles
        )
    )
    /// The same for the changed-lines stepper.
    private static let lineRange = ClosedRange(
        uncheckedBounds: (
            lower: TrustLaneConfiguration.minimumThreshold,
            upper: TrustLaneConfiguration.maximumChangedLines
        )
    )

    private var trackRecordSection: some View {
        Section {
            LabeledContent {
                trackRecordButtons
            } label: {
                Text(String(localized: "History"))
                Text(String(
                    localized: "\(environment.trackRecord.storedOutcomeCount) closed pull requests stored on this Mac. This history is not synced."
                ))
            }
            if let progress = environment.trackRecord.progress {
                Text(TrackRecordProgressLine.text(for: progress))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result = environment.trackRecord.lastResult {
                Text(TrackRecordProgressLine.text(for: result))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Every failure as one line, in the words the server gave: a run over six
                // repositories that could not search the third has still imported five.
                ForEach(result.failures, id: \.repo) { failure in
                    Label(
                        TrackRecordProgressLine.text(for: failure),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(Theme.failure)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(String(localized: "Track record"))
        } footer: {
            SettingsNote(String(
                localized: "The last 90 days of closed pull requests, up to 500 per repository, for each agent's chip."
            ))
        }
    }

    @ViewBuilder
    private var trackRecordButtons: some View {
        HStack(spacing: 8) {
            if environment.trackRecord.storedOutcomeCount > 0 {
                Button(String(localized: "Clear history")) {
                    guard let database = environment.session?.database else { return }
                    environment.trackRecord.clearHistory(database: database)
                }
            }
            if environment.trackRecord.isRunning {
                ProgressView()
                    .controlSize(.small)
                Button(String(localized: "Stop")) {
                    environment.trackRecord.cancel()
                }
            } else {
                Button(String(localized: "Load track record")) {
                    environment.startTrackRecordBackfill()
                }
                .disabled(environment.trackRecordBackfillRepositories.isEmpty)
                .help(
                    environment.trackRecordBackfillRepositories.isEmpty
                        ? String(localized: "Nothing to load yet: sync an inbox first.")
                        : String(localized: "Reads the last 90 days of closed pull requests, one repository at a time.")
                )
            }
        }
    }

    /// The thresholds as one plain sentence, so nobody has to infer them from two steppers.
    private var trustLaneSentence: String {
        let configuration = environment.settings.trustLaneConfiguration
        return String(
            localized: "Short look: CI green, at most \(configuration.maxFiles) files and \(configuration.maxChangedLines) changed lines, nothing sensitive. Everything else is a full review."
        )
    }

    private var trustLaneFilesBinding: Binding<Int> {
        Binding(
            get: { environment.settings.trustLaneConfiguration.maxFiles },
            set: { environment.settings.trustLaneMaxFiles = $0 }
        )
    }

    private var trustLaneLinesBinding: Binding<Int> {
        Binding(
            get: { environment.settings.trustLaneConfiguration.maxChangedLines },
            set: { environment.settings.trustLaneMaxChangedLines = $0 }
        )
    }

    // MARK: - Derived state

    /// What is wrong with the URL in the field, if anything. `nil` while the field is empty —
    /// an untouched field is not an error.
    private var urlProblem: String? {
        let text = environment.settings.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        do {
            _ = try WebhookConfiguration.destination(text)
            return nil
        } catch {
            return error.userFacingDescription
        }
    }

    /// Whether the test button has somewhere to post to.
    private var isURLUsable: Bool {
        WebhookConfiguration.isUsable(environment.settings.webhookURL)
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.webhooksEnabled },
            set: { environment.settings.webhooksEnabled = $0 }
        )
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: { environment.settings.webhookURL },
            set: { environment.settings.webhookURL = $0 }
        )
    }

    private func eventBinding(_ kind: WebhookEventKind) -> Binding<Bool> {
        Binding(
            get: { environment.settings.webhookEvents.contains(kind) },
            set: { environment.settings.setWebhookEvent(kind, isOn: $0) }
        )
    }

    private var secretBinding: Binding<String> {
        Binding(get: { model.webhookSecretField }, set: { model.webhookSecretField = $0 })
    }

    private var autoMergeEnabledBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.autoMerge.isEnabled },
            set: { environment.settings.autoMerge.isEnabled = $0 }
        )
    }
}

/// The lines the track-record section shows about a run (ADR 0027).
///
/// Static functions on a type of their own rather than methods on the view, so an app test can
/// assert the sentences a user reads without building a Settings tab.
enum TrackRecordProgressLine {
    /// The progress line: "konduit: 120 of about 340", plus which repository this is.
    /// - Parameter progress: What the pager reported.
    /// - Returns: The line.
    static func text(for progress: TrackRecordBackfillProgress) -> String {
        let counted = String(
            localized: "\(progress.repo.name): \(progress.stored) of about \(progress.estimatedTotal)"
        )
        guard progress.repositoryCount > 1 else { return counted }
        let position = String(
            localized: "repository \(progress.repositoryIndex) of \(progress.repositoryCount)"
        )
        return "\(counted) · \(position)"
    }

    /// What a finished run says.
    /// - Parameter result: The run's result.
    /// - Returns: The line.
    static func text(for result: TrackRecordBackfillResult) -> String {
        var parts = [String(localized: "\(result.stored) closed pull requests read")]
        if result.revertsLinked > 0 {
            parts.append(String(localized: "\(result.revertsLinked) reverts matched"))
        }
        if !result.cappedRepositories.isEmpty {
            parts.append(
                String(localized: "\(result.cappedRepositories.count) repositories hit the 500 cap")
            )
        }
        if result.wasCancelled {
            parts.append(String(localized: "stopped early"))
        }
        return parts.joined(separator: " · ")
    }

    /// One failed repository as one line.
    /// - Parameter failure: The failure.
    /// - Returns: The line.
    static func text(for failure: TrackRecordBackfillFailure) -> String {
        String(localized: "\(failure.repo.fullName): \(failure.localizedMessage)")
    }
}
