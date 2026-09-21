#!/usr/bin/env bash
#
# Put the Developer ID identity into a keychain the release build can actually use,
# on a self-hosted runner, and leave nothing behind (ADR 0010, docs/RELEASING.md).
#
# ── Why this exists ───────────────────────────────────────────────────────────────────────────
#
# The obvious arrangement — import the certificate into the runner user's login keychain once,
# by hand — does not work, and fails in a way that reads like a permissions bug. A GitHub
# runner installed with `svc.sh` is a **LaunchAgent**, so it runs in that user's Aqua session.
# A keychain's unlocked state lives in `securityd` per security session, and an
# `unlock-keychain` typed over SSH unlocks it for the SSH session only. The runner's session
# still sees it locked, `codesign` cannot reach the private key, and every signing command dies
# with the opaque `errSecInternalComponent` — after a full Release build, twenty minutes in.
#
# So the keychain is created *inside the job*, in the runner's own session, from a `.p12` that
# travels as a secret. The machine then holds no signing material at all: nothing to install on
# a new runner, nothing to re-unlock after a reboot, and nothing left over if the job is
# cancelled (the workflow's `if: always()` cleanup removes it).
#
# ── What it reads ─────────────────────────────────────────────────────────────────────────────
#
# From the environment, which the workflow fills in from repository secrets (Infisical is the
# source of truth and syncs them there):
#
#   MACOS_DEVID_CERT_P12_BASE64   base64 of the Developer ID Application .p12 (certificate *and*
#                                 private key — export both together, see docs/RELEASING.md)
#   MACOS_DEVID_CERT_PASSWORD     the password that .p12 was exported with
#
# ── What it writes ────────────────────────────────────────────────────────────────────────────
#
#   $RUNNER_TEMP/signing_identity        the certificate's SHA-1, for CODESIGN_IDENTITY
#   $RUNNER_TEMP/signing_keychain        the keychain's path, for the cleanup step
#   $RUNNER_TEMP/orig-default-keychain   what the default keychain was, so it can be restored
#
# The SHA-1 rather than the identity's name on purpose, and for the reason `mise.toml`'s `qa`
# task already records for the development certificate: a name is resolved against the whole
# search list, and it resolves wrong or ambiguously often enough to be worth never relying on.
#
# `Scripts/release.sh` is not touched by any of this. It reads `CODESIGN_IDENTITY` from the
# environment and knows nothing about Infisical or CI — which is what keeps it runnable on a
# maintainer's own Mac, exactly as docs/RELEASING.md promises.
set -euo pipefail

: "${RUNNER_TEMP:?must run on a GitHub runner (RUNNER_TEMP is unset)}"
: "${MACOS_DEVID_CERT_P12_BASE64:?missing — expected from Infisical}"
: "${MACOS_DEVID_CERT_PASSWORD:?missing — expected from Infisical}"
echo "::add-mask::$MACOS_DEVID_CERT_PASSWORD"

keychain="$RUNNER_TEMP/release-signing.keychain-db"
keychain_password="$(openssl rand -base64 24)"

security create-keychain -p "$keychain_password" "$keychain"
# Six hours, and no lock on sleep: a notarization round trip can idle for a quarter of an hour,
# and a keychain that relocks mid-build is this script's original bug in a new costume.
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"

# Tolerated rather than required, and the `|| true` is load-bearing under `set -euo pipefail`:
# a runner registered as a *daemon* has no Aqua session, therefore no login keychain, therefore
# no default one, and `security` exits non-zero saying so. That is a fact about how the runner
# was installed and not a reason to refuse to sign — this value exists only so the cleanup step
# can put back what was there, and "there was nothing" restores just as faithfully as a path.
# The cleanup already reads it with a fallback and swallows its own failure.
security default-keychain -d user 2>/dev/null | tr -d ' "' > "$RUNNER_TEMP/orig-default-keychain" || true

# Rebuild the search list with this keychain first and everything that was there after it.
#
# Read the *effective* list (no `-d user`) rather than the user domain: the user domain does not
# include `/Library/Keychains/System.keychain`, so rebuilding from it would silently drop the
# keychain where a CI Mac keeps Apple's intermediate certificates — and `codesign` needs those
# to build leaf → Developer ID CA → Apple Root. Stale entries from an earlier run are pruned and
# System.keychain is appended once, so it can neither vanish nor appear twice.
previous="$(security list-keychains | tr -d '"' \
  | grep -v 'release-signing\.keychain-db$' \
  | grep -v '^[[:space:]]*/Library/Keychains/System\.keychain$' || true)"
# shellcheck disable=SC2086  # deliberate word splitting: one argument per keychain
security list-keychains -d user -s "$keychain" $previous /Library/Keychains/System.keychain
security default-keychain -s "$keychain"

p12="$RUNNER_TEMP/devid.p12"
printf '%s' "$MACOS_DEVID_CERT_P12_BASE64" | base64 --decode > "$p12"
security import "$p12" -k "$keychain" -P "$MACOS_DEVID_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/xcodebuild
rm -f "$p12"

# Authorise the two tools to use the private key without asking. Naming them in `security
# import -T` has not been enough since macOS 10.12; the partition list is the part that counts,
# and without it `codesign` wants a dialog no headless runner can answer.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$keychain_password" "$keychain" >/dev/null

# `find-identity -v` lists only identities whose chain reaches a trusted anchor, so this is also
# the chain check: a .p12 exported without its intermediate fails here, in a step that takes two
# seconds and says what to do, rather than as `errSecInternalComponent` after the build.
identity="$(security find-identity -v -p codesigning "$keychain" \
  | awk '/Developer ID Application/ { print $2; exit }')"
if [ -z "$identity" ]; then
  echo "::error::No valid Developer ID Application identity in the release keychain."
  echo "::error::The .p12 imported, but nothing in it is usable for signing. Either it carries"
  echo "::error::only the certificate or only the private key — Keychain Access exports just one"
  echo "::error::unless both are selected — or its chain to the Apple root cannot be built."
  echo "::error::Re-export with the certificate AND its key selected, then update"
  echo "::error::MACOS_DEVID_CERT_P12_BASE64 in Infisical. See docs/RELEASING.md."
  echo "Identities in the keychain (listed even when invalid):"
  security find-identity -p codesigning "$keychain" || true
  exit 1
fi

printf '%s' "$identity" > "$RUNNER_TEMP/signing_identity"
printf '%s' "$keychain" > "$RUNNER_TEMP/signing_keychain"
echo "Signing ready: Developer ID identity $identity in $keychain"
