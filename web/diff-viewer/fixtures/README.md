# Bridge fixtures — the cross-language contract corpus

These JSON files are the **shared decode fixtures for the Swift ⇄ web diff-viewer bridge**.
They are not web-only test data: the Swift side (`Shepherd/Features/DiffViewer/BridgeProtocol.swift`)
decodes *these same files* in its own unit tests, so a protocol drift between the two
implementations fails CI on whichever side moved.

Reference: [`docs/ARCHITECTURE.md` §"Diff viewer bridge (Swift ⇄ Monaco)"](../../../docs/ARCHITECTURE.md)
and [`../src/bridge/protocol.ts`](../src/bridge/protocol.ts).

## Naming convention

```
<messageType>.valid.json            must decode
<messageType>.valid-<variant>.json  must decode (an alternative shape of the same message)
<messageType>.invalid.json          must be rejected
```

`tests/fixtures.test.ts` walks this directory, so a new file is picked up automatically — no
list to update. The Swift test should do the same (enumerate the bundle directory) and assert:

| file pattern | Swift expectation |
| --- | --- |
| `*.valid*.json` | `JSONDecoder().decode(...)` succeeds and round-trips |
| `*.invalid.json` | decoding **throws** |

## Coverage

Every message type in both directions has at least one valid and one invalid fixture.

Swift → web:

| message | valid | invalid — why it must be rejected |
| --- | --- | --- |
| `loadFile` | `loadFile.valid.json`, `loadFile.valid-inline.json` | `mode: "unified"` is not `sideBySide`/`inline` |
| `setTheme` | `setTheme.valid.json` | `theme: "solarized"` is not `light`/`dark` |
| `setThreads` | `setThreads.valid.json` | `comments[0].isAgent` is the string `"false"` |
| `setDraftComments` | `setDraftComments.valid.json` | `line: 0` — line numbers are 1-based |
| `revealLine` | `revealLine.valid.json` | `side: "modified"` is not `left`/`right` |

Web → Swift:

| message | valid | invalid — why it must be rejected |
| --- | --- | --- |
| `ready` | `ready.valid.json` | `v: 2` — unsupported protocol version |
| `addComment` | `addComment.valid.json`, `addComment.valid-multiline.json` | `startLine` (9) after `line` (7) |
| `commentClicked` | `commentClicked.valid.json`, `commentClicked.valid-draft.json` | both `threadID` and `localID` present — exactly one is allowed |
| `viewportChanged` | `viewportChanged.valid.json` | `firstVisibleLine: 12.5` is not an integer |

## Rules

- Every message carries `"v": 1`.
- Changing a fixture means changing `protocol.ts`, `BridgeProtocol.swift` **and**
  `docs/ARCHITECTURE.md` in the same PR (see `CONTRIBUTING.md`).
- Keep the files small and human-readable — they double as protocol documentation.
