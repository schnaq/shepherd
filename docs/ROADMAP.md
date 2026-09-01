# Roadmap

Scope decisions from the founder interviews (2026-08-31, plus the 2026-09-01 follow-up that
prioritised saved replies and the focus review session). v1 is deliberately full-featured on
the review path — the founder's bar is "never need to open github.com for a routine review".

## v0.x → v1.0 (current work)

**Inbox**
- [ ] GitHub sign-in: device flow + fine-grained PAT fallback (ADR 0004)
- [ ] Cross-repo inbox via GraphQL search sweep; sections & facets: provenance (agent/human),
      repo/org, review-requested / my PRs / involved (ADR 0005, 0008)
- [ ] Agent detection with bundled + user-extensible registry (ADR 0008)
- [ ] CI check rollup, review decision, draft/mergeable badges on rows
- [ ] `j`/`k` navigation, ⌘K command palette, saved filter views
- [ ] macOS notifications: new review requests, checks failed on own PRs (polling, ADR 0005)
- [x] Menu-bar quick inbox (pulled into v1 from v1.x): a menu-bar item with the number of pull
      requests waiting for your review, and a small window with the top eight — repo#number,
      title, provenance chip, CI dot — where a click opens the pull request in the main window.
      Plus "Open Shepherd", "Sync now" and "n more…". Reads the same database observation the
      inbox does, has no sync of its own, and can be switched off in Settings → Appearance

**Review**
- [ ] PR detail: description, timeline, commits, checks detail
- [ ] Linked issues on PR detail: closing references ("closes #123") shown with title/state,
      one keystroke to open; issue links in PR bodies/comments resolve to previews
- [ ] Monaco diff viewer: side-by-side & inline, syntax highlighting, dark/light (ADR 0003)
- [ ] File list ordered by review priority with reasons; viewed-state tracking (ADR 0007 tier 1)
- [ ] Pending review composer: inline comments (incl. multi-line), summary, verdict;
      drafts survive restart/offline; staleness check before submit (ADR 0006)
- [ ] Threads: reply, resolve/unresolve
- [ ] Merge: merge/squash/rebase, delete-branch option, mergeability preflight
- [x] Bulk triage (ADR 0015, pulled into v1 from v1.x): tick rows with `x` / ⌘-click / ⇧-click
      (or "select all green agent PRs in this view"), then approve, approve & merge, or merge the
      selection behind **one** confirmation dialog that lists every pull request with its state
      and marks the ones it skips — red CI, conflicts, drafts, changes requested, your own —
      with the reason. Confirming enqueues one ordinary outbox row per write, so offline, retry,
      rate-limit throttling and the per-pull-request staleness check all apply unchanged
- [x] Focus review session (founder interview 2026-09-01): "Start review session" (⇧⌘⏎, `r f`, ⌘K,
      Review menu, or a button in the inbox header) walks through every pull request waiting for
      your review on the ordinary review screen — no second review UI — with a thin bar showing
      "3 of 12", the pull request's title, and `d` done & next / `n` next / `esc` end. Approve,
      request changes and merge advance the queue themselves, at the moment the write reaches the
      outbox rather than when it reaches GitHub. The queue is a **snapshot** taken at start
      (`SmartView.needsMyReview` + `InboxModel.prioritySorted`), so pull requests arriving mid-run
      wait in the inbox instead of moving the goalposts; one that was merged or closed in the
      meantime is skipped with a note when it is reached. Ends with
      "Session complete — 9 reviewed, 3 skipped" plus the duration, and asks first if pull requests
      are still in the queue. No new setting and nothing persisted — a session is a sitting
- [x] Saved replies & review templates (pulled into v1 from v1.x, founder interview 2026-09-01):
      named, reusable Markdown snippets insertable into every comment field — inline comment
      composer, review summary, thread reply — from a `text.badge.plus` menu on the field itself
      (not ⌘K: the palette would have to guess which composer to write into). Plus an optional
      per-repository summary template matched by pattern (`owner/repo` exactly or `owner/*`; exact
      beats wildcard, longer wildcard beats shorter, then list order), used **only** to prefill a
      new, entirely empty draft — a review with a comment, a summary or a verdict is never
      overwritten. Managed in Settings → Replies; both lists travel in the encrypted settings
      document (ADR 0014)
- [x] Delegate to local agent (ADR 0011): send a PR or a review finding back to the locally
      installed Claude Code (headless `claude -p`, stream-json, detached-worktree isolation,
      turn/budget caps); command template configurable for other agent CLIs; Shepherd never
      touches agent auth and never auto-pushes

**Automation (ADR 0012, 0016)**
- [x] Outbound webhooks: POST a versioned JSON event to one user-configured URL (n8n-compatible)
      for `review.submitted`, `pr.merged`, `delegation.finished`, `inbox.new_review_request`;
      events fire only after the outbox actually sent the mutation (or a delegation reached a
      terminal state), optional HMAC-SHA256 signature with a Keychain-stored secret, and a
      failing webhook can never interrupt a review, a merge or a sync. Outbound only —
      inbound webhooks stay excluded (ADR 0005). Schema: [docs/WEBHOOKS.md](WEBHOOKS.md)
- [x] `shepherd://` deep links + companion `shepherd` CLI (ADR 0013): open a pull request, the
      inbox (optionally filtered), a Settings tab, or trigger a sweep — from the terminal,
      Raycast, Shortcuts or an n8n Execute Command node, which together with outbound webhooks
      closes the automation loop without Shepherd ever listening on a port. The CLI links
      ShepherdCore only: it builds URLs, it never talks to GitHub and never sees a token
- [x] End-to-end encrypted settings sync across Macs (ADR 0014): one object in a bucket the user
      owns (STACKIT Object Storage, MinIO, any S3-compatible endpoint), holding every setting
      *and* every secret — GitHub token, AI keys, webhook secret — so a new Mac with bucket access
      and the passphrase is fully set up. PBKDF2-HMAC-SHA256 (600 000 iterations) + AES-256-GCM
      with the envelope metadata as AAD; SigV4 signed by hand for `GET`/`PUT`/`HEAD` on that one
      object, no AWS SDK. Manual upload/download with a confirmation dialog, no background sync in
      v1, no recovery if the passphrase is lost — by design
- [x] Opt-in auto-delegation rules (ADR 0016): when CI turns red on a pull request of yours — or,
      as a second opt-in, when a reviewer requests changes — Shepherd can start the ADR 0011
      delegation for you, in an isolated worktree, with the same turn/budget caps, and with a
      notification saying it did. Off by default; only on the *transition*, never on the state;
      at most one run per pull request and per head commit (deduplicated across restarts); global
      caps for simultaneous and daily runs, with a notification instead of a start when one bites.
      Still no auto-push, no auto-approve, no auto-merge — the result waits in the Delegation
      Center marked as automatic

**Intelligence (ADR 0007)**
- [ ] Tier 1 heuristics: file prioritization, risk hints — always on
- [ ] Tier 2 on-device PR summaries via Foundation Models (availability-gated)
- [ ] Tier 3 BYOK: whole-PR summary & review-focus hints — Anthropic, plus any
      OpenAI-compatible endpoint with one-click endpoint presets (Konduit (EU) — EU-hosted open
      models, with a link to the console for the key; Ollama on localhost; or a custom base URL),
      model discovery via `GET {base}/models` with the free-text model field as the fallback, and
      a connection test (ADR 0007 amendment)

**Foundation**
- [ ] Local-first SQLite cache + outbox (ADR 0006)
- [ ] Dark/light theme system, Linear-inspired visual language
- [ ] CI: ShepherdKit tests (macOS + Linux), web bundle build+tests, app build on macOS runner

## v1.x

- Authorization Code + PKCE loopback sign-in (nicer than device flow)
- ~~Bulk triage actions (approve/merge a selected set of green agent PRs, one confirm)~~ —
  pulled into v1, see above (ADR 0015)
- Draft AI-assisted review comments & commit/PR message suggestions (explicit founder wish;
  needs tier 2/3)
- Multiple GitHub accounts; GitHub Enterprise Server base-URL support
- Automatic settings sync (ADR 0014 deferred it deliberately): needs a conflict story before
  last-write-wins may touch a document that contains the GitHub token. Candidates: per-Mac objects
  plus an explicit "adopt from" step, or an `If-Match`/ETag guard with a visible conflict
- ~~Menu-bar quick inbox~~ — pulled into v1, see above
- ~~Saved replies & per-repo review templates~~ — prioritised in the founder interview of
  2026-09-01 and pulled into v1, see above. Still open on top of it: template placeholders
  (`{repo}`, `{number}`) the way auto-delegation's task template has them, and inserting a snippet
  at the caret rather than appending — the latter needs an `NSTextView`-backed comment field, which
  is a bigger change than the feature was worth
- More webhook events (thread replies, resolves, checks turning red) — additive under `"v": 1`
  (ADR 0012)
- More auto-delegation conditions (ADR 0016 keeps the action fixed: a third *condition* is a case
  in one enum plus a checkbox; a third *action* needs a new ADR). A shared, synced ledger so two
  Macs cannot both start a run for the same pull request is the open question there
- More `shepherd://` commands (additive by design, ADR 0013). Anything that must *return* data
  (`shepherd status`, "how many need my review?") is not a URL-scheme feature and needs the XPC
  or AppleScript decision ADR 0013 deferred
- Issues as a first-class inbox section: browse/triage issues across repos, link/unlink
  issues to PRs, see which agent PRs address which issue — groundwork for "assign an issue
  to an agent" flows
- ~~Signed + notarized releases, Homebrew cask, Sparkle appcast (ADR 0010)~~ — **built, waiting on
  one credential.** `Scripts/release.sh` (build → Developer-ID sign → DMG → notarize → staple →
  Sparkle-sign → appcast), `.github/workflows/release.yml` (tag `v*` or manual), Sparkle 2 in the
  app with a "Check for Updates…" menu item and an opt-out toggle in Settings, and a Homebrew
  cask template for `schnaq/homebrew-tap` are all committed. What is missing is the maintainer's
  Apple Developer ID certificate and one run of Sparkle's `generate_keys`: until then the updater
  refuses to start (and says why, rather than shipping something unverified) and the release
  workflow aborts on its first step naming the missing secrets. One-time setup:
  [docs/RELEASING.md](RELEASING.md)

## Later / explorations

- Checkout-and-run integration (open worktree in editor/terminal for local verification)
- Team dashboards (review load, agent PR statistics)
- iPad companion (ShepherdKit is already platform-independent)

## Non-goals

- Windows/Linux builds (ADR 0001), Mac App Store for v1 (ADR 0010), running/hosting coding
  agents (Shepherd reviews their output; it doesn't orchestrate them — an opt-in rule may *start*
  a local delegation on your own machine, ADR 0016, but nothing is hosted and nothing is written to
  GitHub by it), auto-submitting AI-generated reviews (AI output is always a suggestion a human
  confirms).
