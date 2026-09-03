# ADR 0024: Tool calling for "why is CI red?" — three reads, one card, one explicit click to the cloud

Status: Accepted · Date: 2026-09-03

## Context

A red check is the most common reason a reviewer stops reading a pull request and starts reading a
log. The log is on GitHub, behind two clicks and a scroll, and the answer in it is usually one
line: a test name, a file, a line number. Shepherd already has everything around that line — the
check runs, the diff, the delegation loop that could fix it — and until now nothing that could
read the log.

This is also the first feature where **the model decides what to read**. Every AI surface before
it was one prompt built by a tier-1 digest a human could see the shape of
([ADR 0007](0007-layered-intelligence.md) and its amendments): a summary, a draft, an explanation
of the lines the reviewer picked. A diagnosis cannot work that way — which log matters depends on
which check is red, and which file matters depends on what the log says — so the model has to be
able to ask. The groundwork for that (`docs/plans/apple-intelligence-v2.md` §0.3: the tool
contract, the trace, the twins, the loop in all three providers) landed before this decision; what
is decided here is the feature built on it, the one GitHub read it needs, and the one rule about
where a log may travel.

Verified facts this rests on:

- `GET /repos/{owner}/{repo}/actions/jobs/{id}/logs` answers `302` with a `Location` pointing at a
  short-lived blob on GitHub's own storage host, which carries its own signature in the query
  string. The job id is not on a check run; it is inside the check's `detailsURL`
  (`/actions/runs/{run}/job/{job}`), and checks from other CI systems point somewhere else
  entirely.
- Apple's on-device model has an 8,192-token window shared between prompt and answer. A single
  `xcodebuild` log is routinely a megabyte. The reduction is therefore not an optimisation; it is
  the feature's precondition.

## Decision

**A red check gets a *Why?* button. The answer is a card under the checks list, and the card shows
its work.**

### 1. Three read tools, fixed at compile time

`IntelligenceToolName` has exactly three cases — `failingChecks`, `jobLogTail`, `fileDiff` — and
that is the guardrail, expressed as a type rather than as a policy: a tool cannot be registered at
runtime, assembled from a string, or be anything but a read. `IntelligenceToolRegistry.validate`
refuses a call with an unknown tool, a missing or invented argument, or — the rule with the sharpest
edge — a `fileDiff` path that is not one of this pull request's own changed files, so **no free
text a model wrote reaches GitHub**. A refused call comes back as a *result* the model reads and
can correct, never as an error that ends the turn, and the hop cap
(`IntelligenceToolLoop.maximumHops` = 6) is a hard stop rather than a sentence in the prompt.

Adding a fourth tool is a case in that enum, a descriptor, a concrete implementation, an amendment
here — in that order. There is no tool that writes, and there is no method on the tool contract
that returns anything the outbox could consume.

### 2. The log is reduced on this Mac before any model sees it

`LogDigest` (pure, `ShepherdCore`, Linux-tested against the four real log tails in
`Tests/Fixtures/eval/ci-*.json`) keeps the lines that name a failure with three lines of context
that carry something on either side, drops repeats and blank lines, strips ANSI escapes and
Actions' per-line timestamps, and caps the result at a fifth of the answering tier's characters —
which on the on-device tier is ~1,200 tokens. Over budget it gives up the *front*, because a build
that failed twice usually failed last for the reason worth reading.

The download itself is capped at 2 MB and refused beyond that
(`GitHubError.responseTooLarge`) rather than silently truncated: the *end* of a log is where the
failure summary lives, so a digest of the first two megabytes of a ten-megabyte log would be a
confident answer about the wrong part of the run. A check that is not a GitHub Actions job — a
Buildkite or CircleCI check, or an app's own check run — has no readable log, and the tool says so
in words the model can act on rather than failing; the same is true of a log that could not be
fetched or came back empty. That is permanent behaviour for part of the input, not a gap.

### 3. Log content travels to a cloud tier only after an explicit click

The ladder for this call runs the *opposite way* to every other call in `IntelligenceRouter`: tier
2 first, and tier 3 only when tier 2 could not answer for one of exactly two reasons — the content
**did not fit** (`IntelligenceError.contextExceeded` / `digestTooLarge`), or the on-device model is
**not available on this Mac at all** — **and** the reviewer pressed the card's one button, which is
only drawn when a key is configured. Any other tier-2 failure is reported as it happened: a cloud
provider is not a retry.

The second reason is not a budget failure and does not pretend to be one; it is the same *offer*
with the other sentence in front of it. A Mac with Apple Intelligence switched off and a key
configured gets the *Why?* button, and the card says the on-device model is unavailable and asks
*"…Ask <provider> instead?"* — the log reaches the endpoint on that click and not before, which is
this section's rule unchanged. A Mac with **neither** tier gets no button: `canDiagnose`
(on-device available *or* a cloud tier), not `canDraft`, is what the checks list asks, because
`canDraft` is satisfied by a key alone and this ladder starts on-device — a *Why?* button that was
drawn from a key and then refused by the tier below it was a promise the feature could not keep.
`preferCloud` defaults to `false`, so no caller can send a log to a configured endpoint by leaving
an argument out.

CI log output is a **new kind of content for the cloud path**, so it is stated where the privacy
contract lives: `CONTRIBUTING.md`'s host list now says that the reduced log tail reaches the
configured provider, and only after that click. No new host: the blob the redirect points at is
GitHub's own storage, part of the same `api.github.com` read.

### 4. The answer is a card, and the card shows what the model saw

`CIDiagnosisCard` renders the twin `CIDiagnosis` — failing test, file, line, one-line hypothesis,
confidence — omitting every field the log did not name rather than inventing one, with the tier
named on it (*Diagnosed on-device*) because that is the answer to "did my log leave this Mac?".
The `file:line` is a link into the diff viewer when the file is in the diff and plain text when it
is not — CI fails in files a pull request never touched, and that is exactly when a diagnosis is
most useful.

`IntelligenceTrace` is rendered as expandable steps, and each step now carries the tool's
**budgeted result content**, so an expanded step shows exactly what the model was given rather than
a summary of it. A hypothesis with a confidence label on it is a guess; a hypothesis with *"last 42
of 1,320 lines of App build (macOS)"* under it, expandable to those 42 lines, is a claim a reviewer
can check. Nothing about a diagnosis is persisted — no `UserDefaults`, no GRDB table, no field in
the synced settings document — for [ADR 0020](0020-apple-native-text-intelligence.md)'s reason
about held prose: it is a reading aid that holds a log tail, and it lives as long as somebody is
looking at it.

### 5. The hand-off ends in a human Run

*Draft an agent brief* opens the delegation sheet with a `DelegationContext` whose origin is the
finding the log named and whose one finding comment is *"CI: <test> — <hypothesis>"*.
Feature E's drafter then writes the brief ([ADR 0011](0011-delegate-to-local-agent-cli.md)'s
amendment), the reviewer edits it, and **the reviewer presses Run**. The finding comment carries no
author, deliberately: it is Shepherd's own sentence rather than a colleague's, which is what the
author list exists to distinguish.

**Nothing in this feature acts.** There is no path from a diagnosis to a comment, to the outbox, to
a re-run of CI, to a merge or to a started agent. It reads, and it says what it read.

## Consequences

- The three-tool registry is now load-bearing in two directions: it is what a model may call, and
  it is what a reviewer is promised. A fourth tool needs an amendment here, and a tool that writes
  needs a new ADR that overturns §1 rather than widening it.
- CI logs are the second content class to reach a configured endpoint, after the diff excerpt
  ([ADR 0007](0007-layered-intelligence.md)'s drafting amendment) — and the first that needs a
  click of its own. Any further content class follows this shape: a named button, a sentence in the
  host list, a line here.
- `GitHubKit` gained one read and one error case. The read deliberately bypasses the conditional
  cache: the URL is keyed by an immutable job id, so every cached entry would be an unreachable row
  holding up to 2 MB — the reason `/check-runs` is not cached either.
- A tier that cannot call tools says so (`IntelligenceError.toolsUnsupported`) instead of answering
  from a turn where it read nothing, and a provider that does not implement the method inherits a
  default that refuses. An unread guess looks exactly like a read one on a card, which is the one
  failure mode this feature could not tolerate.
