# ADR 0043: The conversation tab — GitHub's timeline, read in full and answered in place

Status: Accepted · Date: 2026-10-16

## Context

The review screen's second tab is called *Conversation*, and until now it did not show the
conversation. It showed the description, an *Activity* card of at most twelve one-liners built from
commits and review verdicts (never a comment body — `ResponseMapping.timeline` reads no
comments), a *Commits* card, the checks, and the review threads that cannot be drawn on the current
diff. A pull request's general discussion — the issue comments under it, which is what people mean
when they say "the conversation" — was not fetched at all, and neither were the texts of reviews.
Answering meant the *Comment…* sheet, written blind.

Christian asked for the whole conversation in that tab, and for it to work "like on GitHub":
comment, reply, react, edit and delete, with the events between the comments. That is three
pieces of work, shipped in three steps:

- **A** — the timeline itself and a composer at the bottom of it (1.12.0);
- **B** — reactions (1.13.0);
- **C** — editing and deleting your own comments (1.14.0).

This ADR records the decisions for all three, so B and C build on a model A already fetches and
stores.

## Decision

### One more GraphQL read on the detail fetch, tolerated like the closing issues

`GraphQLDocuments.pullRequestConversation` reads `timelineItems` with an explicit `itemTypes` list:
issue comments, reviews, and twenty kinds of event (labels added and removed, assignments, review
requests and their removal, title changes, ready for review / back to draft, merged, closed,
reopened, head branch deleted and restored, base branch changed, force-pushes, cross-references,
dismissed reviews, auto-merge switched on and off). Beside them it reads the pull request's own
`reactionGroups`, `viewerCanUpdate`, `viewerCanReact` and `lastEditedAt`, which are the
description's.

- **Measured, not assumed:** `rateLimit { cost }` reports **1 point** for the query with every
  reaction group on every item, on a 20-item cli/cli pull request as on a 3-item Shepherd one
  (2026-10-16). It therefore runs where every other detail read runs — in
  `GitHubClient.pullRequestDetail(repo:number:)`, for a pull request whose `updatedAt` moved — and a
  comment a colleague writes reaches an open review screen the way a new check does, through
  `ReviewModel.change → .refresh`.
- **Newest first:** the connection is read backwards (`last: 100, before:`), at most five pages.
  A pull request with more than 500 timeline items loses its *oldest* ones, and the tab says
  "Earlier activity is on GitHub" with a link, rather than losing the newest, which are the ones a
  reviewer is there to read.
- **Tolerated:** like `closingIssuesReferences` (ADR 0032), a failure of this one read does not
  fail the detail. The detail then carries `conversation == nil`, which the store reads as
  "unknown" and does not write through: the conversation the database already holds stays on
  screen. A transient error must not empty a chat. One refinement: an answer that carries both
  `data` and `errors` — one node GitHub would not resolve for this token, a cross-reference behind
  SAML enforcement — is kept, and the nodes GitHub nulled are dropped, because refusing the whole
  read for one of them would leave that pull request's tab empty on every fetch. A rate limit still
  fails the read, and so does a page whose items came back `null`: that is a page lost, not a node.
- **GitHub already hides reply-only reviews.** A reply typed under an existing thread is, in
  GitHub's model, a review of its own with one comment and no body; `timelineItems` leaves those out
  (verified against cli/cli#14569: sixteen reviews, two in the timeline). Shepherd does the same
  and needs no rule of its own for it.

### Threads hang under the review that started them

The existing `reviewThreads` document gains, per comment, `pullRequestReview { id }`,
`reactionGroups`, `viewerCanUpdate`, `viewerCanDelete`, `lastEditedAt` and `url`. A thread is
drawn under the review its *first* comment belongs to, exactly where GitHub draws it; a thread whose
review is not in the timeline (a page that was cut, a pending review of the viewer's) is drawn on
its own at the time of its first comment. The stream therefore replaces both the *Activity* card and
*Conversations not on the current diff* — every thread is in it, with its *outdated* and *resolved*
chips, and resolved or outdated ones start collapsed, as on GitHub.
GitHub also records a `ClosedEvent` with every merge, by the same person, within a second of the
`MergedEvent`; its own page draws only the merge, so the stream drops a close at or after a merge
(a merged pull request cannot be reopened, so an earlier close and reopen still show).

`diffHunk` is **not** fetched. GitHub sends the whole hunk, and hunks of 500 lines are ordinary
(cli/cli#14569). A thread shows its `path:line` (or "was line N") and a **Show in diff** button
instead, through the `ReviewModel.reveal(path:line:)` every `file:line` link already uses.

### The model lives in ShepherdCore and holds no words

`PullRequestConversation` holds the description's reactions and flags, the items oldest first, and
whether the oldest were cut. An item is a comment, a review or an event; an event is an enum with
associated values (a label's name, a title's old and new spelling, a branch name, a referenced pull
request) — every sentence is the app's, through `String(localized:)`, because ShepherdKit has no
user-visible strings (CONTRIBUTING). Commits are not fetched a second time: the REST list the
detail fetch already reads is placed into the stream by date, consecutive commits as one group.

Persistence is migration **v11**: a table of its own, `pull_request_conversations` (one JSON
document per pull request, keyed by `prID` and cascading with it, like
`pull_request_closing_issues`), rather than a column on `pull_requests` — the inbox query reads
every `pull_requests` row in full on every observation, and every pull request's comment bodies
have no business riding along with it. A sweep never touches that table, so its
upsert of the inbox row cannot wipe a conversation, and a detail whose conversation is `nil` leaves
the stored one alone. On `review_comments` v11 adds the columns `reviewID`, `reactionsJSON`,
`viewerCanUpdate`, `viewerCanDelete`, `isEdited` and `url`. The condensed `timeline` is left
exactly as it is: ADR 0028's retroactive baseline reads it.

Reactions and the viewer's permissions are fetched and stored from A onwards, so B and C add
buttons and outbox actions and no migration. In A they are shown, not offered.

### The tab, top to bottom

The intelligence cards stay where they are (claims vs. evidence, the recurring finding, the issues
it closes, the stack), because they are read before the discussion. Then the description, drawn as
the first post — author, time, *edited*, reactions. Then the stream. Then the checks, which is
where GitHub has them, beside its merge box. Then a composer: *Post comment* (⌘⏎ while the field
has the keyboard — everywhere else ⌘⏎ stays the toolbar's *Review*) and *Comment and close* /
*Close without a comment*, with saved replies and ⌘V image paste — the same field and the
same two writes as the *Comment…* sheet (ADR 0005's 2026-09-14 amendment), no new action.
*Quote reply* on any post puts the post, quoted, into that composer. A half-written reply in a thread, and which
threads the reviewer folded or unfolded, live in the review screen's model rather than in the
cards, so a trip to *Files* — *Show in diff* is one — does not lose them; resolving a thread folds
it, reopening it unfolds it. The *Commits* card goes: its
rows, trailers included, are the stream's commit groups.

A thread in the stream uses the same reply bar as the thread popover in the diff — one view, not a
third copy — with *Reply*, *Resolve*/*Unresolve*, *Delegate…* and the saved replies. Once a
comment, a reply, a thread's resolution or a review has **reached** GitHub, Shepherd re-reads that
pull request once, a second later and coalesced per pull request, so it appears without waiting
for the next sweep — whichever surface wrote it (this tab, the diff's popover, a write the outbox
sent later). The open screen takes the stored detail through its own observation. A write that is
only queued is said by the toast, as before.

### Bot bodies

Agent and bot comments are written in GitHub's HTML-flavoured Markdown: `<!-- markers -->`,
`<details><summary>`, `<br>`. `MarkdownDocument` rendered those as literal text. A narrow pre-pass
drops HTML comments and turns `<br>` into a line break — both only outside backtick code spans, so a
review that *discusses* `<br>` reads verbatim — and unwraps `<details>` and turns `<summary>` into a
bold line only where the tag is the whole line, which is how bots write them; every other tag is
left as it is written. The parser also splits lines on any line break, so a comment typed on
github.com (CRLF) no longer renders every line as a paragraph of its own. A comment GitHub reports as minimized (hidden as
off-topic, outdated, spam …) starts collapsed behind one line.

### B: reactions are the second GraphQL write

`addReaction` and `removeReaction` by subject node id, as an exception to ADR 0005's REST writes
beside thread resolution: REST has no reaction endpoint for a pull-request *review* at all, and
removing a reaction through REST needs the reaction's own id, which would mean a read before every
removal. One outbox action, `react(subjectID:content:adding:)`. What the bar shows is GitHub's
state plus the reviewer's own clicks, so a click is visible at once and an offline click stays
visible until it is sent. A click that undoes one still waiting in the outbox cancels that row,
because a row in a retry's backoff could otherwise be sent after the click that undid it and leave
the reaction the reviewer took back — and queues its own row all the same: the stored detail lags
every row in flight or landed, so nothing on the Mac can tell that the click's row is unneeded, and
a redundant one costs one idempotent mutation. The click's row is on disk without waiting for any
drain: a click the bar shows never waits for the network to be saved. A refusal the click's own
drain sees takes the click back off the bar; one that a later drain meets shows in Settings → Sync,
and the bar corrects itself when the screen is reopened.

### C: edits and deletes are REST, gated by GitHub's own flags

`PATCH …/issues/comments/{id}`, `PATCH …/pulls/comments/{id}`, `PUT …/pulls/{n}/reviews/{id}`
(a submitted review can be edited, never deleted) and `PATCH …/pulls/{n}` for the description;
`DELETE` on the two comment kinds. Offered only where GitHub's `viewerCanUpdate` /
`viewerCanDelete` say so, and a delete asks first. A delete that comes back `404` was sent before —
a crash between GitHub deleting and the row being marked — and is completed, the way a merge
answered `405` on a merged pull request is (ADR 0005's 2026-09-05 amendment).

## Consequences

- No new host. The read is one more GraphQL query on `api.github.com` per changed pull request,
  costing one point; B adds two GraphQL mutations and C five REST calls on the same host with the
  same token, each an ordinary outbox row.
- Comment bodies stay out of webhooks (ADR 0012) and telemetry (ADR 0036): no new event, no new
  payload field.
- The conversation is stored locally like every other part of a detail, so the tab reads offline
  and is erased with everything else on sign-out.
- The *Comment…* sheet stays for the inbox panel, which has no room for a timeline.
- The GitHub App's permissions for B's and C's writes cannot be checked from a `gh` token; they are
  checked with the app's own token in `schnaq/shepherd-playground`. As with ⌘V image upload (1.11.0)
  the check follows the release rather than gating it, because a refusal is harmless: the click is
  taken back with a toast, and the failed row says GitHub's own words in Settings → Sync.
