#!/usr/bin/env bash
#
# Shepherd for iPhone → TestFlight (ADR 0044).
#
#   archive (Release, generic iOS) → encryption guard → export (app-store-connect) → upload
#
# The iPhone companion is not part of the Mac release (Scripts/release.sh): it has its own
# version (MARKETING_VERSION on the ShepherdPhone target in project.yml), its own build numbers,
# and Apple distributes it, so there is no DMG, no notarization and no appcast. One command
# archives the app and hands it to App Store Connect, where it appears in TestFlight once Apple
# has processed it (a few minutes to an hour). The one-time setup — the Apple account, the App
# Store Connect app record, the tester group — is in docs/RELEASING.md § Shepherd for iPhone.
#
# ── Credentials: one of ──────────────────────────────────────────────────────────────────────
#
#   nothing                    The Apple account signed in to Xcode (Settings → Accounts) is used.
#                              That is the maintainer's-Mac path: Xcode registers the App ID,
#                              creates the profiles and signs with a cloud-managed certificate.
#
#   ASC_API_KEY_PATH           An App Store Connect API key (the CI path): the AuthKey_*.p8 file,
#   ASC_API_KEY_ID             its Key ID and
#   ASC_API_ISSUER_ID          the issuer UUID. The key needs the Admin role: automatic signing
#                              creates a cloud-managed Apple Distribution certificate, which a
#                              Developer-role key (the notarization key) is not allowed to do.
#
# ── Optional environment ─────────────────────────────────────────────────────────────────────
#
#   BUILD_NUMBER               CFBundleVersion. Default: UTC time as yyDDDHHMM, e.g. 262921530 —
#                              always higher than the last one, on any machine, with no git
#                              history needed (a CI checkout is shallow), and below 2^31. One
#                              upload per minute, which is plenty.
#   ALLOW_UNSIGNED=1           Archive without signing, run the encryption guard, and stop. Proves
#                              the build on a machine with no Apple account; uploads nothing.
#   BUILD_DIR                  Derived data and the archive. Default: `.build/testflight`.
#
set -euo pipefail

# ── Plumbing ─────────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

log() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

ALLOW_UNSIGNED=${ALLOW_UNSIGNED:-}
BUILD_DIR=${BUILD_DIR:-$REPO_ROOT/.build/testflight}
BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%y%j%H%M)}
ARCHIVE="$BUILD_DIR/Shepherd-iOS.xcarchive"
EXPORT_OPTIONS="$REPO_ROOT/ShepherdPhone/Support/ExportOptions.plist"

# ── 1. Preflight ─────────────────────────────────────────────────────────────────────────────

log "Preflight"

[[ "$(uname -s)" == "Darwin" ]] || die "An iPhone build can only be made on macOS."
command -v xcodebuild >/dev/null 2>&1 || die "Install Xcode 27 and run \`sudo xcode-select -s /Applications/Xcode.app\`."
xcodebuild -showsdks | grep -q iphoneos ||
    die "This Xcode has no iOS SDK. Install the iOS platform (Xcode → Settings → Components)."
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "BUILD_NUMBER must be digits only, got '$BUILD_NUMBER'."

# An empty array expands to nothing under `set -u` only through the `${…+…}` form below, which
# is what keeps this working with the /bin/bash 3.2 macOS still ships.
AUTH=()
if [[ -n "$ALLOW_UNSIGNED" ]]; then
    warn "ALLOW_UNSIGNED is set: the archive is unsigned and nothing is uploaded."
elif [[ -n "${ASC_API_KEY_PATH:-}" ]]; then
    [[ -f "$ASC_API_KEY_PATH" ]] || die "\$ASC_API_KEY_PATH does not point at a file: $ASC_API_KEY_PATH"
    [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]] ||
        die "Set ASC_API_KEY_ID and ASC_API_ISSUER_ID alongside ASC_API_KEY_PATH. See docs/RELEASING.md."
    AUTH=(-authenticationKeyPath "$ASC_API_KEY_PATH"
        -authenticationKeyID "$ASC_API_KEY_ID"
        -authenticationKeyIssuerID "$ASC_API_ISSUER_ID")
else
    info "No ASC_API_KEY_PATH: signing and uploading as the Apple account signed in to Xcode."
fi

# Regenerated every time rather than only when missing: the project is generated and
# git-ignored, so one left over from an older checkout would archive an older target.
command -v xcodegen >/dev/null 2>&1 || die "Install it with \`brew install xcodegen\`."
(cd "$REPO_ROOT" && xcodegen generate --quiet)

# ── 2. Archive ───────────────────────────────────────────────────────────────────────────────

log "Archiving ShepherdPhone (Release, build $BUILD_NUMBER)"
rm -rf "$ARCHIVE"
ARGS=(
    -project "$REPO_ROOT/Shepherd.xcodeproj"
    -scheme ShepherdPhone
    -configuration Release
    -destination 'generic/platform=iOS'
    -derivedDataPath "$BUILD_DIR"
    -archivePath "$ARCHIVE"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
if [[ -n "$ALLOW_UNSIGNED" ]]; then
    ARGS+=(CODE_SIGNING_ALLOWED=NO)
else
    ARGS+=(-allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"})
fi
xcodebuild "${ARGS[@]}" archive

APP="$ARCHIVE/Products/Applications/Shepherd.app"
[[ -d "$APP" ]] || die "xcodebuild reported success but $APP does not exist."
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Info.plist")
BUILT_NUMBER=$(plutil -extract CFBundleVersion raw -o - "$APP/Info.plist")
[[ "$BUILT_NUMBER" == "$BUILD_NUMBER" ]] ||
    die "The archive says build $BUILT_NUMBER, not $BUILD_NUMBER. Is CFBundleVersion still \$(CURRENT_PROJECT_VERSION) in project.yml?"
info "Archived Shepherd for iPhone $VERSION ($BUILD_NUMBER)"

# ── 3. Export compliance ─────────────────────────────────────────────────────────────────────
#
# On the Release binary, which is the one Apple receives: ITSAppUsesNonExemptEncryption is NO,
# and this checks the system ciphers it imports. The archive is stripped of the symbols it
# defines, so a cipher compiled in from a package is caught by CI's scan of the Debug build
# instead (`check-phone-encryption.sh` says why), not here (ADR 0044).

log "Checking the binary for ciphers"
"$SCRIPT_DIR/check-phone-encryption.sh" "$APP"

if [[ -n "$ALLOW_UNSIGNED" ]]; then
    log "Done (unsigned)"
    info "Archive: $ARCHIVE"
    info "Nothing was uploaded."
    exit 0
fi

# ── 4. Export and upload ─────────────────────────────────────────────────────────────────────
#
# `destination: upload` in ExportOptions.plist makes this one step: Xcode re-signs for App Store
# distribution and sends the build to App Store Connect, dSYMs included.

log "Uploading to App Store Connect"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$BUILD_DIR/export" \
    -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

log "Uploaded Shepherd for iPhone $VERSION ($BUILD_NUMBER)"
info "It shows up in App Store Connect → TestFlight once processing finishes."
