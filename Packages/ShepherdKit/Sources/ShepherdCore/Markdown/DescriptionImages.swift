import Foundation

/// A screenshot somebody attached to a pull-request description (ADR 0038 item 4).
///
/// Only images GitHub itself stores count: an upload dragged into the description box
/// (`github.com/user-attachments/assets/<uuid>`) and the older upload hosts
/// (`user-images.githubusercontent.com`, `private-user-images.githubusercontent.com`). An image
/// linked from anywhere else is *somebody else's host*, and reading it would add that host to the
/// list CONTRIBUTING.md keeps — so it is not an attachment here, whatever it shows.
public struct DescriptionImage: Sendable, Hashable {
    /// The URL as the description wrote it.
    public var url: URL
    /// The alt text, trimmed. Empty when the author gave none.
    public var altText: String
    /// The part of the URL that survives GitHub's rewriting of it into a signed download link:
    /// the asset's UUID for an upload, the file name for the older hosts. Lowercased.
    public var key: String

    /// Creates an attachment.
    /// - Parameters:
    ///   - url: The URL as written.
    ///   - altText: The alt text.
    ///   - key: The matching key; see ``key``.
    public init(url: URL, altText: String, key: String) {
        self.url = url
        self.altText = altText
        self.key = key
    }
}

/// Finds the screenshots in a pull request's description, and the signed links GitHub serves
/// them under (ADR 0038 item 4, ADR 0007's 2026-09-22 amendment).
///
/// Two pure halves of a read the app makes only when a reviewer asks for it:
///
/// 1. ``attachments(inMarkdown:)`` reads the Markdown the inbox already holds, which is how the
///    summary card knows whether to offer *Read screenshots* without asking the network anything.
/// 2. ``signedSources(for:inBodyHTML:)`` reads GitHub's own rendering of the same description
///    (`Accept: application/vnd.github.html+json` on `/pulls/{n}`), in which every upload has been
///    rewritten to a short-lived link on `private-user-images.githubusercontent.com` that carries
///    its own signature. That link is what gets downloaded, without a token — the
///    `github.com/user-attachments` URL itself would redirect to an Amazon S3 bucket, a host that
///    is not on the list.
///
/// `NSRegularExpression` rather than Swift Regex for ``ClaimPattern``'s reason: one engine with the
/// same behaviour on macOS and on the Linux runner these tests run on.
public enum DescriptionImages {
    /// How many screenshots one reading looks at.
    ///
    /// Two, because the on-device window is 8,192 tokens and the description, the instructions
    /// and the answer share it — and because a pull request with a before and an after is the case
    /// this is for. A description with more says so on the card rather than silently reading two.
    public static let maximumImages = 2

    /// The hosts a signed screenshot may be downloaded from. GitHub's, and only these two.
    public static let downloadHosts: Set<String> = [
        "private-user-images.githubusercontent.com",
        "user-images.githubusercontent.com",
    ]

    /// The screenshots a description attaches, in the order it shows them, without repeats.
    ///
    /// Markdown images (`![alt](url)`, with or without a title) and HTML `<img src="…">` both
    /// count, because GitHub's own upload writes the latter when somebody resizes a screenshot.
    /// Anything inside a fenced code block is text, not an image, and is skipped.
    /// - Parameter markdown: The description as Markdown source.
    /// - Returns: The GitHub-hosted images; empty when there are none.
    public static func attachments(inMarkdown markdown: String) -> [DescriptionImage] {
        let text = withoutFencedCode(markdown)
        let range = NSRange(text.startIndex..., in: text)
        var found: [(location: Int, image: DescriptionImage)] = []

        for match in markdownImage?.matches(in: text, range: range) ?? [] {
            guard let alt = substring(text, match.range(at: 1)),
                  let link = substring(text, match.range(at: 2)),
                  let image = attachment(link: link, altText: alt)
            else { continue }
            found.append((match.range.location, image))
        }
        for match in htmlImage?.matches(in: text, range: range) ?? [] {
            guard let tag = substring(text, match.range),
                  let link = attribute("src", in: tag),
                  let image = attachment(link: link, altText: attribute("alt", in: tag) ?? "")
            else { continue }
            found.append((match.range.location, image))
        }

        var seen = Set<String>()
        return found
            .sorted { $0.location < $1.location }
            .map(\.image)
            .filter { seen.insert($0.key).inserted }
    }

    /// The signed download link for each attachment, from GitHub's HTML rendering of the
    /// description.
    ///
    /// An attachment is matched to the `<img>` whose file name contains its ``DescriptionImage/key``
    /// — GitHub keeps the upload's UUID in the name it signs — and only `https` links on
    /// ``downloadHosts`` are returned: an `<img>` GitHub proxied through `camo`, a `<video>`, or a
    /// link anywhere else is not a screenshot Shepherd will fetch.
    /// - Parameters:
    ///   - attachments: The attachments to find, in the order they should be read.
    ///   - html: The `body_html` GitHub returned.
    /// - Returns: Each matched attachment with its link, in the attachments' order; an attachment
    ///   with no match is left out, so the pairs — not two parallel lists — are what a caller reads.
    public static func signedSources(
        for attachments: [DescriptionImage],
        inBodyHTML html: String
    ) -> [(image: DescriptionImage, url: URL)] {
        let range = NSRange(html.startIndex..., in: html)
        let sources: [URL] = (htmlImage?.matches(in: html, range: range) ?? []).compactMap { match in
            guard let tag = substring(html, match.range),
                  let raw = attribute("src", in: tag),
                  let url = URL(string: unescapedHTML(raw)),
                  isDownloadable(url)
            else { return nil }
            return url
        }
        var used = Set<URL>()
        return attachments.compactMap { attachment in
            guard let match = sources.first(where: { source in
                !used.contains(source) && source.lastPathComponent.lowercased().contains(attachment.key)
            }) else { return nil }
            used.insert(match)
            return (attachment, match)
        }
    }

    /// Whether a link is one Shepherd may download a screenshot from: `https`, on one of
    /// ``downloadHosts``. Asked again by the client just before the request, so that a URL that
    /// reached it some other way is refused there too.
    /// - Parameter url: The link.
    public static func isDownloadable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return downloadHosts.contains(host)
    }

    // MARK: - Recognising an attachment

    /// The attachment a link names, or `nil` when it is not a GitHub-hosted image.
    private static func attachment(link: String, altText: String) -> DescriptionImage? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard let url = URL(string: unescapedHTML(trimmed)),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        let key: String?
        switch host {
        case "github.com":
            // `/user-attachments/assets/<uuid>` — the upload GitHub writes today.
            guard components.count == 3,
                  components[0] == "user-attachments",
                  components[1] == "assets"
            else { return nil }
            key = components[2]
        case _ where downloadHosts.contains(host):
            // `/<user id>/<id>-<uuid>.<ext>` — the older uploads, and a signed link pasted as is.
            key = components.count >= 2 ? components.last : nil
        default:
            key = nil
        }
        guard let key, !key.isEmpty else { return nil }
        return DescriptionImage(
            url: url,
            altText: altText.trimmingCharacters(in: .whitespacesAndNewlines),
            key: key.lowercased()
        )
    }

    // MARK: - Parsing

    /// `![alt](url)` or `![alt](url "title")`. The URL is the first run of non-space characters.
    private static let markdownImage = try? NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(\s*<?([^\s)>]+)>?(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)"#
    )

    /// One `<img …>` tag, whatever its attributes.
    private static let htmlImage = try? NSRegularExpression(
        pattern: #"<img\b[^>]*>"#,
        options: [.caseInsensitive]
    )

    /// The value of one attribute in a tag, quoted either way.
    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return nil }
        return substring(tag, match.range(at: 1)) ?? substring(tag, match.range(at: 2))
    }

    /// The text of one capture, or `nil` when it did not take part in the match.
    private static func substring(_ text: String, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, let bounds = Range(range, in: text) else { return nil }
        return String(text[bounds])
    }

    /// The five entities GitHub's renderer writes into an attribute; `&amp;` is the one that
    /// matters, since every signed link has a query string.
    private static func unescapedHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The description with every fenced code block blanked out, line for line.
    ///
    /// The fence rule is ``MarkdownDocument``'s: a line that opens with three backticks or three
    /// tildes starts one, and the same marker closes it. An unclosed fence runs to the end, as it
    /// renders.
    private static func withoutFencedCode(_ markdown: String) -> String {
        var marker: String?
        var kept: [Substring] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = marker {
                if trimmed.hasPrefix(open) { marker = nil }
                kept.append("")
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                marker = String(trimmed.prefix(3))
                kept.append("")
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }
}
