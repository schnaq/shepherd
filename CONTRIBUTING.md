# Contributing to Shepherd

Thanks for helping herd the agents! 🐑

## Prerequisites

- macOS 26+, Xcode 26+ (app target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Node 22+ (only if you touch `web/diff-viewer`)

## Setup

```sh
cd web/diff-viewer && npm ci && npm run build && cd ../..   # builds Resources/DiffViewer/dist
xcodegen generate
open Shepherd.xcodeproj
```

`Shepherd.xcodeproj` is generated and git-ignored — edit `project.yml`, not the project.

## Working on ShepherdKit (no Xcode needed)

The domain/network/persistence/sync logic is a plain SPM package:

```sh
cd Packages/ShepherdKit
swift test
```

It must keep building without AppKit/SwiftUI/WebKit imports and pass tests headlessly —
this is enforced by CI on both macOS and Linux. GRDB supports Linux via SwiftPM since 7.10,
so the persistence tests run on both runners; on Linux you need `libsqlite3-dev` installed
(`sudo apt-get install libsqlite3-dev`), which CI does for you.

## Working on the `shepherd` CLI

```sh
xcodebuild -project Shepherd.xcodeproj -scheme ShepherdCLI -configuration Debug build
```

The CLI is a URL builder and must stay one (ADR 0013): it links `ShepherdCore` only — no
GitHubKit, no persistence, no Keychain, no network code. Its argument grammar and the
`shepherd://` grammar both live in `Packages/ShepherdKit/Sources/ShepherdCore/Routing/` and are
tested with `swift test`, so most CLI work needs no Xcode either. Console output is English and
unlocalised; the `String(localized:)` rule is for the app's UI.

## Working on the diff viewer

```sh
cd web/diff-viewer
npm ci
npm run dev     # standalone harness in the browser with fixture data
npm test        # bridge protocol + rendering tests
npm run build   # emits ../../Shepherd/Resources/DiffViewer/dist — commit the output
```

The Swift⇄web bridge protocol is a contract: change `src/bridge/protocol.ts`,
`BridgeProtocol.swift`, the shared fixtures, and `docs/ARCHITECTURE.md` together.

## Working on the release pipeline

`Scripts/release.sh` is the whole thing — build, Developer-ID sign, DMG, notarize, staple,
Sparkle-sign, appcast — and `.github/workflows/release.yml` only feeds it secrets.
It runs without an Apple account:

```sh
ALLOW_UNSIGNED=1 ./Scripts/release.sh   # → dist/, with loud "do not publish" warnings
```

Setup and the per-release checklist are in [docs/RELEASING.md](docs/RELEASING.md). Adding or
bumping a dependency that ships inside the app also means a line in
[NOTICES.md](NOTICES.md) (ADR 0009).

## Rules of the road

- Decisions live in [docs/adr](docs/adr). Changing a decision = new ADR, not a silent edit.
- UI strings: English, `String(localized:)`. Colors: semantic tokens only (dark/light!).
- Adding a **setting** has a second obligation: carry it in `SyncedSettingsDocument` and in both
  directions of `SettingsSyncApplier` (ADR 0014), or it silently stops travelling between a user's
  Macs. The two functions are deliberately mirror images — diff them by eye — and
  `SettingsSyncTests` capture-apply-captures a document with every field non-default.
  There is exactly one documented exception: the "check for updates automatically" toggle, which
  is Sparkle's own `automaticallyChecksForUpdates` and which Sparkle persists itself. Shepherd
  mirrors it rather than storing it (`UpdateController`), because a second copy in `AppSettings`
  could only ever disagree with the one the updater actually reads. Anything else you add goes in
  `AppSettings` and therefore into the synced document.
- Secrets go in the Keychain, never in `UserDefaults` and never in the database. That includes
  anything new: the sync document is encrypted, but `UserDefaults` is not.
- No telemetry, ever. The complete list of hosts Shepherd may contact:
  - api.github.com / github.com;
  - only when the user configures a key: api.anthropic.com, or the OpenAI-compatible endpoint
    they chose themselves (a preset's base URL is still their choice). What travels there is the
    tier-1 digest — title, description excerpt, file list, top hunks — and, when you use AI
    drafting (ADR 0007 amendment), the diff excerpt around the line you are commenting on plus
    the inline comments already in your pending review. So: yes, pull-request *code* reaches that
    endpoint, only that endpoint, only for the pull request you are looking at, and only after you
    configured it and clicked. Everything is capped against an explicit token budget before it is
    sent;
  - only when the user enables webhooks and types a URL: **that URL** (ADR 0012). Outbound only,
    one destination, off by default, and the payload never carries review text, comment bodies,
    diffs or agent output;
  - only when the user enables settings sync and types one: **the S3-compatible endpoint they
    configured** (ADR 0014) — one object, `GET`/`PUT`/`HEAD`, https only, and everything that goes
    there is encrypted on this Mac first, so the endpoint sees ciphertext and never a setting or a
    secret;
  - the update feed and the update download (ADR 0010): `github.com` — already on this list — plus
    the `*.githubusercontent.com` host GitHub redirects release-asset downloads to. Two plain
    `GET`s, no request body, nothing identifying beyond Sparkle's user agent and the version being
    upgraded from. Automatic checks are on by default and switchable off in Settings → Account;
    with the toggle off, nothing is requested until the user presses "Check for Updates…", and a
    build without a signing key never requests anything at all.

  Nothing else. This is a hard privacy line: adding a host means a new ADR, a settings control the
  user has to switch on, and a line here.
- **Diagnostics stay local.** Shepherd has no crash-reporting SDK and no crash endpoint. The opt-in
  crash/hang reporting (ADR 0017) is MetricKit: macOS hands the app its own `MXDiagnosticPayload`s
  on the next launch after a crash, and `Shepherd/Diagnostics/` writes each one as a JSON file in
  `~/Library/Application Support/Shepherd/Diagnostics/`. Off by default; with the toggle off no
  subscriber is registered, so nothing is delivered and nothing is stored. There is no uploader in
  that folder's code path — not a disabled one, none — so the host list above is unchanged, and a
  bug report happens only when a user opens the folder and attaches a file themselves. Anything
  that would *send* a diagnostic is a new host and therefore a new ADR.
- Conventional commits appreciated (`feat:`, `fix:`, `docs:` …), not enforced.

## License

By contributing you agree your contributions are licensed under the [MIT license](LICENSE).
