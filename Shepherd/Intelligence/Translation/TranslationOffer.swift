import Foundation
import NaturalLanguage
import Translation

/// Whether a piece of pull-request text may be offered a *Translate* button, and why not when not.
///
/// The cases are the four honest answers, and each one produces a different affordance rather than
/// the same shrug: a button, no button at all, or a disabled button that says what is missing.
enum TranslationEligibility: Sendable, Equatable {
    /// The text is in another language and the pair can be translated on this Mac.
    ///
    /// "Can be" includes *not downloaded yet*: `LanguageAvailability` reports `.supported` for a
    /// pair whose language pack is missing, and the first translation then makes macOS present its
    /// own download sheet. That is the OS asking, with the OS's own UI, for the OS's own asset —
    /// Shepherd neither downloads nor hosts anything (ADR 0020).
    case eligible(source: Locale.Language)
    /// The text is already in the language the reviewer reads, so there is nothing to offer.
    case alreadyInTargetLanguage
    /// A language was detected but this Mac cannot translate that pair at all.
    case unsupportedPair(source: Locale.Language)
    /// No language could be established with enough confidence — see ``TranslationOffer``.
    case undetectable
}

/// Decides whether to offer a translation of a piece of text, and in which direction.
///
/// The decision is split in two on purpose. ``decide(source:target:isPairSupported:)`` is a pure
/// function over three plain values and is where every rule lives, so the rules are unit-tested
/// without a language pack, without Apple Intelligence and without a window.
/// ``eligibility(for:target:)`` is the thin async shell that asks the two frameworks for those
/// three values.
///
/// **Why detect the language ourselves.** `LanguageAvailability` also has a
/// `status(for:to:)` overload that detects the source language internally, which looks like the
/// shorter path. It answers a different question, though: it returns a *status*, never the language
/// it detected — and the rule this feature needs most ("never offer to translate text that is
/// already in the reader's language") is a statement about that language. So the source is
/// established once, here, with `NLLanguageRecognizer`, and then used for both the same-language
/// check and the availability query. One detector, one answer, no way for the two checks to
/// disagree.
///
/// **Why the detector is fussy.** A pull-request comment is not a paragraph of prose: it is prose
/// with stack traces, identifiers, fenced code and URLs in it, and a language recogniser fed
/// `assertEquals(foo, bar)` will confidently say Latin. Three guards keep that out of the UI:
/// fenced and indented code, inline code spans, links and `@mentions` are removed before
/// detection; what remains has to be at least ``minimumCharacters`` long; and a reported confidence
/// below ``minimumConfidence`` for the recogniser's own top hypothesis is rejected. A body that
/// fails any of them is ``TranslationEligibility/undetectable`` and gets no button at all — an
/// unasked question is better than a confident translation of a code sample.
enum TranslationOffer {
    /// How much prose has to survive the strip before detection is trusted.
    ///
    /// Roughly a sentence. Below it, "LGTM" and "+1" are the honest majority of comments and no
    /// recogniser can say anything useful about them.
    static let minimumCharacters = 24
    /// How sure `NLLanguageRecognizer` has to be of its top hypothesis.
    static let minimumConfidence = 0.55
    /// How much of a long body is fed to the recogniser.
    ///
    /// Language identification saturates long before this; a 200 KB generated changelog would
    /// only cost time.
    static let detectionWindow = 1_000

    /// The rules, as a pure function.
    /// - Parameters:
    ///   - source: The detected language, or `nil` when detection did not commit to one.
    ///   - target: The language the reviewer reads — `Locale.current.language` in the app.
    ///   - isPairSupported: Whether this Mac can translate `source` → `target`, installed or
    ///     downloadable.
    /// - Returns: What to offer.
    static func decide(
        source: Locale.Language?,
        target: Locale.Language,
        isPairSupported: Bool
    ) -> TranslationEligibility {
        guard let source else { return .undetectable }
        if isSameLanguage(source, target) { return .alreadyInTargetLanguage }
        return isPairSupported ? .eligible(source: source) : .unsupportedPair(source: source)
    }

    /// Asks the frameworks for the three values ``decide(source:target:isPairSupported:)`` needs.
    ///
    /// Two properties of this function are load-bearing. It carries no actor isolation and is
    /// `async`, so a caller on the main actor hops off it (SE-0338) and the recogniser's work never
    /// runs on the thread drawing a conversation of forty comments. And the same-language check comes *before*
    /// the availability query, so the common case — an English comment for an English reader — is
    /// answered by local text analysis alone and asks the Translation framework nothing.
    ///
    /// `LanguageAvailability` is created per call rather than held in a `static let`: it is cheap,
    /// and a shared instance would be mutable global state in an app built with strict concurrency
    /// for no benefit.
    /// - Parameters:
    ///   - text: The Markdown body as GitHub sent it.
    ///   - target: The language the reviewer reads.
    /// - Returns: What to offer for this text.
    static func eligibility(for text: String, target: Locale.Language) async -> TranslationEligibility {
        guard let source = detectedLanguage(in: text) else { return .undetectable }
        guard !isSameLanguage(source, target) else { return .alreadyInTargetLanguage }
        let status = await LanguageAvailability().status(from: source, to: target)
        let supported: Bool
        switch status {
        case .installed, .supported:
            supported = true
        default:
            // `.unsupported` today, and anything Apple adds later: an unknown status is treated as
            // "do not promise a translation", which fails towards the disabled button.
            supported = false
        }
        return decide(source: source, target: target, isPairSupported: supported)
    }

    /// The dominant language of a Markdown body, or `nil` when it cannot be established.
    ///
    /// See the type's documentation for why this strips code before it counts characters.
    /// - Parameter text: The Markdown body.
    /// - Returns: The detected language, or `nil`.
    static func detectedLanguage(in text: String) -> Locale.Language? {
        let sample = String(prose(in: text).prefix(detectionWindow))
        guard sample.count >= minimumCharacters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        // The confidence check rejects rather than confirms: when the recogniser reports a
        // probability for its own dominant language and that probability is low, the answer is
        // dropped. A missing probability is not treated as a low one — `dominantLanguage` having
        // committed to a language is itself the primary signal, and inventing a zero there would
        // silently turn every body into `undetectable`.
        if let confidence = recognizer.languageHypotheses(withMaximum: 3)[dominant],
           confidence < minimumConfidence {
            return nil
        }
        return Locale.Language(identifier: dominant.rawValue)
    }

    /// Whether two languages are the same language as far as a reader is concerned.
    ///
    /// Only the ISO-639 language code is compared, so `en-GB` and `en-US` are the same language and
    /// a British reviewer is never offered a translation of American English. Region and script are
    /// deliberately ignored: the alternative — offering to "translate" `pt-BR` into `pt-PT` — is
    /// noise, and the framework would in any case refuse the pair.
    /// - Parameters:
    ///   - lhs: One language.
    ///   - rhs: The other.
    /// - Returns: `true` when both carry the same language code.
    static func isSameLanguage(_ lhs: Locale.Language, _ rhs: Locale.Language) -> Bool {
        guard let left = lhs.languageCode, let right = rhs.languageCode else { return false }
        return left == right
    }

    /// A language's name in the reviewer's own language, for a button's tooltip.
    /// - Parameter language: The language to name.
    /// - Returns: The localized name, or `nil` when the language has no code to look up.
    static func displayName(for language: Locale.Language) -> String? {
        guard let code = language.languageCode?.identifier else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)
    }

    /// The prose left in a Markdown body once the parts that are not a language are removed.
    ///
    /// Fenced blocks (``` and ~~~), indented code blocks, inline code spans, links and `@mentions`
    /// go; everything else stays, including the words around them. Written as a line walk rather
    /// than as a regular expression because an unterminated fence — the normal state of a body
    /// somebody is still typing — has to behave predictably: the fence swallows the rest of the
    /// text rather than the regex matching nothing.
    /// - Parameter markdown: The body.
    /// - Returns: The prose, joined by newlines.
    static func prose(in markdown: String) -> String {
        var lines: [String] = []
        var insideFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { continue }
            let stripped = withoutLinksAndMentions(withoutInlineCode(String(line)))
            if !stripped.isEmpty { lines.append(stripped) }
        }
        return lines.joined(separator: "\n")
    }

    /// Drops everything between backticks, keeping the text around it.
    ///
    /// Splitting on the backtick and keeping the even-indexed pieces is exact for the common case
    /// and harmless for the pathological one: an odd number of backticks turns the tail into a
    /// "code" span, which is the conservative direction — less text to detect on, never more.
    private static func withoutInlineCode(_ line: String) -> String {
        guard line.contains("`") else { return line }
        let pieces = line.split(separator: "`", omittingEmptySubsequences: false)
        return pieces.enumerated()
            .filter { $0.offset.isMultiple(of: 2) }
            .map(\.element)
            .joined(separator: " ")
    }

    /// Drops URLs and `@mentions`, which no recogniser should be asked to read.
    private static func withoutLinksAndMentions(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .filter { word in
                !word.contains("://") && !word.hasPrefix("@") && !word.hasPrefix("www.")
            }
            .joined(separator: " ")
    }
}
