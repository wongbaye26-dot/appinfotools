#!/usr/bin/env bash
# macOS runtime smoke: launch the packaged .app and verify it stays alive.
#
# Scope: **startup only**. IPA analysis / report export / file association are
# covered by the Stage E manual acceptance checklist, because driving the native
# save panel and file-open flow reliably on a CI runner is not possible without a
# GUI session. This script deliberately does not claim those checks.
set -euo pipefail

APP="${1:-build/macos/Build/Products/Release/AppInfoTool.app}"
EXE="$APP/Contents/MacOS/AppInfoTool"
if [ ! -x "$EXE" ]; then
  echo "macOS runtime smoke: executable not found: $EXE" >&2
  exit 1
fi

LOG="$(mktemp -t appinfotool-macos-smoke.XXXXXX)"
"$EXE" >"$LOG" 2>&1 &
PID=$!
cleanup() {
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

# 10 seconds is enough for Flutter to create its window on a normal runner.
for _ in $(seq 1 20); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "macOS runtime smoke: app exited during startup" >&2
    cat "$LOG" >&2 || true
    exit 1
  fi
  sleep 0.5
done

if ! kill -0 "$PID" 2>/dev/null; then
  echo "macOS runtime smoke: app is not running after 10s" >&2
  cat "$LOG" >&2 || true
  exit 1
fi

echo "macOS runtime smoke: OK (app stayed alive for 10s; launch-only scope)"
