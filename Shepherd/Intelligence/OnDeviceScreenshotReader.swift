import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import ShepherdCore

// MARK: - Guided-generation type

/// The shape the on-device model fills in for a description's screenshots.
///
/// One list of sentences. No status and no confidence field — ADR 0026's rule for anything a model
/// writes beside a colleague's work: the model says what it sees, never whether the pull request
/// does what it claims.
@Generable
struct OnDeviceScreenshotObservations {
    /// What the screenshots show.
    @Guide(description: "One short sentence per thing the screenshots visibly show, at most five. Only what is visible in the images.")
    var observations: [String]
}

// MARK: - The reader

/// Tier 2 for a description's screenshots (ADR 0038 item 4, ADR 0007's 2026-09-22 amendment).
///
/// The images reach the model as `Attachment` values built from a `CGImage` — the SDK's own
/// spelling; ADR 0038's `Attachment(ImageAttachmentContent(...))` has no public initialiser —
/// on `SystemLanguageModel.default`, whose `capabilities` contain `.vision` on macOS 27.
///
/// The pre-flight differs from every other on-device request in one way, and it is the SDK's
/// doing: `tokenCount(for:)` throws for a prompt with an attachment (`ModelManagerError 1001`,
/// 2026-09-22), so the images cannot be measured. The text is measured as always, and each image
/// is charged ``tokensPerImage`` — the spike measured 35 to 165 tokens an image, from 256 pixels up
/// to 2,048, because the framework scales every image down itself. The images are decoded here at
/// most ``maximumPixelEdge`` pixels on their long side anyway, so a 40-megapixel capture does not
/// sit in memory for the length of the request.
struct OnDeviceScreenshotReader: DescriptionScreenshotReading {
    /// What one image is charged against the window. Half again what the largest measured cost.
    static let tokensPerImage = 256

    /// The longest side an image is decoded at.
    static let maximumPixelEdge = 1_024

    /// The most pixels an image may declare before it is refused undecoded.
    ///
    /// Fifty megapixels is well above any real screenshot (a 6K display is 20 MP). The cap exists
    /// for the image that is small on the wire and enormous in memory — a PNG of one colour that
    /// declares 100,000 × 100,000 compresses to kilobytes — because ImageIO may allocate the full
    /// bitmap to produce even a thumbnail. The dimensions come from the header, before anything
    /// is decoded.
    static let maximumPixels = 50_000_000

    /// How many tokens the answer may use: five short sentences, with room to finish the last.
    static let responseTokens = 400

    init() {}

    func availability() async -> OnDeviceAvailability {
        if let reason = OnDeviceProvider.unavailabilityReason(for: .prose) {
            return .unavailable(reason)
        }
        guard OnDeviceUseCase.prose.model().capabilities.contains(.vision) else {
            return .unavailable(String(localized: "The on-device model on this Mac cannot read images."))
        }
        return .available
    }

    func read(_ request: ScreenshotReadingRequest, images: [Data]) async throws -> ScreenshotReading {
        // An image that does not decode (an SVG, a truncated download) is dropped here rather than
        // failing the reading, and the request is narrowed to the ones that did — so the caption
        // says "1 of 2" rather than claiming both were read.
        let decoded = zip(request.images.indices, images).compactMap { index, data in
            Self.image(from: data).map { (index, $0) }
        }
        guard !decoded.isEmpty else {
            throw IntelligenceError.unavailable(String(localized: "None of the screenshots could be opened."))
        }
        let labels = decoded.map { request.label(at: $0.0) }
        let session = try await Self.preflight(request.promptText, imageCount: decoded.count)
        let generated: OnDeviceScreenshotObservations
        do {
            generated = try await session.respond(
                generating: OnDeviceScreenshotObservations.self,
                options: GenerationOptions(
                    temperature: OnDeviceGeneration.structuredTemperature,
                    maximumResponseTokens: Self.responseTokens
                )
            ) {
                request.promptText
                for (offset, image) in decoded.enumerated() {
                    Attachment(image.1).label(labels[offset])
                }
            }.content
        } catch {
            throw LanguageModelErrors.mapped(error)
        }
        let observations = generated.observations
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !observations.isEmpty else { throw IntelligenceError.malformedResponse }
        return ScreenshotReading(
            observations: observations,
            readCount: decoded.count,
            totalCount: request.totalCount
        )
    }

    // MARK: - Decoding

    /// The image in some bytes, at most ``maximumPixelEdge`` on its long side, or `nil` when they
    /// are not an image ImageIO can decode or declare more than ``maximumPixels``.
    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width.multipliedReportingOverflow(by: height).partialValue <= maximumPixels,
              !width.multipliedReportingOverflow(by: height).overflow
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Pre-flight

    /// Availability, vision, budget and session in one decision.
    private static func preflight(_ prompt: String, imageCount: Int) async throws -> LanguageModelSession {
        let useCase = OnDeviceUseCase.prose
        if let reason = OnDeviceProvider.unavailabilityReason(for: useCase) {
            throw IntelligenceError.unavailable(reason)
        }
        let model = useCase.model()
        guard model.capabilities.contains(.vision) else {
            throw IntelligenceError.unavailable(
                String(localized: "The on-device model on this Mac cannot read images.")
            )
        }
        let text = instructions + "\n" + prompt
        let counted = try? await model.tokenCount(for: text)
        let budget = OnDeviceProvider.budget.limited(
            toContextSize: model.contextSize,
            reservedForResponse: OnDeviceGeneration.reservedResponseTokens
        )
        let tokens = budget.measured(text) { $0 == text ? counted : nil } + imageCount * tokensPerImage
        guard tokens <= budget.maxTokens else {
            throw IntelligenceError.digestTooLarge(tokens: tokens, limit: budget.maxTokens)
        }
        return LanguageModelSession(model: model, instructions: instructions)
    }

    // MARK: - Instructions

    /// The session's instructions.
    ///
    /// The sentence that carries the product rule is the second: say only what is visible. The
    /// model is not shown the description (``ShepherdCore/ScreenshotReadingRequest`` explains
    /// why), and it is told not to judge, because "the new layout looks correct" is a verdict about
    /// a colleague's work wearing a description's clothes.
    static var instructions: String {
        """
        You describe the screenshots a pull request's author attached to its description, for a \
        reviewer deciding what to look at. Say only what is visible in the images — the screens, \
        controls, text and states they show, and what differs between them when there is more than \
        one. Never guess what the code does, never say whether the change is correct or looks \
        good, and never tell the reviewer what to do. Keep each sentence short. Write in \
        \(IntelligencePrompt.answerLanguageName).
        """
    }
}
