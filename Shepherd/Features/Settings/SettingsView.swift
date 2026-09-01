import ShepherdCore
import SwiftUI

/// The Settings window: Account, Sync, Agents, Intelligence, Delegation, Automation,
/// Appearance.
///
/// Webhooks get their own tab rather than a section under Sync: Sync is about keeping the local
/// cache in step with GitHub, while Automation is about what Shepherd tells the outside world —
/// a different direction, a different failure mode, and the place the next integration will go.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model = SettingsModel()
    /// Which tab is showing. Every tab is tagged with its ``SettingsDeepLinkTab``, which is
    /// what lets `shepherd://settings/<tab>` land on one (ADR 0013).
    @State private var selection: SettingsDeepLinkTab

    /// Creates the Settings window or sheet.
    /// - Parameter initialTab: The tab to open on. Defaults to Account, which is what the
    ///   ⌘, window and the rail button want.
    init(initialTab: SettingsDeepLinkTab = .account) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            AccountSettingsTab()
                .tabItem { Label(String(localized: "Account"), systemImage: "person.crop.circle") }
                .tag(SettingsDeepLinkTab.account)
            SyncSettingsTab()
                .tabItem { Label(String(localized: "Sync"), systemImage: "arrow.clockwise") }
                .tag(SettingsDeepLinkTab.sync)
            AgentSettingsTab(model: model)
                .tabItem { Label(String(localized: "Agents"), systemImage: "cpu") }
                .tag(SettingsDeepLinkTab.agents)
            IntelligenceSettingsTab(model: model)
                .tabItem { Label(String(localized: "Intelligence"), systemImage: "sparkles") }
                .tag(SettingsDeepLinkTab.intelligence)
            DelegationSettingsTab()
                .tabItem {
                    Label(
                        String(localized: "Delegation"),
                        systemImage: "arrow.uturn.backward.badge.clock"
                    )
                }
                .tag(SettingsDeepLinkTab.delegation)
            AutomationSettingsTab(model: model)
                .tabItem {
                    Label(String(localized: "Automation"), systemImage: "bolt.horizontal")
                }
                .tag(SettingsDeepLinkTab.automation)
            AppearanceSettingsTab()
                .tabItem { Label(String(localized: "Appearance"), systemImage: "paintbrush") }
                .tag(SettingsDeepLinkTab.appearance)
        }
        .frame(width: 620, height: 460)
        .background(Theme.background)
    }
}

// MARK: - Account

/// Avatar, login, sign out & erase.
struct AccountSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingSignOut = false

    var body: some View {
        SettingsPage {
            if let session = environment.session {
                HStack(spacing: 12) {
                    AvatarView(
                        login: session.account.login,
                        url: session.account.avatarURL,
                        size: 46
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.account.login)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textStrong)
                        Text(authDescription(session.account.authKind))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                }

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        CardTitle(String(localized: "LOCAL DATA"))
                        Text(String(
                            localized: "Everything Shepherd has fetched lives in a SQLite file in Application Support. Your token lives in the Keychain and nowhere else."
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(AppConfig.databaseURL.path)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textMuted)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }

                Button(String(localized: "Sign out & erase local data")) {
                    isConfirmingSignOut = true
                }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.failure))
                .confirmationDialog(
                    String(localized: "Sign out and erase everything?"),
                    isPresented: $isConfirmingSignOut
                ) {
                    Button(String(localized: "Sign out & erase"), role: .destructive) {
                        Task { await environment.signOutAndErase() }
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text(String(
                        localized: "The Keychain token is deleted and the local database is emptied. Pending reviews that have not been sent are lost."
                    ))
                }
            } else {
                EmptyStateView(
                    systemImage: "person.crop.circle.badge.questionmark",
                    title: String(localized: "Not signed in"),
                    message: String(localized: "Sign in from the main window to see your account here.")
                )
            }
        }
    }

    private func authDescription(_ kind: AuthKind) -> String {
        switch kind {
        case .deviceFlow: return String(localized: "Signed in with the GitHub App device flow")
        case .pat: return String(localized: "Signed in with a personal access token")
        }
    }
}

// MARK: - Sync

/// Sweep interval and notification toggles.
struct SyncSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsPage {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(String(localized: "INBOX SWEEP"))
                    HStack(spacing: 12) {
                        Slider(value: intervalBinding, in: 1...10, step: 1)
                        Text(String(localized: "\(Int(environment.settings.sweepIntervalMinutes)) min"))
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    Text(String(
                        localized: "Notifications are polled at the interval GitHub asks for; this slider only controls the full search sweep. It takes effect the next time you sign in."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "NOTIFICATIONS"))
                    Toggle(String(localized: "A new review is requested from me"), isOn: reviewBinding)
                    Toggle(String(localized: "Checks fail on a pull request I opened"), isOn: checksBinding)
                    Toggle(String(localized: "A queued review could not be sent"), isOn: conflictBinding)
                    Text(String(
                        localized: "macOS asks for permission the first time Shepherd actually needs to post one."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                }
            }

            if let session = environment.session {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        CardTitle(String(localized: "OUTBOX"))
                        Text(session.pendingOutboxCount == 0
                            ? String(localized: "Nothing waiting to be sent.")
                            : String(localized: "\(session.pendingOutboxCount) mutations waiting to be sent."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Button(String(localized: "Sync now")) {
                            Task { await environment.syncNow() }
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 28))
                    }
                }
            }
        }
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { environment.settings.sweepIntervalMinutes },
            set: { environment.settings.sweepIntervalMinutes = $0 }
        )
    }

    private var reviewBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.notifyOnReviewRequest },
            set: { environment.settings.notifyOnReviewRequest = $0 }
        )
    }

    private var checksBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.notifyOnChecksFailed },
            set: { environment.settings.notifyOnChecksFailed = $0 }
        )
    }

    private var conflictBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.notifyOnDraftConflict },
            set: { environment.settings.notifyOnDraftConflict = $0 }
        )
    }
}

// MARK: - Agents

/// The bundled registry (read-only) plus the user's extensions (ADR 0008).
struct AgentSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    /// The settings model.
    let model: SettingsModel
    @State private var errorMessage: String?

    var body: some View {
        SettingsPage {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(String(localized: "BUNDLED REGISTRY"))
                    if let error = model.registryError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.failure)
                    }
                    ForEach(model.bundledAgents) { entry in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(AgentPalette.color(forAgentID: entry.id))
                                .frame(width: 8, height: 8)
                            Text(entry.displayName)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: 6)
                            Text(entry.loginPatterns.joined(separator: ", "))
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Text(String(
                        localized: "Bundled entries ship with Shepherd. Add your own below — an entry with the same id replaces the bundled one."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "YOUR EXTENSIONS"))
                    if model.overrides.isEmpty {
                        Text(String(localized: "None yet."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    ForEach(model.overrides) { entry in
                        HStack(spacing: 8) {
                            Text(entry.displayName)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text)
                            Text(entry.id)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.textMuted)
                            Spacer(minLength: 6)
                            Button(String(localized: "Remove")) {
                                Task {
                                    await model.removeOverride(
                                        id: entry.id,
                                        session: environment.session
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.failure)
                        }
                    }

                    Divider().overlay(Theme.hairline)

                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text(String(localized: "Id"))
                            TextField("my-agent", text: idBinding)
                        }
                        GridRow {
                            Text(String(localized: "Name"))
                            TextField("My Agent", text: nameBinding)
                        }
                        GridRow {
                            Text(String(localized: "Logins"))
                            TextField("my-agent[bot], my-agent-*", text: loginsBinding)
                        }
                        GridRow {
                            Text(String(localized: "Branches"))
                            TextField("my-agent/", text: branchesBinding)
                        }
                        GridRow {
                            Text(String(localized: "Trailers"))
                            TextField("Co-Authored-By: My Agent", text: trailersBinding)
                        }
                    }
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.failure)
                    }

                    Button(String(localized: "Add entry")) {
                        Task {
                            errorMessage = await model.addOverride(session: environment.session)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
                }
            }
        }
        .task {
            await model.loadRegistry(session: environment.session)
        }
    }

    private var idBinding: Binding<String> {
        Binding(get: { model.newAgentID }, set: { model.newAgentID = $0 })
    }

    private var nameBinding: Binding<String> {
        Binding(get: { model.newAgentName }, set: { model.newAgentName = $0 })
    }

    private var loginsBinding: Binding<String> {
        Binding(get: { model.newAgentLogins }, set: { model.newAgentLogins = $0 })
    }

    private var branchesBinding: Binding<String> {
        Binding(get: { model.newAgentBranches }, set: { model.newAgentBranches = $0 })
    }

    private var trailersBinding: Binding<String> {
        Binding(get: { model.newAgentTrailers }, set: { model.newAgentTrailers = $0 })
    }
}

// MARK: - Intelligence

/// Provider picker, BYOK configuration, connection test (ADR 0007).
struct IntelligenceSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    /// The settings model.
    let model: SettingsModel
    @State private var saveError: String?

    var body: some View {
        SettingsPage {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "PROVIDER"))
                    Picker(String(localized: "Provider"), selection: modeBinding) {
                        ForEach(IntelligenceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(environment.settings.intelligenceMode.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if environment.settings.intelligenceMode != .off,
                       let reason = OnDeviceProvider.unavailabilityReason() {
                        Text(String(localized: "On-device model: \(reason)"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.pending)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if environment.settings.intelligenceMode == .onDeviceAndCloud {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(String(localized: "BRING YOUR OWN KEY"))
                        Picker(String(localized: "Kind"), selection: kindBinding) {
                            ForEach(CloudProviderKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if environment.settings.cloudProviderKind == .openAICompatible {
                            endpointPresetPicker
                            LabeledField(
                                label: String(localized: "Base URL"),
                                placeholder: "https://api.example.eu/v1",
                                text: baseURLBinding
                            )
                            modelField
                            endpointNote
                        } else {
                            LabeledField(
                                label: String(localized: "Model"),
                                placeholder: AnthropicProvider.defaultModel,
                                text: anthropicModelBinding
                            )
                        }

                        HStack(spacing: 8) {
                            Text(String(localized: "API key"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 74, alignment: .leading)
                            SecureField(apiKeyPlaceholder, text: keyBinding)
                                .textFieldStyle(.roundedBorder)
                        }

                        Text(String(
                            localized: "The key is stored in your Keychain, next to the GitHub token, and is sent only to the endpoint above."
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button(String(localized: "Save key")) {
                                saveError = model.saveKey(
                                    kind: environment.settings.cloudProviderKind,
                                    store: environment.secretStore
                                )
                                environment.refreshIntelligence()
                            }
                            .buttonStyle(SecondaryButtonStyle(height: 28))

                            if environment.settings.cloudProviderKind == .openAICompatible {
                                Button(String(localized: "Load models")) {
                                    Task { await model.loadModels(settings: environment.settings) }
                                }
                                .buttonStyle(SecondaryButtonStyle(height: 28))
                                .disabled(
                                    model.modelListState == .loading
                                        || !model.canLoadModels(settings: environment.settings)
                                )
                            }

                            Button(String(localized: "Test connection")) {
                                Task { await model.testConnection(settings: environment.settings) }
                            }
                            .buttonStyle(SecondaryButtonStyle(height: 28))
                            .disabled(model.testState == .running)

                            if model.testState == .running || model.modelListState == .loading {
                                ProgressView().controlSize(.small)
                            }
                        }

                        modelListResult
                        testResult
                        if let saveError {
                            Text(saveError)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.failure)
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(String(localized: "WHAT AI NEVER DOES"))
                    Text(String(
                        localized: "AI output is only ever shown as a dismissible hint. Shepherd never submits a review, approves, merges or comments on your behalf."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            model.loadKey(
                kind: environment.settings.cloudProviderKind,
                store: environment.secretStore
            )
            await model.loadModelsIfConfigured(settings: environment.settings)
        }
        .onChange(of: environment.settings.cloudProviderKind) { _, kind in
            model.loadKey(kind: kind, store: environment.secretStore)
            environment.refreshIntelligence()
        }
        .onChange(of: environment.settings.intelligenceMode) { _, _ in
            environment.refreshIntelligence()
        }
    }

    // MARK: - OpenAI-compatible endpoint (ADR 0007, tier 3b)

    /// The preset picker. Selecting a preset fills in its base URL; "Custom" keeps the typed one.
    private var endpointPresetPicker: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Endpoint"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 74, alignment: .leading)
            Picker(String(localized: "Endpoint"), selection: presetBinding) {
                ForEach(IntelligenceEndpointPreset.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
        }
    }

    /// The endpoint's note plus, where the endpoint issues keys, a link to its console.
    @ViewBuilder
    private var endpointNote: some View {
        if let note = preset.note {
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let url = preset.consoleURL, let title = preset.consoleLinkTitle {
            Link(title, destination: url)
                .font(.system(size: 11))
        }
    }

    /// The model row: a picker once the endpoint's list is loaded, the free-text field otherwise.
    @ViewBuilder
    private var modelField: some View {
        if modelOptions.isEmpty {
            LabeledField(
                label: String(localized: "Model"),
                placeholder: preset.modelPlaceholder,
                text: openAIModelBinding
            )
        } else {
            HStack(spacing: 8) {
                Text(String(localized: "Model"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 74, alignment: .leading)
                Picker(String(localized: "Model"), selection: openAIModelBinding) {
                    ForEach(modelOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                Button(String(localized: "Type a name")) { model.forgetLoadedModels() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accentText)
            }
        }
    }

    /// What the last model-discovery run produced.
    @ViewBuilder
    private var modelListResult: some View {
        switch model.modelListState {
        case .idle, .loading:
            EmptyView()
        case .loaded(let models):
            Text(String(localized: "\(models.count) models offered by this endpoint."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        case .failed(let message):
            Label(
                String(localized: "Could not load models: \(message)"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.pending)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The model ids the picker should offer, empty when the free-text field is in charge.
    private var modelOptions: [String] {
        model.modelOptions(selected: environment.settings.openAICompatibleModel)
    }

    /// The endpoint preset currently selected.
    private var preset: IntelligenceEndpointPreset {
        environment.settings.openAICompatiblePreset
    }

    /// The placeholder of the key field, which differs per endpoint.
    private var apiKeyPlaceholder: String {
        environment.settings.cloudProviderKind == .openAICompatible
            ? preset.apiKeyPlaceholder
            : "sk-…"
    }

    @ViewBuilder
    private var testResult: some View {
        switch model.testState {
        case .idle, .running:
            EmptyView()
        case .success(let message):
            Label(message, systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.success)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.failure)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeBinding: Binding<IntelligenceMode> {
        Binding(
            get: { environment.settings.intelligenceMode },
            set: { environment.settings.intelligenceMode = $0 }
        )
    }

    private var kindBinding: Binding<CloudProviderKind> {
        Binding(
            get: { environment.settings.cloudProviderKind },
            set: { environment.settings.cloudProviderKind = $0 }
        )
    }

    private var presetBinding: Binding<IntelligenceEndpointPreset> {
        Binding(
            get: { environment.settings.openAICompatiblePreset },
            set: { selection in
                environment.settings.applyEndpointPreset(selection)
                // A list loaded from the previous endpoint would offer models the new one does
                // not serve, so it is dropped rather than shown for the wrong host.
                model.forgetLoadedModels()
                environment.refreshIntelligence()
            }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { environment.settings.openAICompatibleBaseURL },
            set: { url in
                environment.settings.openAICompatibleBaseURL = url
                // Editing the URL by hand must not leave the picker claiming a preset the
                // field contradicts — and typing a preset's URL selects that preset.
                environment.settings.openAICompatiblePreset = .matching(baseURL: url)
                model.forgetLoadedModels()
            }
        )
    }

    private var openAIModelBinding: Binding<String> {
        Binding(
            get: { environment.settings.openAICompatibleModel },
            set: { environment.settings.openAICompatibleModel = $0 }
        )
    }

    private var anthropicModelBinding: Binding<String> {
        Binding(
            get: { environment.settings.anthropicModel },
            set: { environment.settings.anthropicModel = $0 }
        )
    }

    private var keyBinding: Binding<String> {
        Binding(get: { model.apiKeyField }, set: { model.apiKeyField = $0 })
    }
}

// MARK: - Appearance

/// Dark, light or system.
struct AppearanceSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsPage {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "APPEARANCE"))
                    Picker(String(localized: "Appearance"), selection: appearanceBinding) {
                        ForEach(AppearanceSetting.allCases) { setting in
                            Text(setting.title).tag(setting)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(String(
                        localized: "The diff viewer follows the same setting: the theme is pushed into Monaco over the bridge."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(String(localized: "DIFF VIEWER"))
                    HStack(spacing: 12) {
                        Text(String(localized: "Font size"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Slider(value: fontBinding, in: 10...18, step: 1)
                        Text("\(Int(environment.settings.diffFontSize)) pt")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                    Toggle(String(localized: "Wrap long lines"), isOn: wrapBinding)
                    Toggle(String(localized: "Show diffs inline instead of side by side"), isOn: inlineBinding)
                }
            }
        }
    }

    private var appearanceBinding: Binding<AppearanceSetting> {
        Binding(
            get: { environment.settings.appearance },
            set: {
                environment.settings.appearance = $0
                environment.applyAppearance()
            }
        )
    }

    private var fontBinding: Binding<Double> {
        Binding(
            get: { environment.settings.diffFontSize },
            set: { environment.settings.diffFontSize = $0 }
        )
    }

    private var wrapBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.diffWrapsLines },
            set: { environment.settings.diffWrapsLines = $0 }
        )
    }

    private var inlineBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.diffUsesInlineMode },
            set: { environment.settings.diffUsesInlineMode = $0 }
        )
    }
}

// MARK: - Shared chrome

/// The scrolling container every settings tab uses.
struct SettingsPage<Content: View>: View {
    /// The tab's content.
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }
}

/// A labelled text field used by the intelligence tab.
struct LabeledField: View {
    /// The field's label.
    let label: String
    /// The placeholder text.
    let placeholder: String
    /// The bound value.
    let text: Binding<String>

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 74, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
