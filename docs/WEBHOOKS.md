# Outbound webhooks

Shepherd can POST a JSON event to one URL you configure — an [n8n](https://n8n.io) Webhook
node, a Zapier catch-hook, a small script, anything that accepts a JSON body. This is the
**outbound** half only: Shepherd never listens on a port and never registers a GitHub webhook.
The reasoning is in [ADR 0012](adr/0012-outbound-webhooks.md), and the *inbound* exclusion it
inherits is in [ADR 0005](adr/0005-api-strategy-graphql-search-rest-writes.md).

Setup: **Settings → Automation**. Paste a URL, tick the events you want, switch it on, press
*Send test event*.

## Guarantees, and non-guarantees

- **Events fire when the action actually succeeded**, not when you pressed the key. Shepherd's
  writes go through a persisted outbox ([ADR 0006](adr/0006-local-first-sqlite-grdb.md)); a
  queued approval that is still waiting out a retry has approved nothing, and no event is sent
  for it. `review.submitted` and `pr.merged` come from the outbox drain. That also means a bulk
  triage run ([ADR 0015](adr/0015-bulk-triage.md)) delivers one event per pull request, as each
  row lands, rather than one event for the batch.
- **Delivery is best-effort.** Two attempts, two seconds apart, ten-second timeout, then
  Shepherd gives up quietly and shows one line in Settings. A failing webhook never interrupts
  a review, a merge or a sync, and never produces an alert.
- **Retries reuse the same body and the same `id`**, so a receiver can de-duplicate.
- **Nothing goes anywhere but your URL.** No telemetry, no vendor endpoint. `https` to any
  host; `http` only for `localhost` / `127.0.0.1` / `host.docker.internal`.
- **The payload says what happened, never what was written.** No review text, no comment
  bodies, no diffs, no agent output. Follow the `url` when you want the substance.

## Request

```
POST <your URL>
content-type: application/json
user-agent: Shepherd
X-Shepherd-Event: review.submitted
X-Shepherd-Delivery: 0f7ac1de-0000-4000-8000-00000000002a
X-Shepherd-Signature: sha256=<hex>          # only when a secret is configured
```

The two `X-Shepherd-*` routing headers mirror `event` and `id` from the body, so a receiver can
route without parsing JSON.

### Signature

Set a **signing secret** in Settings → Automation (it is stored in your Keychain and nowhere
else) and every request carries:

```
X-Shepherd-Signature: sha256=<lowercase hex HMAC-SHA256(raw request body, secret)>
```

This is deliberately the same shape as GitHub's `X-Hub-Signature-256`, so any verification step
you already have for GitHub webhooks works unchanged. Compute the HMAC over the **raw body
bytes**, before any JSON parsing or re-serialisation.

## Envelope

Every event has the same envelope. `v` is bumped only by a change a receiver cannot ignore;
new events and new `details` keys are additive and stay at `v: 1`. Every key is always
present — a value that does not apply is `null`, never omitted. Key *order* is alphabetical as
an artefact of canonical encoding; JSON objects are unordered, so do not depend on it.

```json
{
  "v": 1,
  "event": "review.submitted",
  "id": "0f7ac1de-0000-4000-8000-00000000002a",
  "occurredAt": "2026-08-31T07:40:00Z",
  "source": "shepherd",
  "pullRequest": {
    "owner": "schnaq",
    "repo": "review",
    "number": 42,
    "nodeId": "PR_kwDOexample",
    "title": "Fix the login flow",
    "url": "https://github.com/schnaq/review/pull/42",
    "author": "claude[bot]",
    "authorKind": "agent",
    "isAgentAuthored": true,
    "agentId": "claude-code",
    "branch": "claude/fix-login",
    "baseBranch": "main",
    "headSha": "abc123def456",
    "isDraft": false,
    "additions": 120,
    "deletions": 8,
    "changedFiles": 5,
    "labels": ["bug", "agent"]
  },
  "details": { "verdict": "approve", "inlineCommentCount": 2 }
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `v` | int | Envelope version. `1`. |
| `event` | string | One of the event names below. |
| `id` | string | UUID, stable across this event's retries — the idempotency key. |
| `occurredAt` | string | ISO-8601 UTC, second precision. When it *happened*, not when the POST was attempted. |
| `source` | string | Always `"shepherd"`. |
| `pullRequest.authorKind` | string | `"human"`, `"bot"`, `"agent"`, or `"unknown"` (see below). |
| `pullRequest.isAgentAuthored` | bool | True only for a recognised coding agent ([ADR 0008](adr/0008-agent-provenance-first-class.md)). |
| `pullRequest.agentId` | string \| null | Registry id, e.g. `"claude-code"`. `null` for humans and plain bots. |
| `pullRequest.nodeId` | string | GitHub GraphQL node id — Shepherd's primary key. |

`authorKind: "unknown"` with empty strings happens in one narrow case: a merge that succeeds
just after the inbox sweep pruned the row, leaving nothing to describe it with. The shape does
not change — only `owner`, `repo`, `number`, `nodeId` and `url` are populated.

## Events

### `review.submitted`

A review reached GitHub.

```json
{ "verdict": "approve", "inlineCommentCount": 2 }
```

| Key | Values |
| --- | --- |
| `verdict` | `"approve"` · `"request_changes"` · `"comment"` · `"pending"` (parked as a GitHub pending review) |
| `inlineCommentCount` | int — how many inline comments went with it. Their text is not sent. |

### `pr.merged`

A merge reached GitHub. **Fires only for merges Shepherd performed** — the inbox sweep sees
that a pull request left the open set but cannot tell a merge from a close, so that signal is
not used here.

```json
{ "mergeMethod": "squash" }
```

`mergeMethod` is `"merge"`, `"squash"` or `"rebase"`.

### `delegation.finished`

A local-agent run ended ([ADR 0011](adr/0011-delegate-to-local-agent-cli.md)).

```json
{
  "status": "finished",
  "agent": "Claude Code",
  "durationSeconds": 72,
  "changedFileCount": 3,
  "message": null,
  "automatic": false
}
```

| Key | Values |
| --- | --- |
| `status` | `"finished"` (ran to completion, no error) · `"failed"` (the agent errored, or Shepherd could not run it) · `"cancelled"` (you stopped it) |
| `agent` | The configured CLI's display name. |
| `durationSeconds` | int. |
| `changedFileCount` | Files left changed in the worktree. Shepherd never pushes them for you. |
| `message` | string \| null — a short reason: Shepherd's own error, or the CLI's result subtype such as `"error_max_turns"`. **Never** the agent's output. |
| `automatic` | bool — `true` when an auto-delegation rule started the run rather than you ([ADR 0016](adr/0016-auto-delegation-rules.md)). Added later and additive under `"v": 1`: always present, `false` for a run you started. |

### `inbox.new_review_request`

A sweep found a pull request waiting for your review. Fires once per pull request.

```json
{
  "relations": ["mentioned", "reviewRequested"],
  "reviewDecision": "reviewRequired",
  "checks": "success"
}
```

| Key | Values |
| --- | --- |
| `relations` | Sorted subset of `reviewRequested`, `author`, `mentioned`, `assigned`. |
| `reviewDecision` | `"approved"` · `"changesRequested"` · `"reviewRequired"` · `null` |
| `checks` | `"success"` · `"failure"` · `"pending"` · `"none"` · `null` (no checks reported) |

### `shepherd.test`

Sent only by the *Send test event* button, so you can wire a workflow up before any real event
happens. The `pullRequest` object is fictional (`octocat/hello-world#1`) and `details` is
`{ "note": "…fictional." }`. This event is never delivered on its own and cannot be subscribed
to.

## n8n in three minutes

1. New workflow → add a **Webhook** node. Method `POST`, path e.g. `shepherd`. Copy its
   **Production URL** (`https://n8n.example.com/webhook/shepherd`).
2. In Shepherd: **Settings → Automation** → paste the URL → tick the events → switch
   *Send events to a webhook* on.
3. Press **Send test event**. The Webhook node's "Listen for test event" catches it and n8n
   shows you the payload, so the rest of the workflow can be built against real data.
4. Route on the event name with a **Switch** node on `{{ $json.event }}` — or, without touching
   the body, on the `X-Shepherd-Event` header.

A Slack message for approvals of agent-authored pull requests, as an example expression:

```
{{ $json.pullRequest.isAgentAuthored && $json.details.verdict === "approve"
   ? `✅ ${$json.pullRequest.author} · ${$json.pullRequest.owner}/${$json.pullRequest.repo}#${$json.pullRequest.number} — ${$json.pullRequest.title}\n${$json.pullRequest.url}`
   : null }}
```

If you set a signing secret, add a **Crypto** node (HMAC, SHA256, secret, hex) over the raw
body and compare with `X-Shepherd-Signature` minus its `sha256=` prefix. n8n's Webhook node
must be set to keep the raw body for this — the HMAC is over the exact bytes Shepherd sent, and
a re-serialised JSON object will not match.

Self-hosted n8n on the same Mac works with `http://localhost:5678/webhook/shepherd`; in Docker,
use `http://host.docker.internal:5678/…` if n8n reaches Shepherd's host that way. Any other
host must be `https`.

## The other direction

Webhooks are Shepherd talking to your automation. For your automation talking to Shepherd there
is the `shepherd://` URL scheme and the `shepherd` CLI
([ADR 0013](adr/0013-url-scheme-and-cli.md)): an n8n **Execute Command** node running
`shepherd open owner/repo#123` puts that pull request on the reviewer's review screen, and
`shepherd sync` triggers a sweep. That closes the loop — GitHub → n8n → Shepherd → webhook →
n8n — without Shepherd ever listening on a port. The node has to run on the same Mac as
Shepherd (a URL scheme is local by nature), so this is for a locally installed n8n, not a
server-side one.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| *Refusing to send to … over plain HTTP* | `http` is only allowed for this machine. Use `https`. |
| *The webhook answered 404* | Wrong path, or an n8n workflow that is not active (test URLs only work while the node is listening). Not retried — a 404 will not fix itself in two seconds. |
| *The webhook answered 500* | Retried once, then reported. Look at the receiver. |
| Nothing arrives, no status line | The event is not ticked, or the toggle is off. A gated event is never an attempt. |
| Signature never matches | The HMAC must be over the raw body bytes, and the secret must be byte-identical. |
| No `pr.merged` for a pull request somebody else merged | By design; see above. |
