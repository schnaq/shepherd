#!/usr/bin/env bash
# Relaunches a freshly built Shepherd.app, killing the instance that is already running.
#
# `open` on a bundle whose process is already running only brings that process forward — the old
# binary, silently — so a rebuild-and-look loop can spend rounds looking at the build before last.
# The running app is therefore asked to quit, given a moment, and killed if it did not go. Nothing
# is lost either way: drafts and the inbox live in the local database (ADR 0006).
#
# Called by `mise run start` and `mise run qa-start`, which differ only in which build they point
# at. A script rather than the same fifteen lines in both tasks: mise has no way to share a shell
# snippet between two `run` blocks, and `Scripts/` is where this repository already keeps the
# commands its tasks call.
set -euo pipefail

APP="${1:?usage: relaunch-app.sh <path to Shepherd.app>}"
[[ -d "$APP" ]] || { echo "No app bundle at $APP — build it first." >&2; exit 1; }

# Only this build's own processes, matched by executable path. `pkill -x Shepherd` matches by
# name, and a Mac can have two: the dev-signed QA build kept open for a live-account session and
# the unsigned one from `mise run start`. Killing the wrong one costs somebody their signed-in
# window for an errand that had nothing to do with it.
executable="$APP/Contents/MacOS/Shepherd"
running_pids() {
    # `|| true` twice over: `pgrep` exits 1 when nothing matches, and under `set -o pipefail`
    # that would end the script at the very moment there is nothing to do.
    { pgrep -x Shepherd 2>/dev/null || true; } | while read -r pid; do
        [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == "$executable" ]] && echo "$pid"
    done
}

pids=$(running_pids || true)
if [[ -n "$pids" ]]; then
    # AppleScript only when this build is the *only* Shepherd running: `quit app "Shepherd"`
    # cannot be aimed, and it is the gentler of the two — the app gets to finish what it was
    # doing. Otherwise the matched processes are asked directly.
    all_shepherds=$(pgrep -cx Shepherd 2>/dev/null || echo 0)
    if [[ "$all_shepherds" == "$(echo "$pids" | grep -c . || true)" ]]; then
        osascript -e 'quit app "Shepherd"' >/dev/null 2>&1 || true
    else
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null || true
    fi
    for _ in $(seq 1 20); do
        [[ -z "$(running_pids)" ]] && break
        sleep 0.25
    done
    remaining=$(running_pids || true)
    if [[ -n "$remaining" ]]; then
        # shellcheck disable=SC2086
        kill -KILL $remaining 2>/dev/null || true
    fi
    sleep 0.5
fi

# `open -a <path>`, never `open -b <bundle id>`: a machine can hold several Shepherd builds, and
# Launch Services would otherwise pick one of them — including for `shepherd://` links (ADR 0013).
open -a "$APP"
echo "Launched $APP"
