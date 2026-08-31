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
