import Foundation

/// What happened to a file in a pull request.
public enum FileChangeStatus: String, Sendable, Codable, Hashable, CaseIterable {
    /// The file is new.
    case added
    /// The file existed and was edited.
    case modified
    /// The file was deleted.
    case removed
    /// The file moved, possibly with edits (see ``ChangedFile/previousPath``).
    case renamed

    /// Maps GitHub's REST `status` string onto a status, defaulting to ``modified``.
    ///
    /// GitHub also emits `copied`, `changed` and `unchanged`; all of them are treated as
    /// edits of an existing file.
    /// - Parameter raw: The raw REST status string.
    public static func fromAPI(_ raw: String) -> FileChangeStatus {
        switch raw.lowercased() {
        case "added": return .added
        case "removed", "deleted": return .removed
        case "renamed": return .renamed
        default: return .modified
        }
    }
}

/// One file changed by a pull request.
public struct ChangedFile: Sendable, Codable, Hashable, Identifiable {
    /// The path of the file after the change.
    public var path: String
    /// The path before a rename, when ``status`` is ``FileChangeStatus/renamed``.
    public var previousPath: String?
    /// What happened to the file.
    public var status: FileChangeStatus
    /// Added lines.
    public var additions: Int
    /// Deleted lines.
    public var deletions: Int
    /// The unified diff for this file, or `nil` for binary files and diffs GitHub truncated.
    public var patch: String?
    /// Whether the file counts as viewed.
    ///
    /// From a fetch, GitHub's own *Viewed* checkbox for the signed-in user — `VIEWED` only, so a
    /// file GitHub reports as changed since (`DISMISSED`) is not. Read from the store, the
    /// reviewer's own decision made here — a tick or an untick, which survives a push that left
    /// the file's content alone — or else GitHub's checkbox
    /// (`DatabaseManager.loadPullRequestDetail`).
    public var isViewed: Bool
    /// The file's blob SHA at the head commit, or `nil` when GitHub did not send one.
    ///
    /// Carried for one comparison: a tick made at an older head still holds when the blob is the
    /// same, which is how GitHub keeps its own checkbox across a push.
    public var blobSha: String?

    /// Creates a changed file.
    public init(
        path: String,
        previousPath: String? = nil,
        status: FileChangeStatus,
        additions: Int = 0,
        deletions: Int = 0,
        patch: String? = nil,
        isViewed: Bool = false,
        blobSha: String? = nil
    ) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
        self.isViewed = isViewed
        self.blobSha = blobSha
    }

    /// `ChangedFile` is identified by its ``path`` within a pull request.
    public var id: String { path }

    /// Total churn (added plus deleted lines).
    public var churn: Int { additions + deletions }

    /// The lowercased file extension without the dot, or `nil` when the name has none.
    public var fileExtension: String? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : ext.lowercased()
    }

    /// The last path component.
    public var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Whether GitHub supplied a diff for this file.
    public var hasPatch: Bool { !(patch ?? "").isEmpty }
}
