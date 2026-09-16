# ADR 0013: A `shepherd://` URL scheme, and a CLI that speaks nothing else

Status: Accepted (v1.x scope) · Date: 2026-09-01

## Context

ADR 0012 gave Shepherd a way to tell the outside world what happened. The opposite direction is
still missing: nothing outside the app can ask Shepherd to *do* something. The concrete wishes
are small and all the same shape — a Raycast entry that jumps to the pull request under review, a
`shepherd open owner/repo#123` in the terminal instead of hunting the row in the list, a keyboard
shortcut that opens "Needs my review", and — the one that closes the loop with ADR 0012 — an n8n
workflow that receives a GitHub notification and *opens the pull request on the reviewer's Mac*
via an Execute Command node.

Three channels could carry that, and they are not equally cheap:

- A **URL scheme** is a single Info.plist entry plus one `onOpenURL` handler. Every tool on macOS
  can already open a URL: `open(1)`, Raycast, Shortcuts, Alfred, a `Cmd`-click in a note, an n8n
  Execute Command node, a `<a href>` in the user's own dashboard. It launches the app if it is
  not running, and it is the only one of the three that needs no permission dialog, no entitlement
  and no second process.
- **XPC / a Mach service** would give typed request/response and could return data. It needs a
  service registration, a signed and installed helper, a hand-written protocol on both sides, and
  a story for authenticating callers — a lot of machinery for "please show me this pull request".
- **AppleScript / an `NSAppleEventsUsageDescription` scripting dictionary** would make Shepherd
  scriptable in the classic Mac way, including *reading* state ("how many pull requests need my
  review?"). It also means an `sdef`, Apple event plumbing, and the automation-permission prompt
  in System Settings that users have learned to distrust.

The distinction that decides it: everything asked for so far is *navigation and one command* — go
here, filter that, sync now. None of it needs a return value. A URL scheme is exactly a fire-and-
forget navigation channel, and it is the smallest thing that can carry all of it.

The second question is the CLI. A command-line tool could talk to GitHub itself — it has the
same Keychain, after all. That would make it a second, unsupervised copy of the app's write path:
a second place tokens are read, a second place mutations are made without the outbox (ADR 0006),
a second thing to audit. The whole appeal of the CLI is convenience of *typing*, not a second
client.

## Decision

- **One channel: the `shepherd://` URL scheme.** Registered by the app
  (`CFBundleURLTypes` in `project.yml`, so it is generated with the rest of the Info.plist) and
  handled in exactly one place, `ShepherdApp`'s `onOpenURL`. The grammar is closed:

  | URL | Effect |
  | --- | --- |
  | `shepherd://pr/<owner>/<repo>/<number>` | Open the full-window review screen for that pull request |
  | `shepherd://inbox` | Show the inbox |
  | `shepherd://inbox?filter=<token>` | Show the inbox with one rail filter applied |
  | `shepherd://sync` | Run one sweep now (the ⌘R path) |
  | `shepherd://settings` / `shepherd://settings/<tab>` | Open Settings, optionally on a tab |

  Filter tokens: `needs-my-review`, `mine`, `involved`, `approved-by-me`, `watched`, `humans`,
  `bots`, `agent:<id>`, `repo:<owner>/<name>`. Settings tabs: `account`, `sync`, `agents`,
  `intelligence`, `delegation`, `automation`, `appearance`.

- **Parsing is a pure value type in ShepherdCore.** `DeepLink.parse(URL) -> DeepLink?` imports
  Foundation and nothing else, so it is unit-tested headlessly on both CI runners
  (`docs/ARCHITECTURE.md`, "Verification reality check") rather than only inside a simulator run.
  `DeepLink.urlString` is the same grammar in the other direction, which is what lets the CLI
  build URLs the app is guaranteed to accept — a round-trip property the tests pin.

- **Untrusted input, validated strictly.** Any process on the Mac can open a URL, so the parser
  refuses rather than guesses: the command word and both token vocabularies are closed sets;
  `owner`, `repo` and `number` must match GitHub's own character rules (ASCII only — a Cyrillic
  look-alike login must not resolve); percent-decoding happens *after* the path is split, so an
  encoded `/` can never create structure; a trailing extra segment is a rejection, not something
  to ignore; and a URL carrying a user, password, port or fragment is refused outright. No case
  carries a file path, a command line, a URL to fetch or a body to POST, so there is nothing in
  the grammar that could become a shell invocation, a file read or an exfiltration target. An
  unparsable link produces one toast and no state change. The privacy line of `CONTRIBUTING.md`
  is untouched: a deep link adds no host — `shepherd://pr/...` causes at most the same
  `api.github.com` detail fetch that clicking the row does.

- **Routing goes through the existing state machine, not around it.** `AppEnvironment` owns it:
  `.pullRequest` ends in `openReview(prID:)`, `.inbox`/`.settings` set `route` and raise a
  pending request the inbox screen consumes (the same mechanism menu commands and ⌘K already use
  for actions), `.sync` calls `syncNow()`. No deep link reaches into a model a screen owns, and
  no deep link is a second implementation of anything.

- **Not signed in: remember it, run it after sign-in.** A link that arrives while the app is
  launching or on the sign-in screen is kept in one slot (last link wins) and executed at the end
  of a successful session start; on the sign-in screen the user is told so. Ignoring it would be
  the wrong default, because opening the app *is* how a link launches it: the very first deep
  link of a session almost always arrives before the Keychain check has finished. Signing out
  clears the slot — the link was meant for the account that was signed in.

- **Pull request not in the cache: fetch that one pull request, then navigate.** The inbox is a
  sweep of `involves:@me` (ADR 0005), so the most interesting link — the one a colleague or an
  n8n workflow sends you — is frequently *not* in it. Triggering a sweep would take seconds and
  still not find it. So the cache is consulted first (free, covers every row in the inbox) and
  otherwise the app fetches exactly that pull request, stores it (ADR 0006: the screen renders
  from SQLite), and opens the review screen. Failures — no access, wrong number, offline —
  surface as a toast naming the pull request.

- **The CLI is a URL builder, and that is the security boundary.** `shepherd` is a separate
  executable target that links `ShepherdCore` **only**: no GitHubKit, no persistence, no
  Keychain, no network code, no configuration file of its own. It maps arguments to a
  `DeepLink` and hands the URL to `NSWorkspace`. Installing it therefore grants no capability
  the app does not already expose to every process on the Mac, and there is no second write path
  to audit. Its argument grammar (`ShepherdCommandLine`) lives next to the URL grammar it
  targets, in the same package, tested together — the two cannot drift.

- **Console text is English and unlocalised.** The app's `String(localized:)` rule covers its
  UI. A developer tool's `--help` and diagnostics follow the developer documentation instead,
  and `--help` prints the full grammar so the URL scheme is discoverable without the docs.

- **No XPC and no AppleScript in v1.** Both are additive later — an `sdef` on top of this
  changes nothing about it — and both cost a permission story that "open this pull request" does
  not justify. The consequence is accepted openly: a URL scheme cannot *return* anything, so
  "shepherd list" or "shepherd status" is not implementable through this channel and is not
  attempted. Read-only queries, if they are ever wanted, are the decision that would need XPC or
  a scripting dictionary, and get their own ADR.

## Consequences

- Shepherd becomes drivable from anything that can open a URL, which together with ADR 0012 makes
  a full n8n round trip possible without Shepherd ever listening on a port: GitHub → n8n →
  `shepherd open owner/repo#123` on the reviewer's Mac, and Shepherd → webhook → n8n on the way
  back.
- The scheme is a **public interface** from now on. `shepherd://` URLs end up in Raycast scripts,
  browser bookmarks and n8n workflows, so the grammar is additive-only: new commands and new
  tokens are free, a renamed or repurposed one breaks someone's automation. Deleting one needs
  its own decision, exactly like a webhook payload change.
- Any process on the machine can navigate the app. That is the honest cost of the channel, and it
  is bounded by what the grammar can express: navigation, one sweep, and the same detail fetch
  the UI already performs. No deep link can submit a review, merge, delegate, change a setting or
  read anything back — every mutating action stays behind the UI and the outbox.
- A pull request opened by link that the user is not involved in is **not** held in the inbox: the
  next sweep prunes it, because a sweep prunes what its search did not return (only a draft or a
  queued mutation pins a row, `InboxStore.pruneGuardSQL`). The open review screen keeps rendering
  the copy it loaded, and writing anything creates the draft that pins it. Acceptable, and better
  than teaching the sweep about rows it did not fetch.
- The CLI links a package target that carries a resource (the bundled agent registry), and a
  command-line tool has no bundle to find one in. It never reads it — the CLI touches nothing but
  `DeepLink` and `ShepherdCommandLine`, both pure Foundation — and that is a rule worth keeping:
  code the CLI calls must not depend on `Bundle.module`.
- The CLI's version string is a constant in its source that tracks `CFBundleShortVersionString`
  in `project.yml`; both are bumped together. A tool that read its version from a bundle it does
  not have would be worse.
- Distribution grows one artefact. ADR 0010 (DMG + Homebrew) now has a second thing to ship: the
  `shepherd` binary, which a Homebrew formula can install onto the PATH and a DMG user can copy
  by hand. Until then it is built from source (`xcodebuild -scheme ShepherdCLI`).
- `RepoRef` gained `isSameRepository(as:)`. Externally supplied repository references carry
  whatever casing was typed, while `Hashable` conformance has to stay exact because it is a
  persistence key — so identity is now an explicit operation, and the inbox's repository facet
  uses it too.
