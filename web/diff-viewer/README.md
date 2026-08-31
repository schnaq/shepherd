# Shepherd diff viewer (`web/diff-viewer`)

The diff view in Shepherd is a **locally bundled Monaco diff editor running in a WKWebView**
([ADR 0003](../../docs/adr/0003-monaco-diff-viewer-in-wkwebview.md)). This directory is that
bundle: a TypeScript project built with esbuild into a fully offline `index.html` + JS + CSS,
committed to [`Shepherd/Resources/DiffViewer/dist`](../../Shepherd/Resources/DiffViewer/dist)
so app builders never need Node.

```sh
npm ci
npm run dev      # standalone browser harness with fixture data → http://127.0.0.1:5173
npm test         # tsc --noEmit + vitest (protocol, routing, zones, gutter, themes, cards)
npm run build    # wipes and re-emits ../../Shepherd/Resources/DiffViewer/dist — commit it
```

## How it works

```
Swift (Features/DiffViewer)                         web bundle (this directory)
  evaluateJavaScript("shepherd.receive({…})")  ──▶  window.shepherd.receive
                                                      └ parseInbound()  (protocol.ts)
                                                        └ routeInbound() (router.ts)
                                                          └ MonacoDiffViewer  (monacoViewer.ts)
  userContentController "shepherd"             ◀──  window.webkit.messageHandlers
                                                      .shepherd.postMessage
```

| module | role |
| --- | --- |
| `src/bridge/protocol.ts` | the versioned message contract: TS types, constructors, hand-rolled validators |
| `src/bridge/transport.ts` | installs `window.shepherd`, finds the WKWebView handler, stubs it outside one |
| `src/viewer/router.ts` | dispatches a validated message onto the `ViewerPort` interface |
| `src/viewer/monacoViewer.ts` | the only file that touches Monaco — the imperative shell |
| `src/viewer/zoneState.ts` | reconciles thread/draft snapshots into add/update/remove view-zone work |
| `src/viewer/threadCard.ts` | the DOM for thread and draft cards (+ the HTML scrub) |
| `src/viewer/gutter.ts` | gutter “+” hit-testing |
| `src/viewer/themes.ts` | the two custom Monaco themes and the font-size clamp |
| `src/viewer/languages.ts` | which Monarch grammars get registered (and the two we ship ourselves) |
| `src/viewer/workerEnvironment.ts` | how Monaco's editor worker is started under `file://` |

Everything except `monacoViewer.ts` is pure enough to unit-test; Monaco itself is never booted
in jsdom.

## The bridge protocol

Normative definition: [`docs/ARCHITECTURE.md` §"Diff viewer bridge (Swift ⇄ Monaco)"](../../docs/ARCHITECTURE.md)
→ implemented in [`src/bridge/protocol.ts`](src/bridge/protocol.ts) and (Swift side)
`Shepherd/Features/DiffViewer/BridgeProtocol.swift`. All three must stay field-for-field
identical; [`fixtures/`](fixtures) is the shared decode corpus both sides test against.

Every message carries `"v": 1`.

Swift → web: `loadFile`, `setTheme`, `setThreads`, `setDraftComments`, `revealLine`.
Web → Swift: `ready`, `addComment`, `commentClicked`, `viewportChanged`.

`shepherd.receive` returns `true`/`false` so Swift can assert delivery, and
`shepherd.protocolVersion` lets it check the bundle it loaded speaks version 1.

### Behaviour notes

- **`ready` first.** Nothing is guaranteed to be applied before the bundle posts `ready`;
  Swift should queue and flush on receipt.
- **Comment text entry is native.** The gutter “+” only posts `addComment {line, side}`;
  Swift opens the SwiftUI composer. The webview never handles comment keystrokes.
- **`startLine` is a v1 passthrough.** Multi-line drag selection on the gutter is v2 — the
  viewer always emits the single-line form today, but `startLine` is already validated and
  decoded on both sides so the affordance can land without a protocol bump.
- **`viewportChanged` is throttled** to one message per 120 ms (leading + trailing).
- **Inline mode** has a single pane, so left-side threads render on the modified editor at
  their original-model line number — exact for right-side threads, approximate for left-side
  ones. Side-by-side mode places each zone on its own pane.

### `bodyHTML` is trusted-from-native

`ThreadComment.bodyHTML` is rendered with `innerHTML`. **Swift renders and sanitizes the
GitHub markdown before it reaches the webview** — that is the contract. As belt-and-braces the
viewer still scrubs the parsed fragment (`sanitizeInPlace` in `threadCard.ts`): it deletes
`<script>`/`<style>`/`<iframe>`/`<object>`/form elements, strips every `on*` attribute, and
drops `javascript:`, `vbscript:` and `data:text/html` URLs. No inline event handlers are ever
emitted — interaction is wired with `addEventListener`. Draft bodies are plain text and go in
through `textContent`.

## Offline guarantees

- One JS file, one CSS file, one worker file. No CDN, no `fetch`, no dynamic `import()` that
  survives bundling (esbuild inlines Monaco's lazy grammar imports into the IIFE).
- Any font/image asset is inlined as a `data:` URI — the built CSS contains no `url()` at all.
- `index.html` ships a CSP with `default-src 'none'` and **`connect-src 'none'`**, so
  fetch/XHR/WebSocket are impossible at runtime. `blob:` is allowed only for the worker.
- All references in `index.html` are relative (`./viewer.js`, `./viewer.css`), so the bundle
  works from any bundle path.

## Worker loading (the WKWebView-specific part)

Monaco computes diffs in `editor.worker`. Under `WKWebView.loadFileURL` the page has an opaque
`file:` origin where `new Worker('./editor.worker.js')` is refused, and module workers are
worse. So:

1. `scripts/build-support.mjs` bundles `monaco-editor/editor/editor.worker` on its own into a
   **classic IIFE**.
2. That source is inlined into the main bundle as a string through the virtual module
   `virtual:editor-worker-source`.
3. At runtime `workerEnvironment.ts` sets
   `self.MonacoEnvironment = { getWorker: () => new Worker(URL.createObjectURL(new Blob([source]))) }`.
   A `blob:` URL inherits the page origin and needs no file-system read permission.
4. `dist/editor.worker.js` is emitted anyway — as a debugging aid and as the fallback used if
   `Blob`/`createObjectURL` is unavailable or the blob worker is rejected.

`tests/workerEnvironment.test.ts` pins that ordering (blob first, classic worker, fallback).

## Syntax highlighting

Plain `monaco-editor/editor/editor.api` imports register **no languages at all** — the Monarch
grammars live in `monaco-editor/languages/definitions/<id>/register.js` and only
`editor.main` pulls them in (along with every language *service* and its four workers). Since
Shepherd only displays diffs, the language services are all left out and the grammars are
imported explicitly in `src/viewer/languages.ts`:

`c`, `cpp`, `csharp`, `css`, `dockerfile`, `go`, `graphql`, `html`, `java`, `javascript`,
`kotlin`, `markdown`, `objective-c`, `php`, `python`, `ruby`, `rust`, `shell`, `sql`, `swift`,
`typescript`, `xml`, `yaml` — plus `json` and `toml`, for which monaco-editor ships no Monarch
grammar (JSON is coloured by its language service upstream; TOML does not exist), written in
`src/viewer/extraLanguages.ts`.

Anything else falls back to `plaintext`; `resolveLanguage` also maps common aliases (`ts`,
`c++`, `yml`, `bash`, …) so a slightly-off id from Swift never kills colourization.

## Loading it from Swift

```swift
let config = WKWebViewConfiguration()
config.userContentController.add(bridgeHandler, name: "shepherd")   // ← must be "shepherd"
config.defaultWebpagePreferences.allowsContentJavaScript = true

let webView = WKWebView(frame: .zero, configuration: config)
webView.isInspectable = true   // debug builds only

let dist = Bundle.main.url(forResource: "DiffViewer/dist", withExtension: nil)!
webView.loadFileURL(dist.appendingPathComponent("index.html"), allowingReadAccessTo: dist)
```

- The handler name **must** be `shepherd` — that is what `transport.ts` looks up in
  `window.webkit.messageHandlers`.
- `allowingReadAccessTo` must be the `dist` **directory** (not the html file) so `viewer.js`
  and `viewer.css` resolve.
- Send with `webView.evaluateJavaScript("shepherd.receive(\(json))")` where `json` is the
  encoded message; wait for the `ready` message before the first send.
- Nothing outside `dist/` is reachable, and the CSP blocks all network access, so no
  navigation delegate policy is strictly required — but denying every non-`file:` navigation
  is still the right belt-and-braces.

## Build output

`npm run build` wipes `../../Shepherd/Resources/DiffViewer/dist` and re-emits:

| file | ~size | what |
| --- | --- | --- |
| `index.html` | 1 KB | shell + CSP |
| `viewer.js` | 2.95 MB | Monaco core, Monarch grammars, the bridge, the inlined worker |
| `viewer.css` | 82 KB | Monaco CSS + thread-zone chrome |
| `editor.worker.js` | 297 KB | fallback/debug copy of the worker |
| **total** | **≈ 3.3 MB** | |

The build is deterministic — no content hashes, no timestamps, no sourcemaps — so rebuilding
unchanged sources produces byte-identical files and CI's `git diff --exit-code` on `dist/`
stays quiet.

## Changing the protocol

Per `CONTRIBUTING.md`, these move together in one PR: `src/bridge/protocol.ts`,
`Shepherd/Features/DiffViewer/BridgeProtocol.swift`, `fixtures/*.json`, and
`docs/ARCHITECTURE.md`.
