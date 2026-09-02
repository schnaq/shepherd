import Foundation
import Observation

/// One translation's identity: the exact text that was translated, and the language it was
/// translated *into*.
///
/// The key is the text itself rather than a hash of it. A hash would be smaller, but a collision
/// would put somebody else's sentence under a reviewer's comment — the one failure this feature
/// cannot have — and the saving is imaginary: the string is a `String` the model already holds, so
/// the key stores a reference to the same storage rather than a copy. Hashing still happens, of
/// course; it happens where a dictionary is allowed to be wrong about equality, which is nowhere.
///
/// The target language is part of the key because the cache outlives a language change: a reviewer
/// who switches the system language mid-session must not be shown yesterday's German under a
/// French UI.
struct TranslationKey: Hashable, Sendable {
    /// The original text, verbatim.
    let text: String
    /// The language the text was translated into.
    let target: Locale.Language
}

/// Where one translation has got to.
///
/// There is deliberately no `idle` case: "never asked for" is the absence of an entry, so the
/// button's default state cannot be confused with a finished translation of an empty string.
enum TranslationState: Sendable, Equatable {
    /// A `TranslationSession` is working on it.
    case translating
    /// The translated text, ready to be shown below the original.
    case translated(String)
    /// The translation failed, with the framework's own reason in the user's language.
    case failed(String)
}

/// The in-memory translation cache for one screen (ADR 0020).
///
/// Everything about this type is chosen so that translating is cheap to *repeat* and impossible to
/// *keep*:
///
/// - **Nothing is persisted.** No `UserDefaults`, no GRDB table, no field in
///   `SyncedSettingsDocument` — so the standing ADR 0014 obligation ("adding a setting means
///   carrying it in both directions of the applier") does not apply, because this is not a setting.
///   A translation is a reading aid for the minute you are reading in; it is not a fact about the
///   pull request, and storing it would create a second, staler copy of somebody else's words.
/// - **It is owned by a view, not by `AppEnvironment`.** The conversation tab and each thread
///   popover create their own, which is what "for the screen's lifetime" means. A shared singleton
///   would keep every comment of every pull request a reviewer looked at today in memory for the
///   whole session, to save a translation that takes a second to redo.
/// - **It survives view identity, which is the whole point.** A sync sweep replaces
///   `model.detail`, a `ForEach` rebuilds its rows, the reviewer switches to Files and back — all
///   of that discards `@State` and none of it should discard the translation the reviewer is in the
///   middle of reading. Keying on the text means the same comment finds its translation again even
///   though the view showing it is a different view.
///
/// The cache is bounded: a conversation with several hundred comments must not be able to double
/// the app's memory by being scrolled through with the button pressed. Eviction is
/// oldest-request-first, which is the right order here — the entry a reviewer is looking at is the
/// one they asked for last.
@MainActor
@Observable
final class TranslationCoordinator {
    /// The states, keyed by text and target language.
    private var states: [TranslationKey: TranslationState] = [:]
    /// The keys in the order they were first requested, so eviction has an oldest to pick.
    private var order: [TranslationKey] = []
    /// The keys whose translation block the reviewer has collapsed.
    ///
    /// Stored as the *exception* rather than as a `Bool` per entry so that a fresh translation is
    /// visible without anybody having to remember to say so.
    private var collapsed: Set<TranslationKey> = []
    /// How many translations are kept before the oldest is dropped.
    private let capacity: Int

    /// Creates an empty cache.
    /// - Parameter capacity: How many translations to keep. The default is generous for one
    ///   conversation and small enough that the cache cannot become the app's memory story; tests
    ///   pass something tiny to observe the eviction.
    init(capacity: Int = 128) {
        self.capacity = capacity
    }

    /// The state of one translation, or `nil` when it was never asked for.
    /// - Parameter key: The text and target language.
    /// - Returns: The state, or `nil`.
    func state(for key: TranslationKey) -> TranslationState? {
        states[key]
    }

    /// Records that a session has been asked for this text.
    ///
    /// Also un-collapses the block: pressing *Translate* again after hiding a translation has to
    /// show one, or the button would look broken.
    /// - Parameter key: The text and target language.
    func begin(_ key: TranslationKey) {
        collapsed.remove(key)
        record(.translating, for: key)
    }

    /// Stores a finished translation.
    /// - Parameters:
    ///   - translated: The translated text, exactly as the framework returned it.
    ///   - key: The text and target language it was made for.
    func finish(_ translated: String, for key: TranslationKey) {
        record(.translated(translated), for: key)
    }

    /// Stores a failure, so the UI can say why instead of silently doing nothing.
    /// - Parameters:
    ///   - message: The localized reason.
    ///   - key: The text and target language it was made for.
    func fail(_ message: String, for key: TranslationKey) {
        record(.failed(message), for: key)
    }

    /// Whether the translation block is currently shown.
    /// - Parameter key: The text and target language.
    /// - Returns: `true` unless the reviewer collapsed it.
    func isVisible(_ key: TranslationKey) -> Bool {
        !collapsed.contains(key)
    }

    /// Shows or collapses the translation block.
    ///
    /// Note what this cannot do: it never hides the *original*. The original is not drawn by this
    /// type and has no toggle anywhere in the feature (ADR 0020) — a reviewer always sees what was
    /// actually written.
    /// - Parameters:
    ///   - visible: Whether the translation should be shown.
    ///   - key: The text and target language.
    func setVisible(_ visible: Bool, for key: TranslationKey) {
        if visible {
            collapsed.remove(key)
        } else {
            collapsed.insert(key)
        }
    }

    /// How many translations are cached, including in-flight ones. Used by tests.
    var count: Int { states.count }

    /// Writes a state and trims the cache back to ``capacity``.
    private func record(_ state: TranslationState, for key: TranslationKey) {
        if states[key] == nil {
            order.append(key)
        }
        states[key] = state
        while order.count > capacity {
            let oldest = order.removeFirst()
            states[oldest] = nil
            collapsed.remove(oldest)
        }
    }
}
