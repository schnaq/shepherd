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
/// emits is one of the webhook events listed above. It is also the only card in Settings that
/// carries a warning rather than an explanation, which is why it is last: everything above it can
/// be misconfigured, this one can merge.
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
            webhookCard
            eventsCard
            signingCard
            deliveryCard
            policyCard
            autoMergeCard
            autoMergeLogCard
            trustLaneCard
            trackRecordCard
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

    private var webhookCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "OUTBOUND WEBHOOK"))
                Toggle(String(localized: "Send events to a webhook"), isOn: enabledBinding)
                LabeledField(
                    label: String(localized: "URL"),
                    placeholder: "https://n8n.example.com/webhook/shepherd",
                    text: urlBinding
                )
                if let problem = urlProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.pending)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(
                    localized: "Paste an n8n Webhook node's URL (or any endpoint that accepts a JSON POST). https everywhere, or http for a server on this machine. Nothing is ever sent anywhere else."
                ))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Events

    private var eventsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "EVENTS"))
                ForEach(WebhookEventKind.userSelectable) { kind in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(kind.title, isOn: eventBinding(kind))
                        Text(kind.explanation)
                            .font(Theme.type(.subheadline))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Signing

    private var signingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "SIGNING SECRET (OPTIONAL)"))
                HStack(spacing: 8) {
                    Text(String(localized: "Secret"))
                        .font(Theme.type(.callout))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 74, alignment: .leading)
                    SecureField(String(localized: "leave empty for unsigned"), text: secretBinding)
                        .textFieldStyle(.roundedBorder)
                }
                Text(String(
                    localized: "With a secret set, every request carries X-Shepherd-Signature: sha256=<HMAC-SHA256 of the body>. That is the same shape as GitHub's X-Hub-Signature-256, so a verification step built for GitHub works unchanged. The secret is stored in your Keychain, next to the GitHub token."
                ))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(String(localized: "Save secret")) {
                        saveError = model.saveWebhookSecret(store: environment.secretStore)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                    if model.hasStoredWebhookSecret {
                        Text(String(localized: "A secret is stored."))
                            .font(Theme.type(.subheadline))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                if let saveError {
                    Text(saveError)
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.failure)
                }
            }
        }
    }

    // MARK: - Delivery

    private var deliveryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(String(localized: "DELIVERY"))
                HStack(spacing: 8) {
                    Button(String(localized: "Send test event")) {
                        let coordinator = environment.webhookCoordinator
                        Task { await model.sendTestWebhook(coordinator: coordinator) }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                    .disabled(model.webhookTestState == .running || !isURLUsable)
                    if model.webhookTestState == .running {
                        ProgressView().controlSize(.small)
                    }
                }
                testResult
                if let delivery = environment.webhooks.lastDelivery {
                    Label(
                        delivery.summary,
                        systemImage: delivery.isSuccess
                            ? "checkmark.circle"
                            : "exclamationmark.triangle"
                    )
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(delivery.isSuccess ? Theme.textMuted : Theme.pending)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(
                    localized: "A failing webhook never interrupts a review, a merge or a sync: Shepherd tries twice, then gives up quietly and says so here."
                ))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var policyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(String(localized: "WHAT WEBHOOKS NEVER SEND"))
                Text(String(
                    localized: "The payload says what happened — repository, number, title, author, provenance, verdict — and nothing more. No review text, no comment bodies, no diffs and no agent output leave your Mac. Events fire only after the action really succeeded, and only while the toggle above is on."
                ))
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var testResult: some View {
        AsyncActionStatusLine(state: model.webhookTestState)
    }

    // MARK: - Automatic merging (ADR 0018)

    private var autoMergeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                autoMergeSwitch
                Divider().overlay(Theme.hairline)
                autoMergeNarrowing
                Divider().overlay(Theme.hairline)
                autoMergeMethodSection
                Divider().overlay(Theme.hairline)
                autoMergeSummary
            }
        }
    }

    private var autoMergeSwitch: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(String(localized: "AUTOMATIC MERGING"))
            Toggle(
                String(localized: "Merge green, approved agent pull requests by myself"),
                isOn: autoMergeEnabledBinding
            )
            Label(
                String(
                    localized: "There is no confirmation click. With this on, Shepherd queues the merge as soon as a sweep sees a pull request that satisfies every rule below — the same merge you would have queued from the merge sheet, sent through the same outbox. That includes pull requests that are already waiting, so switching this on can merge several of them on the next sweep."
                ),
                systemImage: "exclamationmark.triangle"
            )
            .font(Theme.type(.subheadline))
            .foregroundStyle(Theme.pending)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var autoMergeNarrowing: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledField(
                label: String(localized: "Repos"),
                placeholder: "schnaq/review, schnaq/*",
                text: $repositoryField
            )
            Text(String(
                localized: "Comma-separated, with * and ? as wildcards. Leave it empty for every repository in your inbox."
            ))
            .font(Theme.type(.subheadline))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            LabeledField(
                label: String(localized: "Labels"),
                placeholder: "automerge",
                text: $labelField
            )
            Text(String(
                localized: "Comma-separated. A pull request has to carry every label listed here, which is how you opt single pull requests in instead of whole repositories. Leave it empty to require none."
            ))
            .font(Theme.type(.subheadline))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: repositoryField) { _, text in
            environment.settings.autoMerge.allowedRepositories = AutoMergeRules.list(from: text)
        }
        .onChange(of: labelField) { _, text in
            environment.settings.autoMerge.requiredLabels = AutoMergeRules.list(from: text)
        }
    }

    private var autoMergeMethodSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MergeMethodPicker(settings: environment.settings)
            Text(String(
                localized: "The same method the merge sheet and bulk triage use — whichever you merged with last. Changing it here changes it there."
            ))
            .font(Theme.type(.subheadline))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var autoMergeSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(autoMergeSentence)
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(
                localized: "Each pull request is queued at most once per commit: a merge Shepherd could not send — because somebody pushed in between — waits for you in Settings → Sync rather than being tried again against the new commit."
            ))
            .font(Theme.type(.subheadline))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var autoMergeLogCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardTitle(String(localized: "WHAT SHEPHERD MERGED"))
                    Spacer(minLength: 8)
                    if environment.autoMerge.auditEntryCount > 0 {
                        Button(String(localized: "Clear")) {
                            environment.autoMergeStore.clear()
                        }
                        .buttonStyle(.plain)
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.accentText)
                    }
                }
                if environment.autoMerge.auditEntries.isEmpty {
                    Text(String(localized: "Nothing yet. Every automatic merge is recorded here, on this Mac only."))
                        .font(Theme.type(.callout))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(environment.autoMerge.auditEntries) { entry in
                        Text(auditLine(for: entry))
                            .font(Theme.type(.subheadline))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            localized: "In plain words: Shepherd will \(autoMergeMethodName) a pull request by itself when \(joined). Anything else — a human's pull request, a red check, a pull request nobody approved — is left for you."
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

    private var trustLaneCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "TRUST LANES"))
                Text(String(
                    localized: "The inbox splits into Short look and Full review. A pull request is a short look only when CI is green, the diff is within both numbers below, and it touches no workflow, auth, secret, migration or deleted-test file."
                ))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                TrustThresholdRow(
                    title: String(localized: "Files"),
                    value: trustLaneFilesBinding,
                    range: TrustThresholdRow.fileRange
                )
                TrustThresholdRow(
                    title: String(localized: "Lines"),
                    value: trustLaneLinesBinding,
                    range: TrustThresholdRow.lineRange
                )
                Text(trustLaneSentence)
                    .font(Theme.type(.callout))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(
                    localized: "Both numbers travel to your other Macs. A track record never moves a pull request between the lanes — it only colours the chip and orders rows inside a lane."
                ))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trackRecordCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "TRACK RECORD"))
                Text(String(
                    localized: "Loads the pull requests your repositories closed in the last 90 days, so each agent's chip can say how much of its work was merged and how much came back out. At most 500 per repository, read once and kept up to date by the sync from then on."
                ))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                trackRecordButtons
                if let progress = environment.trackRecord.progress {
                    Text(TrackRecordProgressLine.text(for: progress))
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let result = environment.trackRecord.lastResult {
                    Text(TrackRecordProgressLine.text(for: result))
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Every failure as one line, in the words the server gave: a run over six
                    // repositories that could not search the third has still imported five.
                    ForEach(result.failures, id: \.repo) { failure in
                        Label(
                            TrackRecordProgressLine.text(for: failure),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(Theme.type(.subheadline))
                        .foregroundStyle(Theme.failure)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(String(
                    localized: "\(environment.trackRecord.storedOutcomeCount) closed pull requests stored on this Mac. This history is not synced."
                ))
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var trackRecordButtons: some View {
        HStack(spacing: 8) {
            if environment.trackRecord.isRunning {
                Button(String(localized: "Stop")) {
                    environment.trackRecord.cancel()
                }
                .buttonStyle(SecondaryButtonStyle(height: 28))
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(String(localized: "Load track record")) {
                    environment.startTrackRecordBackfill()
                }
                .buttonStyle(SecondaryButtonStyle(height: 28))
                .disabled(environment.trackRecordBackfillRepositories.isEmpty)
                .help(
                    environment.trackRecordBackfillRepositories.isEmpty
                        ? String(localized: "Nothing to load yet: sync an inbox first.")
                        : String(localized: "Reads the last 90 days of closed pull requests, one repository at a time.")
                )
            }
            if environment.trackRecord.storedOutcomeCount > 0 {
                Button(String(localized: "Clear history")) {
                    guard let database = environment.session?.database else { return }
                    environment.trackRecord.clearHistory(database: database)
                }
                .buttonStyle(.plain)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.accentText)
            }
            Spacer(minLength: 0)
        }
    }

    /// The thresholds as one plain sentence, so nobody has to infer them from two steppers.
    private var trustLaneSentence: String {
        let configuration = environment.settings.trustLaneConfiguration
        return String(
            localized: "In plain words: a green pull request touching at most \(configuration.maxFiles) files and \(configuration.maxChangedLines) changed lines, with nothing sensitive in it, is a short look. Everything else is a full review."
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
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

/// One "label · stepper · number" row, as both trust-lane thresholds are.
///
/// A private twin of the Delegation tab's row rather than a shared component: the two tabs' rows
/// differ in label width and in nothing else, and a shared one would need a parameter for that
/// and a home neither tab owns.
private struct TrustThresholdRow: View {
    /// The range the file stepper may move in — the configuration's own clamp, so the control
    /// cannot produce a value the pure type would then silently change.
    static let fileRange = ClosedRange(
        uncheckedBounds: (
            lower: TrustLaneConfiguration.minimumThreshold,
            upper: TrustLaneConfiguration.maximumFiles
        )
    )
    /// The same for the changed-lines stepper.
    static let lineRange = ClosedRange(
        uncheckedBounds: (
            lower: TrustLaneConfiguration.minimumThreshold,
            upper: TrustLaneConfiguration.maximumChangedLines
        )
    )

    /// The row's label.
    let title: String
    /// The value the stepper edits and the row displays.
    let value: Binding<Int>
    /// The permitted range.
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Theme.type(.callout))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 74, alignment: .leading)
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .font(Theme.mono(.callout))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
        }
    }
}

/// The lines the track-record card shows about a run (ADR 0027).
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
        String(localized: "\(failure.repo.fullName): \(failure.message)")
    }
}
