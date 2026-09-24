import ShepherdCore
import ShepherdPersistence
import SwiftUI

/// Provider picker, BYOK configuration, connection test (ADR 0007).
struct IntelligenceSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    /// The settings model.
    let model: SettingsModel
    @State private var saveError: String?

    var body: some View {
        SettingsPage {
            Section {
                Picker(selection: modeBinding) {
                    ForEach(IntelligenceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text(String(localized: "Provider"))
                    Text(environment.settings.intelligenceMode.explanation)
                }
                if environment.settings.intelligenceMode != .off,
                   let reason = OnDeviceProvider.unavailabilityReason() {
                    Text(String(localized: "On-device model: \(reason)"))
                        .foregroundStyle(Theme.pending)
                }
            } footer: {
                // What AI never does: the promise stays on the page, and what a model's look-ups
                // may do is one click away.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    SettingsNote(String(localized: "Shepherd never reviews, approves, merges or comments for you."))
                    InfoButton(neverDoesDetail)
                }
            }

            if environment.settings.intelligenceMode == .onDeviceAndCloud {
                bringYourOwnKeySection
                if environment.settings.cloudProviderKind == .openAICompatible {
                    sovereigntyPolicySection
                }
            }

            semanticSearchSection

            structuredTriageSection

            spotlightSection

            screenshotSection
        }
        .task {
            model.loadKey(
                kind: environment.settings.cloudProviderKind,
                store: environment.secretStore
            )
            // The country field shows the stored policy rather than an empty line (plan §3.K).
            model.loadSovereigntyPolicy(settings: environment.settings)
            await model.loadModelsIfConfigured(settings: environment.settings)
        }
        .onChange(of: environment.settings.cloudProviderKind) { _, kind in
            model.loadKey(kind: kind, store: environment.secretStore)
            environment.refreshIntelligence()
        }
        .onChange(of: environment.settings.intelligenceMode) { _, _ in
            environment.refreshIntelligence()
        }
        .onChange(of: environment.settings.screenshotReadingEnabled) { _, _ in
            environment.refreshIntelligence()
        }
    }

    /// The long form of the provider section's footer.
    ///
    /// The second paragraph is about the *tools* a model may call (plan §0.3): the registry is
    /// three reads, fixed at compile time, and the promise would be worth less if the model could
    /// look things up without the reader knowing what "look up" is allowed to mean.
    private var neverDoesDetail: String {
        String(
            localized: "AI output is only ever shown as a dismissible hint. Shepherd never submits a review, approves, merges or comments on your behalf."
        ) + "\n\n" + String(
            localized: "When the model looks something up, it can only read — the checks, a log, a file. It cannot comment, approve, merge or start an agent."
        )
    }

    /// A section title with an ⓘ beside it, for the sections whose privacy story is longer than
    /// one subtitle.
    private func sectionHeader(_ title: String, info: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(info)
        }
    }

    // MARK: - Bring your own key (ADR 0007, tier 3)

    /// The endpoint, model and key rows, on screen only while the API-key tier is chosen.
    private var bringYourOwnKeySection: some View {
        Section {
            Picker(String(localized: "Kind"), selection: kindBinding) {
                ForEach(CloudProviderKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            if environment.settings.cloudProviderKind == .openAICompatible {
                endpointPresetPicker
                if let url = preset.consoleURL, let title = preset.consoleLinkTitle {
                    Link(title, destination: url)
                }
                LabeledField(
                    label: String(localized: "Base URL"),
                    placeholder: "https://api.example.eu/v1",
                    text: baseURLBinding
                )
                modelField
            } else {
                LabeledField(
                    label: String(localized: "Model"),
                    placeholder: ClaudeProvider.defaultModelID,
                    text: anthropicModelBinding
                )
            }

            SecureField(
                String(localized: "API key"),
                text: keyBinding,
                prompt: Text(apiKeyPlaceholder)
            )

            HStack(spacing: 8) {
                if model.testState == .running || model.modelListState == .loading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if environment.settings.cloudProviderKind == .openAICompatible {
                    Button(String(localized: "Load models")) {
                        Task { await model.loadModels(settings: environment.settings) }
                    }
                    .disabled(
                        model.modelListState == .loading
                            || !model.canLoadModels(settings: environment.settings)
                    )
                }
                Button(String(localized: "Test connection")) {
                    Task { await model.testConnection(settings: environment.settings) }
                }
                .disabled(model.testState == .running)
                Button(String(localized: "Save key")) {
                    saveError = model.saveKey(
                        kind: environment.settings.cloudProviderKind,
                        store: environment.secretStore
                    )
                    environment.refreshIntelligence()
                }
            }

            modelListResult
            testResult
            if let saveError {
                Text(saveError)
                    .font(Theme.type(.caption))
                    .foregroundStyle(Theme.failure)
            }
        } header: {
            Text(String(localized: "Bring your own key"))
        } footer: {
            SettingsNote(String(localized: "The key stays in your Keychain and is sent only to this endpoint."))
        }
    }

    // MARK: - Screenshots (ADR 0038 item 4)

    /// The switch for the one host this feature adds, off by default (CONTRIBUTING.md).
    private var screenshotSection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { environment.settings.screenshotReadingEnabled },
                    set: { environment.settings.screenshotReadingEnabled = $0 }
                )
            ) {
                Text(String(localized: "Read screenshots in descriptions on this Mac"))
                Text(String(localized: "Downloaded only when you ask, and never sent anywhere else."))
            }
            .disabled(environment.settings.intelligenceMode == .off)
        } header: {
            sectionHeader(
                String(localized: "Screenshots"),
                info: String(
                    localized: "Adds a button to the summary card. Pressing it downloads up to two of the description's screenshots from GitHub's upload host (private-user-images.githubusercontent.com) and reads them with the model on this Mac. The images are never sent anywhere else, and nothing is downloaded until you press it."
                )
            )
        }
    }

    // MARK: - Semantic ⌘K search (ADR 0019)

    /// The one toggle, one status line and one button the search index needs.
    ///
    /// It sits on the Intelligence tab because that is where a user looks for "how does Shepherd
    /// understand my pull requests", and it states its own privacy answer because that answer is
    /// different from every other one on the tab: it never uses a provider. "Does typing in ⌘K
    /// send my diffs somewhere" is a question a user is entitled to have answered where they are
    /// standing, so the short form is the toggle's subtitle and the long form is behind the ⓘ.
    ///
    /// On by default, which no other intelligence-shaped setting is (ADR 0019 argues it).
    private var semanticSearchSection: some View {
        Section {
            Toggle(isOn: semanticSearchBinding) {
                Text(String(localized: "Semantic search index"))
                Text(String(localized: "⌘K finds pull requests and issues by meaning, on this Mac."))
            }
            LabeledContent {
                HStack(spacing: 8) {
                    if environment.search.status.isIndexing {
                        ProgressView().controlSize(.small)
                    }
                    Button(String(localized: "Rebuild index")) {
                        environment.rebuildSearchIndex()
                    }
                    .disabled(
                        !environment.settings.semanticSearchEnabled
                            || environment.session == nil
                    )
                }
            } label: {
                Text(String(localized: "Index"))
                Text(searchIndexStatusLine)
            }
        } header: {
            sectionHeader(
                String(localized: "Semantic search"),
                info: String(
                    localized: "The index is built on this Mac with Apple's on-device embeddings and kept in the local database. It never uses an AI endpoint, even when you have configured one. Switched off, the index is emptied and ⌘K matches words only."
                )
            )
        }
    }

    /// "412 pull requests indexed · 806 KB · last updated 4 minutes ago", and the honest variants.
    ///
    /// Assembled from ``SearchIndexStatus`` rather than from the database directly, so the line
    /// says what the *running* index holds. The two states worth naming are switched-off and
    /// "no model on this Mac": both leave search working on words, and a row that showed a size
    /// of zero without saying why would read as a bug.
    private var searchIndexStatusLine: String {
        let status = environment.search.status
        guard environment.settings.semanticSearchEnabled else {
            return String(localized: "Off — ⌘K matches words only, and nothing is stored.")
        }
        if let reason = status.embeddingUnavailabilityReason {
            return reason
        }
        let sizeText = ByteCountFormatter.string(
            fromByteCount: Int64(status.vectorByteCount),
            countStyle: .file
        )
        guard let last = status.lastIndexedAt else {
            guard status.isIndexing else { return String(localized: "Nothing indexed yet.") }
            return String(localized: "Indexing \(status.documentCount) pull requests and \(status.issueDocumentCount) issues…")
        }
        return String(
            localized: "\(status.embeddedCount) of \(status.documentCount) pull requests and \(status.issueEmbeddedCount) of \(status.issueDocumentCount) issues indexed · \(sizeText) · last updated \(RelativeDate.long(last))."
        )
    }

    // MARK: - Structured triage (plan §3.A)

    /// The toggle and the status line the on-device classifier needs.
    ///
    /// Directly under the search section because it is the same promise about the same kind of
    /// work: on-device, over rows Shepherd already has, going nowhere. The difference is stated
    /// rather than implied — this one *needs a model*, so with the provider switched off it can do
    /// nothing, and the ⓘ says so instead of leaving a toggle that looks broken.
    ///
    /// There is deliberately no *Rebuild* button beside the search index's: a verdict is
    /// invalidated by the document hash exactly as a vector is, so the only way to want one
    /// rebuilt is to want them all rebuilt — which is what switching the toggle off and on does,
    /// in two clicks, without a third control that means the same thing.
    private var structuredTriageSection: some View {
        Section {
            Toggle(isOn: structuredTriageBinding) {
                Text(String(localized: "Classify pull requests"))
                Text(String(localized: "Kind of change and risk, to sort the inbox by. Stays on this Mac."))
            }
        } header: {
            sectionHeader(
                String(localized: "Structured triage"),
                info: String(
                    localized: "Each pull request gets a kind, a risk and a one-sentence reason from the on-device model. Nothing acts on it: it never approves, merges or comments. With the provider set to Off nothing is classified, and the inbox keeps its risk hints either way."
                )
            )
        } footer: {
            SettingsNote(structuredTriageStatusLine)
        }
    }

    /// "142 of 210 pull requests classified", and the honest variants.
    ///
    /// Assembled from ``TriageStatus`` rather than from the database, so the line says what the
    /// *running* classifier holds — the search index's arrangement. Three states are worth naming
    /// and each one leaves the inbox usable: switched off, no model (or the tiers off), and a
    /// pass in progress. The unavailability reason is shown in the model's own words, because
    /// "Apple Intelligence is turned off in System Settings" is a sentence the user can act on
    /// and "unavailable" is not.
    private var structuredTriageStatusLine: String {
        let status = environment.triage.status
        guard environment.settings.structuredTriageEnabled else {
            return String(localized: "Off — no verdicts are stored, and the inbox shows risk hints only.")
        }
        if let reason = status.unavailabilityReason {
            return reason
        }
        guard status.classifiedCount > 0 else {
            guard status.isClassifying else { return String(localized: "Nothing classified yet.") }
            return String(localized: "Classifying \(status.rowCount) pull requests…")
        }
        return String(
            localized: "\(status.classifiedCount) of \(status.rowCount) pull requests classified on this Mac."
        )
    }

    private var structuredTriageBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.structuredTriageEnabled },
            // Nothing is applied here, exactly like the two switches above: `ShepherdApp`
            // watches the flag and calls `applyStructuredTriageSetting()`, so the toggle and an
            // arriving settings document reach the coordinator through one route (ADR 0023).
            set: { environment.settings.structuredTriageEnabled = $0 }
        )
    }

    // MARK: - Pull requests in Spotlight (ADR 0021)

    /// The one toggle and one status line the Spotlight export needs.
    ///
    /// A section of its own, directly under the search index, because it answers the question
    /// that one raises next: the index is work Shepherd does *inside* its own database, and this
    /// is the only thing on the tab that puts pull-request data **outside** it. The subtitle and
    /// the ⓘ say exactly what leaves and what does not, in the UI rather than only in ADR 0021 —
    /// "what of mine ends up in the system index" is a question a user is entitled to have
    /// answered where they are standing.
    private var spotlightSection: some View {
        Section {
            Toggle(isOn: spotlightBinding) {
                Text(String(localized: "Show pull requests in Spotlight"))
                Text(String(localized: "Find inbox pull requests with ⌘Space. Only titles and metadata go there."))
            }
        } header: {
            sectionHeader(
                String(localized: "Spotlight"),
                info: String(
                    localized: "Spotlight's index is macOS's, not Shepherd's — so only the title, owner/repo#number, labels, repository and agent are exported. Descriptions, diffs, review comments and your drafts never leave the local database. Switching this off deletes every pull request Shepherd put there."
                )
            )
        } footer: {
            SettingsNote(spotlightStatusLine)
        }
    }

    /// "412 pull requests in Spotlight", and the honest variants.
    private var spotlightStatusLine: String {
        let status = environment.spotlight.status
        // Comes first, on or off: the promise a pending deletion breaks is the same in both states.
        if status.domainDeletionPending {
            return String(
                localized: "Spotlight has not confirmed the removal yet — Shepherd asks again on the next sync."
            )
        }
        guard environment.settings.spotlightExportEnabled else {
            return String(localized: "Off — Shepherd's pull requests are not in Spotlight.")
        }
        guard status.itemCount > 0 else {
            guard status.isExporting else { return String(localized: "Nothing exported yet.") }
            return String(localized: "Exporting…")
        }
        return String(localized: "\(status.itemCount) pull requests in Spotlight.")
    }

    private var spotlightBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.spotlightExportEnabled },
            // Nothing is applied here, exactly as above: `ShepherdApp` watches the flag and calls
            // `applySpotlightSetting()`, so the toggle and an arriving settings document reach the
            // exporter through one route (ADR 0021).
            set: { environment.settings.spotlightExportEnabled = $0 }
        )
    }

    private var semanticSearchBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.semanticSearchEnabled },
            // Nothing is applied here: `ShepherdApp` watches the flag and calls
            // `applySemanticSearchSetting()`, so the toggle and an arriving settings document
            // reach the coordinator through one route (ADR 0017's rule, ADR 0019's feature).
            set: { environment.settings.semanticSearchEnabled = $0 }
        )
    }

    // MARK: - OpenAI-compatible endpoint (ADR 0007, tier 3b)

    /// The preset picker, with the endpoint's own note as its subtitle. Selecting a preset fills
    /// in its base URL; "Custom" keeps the typed one.
    private var endpointPresetPicker: some View {
        Picker(selection: presetBinding) {
            ForEach(IntelligenceEndpointPreset.allCases) { option in
                Text(option.title).tag(option)
            }
        } label: {
            Text(String(localized: "Endpoint"))
            if let note = preset.note {
                Text(note)
            }
        }
    }

    /// The model row: a picker once the endpoint's list is loaded, the free-text field otherwise.
    ///
    /// A picker row carries the endpoint's own sovereignty badge when it published one —
    /// `FR · zero retention · eu` — as its subtitle, because "where does this model run" is the
    /// question somebody on this tier is most likely picking a model *by*, and it is published
    /// per model rather than per endpoint (plan §3.K). A plain OpenAI endpoint publishes nothing
    /// and the row is the id, exactly as before.
    @ViewBuilder
    private var modelField: some View {
        if modelOptions.isEmpty {
            LabeledField(
                label: String(localized: "Model"),
                placeholder: preset.modelPlaceholder,
                text: openAIModelBinding
            )
        } else {
            LabeledContent {
                HStack(spacing: 8) {
                    Picker(String(localized: "Model"), selection: openAIModelBinding) {
                        ForEach(modelOptions, id: \.self) { option in
                            Text(model.modelPickerLabel(for: option)).tag(option)
                        }
                    }
                    .labelsHidden()
                    Button(String(localized: "Type a name")) { model.forgetLoadedModels() }
                        .buttonStyle(.link)
                }
            } label: {
                Text(String(localized: "Model"))
                if let badge = model.sovereigntyBadge(for: environment.settings.openAICompatibleModel) {
                    Text(badge)
                }
            }
        }
    }

    // MARK: - The optional sovereignty policy (plan §3.K)

    /// The two fields that pin a request to a country set and to a zero-retention operator.
    ///
    /// Directly under the endpoint, because that is what they are about — and with the copy that
    /// makes them honest behind the ⓘ: they are **part of the request body**, so an endpoint that
    /// understands them honours them and an endpoint that does not refuses the request in its own
    /// words. There is no probing, no capability list and no per-endpoint behaviour behind them;
    /// the one endpoint-specific thing on screen is the preset's own sentence saying what it does
    /// with them, which is copy rather than a code path (ADR 0007's 2026-09-03 amendment).
    ///
    /// Both fields ship empty and off, and in that state nothing about the request changes at
    /// all — which is why they can sit here without an opt-in toggle above them.
    private var sovereigntyPolicySection: some View {
        Section {
            TextField(
                String(localized: "Countries"),
                text: sovereigntyCountriesBinding,
                prompt: Text(verbatim: "DE, FR")
            )
            Toggle(String(localized: "Require zero retention"), isOn: zeroRetentionBinding)
        } header: {
            sectionHeader(String(localized: "Where the model runs"), info: sovereigntyDetail)
        } footer: {
            SettingsNote(String(localized: "Optional. Two-letter country codes, comma-separated."))
        }
    }

    /// What the two policy fields do to the request, plus the selected endpoint's own sentence.
    private var sovereigntyDetail: String {
        let general = String(
            localized: "Both are sent as part of the request. An endpoint that cannot meet them refuses the request rather than answering from somewhere else. Left empty and off, nothing extra is sent."
        )
        guard let note = preset.sovereigntyNote else { return general }
        return general + "\n\n" + note
    }

    /// The country list as the comma-separated text the field edits.
    ///
    /// The text is the model's and the parsed list is the setting's — see
    /// ``SettingsModel/sovereigntyCountriesField``, which explains why a binding that re-derived
    /// the string from the array would eat the comma as it was typed.
    private var sovereigntyCountriesBinding: Binding<String> {
        Binding(
            get: { model.sovereigntyCountriesField },
            set: { text in
                model.applySovereigntyCountries(text, settings: environment.settings)
                environment.refreshIntelligence()
            }
        )
    }

    private var zeroRetentionBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.openAICompatibleZeroRetention },
            set: { isOn in
                environment.settings.openAICompatibleZeroRetention = isOn
                environment.refreshIntelligence()
            }
        )
    }

    /// What the last model-discovery run produced.
    @ViewBuilder
    private var modelListResult: some View {
        switch model.modelListState {
        case .idle, .loading:
            EmptyView()
        case .loaded(let models):
            Text(String(localized: "\(models.count) models offered by this endpoint."))
                .font(Theme.type(.caption))
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(
                String(localized: "Could not load models: \(message)"),
                systemImage: "exclamationmark.triangle"
            )
            .font(Theme.type(.caption))
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

    private var testResult: some View {
        AsyncActionStatusLine(state: model.testState)
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
                // The picker follows the field on its own — the preset is derived from the base
                // URL — so editing by hand cannot leave it claiming an endpoint the field
                // contradicts, and typing a preset's URL selects that preset.
                environment.settings.openAICompatibleBaseURL = url
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
