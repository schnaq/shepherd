import Foundation

/// Reads which GitHub repository a clone's `origin` remote points at.
///
/// "Add a local repository…" starts from a folder rather than from a name: the user picks their
/// clone, Shepherd asks git for `remote.origin.url`, and this decides what that URL means. It is a
/// *classifier* over ``RepoRef/parse(userInput:)`` rather than a second URL grammar: the path is
/// read by the same content rules the `shepherd://` grammar enforces, and what is added here is
/// only the part a pasted-text parser never needed — telling a remote on another host apart from
/// one that is not a URL at all, so the sheet can say *why* it could not name the repository.
///
/// Shepherd talks to github.com and nothing else (CONTRIBUTING.md's host list; `AppConfig` has no
/// configurable host), so a GitHub Enterprise remote is recognised in order to be refused with its
/// own sentence rather than being mistaken for "not GitHub at all" — the user of one knows it *is*
/// GitHub and would read the generic message as a bug.
///
/// Pure and Foundation-only, so every remote shape is pinned by tests on the Linux runner.
public enum GitRemote {
    /// What a remote URL turned out to be.
    public enum Reading: Sendable, Equatable {
        /// A repository on github.com.
        case github(RepoRef)
        /// A host that looks like a GitHub Enterprise installation, e.g. `github.example.com`.
        case enterpriseHost(String)
        /// A host that is not GitHub at all, e.g. `gitlab.com`.
        case otherHost(String)
        /// Not a URL Shepherd can read a host out of — a local path, an empty string.
        case unreadable
    }

    /// The hosts that are github.com, spelled the ways a clone may spell them.
    ///
    /// `ssh.github.com` is GitHub's SSH-over-port-443 endpoint, which people behind a firewall
    /// put in their remotes.
    static let githubHosts: Set<String> = ["github.com", "www.github.com", "ssh.github.com"]

    /// Classifies a remote URL.
    ///
    /// Accepts the forms git itself writes into a config: `https://github.com/o/r(.git)`,
    /// `ssh://git@github.com(:port)/o/r(.git)`, `git://…`, and the scp-like
    /// `git@github.com:o/r.git`. A path on github.com must be exactly `owner/name` — a remote
    /// never carries anything past the name, so a third segment is a remote Shepherd does not
    /// understand rather than noise to drop.
    /// - Parameter remoteURL: What `git remote get-url origin` printed.
    public static func read(_ remoteURL: String) -> Reading {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (host, path) = split(text) else { return .unreadable }
        let lowered = host.lowercased()
        guard githubHosts.contains(lowered) else {
            return isEnterpriseLooking(lowered) ? .enterpriseHost(lowered) : .otherHost(lowered)
        }
        var segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 2 else { return .unreadable }
        if segments[1].lowercased().hasSuffix(".git") {
            segments[1] = String(segments[1].dropLast(4))
        }
        guard let repo = DeepLinkValidation.repository(fullName: "\(segments[0])/\(segments[1])") else {
            return .unreadable
        }
        return .github(repo)
    }

    /// Splits a remote into its host and its path, or `nil` when it has no host.
    private static func split(_ text: String) -> (host: String, path: String)? {
        guard !text.isEmpty else { return nil }
        if let schemeEnd = text.range(of: "://") {
            // `scheme://[user@]host[:port]/path`
            let rest = text[schemeEnd.upperBound...]
            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            var authority = rest[..<authorityEnd]
            if let at = authority.lastIndex(of: "@") {
                authority = authority[authority.index(after: at)...]
            }
            if let colon = authority.firstIndex(of: ":") {
                authority = authority[..<colon]
            }
            guard !authority.isEmpty else { return nil }
            return (String(authority), String(rest[authorityEnd...]))
        }
        // scp-like `[user@]host:path`. git only reads it that way when the colon comes before
        // the first slash — `./a:b` and `/srv/a:b` are local paths, and so is anything else.
        guard let colon = text.firstIndex(of: ":") else { return nil }
        if let slash = text.firstIndex(of: "/"), slash < colon { return nil }
        var host = text[..<colon]
        if let at = host.lastIndex(of: "@") {
            host = host[host.index(after: at)...]
        }
        guard !host.isEmpty else { return nil }
        return (String(host), String(text[text.index(after: colon)...]))
    }

    /// Whether a host that is not github.com is nevertheless a GitHub installation.
    ///
    /// A heuristic, and deliberately a generous one: the only consequence of a false positive is
    /// a sentence that says "GitHub Enterprise" where "not GitHub" would have been accurate, and
    /// both refuse the same way.
    private static func isEnterpriseLooking(_ host: String) -> Bool {
        host.hasSuffix(".ghe.com") || host.split(separator: ".").contains { $0.contains("github") }
    }
}
