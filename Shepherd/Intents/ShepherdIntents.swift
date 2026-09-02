import AppIntents
import Foundation
import ShepherdCore

// MARK: - Parameter vocabularies
//
// The two enums below mirror ``ShepherdCore/InboxDeepLinkFilter`` and
// ``ShepherdCore/SettingsDeepLinkTab``, and they mirror them *by token* rather than by case: the
// raw value of each case is the exact string the `shepherd://` grammar uses, so the mapping is
// `init(token:)` and there is no second table of "which case means which filter" to keep in step.
// `SystemIntegrationTests` asserts the two vocabularies are the same size and that every raw value
// resolves, which is what turns "somebody added a Settings tab" into a failing test rather than
// into a Shortcuts action that silently opens the Account tab.

/// One inbox filter, offered as a Shortcuts parameter (ADR 0021).
///
/// Only the *keyword* half of ``ShepherdCore/InboxDeepLinkFilter`` can be an `AppEnum`: `agent:<id>`
/// and `repo:<owner>/<name>` carry a payload, and an enum case cannot. That is not a gap worth
/// closing with a free-text parameter — a mistyped agent id would produce an empty inbox with no
/// explanation, while `shepherd://inbox?filter=agent:claude-code` already serves the scripted case
/// and says so when the token is wrong (ADR 0013).
enum InboxFilterOption: String, AppEnum, CaseIterable {
    /// Pull requests that asked for the user's review.
    case needsMyReview = "needs-my-review"
    /// Pull requests the user opened.
    case mine
    /// Everything the user is involved in.
    case involved
    /// Pull requests that already carry the user's approval.
    case approvedByMe = "approved-by-me"
    /// Human-authored pull requests.
    case humans
    /// Pull requests from bot accounts.
    case bots

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Inbox Filter")
    }

    static var caseDisplayRepresentations: [InboxFilterOption: DisplayRepresentation] {
        [
            .needsMyReview: DisplayRepresentation(title: "Needs my review"),
            .mine: DisplayRepresentation(title: "My pull requests"),
            .involved: DisplayRepresentation(title: "Involved"),
            .approvedByMe: DisplayRepresentation(title: "Approved by me"),
            .humans: DisplayRepresentation(title: "People"),
            .bots: DisplayRepresentation(title: "Bots"),
        ]
    }

    /// The deep-link filter this option stands for.
    ///
    /// Never `nil` in practice — every raw value here is a token
    /// ``ShepherdCore/InboxDeepLinkFilter/init(token:)`` accepts, and a test pins that — but the
    /// parser is the authority on its own vocabulary and is not going to be second-guessed with a
    /// force-unwrap in a code path Siri can reach.
    var deepLinkFilter: InboxDeepLinkFilter? { InboxDeepLinkFilter(token: rawValue) }
}

/// One Settings tab, offered as a Shortcuts parameter (ADR 0021).
enum SettingsTabOption: String, AppEnum, CaseIterable {
    /// Account, sign-out & erase.
    case account
    /// Sweep interval, notifications, the morning digest and encrypted sync.
    case sync
    /// Saved replies and per-repository review templates.
    case replies
    /// The agent registry.
    case agents
    /// Intelligence tiers, the search index and the Spotlight export.
    case intelligence
    /// Delegation to a local agent CLI.
    case delegation
    /// Webhooks and automatic merging.
    case automation
    /// Theme and the menu-bar item.
    case appearance

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Settings Tab")
    }

    static var caseDisplayRepresentations: [SettingsTabOption: DisplayRepresentation] {
        [
            .account: DisplayRepresentation(title: "Account"),
            .sync: DisplayRepresentation(title: "Sync"),
            .replies: DisplayRepresentation(title: "Replies"),
            .agents: DisplayRepresentation(title: "Agents"),
            .intelligence: DisplayRepresentation(title: "Intelligence"),
            .delegation: DisplayRepresentation(title: "Delegation"),
            .automation: DisplayRepresentation(title: "Automation"),
            .appearance: DisplayRepresentation(title: "Appearance"),
        ]
    }

    /// The deep-link tab this option stands for.
    var deepLinkTab: SettingsDeepLinkTab? { SettingsDeepLinkTab(token: rawValue) }
}

// MARK: - Intents
//
// Every intent below is a *typed front for ADR 0013's grammar*. It resolves its parameters, builds
// a `DeepLink`, and hands it to `AppEnvironment.open(_:)` — the same call `onOpenURL` makes for a
// `shepherd://` URL from the terminal, Raycast or an n8n Execute Command node. So "open a pull
// request", "show the inbox filtered", "sync now" and "open Settings on a tab" have exactly one
// implementation each, including the awkward parts of it: the queue-until-signed-in slot, the
// individual fetch for a pull request that is not in the cache, and the toast when it fails.
//
// What is deliberately absent is the whole write half. There is no ApproveIntent, no MergeIntent,
// no SubmitReviewIntent and no DelegateIntent, and that is the decision ADR 0021 exists to record:
// an intent runs without the review screen in front of the user, frequently from a voice request,
// so a verdict formed there would be a verdict formed without anybody having read the diff — which
// is the line ADR 0016 and ADR 0018 draw and CONTRIBUTING.md states as a rule.

/// Opens one pull request's review screen (ADR 0021).
struct OpenPullRequestIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Pull Request" }

    /// This intent's whole effect is on screen, so the app comes forward with it.
    static var openAppWhenRun: Bool { true }

    /// The pull request to open.
    @Parameter(title: "Pull Request")
    var pullRequest: PullRequestEntity

    /// Required by `AppIntent`: the system creates intents with no arguments.
    init() {}

    /// Creates a pre-filled intent, for ``ShepherdShortcuts``.
    /// - Parameter pullRequest: The pull request to open.
    init(pullRequest: PullRequestEntity) {
        self.pullRequest = pullRequest
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let (environment, session) = try IntentBridge.requireSession()
        // The entity is a handle, not a snapshot: the repository and number come from today's row,
        // and a shortcut built against a pull request that has since been merged says so rather
        // than opening whatever now has that number.
        guard let row = PullRequestIdentifierLookup.row(
            nodeID: pullRequest.id,
            in: session.inboxRows
        ) else {
            throw IntentFailure.pullRequestNotAvailable(slug: pullRequest.slug)
        }
        environment.open(.pullRequest(repo: row.repo, number: row.number))
        environment.revealWindow()
        return .result()
    }
}

/// Shows the inbox, optionally with one rail filter applied (ADR 0021).
struct ShowInboxIntent: AppIntent {
    static var title: LocalizedStringResource { "Show Inbox" }

    static var openAppWhenRun: Bool { true }

    /// Which rail filter to apply. Nothing means the inbox as the user left it.
    @Parameter(title: "Filter")
    var filter: InboxFilterOption?

    /// Required by `AppIntent`.
    init() {}

    /// Creates a pre-filled intent, for ``ShepherdShortcuts``.
    /// - Parameter filter: The rail filter, or `nil` for the inbox as it is.
    init(filter: InboxFilterOption?) {
        self.filter = filter
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // No session is required: `open(_:)` queues a link that arrives before sign-in and replays
        // it afterwards (ADR 0013), and telling the user to sign in is the toast's job, not this
        // intent's. A Shortcut fired at login is exactly the case that mechanism exists for.
        let environment = try IntentBridge.requireEnvironment()
        environment.open(.inbox(filter: filter?.deepLinkFilter))
        environment.revealWindow()
        return .result()
    }
}

/// Runs one sweep now — the ⌘R path (ADR 0021).
struct SyncNowIntent: AppIntent {
    static var title: LocalizedStringResource { "Sync Now" }

    /// True even though nothing about a sweep is visual, because a sweep needs the running app.
    ///
    /// An intent that did not open the app would be launched into a process with no window, where
    /// nothing has read the Keychain and there is therefore no session to sync — the deep link
    /// would be queued against a sign-in that never happens, and the shortcut would report success
    /// having done nothing. Opening the app is the honest cost of the only intent that performs
    /// work rather than navigation.
    static var openAppWhenRun: Bool { true }

    /// Required by `AppIntent`.
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = try IntentBridge.requireEnvironment()
        environment.open(.sync)
        return .result(dialog: "Syncing Shepherd.")
    }
}

/// Starts the focus review session (ADR 0021).
struct StartFocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Review Session" }

    static var openAppWhenRun: Bool { true }

    /// Required by `AppIntent`.
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (environment, _) = try IntentBridge.requireSession()
        // The one exception to "route through `DeepLink`", and it is a deliberate one: the focus
        // session has no `shepherd://` command. The grammar is a public interface that the CLI's
        // argument parser, its `--help` output and the README's URL table all restate (ADR 0013),
        // so adding a command to it is its own additive change with its own obligations — not
        // something an App Intent may drag in as a side effect. What this calls instead *is* the
        // single implementation: `startReviewSession()` is the method the Review menu, `r f`, the
        // ⌘K palette and the inbox header's button all reach through a `PendingAction`, and it
        // freezes its queue from the session's own rows, so it does not care which surface asked.
        let started = environment.startReviewSession()
        environment.revealWindow()
        // Spoken, because Siri is the one caller with nothing to look at: the toast that says
        // "nothing needs your review" is on a screen the person asking may not be facing.
        let dialog = started
            ? IntentDialog("Review session started.")
            : IntentDialog("Nothing needs your review right now.")
        return .result(dialog: dialog)
    }
}

/// Opens Settings on a tab (ADR 0021).
struct OpenSettingsIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Shepherd Settings" }

    static var openAppWhenRun: Bool { true }

    /// Which tab to open.
    @Parameter(title: "Tab")
    var tab: SettingsTabOption

    /// Required by `AppIntent`.
    init() {}

    /// Creates a pre-filled intent, for ``ShepherdShortcuts``.
    /// - Parameter tab: The tab to open.
    init(tab: SettingsTabOption) {
        self.tab = tab
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let environment = try IntentBridge.requireEnvironment()
        // `.account` is the grammar's own default for a `shepherd://settings` with no tab, so an
        // unresolvable token lands where the URL scheme lands it rather than nowhere.
        environment.open(.settings(tab: tab.deepLinkTab ?? .account))
        environment.revealWindow()
        return .result()
    }
}

/// Answers "how many pull requests need me, and which ones" — the one read-only intent (ADR 0021).
///
/// It exists because it is the question a Shortcut can *use*: a count on a Stream Deck, a line in
/// a status bar, a HomeKit-shaped "if anything is waiting, tell me". It reads the local database
/// and nothing else — no GitHub call, so it is safe to fire on a five-minute automation without
/// spending rate limit or waking the network — and it returns the same ordered queue the menu-bar
/// badge, the focus session and the morning digest read (``PullRequestEntity/reviewQueue(limit:)``).
///
/// It is also the only intent that does **not** open the app, which is the whole point of it: a
/// shortcut that answered "3 pull requests need you" by putting the inbox on screen would have
/// answered a different question. The cost is stated rather than papered over — Shepherd has to be
/// running, and when it is not the intent says so instead of reporting a reassuring zero.
struct GetReviewQueueIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Pull Requests Needing Review" }

    /// False: reading a count must not steal the user's focus. See the type's discussion.
    static var openAppWhenRun: Bool { false }

    /// Required by `AppIntent`.
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[PullRequestEntity]>
        & ProvidesDialog
    {
        // Throws rather than answering an empty list: "no account is signed in" and "nothing needs
        // your review" are different facts, and a shortcut told the second when the first is true
        // would quietly stop reporting real work.
        _ = try IntentBridge.requireSession()
        let queue = PullRequestEntity.reviewQueue()
        return .result(value: queue, dialog: Self.dialog(count: queue.count))
    }

    /// The spoken answer. Singular and plural are written out because Siri reads this aloud.
    /// - Parameter count: How many pull requests are waiting.
    /// - Returns: The dialog.
    private static func dialog(count: Int) -> IntentDialog {
        switch count {
        case 0: return IntentDialog("Nothing needs your review.")
        case 1: return IntentDialog("1 pull request needs your review.")
        default: return IntentDialog("\(count) pull requests need your review.")
        }
    }
}
