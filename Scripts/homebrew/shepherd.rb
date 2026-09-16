# Homebrew cask for Shepherd (ADR 0010) — a TEMPLATE, not a published formula.
#
# It lives here so the cask is reviewed in the same pull request as the pipeline that feeds it.
# The published copy belongs in the maintainer's own tap, `schnaq/homebrew-tap`, as
# `Casks/shepherd.rb`; from there `brew install --cask schnaq/tap/shepherd` works. Submitting to
# homebrew-cask proper needs a stable release history first (see docs/RELEASING.md).
#
# Two values change per release. `docs/RELEASING.md § Homebrew` has the two commands that
# produce them:
#
#   version — the release version, without the leading "v"
#   sha256  — shasum -a 256 of the release's DMG asset
#
cask "shepherd" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/schnaq/shepherd/releases/download/v#{version}/Shepherd-#{version}.dmg",
      verified: "github.com/schnaq/shepherd/"
  name "Shepherd"
  desc "Review inbox for pull requests from coding agents"
  homepage "https://github.com/schnaq/shepherd"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Sparkle keeps the installed copy current, so Homebrew should not fight it: `brew upgrade`
  # leaves an app with `auto_updates true` alone unless the cask's version moved.
  auto_updates true
  # ADR 0002: macOS 26 (Tahoe) and Apple Silicon only. A bare symbol already means "this version
  # or newer" in a cask, and `brew style` rewrites `">= :tahoe"` to this; the blank line above it
  # goes for the same reason — the three stanzas are one group.
  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Shepherd.app"

  # The `shepherd` command line (ADR 0013) is a separate build product and is not inside the
  # DMG, so there is no `binary` stanza; the README documents building it. If it is ever copied
  # into the app bundle, add:
  #   binary "#{appdir}/Shepherd.app/Contents/MacOS/shepherd"

  zap trash: [
    "~/Library/Application Support/Shepherd",
    "~/Library/Caches/com.schnaq.shepherd",
    "~/Library/HTTPStorages/com.schnaq.shepherd",
    "~/Library/Preferences/com.schnaq.shepherd.plist",
    "~/Library/Saved Application State/com.schnaq.shepherd.savedState",
  ]

  caveats <<~EOS
    Shepherd keeps everything on this Mac: the local database lives in
    ~/Library/Application Support/Shepherd and your GitHub token lives in the Keychain.
    `brew uninstall --zap --cask shepherd` removes both.
  EOS
end
