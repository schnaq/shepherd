import ShepherdCore
import SwiftUI

/// Settings → Automation: the outbound webhook (ADR 0012).
///
/// One URL, a set of events, an optional signing secret, and a button that proves the whole
/// thing works. There is no inbound half and no "connect account" step — Shepherd has no
/// server to receive anything (ADR 0005), so automation is strictly one-directional.
struct AutomationSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    /// The settings model, which owns the secret editor and the test state.
    let model: SettingsModel

    @State private var saveError: String?

    var body: some View {
        SettingsPage {
            webhookCard
            eventsCard
            signingCard
            deliveryCard
            policyCard
        }
        .task {
            model.loadWebhookSecret(store: environment.secretStore)
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
}
