import Foundation

/// A `shepherd://` deep link — the app's entire remote-control surface (ADR 0013).
///
/// The type is the *grammar*, not the behaviour: parsing a URL yields one of these values and
/// nothing else happens. What each case does is the app target's business, which is what keeps
/// this parser pure, platform-independent and testable on Linux — and what lets the `shepherd`
/// CLI build exactly the URLs the app can parse, from the same source of truth
/// (``DeepLink/urlString``).
///
/// Grammar (every accepted form; anything else is rejected):
///
/// ```
/// shepherd://pr/<owner>/<repo>/<number>
/// shepherd://issue/<owner>/<repo>/<number>
/// shepherd://inbox
/// shepherd://inbox?filter=<token>
/// shepherd://sync
/// shepherd://settings
/// shepherd://settings/<tab>
/// ```
///
/// Deep-link input is **untrusted** — anything on the Mac can hand the app a URL — so the
/// parser is strict rather than forgiving: the command word and the token vocabularies are
/// closed sets, `owner`, `repo` and `number` must match GitHub's own character rules, a
/// trailing extra path segment is a rejection rather than something to ignore, and a URL
/// carrying a user, password, port or fragment is refused outright. No case carries a file
/// path, a command line or a URL to fetch, so there is nothing here that could turn into a
/// shell invocation or a file read.
public enum DeepLink: Hashable, Sendable {
    /// Open the full-window review screen for one pull request.
    case pullRequest(repo: RepoRef, number: Int)
    /// Show one issue in the inbox's issues section (ADR 0032).
    ///
    /// Parsed and serialised exactly like ``pullRequest`` — the same three validated segments,
    /// the same closed command word — because GitHub numbers issues and pull requests from one
    /// sequence and a reader who can write one link can write the other. What it *does* is the
    /// app's business, and it is the pull-request link's rule too: the local cache first, then a
    /// fetch of that one issue.
    case issue(repo: RepoRef, number: Int)
    /// Show the inbox, optionally with one rail filter applied.
    case inbox(filter: InboxDeepLinkFilter?)
    /// Run one sweep now.
    case sync
    /// Open Settings on a tab.
    case settings(tab: SettingsDeepLinkTab)

    /// The URL scheme Shepherd registers (`CFBundleURLTypes` in `project.yml`).
    public static let scheme = "shepherd"

    // MARK: - Parsing

    /// Parses a `shepherd://` URL.
    /// - Parameter url: The URL the system (or the CLI) handed over.
    /// - Returns: The deep link, or `nil` when the URL is not one Shepherd understands.
    public static func parse(_ url: URL) -> DeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil
        else { return nil }

        guard let segments = pathSegments(of: components) else { return nil }
        guard let command = segments.first?.lowercased() else { return nil }
        let rest = Array(segments.dropFirst())

        switch command {
        case "pr":
            // `pr/<owner>/<repo>/<number>` — exactly three segments, each fully validated.
            guard rest.count == 3,
                  let owner = DeepLinkValidation.owner(rest[0]),
                  let name = DeepLinkValidation.repositoryName(rest[1]),
                  let number = DeepLinkValidation.number(rest[2])
            else { return nil }
            return .pullRequest(repo: RepoRef(owner: owner, name: name), number: number)

        case "issue":
            // `issue/<owner>/<repo>/<number>`, validated exactly as `pr` is (ADR 0032).
            guard rest.count == 3,
                  let owner = DeepLinkValidation.owner(rest[0]),
                  let name = DeepLinkValidation.repositoryName(rest[1]),
                  let number = DeepLinkValidation.number(rest[2])
            else { return nil }
            return .issue(repo: RepoRef(owner: owner, name: name), number: number)

        case "inbox":
            guard rest.isEmpty else { return nil }
            guard let raw = singleQueryValue(named: "filter", in: components) else { return nil }
            // An empty `filter=` — a script whose variable was not set — means "no filter"
            // rather than a rejection; a filter that is present but unknown is an error,
            // because silently showing an unfiltered inbox would look like it worked.
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return .inbox(filter: nil) }
            guard let filter = InboxDeepLinkFilter(token: trimmed) else { return nil }
            return .inbox(filter: filter)

        case "sync":
            guard rest.isEmpty else { return nil }
            return .sync

        case "settings":
            if rest.isEmpty { return .settings(tab: .account) }
            guard rest.count == 1,
                  let tab = SettingsDeepLinkTab(token: rest[0])
            else { return nil }
            return .settings(tab: tab)

        default:
            return nil
        }
    }

    /// The URL's segments, host first, percent-decoded **after** splitting.
    ///
    /// Decoding after the split is what makes `shepherd://pr/a%2Fb/c/1` a link with an invalid
    /// owner (`a/b`) instead of a link with four segments: an encoded separator can never
    /// create structure.
    private static func pathSegments(of components: URLComponents) -> [String]? {
        var encoded: [String] = []
        if let host = components.percentEncodedHost, !host.isEmpty {
            encoded.append(host)
        }
        encoded += components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let decoded = encoded.compactMap { $0.removingPercentEncoding }
        guard decoded.count == encoded.count else { return nil }
        return decoded
    }

    /// The value of a query item that may appear at most once.
    /// - Returns: The value (possibly empty) when the item is absent or present exactly once,
    ///   `nil` when it is repeated — a repeated filter has no obvious winner, so it is refused.
    private static func singleQueryValue(
        named name: String,
        in components: URLComponents
    ) -> String? {
        let matches = (components.queryItems ?? [])
            .filter { $0.name.lowercased() == name }
        switch matches.count {
        case 0: return ""
        case 1: return matches[0].value ?? ""
        default: return nil
        }
    }

    // MARK: - Serialisation

    /// The canonical URL string for this link — what the `shepherd` CLI opens.
    ///
    /// Round-trips through ``parse(_:)`` for every value, which is the property the tests pin:
    /// the CLI cannot construct a link the app would refuse.
    public var urlString: String {
        switch self {
        case .pullRequest(let repo, let number):
            let owner = DeepLink.encode(repo.owner)
            let name = DeepLink.encode(repo.name)
            return "\(DeepLink.scheme)://pr/\(owner)/\(name)/\(number)"
        case .issue(let repo, let number):
            let owner = DeepLink.encode(repo.owner)
            let name = DeepLink.encode(repo.name)
            return "\(DeepLink.scheme)://issue/\(owner)/\(name)/\(number)"
        case .inbox(let filter):
            guard let filter else { return "\(DeepLink.scheme)://inbox" }
            return "\(DeepLink.scheme)://inbox?filter=\(DeepLink.encode(filter.token))"
        case .sync:
            return "\(DeepLink.scheme)://sync"
        case .settings(let tab):
            return "\(DeepLink.scheme)://settings/\(tab.token)"
        }
    }

    /// The canonical URL for this link.
    public var url: URL? { URL(string: urlString) }

    /// RFC 3986 unreserved characters: everything else is percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

/// One rail filter, addressable from a `shepherd://inbox?filter=…` link (ADR 0013).
///
/// The four view tokens are the inbox's smart views; the four facet tokens are the provenance
/// and repository facets. Which state each one produces is the app's decision (a facet filter
/// widens the smart view to "Involved", so `filter=bots` shows *every* bot pull request rather
/// than only the ones that also asked for a review).
///
/// ``issues`` is the odd one and deliberately so (ADR 0032): it names the inbox *section* rather
/// than a rail state, so it moves the content-kind picker and narrows nothing. That is what keeps
/// the grammar additive — one more token in a vocabulary that already existed, instead of a
/// second `shepherd://` command word for a screen that is the same screen.
public enum InboxDeepLinkFilter: Hashable, Sendable {
    /// Pull requests that asked for the user's review.
    case needsMyReview
    /// Pull requests the user opened.
    case myPullRequests
    /// Everything the user is involved in.
    case involved
    /// Pull requests that already carry an approval.
    case approvedByMe
    /// Human-authored pull requests.
    case humans
    /// Pull requests from generic bot accounts.
    case bots
    /// Pull requests from one detected agent (``AgentIdentity/id``).
    case agent(id: String)
    /// Pull requests from one repository.
    case repository(RepoRef)
    /// The issues section of the inbox, unnarrowed (ADR 0032).
    case issues

    /// The token used in the URL.
    public var token: String {
        switch self {
        case .needsMyReview: return "needs-my-review"
        case .myPullRequests: return "mine"
        case .involved: return "involved"
        case .approvedByMe: return "approved-by-me"
        case .humans: return "humans"
        case .bots: return "bots"
        case .agent(let id): return "agent:\(id)"
        case .repository(let repo): return "repo:\(repo.fullName)"
        case .issues: return "issues"
        }
    }

    /// Parses a filter token.
    ///
    /// The keyword half is matched case-insensitively (`Bots`, `AGENT:Claude-Code`); an agent
    /// id is lowercased, because registry ids are, while a repository keeps the casing it was
    /// given — GitHub treats owner and repository names case-insensitively and the app
    /// compares them that way (``RepoRef/isSameRepository(as:)``).
    /// - Parameter token: The raw token from the URL.
    public init?(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if let separator = trimmed.firstIndex(of: ":") {
            let keyword = trimmed[trimmed.startIndex..<separator].lowercased()
            let value = String(trimmed[trimmed.index(after: separator)...])
            switch keyword {
            case "agent":
                guard let id = DeepLinkValidation.agentID(value) else { return nil }
                self = .agent(id: id)
            case "repo":
                guard let repo = DeepLinkValidation.repository(fullName: value) else { return nil }
                self = .repository(repo)
            default:
                return nil
            }
            return
        }
        switch trimmed.lowercased() {
        case "needs-my-review": self = .needsMyReview
        case "mine": self = .myPullRequests
        case "involved": self = .involved
        case "approved-by-me": self = .approvedByMe
        case "humans": self = .humans
        case "bots": self = .bots
        case "issues": self = .issues
        default: return nil
        }
    }

    /// The tokens without an argument, in the order the documentation lists them.
    public static let keywordTokens = [
        "needs-my-review", "mine", "involved", "approved-by-me", "humans", "bots", "issues",
    ]
}

/// A Settings tab, addressable from a `shepherd://settings/<tab>` link (ADR 0013).
///
/// A routing token, not a view: the app maps each case onto its tab in one exhaustive switch,
/// so a tab added here without a home in Settings is a compile error rather than a dead link.
public enum SettingsDeepLinkTab: String, Hashable, Sendable, CaseIterable {
    /// Account, sign-out & erase.
    case account
    /// Sweep interval and notifications.
    case sync
    /// Saved replies and per-repository review templates.
    case replies
    /// The agent registry.
    case agents
    /// Intelligence tiers, endpoints and keys.
    case intelligence
    /// Delegation to a local agent CLI.
    case delegation
    /// Outbound webhooks.
    case automation
    /// Theme.
    case appearance

    /// The token used in the URL.
    public var token: String { rawValue }

    /// Parses a tab token, case-insensitively.
    /// - Parameter token: The raw token from the URL.
    public init?(token: String) {
        self.init(rawValue: token.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// The character rules deep-link input has to satisfy.
///
/// Kept in one place because both the URL parser and the CLI's argument parser validate the
/// same identifiers, and because "what exactly is accepted" is a security property worth being
/// able to read in one screen. Everything is ASCII-only on purpose: GitHub owners and
/// repository names are, and a homoglyph that merely *looks* like a login must not resolve.
enum DeepLinkValidation {
    /// A GitHub owner (user or organisation): 1–39 characters, letters, digits and hyphens,
    /// never starting or ending with a hyphen.
    static func owner(_ raw: String) -> String? {
        guard (1...39).contains(raw.count),
              !raw.hasPrefix("-"),
              !raw.hasSuffix("-"),
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return raw
    }

    /// A GitHub repository name: 1–100 characters, letters, digits, `-`, `_` and `.`, and
    /// never the traversal-shaped `.` or `..`.
    static func repositoryName(_ raw: String) -> String? {
        guard (1...100).contains(raw.count),
              raw != ".",
              raw != "..",
              raw.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
              })
        else { return nil }
        return raw
    }

    /// An `owner/name` pair.
    static func repository(fullName: String) -> RepoRef? {
        guard let parsed = RepoRef.parse(fullName: fullName),
              let owner = owner(parsed.owner),
              let name = repositoryName(parsed.name)
        else { return nil }
        return RepoRef(owner: owner, name: name)
    }

    /// A pull-request or issue number: 1–9 ASCII digits, greater than zero.
    ///
    /// One rule for both, because GitHub draws them from one sequence per repository.
    static func number(_ raw: String) -> Int? {
        guard (1...9).contains(raw.count),
              raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(raw),
              value > 0
        else { return nil }
        return value
    }

    /// An agent-registry id: 1–64 characters, letters, digits, `-`, `_` and `.`, lowercased.
    static func agentID(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        guard (1...64).contains(lowered.count),
              lowered.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
              })
        else { return nil }
        return lowered
    }
}
