#!/usr/bin/env bash
#
# Saves a PNG of every page (light and dark) into ./snapshots, then quits.
# Handy for checking the UI after a change. Requires build/MacMonitor.app
# (run Scripts/build.sh first).

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BIN="$PROJECT_ROOT/build/MacMonitor.app/Contents/MacOS/MacMonitor"
OUT="$PROJECT_ROOT/snapshots"

[[ -x "$APP_BIN" ]] || { echo "Build first: Scripts/build.sh" >&2; exit 1; }
mkdir -p "$OUT"

for mode in light dark; do
    echo "==> Capturing $mode mode…"
    MACMONITOR_SNAPSHOT_DIR="$OUT" MACMONITOR_SNAPSHOT_APPEARANCE="$mode" "$APP_BIN"
done
echo "==> Saved to $OUT"
ls -1 "$OUT"
