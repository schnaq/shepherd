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

if pgrep -x Shepherd >/dev/null 2>&1; then
    osascript -e 'quit app "Shepherd"' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x Shepherd >/dev/null 2>&1 || break
        sleep 0.25
    done
    pgrep -x Shepherd >/dev/null 2>&1 && pkill -x Shepherd || true
    sleep 0.5
fi

# `open -a <path>`, never `open -b <bundle id>`: a machine can hold several Shepherd builds, and
# Launch Services would otherwise pick one of them — including for `shepherd://` links (ADR 0013).
open -a "$APP"
echo "Launched $APP"
