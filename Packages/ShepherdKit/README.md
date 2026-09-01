# ShepherdKit

The platform-independent core of [Shepherd](../../README.md): domain models, GitHub client,
local database and sync engine. **No AppKit, SwiftUI, WebKit, or Security imports** — the app
target owns every Apple-only framework. Everything here builds and tests headlessly with
`swift test` on macOS and Linux.

## What's in the box

| Target | Depends on | What lives there |
| --- | --- | --- |
| `ShepherdCore` | Foundation only | Domain models (`PullRequestSummary`, `ReviewDraft`, `ChangedFile`, …), `AgentDetector` + the bundled `agent-registry.json`, `FilePrioritizer`, `InboxGrouper`, `PullRequestDigestBuilder`, `BulkTriagePlan`, the `ConditionalCache` and `Sleeping` protocols |
| `GitHubKit` | `ShepherdCore` | `GitHubClient` actor (GraphQL search sweep, REST detail/writes, GraphQL thread resolution), `DeviceFlowAuthenticator` + `TokenRefresher`, `TokenStore`, rate-limit parsing and backoff, `AsyncSemaphore`, `HTTPTransport` |
| `ShepherdPersistence` | `ShepherdCore`, GRDB | `DatabaseManager` (migrator + v1 schema), record types, inbox/draft/outbox/etag stores, `ValueObservation` streams |
| `ShepherdSync` | all three | `SyncEngine` actor: notifications loop + inbox sweep, delta detection, staggered detail fetches, outbox drain with staleness re-validation |

The dependency direction is one-way and enforced by the package manifest:

```
ShepherdSync → GitHubKit ────→ ShepherdCore
            ↘ ShepherdPersistence ↗
```

Design decisions behind all of this live in [`docs/adr`](../../docs/adr); the module contract
is [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md). If code and that document disagree,
fix one of them in the same PR.

## Testing

```sh
cd Packages/ShepherdKit
swift test                      # everything
swift test --filter ShepherdCoreTests
swift test --filter FilePrioritizerTests/testDeletingATestFileIsARiskBoost
```

On Linux you need SQLite's headers for GRDB's system-library target:

```sh
sudo apt-get install -y libsqlite3-dev
```

### How the tests are built

- **No network, ever.** `GitHubKit` talks to the world through the `HTTPTransport` protocol;
  the tests inject a scripted `MockTransport` and assert against recorded API payloads in
  `Tests/GitHubKitTests/Fixtures/`. Those fixtures are the shapes from GitHub's documentation
  — if GitHub changes a response, change the fixture and the mapper together.
- **No wall-clock waits.** Every delay goes through `Sleeping`. Tests inject a recorder that
  returns immediately and remembers what it was asked to wait for, so rate-limit backoff and
  the poll loops can be asserted on without the suite taking minutes.
- **No temp-file surprises.** Persistence tests run against an in-memory `DatabaseQueue`;
  the two tests that need a real file create and clean up their own directory.

## Conventions

- Public types carry `///` documentation. Library code has no force-unwraps and no
  `fatalError` — failures are typed (`GitHubError`, `AgentRegistryError`).
- Concurrency: mutable shared state lives in actors; value types are `Sendable`. `@unchecked
  Sendable` appears exactly once (`URLSessionTransport`) and carries the reason in a comment.
- Timestamps cross the wire as ISO-8601 (`GitHubTimestamp`) and are stored in SQLite as REAL
  Unix epoch seconds, so they round-trip exactly.
- Database columns are camelCase (GRDB's own convention); table names are snake_case and match
  `docs/ARCHITECTURE.md`.
- The schema migrator is **append-only**. Never edit an existing migration; add a new one.

## Wiring it up from the app

```swift
let database = try DatabaseManager(url: applicationSupportURL)
let client = GitHubClient(
    transport: URLSessionTransport(),
    tokenProvider: RefreshingTokenProvider(login: login, store: keychainTokenStore,
                                           refresher: TokenRefresher(clientID: AppConfig.clientID,
                                                                     transport: URLSessionTransport())),
    agentDetector: try AgentDetector(extensions: await database.agentRegistryOverrides()),
    cache: DatabaseConditionalCache(database: database)
)
let engine = SyncEngine(github: client, store: database)
await engine.start()
for await event in engine.events { … }        // map to macOS notifications
for await inbox in database.observeInbox() { … }   // render the UI from the database
```
