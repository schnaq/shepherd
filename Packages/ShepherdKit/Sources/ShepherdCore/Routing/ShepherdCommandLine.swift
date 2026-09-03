import Foundation

/// The `shepherd` CLI's argument grammar: argv in, a ``DeepLink`` out (ADR 0013).
///
/// The CLI is a URL builder and nothing more — it has no network code, no token, no database
/// and no knowledge of GitHub. Everything it can ask for, it asks for through the URL scheme,
/// which is the same channel Raycast, n8n or a shell script uses. This type is that mapping,
/// kept next to ``DeepLink`` on purpose: the grammar the CLI writes and the grammar the app
/// reads are one source of truth, tested together, and neither can drift.
///
/// ```
/// shepherd open <owner>/<repo>#<number>
/// shepherd open <owner>/<repo>/<number>
/// shepherd open https://github.com/<owner>/<repo>/pull/<number>
/// shepherd issue <owner>/<repo>#<number>
/// shepherd issue <owner>/<repo>/<number>
/// shepherd issue https://github.com/<owner>/<repo>/issues/<number>
/// shepherd inbox [<filter> | --filter <filter>]
/// shepherd sync
/// shepherd settings [<tab>]
/// shepherd --help | --version
/// ```
public enum ShepherdCommandLine {
    /// What one invocation asks for.
    public enum Invocation: Hashable, Sendable {
        /// Hand a deep link to the app.
        case open(DeepLink)
        /// Print the usage text.
        case help
        /// Print the version.
        case version
    }

    /// Why an invocation could not be understood.
    ///
    /// The messages are plain English, deliberately not localised: console output follows the
    /// developer documentation, not the app's UI language rules (`CONTRIBUTING.md`).
    public enum Failure: LocalizedError, Equatable {
        /// The first argument is not a known command.
        case unknownCommand(String)
        /// A command needs an argument that was not given.
        case missingArgument(command: String, expected: String)
        /// There were more arguments than the command takes.
        case unexpectedArgument(String)
        /// An option the command does not have.
        case unknownOption(String)
        /// The pull-request reference is not `owner/repo#number` or a github.com pull URL.
        case invalidPullRequestReference(String)
        /// The issue reference is not `owner/repo#number` or a github.com issue URL.
        ///
        /// A case of its own rather than a reused one, because the two messages have to name
        /// different example URLs: somebody who typed a `/pull/` link at `shepherd issue`
        /// needs to be told which of the two verbs they wanted.
        case invalidIssueReference(String)
        /// The inbox filter is not one of the known tokens.
        case invalidInboxFilter(String)
        /// The settings tab is not one of the known tabs.
        case unknownSettingsTab(String)

        public var errorDescription: String? {
            switch self {
            case .unknownCommand(let command):
                return "Unknown command “\(command)”. Run “shepherd --help”."
            case .missingArgument(let command, let expected):
                return "“shepherd \(command)” needs \(expected)."
            case .unexpectedArgument(let argument):
                return "Unexpected argument “\(argument)”."
            case .unknownOption(let option):
                return "Unknown option “\(option)”."
            case .invalidPullRequestReference(let reference):
                return """
                    Could not read “\(reference)” as a pull request. Use owner/repo#123, \
                    owner/repo/123, or a https://github.com/owner/repo/pull/123 URL.
                    """
            case .invalidIssueReference(let reference):
                return """
                    Could not read “\(reference)” as an issue. Use owner/repo#123, \
                    owner/repo/123, or a https://github.com/owner/repo/issues/123 URL.
                    """
            case .invalidInboxFilter(let filter):
                return """
                    Unknown inbox filter “\(filter)”. Use one of \
                    \(InboxDeepLinkFilter.keywordTokens.joined(separator: ", ")), \
                    agent:<id> or repo:<owner>/<name>.
                    """
            case .unknownSettingsTab(let tab):
                return """
                    Unknown settings tab “\(tab)”. Use one of \
                    \(SettingsDeepLinkTab.allCases.map(\.token).joined(separator: ", ")).
                    """
            }
        }
    }

    /// The usage text printed by `--help` and by a bare `shepherd`.
    public static let usage = """
        shepherd — drive Shepherd, the macOS review inbox, from the command line.

        USAGE
          shepherd open <pull request>     Open a pull request in Shepherd's review screen
          shepherd issue <issue>           Open an issue in Shepherd's issues inbox
          shepherd inbox [<filter>]        Show the inbox, optionally filtered
          shepherd sync                    Sweep every repository now
          shepherd settings [<tab>]        Open Settings on a tab
          shepherd --help | --version

        PULL REQUEST
          owner/repo#123
          owner/repo/123
          https://github.com/owner/repo/pull/123

        ISSUE
          owner/repo#123
          owner/repo/123
          https://github.com/owner/repo/issues/123

        INBOX FILTERS
          needs-my-review, mine, involved, approved-by-me, issues
          humans, bots, agent:<id>, repo:<owner>/<name>

        SETTINGS TABS
          account, sync, agents, intelligence, delegation, automation, appearance

        EXAMPLES
          shepherd open schnaq/review#42
          shepherd issue schnaq/review#128
          shepherd inbox issues
          shepherd inbox needs-my-review
          shepherd inbox --filter agent:claude-code
          shepherd sync

        Every command works by opening a shepherd:// URL, so Shepherd itself does the work —
        the CLI never talks to GitHub and never sees a token.
        """

    /// Parses one invocation.
    /// - Parameter arguments: argv **without** the executable name.
    /// - Returns: What the invocation asks for.
    /// - Throws: ``Failure`` when the arguments cannot be understood.
    public static func parse(_ arguments: [String]) throws -> Invocation {
        guard let command = arguments.first else { return .help }
        if arguments.contains(where: { $0 == "--help" || $0 == "-h" || $0 == "help" }) {
            return .help
        }
        if arguments.contains(where: { $0 == "--version" || $0 == "-v" || $0 == "version" }) {
            return .version
        }

        let rest = Array(arguments.dropFirst())
        switch command {
        case "open":
            guard let reference = rest.first else {
                throw Failure.missingArgument(command: "open", expected: "a pull request")
            }
            if let extra = rest.dropFirst().first { throw Failure.unexpectedArgument(extra) }
            guard let link = pullRequestLink(for: reference) else {
                throw Failure.invalidPullRequestReference(reference)
            }
            return .open(link)

        case "issue":
            // The same three spellings `open` takes, with `/issues/` in place of `/pull/` in the
            // browser form (ADR 0032). A verb of its own rather than a flag on `open`, because
            // the grammar is a public interface and `shepherd open --issue` would make the
            // existing verb's meaning depend on an option (ADR 0013: additive only).
            guard let reference = rest.first else {
                throw Failure.missingArgument(command: "issue", expected: "an issue")
            }
            if let extra = rest.dropFirst().first { throw Failure.unexpectedArgument(extra) }
            guard let link = issueLink(for: reference) else {
                throw Failure.invalidIssueReference(reference)
            }
            return .open(link)

        case "inbox":
            guard let token = try filterToken(in: rest) else { return .open(.inbox(filter: nil)) }
            guard let filter = InboxDeepLinkFilter(token: token) else {
                throw Failure.invalidInboxFilter(token)
            }
            return .open(.inbox(filter: filter))

        case "sync":
            if let extra = rest.first { throw Failure.unexpectedArgument(extra) }
            return .open(.sync)

        case "settings":
            guard let token = rest.first else { return .open(.settings(tab: .account)) }
            if let extra = rest.dropFirst().first { throw Failure.unexpectedArgument(extra) }
            guard let tab = SettingsDeepLinkTab(token: token) else {
                throw Failure.unknownSettingsTab(token)
            }
            return .open(.settings(tab: tab))

        default:
            throw Failure.unknownCommand(command)
        }
    }

    /// Reads the inbox filter from `inbox`'s arguments, positional or as `--filter`.
    private static func filterToken(in arguments: [String]) throws -> String? {
        guard let first = arguments.first else { return nil }
        if first == "--filter" {
            guard let value = arguments.dropFirst().first else {
                throw Failure.missingArgument(command: "inbox --filter", expected: "a filter")
            }
            if let extra = arguments.dropFirst(2).first {
                throw Failure.unexpectedArgument(extra)
            }
            return value
        }
        if let value = optionValue(of: first, named: "--filter") {
            if let extra = arguments.dropFirst().first { throw Failure.unexpectedArgument(extra) }
            return value
        }
        if first.hasPrefix("-") { throw Failure.unknownOption(first) }
        if let extra = arguments.dropFirst().first { throw Failure.unexpectedArgument(extra) }
        return first
    }

    /// The value of a `--name=value` argument.
    /// - Parameters:
    ///   - argument: The argument to read.
    ///   - name: The option including its dashes, e.g. `"--filter"`.
    /// - Returns: The value, or `nil` when the argument is not that option in `=` form.
    private static func optionValue(of argument: String, named name: String) -> String? {
        let prefix = name + "="
        guard argument.hasPrefix(prefix) else { return nil }
        return String(argument.dropFirst(prefix.count))
    }

    /// Reads the three accepted spellings of a pull-request reference.
    ///
    /// Pure string work: the github.com form is accepted because that is what a browser puts on
    /// the clipboard, not because the CLI ever fetches it.
    static func pullRequestLink(for reference: String) -> DeepLink? {
        nodeLink(for: reference, browserSegment: "pull") {
            DeepLink.pullRequest(repo: $0, number: $1)
        }
    }

    /// Reads the three accepted spellings of an issue reference (ADR 0032).
    ///
    /// The pull-request reader with two things changed: the browser form's `/pull/` becomes
    /// `/issues/`, and the value built at the end is ``DeepLink/issue(repo:number:)``. Sharing
    /// the body rather than copying it is what keeps `shepherd issue` from accidentally
    /// accepting a slightly different set of references than `shepherd open` — a `#` with no
    /// number, a third path segment, a non-ASCII owner all have to be refused identically.
    static func issueLink(for reference: String) -> DeepLink? {
        nodeLink(for: reference, browserSegment: "issues") {
            DeepLink.issue(repo: $0, number: $1)
        }
    }

    /// The shared reader behind ``pullRequestLink(for:)`` and ``issueLink(for:)``.
    /// - Parameters:
    ///   - reference: What the user typed.
    ///   - browserSegment: The github.com path segment that identifies the kind — `pull` or
    ///     `issues`. It is matched exactly, so a `/pull/` link handed to `shepherd issue` is a
    ///     refusal with a message naming the right verb rather than a link to the wrong screen.
    ///   - make: Builds the link once the repository and number have been validated.
    private static func nodeLink(
        for reference: String,
        browserSegment: String,
        make: (RepoRef, Int) -> DeepLink
    ) -> DeepLink? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            return gitHubLink(for: trimmed, browserSegment: browserSegment, make: make)
        }

        // owner/repo#123
        if let hash = trimmed.lastIndex(of: "#") {
            let fullName = String(trimmed[trimmed.startIndex..<hash])
            let numberText = String(trimmed[trimmed.index(after: hash)...])
            return link(fullName: fullName, number: numberText, make: make)
        }
        // owner/repo/123
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return link(fullName: "\(parts[0])/\(parts[1])", number: String(parts[2]), make: make)
    }

    /// `https://github.com/<owner>/<repo>/<pull|issues>/<number>`, with anything after the number
    /// (`/files`, a query, a comment anchor) ignored.
    private static func gitHubLink(
        for reference: String,
        browserSegment: String,
        make: (RepoRef, Int) -> DeepLink
    ) -> DeepLink? {
        guard let components = URLComponents(string: reference),
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com"
        else { return nil }
        let segments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { String($0).removingPercentEncoding }
        guard segments.count >= 4, segments[2].lowercased() == browserSegment else { return nil }
        return link(fullName: "\(segments[0])/\(segments[1])", number: segments[3], make: make)
    }

    private static func link(
        fullName: String,
        number: String,
        make: (RepoRef, Int) -> DeepLink
    ) -> DeepLink? {
        guard let repo = DeepLinkValidation.repository(fullName: fullName),
              let number = DeepLinkValidation.number(number)
        else { return nil }
        return make(repo, number)
    }
}
