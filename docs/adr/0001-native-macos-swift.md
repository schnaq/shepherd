# ADR 0001: Native macOS app in Swift/SwiftUI

Status: Accepted · Date: 2026-08-31

## Context

Shepherd needs a Linear-quality desktop experience. Three stacks were evaluated in depth
([research](../research/research-github-stack.md#4-tech-stack-comparison)):

- **Native Swift/SwiftUI** — smallest footprint, fastest cold start, deepest OS integration
  (Keychain, UserNotifications, menu bar), and uniquely: access to Apple's on-device
  **Foundation Models** framework. Weakness: no off-the-shelf Monaco-quality diff viewer.
- **Tauri v2 + React** — light shell, full web diff ecosystem, cross-platform path. The
  research report's pragmatic recommendation *if cross-platform optionality matters*.
- **Electron + React** — lowest diff-viewer risk, heaviest footprint; contradicts the
  local-first/lightweight product thesis.

The founder decided macOS-only is acceptable: the target user is a Mac-based maintainer, and
on-device AI via Foundation Models is part of the product identity, not an add-on.

## Decision

Shepherd is a **native macOS application written in Swift 6 / SwiftUI**. Domain logic lives in
a platform-independent SPM package (`ShepherdKit`) so it stays testable headlessly and keeps a
future port (iPadOS, or another shell) possible. The diff viewer risk is mitigated separately
(ADR 0003), not by switching stacks.

## Consequences

- Windows/Linux users are out of scope indefinitely; the README says so plainly.
- We get Foundation Models, native Keychain, native notifications, and a genuinely small,
  fast app — the qualities the product is pitched on.
- Core logic must not import AppKit/SwiftUI; CI enforces `swift test` on `ShepherdKit`.
- The one web technology exception is the diff viewer (ADR 0003).
