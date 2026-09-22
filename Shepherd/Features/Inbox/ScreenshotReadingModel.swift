import Foundation
import Observation
import ShepherdCore

/// What the summary card shows about a description's screenshots.
enum ScreenshotReadingState: Equatable {
    /// Nothing to offer: no GitHub-hosted screenshots, or no model on this Mac that reads images.
    case none
    /// *Read screenshots* can be pressed; the count is how many the description attaches.
    case offered(count: Int)
    /// The download and the reading are under way.
    case reading
    /// What the model said.
    case read(ScreenshotReading)
    /// Why there is no reading, in one sentence.
    case failed(String)
}

/// Holds the screenshot reading for the pull request in the inbox's detail panel
/// (ADR 0038 item 4, ADR 0007's 2026-09-22 amendment).
///
/// Four things about it are decisions rather than mechanics:
///
/// - **The click is the only trigger.** The text summary starts when a row is selected — `j`/`k`
///   through thirty rows asks thirty times — so the screenshots are not part of it: selecting a
///   row costs one Markdown scan of a description the inbox already holds, and a download happens
///   only in ``read(detail:fetcher:)``, behind the card's own button.
/// - **Its only model dependency is ``DescriptionScreenshotReading``.** No router, no base URL, no
///   key — the screenshots never reach a cloud tier because nothing here can name one.
/// - **Two reads, then the images.** The rendered description (`api.github.com`, with the token)
///   is fetched at click time rather than cached, because its signed links expire within
///   minutes; the images are fetched from those links without the token.
/// - **Nothing is stored.** Bytes and answer live as long as the selection does; selecting another
///   row, or a new description, forgets them. A failure is not retried by anything but another
///   click on another selection, ADR 0007's no-retry rule.
@MainActor
@Observable
final class ScreenshotReadingModel {
    /// What the card draws.
    private(set) var state: ScreenshotReadingState = .none

    /// The pull request and description the state belongs to.
    @ObservationIgnored private var key: String?
    /// The description's attachments, from the last refresh.
    @ObservationIgnored private var attachments: [DescriptionImage] = []
    /// The reader, as the caller had it at the last refresh.
    @ObservationIgnored private var reader: (any DescriptionScreenshotReading)?
    /// The reader's answer about this Mac, once asked. Forgotten when the reader comes or goes.
    @ObservationIgnored private var availability: OnDeviceAvailability?
    /// The reading in flight.
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {}

    /// Re-reads which screenshots the description has, and forgets a reading of another one.
    ///
    /// Cheap and offline: a Markdown scan, plus — once per reader — the availability question.
    /// A refresh for the pull request and description already held changes nothing, so a reading
    /// survives the detail's own background refetch.
    /// - Parameters:
    ///   - detail: The selected pull request, or `nil`.
    ///   - reader: The on-device reader, or `nil` with the tiers off.
    func refresh(detail: PullRequestDetail?, reader: (any DescriptionScreenshotReading)?) async {
        let newKey = detail.map { "\($0.id)|\($0.bodyMarkdown.hashValue)" }
        let readerChanged = (self.reader == nil) != (reader == nil)
        self.reader = reader
        guard newKey != key || readerChanged else { return }

        task?.cancel()
        task = nil
        key = newKey
        state = .none
        if readerChanged { availability = nil }
        attachments = detail.map { DescriptionImages.attachments(inMarkdown: $0.bodyMarkdown) } ?? []
        guard let reader, !attachments.isEmpty else { return }

        if availability == nil {
            availability = await reader.availability()
        }
        // The question was asked across a suspension: the selection may have moved meanwhile.
        guard key == newKey, availability == .available, state == .none else { return }
        state = .offered(count: attachments.count)
    }

    /// Downloads at most ``ShepherdCore/DescriptionImages/maximumImages`` screenshots and reads
    /// them on this Mac.
    /// - Parameters:
    ///   - detail: The selected pull request — the one ``refresh(detail:reader:)`` last saw.
    ///   - fetcher: The signed-in client, or `nil` when signed out.
    func read(detail: PullRequestDetail, fetcher: (any DescriptionImageFetching)?) {
        guard case .offered = state, let reader else { return }
        guard let fetcher else {
            state = .failed(String(localized: "Sign in to GitHub to read the screenshots."))
            return
        }
        let expected = key
        let request = ScreenshotReadingRequest(title: detail.summary.title, attachments: attachments)
        let repo = detail.summary.repo
        let number = detail.summary.number
        state = .reading
        task = Task { [weak self] in
            let outcome = await Self.run(request, repo: repo, number: number, fetcher: fetcher, reader: reader)
            guard let self, !Task.isCancelled, self.key == expected else { return }
            self.state = outcome
        }
    }

    /// The whole read: the rendered description, the images, the model.
    private nonisolated static func run(
        _ request: ScreenshotReadingRequest,
        repo: RepoRef,
        number: Int,
        fetcher: any DescriptionImageFetching,
        reader: any DescriptionScreenshotReading
    ) async -> ScreenshotReadingState {
        let html: String
        do {
            html = try await fetcher.pullRequestBodyHTML(repo: repo, number: number)
        } catch {
            return .failed(String(localized: "GitHub did not return the description's screenshots."))
        }
        // An attachment GitHub rendered as a video, or not at all, has no link and is left out;
        // one whose download fails is left out too. The request is narrowed to what arrived, so
        // the caption counts what was read rather than what was hoped for.
        var images: [Data] = []
        var kept: [DescriptionImage] = []
        for source in DescriptionImages.signedSources(for: request.images, inBodyHTML: html) {
            guard !Task.isCancelled else { return .none }
            if let data = try? await fetcher.descriptionImage(at: source.url) {
                images.append(data)
                kept.append(source.image)
            }
        }
        guard !images.isEmpty else {
            return .failed(String(localized: "The screenshots could not be downloaded."))
        }
        do {
            return .read(try await reader.read(request.keeping(kept), images: images))
        } catch let error as IntelligenceError {
            return .failed(message(for: error))
        } catch {
            return .failed(String(localized: "The screenshots could not be read on this Mac."))
        }
    }

    /// The card's sentence for a failure.
    ///
    /// Not ``IntelligenceError/errorDescription`` for the two window cases: that sentence offers a
    /// cloud provider, and there is none for screenshots.
    nonisolated static func message(for error: IntelligenceError) -> String {
        switch error {
        case .unavailable(let reason):
            return reason
        case .contextExceeded, .digestTooLarge:
            return String(localized: "The screenshots do not fit the on-device model's window.")
        default:
            return error.errorDescription
                ?? String(localized: "The screenshots could not be read on this Mac.")
        }
    }
}
