# ADR 0010: Distribution via GitHub Releases (DMG) + Homebrew cask, Sparkle for updates

Status: Accepted · Date: 2026-08-31

## Context

Options: Mac App Store (reach, but sandbox restrictions and review latency fight a
power-user Git tool), plain "build it yourself", or the OSS-standard path: notarized DMG on
GitHub Releases + a Homebrew cask + Sparkle self-updates.

## Decision

- Releases ship as a **DMG (and ZIP) via GitHub Releases**, installable with
  `brew install --cask shepherd` once the cask is published.
- **Sparkle 2** provides in-app updates, fed by an appcast generated in release CI.
- Code signing & notarization with the maintainer's Apple Developer ID **as soon as the
  account exists**; until then, releases are unsigned and the README documents the
  right-click-open caveat. The build must not *depend* on signing (contributors build unsigned).
- No Mac App Store distribution for v1 (sandbox would complicate Keychain/device-flow and
  Sparkle; revisit post-1.0).

## Consequences

- Release CI (GitHub Actions, macOS runner) builds, signs when secrets are present, notarizes,
  produces DMG + appcast. Local `xcodegen && xcodebuild` stays the contributor path.
- Sparkle adds one runtime dependency and an `SUFeedURL`; auto-update is opt-out in settings.
