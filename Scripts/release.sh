#!/usr/bin/env bash
#
# Shepherd release build (ADR 0010).
#
#   build → sign → DMG → notarize → staple → Sparkle-sign → appcast
#
# One command produces everything a release needs: a notarized, stapled DMG a user can
# double-click, a ZIP of the same stapled app, and an `appcast.xml` whose newest item points at
# this release's DMG and carries its EdDSA signature. Nothing here talks to GitHub — uploading
# the artefacts is the release workflow's job (.github/workflows/release.yml).
#
# Everything is written to `dist/` (override with $RELEASE_DIR).
#
# ── Required environment ──────────────────────────────────────────────────────────────────────
#
#   CODESIGN_IDENTITY          The Developer ID Application identity to sign with, exactly as
#                              `security find-identity -v -p codesigning` prints it, e.g.
#                              "Developer ID Application: Jane Doe (AB12CD34EF)". The team id
#                              alone works too.
#   SPARKLE_PRIVATE_KEY        The base64 EdDSA private key `generate_keys -x` exported. Never
#                              committed; it lives in the login Keychain and in a GitHub secret.
#
#   …plus notarization credentials, either
#
#   NOTARY_KEYCHAIN_PROFILE    The name of a profile stored with
#                              `xcrun notarytool store-credentials` (the local-Mac path), or
#
#   NOTARY_API_KEY_PATH        Path to the App Store Connect `AuthKey_XXXXXXXX.p8` file,
#   NOTARY_API_KEY_ID          its Key ID, and
#   NOTARY_API_ISSUER_ID       the issuer UUID of the App Store Connect team (the CI path).
#
# ── Optional environment ──────────────────────────────────────────────────────────────────────
#
#   SHEPHERD_VERSION           The version this run is expected to produce, without the leading
#                              "v". When set, it is checked against the built app's
#                              CFBundleShortVersionString and a mismatch aborts the release —
#                              this is what stops a `v1.2.0` tag from shipping a 1.1.0 build.
#   RELEASE_DIR                Where the artefacts go. Default: `dist`.
#   BUILD_DIR                  Derived-data path. Default: `.build/release`.
#   SPARKLE_BIN_DIR            Directory holding `sign_update`. Default: found inside BUILD_DIR,
#                              where SwiftPM unpacks Sparkle's binary artefacts.
#   APPCAST_INPUT              A local appcast to extend instead of downloading the published
#                              one. Useful for a dry run and for the very first release.
#   APPCAST_URL                Where to download the current appcast from. Default: the
#                              SUFeedURL baked into the built app.
#   RELEASE_URL_BASE           Prefix for the enclosure URL. Default:
#                              https://github.com/<repo>/releases/download/v<version>
#   GITHUB_REPOSITORY          owner/name, used for the default URLs. Default: schnaq/review.
#   RELEASE_NOTES_FILE         An HTML or plain-text file whose contents become the appcast
#                              item's <description>, i.e. what Sparkle shows in its update
#                              window. Optional.
#   SKIP_NOTARIZATION=1        Sign and package, but do not submit to Apple. For iterating on
#                              this script without spending notarization round-trips.
#   ALLOW_UNSIGNED=1           Build and package with no identity, no notarization and no
#                              Sparkle signature. Produces an *undistributable* DMG and an
#                              appcast with an empty signature, and says so loudly. This is the
#                              mode to use before an Apple Developer account exists: it proves
#                              the whole pipeline runs end to end.
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

# Fails with the fix rather than with the variable name.
require_env() {
    local name=$1
    local hint=$2
    if [[ -z "${!name:-}" ]]; then
        die "\$$name is not set. $hint"
    fi
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "\`$1\` is not on PATH. $2"
}

ALLOW_UNSIGNED=${ALLOW_UNSIGNED:-}
SKIP_NOTARIZATION=${SKIP_NOTARIZATION:-}
GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-schnaq/review}
RELEASE_DIR=${RELEASE_DIR:-$REPO_ROOT/dist}
BUILD_DIR=${BUILD_DIR:-$REPO_ROOT/.build/release}

# ── 1. Preflight ─────────────────────────────────────────────────────────────────────────────

log "Preflight"

[[ "$(uname -s)" == "Darwin" ]] || die "A release can only be built on macOS."
require_tool xcodebuild "Install Xcode and run \`sudo xcode-select -s /Applications/Xcode.app\`."
require_tool xcrun "Install the Xcode command line tools."
require_tool hdiutil "This is part of macOS; something is very wrong."
require_tool plutil "This is part of macOS; something is very wrong."
require_tool python3 "Install the Xcode command line tools (\`xcode-select --install\`)."

if [[ -n "$ALLOW_UNSIGNED" ]]; then
    warn "ALLOW_UNSIGNED is set: the DMG will be unsigned, un-notarized and unusable as an"
    warn "update. Do not publish the result."
else
    require_env CODESIGN_IDENTITY \
        "Run \`security find-identity -v -p codesigning\` and use the \"Developer ID Application: …\" line. See docs/RELEASING.md."
    require_env SPARKLE_PRIVATE_KEY \
        "Export it once with \`generate_keys -x sparkle-private-key.txt\`. See docs/RELEASING.md."
    if [[ -z "$SKIP_NOTARIZATION" ]]; then
        if [[ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
            require_env NOTARY_API_KEY_PATH \
                "Either set \$NOTARY_KEYCHAIN_PROFILE (see \`xcrun notarytool store-credentials\`) or all three of \$NOTARY_API_KEY_PATH, \$NOTARY_API_KEY_ID and \$NOTARY_API_ISSUER_ID."
            require_env NOTARY_API_KEY_ID "Set it alongside \$NOTARY_API_KEY_PATH."
            require_env NOTARY_API_ISSUER_ID "Set it alongside \$NOTARY_API_KEY_PATH."
            [[ -f "$NOTARY_API_KEY_PATH" ]] || die "\$NOTARY_API_KEY_PATH does not point at a file: $NOTARY_API_KEY_PATH"
        fi
    fi
fi

# The web bundle is committed (ADR 0003), so a normal checkout has it; a release must never
# silently ship an app whose diff viewer is missing.
[[ -f "$REPO_ROOT/Shepherd/Resources/DiffViewer/dist/index.html" ]] ||
    die "The Monaco bundle is missing. Run \`npm ci && npm run build\` in web/diff-viewer."

if [[ ! -d "$REPO_ROOT/Shepherd.xcodeproj" ]]; then
    require_tool xcodegen "Install it with \`brew install xcodegen\`."
    log "Generating Shepherd.xcodeproj"
    (cd "$REPO_ROOT" && xcodegen generate)
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shepherd-release.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

# ── 2. Build ─────────────────────────────────────────────────────────────────────────────────

log "Building Shepherd (Release, arm64)"

BUILD_ARGS=(
    -project "$REPO_ROOT/Shepherd.xcodeproj"
    -scheme Shepherd
    -configuration Release
    -destination 'platform=macOS,arch=arm64'
    -derivedDataPath "$BUILD_DIR"
)
if [[ -n "$ALLOW_UNSIGNED" ]]; then
    BUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
else
    # Manual signing with an explicit identity: Developer ID distribution on macOS needs no
    # provisioning profile, and automatic signing on a headless runner would try to talk to
    # Xcode's account store.
    BUILD_ARGS+=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY"
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
        BUILD_ARGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
    fi
fi

(cd "$REPO_ROOT" && xcodebuild "${BUILD_ARGS[@]}" build)

APP="$BUILD_DIR/Build/Products/Release/Shepherd.app"
[[ -d "$APP" ]] || die "xcodebuild reported success but $APP does not exist."

APP_PLIST="$APP/Contents/Info.plist"
read_plist() { plutil -extract "$1" raw -o - "$APP_PLIST" 2>/dev/null || printf ''; }

VERSION=$(read_plist CFBundleShortVersionString)
BUILD_NUMBER=$(read_plist CFBundleVersion)
MIN_SYSTEM=$(read_plist LSMinimumSystemVersion)
FEED_URL=$(read_plist SUFeedURL)
PUBLIC_KEY=$(read_plist SUPublicEDKey)

[[ -n "$VERSION" ]] || die "The built app has no CFBundleShortVersionString."
[[ -n "$BUILD_NUMBER" ]] || die "The built app has no CFBundleVersion."
info "version $VERSION (build $BUILD_NUMBER), minimum macOS $MIN_SYSTEM"

# The one guard that catches the mistake nobody notices until users do: a tag that does not
# match the version in project.yml.
if [[ -n "${SHEPHERD_VERSION:-}" && "$SHEPHERD_VERSION" != "$VERSION" ]]; then
    die "Version mismatch: this run was asked for $SHEPHERD_VERSION but the build is $VERSION. Bump CFBundleShortVersionString in project.yml (and CFBundleVersion), then tag again."
fi

# Sparkle would accept the placeholder in the plist and only fail once a user tried to install
# the download. A release built against it is worse than no release.
if [[ -z "$ALLOW_UNSIGNED" ]]; then
    python3 -c '
import base64, binascii, sys
key = sys.argv[1].strip()
try:
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError
except (ValueError, binascii.Error):
    sys.exit(1)
' "$PUBLIC_KEY" || die "SUPublicEDKey in project.yml is still the placeholder (or not a 32-byte ed25519 key). Paste the public key \`generate_keys\` printed. See docs/RELEASING.md."
fi

# ── 3. Verify the signature xcodebuild produced ──────────────────────────────────────────────
#
# Nothing is re-signed here on purpose. Xcode signs the embedded Sparkle XCFramework and its
# nested helpers (Autoupdate, Updater.app, the XPC services) inside-out as part of the build; a
# `codesign --force` pass over the app afterwards would invalidate that nested code and strip the
# app's entitlements. So this step only checks — and, when a nested helper is unsigned, says
# exactly which one, because that is the failure that otherwise shows up as "the update
# installer quit unexpectedly" months later.

if [[ -z "$ALLOW_UNSIGNED" ]]; then
    log "Verifying code signatures"
    codesign --verify --deep --strict --verbose=2 "$APP"
    SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
        while IFS= read -r nested; do
            [[ -n "$nested" ]] || continue
            codesign --verify --strict "$nested" ||
                die "Sparkle's nested helper is not correctly signed: $nested"
            info "signed: ${nested#"$APP/"}"
        done < <(find "$SPARKLE_FRAMEWORK/Versions" -maxdepth 3 \
            \( -name 'Updater.app' -o -name 'Autoupdate' -o -name '*.xpc' \) 2>/dev/null || true)
    else
        warn "No Sparkle.framework inside the app — in-app updates will not work."
    fi
    codesign --display --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
fi

# ── 4. DMG ───────────────────────────────────────────────────────────────────────────────────
#
# `hdiutil` rather than create-dmg: a plain UDZO image needs no extra dependency and no Finder,
# which matters on a headless self-hosted runner (ADR 0010).

log "Building the DMG"

DMG_NAME="Shepherd-$VERSION.dmg"
DMG="$RELEASE_DIR/$DMG_NAME"
STAGE="$WORK_DIR/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Shepherd.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "Shepherd $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null
info "$DMG_NAME ($(du -h "$DMG" | cut -f1))"

if [[ -z "$ALLOW_UNSIGNED" ]]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi

# ── 5. Notarize & staple ─────────────────────────────────────────────────────────────────────
#
# One submission, of the DMG. It covers the app inside it, so the ticket can then be stapled to
# both — and the DMG is what a user actually downloads and what Gatekeeper checks on first open.
#
# The app *inside* the DMG is therefore not itself stapled (it was copied in before the ticket
# existed); the copy in the ZIP is. That costs nothing in practice — Gatekeeper resolves the
# ticket online, and mounting the stapled DMG caches it locally — and saves a second
# notarization round-trip. Note the order below: stapling rewrites the DMG, so its length and
# its Sparkle signature must be taken afterwards, which is what steps 7 and 8 do.

if [[ -n "$ALLOW_UNSIGNED" || -n "$SKIP_NOTARIZATION" ]]; then
    warn "Skipping notarization. The DMG will be blocked by Gatekeeper on other Macs."
else
    log "Notarizing (this waits for Apple; a few minutes is normal)"

    NOTARY_AUTH=()
    if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
        NOTARY_AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    else
        NOTARY_AUTH=(
            --key "$NOTARY_API_KEY_PATH"
            --key-id "$NOTARY_API_KEY_ID"
            --issuer "$NOTARY_API_ISSUER_ID"
        )
    fi

    # `notarytool submit --wait` exits 0 whenever it *reached* Apple and got an answer — an
    # answer of "Invalid" included. Taken at its exit code alone, a rejected build walks on to
    # the stapler, which then fails with "Record not found" and an error about stapling, for a
    # problem that has nothing to do with stapling. So the verdict is read out of the JSON, and
    # anything but "Accepted" ends the release here, with Apple's own log printed: that log is
    # the only place the actual reason exists, and fetching it afterwards means finding the
    # submission id in a CI log first.
    SUBMISSION="$WORK_DIR/notarization.json"
    xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait --output-format json \
        > "$SUBMISSION" ||
        die "Could not submit to the notary service. Check the credentials and the network."

    # `plutil` reads JSON and ships with macOS, so this needs no `jq` on the runner.
    NOTARY_STATUS=$(/usr/bin/plutil -extract status raw -o - "$SUBMISSION" 2>/dev/null || true)
    NOTARY_ID=$(/usr/bin/plutil -extract id raw -o - "$SUBMISSION" 2>/dev/null || true)

    if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
        warn "Apple did not accept this build: ${NOTARY_STATUS:-unknown}. Its log follows."
        if [[ -n "$NOTARY_ID" ]]; then
            xcrun notarytool log "$NOTARY_ID" "${NOTARY_AUTH[@]}" || true
        fi
        die "Notarization returned ${NOTARY_STATUS:-no status}. Nothing was stapled or published."
    fi

    log "Stapling"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG" ||
        die "The notarization ticket is not attached to the DMG. Do not publish it."
    # The ticket was issued for the app's code directory too, so it can be stapled into the app
    # bundle that goes into the ZIP. Best-effort: the DMG is the artefact that must be stapled.
    xcrun stapler staple "$APP" ||
        warn "Could not staple the .app; the ZIP will need an online Gatekeeper check on first launch."

    # Advisory: `spctl` is what a user's Mac effectively runs, but it is also the step most
    # likely to complain for reasons that have nothing to do with this build (no network, a
    # policy quirk on the runner), so a failure here is loud rather than fatal — `stapler
    # validate` above is the check that decides whether the DMG is publishable.
    log "Gatekeeper assessment (advisory)"
    spctl --assess --verbose=4 --type open --context context:primary-signature "$DMG" ||
        warn "spctl did not accept the DMG. Verify by hand before publishing."
fi

# ── 6. ZIP ───────────────────────────────────────────────────────────────────────────────────
#
# ADR 0010 promises a ZIP alongside the DMG. It is built from the stapled app, after
# notarization, so it carries the ticket too.

log "Building the ZIP"
ZIP_NAME="Shepherd-$VERSION.zip"
ZIP="$RELEASE_DIR/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
info "$ZIP_NAME ($(du -h "$ZIP" | cut -f1))"

# ── 7. Sparkle signature ─────────────────────────────────────────────────────────────────────

log "Signing the update for Sparkle"

find_sparkle_tool() {
    local tool=$1
    if [[ -n "${SPARKLE_BIN_DIR:-}" ]]; then
        [[ -x "$SPARKLE_BIN_DIR/$tool" ]] ||
            die "\$SPARKLE_BIN_DIR is set but $SPARKLE_BIN_DIR/$tool is not executable."
        printf '%s' "$SPARKLE_BIN_DIR/$tool"
        return
    fi
    local found
    found=$(find "$BUILD_DIR/SourcePackages/artifacts" -type f -name "$tool" 2>/dev/null | head -n 1 || true)
    [[ -n "$found" ]] ||
        die "Could not find Sparkle's \`$tool\` under $BUILD_DIR/SourcePackages/artifacts. Set \$SPARKLE_BIN_DIR to the \`bin\` directory of Sparkle's distribution."
    printf '%s' "$found"
}

ED_SIGNATURE=""
DMG_LENGTH=$(stat -f%z "$DMG")
if [[ -n "$ALLOW_UNSIGNED" ]]; then
    warn "No Sparkle signature: the appcast item gets an empty sparkle:edSignature, which no"
    warn "installed Shepherd will accept as an update."
else
    SIGN_UPDATE=$(find_sparkle_tool sign_update)
    info "using ${SIGN_UPDATE#"$REPO_ROOT/"}"
    # The key goes in on stdin: `sign_update -s <key>` is deprecated and rejects keys in the
    # current format, and a key on the command line would show up in `ps`.
    ED_SIGNATURE=$(printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" -p --ed-key-file - "$DMG")
    [[ -n "$ED_SIGNATURE" ]] || die "sign_update produced an empty signature."
    # Prove the signature verifies against the very file that will be uploaded, with the same
    # tool a user's Sparkle will use. Cheap, and it turns "the update silently fails to install"
    # into a failed release build.
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" |
        "$SIGN_UPDATE" --verify --ed-key-file - "$DMG" "$ED_SIGNATURE" ||
        die "The signature sign_update just produced does not verify."
    info "signature verified"
fi

# ── 8. Appcast ───────────────────────────────────────────────────────────────────────────────
#
# The published appcast is fetched and *extended*, never rewritten from scratch: the feed lives
# as an asset of the newest release, so the only copy of the release history is the one that is
# already online. A run that cannot reach it starts a fresh feed and says so.

log "Writing the appcast"

APPCAST="$RELEASE_DIR/appcast.xml"
APPCAST_URL=${APPCAST_URL:-$FEED_URL}
RELEASE_URL_BASE=${RELEASE_URL_BASE:-https://github.com/$GITHUB_REPOSITORY/releases/download/v$VERSION}
PREVIOUS="$WORK_DIR/previous-appcast.xml"

if [[ -n "${APPCAST_INPUT:-}" ]]; then
    [[ -f "$APPCAST_INPUT" ]] || die "\$APPCAST_INPUT does not point at a file: $APPCAST_INPUT"
    cp "$APPCAST_INPUT" "$PREVIOUS"
    info "extending $APPCAST_INPUT"
elif [[ -n "$APPCAST_URL" ]] && curl -fsSL --retry 3 -o "$PREVIOUS" "$APPCAST_URL"; then
    info "extending the published feed at $APPCAST_URL"
else
    : >"$PREVIOUS"
    warn "No published appcast found at ${APPCAST_URL:-<no SUFeedURL>} — starting a new feed."
    warn "That is expected for the first release and a red flag for any later one."
fi

python3 - \
    "$PREVIOUS" \
    "$APPCAST" \
    "$VERSION" \
    "$BUILD_NUMBER" \
    "$MIN_SYSTEM" \
    "$RELEASE_URL_BASE/$DMG_NAME" \
    "$DMG_LENGTH" \
    "$ED_SIGNATURE" \
    "$APPCAST_URL" \
    "${RELEASE_NOTES_FILE:-}" <<'PYTHON'
"""Extend a Sparkle 2 appcast with one new item.

Kept here rather than delegated to `generate_appcast` because that tool derives the whole feed
from a directory of archives: it would need every past DMG on disk to keep the history, and it
would invent enclosure URLs from file names. What we have instead is the previous feed plus one
new archive, which is exactly this.
"""
import os
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

(
    previous_path,
    output_path,
    version,
    build_number,
    minimum_system,
    enclosure_url,
    length,
    signature,
    feed_url,
    release_notes_path,
) = sys.argv[1:11]

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

# How many releases the feed keeps. Sparkle only ever needs the newest item a host qualifies
# for, but keeping a handful makes the feed readable and lets a machine that skipped versions
# see what it skipped.
MAX_ITEMS = 10


def sparkle(name):
    return f"{{{SPARKLE}}}{name}"


def load_channel():
    try:
        with open(previous_path, "rb") as handle:
            data = handle.read()
        if data.strip():
            root = ET.fromstring(data)
            channel = root.find("channel")
            if channel is not None:
                return root, channel
    except ET.ParseError as error:
        raise SystemExit(f"error: the previous appcast is not valid XML: {error}")
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Shepherd"
    ET.SubElement(channel, "description").text = "Shepherd release updates"
    ET.SubElement(channel, "language").text = "en"
    if feed_url:
        ET.SubElement(channel, "link").text = feed_url
    return root, channel


def build_of(item):
    """The item's CFBundleVersion, which is what Sparkle compares."""
    node = item.find(sparkle("version"))
    text = (node.text or "").strip() if node is not None else ""
    return text


root, channel = load_channel()
items = channel.findall("item")

# Republishing the same version is a re-run, not a downgrade: drop the old item and rebuild it.
# A *lower* build number than one already published is always a mistake — Sparkle would offer
# the newer release to everyone forever and the release would look mysteriously inert.
highest = 0
for item in list(items):
    existing = build_of(item)
    if existing == build_number:
        channel.remove(item)
        continue
    try:
        highest = max(highest, int(existing))
    except ValueError:
        pass
try:
    if int(build_number) < highest:
        raise SystemExit(
            f"error: this build is {build_number} but the feed already publishes {highest}. "
            "Bump CFBundleVersion in project.yml."
        )
except ValueError:
    raise SystemExit(f"error: CFBundleVersion {build_number!r} is not a number.")

item = ET.Element("item")
ET.SubElement(item, "title").text = version
ET.SubElement(item, "pubDate").text = formatdate(localtime=False, usegmt=True)
ET.SubElement(item, sparkle("version")).text = build_number
ET.SubElement(item, sparkle("shortVersionString")).text = version
if minimum_system:
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = minimum_system
if release_notes_path and os.path.exists(release_notes_path):
    with open(release_notes_path, encoding="utf-8") as handle:
        ET.SubElement(item, "description").text = handle.read().strip()
ET.SubElement(
    item,
    "enclosure",
    {
        "url": enclosure_url,
        sparkle("edSignature"): signature,
        "length": str(length),
        "type": "application/octet-stream",
    },
)

# Newest first, and only ever MAX_ITEMS of them. The position is recomputed from what is left
# in the tree — the item for this build number may just have been removed above.
remaining = channel.findall("item")
if remaining:
    channel.insert(list(channel).index(remaining[0]), item)
else:
    channel.append(item)
for extra in channel.findall("item")[MAX_ITEMS:]:
    channel.remove(extra)

ET.indent(root, space="    ")
ET.ElementTree(root).write(output_path, encoding="utf-8", xml_declaration=True)
with open(output_path, "a", encoding="utf-8") as handle:
    handle.write("\n")
print(f"    appcast.xml now lists {len(channel.findall('item'))} release(s)")
PYTHON

# ── 9. Done ──────────────────────────────────────────────────────────────────────────────────

log "Release artefacts in ${RELEASE_DIR#"$REPO_ROOT/"}"
# shellcheck disable=SC2012 # these are file names this script chose itself
ls -lh "$RELEASE_DIR" | sed 's/^/    /'

if [[ -n "$ALLOW_UNSIGNED" ]]; then
    warn "Reminder: ALLOW_UNSIGNED was set. These artefacts must not be published."
fi
