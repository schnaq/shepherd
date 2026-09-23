import AppIntents
import Foundation

/// The shortcuts Shepherd offers without the user building one (ADR 0021).
///
/// An `AppShortcutsProvider` is what puts an action in the Shortcuts app's gallery, in Spotlight's
/// action results and — the part that costs thought — in Siri's vocabulary the moment the app is
/// installed. Every phrase must contain `\(.applicationName)`; that is a system requirement and
/// also the right thing, because "sync" on its own belongs to no app.
///
/// Five, deliberately. The list is what a user would want *without being asked to configure
/// anything*, and every entry on it is navigation or a read:
///
/// - the review queue, which is the app's whole reason for existing;
/// - the count, the one thing worth having as a spoken answer rather than a window;
/// - a sweep, the equivalent of ⌘R;
/// - the focus session, the one command that does something a click cannot do faster;
/// - the summary of the next review (plan §3.H), the second thing worth *hearing* rather than
///   reading — and the only phrase here that runs a model, on-device only.
///
/// The phrases here are English, including both spellings of *summarise*, because Siri matches a
/// phrase literally and a user who says "summarize" is asking for the same thing. Their German
/// utterances live in `Resources/AppShortcuts.xcstrings` (ADR 0022's Siri-phrases amendment), one per
/// English key — not in `Localizable.xcstrings`, because the App Intents metadata processor looks
/// them up in a catalog of exactly that name, which is also why `Scripts/check-localization.py`
/// leaves it alone.
///
/// Nothing that writes to GitHub is here, and nothing that writes to GitHub exists as an intent at
/// all — see the note in `ShepherdIntents.swift` and ADR 0021. A Siri phrase that could approve a
/// pull request is precisely the failure mode this feature had to be designed against.
struct ShepherdShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowInboxIntent(filter: .needsMyReview),
            phrases: [
                "Open my review queue in \(.applicationName)",
                "Show my review queue in \(.applicationName)",
            ],
            shortTitle: "Review queue",
            systemImageName: "tray.full"
        )
        AppShortcut(
            intent: GetReviewQueueIntent(),
            phrases: [
                "What needs my review in \(.applicationName)",
                "How many pull requests need me in \(.applicationName)",
            ],
            shortTitle: "Needs my review",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: [
                "Sync \(.applicationName)",
            ],
            shortTitle: "Sync now",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: StartFocusSessionIntent(),
            phrases: [
                "Start a review session in \(.applicationName)",
            ],
            shortTitle: "Review session",
            systemImageName: "play.circle"
        )
        AppShortcut(
            // No pull request pre-filled: the phrase says "my next review", and the intent's
            // optional parameter is what turns that into the top of the review queue while the
            // same action still takes an entity a shortcut hands it (plan §3.H).
            intent: SummarizePullRequestIntent(pullRequest: nil),
            phrases: [
                "Summarise my next review in \(.applicationName)",
                "Summarize my next review in \(.applicationName)",
                "What's my next review about in \(.applicationName)",
            ],
            shortTitle: "Summarise a review",
            systemImageName: "sparkles"
        )
    }
}
