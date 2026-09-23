import Foundation

/// Where a repository stands before "Add a local repository…" changes anything.
///
/// The confirmation sheet does two things in one step — link the folder as the repository's local
/// checkout (the map delegation and *Open in editor* read, ADR 0011 and ADR 0039) and watch the
/// repository (ADR 0005's 2026-09-16 amendment) — and either may already be done. Adding the same
/// clone twice must be a no-op that says so, not a second watch entry or a silent overwrite of a
/// checkout pointing somewhere else. This works that out from the two settings values alone.
///
/// Pure and Foundation-only, so the idempotency rules are pinned by tests on the Linux runner.
public struct LocalRepositoryLink: Sendable, Equatable {
    /// The checkout half.
    public enum Checkout: Sendable, Equatable {
        /// No folder is linked for this repository yet.
        case unlinked
        /// This very folder is already linked.
        case linkedHere
        /// Another folder is linked; linking this one replaces it.
        case linkedElsewhere(path: String)
    }

    /// The watch half.
    public enum Watch: Sendable, Equatable {
        /// Not watched yet, and there is room.
        case notWatched
        /// Already on the watch list.
        case watched
        /// Not watched, and the list is at its cap.
        case listFull
    }

    /// The checkout half.
    public var checkout: Checkout
    /// The watch half.
    public var watch: Watch

    /// Creates a state.
    public init(checkout: Checkout, watch: Watch) {
        self.checkout = checkout
        self.watch = watch
    }

    /// Works out the state of a repository and a folder.
    ///
    /// Both lookups ignore case, because GitHub does: `Schnaq/Shepherd` read out of a remote and
    /// `schnaq/shepherd` typed into Settings a month ago are one repository, and the sheet must
    /// say "already linked" rather than add a second entry beside the first.
    /// - Parameters:
    ///   - repo: The repository.
    ///   - path: The folder's absolute path.
    ///   - watched: The current watch list.
    ///   - checkouts: The current `owner/name` → path map.
    ///   - maximumWatched: The watch list's cap.
    public static func state(
        repo: RepoRef,
        path: String,
        watched: [RepoRef],
        checkouts: [String: String],
        maximumWatched: Int
    ) -> LocalRepositoryLink {
        let linked = checkouts.first { $0.key.lowercased() == repo.fullName.lowercased() }?.value
        let checkout: Checkout
        switch linked.map(normalised) {
        case nil, "":
            checkout = .unlinked
        case normalised(path):
            checkout = .linkedHere
        default:
            checkout = .linkedElsewhere(path: linked ?? "")
        }

        let watch: Watch
        if watched.contains(where: { $0.isSameRepository(as: repo) }) {
            watch = .watched
        } else if watched.count >= maximumWatched {
            watch = .listFull
        } else {
            watch = .notWatched
        }
        return LocalRepositoryLink(checkout: checkout, watch: watch)
    }

    /// Whether there is anything left to do at all.
    public var isComplete: Bool { checkout == .linkedHere && watch == .watched }

    /// A path compared the way two spellings of one folder should be: trimmed, without a
    /// trailing slash.
    private static func normalised(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
