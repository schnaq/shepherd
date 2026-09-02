import Foundation
import SwiftUI
import Translation

/// A pull-request body or comment, with an on-device translation *added below it* on request
/// (ADR 0020).
///
/// This is the only translation surface in the app, and it is deliberately a decoration on
/// ``MarkdownText`` rather than a replacement for it:
///
/// - **The original is never replaced, moved or hidden.** It is drawn first, by the same view that
///   draws it everywhere else, and it stays on screen while the translation is fetched, while it is
///   shown, and after it is collapsed. A reviewer approves or rejects what was *written*, so the
///   words they act on must be the words the author typed. There is therefore no "show original"
///   control anywhere in this view: nothing ever took the original away.
/// - **Nothing happens until the button is pressed.** No text is translated on appear, on scroll or
///   on sync. What runs unasked is one language check per body, entirely on-device
///   (`NLLanguageRecognizer` plus `LanguageAvailability`), and its only effect is whether a button
///   is drawn.
/// - **The translation is on-device, always, and there is no setting for that.** It goes through
///   Apple's `TranslationSession`; a configured BYOK provider (ADR 0007 tier 3) is not consulted
///   and cannot be, because no code path here can reach `IntelligenceRouter`. Comment text is
///   exactly the kind of content that must not travel because a reviewer wanted to *read* it.
///
/// The `Translation` and `NaturalLanguage` imports live here and in ``TranslationOffer`` and
/// nowhere else — never in `ShepherdKit`, which must keep building on Linux
/// (`docs/ARCHITECTURE.md`, dependency rule).
struct TranslatableMarkdownText: View {
    /// The Markdown source, as GitHub sent it.
    let markdown: String
    /// The screen's translation cache.
    let translations: TranslationCoordinator
    /// The font size handed to ``MarkdownText``.
    var size: CGFloat = 12.5

    /// What may be offered for this text; `nil` until the language check has answered.
    @State private var eligibility: TranslationEligibility?
    /// The session configuration, non-`nil` once the reviewer has asked for a translation.
    ///
    /// `.translationTask` starts a session when this changes and holds it while the value stays
    /// non-`nil`. It is kept rather than cleared on completion so that a retry — and a body that
    /// changes under the same view — can re-run the same session through
    /// `TranslationSession.Configuration.invalidate()`, which is the framework's own way of saying
    /// "again, with these settings".
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        // Both are read once, here, so the job below carries two `Sendable` values — a value type
        // and a `@MainActor` reference — instead of capturing `self` and dragging the view's
        // `@State` across an isolation boundary.
        let requested = key
        let store = translations

        VStack(alignment: .leading, spacing: 6) {
            MarkdownText(markdown: markdown, size: size)
            controls
            translationBlock
        }
        .task(id: markdown) {
            eligibility = await TranslationOffer.eligibility(for: markdown, target: target)
        }
        .translationTask(configuration, action: TranslationJob(requested: requested, store: store).run)
    }

    /// The work a `TranslationSession` does for one request, kept off the main actor on purpose.
    ///
    /// A closure literal written inline in `body` would inherit the view's `@MainActor` isolation,
    /// and `TranslationSession.translate(_:)` is a nonisolated `async` call on a non-`Sendable`
    /// object — Swift 6 rejects that as "sending 'session' risks causing data races", because the
    /// session would cross from the main actor to the generic executor. A nonisolated method on a
    /// `Sendable` value has no isolation to leave: the session is handed in by the framework, is
    /// used here, and never leaves. The only things that travel back to the main actor are two
    /// `Sendable` values — the key and the translated (or error) `String`.
    private struct TranslationJob: Sendable {
        let requested: TranslationKey
        let store: TranslationCoordinator

        nonisolated func run(_ session: TranslationSession) async {
            do {
                let response = try await session.translate(requested.text)
                let translated = response.targetText
                await MainActor.run { store.finish(translated, for: requested) }
            } catch {
                // Apple's `TranslationError` — an unsupported pairing, a cancelled or refused
                // language-pack download — arrives here and is surfaced in the framework's own
                // words, the same way `ToastCenter.failure(_:context:)` surfaces every other
                // error. Errors are never printed (project rule).
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run { store.fail(message, for: requested) }
            }
        }
    }

    // MARK: - Controls

    /// The one control this view adds: translate, collapse, expand, or retry.
    @ViewBuilder
    private var controls: some View {
        switch translations.state(for: key) {
        case .none:
            translateButton
        case .some(.translating):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Translating on this Mac…"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
        case .some(.translated):
            Button {
                translations.setVisible(!translations.isVisible(key), for: key)
            } label: {
                buttonLabel(
                    translations.isVisible(key)
                        ? String(localized: "Hide translation")
                        : String(localized: "Show translation"),
                    symbol: "globe"
                )
            }
            .buttonStyle(SecondaryButtonStyle(height: 24))
            .help(String(localized: "The original above is always shown, translated or not."))
        case .some(.failed(let message)):
            HStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Try again")) { requestTranslation() }
                    .buttonStyle(SecondaryButtonStyle(height: 24))
            }
        }
    }

    /// The *Translate* button, in the two shapes the eligibility check can produce.
    ///
    /// Text already in the reviewer's language gets **no button at all** — not a disabled one:
    /// there is nothing to explain about a translation nobody would want. A pair this Mac cannot
    /// translate gets a disabled button with the reason, because there the reviewer *did* want
    /// something and deserves to know why it is not on offer. An undetectable body (too short,
    /// mostly code) also gets nothing, since the honest tooltip would be "we cannot tell what this
    /// is", which is not worth a control.
    @ViewBuilder
    private var translateButton: some View {
        switch eligibility {
        case .some(.eligible(let source)):
            Button { requestTranslation() } label: {
                buttonLabel(String(localized: "Translate"), symbol: "globe")
            }
            .buttonStyle(SecondaryButtonStyle(height: 24))
            .help(translateHelp(source: source))
        case .some(.unsupportedPair(let source)):
            Button {} label: {
                buttonLabel(String(localized: "Translate"), symbol: "globe")
            }
            .buttonStyle(SecondaryButtonStyle(height: 24))
            .disabled(true)
            .help(unsupportedHelp(source: source))
        default:
            EmptyView()
        }
    }

    /// The translated text, in a tinted block under the original.
    @ViewBuilder
    private var translationBlock: some View {
        if case .some(.translated(let text)) = translations.state(for: key),
           translations.isVisible(key) {
            VStack(alignment: .leading, spacing: 4) {
                CardTitle(String(localized: "TRANSLATED ON THIS MAC"), tint: Theme.accentText)
                Text(text)
                    .font(.system(size: size))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.accent.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.accent.opacity(0.18), lineWidth: 1)
            )
        }
    }

    /// The icon-plus-text label both button shapes share.
    private func buttonLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
            Text(title)
        }
    }

    // MARK: - Actions

    /// Asks for a translation, or asks again.
    ///
    /// The cache entry is set to `.translating` *before* the session is started, so a second click
    /// on a slow translation cannot start a second one: the button is no longer drawn.
    private func requestTranslation() {
        translations.begin(key)
        if configuration == nil {
            // Source `nil` means "detect it": the framework does its own identification for the
            // translation itself, and ``TranslationOffer``'s detection is only used to decide
            // whether to offer the button at all.
            configuration = TranslationSession.Configuration(source: nil, target: target)
        } else {
            configuration?.invalidate()
        }
    }

    // MARK: - Text

    /// The language the reviewer reads: the system's, never a setting of Shepherd's own.
    ///
    /// A language picker of Shepherd's own would be a second answer to a question System Settings
    /// already answers, and the first one that could disagree with it — the same argument
    /// `UpdateController` makes about Sparkle's own flag (`CONTRIBUTING.md`).
    private var target: Locale.Language { Locale.current.language }

    /// This text's cache key.
    private var key: TranslationKey { TranslationKey(text: markdown, target: target) }

    /// The tooltip on an offered translation.
    private func translateHelp(source: Locale.Language) -> String {
        guard let name = TranslationOffer.displayName(for: source) else {
            return String(localized: "Translate this text on this Mac. The original stays above it.")
        }
        return String(
            localized: "Translate this \(name) text on this Mac. The original stays above it."
        )
    }

    /// The tooltip on a pair this Mac cannot translate.
    private func unsupportedHelp(source: Locale.Language) -> String {
        guard let from = TranslationOffer.displayName(for: source),
              let into = TranslationOffer.displayName(for: target)
        else {
            return String(localized: "macOS cannot translate this language pair on this Mac.")
        }
        return String(localized: "macOS cannot translate \(from) into \(into) on this Mac.")
    }
}
