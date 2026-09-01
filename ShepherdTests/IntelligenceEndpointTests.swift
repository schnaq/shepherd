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
    }

    private func modelIDs(_ json: String) throws -> [String] {
        try OpenAIModelsResponse.modelIDs(in: Data(json.utf8))
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

    // MARK: - Stubs

    /// A stubbed endpoint: the list Settings would have fetched, or the failure it would have hit.
    private struct StubEndpoint: ModelListing {
        var models: [String] = []
        var failure: IntelligenceError? = nil

        func availableModels() async throws -> [String] {
            if let failure { throw failure }
            return models
        }
    }
}
