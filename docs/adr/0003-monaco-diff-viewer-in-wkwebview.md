# ADR 0003: Monaco diff editor in WKWebView (hybrid diff viewer)

Status: Accepted · Date: 2026-08-31

## Context

The inline-comment diff viewer is the hardest, highest-risk single component
([research](../research/research-github-stack.md#4-tech-stack-comparison)). There is no
Monaco-equivalent Swift library; building GitHub-quality side-by-side diffs with syntax
highlighting and inline comment gutters on `STTextView`/Highlightr is weeks of custom work.
Monaco's diff editor (the actual VS Code engine) runs unmodified inside WKWebView and has OSS
prior art for exactly this use (Bottleneck).

## Decision

The diff view is a **locally bundled Monaco diff editor running in a WKWebView**, embedded in
an otherwise fully native SwiftUI app. Swift ⇄ web communication goes through a **typed,
versioned JSON message bridge** (documented in [ARCHITECTURE.md](../ARCHITECTURE.md)); the web
bundle is built from TypeScript with esbuild and shipped as a static app resource — no
network access, no remote content, `file`/`about:` origin only.

## Consequences

- GitHub-quality diff UX (syntax highlighting for ~80 languages, side-by-side/inline toggle,
  word-level diffs, comment zone widgets) is available from day one.
- The repo contains one TypeScript sub-project (`web/diff-viewer`) with an npm build step;
  its `dist/` output is committed so app builders don't need Node.
- Theme (dark/light), font, and all review actions must round-trip the bridge; the bridge
  protocol is a public contract with schema tests on both sides.
- Native rewrite of the diff view remains possible later behind the same view-model
  boundary — the bridge isolates Monaco from the rest of the app.

## Amendment (2026-09-04): the boundary is enforced, not assumed

This ADR says the web view has no network access of its own — a `file://` origin, no remote
loads — and the bundle was written against that sentence. It was not true. A `WKWebView` with no
navigation delegate answers *allow* to every navigation, and the viewer renders somebody else's
text: `MarkdownHTML` deliberately lets `https://` links through and the bundle draws them as
ordinary anchors, so anyone who can write a pull-request description or a review comment could put
a link in front of the reviewer that navigated **this** view — the one holding the `shepherd`
message handler — to a page of their choosing. That page would then have been able to post forged
bridge messages from the same `WKWebViewConfiguration`, and it would have done so inside the app's
own chrome, where there is no address bar to give it away.

So the sentence is now a `WKNavigationDelegate`. The only navigation allowed is a file inside the
bundle directory, compared after both paths are standardised and their symlinks resolved, which is
`GitWorktree.ensureManaged()`'s reasoning. A view that could not find its own bundle allows
nothing at all. A clicked `http`/`https` link is cancelled here and opened in the user's browser
instead, where a URL bar and a real security model exist; every other scheme is refused without
comment.

The decision this records is small and worth stating anyway: a trust boundary a document only
*describes* is not a boundary. The check is a static function so it can be asserted without
fabricating a `WKNavigationAction`, and the tests spell out the cases — the bundle's own files, a
web page, a traversal out, a sibling directory whose name starts the same way, and no bundle.
