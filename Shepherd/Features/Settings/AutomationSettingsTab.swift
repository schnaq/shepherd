import GitHubKit
import ShepherdCore
import SwiftUI

/// Settings → Automation: the outbound webhook (ADR 0012) and automatic merging (ADR 0018).
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
        }
        .task {
            model.loadWebhookSecret(store: environment.secretStore)
            loadAutoMergeFields()
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
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.pending)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(
                    localized: "Paste an n8n Webhook node's URL (or any endpoint that accepts a JSON POST). https everywhere, or http for a server on this machine. Nothing is ever sent anywhere else."
                ))
                .font(.system(size: 11))
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
                            .font(.system(size: 11))
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
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 74, alignment: .leading)
                    SecureField(String(localized: "leave empty for unsigned"), text: secretBinding)
                        .textFieldStyle(.roundedBorder)
                }
                Text(String(
                    localized: "With a secret set, every request carries X-Shepherd-Signature: sha256=<HMAC-SHA256 of the body>. That is the same shape as GitHub's X-Hub-Signature-256, so a verification step built for GitHub works unchanged. The secret is stored in your Keychain, next to the GitHub token."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(String(localized: "Save secret")) {
                        saveError = model.saveWebhookSecret(store: environment.secretStore)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                    if model.hasStoredWebhookSecret {
                        Text(String(localized: "A secret is stored."))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                if let saveError {
                    Text(saveError)
                        .font(.system(size: 11))
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
                    .font(.system(size: 11))
                    .foregroundStyle(delivery.isSuccess ? Theme.textMuted : Theme.pending)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(
                    localized: "A failing webhook never interrupts a review, a merge or a sync: Shepherd tries twice, then gives up quietly and says so here."
                ))
                .font(.system(size: 11))
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
                .font(.system(size: 12))
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
            .font(.system(size: 11))
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
            .font(.system(size: 11))
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
            .font(.system(size: 11))
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
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var autoMergeSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(autoMergeSentence)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(
                localized: "Each pull request is queued at most once per commit: a merge Shepherd could not send — because somebody pushed in between — waits for you in Settings → Sync rather than being tried again against the new commit."
            ))
            .font(.system(size: 11))
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
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accentText)
                    }
                }
                if environment.autoMerge.auditEntries.isEmpty {
                    Text(String(localized: "Nothing yet. Every automatic merge is recorded here, on this Mac only."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(environment.autoMerge.auditEntries) { entry in
                        Text(auditLine(for: entry))
                            .font(.system(size: 11))
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
