# Roadmap

Scope decisions from the founder interviews (2026-08-31, the 2026-09-01 follow-up that
prioritised saved replies, the focus review session and the morning digest, and the 2026-09-02 one
that added semantic ⌘K search, the Apple-native intelligence block — Writing Tools, on-device
translation, App Intents, Spotlight — and settled what comes after v1: the issues inbox, see
[v1.1](#v11--issues-inbox-and-agent-assignment)). v1 is deliberately full-featured on the review
path — the founder's bar is "never need to open github.com for a routine review".

Ticked boxes are shipped on `main`; the unticked lines under **Foundation** are what remains before
the release workflow is run in earnest.

## v0.x → v1.0 (current work)

**Inbox**
- [x] GitHub sign-in: device flow + fine-grained PAT fallback (ADR 0004)
- [x] Cross-repo inbox via GraphQL search sweep; sections & facets: provenance (agent/human),
      repo/org, review-requested / my PRs / involved (ADR 0005, 0008)
- [x] Agent detection with bundled + user-extensible registry (ADR 0008)
- [x] CI check rollup, review decision, draft/mergeable badges on rows
- [x] `j`/`k` navigation, ⌘K command palette, saved filter views
- [x] macOS notifications: new review requests, checks failed on own PRs (polling, ADR 0005)
- [x] Morning digest (founder interview 2026-09-01): an opt-in daily summary of what came in since
      the last one — new review requests, green agent pull requests that only need an approval or a
      merge (the ADR 0015 preselect), your own pull requests with red CI or a change request
      (ADR 0016's "is this mine"), and reviews the outbox parked. Delivered as a macOS notification
      that opens the inbox and as a dismissible card above the list whose lines each jump to the
      right rail; it disappears by itself when the day rolls over. **Tier 1 only and no network at
      all** — it is generated unattended, so the digest path may not call GitHub and may not call an
      AI endpoint. No launch agent and no daemon either: the app evaluates a pure due rule once a
      minute while it is running, so a nine-o'clock digest missed because the Mac was asleep arrives
      when it wakes — once, and only on the same day. Off by default, with a time and a
      weekdays-only switch in Settings → Sync; the schedule travels in the encrypted settings
      document (ADR 0014) while "when this Mac last delivered one" deliberately stays put
- [x] Semantic ⌘K search (founder interview 2026-09-02, ADR 0019): ⌘K searches the pull requests
      in the inbox by what they are *about*, not by exact title words — a **Pull requests** section
      beside the commands, each row with repo#number, title, provenance chip, CI dot and a one-line
      "why it matched" (the label, the file path, the diff line). Ranked by a blend of BM25 over a
      per-pull-request search document (title, identity, labels, author, branch, description,
      changed-file paths and the *added* diff lines of anything you have opened, each against an
      explicit byte budget) and the cosine of Apple's **on-device** sentence embeddings, stored as
      `Float32` blobs in the local SQLite. An exact `owner/repo#123` or `#123` always wins; a query
      that matches nothing returns nothing. **Never an AI endpoint**, even when one is configured —
      search runs on every keystroke over every pull request, so it stays on this Mac, and the
      lexical half is a pure function in `ShepherdCore` that keeps working with no model at all.
      Indexed opportunistically from rows the sweep and the review screen already stored: no extra
      GitHub call anywhere. On by default, with the index size and a *Rebuild index* button in
      Settings → Intelligence; the switch travels in the encrypted settings document, the index
      does not
- [x] Menu-bar quick inbox (pulled into v1 from v1.x): a menu-bar item with the number of pull
      requests waiting for your review, and a small window with the top eight — repo#number,
      title, provenance chip, CI dot — where a click opens the pull request in the main window.
      Plus "Open Shepherd", "Sync now" and "n more…". Reads the same database observation the
      inbox does, has no sync of its own, and can be switched off in Settings → Appearance

**Review**
- [x] PR detail: description, timeline, commits, checks detail
- [ ] Linked issues on PR detail: closing references ("closes #123") shown with title/state,
      one keystroke to open; issue links in PR bodies/comments resolve to previews — **moved into
      the v1.1 issues block below**, where the issue model it needs is built once for everything
- [x] Monaco diff viewer: side-by-side & inline, syntax highlighting, dark/light (ADR 0003)
- [x] File list ordered by review priority with reasons; viewed-state tracking (ADR 0007 tier 1)
- [x] Pending review composer: inline comments (incl. multi-line), summary, verdict;
      drafts survive restart/offline; staleness check before submit (ADR 0006)
- [x] Threads: reply, resolve/unresolve
- [x] Merge: merge/squash/rebase, delete-branch option, mergeability preflight
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
      Still no auto-push and no auto-approve — the result waits in the Delegation Center marked as
      automatic. Merging is the one action a rule may now perform, under the much narrower
      conditions of ADR 0018 below
- [x] Opt-in auto-merge rules (ADR 0018): when an agent's pull request is green, **approved**, not
      a draft and mergeable, Shepherd queues the merge itself — through the ordinary outbox, with
      the head commit the decision was made on as the precondition, so a push in between parks it
      instead of merging something nobody judged. Off by default; the conditions are not
      checkboxes (only a repository allow-list and required labels can narrow them further), the
      merge method is the app's one remembered method, and each pull request is queued at most once
      per commit. Every merge is recorded in an audit log in Settings → Automation, announced once
      per pass as a notification, and reported as the additive `pr.auto_merge_queued` webhook
      event. Auto-approve stays a non-goal: this only ever records a decision a human already made
- [x] App Intents for Shortcuts and Siri (ADR 0021): *Open Pull Request* (with a `PullRequestEntity`
      you pick or search for through the on-device ⌘K ranker), *Show Inbox* with a filter,
      *Sync Now*, *Open Settings* on a tab, *Start Review Session*, and the one read-only action —
      *Get Pull Requests Needing Review*, which answers with the count and the list from the local
      database and makes no GitHub call. Four Siri phrases out of the box. Each intent builds a
      `DeepLink` and hands it to the same `AppEnvironment.open(_:)` a `shepherd://` URL goes
      through, so the cache lookup, the single-pull-request fetch and the queue-until-signed-in slot
      have one implementation. **No write intents**: nothing may approve, request changes, comment,
      merge or delegate from a surface with no review screen in front of the user, and that is a
      non-goal rather than a gap
- [x] Pull requests in Spotlight (ADR 0021): every row in the inbox becomes a `CSSearchableItem` —
      title, `owner/repo#123 · author · CI state`, labels plus the agent's name and the repository
      as keywords — and a ⌘Space result opens the review screen through the same
      `DeepLink.pullRequest` routing. **Metadata only**: no description, no diff, no review comment
      and no draft, enforced by the exported value type having nowhere to put one, because
      Spotlight's index is system-wide and outside the app's database. Driven by the same
      `onInboxRows` callback auto-merge and the search index use, diffed against what was last
      written so a sweep that changed nothing costs no framework call, batched and low priority;
      a pull request that leaves the inbox is deleted, and signing out or switching the toggle off
      deletes the whole domain. On by default, synced in the encrypted settings document

**Intelligence (ADR 0007)**
- [x] Tier 1 heuristics: file prioritization, risk hints — always on
- [x] Tier 2 on-device PR summaries via Foundation Models (availability-gated)
- [x] Tier 3 BYOK: whole-PR summary & review-focus hints — Anthropic, plus any
      OpenAI-compatible endpoint with one-click endpoint presets (Konduit (EU) — EU-hosted open
      models, with a link to the console for the key; Ollama on localhost; or a custom base URL),
      model discovery via `GET {base}/models` with the free-text model field as the fallback, and
      a connection test (ADR 0007 amendment)
- [x] AI-drafted review text (tier 2 or 3): a "draft with AI" button beside the review summary and
      beside every inline comment. The summary is drafted from the tier-1 digest plus the inline
      comments already in your pending review; a comment is drafted from the diff excerpt around
      the line you clicked. The draft is editable text in the field, labelled until you edit it,
      and it asks before replacing anything you typed. Auto-submitting stays a non-goal, below —
      prioritised in the founder interview of 2026-09-01 and pulled into v1 from v1.x
      (ADR 0007 amendment)
- [x] Apple Writing Tools in every composer (ADR 0020): proofread, rewrite and tone changes in the
      review summary, the inline comment composer, thread replies, saved replies and review
      templates, and the delegation task field — `.complete` where prose is written, `.limited` on
      one-line names and on the auto-delegation prompt template with its `{{…}}` placeholders, off
      on the repository pattern, and nothing in the Monaco webview (ADR 0003 stands). No setting: it
      is the system's own capability, and it complements the ✨ draft rather than competing with it —
      the draft lands as editable text, Writing Tools refines it, and neither can submit anything
- [x] On-device translation of pull-request text (ADR 0020): a *Translate* button on the description
      and on every review or thread comment puts the translation in a tinted block **below** the
      original — never replacing it — with a *Hide translation* toggle. Apple's Translation
      framework, `Locale.current.language` as the target, **never** a cloud endpoint even with a
      BYOK key configured (a fixed rule, not a preference); guarded by `LanguageAvailability` and
      `NLLanguageRecognizer`, so an unsupported pair is a disabled button with a reason and text
      already in your language gets no button at all. Cached in memory per screen, nothing
      persisted, nothing synced, and no new host — the language pack is macOS's own download

**Foundation**
- [x] Local-first SQLite cache + outbox (ADR 0006)
- [x] Dark/light theme system, Linear-inspired visual language
- [x] CI: ShepherdKit tests (macOS + Linux), web bundle build+tests, app build on macOS runner
- [x] German localisation (founder interview 2026-09-02): a String Catalog for every
      `String(localized:)` in the app and the CLI, German as the first added language, with the
      review vocabulary kept in English where GitHub's own UI keeps it (approve, request changes,
      merge, draft) so a bilingual team reads the same words in both places. Dates, counts and
      plurals through the catalog's plural rules, not string concatenation. Shipped as
      [ADR 0022](adr/0022-german-localisation.md): 859 entries in
      `Shepherd/Resources/Localizable.xcstrings`, plus `Scripts/check-localization.py` as a Linux
      CI gate, because a `String(localized:)` with no German row builds fine and silently shows
      English. The **CLI stayed English** — CONTRIBUTING.md's existing line, kept deliberately: its
      output is read by shell scripts and n8n nodes, and ADR 0013 leaves it a URL builder with no
      resource bundle
- [ ] First signed release: the maintainer's Developer ID certificate and Sparkle's `generate_keys`
      run once, then `Scripts/release.sh` (ADR 0010, [docs/RELEASING.md](RELEASING.md))

## v1.1 — issues inbox and agent assignment

The next big block, settled in the founder interview of 2026-09-02. Today Shepherd starts at the
pull request; the founder's day starts one step earlier, at the issue an agent should pick up. The
v1.1 theme is to move that first step into the app without turning Shepherd into an agent
orchestrator (non-goal, below): Shepherd *assigns* and *watches*, the agent still runs where it runs.

- [ ] Issues as a first-class inbox section (new ADR): a second sweep beside the pull-request one
      — issues assigned to you, issues you opened, issues mentioning you — in the same GraphQL
      search shape (ADR 0005), stored in the same local database with the same outbox for the
      writes below, and drawn as a section with its own facets: repository, label, age, and
      *has an agent pull request* / *has none*. Same `j`/`k`, same ⌘K search over title and body
      through the ADR 0019 ranker, same provenance chip where the author is an agent
- [ ] Issue ↔ pull request linking: GitHub's closing references (`closes #123`, the *Development*
      panel) resolved in both directions, so a pull request shows the issue it closes with title
      and state, and an issue shows the agent pull requests addressing it with their CI dot and
      review decision. This is where the parked *linked issues on PR detail* item lands
- [ ] Assign an issue to an agent: from the issue's row, start an ADR 0011 delegation whose task
      is the issue — title, body, labels and the repository, rendered through a template the way
      auto-delegation's `{{…}}` template works — in an isolated worktree with the same turn and
      budget caps, and record the assignment on the issue as a comment (through the outbox, so it
      is visible on GitHub and to teammates). Still no auto-push: the result waits in the
      Delegation Center; opening the pull request the agent made is the human's click. A
      **rule** that assigns unattended ("every issue with label `agent-ok`") is a separate, later
      opt-in under ADR 0016's shape — condition enum plus checkbox — not part of the first cut
- [ ] Issue triage writes: label, assign, close as completed / not planned, comment — each one
      outbox row, each with the same staleness precondition the review writes have (ADR 0006)
- [ ] Webhook events `issue.assigned_to_agent` and `issue.closed`, additive under `"v": 1`
      (ADR 0012), and `shepherd://issue/{owner}/{repo}/{number}` plus an `issues` inbox filter
      (ADR 0013, additive)
- [ ] Morning digest gains one line: issues assigned to you since the last digest, and agent
      pull requests that closed one (tier 1, no network — the rule of the digest stands)

## Intelligence v2 (ADR 0007 follow-ups)

What the 2026-09-02 interview kept from the Apple-intelligence brainstorm for *after* v1. Every
item is tier 2 (on-device) first; a tier-3 variant only where the rules of ADR 0007 already allow
that content to travel, and never for anything that runs unattended.

- [ ] "Why is CI red?" — Foundation Models **tool calling** on the review screen: the model gets
      three read-only tools (the failing check runs, the tail of a job log, the diff of one file)
      and answers with the failing test, the line it points at, and a one-line hypothesis, each
      hop shown as a step the reviewer can expand. Read-only by construction: the tools are
      `GitHubKit` reads, there is no tool that writes, and the answer is text in a card, not an
      action. Fits ADR 0011 too — the same summary makes a good delegation task
- [ ] Structured triage classification — a `@Generable` verdict per pull request (kind:
      feature / fix / chore / dependency bump; risk: low / medium / high, with the one-sentence
      reason) computed on-device from the ADR 0019 search document, stored beside the vector, and
      exposed as an inbox facet and a ⌘K filter. Never sent anywhere, never decides anything:
      it sorts, it does not approve (non-goal). The on-device model is the ceiling here — when it
      is unavailable the facet is simply absent, there is no cloud fallback for a bulk pass
- [ ] Streaming drafts — the ✨ draft (ADR 0007 amendment) arrives token by token in the composer
      instead of after a spinner, through `LanguageModelSession.streamResponse` for tier 2 and the
      SSE variants of the tier-3 providers; still labelled until edited, still asks before
      replacing anything typed
- [ ] Saved-reply suggestion — when the reviewer starts a comment, the two saved replies whose
      embedding (ADR 0019's on-device model, cached per snippet) is nearest to the thread's text are
      offered in the `text.badge.plus` menu first. No new model, no new setting, and nothing
      inserted uninvited
- Considered and rejected in the same interview, recorded so it is not proposed again: Image
  Playground / Genmoji (no image surface in a review tool), speech input (`SpeechAnalyzer` — a
  review is read, not dictated), a sentiment check on outgoing comments (tone is the reviewer's
  call; Writing Tools already offers a rewrite when asked), and an AI-written morning digest (the
  digest runs unattended and its lines are deterministic on purpose, see v1.x below)

## v1.x

- Authorization Code + PKCE loopback sign-in (nicer than device flow)
- ~~Bulk triage actions (approve/merge a selected set of green agent PRs, one confirm)~~ —
  pulled into v1, see above (ADR 0015)
- ~~Draft AI-assisted review comments~~ (explicit founder wish) — pulled into v1, see above
  (ADR 0007 amendment). Still open on top of it: commit and pull-request *message* suggestions,
  which are a different surface (the delegation result, not the review composer)
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
- A one-sentence on-device summary on top of the morning digest's deterministic lines (ADR 0007
  tier 2). Deliberately left out of v1: the digest runs unattended, so it may only ever use the
  on-device tier — a cloud call while nobody is watching is out of the question — and the
  `IntelligenceProvider` protocol has no digest-shaped request yet. Adding one means a method every
  provider implements, including the two cloud ones, which is precisely the shape of change that
  could route an unattended request to an endpoint. The deterministic lines are the feature; the
  sentence is decoration, and it can wait for a tier-2-only entry point
- More webhook events (thread replies, resolves, checks turning red) — additive under `"v": 1`
  (ADR 0012)
- More auto-delegation conditions (ADR 0016 keeps the action fixed: a third *condition* is a case
  in one enum plus a checkbox; a third *action* needs a new ADR). A shared, synced ledger so two
  Macs cannot both start a run for the same pull request is the open question there — and it is the
  same open question for auto-merge (ADR 0018), where a second Mac's duplicate merge is refused by
  GitHub rather than duplicating work
- More auto-merge *narrowings* — "only pull requests I approved myself" is the obvious one, and it
  is parked because `PullRequestSummary` carries GitHub's aggregate review decision rather than the
  list of approvers, so it would mean a new call on the unattended path (ADR 0018). Anything that
  would *widen* the rule instead of narrowing it is a new ADR, not a checkbox
- `shepherd://inbox?q=…` and `shepherd inbox --search "…"` (ADR 0019 left them out deliberately):
  a query parameter is not an additive URL change — `DeepLink.inbox(filter:)` would gain a payload,
  touching the grammar, the round trip, the CLI's argument grammar and the README's URL table — for
  a feature whose value is interactive ranking as you type. The CLI half has ADR 0013's other
  problem too: it cannot show results
- `NLContextualEmbedding` instead of the sentence embedding (ADR 0019): stronger on long documents,
  but its models are downloadable *assets*, and a search box that quietly starts a multi-megabyte
  download is not something Shepherd may do. It costs one new model identifier, which invalidates
  the index by itself
- German Siri phrases: an `AppShortcuts.xcstrings` beside the catalog ADR 0022 introduced, so
  "Öffne die Review-Warteschlange in Shepherd" works as well as the English phrase does today
- More `shepherd://` commands (additive by design, ADR 0013). Anything that must *return* data
  (`shepherd status`, "how many need my review?") is not a URL-scheme feature and needs the XPC
  or AppleScript decision ADR 0013 deferred
- ~~Issues as a first-class inbox section~~ — promoted to the v1.1 block above, together with
  linking and "assign an issue to an agent"
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
  a local delegation on your own machine, ADR 0016, but nothing is hosted), auto-submitting
  AI-generated reviews (AI output is always a suggestion a human confirms), and **auto-approving
  anything**. The one write a rule may perform unattended is the merge of a pull request a human
  has already approved (ADR 0018) — Shepherd never forms a verdict by itself.
