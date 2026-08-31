import Foundation
import ShepherdCore

/// Maps a repository path onto a Monaco language id.
///
/// The web bundle registers a fixed set of Monarch grammars (`web/diff-viewer/README.md`,
/// "Syntax highlighting") and resolves aliases itself, so an id Shepherd gets slightly wrong
/// degrades to `plaintext` rather than breaking the viewer.
enum MonacoLanguage {
    private static let byExtension: [String: String] = [
        "swift": "swift",
        "c": "c", "h": "c",
        "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "cs": "csharp",
        "css": "css", "scss": "css", "less": "css",
        "go": "go",
        "graphql": "graphql", "gql": "graphql",
        "htm": "html", "html": "html", "vue": "html",
        "java": "java",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "json": "json", "jsonc": "json",
        "kt": "kotlin", "kts": "kotlin",
        "md": "markdown", "markdown": "markdown",
        "m": "objective-c", "mm": "objective-c",
        "php": "php",
        "py": "python", "pyi": "python",
        "rb": "ruby", "rake": "ruby",
        "rs": "rust",
        "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell",
        "sql": "sql",
        "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
        "toml": "toml",
        "xml": "xml", "plist": "xml", "storyboard": "xml", "xib": "xml", "svg": "xml",
        "yml": "yaml", "yaml": "yaml",
    ]

    private static let byFileName: [String: String] = [
        "dockerfile": "dockerfile",
        "makefile": "shell",
        "gemfile": "ruby",
        "rakefile": "ruby",
        "package.json": "json",
        "cargo.toml": "toml",
        "podfile": "ruby",
        ".gitignore": "plaintext",
    ]

    /// The Monaco language id for a path.
    /// - Parameter path: The repository-relative path.
    /// - Returns: A language id the bundle knows, or `"plaintext"`.
    static func id(forPath path: String) -> String {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if let byName = byFileName[name] { return byName }
        if name.hasPrefix("dockerfile") { return "dockerfile" }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "plaintext" }
        let ext = String(name[name.index(after: dot)...])
        return byExtension[ext] ?? "plaintext"
    }

    /// The Monaco language id for a changed file.
    /// - Parameter file: The changed file.
    static func id(for file: ChangedFile) -> String {
        id(forPath: file.path)
    }
}
