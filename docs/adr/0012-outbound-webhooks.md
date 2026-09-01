# ADR 0012: Outbound webhooks — Shepherd posts events, it never receives them

Status: Accepted (v1.x scope) · Date: 2026-09-01

## Context

Shepherd is where the review happens; it is not where the *rest* of the team's automation
happens. The concrete wishes are all one-directional: post approvals into a Slack channel,
append merges to a spreadsheet, open a ticket when a delegation fails, ping a stand-up bot when
a review request has been waiting too long. Every one of those is a two-node n8n workflow the
moment something POSTs it a JSON body — and n8n (self-hosted, often on the same machine or the
same LAN as Shepherd) is the tool this user base already runs.

ADR 0005 rules out webhooks in the *inbound* direction and gives the reason: local-first, no
server. That reason is intact. A GitHub webhook needs a publicly reachable HTTPS endpoint, which
means either a hosted component Shepherd does not have or a tunnel the user must maintain — and
it would make the sync engine's two polling loops a second, redundant source of truth.

Nothing in that argument applies to the outbound direction. Posting is a client operation: it
needs no listener, no port, no address, no uptime. The asymmetry is the decision.

There is also a hook-point question, and it is the substantive one. Shepherd's writes go through
a persisted outbox (ADR 0006): pressing `r a` *queues* an approval, and the approval reaches
GitHub some time later — possibly after a retry, possibly never (a moved head parks the row as
conflicted). An event fired at the key press would routinely lie.

## Decision

- **Outbound only.** Shepherd gains one configurable webhook URL and POSTs a versioned JSON
  event to it. It never listens on a port, never registers a GitHub webhook, and has no inbound
  half — ADR 0005's exclusion stands, restated as a boundary rather than relaxed.
- **Events fire on success, not on intent.** `review.submitted` and `pr.merged` are emitted by
  the **outbox drain**, from a new `SyncEvent.mutationSent` that the engine yields after the row
  is recorded as sent. `delegation.finished` is emitted from `DelegationModel`'s terminal state,
  once per run. `inbox.new_review_request` reuses the sweep's existing once-per-pull-request
  discovery. `SyncEvent.prMerged` is deliberately *not* mapped: a sweep of open pull requests
  cannot distinguish a merge from a close, so `pr.merged` fires only for merges Shepherd
  performed.
- **Off by default, one destination, nothing else.** No telemetry, no vendor endpoint, no
  discovery. The only outbound target is the URL the user typed, and only while the enable
  toggle is on. `https` anywhere; `http` only for this machine.
- **The payload describes what happened, not what was written.** Repository, number, title,
  URL, author with provenance, size, and a small per-event `details` object. No review text, no
  comment bodies, no diffs, no agent output. Versioned envelope (`"v": 1`), every key always
  present, absent values as explicit `null`. Schema and an n8n recipe: [docs/WEBHOOKS.md](../WEBHOOKS.md).
- **Optional HMAC.** With a shared secret configured (Keychain only, ADR 0004's rule), every
  request carries `X-Shepherd-Signature: sha256=<HMAC-SHA256 of the body>` — GitHub's
  `X-Hub-Signature-256` shape, so an existing verification step works unchanged.
- **A webhook can never break Shepherd.** Fire-and-forget from a detached task; two attempts
  with one short backoff, and only for failures a retry could fix; a ten-second timeout; every
  failure swallowed into a single status line in Settings. Nothing toasts, nothing alerts,
  nothing blocks a review, a merge or a sweep.
- **Placement.** Payload, signing, transport and mapping live in the **app target**
  (`Shepherd/Automation/`), not in ShepherdKit: the signature uses CryptoKit, which does not
  exist on Linux, and `Packages/ShepherdKit` must keep building and testing there
  (`docs/ARCHITECTURE.md`). ShepherdKit's only contribution is the `mutationSent` event — a
  value type, no networking — which is what makes the honest hook point available at all.

## Consequences

- Shepherd becomes scriptable without becoming a server. The user's automation runs in the
  user's own n8n, on the user's own machine if they like, with the user's own credentials.
- Delivery is best-effort **by design**. The outbox guarantees delivery to GitHub; it does not
  guarantee delivery to a third party, and a durable webhook queue would be a second outbox for
  a much smaller prize. A webhook that missed an event is a missed notification, not lost work.
- `SyncEvent` gained a case, so every exhaustive switch over it had to be revisited — a cheap,
  compiler-enforced cost that is worth it: "the mutation actually reached GitHub" was previously
  a fact the app layer could not observe at all.
- The privacy line moves by exactly one host, and only when the user names it. CONTRIBUTING.md's
  network-targets rule now reads: api.github.com / github.com, the AI endpoint the user
  configured, and the webhook URL the user configured.
- Adding a fifth event is a case in one enum plus a mapping arm, and stays additive under
  `"v": 1`. A payload that would carry review text, diff content or agent output is *not*
  additive and needs its own decision.
