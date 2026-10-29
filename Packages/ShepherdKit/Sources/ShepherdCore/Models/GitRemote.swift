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
    ///
    /// An SSH host that is an `~/.ssh/config` alias — one without a dot (`git@github-work:o/r`),
    /// or the `github.com-<account>` convention people use for a second account — is read as
    /// github.com: that is what such aliases are for, and refusing them as "GitHub Enterprise"
    /// left a multi-account user no way in. A wrong guess costs no more than a watched repository
    /// the access check then flags.
    /// - Parameter remoteURL: What `git remote get-url origin` printed.
    public static func read(_ remoteURL: String) -> Reading {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (host, path, isSSH) = split(text) else { return .unreadable }
        let lowered = host.lowercased()
        guard githubHosts.contains(lowered) || (isSSH && isSSHAlias(lowered)) else {
            return isEnterpriseLooking(lowered) ? .enterpriseHost(lowered) : .otherHost(lowered)
        }
        return repository(inPath: path).map(Reading.github) ?? .unreadable
    }

    /// The `owner/name` a remote's path spells, whatever its host — what the sheet pre-fills for
    /// a remote on another host, where the repository often has the same name on GitHub.
    /// - Parameter remoteURL: What `git remote get-url origin` printed.
    public static func pathRepository(_ remoteURL: String) -> RepoRef? {
        split(remoteURL.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { repository(inPath: $0.path) }
    }

    /// A path that is exactly `owner/name(.git)`, validated by the `shepherd://` grammar's rules.
    private static func repository(inPath path: String) -> RepoRef? {
        var segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 2 else { return nil }
        if segments[1].lowercased().hasSuffix(".git") {
            segments[1] = String(segments[1].dropLast(4))
        }
        return DeepLinkValidation.repository(fullName: "\(segments[0])/\(segments[1])")
    }

    /// A remote URL fit to show on screen: without credentials, a query or a fragment.
    ///
    /// Remotes carry secrets more often than they should — `https://user:ghp_…@github.com/o/r`
    /// is what some tutorials still tell people to write — and a remote Shepherd could not read
    /// is exactly the one the sheet quotes back to the user. So the userinfo of a `scheme://` URL
    /// is dropped (all of it: a username alone can be a token), and so is anything after `?` or
    /// `#`. The scp-like form has no password field, and its `git@` is left alone.
    /// - Parameter remoteURL: What `git remote get-url origin` printed.
    public static func redacted(_ remoteURL: String) -> String {
        var text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        guard let schemeEnd = text.range(of: "://") else { return text }
        let rest = text[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        guard let at = rest[..<authorityEnd].lastIndex(of: "@") else { return text }
        return String(text[..<schemeEnd.upperBound]) + String(rest[rest.index(after: at)...])
    }

    /// Splits a remote into its host and its path, or `nil` when it has no host. `isSSH` is
    /// whether git reaches the host over ssh, the only transport `~/.ssh/config` aliases apply to.
    private static func split(_ text: String) -> (host: String, path: String, isSSH: Bool)? {
        guard !text.isEmpty else { return nil }
        if let schemeEnd = text.range(of: "://") {
            // `ssh://` and the `git+ssh://` spelling git still accepts.
            let isSSH = text[..<schemeEnd.lowerBound].lowercased().hasSuffix("ssh")
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
            return (String(authority), String(rest[authorityEnd...]), isSSH)
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
        return (String(host), String(text[text.index(after: colon)...]), true)
    }

    /// Whether an SSH host is an `~/.ssh/config` alias standing in for github.com: no dot at all,
    /// or `github.com-<suffix>`. A real host has a dot, and no top-level domain has a dash.
    private static func isSSHAlias(_ host: String) -> Bool {
        !host.contains(".") || githubHosts.contains { host.hasPrefix($0 + "-") }
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
