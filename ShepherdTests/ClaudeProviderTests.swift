import ClaudeForFoundationModels
import ShepherdCore
import XCTest
@testable import Shepherd

/// The Claude backend's own decisions: which model an id becomes, and what it declares for one
/// the package has never heard of (ADR 0038, item 1).
final class ClaudeProviderTests: XCTestCase {
    func testAKnownIDBecomesThePackagesModelWithItsCapabilityMatrix() {
        let model = ClaudeBackend.model(forID: "claude-haiku-4-5")
        XCTAssertEqual(model, .haiku4_5)
        XCTAssertTrue(model.capabilities.structuredOutput, "guided generation is what every request here relies on")
    }

    func testTheDefaultModelIsAKnownOne() {
        XCTAssertTrue(ClaudeBackend.knownModels.contains { $0.id == ClaudeProvider.defaultModelID })
    }

    func testAnUnknownIDIsSentAsTypedAndDeclaresOnlyGuidedGeneration() {
        let model = ClaudeBackend.model(forID: "  claude-experimental-x \n")
        XCTAssertEqual(model.id, "claude-experimental-x")
        XCTAssertTrue(model.capabilities.structuredOutput)
        XCTAssertFalse(model.capabilities.samplingParams, "a sampling parameter a model rejects is a hard error, so none is declared")
        XCTAssertFalse(model.capabilities.imageInput)
        XCTAssertTrue(model.capabilities.effortLevels.isEmpty)
    }

    func testAnEmptyModelIDFallsBackToTheDefault() {
        let provider = ClaudeProvider(apiKey: "k", modelID: "   ")
        XCTAssertEqual(provider.backend.languageModel.model.id, ClaudeProvider.defaultModelID)
        XCTAssertEqual(ClaudeBackend.model(forID: ""), .haiku4_5)
    }

    func testThePreflightWindowIsTheTierBudgetNotTheModelsWindow() {
        XCTAssertEqual(ClaudeBackend.contextSize, TokenBudget.cloud.maxTokens + ResponseCaps.claude.reserved)
        XCTAssertLessThan(ClaudeBackend.contextSize, ClaudeBackend.modelContextSize)
        let capped = ClaudeProvider.budget.limited(
            toContextSize: ClaudeBackend.contextSize,
            reservedForResponse: ResponseCaps.claude.reserved
        )
        XCTAssertEqual(capped.maxTokens, TokenBudget.cloud.maxTokens, "the pre-flight caps where the digest builders cap")
    }

    func testClaudeGetsItsOwnAnswerLengthsAndAReserveThatCoversThem() {
        let caps = ResponseCaps.claude
        XCTAssertGreaterThan(caps.reserved, max(caps.summary, caps.focus, caps.draft, caps.diagnosis))
        XCTAssertGreaterThan(caps.diagnosis, ResponseCaps.onDevice.diagnosis)
    }

    func testTheBackendIsTheAnthropicTierWithTheCloudBudget() async {
        let provider = ClaudeProvider(apiKey: "k", modelID: "claude-sonnet-5")
        XCTAssertEqual(provider.kind, .anthropic)
        XCTAssertEqual(ClaudeProvider.budget, TokenBudget.cloud)
        let available = await provider.isAvailable
        XCTAssertTrue(available, "a key is checked for by the router; the backend has nothing to refuse")
    }

    func testTheClaudeWindowIsMeasuredByEstimateAgainstTheKnownContext() async {
        let backend = ClaudeBackend(apiKey: "k", modelID: "claude-haiku-4-5")
        let context = await backend.context(of: backend.languageModel, measuring: "some prompt")
        XCTAssertEqual(context.contextSize, ClaudeBackend.contextSize)
        XCTAssertNil(context.measure("some prompt"), "no tokenizer on this side of the network")
    }

    func testAMissingCredentialNamesTheField() {
        let mapped = ClaudeBackend(apiKey: "", modelID: "").mapped(ClaudeError.missingCredential)
        XCTAssertEqual(mapped as? IntelligenceError, .notConfigured("Anthropic API key"))
    }
}
