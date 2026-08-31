import Foundation

/// Renders GitHub-flavoured Markdown into a conservative, already-sanitized HTML fragment.
///
/// This is the Swift half of the bridge's `bodyHTML` contract (`web/diff-viewer/README.md`,
/// "`bodyHTML` is trusted-from-native"): the webview renders the result with `innerHTML`, so
/// **everything is escaped first** and only a fixed, tiny set of tags is emitted afterwards:
///
/// | Markdown | HTML |
/// | --- | --- |
/// | paragraph | `<p>` (single newlines become `<br>`) |
/// | ```` ```fence ```` | `<pre><code>` |
/// | `` `code` `` | `<code>` |
/// | `**bold**`, `__bold__` | `<strong>` |
/// | `*italic*`, `_italic_` | `<em>` |
/// | `- item` | `<ul><li>` |
/// | `> quote` | `<blockquote>` |
/// | `# heading` | `<p><strong>` |
/// | `[text](https://…)` | `<a href="https://…">` — **https only** |
///
/// There is no raw-HTML passthrough, no image tag, no attribute other than a validated
/// `href`, and no `javascript:`/`data:` URL can survive the scheme check. Anything the
/// converter does not understand ends up as escaped text, which is the safe failure mode.
enum MarkdownHTML {
    /// Renders Markdown to a sanitized HTML fragment.
    /// - Parameter markdown: The Markdown source, as GitHub returned it.
    /// - Returns: An HTML fragment safe to assign to `innerHTML`.
    static func render(_ markdown: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var html = ""
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                var body: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }  // consume the closing fence
                html += "<pre><code>" + escape(body.joined(separator: "\n")) + "</code></pre>"
                continue
            }

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let heading = headingText(trimmed) {
                html += "<p><strong>" + inline(escape(heading)) + "</strong></p>"
                index += 1
                continue
            }

            if isListItem(trimmed) {
                var items: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isListItem(candidate) else { break }
                    items.append(String(candidate.dropFirst(2)))
                    index += 1
                }
                html += "<ul>"
                for item in items {
                    html += "<li>" + inline(escape(item)) + "</li>"
                }
                html += "</ul>"
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoted.append(
                        String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                html += "<blockquote><p>"
                    + inline(escape(quoted.joined(separator: "\n"))).replacingOccurrences(
                        of: "\n", with: "<br>"
                    )
                    + "</p></blockquote>"
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || candidate.hasPrefix("```") || candidate.hasPrefix(">")
                    || isListItem(candidate) || headingText(candidate) != nil {
                    break
                }
                paragraph.append(candidate)
                index += 1
            }
            let joined = paragraph.joined(separator: "\n")
            html += "<p>"
                + inline(escape(joined)).replacingOccurrences(of: "\n", with: "<br>")
                + "</p>"
        }

        return html
    }

    // MARK: - Block helpers

    private static func isListItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func headingText(_ line: String) -> String? {
        var hashes = 0
        for character in line {
            if character == "#" {
                hashes += 1
                if hashes > 6 { return nil }
            } else {
                break
            }
        }
        guard hashes > 0 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.hasPrefix(" ") else { return nil }
        return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Escaping

    /// Escapes every character that has meaning in HTML. Runs *before* any tag is emitted.
    /// - Parameter text: Raw text.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: - Inline

    /// Applies inline formatting to text that has **already been escaped**.
    private static func inline(_ escaped: String, depth: Int = 0) -> String {
        guard depth < 4 else { return escaped }
        let characters = Array(escaped)
        var output = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "`" {
                if let close = indexOf(characters, of: "`", from: index + 1) {
                    let code = String(characters[(index + 1)..<close])
                    output += "<code>" + code + "</code>"
                    index = close + 1
                    continue
                }
            }

            if character == "[" {
                if let link = parseLink(characters, from: index, depth: depth) {
                    output += link.html
                    index = link.nextIndex
                    continue
                }
            }

            if character == "*" || character == "_" {
                let isDouble = index + 1 < characters.count && characters[index + 1] == character
                let marker = isDouble ? String(repeating: String(character), count: 2)
                    : String(character)
                if let close = indexOfRun(characters, marker: marker, from: index + marker.count),
                   close > index + marker.count {
                    let inner = String(characters[(index + marker.count)..<close])
                    let rendered = inline(inner, depth: depth + 1)
                    output += isDouble
                        ? "<strong>" + rendered + "</strong>"
                        : "<em>" + rendered + "</em>"
                    index = close + marker.count
                    continue
                }
            }

            output.append(character)
            index += 1
        }

        return output
    }

    private static func indexOf(_ characters: [Character], of target: Character, from start: Int) -> Int? {
        var index = start
        while index < characters.count {
            if characters[index] == target { return index }
            index += 1
        }
        return nil
    }

    private static func indexOfRun(_ characters: [Character], marker: String, from start: Int) -> Int? {
        let markerCharacters = Array(marker)
        var index = start
        while index + markerCharacters.count <= characters.count {
            var matches = true
            for offset in 0..<markerCharacters.count
            where characters[index + offset] != markerCharacters[offset] {
                matches = false
                break
            }
            if matches { return index }
            index += 1
        }
        return nil
    }

    /// Parses `[text](https://…)` starting at `start`, rejecting every non-https URL.
    private static func parseLink(
        _ characters: [Character],
        from start: Int,
        depth: Int
    ) -> (html: String, nextIndex: Int)? {
        guard let closeBracket = indexOf(characters, of: "]", from: start + 1),
              closeBracket + 1 < characters.count,
              characters[closeBracket + 1] == "(",
              let closeParen = indexOf(characters, of: ")", from: closeBracket + 2)
        else { return nil }

        let text = String(characters[(start + 1)..<closeBracket])
        let target = String(characters[(closeBracket + 2)..<closeParen])
            .trimmingCharacters(in: .whitespaces)

        // The URL is already HTML-escaped, so a literal scheme prefix survives untouched.
        guard target.hasPrefix("https://"), !target.contains(" ") else { return nil }

        let rendered = inline(text, depth: depth + 1)
        return ("<a href=\"" + target + "\">" + rendered + "</a>", closeParen + 1)
    }
}
