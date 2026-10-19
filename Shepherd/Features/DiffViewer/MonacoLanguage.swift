import Foundation
import ShepherdCore

/// Maps a repository path onto a Monaco language id.
///
/// The table itself lives in ShepherdCore as ``SourceLanguage``, shared with the native diff's
/// tokenizer and the iPhone companion (ADR 0044) so the renderers cannot disagree about what a
/// file is. This stays as the app's Monaco-facing name. The web bundle resolves aliases itself, so
/// an id Shepherd gets slightly wrong degrades to `plaintext` rather than breaking the viewer.
enum MonacoLanguage {
    /// The Monaco language id for a path.
    /// - Parameter path: The repository-relative path.
    /// - Returns: A language id the bundle knows, or `"plaintext"`.
    static func id(forPath path: String) -> String {
        SourceLanguage(path: path).monacoID
    }

    /// The Monaco language id for a changed file.
    /// - Parameter file: The changed file.
    static func id(for file: ChangedFile) -> String {
        id(forPath: file.path)
    }
}
