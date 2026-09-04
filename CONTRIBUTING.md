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
- UI strings: English source, `String(localized:)`. Colors: semantic tokens only (dark/light!).
- **Every new `String(localized:)` gets a German row in
  `Shepherd/Resources/Localizable.xcstrings`, in the same commit** (ADR 0022). This has the shape
  of the settings obligation below and the same reason: a key with no German value does not warn,
  does not fail the build and does not look broken — Xcode resolves it to the key, which *is* the
  English string, so a German user reads an English sentence and cannot tell it was not meant.
  The same goes for a SwiftUI `Text("…")`, `Label("…", systemImage:)`, `Button("…")` or
  `TextField("…")` with a **string literal** title: those are `LocalizedStringKey`s and are looked
  up in the same catalog, however little they look like it.

  ```sh
  python3 Scripts/check-localization.py   # stdlib only, no Xcode, runs on Linux
  ```

  Run it before you push; it is the first step of the Linux CI job. It reports a key the catalog is
  missing, an entry with no German value, a German value whose `%` specifiers disagree with the
  key's, and a catalog entry no call site produces any more — that last one is a finding too, so a
  string you delete takes its row with it. Interpolating a new `Int` also means a line in the
  script's hand-checked type table (`INTEGER_EXPRESSIONS`), or the derived key will be `%@` where
  Xcode writes `%lld` and the check will say the key is missing.

  German style: Apple's macOS conventions (Einstellungen, Menüleiste, Mitteilungen, Schlüsselbund;
  infinitives on buttons; „…“ and a real …), **du** where the app has to address the reader, and
  roughly the English length — this UI has narrow columns. The review vocabulary GitHub keeps in
  English stays English inside the German sentence: pull request, review, approve, request changes,
  merge, draft, commit, diff, branch, CI, check. Counts that need agreement go through the
  catalog's `variations.plural`, never through concatenation in code.

  What is deliberately *not* localised: the `shepherd` CLI (above — console output is English),
  `Packages/ShepherdKit` (no user-visible strings by decision), the web diff viewer (ADR 0003 keeps
  that boundary at the bridge protocol), and literal syntax inside translated text — placeholders
  like `{prompt}`, flag names, example values (`owner/repo`, `github_pat_…`) and shortcut names.
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
  - api.github.com / github.com. The track record's read of **closed** pull requests (ADR 0027)
    is the same `api.github.com` GraphQL endpoint as the inbox sweep, with `is:closed` in place of
    `is:open` — one more search on the host already on this list, and no new one; the claims card's
    read of the issue a `fixes #N` claim points at (ADR 0026's amendment) is one ETag-cached
    `GET /repos/…/issues/{n}` on that same host, made only while the card is open; the **issues
    inbox**'s sweep (ADR 0032) is three more searches on that same GraphQL endpoint —
    `is:issue is:open archived:false` with `assignee:`/`author:`/`mentions:@me`, beside the
    pull-request sweep's five, in the same cycle and at the same cadence — and the pull requests
    that will close an issue come back inside those pages rather than as reads of their own, so it
    is the host already on this list and no new one; the other direction of that link, the issues
    a pull request **closes** (ADR 0032's Sprint 3 amendment), is one more *field* on the detail
    fetch a pull request already makes — `closingIssuesReferences` on the same GraphQL endpoint,
    beside the review-threads query, so it is neither a new host nor a new request — and the CI
    state the issue's list shows for a linked pull request is read out of the local database by
    `(repo, number)`, never fetched.
    The issues *section* (ADR 0032's Sprint 2
    amendment) adds two per-issue reads on that same host, each made only when somebody asks for
    that one issue: the ETag-cached `GET /repos/…/issues/{n}` the claims card already makes, used
    once for the body when the panel opens an issue whose cached body is older than the row, and
    one `repository { issue(number:) }` GraphQL query when a `shepherd://issue/…` link names an
    issue the local cache does not have. Both are reads, both are `api.github.com`, and typing in
    ⌘K still cannot produce either — the search index is built from rows that are already stored.
    The issue **writes** (ADR 0032's Sprint 4a amendment) are the first thing on that side that is
    not a read, and they are four REST calls on the same host with the same token, each one an
    ordinary outbox row: `POST /repos/…/issues/{n}/comments`, `POST …/issues/{n}/labels` (the
    additive endpoint, so two queued label writes cannot race each other into a lost update),
    `POST …/issues/{n}/assignees`, and `PATCH …/issues/{n}` carrying `state` and `state_reason`
    and nothing else. Before every one of them the drain makes one more read on that same GraphQL
    endpoint — `issue(number:) { id updatedAt closed }`, the staleness probe — and parks the write
    rather than sending it when the issue moved on. Five calls, one host, and it is the host that
    was already on this list. The sweep makes one more read of its own since ADR 0032's
    2026-09-03 amendment: when an issue the sweep was tracking stops coming back from the search,
    one `repository { issue(number:) }` GraphQL query on that same endpoint asks whether it closed
    or merely left the user's facets, so the closed row can be kept — and it is **capped** at ten
    such reads per sweep, with the rest read on the next one. One read per disappearance, on the
    host already on this list, and a row that came back closed then costs nothing further: it is
    kept for fourteen days and pruned;
  - only when the user configures a key: api.anthropic.com, or the OpenAI-compatible endpoint
    they chose themselves (a preset's base URL is still their choice). What travels there is the
    tier-1 digest — title, description excerpt, file list, top hunks — and, when you use AI
    drafting (ADR 0007 amendment), the diff excerpt around the line you are commenting on plus
    the inline comments already in your pending review — and, when you ask that endpoint to
    **explain** a selection, that same diff excerpt and nothing else, cut by the same builder
    against the same budget (ADR 0007's 2026-09-03 amendment), so an explanation sends no kind of
    content a drafted comment does not. When the endpoint's optional **sovereignty policy** fields
    are set (Settings → Intelligence: a country list, "require zero retention"), those two values
    travel as part of the request body as well — they are the only thing Shepherd adds to a request
    that the user did not type into a composer, they are sent only while they are set, and they
    carry no pull-request content. So: yes, pull-request *code* reaches that
    endpoint, only that endpoint, only for the pull request you are looking at, and only after you
    configured it and clicked. Everything is capped against an explicit token budget before it is
    sent. When a cloud provider answers *"why is CI red?"* (ADR 0024), what travels is the failing
    checks' names, conclusions and own summary text, a budgeted diff window around the line the
    model asks about, and — new with that feature — the **reduced tail of the CI job log**: the
    error and failure lines with a little context, cut on this Mac against the tier's budget before
    anything is sent, never the raw log. That tier is only asked at all after the on-device model
    reported the content too large — or reported that it is not available on this Mac at all —
    **and** you pressed the card's own button for that one click; with no key configured the card
    says what happened and offers nothing, and with neither a key nor an on-device model the
    *Why?* button is not drawn. Downloading the log itself touches one more GitHub host, named here
    the way the update download's is: `GET /repos/…/actions/jobs/{id}/logs` on api.github.com
    redirects to the `*.githubusercontent.com` blob host GitHub stores job logs on. One plain `GET`
    of a signed URL, no request body, and the redirect hop carries no `Authorization` header — the
    transport drops it whenever a redirect leaves the host the request was made to, and **every**
    request in the app that carries a credential goes through such a session (`CredentialSafeSession`),
    not only this one: the bucket, the webhook receiver and the AI endpoints are hosts Shepherd does
    not control, and a `302` from one of them must not be able to forward the credential onwards;
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
- **Apple's on-device text features are not a tier and not a host.** Writing Tools in the composers
  and the *Translate* button on pull-request text (ADR 0020) go through the system frameworks —
  `TranslationSession`, `NLLanguageRecognizer` — and add no request to the list above: there is no
  `URLSession` in `Shepherd/Intelligence/Translation/`, no endpoint and nothing to configure. A
  language pack is fetched by **macOS**, through its own sheet, from Apple's asset infrastructure,
  carrying neither the text nor anything about the user — the same category as the system dictionary
  or a font, and it happens identically in TextEdit. What is a hard rule is the direction: a
  translation may never be routed through a configured AI provider, not even as an opt-in, because
  the text belongs to somebody who never saw Shepherd's settings. `IntelligenceProvider` therefore
  has no translation method, and giving it one needs a new ADR.
- **Diagnostics stay local.** Shepherd has no crash-reporting SDK and no crash endpoint. The opt-in
  crash/hang reporting (ADR 0017) is MetricKit: macOS hands the app its own `MXDiagnosticPayload`s
  on the next launch after a crash, and `Shepherd/Diagnostics/` writes each one as a JSON file in
  `~/Library/Application Support/Shepherd/Diagnostics/`. Off by default; with the toggle off no
  subscriber is registered, so nothing is delivered and nothing is stored. There is no uploader in
  that folder's code path — not a disabled one, none — so the host list above is unchanged, and a
  bug report happens only when a user opens the folder and attaches a file themselves. Anything
  that would *send* a diagnostic is a new host and therefore a new ADR.
- **The morning digest stays local.** It is the one thing Shepherd does *while nobody is watching*,
  so its whole path — `ShepherdCore/Digest/`, `Features/Digest/` — reads cached rows out of SQLite
  and calls nothing. No GitHub request, no AI request, no webhook. The tiers above are all
  user-triggered: somebody clicked a button and can see the result, which is what makes "your code
  reaches the endpoint you configured" an informed choice. An unattended timer has nobody to inform,
  so if a digest is ever to gain a generated sentence it may only use the **on-device** tier, and
  wiring it up means a request type only that tier answers — never a method the two cloud providers
  also implement.
- **⌘K search stays on the device.** The semantic search index (ADR 0019) is built from rows the
  sweep and the review screen already wrote — `ShepherdCore/Search/`, `Features/Search/` — and its
  embeddings come from Apple's on-device `NLEmbedding` and nowhere else. The issues index beside it
  (ADR 0032) is the same rule with the same words: a second corpus built from rows the issues sweep
  already wrote, ranked by a sibling of the same lexical ranker, embedded by the same on-device
  provider or by nothing at all. The BYOK endpoint is
  **never** used for it, even when the user has configured one and switched the AI tiers on, and
  that is a rule rather than a default: search runs on every keystroke and over every pull request
  in the inbox, so a provider-backed embedding would ship the whole inbox — titles, descriptions,
  diffs — to a third party as a side effect of typing, which is the opposite of the "somebody
  clicked and can see the result" argument that makes the tiers above acceptable. Nothing in
  `Features/Search/` takes an `IntelligenceRouter`, a base URL or a key, so the impossibility is
  structural; keep it that way. The lexical ranker in `ShepherdCore` is the fallback and is always
  on, which is why no search surface may hard-depend on a model being present (ADR 0007's rule,
  unchanged).
- **The recurring-finding pass reads your own comments, on this Mac.** The feedback loop (ADR 0029)
  is the second thing Shepherd does while nobody is watching, and it reads *review prose*, so its
  licence is narrower than the digest's: `DatabaseManager.viewerReviewComments(login:since:)` matches
  the signed-in login in SQL and returns nobody else's rows at all, and the embeddings come from the
  same on-device `EmbeddingProviding` ⌘K search uses. Nothing in the detection path — `ShepherdCore/Review/RecurringFindings.swift`,
  `Features/Review/RecurringFindingCoordinator.swift` — takes an `IntelligenceRouter`, a base URL or
  a key, so the impossibility is structural, exactly as it is for search; keep it that way. The
  *attended* half may use the tiers, because the reviewer pressed a button and reads the result in a
  field before running it — and it goes through feature E's existing brief request, which already
  refuses the cloud rung for a comment somebody else wrote. No new host, no GitHub read, nothing
  stored.
- **Spotlight gets metadata, never content.** The Spotlight export (ADR 0021) is the only thing
  Shepherd writes *outside* its own database that nobody asked for click by click, and the system
  index is not the app's to govern: it is machine-wide, it is backed up, and other processes can
  query it. So what is exported per pull request is the title, `owner/repo#123 · author · CI
  state`, and its labels, repository and agent as keywords — the same metadata GitHub shows anyone
  who can see the pull request — and **never** a description, a diff hunk, a review comment or a
  draft. That is enforced by `SpotlightItemFields` having nowhere to put one, and by the App
  Intents entity beside it carrying the same five fields and no more; keep it that way, because a
  field added there leaves the app's sandbox for every pull request in the inbox at once. The
  switch is in Settings → Intelligence, switching it off deletes the whole domain, and no host is
  added — Spotlight is local. The same ADR is why there is no intent that approves, merges or
  comments: see the verdict rule below.
- **Shepherd never forms a verdict unattended.** Two rules may act without a human in the loop:
  auto-delegation (ADR 0016) starts a local agent, and auto-merge (ADR 0018) queues a merge. The
  second one is only acceptable because it *records* a decision a human already made — the
  approval — which is why its conditions (agent-authored, checks green with at least one check,
  `reviewDecision == .approved`, not a draft, mergeable) are enforced by
  `ShepherdCore/Automation/AutoMergePolicy.swift` and are **not** fields of `AutoMergeRules`. The
  two fields that exist can only narrow them. Anything that would let a rule merge without an
  approval, approve, submit a review or push is a non-goal (ROADMAP) and needs its own ADR — and
  no rule may write to GitHub except through the ordinary outbox (ADR 0006).
- Conventional commits appreciated (`feat:`, `fix:`, `docs:` …), not enforced.

## License

By contributing you agree your contributions are licensed under the [MIT license](LICENSE).
