/// What language a repository path is written in — the one table both diff renderers read.
///
/// This used to be the app target's `MonacoLanguage`, a path → Monaco-id map. It moved here when
/// the native diff list gained its own syntax highlighting (``SyntaxHighlighter``) and the iPhone
/// companion (ADR 0044) needed the same answer without Monaco: two tables would drift, and a file
/// coloured as Swift in one renderer and as plain text in the other is the kind of difference
/// ADR 0034 allows but nobody wants. `MonacoLanguage.id(forPath:)` is now a one-line delegate to
/// ``monacoID``, and the cases gained the Linux leg the app-target test never had.
///
/// The raw values are Monaco's language ids, so ``monacoID`` is the raw value for every language
/// the web bundle registers (`web/diff-viewer/README.md`, "Syntax highlighting").
public enum SourceLanguage: String, Sendable, Hashable, CaseIterable {
    case c, clojure, cpp, csharp, css, dockerfile, go, graphql, html, java, javascript, json, kotlin
    case markdown, objectiveC = "objective-c", php, python, ruby, rust, shell, sql, swift, toml
    case typescript, xml, yaml, plaintext

    private static let byExtension: [String: SourceLanguage] = [
        "swift": .swift,
        "c": .c, "h": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp,
        "clj": .clojure, "cljs": .clojure, "cljc": .clojure, "edn": .clojure, "bb": .clojure,
        "cs": .csharp,
        "css": .css, "scss": .css, "less": .css,
        "go": .go,
        "graphql": .graphql, "gql": .graphql,
        "htm": .html, "html": .html, "vue": .html,
        "java": .java,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        // A string catalog is JSON on disk, and this repository's own diffs are full of them.
        "json": .json, "jsonc": .json, "xcstrings": .json,
        "kt": .kotlin, "kts": .kotlin,
        "md": .markdown, "markdown": .markdown,
        "m": .objectiveC, "mm": .objectiveC,
        "php": .php,
        "py": .python, "pyi": .python,
        "rb": .ruby, "rake": .ruby,
        "rs": .rust,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "sql": .sql,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "toml": .toml,
        "xml": .xml, "plist": .xml, "storyboard": .xml, "xib": .xml, "svg": .xml,
        "yml": .yaml, "yaml": .yaml,
    ]

    private static let byFileName: [String: SourceLanguage] = [
        "dockerfile": .dockerfile,
        "makefile": .shell,
        "gemfile": .ruby,
        "rakefile": .ruby,
        "podfile": .ruby,
        "package.json": .json,
        "cargo.toml": .toml,
        "deps.edn": .clojure,
        "project.clj": .clojure,
        ".gitignore": .plaintext,
    ]

    /// The language of a path, from its file name first and its extension second.
    ///
    /// Case-insensitive, and only the last path component counts. Anything unknown is
    /// ``plaintext`` — a wrong guess costs colour, never correctness.
    /// - Parameter path: The repository-relative path.
    public init(path: String) {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if let byName = Self.byFileName[name] {
            self = byName
            return
        }
        if name.hasPrefix("dockerfile") {
            self = .dockerfile
            return
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            self = .plaintext
            return
        }
        self = Self.byExtension[String(name[name.index(after: dot)...])] ?? .plaintext
    }

    /// The id Monaco's bundle registers for this language.
    ///
    /// Clojure is the one case without a registered grammar there (`languages.ts` imports none),
    /// so it degrades to `plaintext` in Monaco and is coloured only by the native renderers.
    public var monacoID: String { self == .clojure ? "plaintext" : rawValue }
}
