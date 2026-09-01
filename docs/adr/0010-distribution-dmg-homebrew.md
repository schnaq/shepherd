# ADR 0010: Distribution via GitHub Releases (DMG) + Homebrew cask, Sparkle for updates

Status: Accepted · Implemented, pending the maintainer's Apple account · Date: 2026-08-31

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

## Status of the implementation

Everything except the two credentials that can only exist on the maintainer's Mac is committed:
`Scripts/release.sh` (build → sign → DMG → notarize → staple → Sparkle-sign → appcast),
`.github/workflows/release.yml` (tag `v*` or manual), the Sparkle dependency and `Info.plist`
keys in `project.yml`, `Shepherd/Support/UpdateController.swift`, the "Check for Updates…" menu
item and the Settings section, and `Scripts/homebrew/shepherd.rb`.

Two placeholders remain, and both are the maintainer's one-time work:
`SUPublicEDKey` in `project.yml` (from Sparkle's `generate_keys`) and the GitHub secrets for the
Developer ID identity and notarization. Until they are filled in, the app refuses to start the
updater at all rather than shipping an unverified one — a build whose public key is not a
32-byte ed25519 key disables updates and says so in Settings — and the release workflow aborts
on its first step naming the missing secrets. The full path is in
[docs/RELEASING.md](../RELEASING.md).

Two decisions the ADR left open, resolved during implementation:

- **The feed is `releases/latest/download/appcast.xml`**, not a GitHub-Pages URL: GitHub
  redirects that permanent URL to the newest published release's asset, so publishing the
  release publishes the feed — one moving part instead of two.
- **Sparkle may find updates in the background but never install them silently**
  (`SUAllowsAutomaticUpdates: false`): unsent review drafts live in the local database
  (ADR 0006), and an app that replaces itself mid-review would lose them.
