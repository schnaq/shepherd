# ADR 0022: German localisation through one String Catalog, with a Python gate in CI

Status: Accepted (v1.x) · Date: 2026-09-02

## Context

Shepherd's UI has been written for localisation from the first commit: every user-visible string
goes through `String(localized:)`, which `CONTRIBUTING.md` states as a rule and
`docs/ARCHITECTURE.md` repeats. Nothing was ever translated, so the discipline bought nothing and
cost a line of ceremony per string. The founder interview of 2026-09-02 settled the first added
language: German, the maintainer's own.

Three facts about the situation shape the design more than the request does.

**The strings are already extractable and there are eight hundred and fifty-nine of them.** 931
`String(localized:)` call sites in 65 files, plus 26 SwiftUI `Text(…)`/`TextField(…)` literals —
which are `LocalizedStringKey`s and are looked up in the same table, a fact that is easy to forget
because they do not say "localized" anywhere. There is no partial version of this feature: a
review screen that is nine tenths German is worse than one that is English, because the tenth that
is missing looks like a bug rather than a decision.

**A missing translation is silent.** This is the single most important property of the format and
the reason for half of the decisions below. Xcode derives a catalog key from the source string, so
a key with no German unit resolves to *the key* — the English sentence — with no warning at build
time, no assertion at runtime and nothing visibly wrong. A German user reads an English sentence in
the middle of a German paragraph and has no way to tell whether that was intentional. Every other
kind of localisation mistake announces itself; this one is designed not to.

**The gate has to run without Xcode.** `docs/ARCHITECTURE.md`'s verification reality check is not a
footnote here: two of four CI jobs are Linux, `Packages/ShepherdKit` exists precisely so that most
work needs no Xcode, and much of this repository's work happens in Linux agent environments. A
check that only runs on the macOS runner would not run for the contributor most likely to add an
untranslated string.

**A bilingual team reads two UIs at once.** The person using German Shepherd is looking at
github.com in the next window, and github.com is in English. If Shepherd says "Genehmigen" where
GitHub says "Approve", the two stop being the same verb.

Four failure modes have to be designed out rather than tested out:

1. **A string that is not in the catalog.** Silent English, as above — for one label, or for a
   whole file somebody forgot.
2. **A translation whose format specifiers do not match the key's.** `%lld` where the key has
   `%@` is not a typo that shows up as odd wording: `String(format:)` reads the argument as the
   wrong type, which is a wrong number at best and a crash at worst.
3. **A catalog that rots.** Entries for strings that no longer exist, accumulating until nobody
   can tell which of them still matter, which is how a translation file becomes append-only.
4. **A German UI that no longer matches GitHub's vocabulary**, so a reviewer has to translate
   back before acting.

## Decision

### One String Catalog, English keys, German the only added language

`Shepherd/Resources/Localizable.xcstrings` is the single source: 859 entries, every one with a
German value, `sourceLanguage: "en"`, and `options.developmentLanguage: en` in `project.yml` so
the project agrees. Xcode's String Catalog rather than `.strings`/`.stringsdict` pairs because it
is the format the compiler already extracts into, it carries plural rules in the same file as the
plain strings, and it is one artefact to review instead of four.

**The key is the English string, and there is no `en` string unit for a plain entry.** Writing one
would put the English text in the catalog *and* in the source, where the two can disagree, and the
disagreement would be invisible for the same reason a missing translation is: the source wins for
the key, the catalog wins for the value, and nothing compares them. The only `en` units in the
catalog are inside plural variations, where the key genuinely cannot express what English needs
(below). The Python gate enforces this in both directions.

**German is the whole of the addition.** No language picker, no setting, nothing in the synced
settings document (ADR 0014): the language follows `Locale.current`, which is what a macOS user
sets in System Settings once and expects every app to obey. A third language is 859 more values in
the same file and one more element in the checker's required-language list; it is not a new
mechanism.

### The German follows Apple's macOS conventions, and keeps GitHub's vocabulary in English

- Menu items, buttons and commands are infinitives or nouns, the way Apple's German UI writes them
  — *Einstellungen öffnen*, *Jetzt synchronisieren*, *Review abschicken* — not sentences and not
  imperatives.
- Where the app does address the reader it uses **du**, which is what Apple's German has done since
  macOS Ventura, and it avoids addressing them at all where a nominal phrasing reads better.
- Apple's own terms for Apple's own things: Einstellungen, Menüleiste, Mitteilungen, Schlüsselbund,
  Systemeinstellungen, Spotlight, Apple Intelligence, On-Device.
- Typographic quotes „…“ and a real ellipsis (U+2026), including inside translations of strings
  that quote something.
- **The review vocabulary GitHub keeps in English stays English inside German sentences**: pull
  request, review, approve, request changes, merge, draft, commit, diff, branch, CI, check. So
  "Merge queued for %@." becomes "Merge für %@ eingereiht." and a skip reason stays
  "übersprungen · changes requested". This is the rule the founder interview asked for by name, and
  it is a *rule*, not a default: translating "approve" would make the German UI internally
  consistent and externally wrong, and the person reading it has GitHub open in the next window.
  Failure mode 4, closed by vocabulary rather than by review.
- Lengths are kept close to the English. German is longer by nature, and this UI is a
  three-column list with a 34-point timestamp column; where a faithful translation would have grown
  a button, the shorter phrasing wins ("max. %lld Turns", "Triage: %lld ausgewählt").
- Placeholders (`{prompt}`, `{worktree}`), example values in text fields (`my-agent`,
  `owner/repo`, `github_pat_…`), shortcut names, flag names (`--allowedTools`), header names and
  the `shepherd://` grammar are **not** translated. They are syntax the user has to type or read
  literally; a translated example would be a wrong example.

### Plurals go through the catalog's plural rules, and the code is left alone

Eighteen entries carry `variations.plural`. They are exactly the entries where the count is the
string's *only* argument and German needs agreement the English key does not spell out —
`%lld pull requests`, `%lld checks failing`, `+ %lld more files`, `· %lld files ·`. Those get a
German `one`/`other` pair **and** an English one, which is the only place an `en` unit appears:
`Approve 1 pull requests` was already wrong in English, and a catalog that has to state the plural
anyway may as well state it correctly for both.

Three restrictions are deliberate.

- **Only when the count is the single argument.** A string with a count *and* a `%@` needs
  `substitutions` rather than a top-level variation, because a top-level variation cannot say which
  argument it varies on. Rather than reach for the more complex form for cosmetic gain, those
  strings are phrased so that no agreement is needed — "Das heutige Limit für automatische
  Delegationen (%lld) ist ausgeschöpft." instead of a genitive that would have to inflect.
- **No code changed for plurals.** `DigestPresentation.line(for:)` already selects between two
  whole sentences on `count == 1`, which produces two catalog keys ("1 new review request" and
  "%lld new review requests") that are each correct in both languages — German's `one`/`other`
  split is the same split that `if count == 1` makes. Rewriting it into one interpolated key with
  variations would be a behaviour change bought for tidiness. The rule stands for the case this
  repository does not have: code that *concatenates* a plural word is a bug to fix in the code,
  because no catalog can repair a sentence assembled at runtime.
- **Dates and relative times were already the system's.** `RelativeDate.long` is
  `RelativeDateTimeFormatter`, which is localised by macOS; the compact form (`12 m`, `2 h`) is a
  catalog key like any other. Nothing here formats a date by hand, so nothing had to change.

### `Scripts/check-localization.py` is the gate, and it exists because the build is silent

Python 3, standard library only, no arguments, one command:
`python3 Scripts/check-localization.py`. It runs as the **first** step of the Linux CI job, before
Swift, so it fails in seconds and fails for the contributor who has no Xcode.

It is a reimplementation of Xcode's extraction, and it is deliberate that it is one rather than a
grep:

- It **parses Swift string literals** — single-line and `"""` multi-line, escapes, `\u{…}`, `\`
  line continuations, indentation stripping, nested literals inside interpolations — because the
  key has to be *exactly* what the compiler derives. A key that is nearly right is worse than no
  check: it would demand a catalog entry Xcode never looks up and pass while the real key is
  missing.
- It **tracks comments and literal interiors** while scanning, so a `Text("…")` inside a doc
  comment (this repository's comments are dense and full of code) is not mistaken for a call site.
- It **converts interpolations to specifiers by type**, from a table of every interpolated
  expression in the app hand-checked against its declaration: `Int` → `%lld`, `String` → `%@`, with
  regex fallbacks only for shapes that cannot be anything else (`Int(…)`, `….count`). Two
  same-named bindings of different types in one file (`SettingsSyncError` binds `status` as both
  `Int` and `Int32`) are separated by an override keyed on the key text rather than on a line
  number, so the table survives an edit above it.
- It compares **`%` specifiers by position and conversion**, so a positional (`%1$@`) German
  reordering compares equal to its non-positional key — which is the entire reason positional
  specifiers exist, and the reason the check cannot simply diff strings.

Four findings, all non-zero exit: a source key missing from the catalog; an entry with no German
value or an empty one; a German (or plural-`en`) value whose specifiers differ from the key's; and
a catalog key no call site produces. Failure modes 1, 2 and 3, closed — 3 in particular, because
"stale" is a *finding* rather than a warning: an entry nobody can produce any more has to be
deleted in the commit that stopped producing it.

One `XCTestCase` (`ShepherdTests/LocalizationTests.swift`) covers what the Python cannot see, and
only that: that the catalog reached the built app bundle, that `xcstringstool` compiled a German
table out of it, and that a `String(localized:)` resolves through it — three keys, one of them
interpolated, plus the fallback that gives the key back. Every one of those three steps also fails
silently, so a green Python check and a green build together still prove nothing about the wiring.
Two things about *how* it looks up were learnt the expensive way. The `locale:` parameter of
`String(localized:…)` formats the interpolated values but does not choose the language table — that
follows the bundle's preferred localisations, i.e. the runner's — so the test loads the compiled
`de.lproj` as a bundle of its own and looks the keys up there, which no machine setting can change.
And XcodeGen has no `knownRegions` option: it derives the project's languages from `.lproj`
directories, and Xcode compiles a catalog's German only for a known region, which is what the
one-comment `Shepherd/Resources/de.lproj/InfoPlist.strings` is for.

The App Intents surface (ADR 0021) is the one place the catalog is fed by something other than
`String(localized:)` and the SwiftUI initialisers: an intent's `title`, the `@Parameter` and
`@Property` titles, the `DisplayRepresentation` names of the two parameter enums and the entity, the
App Shortcuts' `shortTitle`s, the spoken `IntentDialog`s and the sentences `IntentFailure` throws
are all `LocalizedStringResource` literals, looked up in the same `Localizable.xcstrings`. They
**must stay literals** — the App Intents metadata processor reads them at build time to describe
the intents to Shortcuts and Siri, and would not see a value that arrives through a function call —
so the checker knows their shapes (`APP_INTENTS_TAILS`) instead of the code being bent towards
`String(localized:)`. The two places that built such a resource from a bare literal in a `return`
or a ternary now spell out `IntentDialog("…")` and `LocalizedStringResource("…")`, which is the
same value with a call site the scanner can anchor on. A literal that is nothing but an
interpolation — `DisplayRepresentation(title: "\(slug)")` — is skipped on purpose: its key would be
a bare `%@`.

### What is not localised, and why that is not an oversight

`CONTRIBUTING.md` already drew one line and it stands: **the `shepherd` CLI's console output is
English and unlocalised.** `ROADMAP.md`'s wish said "the app and the CLI"; the CLI is excluded
deliberately, because ADR 0013 makes it a URL builder whose output is read by shell scripts, n8n
nodes and `--help`, and because it links `ShepherdCore` only — a catalog in the app bundle is not
reachable from a command-line tool that must not gain a resource bundle. A localised CLI would also
be a localised *interface*: text somebody greps.

Also untranslated, each for a stated reason rather than by omission:

- **`Packages/ShepherdKit`.** It has no user-visible strings by decision (`docs/ARCHITECTURE.md`'s
  module rule) — everything the user reads is built in the app layer — and it must keep compiling
  on Linux, where there is no `Bundle.main` worth localising against.
- **The web diff viewer** (`web/diff-viewer`). Its own UI is a handful of thread-card labels
  rendered by TypeScript inside a `WKWebView`; ADR 0003 keeps that boundary at the bridge protocol,
  and pushing a translation table across it is a change to a contract, not a translation.
- **The agent prompt preamble** (`DelegationPrompt.preamble`) *is* translated, because it is
  `String(localized:)` and is shown in the delegation sheet — but it is worth naming here as the
  one string in the catalog whose reader is a program. A German preamble is what a German user
  sees, and Claude Code follows German ground rules; if that ever proves otherwise, the fix is to
  stop routing it through the catalog, not to leave an English value in a German row.
- **The four Siri phrases** (`ShepherdShortcuts`). App Shortcut phrases are not `Localizable`
  strings; they live in their own `AppShortcuts.xcstrings`, which the metadata processor generates
  and which needs every phrase re-authored per language with `${applicationName}` in the right
  place — a small separate task, listed in the roadmap, not a gap in this catalog. Until then the
  English phrases work on a German Mac, because Siri matches them by the app's name.
- **No `InfoPlist.xcstrings`.** The app's Info.plist is generated by XcodeGen out of `project.yml`
  and has no user-facing strings to localise: no permission-usage descriptions (the app asks for
  nothing that needs one), and `CFBundleDisplayName` is the product name.

## Consequences

- German users get a German app, from the system language alone, with no setting to find and
  nothing to sync (ADR 0014's document is unchanged).
- **Every new `String(localized:)` now has a second obligation**, in the same shape as ADR 0014's
  rule for settings: a German row in the same commit, and `python3 Scripts/check-localization.py`
  green. `CONTRIBUTING.md` states it. It is enforced rather than asked for, which is the point —
  the alternative is a catalog that is 95 % complete and a UI nobody can trust to be in one
  language.
- **The Python checker is now part of the contract of the app target's source.** It parses Swift,
  so a literal shape it does not understand is a hard error rather than a skipped file — raw
  strings (`#"…"#`), which the app does not currently use, would need a branch. That is the right
  trade: a parser that guessed would be a check that lies.
- The interpolation type table is the checker's one hand-maintained part. A new interpolation of an
  `Int` needs a line in it; forgetting produces a `%@` key the catalog does not have, so the
  failure is "missing from the catalog" — loud, and pointing at the right line. A new `Double` or
  `Float` interpolation (the app has none; the two floating-point settings are wrapped in `Int(…)`
  at the call site) needs `%lf`/`%f` support added deliberately.
- **English is now a fallback with a meaning.** Because the key is the English string, a German
  value that is deleted degrades to English rather than to a key name — which is why the failure is
  survivable in production and why it has to be caught in CI.
- The plural entries change English output where it was already wrong ("Approve 1 pull request"
  instead of "Approve 1 pull requests"). That is a deliberate, additive fix in the catalog rather
  than in code.
- `project.yml` names the catalog explicitly with `buildPhase: resources` instead of leaving it to
  the folder glob. XcodeGen infers a build phase from the file extension, CI installs XcodeGen from
  Homebrew rather than pinning a version, and an `.xcstrings` handed to the Swift compiler is a
  build error — one line removes the question.
- A second language is now cheap and is *only* values: the same 859 keys, one more language in the
  catalog, one more element in the checker's `REQUIRED_LANGUAGE`. Nothing about the mechanism
  changes, which is the property this ADR was trying to buy.

## Amendment (2026-09-03): German Siri phrases

The follow-up this ADR parked above — *"The four Siri phrases … a small separate task, listed in
the roadmap"* — is done, and it stayed the small separate task it was described as. The German
phrases live in `Shepherd/Resources/AppShortcuts.xcstrings`, a second String Catalog in the same
shape as the first (`sourceLanguage: en`, keys that *are* the English strings, one `de`
`stringUnit` each), added to the app target in `project.yml` exactly the way `Localizable.xcstrings`
is. The file name is not a preference: the App Intents metadata processor reads the phrases out of
`ShepherdShortcuts` at build time and looks their translations up in a catalog called
`AppShortcuts.xcstrings`, which is why this could never have been more rows in the existing one.

What is in it: **nine keys, one German utterance each** — the five `AppShortcut`s carry nine
English phrases between them, because Siri matches a phrase literally and an intent worth speaking
to is worth several ways of asking (the count above said "four" from ADR 0021's era and is left as
written; the phrase list in `ShepherdShortcuts` is the count that matters). The mapping is one to
one on purpose: a German utterance per English phrase and nothing else, so the two catalogs stay
comparable by eye and a phrase added in Swift shows up as exactly one missing row. Each German
phrase keeps `${applicationName}` — the placeholder Xcode writes for `\(.applicationName)` in a
phrase catalog — in the position German word order wants it, which for the *summarise* phrase means
mid-sentence ("Fasse meinen nächsten Review in ${applicationName} zusammen") rather than at the
end. The review vocabulary this ADR keeps in English is kept here too: *pull request*, *review*,
*Review-Queue*, *merge*. A German user says "Öffne meine Review-Queue in Shepherd", not
"Warteschlange", for the same reason the inbox says *Review* on screen.

**It is outside `Scripts/check-localization.py` by design**, and the checker now says so at
`CATALOG_PATH`. The checker gates one catalog against the app's `String(localized:)` and
`Text(…)`-shaped call sites; Siri phrase keys are produced by neither, so every one of its four
findings would be a check against the wrong source of truth — "missing from the catalog" for keys
it cannot see, "stale catalog entry" for every phrase that is in fact live. The safety net for this
file is the other one: a phrase with no German row falls back to the English phrase, which works on
a German Mac today, so the failure mode is the one this ADR already accepted for the main catalog
rather than a broken build or a dead Siri command.

## Amendment (2026-09-22): file priority reasons are values, rendered in the app

The review file list, the inbox's file tooltip and the triage "why this risk" popover showed the
prioritiser's reasons ("Touches security-sensitive path …", "Deletes a test file", "Large change
(420 lines)") in English on a German Mac: they were sentences built in `ShepherdCore`, which is
Foundation-only and cannot call `String(localized:)`, and only the first one — the file's
category — was swapped for a German label on screen.

They now follow the shape `EvidenceFact` set (ADR 0026): `FilePrioritizer` produces a closed
`FilePriorityReason` enum with associated values (the matched security hint, the line count, the
previous path), and the triage hints a closed `TriageRiskHint`. Each has an `englishText` in
`ShepherdCore` — byte for byte the old wording — which is what goes to a model or an agent: the
intelligence digest (`PullRequestDigest.FileStat.reasons` stays `[String]` and carries it), the
triage prompt (`TriageInput.make(document:riskHints:)` still takes the English lines), and the
delegation brief's focus reasons. The screen draws `localizedText(bundle:)`
(`Shepherd/Features/Review/FilePriorityReasonText.swift`) instead, with paths and the hint
interpolated verbatim and the two line-count phrases going through plural rules.
`ShepherdTests/FilePriorityReasonTextTests.swift` walks every case through the compiled `de.lproj`.

No tolerant decoding was needed: neither `FilePriority` nor the triage hints are persisted. The
priorities are recomputed from the stored changed files whenever a review or the inbox detail
opens; `TriageVerdictEntry` stores a document hash and the verdict, not the hints, and the hash is
the search document's, so keeping the prompt's English unchanged also leaves every stored verdict
usable.

## Amendment (2026-09-22): the diff viewer speaks German too

*What is not localised* above excluded the web diff viewer on the grounds that "pushing a
translation table across [the bridge] is a change to a contract, not a translation". Both halves
of that were true, and the exclusion is reversed anyway: a German reviewer saw *Resolved*,
*Outdated*, *Pending*, *2 comments* and *3h ago* in the middle of an otherwise German review screen,
which is exactly the mixed-language UI this ADR exists to prevent. ADR 0033's second amendment had
already crossed the line in principle — `loadFile.paneLabels` is localised wording sent from Swift
because "the app is localised and this bundle is not" — so this finishes the job rather than
opening a new question.

**The bundle's own words cross the bridge.** A new inbound message, `setLocale {locale, strings}`,
carries every string the TypeScript draws itself: the *Resolved*, *Outdated* and *Pending* pills,
*No comments.*, the *unknown* author stand-in, the agent badge's tooltip and aria label, the gutter
“+”'s hover text, and the comment count. The words are `String(localized:)` in
`DiffViewerView.viewerStrings()`, so they are ordinary catalog rows with German values and the
checker gates them like any other; the bundle keeps the English as a default
(`src/viewer/locale.ts`) for the tests, the dev harness and the instant before the message
arrives. The Coordinator sends it once, first, ahead of `setTheme` and the first `loadFile`, so no
card is drawn in English and redrawn. It is a new message type, not a new field, and additive, so
the protocol stays at `v: 1` — the same call `focusEditor` and `setAccessibility` made.

**The count is two phrases, not a noun.** The bundle used to build `${count} comment(s)`, which is
the "sentence assembled at runtime" this ADR's plural section calls a bug. The count lives in the
web view, so the catalog's `variations.plural` cannot reach it; instead the catalog holds two whole
phrases, `1 comment` and `{count} comments`, and the bundle picks one with `Intl.PluralRules` for
the locale and replaces `{count}`. `{count}` is a placeholder in the sense this ADR already uses for
`{prompt}`: syntax, kept verbatim in the German.

**Times go through `Intl`.** `locale` is the language the app's strings resolved to —
`Bundle.main.preferredLocalizations.first`, `"de"` or `"en"` — rather than `Locale.current`, both
because a French Mac gets this app in English and the diff must agree with the screen around it,
and because `Locale.current.identifier` is `de_DE`, which `Intl` rejects. In German, relative times
are `Intl.RelativeTimeFormat` with `style: 'short'` ("jetzt", "vor 5 Min.", "vor 1 Tag",
"vor 3 Wochen"); `narrow` would have given "vor 5 m". `numeric: 'auto'` is used for "jetzt" only:
the buckets floor elapsed time, and "gestern" or "letzte Woche" would be calendar claims they
cannot back — "letzte Woche" for eight days ago on a Monday is two weeks back. English keeps the
compact hand-written form ("3h ago") the card was designed around, because `Intl`'s short English
("3 hr. ago") is longer. The tooltip's absolute time becomes `Intl.DateTimeFormat` in the Mac's
time zone instead of a UTC ISO string. The page's `lang` follows the locale, so VoiceOver reads the
German cards with a German voice.

**Monaco's own strings come along, by a different door.** The "N hidden lines" bar, *Show Unchanged
Region*, Monaco's hovers and its accessibility help are Monaco's, looked up through its `nls`
table — which Monaco reads while its modules evaluate, before the bridge exists. So they cannot
ride `setLocale`. `monaco-editor` ships that table per language; the build copies the German one
verbatim into `dist/nls/de.js` (130 KB, about 4 % of the bundle, from `esm/` because its indices are
the ESM build's), and `DiffViewerView` injects it as a document-start `WKUserScript` when the app
runs in German — the seam the theme bootstrap already uses. Nothing is fetched and nothing in
`index.html` changes, so ADR 0003 is untouched; an English Mac never reads the file. It is
Microsoft's translation, not ours, so its German is VS Code's rather than this ADR's: it says
*Regionen* and *Linien* where Shepherd would say *Bereich* and *Zeilen*. That is the price of not
maintaining a 2,120-string table by hand, and it is still German.

**Still English, deliberately:** the error banner (`Could not handle “…”`, `Rejected message: …`)
that shows only when the bridge itself is broken. It reports a developer's problem, verbatim with
the parser's own detail, and the detail is English either way.
