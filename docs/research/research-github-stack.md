# Research: GitHub-native, local-first PR review inbox (desktop app)

Scope: open-source, standalone desktop app; "sign in with GitHub"; local storage only; Linear-style
review inbox aggregating PRs across all of a user's repos; full review flow (inline comments,
pending multi-comment reviews, approve/request-changes/comment, merge). Research current as of
2025/2026.

---

## 1. Authentication

### The core problem
An OSS desktop app ships its source (and usually its binary) publicly. Any `client_secret` baked
into an **OAuth App** flow is trivially extractable — it is not a secret in practice. This is a
known, accepted trade-off in the ecosystem, not a solved one:

- **GitHub Desktop** (Electron, OSS) uses the classic OAuth **web application flow** and literally
  bundles a Client ID + Client Secret into the webpack build for its own hosted app. Its own docs
  say outright about the fallback dev credentials: *"DO NOT TRUST THIS CLIENT ID AND SECRET! THIS
  IS ONLY FOR TESTING PURPOSES!!"* It supports overriding via `DESKTOP_OAUTH_CLIENT_ID` /
  `DESKTOP_OAUTH_CLIENT_SECRET` env vars for forks/CI. (github.com/desktop/desktop docs/technical/oauth.md)
- **GitHub CLI (`gh`)** sidesteps the problem entirely: it uses **OAuth Device Flow**, which
  requires only a public **Client ID** (`178c6fc778ccc68e1d6a` is `gh`'s, visible in source) and
  **no client secret at all**. The device flow is a "headless" flow: the app requests a device
  code, shows the user a short code, the user opens github.com/login/device in any browser (even
  on another machine) and approves; the app polls for the resulting token. This is GitHub's own
  documented recommendation for CLIs/desktop/headless apps.
- **Gitify** (OSS Electron menu-bar notifications app) similarly authenticates via OAuth against a
  bundled public client, no secret-dependent flow for its core function.

### What changed recently (2025)
GitHub added **PKCE (Proof Key for Code Exchange) support for both OAuth Apps and GitHub Apps**
in mid-2025. PKCE lets a "public client" (native/desktop app that cannot protect a secret) safely
use the **Authorization Code flow with a loopback redirect** (`http://127.0.0.1:<port>/callback`)
*without* a client secret — the PKCE code_verifier/code_challenge pair replaces the secret as
proof of the token request's authenticity. This is now the modern equivalent of what device flow
already offered, but with a nicer UX (auto-redirect back into the app instead of manual code entry).

### GitHub App vs OAuth App
GitHub's current guidance is unambiguous: **prefer GitHub Apps over OAuth Apps** for anything new.
Reasons directly relevant to this project:
- **Fine-grained permissions** (per-resource: Pull requests, Contents, Checks, Metadata) instead
  of OAuth's coarse `repo` scope (all-or-nothing access to every private repo the user can touch).
- **User-to-server tokens are short-lived** (8 hours) with a **refresh token** (~6 months) — a
  leaked access token has a small blast radius; OAuth App tokens are long-lived/non-expiring by
  default (unless the org enables expiration).
- **User controls which repos/orgs** the installation can see (repo-selection screen at install
  time), which matches "local-first / minimal trust" positioning well for an OSS tool people will
  install broadly.
- GitHub Apps **also support Device Flow** (must be explicitly enabled in the App's settings) and
  now PKCE — so the "no secret" login options exist for GitHub Apps too, combining fine-grained
  permissions with a secretless auth flow.

### Recommendation
1. **Register a GitHub App** (not an OAuth App) for the product. Free, one App serves all users.
2. **Primary flow: Device Flow** (simplest to implement cross-platform, no local HTTP server/port
   conflicts, works even in restrictive/corporate network setups) — enable it in the App's
   settings; store only the public Client ID in the binary/source.
   - **Alternative/upgrade: Authorization Code + PKCE with loopback redirect** for a smoother
     "click Sign in → browser opens → auto-return to app" UX (what GitHub Desktop's *new* PKCE
     path and many modern CLIs are moving toward). Either is secret-free and fine for OSS; PKCE
     flow is a bit more polished UX-wise, device flow is a bit simpler to implement correctly.
   - Do **not** replicate GitHub Desktop's legacy bundled-secret OAuth App pattern — it's a known
     wart tolerated only because it predates PKCE/device flow being viable options.
3. **Permissions to request** (GitHub App, repository permissions): `Pull requests: Read & write`,
   `Contents: Read` (diffs; `Read & write` only if you ever push suggested-change commits),
   `Checks: Read` (CI status), `Metadata: Read` (mandatory/auto). Account permission
   `Email addresses: Read` only if needed for attribution. This is materially narrower than OAuth's
   `repo` scope.
4. **Fallback: fine-grained Personal Access Token** entry field for power users, orgs with SSO/App
   restrictions, or GitHub Enterprise Server instances where the App isn't installed. Required
   fine-grained PAT permission: `Pull requests: Read & write` (this alone covers create/comment/
   review/merge/close; `Metadata: Read` is auto-added). Treat it exactly like an App token in
   storage/rotation UI, just without auto-refresh.
5. **Token storage: OS Keychain**, never plaintext/UserDefaults/JSON-on-disk.
   - macOS (Swift): `kSecClassGenericPassword` via the Security framework, or a thin wrapper
     (`KeychainAccess`) — store access token + refresh token + expiry, keyed by GitHub account
     login, service name scoped to the app's bundle ID. Keychain items **persist past uninstall**,
     so clear them proactively on explicit "sign out."
   - Cross-platform (Tauri/Electron): the `keyring` Rust crate (Tauri) or Electron's built-in
     `safeStorage` API both transparently back onto macOS Keychain / Windows Credential Manager /
     Linux Secret Service — same guarantee, no custom crypto needed.

---

## 2. API surface for the review flow

### (a) Listing open PRs across *all* repos — use Search, not per-repo listing
The **Search API** (`GET /search/issues?q=...` REST, or `search(query:, type: ISSUE)` in GraphQL)
is the efficient primitive here: **one query returns matching PRs across every repo the token can
see**, so you never need to enumerate 50 repos and hit `GET /repos/{o}/{r}/pulls` 50 times per poll.
Useful facets to compose into 2-4 inbox queries per poll:
- `is:pr is:open review-requested:@me` — "needs my review" (the core inbox)
- `is:pr is:open author:@me` — "my open PRs" (status/CI tracking)
- `is:pr is:open involves:@me` — broader catch-all (mentions, assigned, commented)
- add `archived:false`, `draft:false` as needed; GraphQL additionally supports `org:` filters if
  you want to shard a huge account.
- GraphQL vs REST here: functionally equivalent; GraphQL lets you shape the exact fields you want
  (title, updatedAt, headRefOid, `statusCheckRollup`, `reviewDecision`) in the *same* round trip
  that lists the PRs, which REST search cannot do (REST search returns issue-shaped objects with
  no CI/review-decision fields — you'd need a second call per PR). **Prefer GraphQL search for the
  inbox list** for exactly this reason — it turns "list + N detail calls" into one call.

### (b) Fetching diffs/files
- REST: `GET /repos/{owner}/{repo}/pulls/{pull_number}/files` (paginated, gives per-file `patch`
  unified-diff text, additions/deletions, status) — simplest, well-documented, good default.
- REST alternative: `GET /repos/{owner}/{repo}/pulls/{pull_number}` with
  `Accept: application/vnd.github.v3.diff` returns the whole PR as one raw unified diff blob —
  fewer requests for very small PRs, but loses per-file structure/pagination for huge diffs.
- GraphQL: `pullRequest.files(first: N) { path, additions, deletions, patch }` — same data, can be
  combined into the same query as PR metadata/threads/checks (fewer round trips overall).

### (c) Pending review with multiple inline comments, then submit
Two options, both real:
- **REST (recommended default):** `POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews` accepts
  `commit_id`, `event` (`APPROVE`|`REQUEST_CHANGES`|`COMMENT`, or **omitted** for a `PENDING`
  draft), `body`, and a **`comments` array** (each with `path`, `line`/`start_line`, `side`,
  `body`) — this lets you **create the review and attach every inline comment in a single POST**,
  then either submit it in that same call (set `event`) or leave it `PENDING` and later call
  `POST .../reviews/{review_id}/events` to submit. This maps cleanly onto "draft a multi-comment
  review, walk away, come back and submit" without juggling per-comment calls.
- **GraphQL:** `addPullRequestReview` (optionally with an initial `comments` list) starts a
  `PENDING` review tied to the viewer; `addPullRequestReviewThread` adds further threads to that
  pending review; `submitPullRequestReview` finalizes it with an event. Functionally equivalent,
  but community bug reports exist against `addPullRequestReviewThread` edge cases, and it's more
  round trips for the same outcome than the REST single-POST path.
- **Recommendation:** use **REST for the write side** (create/submit reviews) — it's simpler,
  well-trodden, and supports the "one call, many inline comments" shape natively. Reserve GraphQL
  mutations for the two things REST *cannot* do at all (next section).

### (d) Review threads: replying & resolving
- **Replying to an existing review comment:** REST has a dedicated endpoint —
  `POST /repos/{owner}/{repo}/pulls/{pull_number}/comments/{comment_id}/replies`.
- **Resolving/unresolving a review thread: GraphQL-only.** There is no REST equivalent —
  `resolveReviewThread(threadId:)` / `unresolveReviewThread(threadId:)` mutations must be used, and
  you need `pullRequest.reviewThreads(first:N){ nodes { id isResolved comments(...) } }` (GraphQL)
  to enumerate thread IDs in the first place. **Plan on a GraphQL client for thread-resolution UX**
  even if writes otherwise go through REST.

### (e) CI/checks status
- REST: `GET /repos/{owner}/{repo}/commits/{ref}/check-runs` (GitHub Checks API, per check-run
  detail) or the older combined `GET /repos/{owner}/{repo}/commits/{ref}/status` (single rolled-up
  state: `success`/`pending`/`failure`).
- GraphQL: `commit.statusCheckRollup.state` — a **single scalar field** giving the rolled-up state,
  ideal for an inbox list view (green/red/yellow dot per row) without a second REST call per PR.
  Fetch full per-check detail only when the user opens a PR.

### (f) Merging
REST `PUT /repos/{owner}/{repo}/pulls/{pull_number}/merge` (body: `merge_method`:
`merge`|`squash`|`rebase`, optional `sha` precondition). Returns `200` merged / `405` not
mergeable / `409` sha mismatch. No meaningful GraphQL advantage here; REST is simpler.

### Detecting agent/bot-authored PRs
No single field is fully reliable; combine signals:
- **`author`/`user` object type:** REST `pull_request.user.type == "Bot"`; GraphQL
  `pullRequest.author.__typename == "Bot"`. Catches classic bot accounts (`dependabot[bot]`,
  `github-actions[bot]`, most GitHub Apps posting as themselves).
- **Login suffix heuristic:** logins ending in `[bot]` (Dependabot, Renovate, github-actions,
  most GitHub-App-authored activity) are bots by convention, but **not universal** — e.g. GitHub's
  own Copilot coding agent and various third-party coding agents (Claude Code, Cursor, etc.) may
  authenticate as a GitHub App/bot account whose login does **not** always carry the `[bot]`
  suffix, or may show up as a regular user's PAT-authenticated commit depending on how the agent
  was invoked.
- **Practical approach:** treat `type == "Bot"` as authoritative where present, layer a
  maintained allow/deny list of known agent logins (`copilot-swe-agent[bot]`, `claude[bot]`,
  `cursor[bot]`, `github-actions[bot]`, `dependabot[bot]`, `renovate[bot]`, etc.) for UI labeling
  ("🤖 Agent PR"), and let users extend the list — this mirrors how `claude-code-action`'s own
  `allowed_bots` allowlist pattern works upstream.

### Rate limits (2025/2026 figures)
| Bucket | Limit | Notes |
|---|---|---|
| REST **core** (authenticated user/OAuth App/PAT) | **5,000 req/hour** | shared across nearly all REST endpoints except search |
| REST **search** (`/search/issues`, `/search/pulls`, etc.) | **30 req/minute** (~1,800/hour ceiling, but the per-minute cap binds first) | separate bucket from core; code search has its own lower 10/min limit — not used here |
| **GraphQL** | **5,000 points/hour** | cost is per-query, scales with node/connection breadth requested, not flat per-call |
| **Secondary rate limits** | ~80 content-generating requests/min, ~500/hour (mutations: comments, reviews, etc.) | independent of the above; triggered by bursty write patterns, not reads |
| **Conditional requests** | 304 responses **do not** count against the primary rate limit, provided the request is sent with a valid `Authorization` header and an `If-None-Match` (ETag) — unauthenticated conditional requests still decrement the budget | core mitigation strategy for polling |
| **Notifications endpoint** | honors `Last-Modified`/`If-Modified-Since` (free 304s) and returns an `X-Poll-Interval` header (server-suggested minimum poll gap, commonly ~60s) that clients are expected to respect | purpose-built for exactly this polling use case |

### Rate-limit math: 50 repos, polled every 2 minutes
The naive design ("loop over 50 repos, call `GET /repos/{o}/{r}/pulls` on each, every 2 min") is
the one to avoid — it wastes the *wrong* budget:
- 50 repos × 30 polls/hour (60min ÷ 2min) = **1,500 REST core requests/hour** just to list PRs,
  before a single diff, thread, or check is fetched — already 30% of the 5,000/hour core budget
  from list calls alone, and each subsequent PR-detail fetch (files, checks, threads) adds more.

The recommended design (search-first, delta-aware) is far cheaper:
- **List step:** 1 GraphQL (or REST search) call per poll cycle covering *all* repos at once via
  `is:pr is:open involves:@me` (+ 1-2 more facet queries for author/review-requested splits) →
  **~2-4 requests / 2-min cycle ≈ 60-120 requests/hour**, against a 1,800/hour search-bucket
  ceiling (REST search) or a few hundred GraphQL points/hour (GraphQL search) — **3-7% of budget**.
- **Detail step:** compare each returned PR's `updatedAt`/`headRefOid` against the local SQLite
  cache; only fetch files/threads/check-rollup for PRs that actually changed since last poll.
  In steady state (a working set of, say, 5-15 "live" PRs out of 50 repos) this adds roughly
  **10-30 additional REST/GraphQL requests per cycle at most**, i.e. **~300-900/hour worst case**,
  still well under the 5,000/hour core ceiling — and every unchanged-PR check via conditional
  ETag GET costs **nothing** against the budget.
- **Net:** a well-built client polling 50 repos every 2 minutes should sit at roughly
  **~5-20% of REST core budget and single-digit percent of the search budget** — comfortable
  headroom for multiple accounts/orgs, background CI-status refreshes, and the occasional burst of
  interactive detail loads (opening a PR triggers its own on-demand fetch outside the poll cycle).
- **The one real risk** is firing all "detail" fetches for many changed PRs in the same instant —
  stagger/queue them (e.g. max 5-10 concurrent, small jitter) to avoid tripping the **secondary**
  rate limit (~80 content-generating req/min), which is independent of the primary counters above.

---

## 3. Notifications

- **No inbound webhooks for a local-only desktop app.** Webhooks require a public HTTPS endpoint;
  a local-first app has none by design, and standing up a relay (smee.io, an ngrok tunnel, or a
  hosted relay service) to receive them would violate the "everything stored locally, no backend"
  premise and adds an availability dependency most users won't want. **Polling is the correct and
  accepted pattern** — this is exactly how the comparable OSS prior art works:
  - **GitHub Desktop** and **Gitify** (OSS, Electron, menu-bar GitHub notifications app,
    macOS/Windows/Linux) both poll the REST `GET /notifications` endpoint rather than using
    webhooks.
- **`GET /notifications`** is purpose-built for this: supports `since`/`participating` filters,
  returns a `reason` field per thread (`review_requested`, `mention`, `assign`, `author`, etc.) so
  you can route "review requested" notifications straight into the inbox, supports conditional
  `If-Modified-Since`/`Last-Modified` for free 304s, and returns an **`X-Poll-Interval`** response
  header telling the client the server's currently-recommended minimum poll cadence (commonly
  ~60s; can rise under GitHub-side load, and well-behaved clients back off accordingly).
- **Recommended polling design:** two complementary, independently-scheduled loops —
  1. `GET /notifications?participating=true` every `X-Poll-Interval` seconds (server-governed,
     cheap, catches review requests/mentions/CI-failure-on-your-PR fast).
  2. The GraphQL/search inbox sweep (section 2a) every ~2 minutes for the full cross-repo PR list,
     state changes (new commits, CI rollup, review decision), and anything the notifications feed
     might miss (e.g. a PR opened without explicitly requesting your review yet, if you track
     `author:@me`/`involves:@me` too).
  Use notifications as the "wake up sooner" signal and the search sweep as the source of truth for
  full inbox state.

---

## 4. Tech stack comparison

| | **Native Swift/SwiftUI** | **Tauri v2 + React** | **Electron + React** |
|---|---|---|---|
| Platforms | macOS only (as scoped: "macOS-first" fits) | macOS/Windows/Linux (+ mobile via v2) from one codebase | macOS/Windows/Linux |
| Binary size / RAM | Smallest; native, no runtime to ship | ~3-10 MB app bundle typical (uses OS webview, not bundled Chromium); ~50% lower RAM than Electron in benchmarks | Largest: ~100-150 MB installer, bundles Chromium+Node; heaviest RAM/cold-start footprint |
| Cold start | Fastest (native) | Fast (~190ms class on Apple Silicon in published benchmarks) | Slowest (~600ms+ class) |
| Diff-viewer / syntax highlighting | **No off-the-shelf Monaco equivalent.** Build on `STTextView` (actively maintained, performant `NSTextView`-based editor component, has a Tree-sitter plugin — `STTextView-Plugin-Neon` — for real syntax highlighting) or `Highlightr` (wraps highlight.js via `JSContext`, simplest path to colored diff lines, less "native"). `Runestone` exists but is iOS-first with less-proven macOS maturity. **This is the single biggest engineering line-item on this path** — a GitHub-quality side-by-side/unified diff view with inline comment gutters is weeks of custom work, not a library import. | Full access to the web diff ecosystem in a native-ish shell: **Monaco's diff editor** (VS Code's actual engine) runs unmodified in the WKWebView, or lighter options (`react-diff-view`, Shiki for highlighting) if Monaco feels heavy. Gets near-Electron diff UX at a fraction of the footprint. | Same Monaco diff editor, but this is Monaco's *native habitat* — this exact pattern (Electron + Monaco diff view for PR/agent review) already has working OSS prior art (e.g. **Bottleneck**, an Electron app reproducing the GitHub PR review experience with Monaco as the diff viewer). Lowest engineering risk for diff-viewer quality specifically. |
| Local storage | **GRDB.swift** — mature Swift SQLite toolkit: typed query interface, migrations, `DatabasePool`/snapshots for concurrent read/write, `ValueObservation` for reactive UI updates off a local cache. Good fit for "load from cache instantly, refresh in background, merge back" offline-first pattern. | Rust core + `rusqlite`/`sqlx` + SQLite; equally mature, plus Rust's ownership model helps correctness in the sync/cache layer. | `better-sqlite3` or similar from the Node side; mature, but the Node/main-process boundary adds a bit more plumbing than either of the other two. |
| Keychain/token storage | Native Security framework / `KeychainAccess` — simplest, most idiomatic option of the three. | `keyring` Rust crate — transparently backs onto macOS Keychain (and Credential Manager/Secret Service if cross-platform ships). | Electron's built-in `safeStorage` API, backed by Keychain/DPAPI/libsecret. |
| Extra capability | **Apple Foundation Models framework** (macOS 26+, on-device 3B-parameter LLM, privacy-preserving, no inference cost) is uniquely available here for e.g. on-device PR/diff summarization — a real differentiator if the product wants "smart" inbox triage without a backend or API cost. Not available to Tauri/Electron (no equivalent framework binding). | — | — |
| Maturity/ecosystem risk | Smallest ecosystem of the three for this exact use case; more custom code, but stable, well-understood platform. | v2 is comparatively young (mobile support, plugin APIs still maturing); relies on OS webview versions (WKWebView on macOS is fine; older Windows WebView2 versions can be a support tail). | Most mature ecosystem overall; downside is footprint/security-surface, not capability. |

### Recommendation
Given the explicit bar ("Linear-quality" UI) and that the **hardest, highest-risk single piece of
this product is the inline-comment diff viewer**, the practical trade-off is:

- **If cross-platform optionality matters at all, or the team wants to de-risk the diff-viewer
  problem fastest: Tauri v2 + React + Monaco's diff editor.** This reuses a battle-tested,
  GitHub-quality diff/comment-gutter UI (Monaco) inside a shell that is dramatically lighter than
  Electron (single-digit-MB bundles, ~50% less RAM, much faster cold start), keeps a genuine Rust
  core for the local SQLite cache and OS-keychain token storage, and preserves a real path to
  Windows/Linux later without a rewrite. This is the pragmatic sweet spot for hitting a polished
  bar without absorbing Electron's footprint or SwiftUI's from-scratch diff-viewer cost.
- **Pure native Swift/SwiftUI is the right call only if macOS-only is a firm, permanent
  constraint** and the team is willing to invest real weeks building the diff viewer on
  `STTextView` (+ the Neon/Tree-sitter plugin for syntax highlighting) — the payoff is the deepest
  native integration (menu bar, Keychain, notarization, and uniquely, **on-device Foundation
  Models** for local PR/diff summarization with zero backend and zero inference cost, which fits
  the local-first thesis unusually well). Treat this as the credible "phase 2 native rewrite" once
  the product concept is validated, or as the v1 choice only if a Monaco-quality diff view isn't
  actually required for the first release (e.g. a simpler unified-diff-only MVP).
- **Electron + React is the fallback, not the first choice** here: it removes all diff-viewer risk
  (Monaco native habitat, direct prior art in Bottleneck) but at the cost this whole product
  concept is explicitly trying to avoid — the heaviest footprint, for an app whose main pitch is a
  fast, always-on, local-first menu-bar-adjacent tool. Reasonable to keep in reserve if Tauri v2's
  webview/native-integration maturity becomes a real blocker during build-out.

---

## Sources consulted
- GitHub Docs: OAuth App best practices, GitHub App best practices, authorizing OAuth apps,
  device flow, fine-grained PAT permissions, REST rate limits, REST search, REST pulls/reviews,
  REST pull request comments, REST notifications, REST commit statuses/checks, GraphQL mutations
  reference (`addPullRequestReview`, `addPullRequestReviewThread`, `resolveReviewThread`).
- `desktop/desktop` repo: `docs/technical/oauth.md` (GitHub Desktop's bundled OAuth credential
  handling and its own caveats).
- `cli/cli` / `cli/oauth`: device flow implementation, public client ID usage.
- `gitify-app/gitify`: OSS Electron GitHub-notifications app (polling prior art).
- `areibman/bottleneck`: OSS Electron PR-review app using Monaco as the diff viewer (prior art for
  the Tauri/Electron diff-viewer approach).
- Swift ecosystem: GRDB.swift docs, `STTextView` / `STTextView-Plugin-Neon`, `Highlightr`,
  `Runestone`, `KeychainAccess`.
- Apple: Foundation Models framework announcement/docs (WWDC25, macOS 26).
- Tauri v2 official docs and community benchmarking write-ups (binary size, RAM, cold start vs
  Electron).
- GitHub community discussions on GraphQL query cost, secondary rate limits, and bot/author-type
  detection patterns (incl. `claude-code-action`'s `allowed_bots` pattern as an example allowlist
  approach).

*Note: several figures above (poll intervals, exact rate-limit numbers, PKCE rollout details) are
drawn from GitHub's own docs/changelog and community reporting as surfaced via web search in
August 2026; verify exact current numbers against `docs.github.com` at implementation time, since
GitHub has adjusted specific thresholds before.*
