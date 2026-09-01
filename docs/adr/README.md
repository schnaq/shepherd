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
| 0010 | [Distribution via DMG + Homebrew, Sparkle updates](0010-distribution-dmg-homebrew.md) | Accepted |
| 0011 | [Delegate coding tasks to a local agent CLI](0011-delegate-to-local-agent-cli.md) | Accepted (v1.x) |
| 0012 | [Outbound webhooks (outbound only, ADR 0005 stands)](0012-outbound-webhooks.md)  | Accepted (v1.x) |
| 0013 | [`shepherd://` URL scheme + companion CLI](0013-url-scheme-and-cli.md)     | Accepted (v1.x) |
| 0014 | [End-to-end encrypted settings sync over the user's own S3 bucket](0014-encrypted-settings-sync.md) | Accepted (v1.x) |

Format: lightweight [MADR](https://adr.github.io/madr/)-style — Context, Decision, Consequences.
New decisions get the next number; superseded ADRs are marked, never deleted.
