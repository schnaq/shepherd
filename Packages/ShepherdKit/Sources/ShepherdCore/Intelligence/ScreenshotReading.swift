import Foundation

/// What the on-device model is asked when a reviewer reads a description's screenshots
/// (ADR 0038 item 4, ADR 0007's 2026-09-22 amendment).
///
/// Pure, so the text the model sees and what the card says about coverage are asserted on Linux.
/// The prompt is deliberately thin: the pull request's title for orientation, and each image's
/// label. **Not** the description itself — it is where the claims are, and a model handed "this
/// makes the button blue" beside a screenshot writes "the button is blue" whether or not it is.
/// What the card promises is what the images show, so the images are the evidence and the title
/// is the only words.
public struct ScreenshotReadingRequest: Sendable, Hashable {
    /// The longest title the prompt carries, in characters.
    public static let maximumTitleCharacters = 200

    /// The pull request's title, capped.
    public var title: String
    /// The screenshots that will be read, at most ``DescriptionImages/maximumImages``.
    public var images: [DescriptionImage]
    /// How many screenshots the description attaches in all.
    public var totalCount: Int

    /// Builds the request for a description's attachments.
    /// - Parameters:
    ///   - title: The pull request's title.
    ///   - attachments: Every attachment the description has, in order.
    public init(title: String, attachments: [DescriptionImage]) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = String(trimmed.prefix(Self.maximumTitleCharacters))
        self.images = Array(attachments.prefix(DescriptionImages.maximumImages))
        self.totalCount = attachments.count
    }

    /// The same request for fewer images — the ones that actually downloaded.
    ///
    /// ``totalCount`` is kept, so a reading of one of three still says *of three*.
    /// - Parameter kept: The images to keep; only ones already in ``images`` survive, in order.
    /// - Returns: The narrowed request.
    public func keeping(_ kept: [DescriptionImage]) -> ScreenshotReadingRequest {
        var copy = self
        copy.images = images.filter { kept.contains($0) }
        return copy
    }

    /// The label each image is attached under: its position, and its alt text when the author
    /// wrote one that says something (GitHub's upload writes the file name, `image`, or nothing).
    /// - Parameter index: The image's position in ``images``, from zero.
    public func label(at index: Int) -> String {
        let position = "Screenshot \(index + 1)"
        guard images.indices.contains(index) else { return position }
        let alt = images[index].altText
        guard Self.isMeaningful(alt) else { return position }
        return "\(position): \(alt.prefix(80))"
    }

    /// The text half of the prompt; the images follow it, each under ``label(at:)``.
    public var promptText: String {
        var lines = ["Pull request: \(title)"]
        lines.append(
            images.count == 1
                ? "One screenshot from its description follows."
                : "\(images.count) screenshots from its description follow, in order."
        )
        lines.append("Say what each screenshot shows.")
        return lines.joined(separator: "\n")
    }

    /// Whether an alt text is the author's words rather than the upload's default.
    static func isMeaningful(_ alt: String) -> Bool {
        let lowered = alt.lowercased()
        guard !lowered.isEmpty, lowered != "image", lowered != "screenshot" else { return false }
        // `Screenshot 2026-09-22 at 10.14.03`, `IMG_1234.png`, `image.png`: a file name.
        if lowered.hasPrefix("screenshot 20") || lowered.hasPrefix("img_") { return false }
        let fileExtensions = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"]
        return !fileExtensions.contains { lowered.hasSuffix($0) }
    }
}

/// What the on-device model said the screenshots show.
///
/// A list of sentences and the coverage, and nothing else — no status, no confidence, no verdict
/// about whether the pull request does what it says (ADR 0026's rule for anything a model writes
/// beside a colleague's work). The card renders it under *Read on this Mac*.
public struct ScreenshotReading: Sendable, Hashable {
    /// One sentence per thing the screenshots show, in the model's words.
    public var observations: [String]
    /// How many screenshots were read.
    public var readCount: Int
    /// How many the description attaches.
    public var totalCount: Int

    /// Creates a reading.
    /// - Parameters:
    ///   - observations: The sentences.
    ///   - readCount: How many screenshots were read.
    ///   - totalCount: How many there are.
    public init(observations: [String], readCount: Int, totalCount: Int) {
        self.observations = observations
        self.readCount = readCount
        self.totalCount = totalCount
    }

    /// Whether some of the description's screenshots were not read.
    public var isPartial: Bool { readCount < totalCount }
}
