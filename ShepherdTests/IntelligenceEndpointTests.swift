import Foundation
import XCTest

@testable import Shepherd

/// The OpenAI-compatible endpoint layer: URL building, the endpoint presets, and the model-list
/// parser (ADR 0007, tier 3b).
///
/// The fixtures are realistic `GET {base}/models` bodies: the documented OpenAI shape, the same
/// shape with extra per-gateway fields, and the ways a gateway can answer with something
/// unusable. None of these tests touch the network — the request itself is a thin wrapper around
/// the parser, and the parser is where the variation lives.
final class IntelligenceEndpointTests: XCTestCase {
    // MARK: - Fixtures

    private enum Fixture {
        /// The documented shape, with the fields Shepherd deliberately ignores present.
        static let konduitList = """
            {"object":"list","data":[
              {"id":"qwen3-32b","object":"model","created":1756000000,"owned_by":"konduit"},
              {"id":"mistral-small-3","object":"model","created":1756000001,"owned_by":"konduit"}
            ]}
            """

        /// Blank ids, an entry without an `id` at all, duplicates, and padded ids.
        static let messyList = """
            {"object":"list","data":[
              {"id":"  first-model  "},
              {"object":"model","created":1},
              {"id":""},
              {"id":"second-model"},
              {"id":"first-model"}
            ]}
            """

        /// Well-formed, but the account has nothing enabled.
        static let emptyList = """
            {"object":"list","data":[]}
            """

        /// A gateway that answers `/models` with its own, different shape.
        static let foreignShape = """
            {"models":["a","b"]}
            """

        /// An error envelope served with a 200, which some gateways do.
        static let errorEnvelope = """
            {"error":{"message":"invalid api key","type":"authentication_error"}}
            """

        static let notJSON = "<html><body>404</body></html>"

        /// The extended shape (plan §3.K): OpenAI's four fields, then `pricing` and the
        /// `sovereignty` block — including one entry whose block is half-filled and one that
        /// carries none at all, because a list is allowed to be mixed.
        static let sovereignList = """
            {"object":"list","data":[
              {"id":"scaleway/mistral-small-3.2@fp8","object":"model","created":1756000000,
               "owned_by":"scaleway","display_name":"Mistral Small 3.2",
               "pricing":{"currency":"EUR","unit":"micro_eur_per_million_tokens",
                          "input":150000,"output":450000},
               "sovereignty":{"hosting_country":"FR","ownership":"France","zero_retention":true,
                              "tier":"eu-owned","note":null,
                              "certifications":[{"type":"iso27001","scope":"platform",
                                                 "evidence_url":"https://example.eu/iso"}]}},
              {"id":"ionos/llama-3.3-70b","object":"model","owned_by":"ionos",
               "sovereignty":{"hosting_country":"de","zero_retention":false,
                              "certifications":[]}},
              {"id":"plain/model","object":"model"}
            ]}
            """

        /// A gateway that sends the key but nothing inside it.
        static let emptySovereignty = """
            {"object":"list","data":[{"id":"a","sovereignty":{}}]}
            """
    }

    private func modelIDs(_ json: String) throws -> [String] {
        try OpenAIModelsResponse.modelIDs(in: Data(json.utf8))
    }

    private func models(_ json: String) throws -> [OpenAIModelsResponse.Model] {
        try OpenAIModelsResponse.models(in: Data(json.utf8))
    }

    // MARK: - Model list parsing

    func testTheDocumentedShapeIsParsedInTheEndpointsOwnOrder() throws {
        XCTAssertEqual(try modelIDs(Fixture.konduitList), ["qwen3-32b", "mistral-small-3"])
    }

    func testIDsAreTrimmedAndDeduplicatedAndUnusableEntriesDropped() throws {
        XCTAssertEqual(try modelIDs(Fixture.messyList), ["first-model", "second-model"])
    }

    func testAnEmptyListIsAnErrorRatherThanAnEmptyPicker() {
        XCTAssertThrowsError(try modelIDs(Fixture.emptyList)) { error in
            XCTAssertEqual(error as? IntelligenceError, .noModelsListed)
        }
    }

    func testAForeignShapeIsRejected() {
        for json in [Fixture.foreignShape, Fixture.errorEnvelope, Fixture.notJSON] {
            XCTAssertThrowsError(try modelIDs(json)) { error in
                XCTAssertEqual(error as? IntelligenceError, .malformedResponse)
            }
        }
    }

    func testEveryFailureCarriesAUserReadableReason() {
        XCTAssertNotNil(IntelligenceError.noModelsListed.errorDescription)
        XCTAssertNotEqual(
            IntelligenceError.noModelsListed.errorDescription,
            IntelligenceError.malformedResponse.errorDescription
        )
    }

    // MARK: - Sovereignty and pricing in the model list (plan §3.K)

    func testThePlainOpenAIShapeStillCarriesNoSovereigntyAndNoPricing() throws {
        let entries = try models(Fixture.konduitList)
        XCTAssertEqual(entries.map(\.id), ["qwen3-32b", "mistral-small-3"])
        for entry in entries {
            XCTAssertNil(entry.sovereignty, "an endpoint that publishes none decodes to none")
            XCTAssertNil(entry.pricing)
            XCTAssertNil(entry.sovereigntyBadge, "and shows no badge")
        }
    }

    func testTheExtendedShapeKeepsSovereigntyAndPricingPerEntry() throws {
        let entries = try models(Fixture.sovereignList)
        XCTAssertEqual(
            entries.map(\.id),
            ["scaleway/mistral-small-3.2@fp8", "ionos/llama-3.3-70b", "plain/model"],
            "the endpoint's own order is kept"
        )

        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.displayName, "Mistral Small 3.2")
        let sovereignty = try XCTUnwrap(first.sovereignty)
        XCTAssertEqual(sovereignty.hostingCountry, "FR")
        XCTAssertEqual(sovereignty.ownership, "France")
        XCTAssertEqual(sovereignty.zeroRetention, true)
        XCTAssertEqual(sovereignty.tier, "eu-owned")
        XCTAssertNil(sovereignty.note, "an explicit null is still nothing to say")
        XCTAssertEqual(sovereignty.certificationTypes, ["iso27001"])
        XCTAssertEqual(
            sovereignty.certifications?.first?.evidenceURL,
            "https://example.eu/iso"
        )
        // Built from the same expression rather than from an English literal: the middle part is
        // the one translated word in the badge, and a test that hard-coded it would fail on a
        // German runner for the wrong reason.
        let zeroRetention = String(localized: "zero retention")
        XCTAssertEqual(first.sovereigntyBadge, "FR · \(zeroRetention) · eu-owned")

        let pricing = try XCTUnwrap(first.pricing)
        XCTAssertEqual(pricing.currency, "EUR")
        XCTAssertEqual(pricing.unit, "micro_eur_per_million_tokens")
        XCTAssertEqual(pricing.input, 150_000)
        XCTAssertEqual(pricing.output, 450_000)

        // A half-filled block is still worth a badge, and a `false` zero-retention flag is not a
        // claim about retention — it is simply not in the badge.
        XCTAssertEqual(entries[1].sovereigntyBadge, "DE")
        XCTAssertNil(entries[1].pricing)
        // A mixed list is fine: the entry that published nothing shows nothing.
        XCTAssertNil(entries[2].sovereignty)
        XCTAssertNil(entries[2].sovereigntyBadge)
    }

    func testAnEmptySovereigntyBlockShowsNoBadgeRatherThanAnEmptyOne() throws {
        let entries = try models(Fixture.emptySovereignty)
        let sovereignty = try XCTUnwrap(entries.first?.sovereignty)
        XCTAssertTrue(sovereignty.isEmpty)
        XCTAssertNil(sovereignty.badge)
        XCTAssertNil(entries.first?.sovereigntyBadge)
    }

    func testTheExtraBlocksNeverCostTheListItself() throws {
        // The ids are what the picker needs, and they come back from the extended shape exactly
        // as they come back from the plain one.
        XCTAssertEqual(
            try modelIDs(Fixture.sovereignList),
            ["scaleway/mistral-small-3.2@fp8", "ionos/llama-3.3-70b", "plain/model"]
        )
        // A block that is not the documented shape at all is dropped, not fatal.
        let hostile = """
            {"data":[{"id":"a","sovereignty":"not an object","pricing":7}]}
            """
        XCTAssertEqual(try modelIDs(hostile), ["a"])
    }

    // MARK: - URL building

    func testBaseNormalizationTrimsWhitespaceAndTrailingSlashes() {
        XCTAssertEqual(
            OpenAICompatibleProvider.normalizedBase("  https://api.konduit.eu/v1///  "),
            "https://api.konduit.eu/v1"
        )
        XCTAssertNil(OpenAICompatibleProvider.normalizedBase(""))
        XCTAssertNil(OpenAICompatibleProvider.normalizedBase("   "))
        XCTAssertNil(OpenAICompatibleProvider.normalizedBase("api.konduit.eu/v1"))
        XCTAssertNil(OpenAICompatibleProvider.normalizedBase("ftp://api.konduit.eu/v1"))
    }

    func testBothEndpointsAreBuiltFromTheSameBase() {
        let base = "https://api.konduit.eu/v1/"
        XCTAssertEqual(
            OpenAICompatibleProvider.completionsURL(base: base)?.absoluteString,
            "https://api.konduit.eu/v1/chat/completions"
        )
        XCTAssertEqual(
            OpenAICompatibleProvider.modelsURL(base: base)?.absoluteString,
            "https://api.konduit.eu/v1/models"
        )
        XCTAssertNil(OpenAICompatibleProvider.modelsURL(base: "not a url"))
    }

    // MARK: - Presets

    func testEveryPresetExceptCustomCarriesAUsableBaseURL() throws {
        for preset in IntelligenceEndpointPreset.allCases where preset != .custom {
            let baseURL = try XCTUnwrap(preset.baseURL)
            XCTAssertNotNil(
                OpenAICompatibleProvider.completionsURL(base: baseURL),
                "\(preset.rawValue) must produce a completions URL"
            )
            XCTAssertNotNil(OpenAICompatibleProvider.modelsURL(base: baseURL))
            XCTAssertFalse(preset.title.isEmpty)
            XCTAssertFalse(preset.apiKeyPlaceholder.isEmpty)
            XCTAssertEqual(IntelligenceEndpointPreset.matching(baseURL: baseURL), preset)
        }
        XCTAssertNil(IntelligenceEndpointPreset.custom.baseURL)
    }

    func testTheKonduitPresetPointsAtTheEUGatewayAndItsConsole() {
        XCTAssertEqual(IntelligenceEndpointPreset.konduitEU.baseURL, "https://api.konduit.eu/v1")
        XCTAssertEqual(
            IntelligenceEndpointPreset.konduitEU.consoleURL?.absoluteString,
            "https://console.konduit.eu"
        )
        XCTAssertNotNil(IntelligenceEndpointPreset.konduitEU.consoleLinkTitle)
        XCTAssertNotNil(IntelligenceEndpointPreset.konduitEU.note)
        // A gateway that always checks the bearer token must not be probed without a key.
        XCTAssertFalse(IntelligenceEndpointPreset.konduitEU.allowsKeylessDiscovery)
        XCTAssertTrue(IntelligenceEndpointPreset.ollamaLocal.allowsKeylessDiscovery)
    }

    func testABaseURLIsMatchedBackToItsPresetToleratingSlashesAndCase() {
        XCTAssertEqual(
            IntelligenceEndpointPreset.matching(baseURL: "https://api.konduit.eu/v1"),
            .konduitEU
        )
        XCTAssertEqual(
            IntelligenceEndpointPreset.matching(baseURL: " https://API.Konduit.EU/v1/ "),
            .konduitEU
        )
        XCTAssertEqual(
            IntelligenceEndpointPreset.matching(baseURL: "http://localhost:11434/v1"),
            .ollamaLocal
        )
        XCTAssertEqual(
            IntelligenceEndpointPreset.matching(baseURL: "https://api.example.eu/v1"),
            .custom
        )
        XCTAssertEqual(IntelligenceEndpointPreset.matching(baseURL: ""), .custom)
    }

    // MARK: - Persistence (non-secret only — ADR 0007)

    @MainActor
    func testSelectingAPresetFillsInItsBaseURLAndIsRemembered() throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let settings = AppSettings(defaults: defaults)
        // A fresh install has no base URL, so there is no endpoint to name.
        XCTAssertEqual(settings.openAICompatiblePreset, .custom)

        settings.applyEndpointPreset(.konduitEU)
        XCTAssertEqual(settings.openAICompatibleBaseURL, "https://api.konduit.eu/v1")
        XCTAssertEqual(settings.openAICompatiblePreset, .konduitEU)

        // "Custom" keeps the URL that is already there rather than clearing the field. The
        // preset is derived from that URL, so it goes on naming the endpoint the field points
        // at — picking "Custom" is not a way to point at Konduit while denying it.
        settings.applyEndpointPreset(.custom)
        XCTAssertEqual(settings.openAICompatibleBaseURL, "https://api.konduit.eu/v1")
        XCTAssertEqual(settings.openAICompatiblePreset, .konduitEU)

        settings.applyEndpointPreset(.ollamaLocal)
        let restored = AppSettings(defaults: defaults)
        // Only the URL is persisted; the preset comes back with it.
        XCTAssertEqual(restored.openAICompatibleBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(restored.openAICompatiblePreset, .ollamaLocal)
    }

    @MainActor
    func testTypingAnEndpointsURLByHandSelectsThatPreset() throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.openAICompatibleBaseURL = " https://API.Konduit.EU/v1/ "
        XCTAssertEqual(settings.openAICompatiblePreset, .konduitEU)

        // Editing it away drops back to "Custom" in the same breath — there is no stored copy
        // that could keep claiming the old endpoint.
        settings.openAICompatibleBaseURL = "https://api.example.eu/v1"
        XCTAssertEqual(settings.openAICompatiblePreset, .custom)
    }

    @MainActor
    func testAnInstallWithoutAStoredPresetDerivesItFromTheBaseURL() throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        // What a build from before presets existed left behind: a base URL, no preset.
        defaults.set("https://api.konduit.eu/v1/", forKey: "intelligence.openaiCompatible.baseURL")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.openAICompatiblePreset, .konduitEU)
        // The stored URL is left exactly as the user typed it.
        XCTAssertEqual(settings.openAICompatibleBaseURL, "https://api.konduit.eu/v1/")
    }

    @MainActor
    func testNoAPIKeyEverReachesUserDefaults() throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.applyEndpointPreset(.konduitEU)
        settings.openAICompatibleModel = "first-model"

        let model = SettingsModel()
        // The editor holds the key; only the Keychain ever receives it (ADR 0007).
        model.apiKeyField = "kdt-not-a-real-key"

        let stored = defaults.dictionaryRepresentation()
        XCTAssertFalse(
            stored.values.contains { ($0 as? String)?.contains("kdt-") == true },
            "an API key must never reach UserDefaults"
        )
        // The non-secret half is persisted, so Settings can restore the endpoint.
        XCTAssertEqual(
            stored["intelligence.openaiCompatible.baseURL"] as? String,
            "https://api.konduit.eu/v1"
        )
        // The preset is not persisted at all — it is derived from the URL above, so there is no
        // second copy that could disagree with it.
        XCTAssertNil(stored["intelligence.openaiCompatible.preset"])
    }

    // MARK: - The Settings model's discovery gate

    @MainActor
    func testDiscoveryIsGatedOnAUsableEndpointAndAKeyWhenOneIsNeeded() throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let settings = AppSettings(defaults: defaults)
        let model = SettingsModel()

        // Anthropic has no `/models` route in this shape at all.
        settings.intelligenceMode = .onDeviceAndCloud
        settings.cloudProviderKind = .anthropic
        XCTAssertFalse(model.canLoadModels(settings: settings))

        settings.cloudProviderKind = .openAICompatible
        settings.applyEndpointPreset(.konduitEU)
        XCTAssertFalse(model.canLoadModels(settings: settings), "no key yet")

        model.apiKeyField = "kdt-not-a-real-key"
        XCTAssertTrue(model.canLoadModels(settings: settings))

        // A local server needs no key, but it still needs a usable URL.
        model.apiKeyField = ""
        settings.applyEndpointPreset(.ollamaLocal)
        XCTAssertTrue(model.canLoadModels(settings: settings))
        settings.openAICompatibleBaseURL = "localhost:11434"
        XCTAssertFalse(model.canLoadModels(settings: settings))
    }

    @MainActor
    func testALoadedListBecomesThePickerAndPreselectsOnlyAnEmptyField() async throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.intelligenceMode = .onDeviceAndCloud
        settings.cloudProviderKind = .openAICompatible
        settings.applyEndpointPreset(.konduitEU)

        let model = SettingsModel()
        // Nothing loaded yet: the free-text field is in charge.
        XCTAssertEqual(model.modelOptions(selected: "anything"), [])

        let endpoint = StubEndpoint(models: ["first-model", "second-model"])
        await model.loadModels(settings: settings, from: endpoint)
        XCTAssertEqual(model.modelListState, .loaded(["first-model", "second-model"]))
        // An empty model field is filled in with the endpoint's first offer, nothing else is.
        XCTAssertEqual(settings.openAICompatibleModel, "first-model")

        settings.openAICompatibleModel = "hand-typed"
        await model.loadModels(settings: settings, from: endpoint)
        XCTAssertEqual(settings.openAICompatibleModel, "hand-typed")
        // A model the endpoint did not list stays selectable, or the picker would silently
        // change the configuration.
        XCTAssertEqual(
            model.modelOptions(selected: " hand-typed "),
            ["hand-typed", "first-model", "second-model"]
        )
        XCTAssertEqual(model.modelOptions(selected: "second-model"), ["first-model", "second-model"])

        model.forgetLoadedModels()
        XCTAssertEqual(model.modelListState, .idle)
        XCTAssertEqual(model.modelOptions(selected: "first-model"), [])
    }

    @MainActor
    func testAFailedLoadLeavesTheFreeTextFieldAndSaysWhy() async throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.cloudProviderKind = .openAICompatible
        settings.applyEndpointPreset(.konduitEU)
        settings.openAICompatibleModel = "hand-typed"

        let model = SettingsModel()
        await model.loadModels(
            settings: settings,
            from: StubEndpoint(failure: .http(status: 401, message: "invalid api key"))
        )

        let reason = try XCTUnwrap(
            IntelligenceError.http(status: 401, message: "invalid api key").errorDescription
        )
        XCTAssertEqual(model.modelListState, .failed(reason))
        XCTAssertEqual(model.modelOptions(selected: "hand-typed"), [], "free text stays in charge")
        XCTAssertEqual(settings.openAICompatibleModel, "hand-typed")
    }

    @MainActor
    func testTheModelPickerCarriesTheEndpointsOwnSovereigntyBadge() async throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.intelligenceMode = .onDeviceAndCloud
        settings.cloudProviderKind = .openAICompatible
        settings.applyEndpointPreset(.konduitEU)

        let model = SettingsModel()
        await model.loadModels(
            settings: settings,
            from: StubEndpoint(entries: try models(Fixture.sovereignList))
        )

        XCTAssertEqual(
            model.modelListState,
            .loaded(["scaleway/mistral-small-3.2@fp8", "ionos/llama-3.3-70b", "plain/model"])
        )
        XCTAssertEqual(model.sovereigntyBadge(for: "ionos/llama-3.3-70b"), "DE")
        XCTAssertEqual(
            model.modelPickerLabel(for: "ionos/llama-3.3-70b"),
            "ionos/llama-3.3-70b — DE"
        )
        // A model the endpoint published nothing about is its id and nothing else.
        XCTAssertNil(model.sovereigntyBadge(for: "plain/model"))
        XCTAssertEqual(model.modelPickerLabel(for: "plain/model"), "plain/model")

        // A list from the previous endpoint would describe models the new one does not serve, so
        // the badges go with it.
        model.forgetLoadedModels()
        XCTAssertNil(model.sovereigntyBadge(for: "ionos/llama-3.3-70b"))
    }

    @MainActor
    func testAnEndpointThatListsOnlyIDsProducesNoBadgesAndStillWorks() async throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.cloudProviderKind = .openAICompatible
        settings.applyEndpointPreset(.ollamaLocal)

        let model = SettingsModel()
        // The seam's default implementation: a conformance that only has ids says only ids.
        await model.loadModels(settings: settings, from: StubEndpoint(models: ["a", "b"]))
        XCTAssertEqual(model.modelListState, .loaded(["a", "b"]))
        XCTAssertNil(model.sovereigntyBadge(for: "a"))
        XCTAssertEqual(model.modelPickerLabel(for: "a"), "a")
    }

    // MARK: - The optional sovereignty policy in Settings (plan §3.K)

    @MainActor
    func testCountryCodesAreUppercasedAndBlanksDropped() {
        XCTAssertEqual(SettingsModel.countryCodes(in: "de, fr"), ["DE", "FR"])
        XCTAssertEqual(SettingsModel.countryCodes(in: " DE ,, ,FR,"), ["DE", "FR"])
        XCTAssertEqual(SettingsModel.countryCodes(in: ""), [])
        XCTAssertEqual(SettingsModel.countryCodes(in: " , "), [])
    }

    @MainActor
    func testThePolicyFieldKeepsWhatWasTypedWhileTheSettingHoldsTheCodes() throws {
        let suite = "shepherd.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        let settings = AppSettings(defaults: defaults)
        // Empty and off on a fresh install: in that state nothing extra is ever sent.
        XCTAssertEqual(settings.openAICompatibleSovereigntyCountries, [])
        XCTAssertFalse(settings.openAICompatibleZeroRetention)

        let model = SettingsModel()
        // Mid-typing: the comma has to survive, or the field would delete it as it is typed.
        model.applySovereigntyCountries("de, ", settings: settings)
        XCTAssertEqual(model.sovereigntyCountriesField, "de, ")
        XCTAssertEqual(settings.openAICompatibleSovereigntyCountries, ["DE"])

        model.applySovereigntyCountries("de, fr", settings: settings)
        XCTAssertEqual(settings.openAICompatibleSovereigntyCountries, ["DE", "FR"])
        settings.openAICompatibleZeroRetention = true

        // Non-secret, so it is persisted and comes back — and the field is seeded from it.
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.openAICompatibleSovereigntyCountries, ["DE", "FR"])
        XCTAssertTrue(restored.openAICompatibleZeroRetention)
        let reopened = SettingsModel()
        reopened.loadSovereigntyPolicy(settings: restored)
        XCTAssertEqual(reopened.sovereigntyCountriesField, "DE, FR")
    }

    func testOnlyTheKonduitPresetClaimsToUnderstandThePolicy() {
        // The single place a preset may show extra UI, and it is copy: nothing in the provider
        // branches on it (ADR 0007's 2026-09-03 amendment).
        XCTAssertNotNil(IntelligenceEndpointPreset.konduitEU.sovereigntyNote)
        XCTAssertNil(IntelligenceEndpointPreset.ollamaLocal.sovereigntyNote)
        XCTAssertNil(IntelligenceEndpointPreset.custom.sovereigntyNote)
    }

    // MARK: - The served-by headers (plan §3.K)

    func testTheServedByHeadersAreReadCaseInsensitivelyAndOptionally() {
        let both = ServedBy.parse(headers: [
            "konduit-provider": "scaleway",
            "Konduit-Deployment": "scaleway/mistral-small-3.2@fp8",
        ])
        XCTAssertEqual(both?.operatorName, "scaleway")
        XCTAssertEqual(both?.deployment, "scaleway/mistral-small-3.2@fp8")
        // The caption is the operator only: the deployment id is long, changes with a variant,
        // and is carried for the code that may pin it rather than for a reviewer to read.
        XCTAssertEqual(both?.caption, "scaleway")

        // The operator alone is a sentence; the deployment alone is not.
        XCTAssertEqual(
            ServedBy.parse(headers: ["Konduit-Provider": " ovhcloud "])?.caption,
            "ovhcloud"
        )
        XCTAssertNil(ServedBy.parse(headers: ["Konduit-Deployment": "x/y"]))
        XCTAssertNil(ServedBy.parse(headers: ["Konduit-Provider": "   "]))
        // An endpoint that sends neither header says nothing, and the caption is unchanged.
        XCTAssertNil(ServedBy.parse(headers: [:]))
        XCTAssertNil(ServedBy.parse(headers: ["Content-Type": "application/json"]))
    }

    func testTheCompletionRecordsWhoServedItWhenTheEndpointSaidSo() async throws {
        let report = IntelligenceEndpointReport()
        let transport = RecordingHTTPTransport([
            .init(
                body: #"{"choices":[{"message":{"content":"ok"}}]}"#,
                headers: [
                    "Konduit-Provider": "scaleway",
                    "Konduit-Deployment": "scaleway/mistral-small-3.2@fp8",
                ]
            ),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "m",
            apiKey: "k",
            transport: transport,
            report: report
        )

        let text = try await provider.complete(system: "s", user: "u")
        XCTAssertEqual(text, "ok")
        let servedBy = await report.servedBy
        XCTAssertEqual(servedBy?.caption, "scaleway")
        XCTAssertEqual(servedBy?.deployment, "scaleway/mistral-small-3.2@fp8")
    }

    func testAnEndpointThatSendsNoHeadersLeavesTheReportEmpty() async throws {
        let report = IntelligenceEndpointReport()
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "m",
            apiKey: "k",
            transport: RecordingHTTPTransport([
                .init(body: #"{"choices":[{"message":{"content":"ok"}}]}"#),
            ]),
            report: report
        )
        _ = try await provider.complete(system: "s", user: "u")
        let servedBy = await report.servedBy
        XCTAssertNil(servedBy)
    }

    // MARK: - Retry-After, once (plan §3.K)

    func testRetryAfterIsHonouredOnlyForADelayAPersonWouldSitThrough() {
        XCTAssertEqual(IntelligenceRetryAfter.delay(headers: ["Retry-After": "5"]), 5)
        XCTAssertEqual(IntelligenceRetryAfter.delay(headers: ["retry-after": "30"]), 30)
        // Clamped up, so a `0` still lets the far side breathe.
        XCTAssertEqual(IntelligenceRetryAfter.delay(headers: ["Retry-After": "0"]), 1)
        // Over the ceiling is a refusal, not an instruction: the 429 surfaces as it is.
        XCTAssertNil(IntelligenceRetryAfter.delay(headers: ["Retry-After": "31"]))
        XCTAssertNil(IntelligenceRetryAfter.delay(headers: ["Retry-After": "600"]))
        XCTAssertNil(IntelligenceRetryAfter.delay(headers: ["Retry-After": "soon"]))
        XCTAssertNil(IntelligenceRetryAfter.delay(headers: ["Retry-After": "  "]))
        XCTAssertNil(IntelligenceRetryAfter.delay(headers: [:]))
    }

    func testAnHTTPDateIsHonouredOnlyInsideTheSameCeiling() throws {
        // The clock is a parameter, so the two branches are testable without waiting.
        let now = Date(timeIntervalSince1970: 1_756_800_000)
        func header(_ offset: TimeInterval) -> [String: String] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            return ["Retry-After": formatter.string(from: now.addingTimeInterval(offset))]
        }
        let soon = try XCTUnwrap(IntelligenceRetryAfter.delay(headers: header(10), now: now))
        XCTAssertEqual(soon, 10, accuracy: 1)
        XCTAssertNil(IntelligenceRetryAfter.delay(headers: header(120), now: now))
        // A date already gone is a clock disagreement, not a refusal to answer.
        XCTAssertEqual(IntelligenceRetryAfter.delay(headers: header(-60), now: now), 1)
    }

    func testA429WithAUsableRetryAfterIsRetriedExactlyOnce() async throws {
        let transport = RecordingHTTPTransport([
            .init(body: #"{"error":{"message":"slow down"}}"#, status: 429,
                  headers: ["Retry-After": "1"]),
            .init(body: #"{"choices":[{"message":{"content":"second time"}}]}"#),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "m",
            apiKey: "k",
            transport: transport
        )

        let answer = try await provider.complete(system: "s", user: "u")
        XCTAssertEqual(answer, "second time")
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2, "sent once, waited, sent once more")
    }

    func testASecond429IsSurfacedRatherThanRetriedAgain() async {
        let transport = RecordingHTTPTransport([
            .init(body: #"{"error":{"message":"slow down"}}"#, status: 429,
                  headers: ["Retry-After": "1"]),
            .init(body: #"{"error":{"message":"still limited"}}"#, status: 429,
                  headers: ["Retry-After": "1"]),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "m",
            apiKey: "k",
            transport: transport
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("a second 429 must not be waited out")
        } catch {
            XCTAssertEqual(
                error as? IntelligenceError,
                .http(status: 429, message: "still limited")
            )
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2, "never a loop")
    }

    func testA429WithoutAUsableRetryAfterIsTodaysErrorAndNothingElse() async {
        let transport = RecordingHTTPTransport([
            .init(body: #"{"error":{"message":"slow down"}}"#, status: 429,
                  headers: ["Retry-After": "3600"]),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "m",
            apiKey: "k",
            transport: transport
        )

        do {
            _ = try await provider.complete(system: "s", user: "u")
            XCTFail("an hour is a failure, not a wait")
        } catch {
            XCTAssertEqual(error as? IntelligenceError, .http(status: 429, message: "slow down"))
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
    }

    func testCancellingDuringTheRetryWaitAbortsRatherThanRetrying() async {
        let transport = RecordingHTTPTransport([
            .init(body: #"{"error":{"message":"slow down"}}"#, status: 429,
                  headers: ["Retry-After": "30"]),
            .init(body: #"{"choices":[{"message":{"content":"never asked for"}}]}"#),
        ])
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "m",
            apiKey: "k",
            transport: transport
        )

        let task = Task { try await provider.complete(system: "s", user: "u") }
        // The first request has to have happened before the wait can be interrupted.
        while await transport.callCount == 0 { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled wait produces no answer")
        } catch {
            XCTAssertTrue(IntelligenceRouter.isCancellation(error))
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1, "the second request was never made")
    }

    // MARK: - The request body (plan §3.K)

    private func requestBody(
        countries: [String] = [],
        zeroRetention: Bool = false,
        streaming: Bool = false
    ) throws -> [String: Any] {
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.eu/v1",
            model: "m",
            apiKey: "k",
            sovereigntyCountries: countries,
            requiresZeroRetention: zeroRetention
        )
        let data = try provider.completionRequestBody(
            system: "s",
            user: "u",
            streaming: streaming
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testNoPolicyMeansNoProviderKeyAtAll() throws {
        let body = try requestBody()
        XCTAssertNil(
            body["provider"],
            "an empty object is refused by the gateways that read this field, so it is absent"
        )
        XCTAssertNil(body["stream"])
        XCTAssertNil(body["stream_options"])
        XCTAssertEqual(body["model"] as? String, "m")
    }

    func testAPolicyIsSentOnlyForTheHalvesTheUserActuallySet() throws {
        let countriesOnly = try requestBody(countries: ["de", " fr "])
        let policy = try XCTUnwrap(countriesOnly["provider"] as? [String: Any])
        XCTAssertEqual(policy["countries"] as? [String], ["DE", "FR"])
        XCTAssertNil(policy["zero_retention"], "`false` and absent mean the same thing")

        let retentionOnly = try requestBody(zeroRetention: true)
        let second = try XCTUnwrap(retentionOnly["provider"] as? [String: Any])
        XCTAssertEqual(second["zero_retention"] as? Bool, true)
        XCTAssertNil(second["countries"])

        let both = try requestBody(countries: ["DE"], zeroRetention: true)
        let third = try XCTUnwrap(both["provider"] as? [String: Any])
        XCTAssertEqual(third["countries"] as? [String], ["DE"])
        XCTAssertEqual(third["zero_retention"] as? Bool, true)

        // Blanks are not a policy.
        XCTAssertNil(try requestBody(countries: ["", "  "])["provider"])
    }

    func testAStreamedRequestAsksForTheFinalUsageChunk() throws {
        let body = try requestBody(streaming: true)
        XCTAssertEqual(body["stream"] as? Bool, true)
        let options = try XCTUnwrap(body["stream_options"] as? [String: Any])
        XCTAssertEqual(options["include_usage"] as? Bool, true)
        // And the two are independent: usage is asked for whether or not a policy is set.
        XCTAssertNil(body["provider"])
    }

    // MARK: - Stubs

    /// A stubbed endpoint: the list Settings would have fetched, or the failure it would have hit.
    ///
    /// It answers with `entries` when a test gave it any, so the sovereignty half of discovery can
    /// be driven without a network; a test that only cares about ids sets `models` and gets the
    /// seam's default implementation, which is the shape every plain endpoint has.
    private struct StubEndpoint: ModelListing {
        var models: [String] = []
        var entries: [OpenAIModelsResponse.Model]? = nil
        var failure: IntelligenceError? = nil

        func availableModels() async throws -> [String] {
            if let failure { throw failure }
            if let entries { return entries.compactMap(\.id) }
            return models
        }

        func availableModelEntries() async throws -> [OpenAIModelsResponse.Model] {
            if let failure { throw failure }
            guard let entries else {
                return models.map { OpenAIModelsResponse.Model(id: $0) }
            }
            return entries
        }
    }
}

/// A transport that answers from a script, headers included, and counts what it was asked.
///
/// An `actor` for the reason ``IntelligenceToolLoopTests``' own double is one: the provider
/// calls it from its own task and the test reads the count back from another, which is the
/// whole assertion for "retried exactly once".
private actor RecordingHTTPTransport: IntelligenceTransport {
    /// One recorded answer.
    struct Answer: Sendable {
        /// The response body.
        var body: String
        /// The HTTP status. Defaults to `200`.
        var status: Int = 200
        /// The response headers, spelled as a server would.
        var headers: [String: String] = [:]
    }

    /// Asked for one more answer than the script has.
    struct Exhausted: Error {}

    private var answers: [Answer]
    /// How many requests were made, which is what "once" is asserted against.
    private(set) var callCount = 0

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    func post(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> (data: Data, status: Int) {
        let response = try await send(url: url, headers: headers, body: body)
        return (response.data, response.status)
    }

    func send(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> IntelligenceHTTPResponse {
        callCount += 1
        guard !answers.isEmpty else { throw Exhausted() }
        let answer = answers.removeFirst()
        return IntelligenceHTTPResponse(
            data: Data(answer.body.utf8),
            status: answer.status,
            headers: answer.headers
        )
    }
}
