# Evaluating Shepherd's intelligence features

A **manually run** harness for measuring what the models actually answer, and the corpus it runs
against. It is *not* part of CI, and that is a decision rather than an omission — see
[Why it is not in CI](#why-it-is-not-in-ci).

Background: [`docs/plans/apple-intelligence-v2.md`](../../docs/plans/apple-intelligence-v2.md)
§0.4, and ADR [0007](../../docs/adr/0007-layered-intelligence.md) for the tier rules the harness
inherits.

## What it is

Two things, in two places:

| Piece | Where |
| --- | --- |
| The corpus: anonymised fixture pull requests with an expected verdict, and CI log tails with an expected diagnosis | [`Tests/Fixtures/eval/`](../../Tests/Fixtures/eval) |
| The runner: an `XCTest` in the app's test target, gated by an environment variable | `ShepherdTests/IntelligenceEvalTests.swift` |

There is no script in this directory. The runner is an `XCTest` because the thing being measured
only exists inside the app target: the on-device model is reached through `FoundationModels`,
which by ADR 0007's placement rule may only be imported under `Shepherd/`. A standalone Swift
script could not call it, and a shell script could not either.

## Running it

```sh
xcodegen generate
SHEPHERD_EVAL=1 xcodebuild -project Shepherd.xcodeproj -scheme Shepherd \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ShepherdTests/IntelligenceEvalTests test
```

Without `SHEPHERD_EVAL=1` every test in that class calls `XCTSkipUnless` and reports as skipped.
That is the intended state: an ordinary `xcodebuild test`, and therefore CI, runs the corpus
checks and the model calls not at all.

Tier 2 needs Apple Intelligence to be switched on and its model downloaded on the Mac doing the
measuring. A tier-3 run additionally needs a key in the Keychain and a configured endpoint, and
costs whatever that endpoint charges — which is the second reason the harness is opt-in.

## The fixture contract

One JSON object per file, in `Tests/Fixtures/eval/`. The file's **prefix decides its kind**, so a
new fixture is one file and no code change; the runner walks the directory and fails on a `.json`
in there that matches neither prefix.

### `pr-*.json` — one pull request to classify

```json
{
  "id": "PR_eval_01",
  "title": "Add saved replies to the review composer",
  "body": "Adds a menu of reusable comment bodies…",
  "files": [
    { "path": "app/Features/Review/ComposerToolbar.swift", "status": "modified", "additions": 74, "deletions": 6 }
  ],
  "riskHints": ["adds a settings surface", "new persisted value"],
  "expected": { "kind": "feature", "risk": "medium" }
}
```

- `status` is a `FileChangeStatus` raw value: `added`, `modified`, `removed`, `renamed`.
- `riskHints` are the **tier-1** hints the classifier is given beside the search document, in the
  wording `FilePrioritizer` produces them in ("touches auth", "deletes tests", lockfile-only).
  They are input, not expectation: the point of the corpus is to measure the model *with* the
  heuristics it will really have.
- `expected.kind` and `expected.risk` are raw values of `TriageVerdict.Kind` and
  `TriageVerdict.Risk`. The runner asserts that they are — a typo in a fixture would otherwise
  read as a model error for ever.

The corpus covers every kind and every risk at least once, and the runner enforces that: a
precision-per-field number computed over a corpus with no `chore` in it cannot say anything about
`chore`.

### `ci-*.json` — one failing check to diagnose

```json
{
  "checkName": "ShepherdKit tests (Linux)",
  "logTail": ["Test Suite 'All tests' started…", "…"],
  "expected": {
    "failingTest": "SearchRankerTests.testBlendedRankingKeepsExactMatchesFirst",
    "file": "Packages/ShepherdKit/Tests/ShepherdCoreTests/SearchRankerTests.swift",
    "line": 212
  }
}
```

- `logTail` is the tail as **separate lines**, 30–60 of them, because that is how a log is
  authored and counted by hand; the harness joins them with `\n` before handing them to the
  digest. Four output shapes are covered — `xcodebuild`, `swift test`, npm (vitest) and pytest —
  because the failing-region heuristic has to work on all four and they agree on nothing.
- Every field of `expected` is optional except in spirit: `failingTest` is `null` where the log
  names no test (a compile error in a test target), and the runner requires that a fixture name
  at least a test *or* a file, so a fixture that expects nothing cannot sit in the corpus looking
  like a pass.

## Anonymisation

Every fixture is written by hand from the *shape* of a real failure, never pasted from one. No
real logins, no real repository names, no customer paths, no tokens; the pull requests are
plausible Shepherd-shaped changes rather than copies of anybody's. That is a hard rule for this
directory: the corpus is committed to a public repository and read by whoever clones it.

## What the runner asserts today

The features that call a model are Sprint 1 and later (plan §3.A, §3.F). Until they land, the
runner validates the *corpus*:

- every fixture decodes into the shape above;
- every expected kind, risk and file status is a case the domain actually has;
- every CI fixture has a 30–60 line tail and names something to measure;
- nothing else is sitting in the directory being silently skipped.

When the classifier and the CI diagnosis exist, the model calls are added to this same class and
print precision per field — `kind`, `risk`, `failingTest`, `file`, `line` — one line per fixture
and a summary. Apple's Evaluations framework replaces the hand-rolled loop if its API is stable
by then; the corpus does not change either way, which is why it is committed first.

## Why it is not in CI

Three reasons, in order of weight:

1. **It measures a model, not the code.** Apple ships a new on-device model with an OS update; a
   BYOK endpoint changes what it serves behind the same name. Either would turn a green build red
   with nobody having touched the repository — a failure that teaches a team to ignore failures.
2. **It needs a machine with Apple Intelligence on**, and the tier-3 half needs a key and spends
   money. CI has neither and should have neither.
3. **The numbers are a judgement, not a threshold.** "Risk was wrong on two of twelve" is
   something a maintainer reads and thinks about before a prompt change; a pass/fail gate would
   invite tuning the corpus until it passes.

So it is run deliberately: before and after a prompt change, after an OS update that moves the
model, and when a feature that depends on a verdict is being designed.
