# ADR 0044: Shepherd for iPhone — the Mac's review logic, a native phone shell, TestFlight first

Status: Accepted · Date: 2026-10-19

## Context

Shepherd is a Mac app, and a review queue does not wait for a Mac. Approving the agent's pull
request from the train, answering a review thread from the sofa, merging the green one before the
laptop is open — Christian asked for an iPhone companion that can do the reviewing, not just show
a list, that goes to testers through TestFlight, and that looks good rather than like a port.

Three things made this less obvious than "add an iOS target":

- **Most of `Shepherd/` is a Mac app.** The composition root (`AppEnvironment`, 2,100 lines)
  constructs and starts Sparkle, the webhook dispatcher, delegation, the merge automations,
  Spotlight, the digest, App Intents and MetricKit. Views lean on AppKit, the mouse and the
  keyboard. Compiling the whole tree for iOS (route A) was measured: after guarding the AppKit
  imports, 62 first-wave errors in 31 files, five of them in files being edited on another
  branch, and everything `AppEnvironment` starts would start on the phone unless gated one by one.
- **The review logic is the valuable, volatile part.** `ReviewModel`, `InboxModel` and
  `PullRequestActions` hold the verdict refusal rules, the draft and head-commit handling, the
  outbox enqueue and read-back paths and the reaction state — about 4,600 lines that ADR 0043 is
  still changing. A phone-native copy of them (route C) would start drifting the day it was
  written.
- **The diff cannot be Monaco.** ADR 0003's viewer is a web bundle in a `WKWebView` sized and
  driven for a Mac window. ADR 0034 already gave the Mac a native renderer held to a three-point
  contract; it had no syntax colour and no word diff.

## Decision

### Route B: one set of review files, compiled twice

A separate iOS 27 application target, `ShepherdPhone` (PRODUCT_NAME *Shepherd*, bundle id
`com.schnaq.shepherd.ios`, iPhone only), compiles its own `ShepherdPhone/` folder **plus a curated
list of the Mac app's files** — the `includes:` list in `project.yml`. The session, the inbox and
review models, the outbox-backed actions, the settings, the Keychain store, the Markdown renderer
and a handful of leaf views (chips, check dots, the stack card, the merge-method picker) are the
Mac's own source, not copies. Not a framework: a module boundary would need `public` on hundreds of
internal declarations, and compiling the same files into two targets needs none.

What made the list close is a small set of seams, each a cut through one edge that dragged
`AppEnvironment` or AppKit in: `PlatformServices` for pasteboard and browser; `Theme` resolving
colours on either platform; `SignInModel` talking to an `AccountSigningIn` protocol and
`SignedInSession` presenting through `SyncEventPresenting`; three value types moved out of view
files; and `#if os(macOS)` around the few Mac-only members of shared files. `PullRequestActions`
took the guard form rather than `PlatformServices` only so it rebased over the conversation
branch (ADR 0043, C) without a conflict; the phone supplies its own `openOnGitHub`/`copyBranch`.
That branch has merged, so routing the Mac file through `PlatformServices` is a follow-up.

Some listed files are compiled but never instantiated — `AppSettings`' stored properties name the
webhook, S3/SigV4, agent-CLI and editor configuration types, `ReviewModel` names the intelligence
router. The phone's composition root, `PhoneEnvironment`, constructs none of them. That is the line
it exists to hold: no automations, delegation, webhooks, Sparkle, Spotlight, search index, digest,
MetricKit or telemetry on the phone.

The list is a promise that every entry builds for iOS, and promises erode. CI's `ios` job builds the
phone on every push, so a Mac change that gives a shared file a Mac-only dependency fails the pull
request that made it.

### A native SwiftUI shell, written for the phone

Every screen is the phone's own, in `ShepherdPhone/`: sign-in, the inbox, the pull request with its
conversation, the files and the diff, the sheets. The Mac screens are bound to
`@Environment(AppEnvironment.self)` and to the pointer; reusing them would mean the phone looks like
a shrunken Mac. One `NavigationStack` with the inbox at the root and values for routes
(`PhoneRoute`), no tab bar, settings as a sheet. Text is on the type scale from the first line, so
Dynamic Type works everywhere — `Scripts/check-type-scale.py` checks every file under
`ShepherdPhone/`, not a list. Glass follows ADR 0040's rule on iOS too: system glass for the control
layer (navigation and toolbars, the prominent action, toasts), opaque content.

Strings go through the one String Catalog (ADR 0022). A phone string is a row in the same file, and
`Scripts/check-localization.py` scans `ShepherdPhone/` as well.

### Native highlighting in ShepherdCore

Syntax colour and word diff are built in `ShepherdCore` (`SourceLanguage`, `SyntaxHighlighter`,
`DiffHighlighting`), pure standard library, tested on the Linux leg — not highlight.js in
JavaScriptCore, which would have put a second JavaScript runtime and a second licence into the
phone for something a byte lexer does in well under a millisecond per typical file. Both renderers
read it: the phone's diff and, later, the Mac's native list. It stays outside ADR 0034's contract
(see its amendment), so neither renderer changes which lines take a comment.

### No push, no background refresh in v1

The phone sweeps while it is open and drains its outbox when it leaves the foreground, inside a
`beginBackgroundTask` window. There is no `UIBackgroundModes`, no `BGTaskScheduler` identifier, no
remote notification and no `shepherd://` URL type in the Info.plist. Push would need a server
Shepherd does not have (ADR 0006: local-first, no backend), and background refresh on iOS
is opportunistic enough that a "new review request" notice driven by it would be late or absent in
ways nobody could explain. Both are v2 questions.

### TestFlight, internal testers, from the maintainer's Mac

`Scripts/testflight.sh` (`mise run testflight`) archives the Release build, checks it, and uploads
through `ShepherdPhone/Support/ExportOptions.plist` with the Apple account signed in to Xcode or an
App Store Connect API key with the Admin role. Build numbers are UTC timestamps, so they rise on any
machine with no history. The iPhone app has its own version line, independent of the Mac's, and
goes to internal testers only: no Beta App Review, no reviewer account. The app icon is an Icon
Composer `AppIcon.icon` (Any, Dark and Tinted renditions), the privacy manifest declares the one
required-reason API the shared code uses (UserDefaults, `CA92.1`). The one-time setup is in
`docs/RELEASING.md`.

### Export compliance: NO, and checked

`ITSAppUsesNonExemptEncryption` is `NO`. The app uses the system's encryption — HTTPS through
`URLSession`, the Keychain — and links CryptoKit only for SHA-256 and HMAC: `SigV4Signer`, compiled
in through `AppSettings`, and the App Attest request signing inside ClaudeForFoundationModels. Those
authenticate and check integrity; they do not encrypt, and they are exempt. The Mac's settings sync
does encrypt (`SettingsSyncCrypto.swift`: AES-GCM, PBKDF2), and that file and
`WebhookSignature.swift` are named in `project.yml` as never to be shared.

A guard rather than a hope: `Scripts/check-phone-encryption.sh` fails on any imported AES,
ChaChaPoly or CommonCrypto cipher or key-derivation symbol. It runs on the archived Release binary
before every upload and on the Debug build in CI. "Does it link CryptoKit" would be the wrong
question — it would stop every build — so it asks by symbol; run against the Mac binary it fires, as
it should.

## Consequences

- The Mac's review rules reach the phone the day they change on the Mac, and so do their bugs. A
  fix in `ReviewModel` is a fix in both apps.
- The shared list costs attention: a new Mac-only dependency in a shared file breaks the phone
  build. CI says so on the pull request; the remedy is a seam or a type move, never a copy.
- The phone binary carries inert Mac code (configuration types, telemetry, the intelligence tiers)
  that is compiled and never run. It costs size, not behaviour. Wrapping `AppSettings`' Mac-only
  properties in `#if os(macOS)` would drop most of it and is left for when the size matters.
- The phone's debug demo mode (`-ShepherdDemo YES`) seeds the Mac demo's sample data into a scratch
  directory, a separate defaults suite and an in-memory Keychain, with a transport that refuses
  every request — the same rules as the Mac's, so a demo launch never touches the real
  installation. It is how the phone's screens are looked at without an account.
- No new host: the phone talks to `api.github.com` and `github.com` with the same device-flow token
  model (ADR 0004), kept in the phone's own Keychain. Nothing is shared with the Mac, and nothing
  synchronises between the two except GitHub itself.
- An external TestFlight group or an App Store release would need Beta App Review and a way for a
  reviewer to sign in. That is a separate decision.
