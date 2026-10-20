import AppKit
import ShepherdCore
import SwiftUI

/// Renders a Markdown body: headings, lists, fenced code and quotes, not only inline formatting.
///
/// It used to be one `Text` holding `AttributedString(markdown:)` with
/// `.inlineOnlyPreservingWhitespace`, which is exactly as much Markdown as that initialiser can
/// do well — bold, italics, code spans and links — and nothing above the line. Pull request
/// bodies are mostly *not* that: an agent writes "## Summary", a bulleted list of what changed
/// and a fenced block of the command it ran, and all of it arrived on screen as literal text
/// with its own syntax still in it.
///
/// So the block level is parsed first (``ShepherdCore/MarkdownDocument``) and each block is
/// rendered as itself, with the inline parser still doing the half it is good at inside each one.
struct MarkdownText: View {
    /// The Markdown source.
    let markdown: String
    /// The node id of the post this is, which its screenshots' signed links are read by (ADR
    /// 0043); `nil` where there is none, and a screenshot stays its alt text and a link.
    let imageSubject: String?
    /// The body font size. Headings and code are derived from it.
    var size: CGFloat = 12.5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Indexed, because the same line can legitimately appear twice in one body — two
            // list items reading "- packages/ui: Jest green" under different headings are two
            // items, and identifying them by content would collapse them into one.
            ForEach(Array(ParsedMarkdown.of(markdown).blocks.enumerated()), id: \.offset) { _, part in
                view(for: part.block, runs: part.runs, cells: part.cells)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.markdownImageSubject, imageSubject)
    }

    /// One block, with `runs` its text and `cells` a table's, inline Markdown already parsed.
    @ViewBuilder
    private func view(for block: MarkdownBlock, runs: [ParsedMarkdown.Run], cells: [[[ParsedMarkdown.Run]]]) -> some View {
        switch block {
        case .heading(let level, _):
            InlineRuns(runs: runs)
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(Theme.textStrong)
                .fixedSize(horizontal: false, vertical: true)
                // Air above a heading and none below it, so a heading reads as belonging to what
                // follows rather than floating between two sections.
                .padding(.top, 6)

        case .paragraph:
            InlineRuns(runs: runs)
                .font(.system(size: size))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

        case .listItem(_, let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker)
                    .font(.system(size: size))
                    .foregroundStyle(Theme.textMuted)
                    // A fixed width so the text of every item in a list starts on the same
                    // column, including "10." beside "9." — and monospaced digits so a numbered
                    // list does not wobble as the numbers grow.
                    .monospacedDigit()
                    .frame(minWidth: 16, alignment: .leading)
                InlineRuns(runs: runs)
                    .font(.system(size: size))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 16)

        case .codeBlock(let code, _):
            // Horizontally scrollable rather than wrapped: a wrapped command line is a command
            // line nobody can copy correctly, and this is the one place in a body where the
            // author's own line breaks carry meaning.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(Theme.mono(size - 0.5))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )

        case .quote:
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 2)
                InlineRuns(runs: runs)
                    .font(.system(size: size))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Divider().overlay(Theme.hairline)

        case .table:
            // Columns rather than lines: a table is how a pull request puts light and dark
            // screenshots side by side, and only a grid keeps each pair together.
            // Lines between rows only: a cell cannot be stretched to its row's height without the
            // grid growing to fill the scroll view, so lines around each cell would not meet.
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(cells.enumerated()), id: \.offset) { row, columns in
                    if row > 0 {
                        Divider().overlay(Theme.border)
                    }
                    GridRow {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, cell in
                            InlineRuns(runs: cell)
                                .font(.system(size: size, weight: row == 0 ? .semibold : .regular))
                                .foregroundStyle(row == 0 ? Theme.textStrong : Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
            .padding(10)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
    }

    /// Forgets every body parsed so far. Called on sign-out, so the leaving account's comments do
    /// not stay in memory after the database they came from is erased.
    @MainActor static func forgetParsedBodies() {
        ParsedMarkdown.cache.removeAllObjects()
        MarkdownImages.forget()
    }

    /// How much bigger a heading is than the body. Three steps for six levels, because a body
    /// that uses `#####` is not asking for a fifth distinct size — it is asking for "smaller".
    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return size + 4
        case 2: return size + 2
        case 3: return size + 1
        default: return size
        }
    }
}

/// One Markdown source, parsed: its blocks, each beside its inline Markdown as `AttributedString`
/// runs, kept process-wide by the source string (``of(_:)``).
///
/// ``MarkdownText`` is drawn again whenever the view holding it is, and a tab flip draws every post
/// on the conversation tab: splitting the blocks and running `AttributedString(markdown:)` once per
/// block, every time, was most of that redraw — for text that had not changed. A source is parsed
/// once now and read back after that. A class because `NSCache` holds objects. The cache keeps a
/// few hundred sources — a long conversation's worth — and lets go of more under memory pressure;
/// sign-out empties it (``MarkdownText/forgetParsedBodies()``), because what it holds is the
/// leaving account's comments.
private final class ParsedMarkdown {
    /// A piece of a block's text: inline Markdown, parsed, or a screenshot GitHub stores, drawn
    /// where it was written (ADR 0043).
    typealias Run = ImageRun<AttributedString>

    /// The blocks in order, each with its text as runs — none for a code block, which is drawn
    /// verbatim, or a rule — and a table's cells, header row first, as runs too.
    let blocks: [(block: MarkdownBlock, runs: [Run], cells: [[[Run]]])]

    private init(_ markdown: String) {
        blocks = MarkdownDocument.blocks(from: markdown).map { block in
            switch block {
            case .heading(_, let text), .paragraph(let text), .listItem(let text, _, _), .quote(let text):
                return (block, Self.runs(text), [])
            case .table(let header, let rows):
                return (block, [], ([header] + rows).map { $0.map(Self.runs) })
            case .codeBlock, .rule:
                return (block, [], [])
            }
        }
    }

    /// One block's text cut around its uploads, each piece of text parsed.
    private static func runs(_ text: String) -> [Run] {
        DescriptionImages.runs(in: text).map { run in
            switch run {
            case .text(let text): .text(inline(text))
            case .image(let image): .image(image)
            }
        }
    }

    /// `markdown` parsed, from the cache when it has been parsed before.
    @MainActor static func of(_ markdown: String) -> ParsedMarkdown {
        let key = markdown as NSString
        if let parsed = cache.object(forKey: key) { return parsed }
        let parsed = ParsedMarkdown(markdown)
        cache.setObject(parsed, forKey: key)
        return parsed
    }

    @MainActor fileprivate static let cache: NSCache<NSString, ParsedMarkdown> = {
        let cache = NSCache<NSString, ParsedMarkdown>()
        cache.countLimit = 300
        return cache
    }()

    /// Inline Markdown within one block, which is what `AttributedString` is good at.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
    }
}

/// A block's runs: one `Text` when it is only text, the common case, and a column otherwise. Font
/// and colour are the caller's, through the environment.
private struct InlineRuns: View {
    let runs: [ParsedMarkdown.Run]

    var body: some View {
        if runs.count == 1, case .text(let text)? = runs.first {
            Text(text)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    switch run {
                    case .text(let text): Text(text)
                    case .image(let image): MarkdownImage(image: image)
                    }
                }
            }
        }
    }
}

private extension EnvironmentValues {
    /// ``MarkdownText/imageSubject``, handed down to the screenshots in it.
    @Entry var markdownImageSubject: String?
}

/// A screenshot GitHub stores, drawn where the post put it — or, until it has arrived and when it
/// cannot, its alt text — and opened on GitHub on a click.
private struct MarkdownImage: View {
    let image: DescriptionImage

    @Environment(\.markdownImageSubject) private var subjectID
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    @Environment(\.openURL) private var openURL
    /// From the cache straight away, so a post scrolled back to does not flash its alt text.
    @State private var loaded: NSImage?
    @State private var isFailed = false

    init(image: DescriptionImage) {
        self.image = image
        _loaded = State(initialValue: MarkdownImages.cached(image))
    }

    var body: some View {
        Button { openURL(image.url) } label: {
            if let loaded {
                Image(nsImage: loaded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    // Never larger than it is, and never so tall that one phone screenshot is the
                    // whole conversation; the click shows it whole.
                    .frame(maxWidth: loaded.size.width, maxHeight: 480, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    if isFailed {
                        Image(systemName: "photo")
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(image.altText.isEmpty ? String(localized: "Image") : image.altText)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .help(String(localized: "Open on GitHub"))
        .accessibilityLabel(Text(verbatim: image.altText))
        .task(id: image.key) {
            // Again here: an edited post can put another upload where this one was.
            loaded = MarkdownImages.cached(image)
            isFailed = false
            guard loaded == nil else { return }
            guard let subjectID, let fetcher = environment?.descriptionImageFetcher else {
                isFailed = true
                return
            }
            loaded = await MarkdownImages.load(image, in: subjectID, fetcher: fetcher)
            isFailed = loaded == nil
        }
    }
}

/// The screenshots posts show, downloaded once per process (ADR 0043).
///
/// A screenshot is fetched the way *Read screenshots* fetches one: the post as GitHub renders it,
/// for the short-lived signed link, then that link without the token, from GitHub's upload host
/// only. The rendering is read once for every upload of a post — its links outlive the minute it
/// is kept — and never stored; the decoded image is kept instead, a few dozen at most, and
/// sign-out lets go of all of it with the bodies (``MarkdownText/forgetParsedBodies()``).
@MainActor
enum MarkdownImages {
    /// Decoded, so priced by their pixels: a phone screenshot is about 15 MB of them.
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()
    /// Each post's rendering being read or read in the last minute, by node id.
    private static var renderings: [String: (task: Task<String?, Never>, startedAt: Date)] = [:]
    /// Each download under way, by the upload's key.
    private static var downloads: [String: Task<NSImage?, Never>] = [:]

    static func cached(_ image: DescriptionImage) -> NSImage? {
        images.object(forKey: image.key as NSString)
    }

    static func load(_ image: DescriptionImage, in subjectID: String, fetcher: any DescriptionImageFetching) async -> NSImage? {
        if let running = downloads[image.key] { return await running.value }
        let download = Task {
            defer { downloads[image.key] = nil }
            guard let html = await rendering(of: subjectID, fetcher: fetcher),
                  let url = DescriptionImages.signedSources(for: [image], inBodyHTML: html).first?.url,
                  let data = try? await fetcher.descriptionImage(at: url),
                  let decoded = NSImage(data: data)
            else { return nil as NSImage? }
            let pixels = decoded.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
            images.setObject(decoded, forKey: image.key as NSString, cost: max(pixels * 4, data.count))
            return decoded
        }
        downloads[image.key] = download
        return await download.value
    }

    private static func rendering(of subjectID: String, fetcher: any DescriptionImageFetching) async -> String? {
        renderings = renderings.filter { $0.value.startedAt.timeIntervalSinceNow > -60 }
        if let kept = renderings[subjectID] { return await kept.task.value }
        let task = Task { try? await fetcher.bodyHTML(subjectID: subjectID) }
        renderings[subjectID] = (task, Date())
        return await task.value
    }

    static func forget() {
        images.removeAllObjects()
        renderings = [:]
        downloads.values.forEach { $0.cancel() }
        downloads = [:]
    }
}
