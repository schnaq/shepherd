#!/usr/bin/env bash
# Screenshots of Shepherd on sample data, without touching the installed app.
#
#   Scripts/demo-screenshots.sh [output-dir]      (default: .build/screenshots)
#   mise run demo-screenshots [output-dir]
#
# Launches the *Debug* build in its demo mode (`Shepherd/Debug/DemoMode.swift`, compiled out of
# Release): a seeded, signed-in-looking session whose database, settings and Keychain live in a
# scratch directory, a separate defaults suite and memory, and which never talks to the network.
# One launch per screen and appearance, because the screen is chosen with `-ShepherdDemoOpen
# <shepherd://…>` rather than `open shepherd://…`: the installed app shares the bundle id, and
# LaunchServices would pick which of the two running copies receives a URL.
#
# Needs Screen Recording permission for the terminal that runs it (System Settings → Privacy &
# Security). Without it `screencapture` writes an image of the desktop wallpaper, not the window.
#
# Environment:
#   SHEPHERD_DEMO_DERIVED_DATA  derived-data path of the Debug build (default: this checkout's
#                          .build/app, where `mise run build` puts it). Deliberately not
#                          SHEPHERD_DD_APP: a shell that activated mise in another checkout carries
#                          that one's path, and the script would launch a build without the demo.
#   SHEPHERD_DEMO_REBUILD  1 to rebuild even when a Debug build exists
#   SHEPHERD_DEMO_SETTLE   seconds to wait after the window appears (default: 4)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.build/screenshots}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
DD="${SHEPHERD_DEMO_DERIVED_DATA:-$ROOT/.build/app}"
APP="$DD/Build/Products/Debug/Shepherd.app"
TOOLS="$ROOT/.build/demo-tools"
SETTLE="${SHEPHERD_DEMO_SETTLE:-4}"

# ── Build ─────────────────────────────────────────────────────────────────────────────────────

if [ ! -d "$APP" ] || [ "${SHEPHERD_DEMO_REBUILD:-0}" = "1" ]; then
    echo "Building the Debug app into $DD …"
    # xcodegen rewrites Info.plist and the build rewrites the string catalogs; put back whatever
    # was clean before, so running this script never leaves a diff behind.
    GENERATED=(Shepherd/Support/Info.plist Shepherd/Resources/Localizable.xcstrings
               Shepherd/Resources/AppShortcuts.xcstrings)
    CLEAN=()
    for file in "${GENERATED[@]}"; do
        if git -C "$ROOT" diff --quiet -- "$file"; then CLEAN+=("$file"); fi
    done
    (cd "$ROOT" && xcodegen generate --quiet)
    xcodebuild -project "$ROOT/Shepherd.xcodeproj" -scheme Shepherd -configuration Debug \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
        CODE_SIGNING_ALLOWED=NO build -quiet
    if [ "${#CLEAN[@]}" -gt 0 ]; then git -C "$ROOT" checkout -- "${CLEAN[@]}"; fi
fi

# A build without the demo mode would ignore the flag and open the *real* installation — database,
# Keychain, Sparkle — so refuse to launch one. The marker is the demo's own argument name.
if ! grep -rqa -- "-ShepherdDemoOpen" "$APP/Contents/MacOS"; then
    echo "error: $APP has no demo mode (an old or Release build?). Rebuild with SHEPHERD_DEMO_REBUILD=1." >&2
    exit 1
fi

if [ ! -f "$ROOT/Shepherd/Resources/DiffViewer/dist/index.html" ]; then
    echo "note: the diff viewer bundle is not built (mise run viewer); the review screen will use the line list." >&2
fi

# ── The window finder ─────────────────────────────────────────────────────────────────────────

# `screencapture -l` wants a window number. CGWindowList has it, filtered by the demo's PID so the
# installed Shepherd — same name, same bundle id — can never be the one captured.
mkdir -p "$TOOLS"
if [ ! -x "$TOOLS/window-id" ] || [ "$0" -nt "$TOOLS/window-id" ]; then
    cat > "$TOOLS/window-id.swift" <<'SWIFT'
import CoreGraphics
import Foundation

// window-id <pid> largest|front — prints the number of that process's on-screen, normal-level
// window: the largest one (the main window), or the frontmost one (a window just brought up).
let arguments = CommandLine.arguments
guard arguments.count == 3, let pid = Int(arguments[1]) else { exit(2) }
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
let windows = info.compactMap { window -> (id: Int, area: Double)? in
    guard window[kCGWindowOwnerPID as String] as? Int == pid,
          window[kCGWindowLayer as String] as? Int == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: Double],
          let width = bounds["Width"], let height = bounds["Height"], width >= 400, height >= 300,
          let id = window[kCGWindowNumber as String] as? Int
    else { return nil }
    return (id, width * height)
}
let pick = arguments[2] == "front" ? windows.first : windows.max { $0.area < $1.area }
guard let pick else { exit(1) }
print(pick.id)
SWIFT
    swiftc -O -o "$TOOLS/window-id" "$TOOLS/window-id.swift"
fi

# ── One screenshot ────────────────────────────────────────────────────────────────────────────

PID=""
cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

# shoot <name> <shepherd:// link> <largest|front> <light|dark> [KEY=value for the app's environment]
shoot() {
    local name="$1" link="$2" which="$3" appearance="$4" extra="${5:-SHEPHERD_DEMO_EXTRA=}"
    local style="Light"
    [ "$appearance" = "dark" ] && style="Dark"
    local before
    before="$(pgrep -f "$APP/Contents/MacOS/Shepherd" || true)"

    # `-n`: a new process even though the installed Shepherd (same bundle id) may be running.
    # `-ApplePersistenceIgnoreState`: saved window state is kept per bundle id, so without it the
    # demo would restore — and on quit overwrite — the installed app's.
    open -n -a "$APP" --env "SHEPHERD_DEMO_APPEARANCE=$appearance" --env "$extra" --args \
        -ShepherdDemo YES -ShepherdDemoOpen "$link" \
        -ApplePersistenceIgnoreState YES -AppleInterfaceStyle "$style"

    PID=""
    for _ in $(seq 1 100); do
        for candidate in $(pgrep -f "$APP/Contents/MacOS/Shepherd" || true); do
            if ! grep -qx "$candidate" <<<"$before"; then PID="$candidate"; fi
        done
        [ -n "$PID" ] && break
        sleep 0.1
    done
    if [ -z "$PID" ]; then echo "error: the demo app did not start" >&2; exit 1; fi

    local window=""
    for _ in $(seq 1 150); do
        window="$("$TOOLS/window-id" "$PID" "$which" || true)"
        [ -n "$window" ] && break
        sleep 0.1
    done
    if [ -z "$window" ]; then echo "error: no window appeared for $name" >&2; exit 1; fi

    # The seed, the deep link and the diff viewer's first paint all land after the window does.
    sleep "$SETTLE"
    # The front window may have changed while settling (Settings opens after the main window).
    window="$("$TOOLS/window-id" "$PID" "$which" || echo "$window")"
    screencapture -o -x -l "$window" "$OUT/$name-$appearance.png"
    echo "$OUT/$name-$appearance.png"

    kill "$PID" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    # The next launch wipes the scratch directory; a demo that ignored the polite signal must not
    # still be writing into it then. Only ever this run's own PID — never the installed app.
    kill -9 "$PID" 2>/dev/null || true
    PID=""
}

# A sleeping display makes `screencapture` fail with "could not create image from window". Keep it
# awake for the length of the run.
caffeinate -d -u -w $$ &

for appearance in light dark; do
    shoot inbox "shepherd://inbox" largest "$appearance"
    shoot review "shepherd://pr/schnaq/shepherd/412" largest "$appearance"
    shoot review-files "shepherd://pr/schnaq/shepherd/412" largest "$appearance" \
        SHEPHERD_DEMO_REVIEW_TAB=files
    shoot issues "shepherd://inbox?filter=issues" largest "$appearance"
    shoot settings-delegation "shepherd://settings/delegation" front "$appearance"
done
