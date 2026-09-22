# Third-party notices

Shepherd itself is MIT-licensed ([`LICENSE`](LICENSE), [ADR 0009](docs/adr/0009-mit-license.md)),
and every dependency it ships is MIT, BSD or equivalently permissive — which
[ADR 0009](docs/adr/0009-mit-license.md) requires. This file lists the components that end up
**inside `Shepherd.app`** and reproduces their notices, as that ADR asks.

Build-time-only tools are deliberately *not* listed: XcodeGen, esbuild, TypeScript, Vitest, jsdom
and Sparkle's `generate_keys` / `sign_update` never reach a user's Mac. `web/diff-viewer`'s
`devDependencies` are all in that category — the only one of them whose output is redistributed is
`monaco-editor`, which is why it appears below.

Keep this file in step with a dependency change in the same pull request; a release checks it
([docs/RELEASING.md](docs/RELEASING.md)).

| Component | Version | License | Where it lives in the app |
| --- | --- | --- | --- |
| [Monaco Editor](https://github.com/microsoft/monaco-editor) | 0.56.0 | MIT | `Contents/Resources/DiffViewer/dist/` (bundled into `viewer.js` / `viewer.css`) |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.x | MIT | linked into the app binary |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | MIT-style (Sparkle license, see below) | `Contents/Frameworks/Sparkle.framework` |
| [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels) | 0.2.1 | Apache-2.0 | linked into the app binary |

Shepherd links Apple's own frameworks (SwiftUI, WebKit, Security, FoundationModels, …) under the
Apple SDK license; they are part of macOS and are not redistributed.

---

## Monaco Editor

The VS Code diff engine, bundled offline into the diff viewer's web bundle
([ADR 0003](docs/adr/0003-monaco-diff-viewer-in-wkwebview.md)). The committed bundle in
`Shepherd/Resources/DiffViewer/dist/` contains Monaco's minified JavaScript and CSS; its icon
font is not part of the bundle.

```
The MIT License (MIT)

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## GRDB.swift

The SQLite toolkit behind the local-first cache
([ADR 0006](docs/adr/0006-local-first-sqlite-grdb.md)). A dependency of `ShepherdPersistence`, so
it is linked into the app on macOS and into the test binaries on Linux.

```
Copyright (C) 2015-2025 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

GRDB links the SQLite library that ships with macOS. SQLite itself is in the
[public domain](https://sqlite.org/copyright.html).

---

## Sparkle

The in-app update framework ([ADR 0010](docs/adr/0010-distribution-dmg-homebrew.md)). Distributed
under Sparkle's own license, which is MIT in substance, plus the licenses of four components
Sparkle vendors. All of them are permissive and reproduced below, condensed to their operative
terms; the authoritative text is
[`LICENSE`](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE) in the Sparkle
repository at the pinned tag.

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

Components Sparkle vendors, from its `EXTERNAL LICENSES` section:

- **bsdiff 4.3** (`bspatch.c`, `bsdiff.c`) — Copyright 2003-2005 Colin Percival, 2-clause BSD.
- **sais-lite (2010/08/07)** (`sais.c`, `sais.h`) — Copyright (c) 2008-2010 Yuta Mori, MIT.
- **Portable C implementation of Ed25519** — Copyright (c) 2015 Orson Peters, zlib-style: provided
  as-is, free for any purpose including commercial use, provided the origin is not
  misrepresented, altered versions are marked as such, and the notice is not removed.
- **`SUSignatureVerifier.m`** — Copyright (c) 2011 Mark Hamlin, 2-clause BSD.

## ClaudeForFoundationModels

Anthropic's bridge from Apple's Foundation Models `LanguageModel` protocol to the Claude Messages
API, behind tier 3 when the reviewer brings an Anthropic key ([ADR 0038](docs/adr/0038-macos-27-floor.md),
item 1). Linked into the app binary; the reviewer's key is the only credential it ever carries.

```
Copyright 2026 Anthropic PBC

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
except in compliance with the License. You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the
License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
either express or implied. See the License for the specific language governing permissions
and limitations under the License.
```

The full licence text is [`LICENSE`](https://github.com/anthropics/ClaudeForFoundationModels/blob/0.2.1/LICENSE)
in that repository at the pinned tag. Apache-2.0 §4(d) asks for a `NOTICE` file's contents to be
reproduced where one exists; the package ships none.

