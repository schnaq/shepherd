# Contributing to Shepherd

Thanks for helping herd the agents! 🐑

## Prerequisites

- macOS 26+, Xcode 26+ (app target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Node 22+ (only if you touch `web/diff-viewer`)

## Setup

```sh
cd web/diff-viewer && npm ci && npm run build && cd ../..   # builds Resources/DiffViewer/dist
xcodegen generate
open Shepherd.xcodeproj
```

`Shepherd.xcodeproj` is generated and git-ignored — edit `project.yml`, not the project.

## Working on ShepherdKit (no Xcode needed)

The domain/network/persistence/sync logic is a plain SPM package:

```sh
cd Packages/ShepherdKit
swift test
```

It must keep building without AppKit/SwiftUI/WebKit imports and pass tests headlessly —
this is enforced by CI on both macOS and Linux. GRDB supports Linux via SwiftPM since 7.10,
so the persistence tests run on both runners; on Linux you need `libsqlite3-dev` installed
(`sudo apt-get install libsqlite3-dev`), which CI does for you.

## Working on the diff viewer

```sh
cd web/diff-viewer
npm ci
npm run dev     # standalone harness in the browser with fixture data
npm test        # bridge protocol + rendering tests
npm run build   # emits ../../Shepherd/Resources/DiffViewer/dist — commit the output
```

The Swift⇄web bridge protocol is a contract: change `src/bridge/protocol.ts`,
`BridgeProtocol.swift`, the shared fixtures, and `docs/ARCHITECTURE.md` together.

## Rules of the road

- Decisions live in [docs/adr](docs/adr). Changing a decision = new ADR, not a silent edit.
- UI strings: English, `String(localized:)`. Colors: semantic tokens only (dark/light!).
- No telemetry, ever. The complete list of hosts Shepherd may contact:
  - api.github.com / github.com;
  - only when the user configures a key: api.anthropic.com, or the OpenAI-compatible endpoint
    they chose themselves (a preset's base URL is still their choice);
  - only when the user enables webhooks and types a URL: **that URL** (ADR 0012). Outbound only,
    one destination, off by default, and the payload never carries review text, comment bodies,
    diffs or agent output.

  Nothing else. This is a hard privacy line: adding a host means a new ADR, a settings control the
  user has to switch on, and a line here.
- Conventional commits appreciated (`feat:`, `fix:`, `docs:` …), not enforced.

## License

By contributing you agree your contributions are licensed under the [MIT license](LICENSE).
