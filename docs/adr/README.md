# Architecture Decision Records

Every significant decision for Shepherd is recorded here. Decisions were made in a structured
founder interview (2026-08-31) combined with three research reports (see
[docs/research](../research)).

| #    | Decision                                                                  | Status   |
| ---- | ------------------------------------------------------------------------- | -------- |
| 0001 | [Native macOS app in Swift/SwiftUI](0001-native-macos-swift.md)           | Accepted |
| 0002 | [Require macOS 26+ on Apple Silicon](0002-macos-26-apple-silicon.md)      | Accepted |
| 0003 | [Monaco diff editor in WKWebView](0003-monaco-diff-viewer-in-wkwebview.md)| Accepted |
| 0004 | [GitHub App + device flow auth, PAT fallback](0004-github-app-device-flow-auth.md) | Accepted |
| 0005 | [GraphQL search reads, REST writes, ETag polling](0005-api-strategy-graphql-search-rest-writes.md) | Accepted |
| 0006 | [Local-first: SQLite (GRDB) as source of truth](0006-local-first-sqlite-grdb.md) | Accepted |
| 0007 | [Layered intelligence: heuristics → on-device → BYOK cloud](0007-layered-intelligence.md) | Accepted |
| 0008 | [Agent provenance as a first-class facet](0008-agent-provenance-first-class.md) | Accepted |
| 0009 | [MIT license](0009-mit-license.md)                                        | Accepted |
| 0010 | [Distribution via DMG + Homebrew, Sparkle updates](0010-distribution-dmg-homebrew.md) | Accepted (pipeline in place, awaiting the Apple account) |
| 0011 | [Delegate coding tasks to a local agent CLI](0011-delegate-to-local-agent-cli.md) | Accepted (v1.x) |
| 0012 | [Outbound webhooks (outbound only, ADR 0005 stands)](0012-outbound-webhooks.md)  | Accepted (v1.x) |
| 0013 | [`shepherd://` URL scheme + companion CLI](0013-url-scheme-and-cli.md)     | Accepted (v1.x) |
| 0014 | [End-to-end encrypted settings sync over the user's own S3 bucket](0014-encrypted-settings-sync.md) | Accepted (v1.x) |
| 0015 | [Bulk triage: one confirmation, n ordinary outbox writes](0015-bulk-triage.md) | Accepted (v1.x) |
| 0016 | [Opt-in auto-delegation rules (red CI on your own PR)](0016-auto-delegation-rules.md) | Accepted (v1.x) |
| 0017 | [Local-only crash and hang reports via MetricKit](0017-local-diagnostics-metrickit.md) | Accepted (v1.x) |
| 0018 | [Opt-in auto-merge rules (green, approved, agent PR)](0018-auto-merge-rules.md) | Accepted (v1.x) |
| 0019 | [Semantic ⌘K search over pull requests, on-device only](0019-semantic-search-on-device-embeddings.md) | Accepted (v1.x) |
| 0020 | [Apple-native text intelligence: Writing Tools + on-device translation](0020-apple-native-text-intelligence.md) | Accepted (v1.x) |
| 0021 | [App Intents for Shortcuts and Siri, pull requests in Spotlight](0021-app-intents-and-spotlight.md) | Accepted (v1.x) |
| 0022 | [German localisation through one String Catalog, with a Python gate in CI](0022-german-localisation.md) | Accepted (v1.x) |
| 0023 | [Structured triage: one on-device verdict per pull request](0023-structured-triage.md) | Accepted (v1.x) |
| 0024 | [Tool calling for "why is CI red?": three reads, one card](0024-tool-calling-ci-diagnosis.md) | Accepted (v1.x) |
| 0025 | [Private Cloud Compute as a tier between on-device and bring-your-own-key: parked, with the conditions that would unpark it](0025-private-cloud-compute.md) | Parked |
| 0026 | [Claims vs. Evidence: the description beside the diff, no score](0026-claims-vs-evidence.md) | Accepted (v1.2) |
| 0027 | [Track record and trust lanes: the gate is CI, size and sensitive paths](0027-track-record-and-trust-lanes.md) | Accepted (v1.2) |
| 0028 | [Since my review: a local snapshot at submit time, the interdiff computed on the Mac](0028-since-my-review-interdiff.md) | Accepted (v1.2) |
| 0029 | [The feedback loop: a recurring finding becomes a drafted agent rule](0029-feedback-loop-agent-rules.md) | Accepted (v1.2) |
| 0030 | [The session back-channel: a finding addressed to the session that wrote the code, through the user's own CLI](0030-session-back-channel.md) | Accepted (v1.2) |
| 0032 | [Issues as a second inbox citizen: own sweep, own tables, own search index](0032-issues-inbox.md) | Accepted |

Format: lightweight [MADR](https://adr.github.io/madr/)-style — Context, Decision, Consequences.
New decisions get the next number; superseded ADRs are marked, never deleted.
