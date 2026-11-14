#!/usr/bin/env bash
# Launch a sealed-off test copy of Hmunmawi once and confirm that process stays alive (no immediate crash).
#   scripts/launch_smoke.sh [built.app] [seconds]
# It never stops, replaces or signals your real Hmunmawi: the test copy has its own bundle id, data folder and
# in-memory keys (see scripts/fresh-copy.sh), and only that copy's own PID is checked and stopped afterwards.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Hmunmawi.app}"
SEC="${2:-60}"
[[ -d "$APP" ]] || { echo "smoke: missing $APP"; exit 1; }
BASE="${HM_FRESH_DIR:-/tmp/hmsmoke}"
HM_FRESH_DIR="$BASE" "$ROOT/scripts/fresh-copy.sh" "$APP" --reset >/dev/null
BIN="$BASE/HmunmawiFresh.app/Contents/MacOS/Hmunmawi"
env HMUNMAWI_PROFILE=smoke HMUNMAWI_ALLOW_SECOND_INSTANCE=1 CFFIXED_USER_HOME="$BASE/home" HOME="$BASE/home" "$BIN" >"$BASE/smoke.log" 2>&1 &
PID=$!
sleep 3
kill -0 "$PID" 2>/dev/null || { echo "smoke: process exited at once (see $BASE/smoke.log)"; exit 1; }
sleep "$SEC"
kill -0 "$PID" 2>/dev/null || { echo "smoke: process exited within ${SEC}s (see $BASE/smoke.log)"; exit 1; }
kill -TERM "$PID" 2>/dev/null || true
echo "smoke: ok (${SEC}s, test copy pid $PID; real app untouched)"
