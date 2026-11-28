#!/usr/bin/env bash
# Linux runtime smoke: launch the AppImage under Xvfb and verify it stays alive.
#
# Scope: **startup only**. APK analysis / report export are covered by the Stage E
# manual acceptance checklist. A CI runner has no interactive desktop, so this
# script must not claim those checks.
set -euo pipefail

APPIMAGE="${1:-}"
if [ -z "$APPIMAGE" ] || [ ! -f "$APPIMAGE" ]; then
  echo "usage: $0 <path-to-AppImage>" >&2
  exit 1
fi
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "linux runtime smoke: xvfb-run is required (install xvfb)" >&2
  exit 1
fi

# xvfb-run / setsid 可能改变工作目录或解析相对路径；先固定为绝对路径。
APPIMAGE="$(cd "$(dirname "$APPIMAGE")" && pwd)/$(basename "$APPIMAGE")"
chmod +x "$APPIMAGE"
LOG="$(mktemp -t appinfotool-linux-smoke.XXXXXX)"
# AppImage may not have FUSE on a CI runner; extract-and-run is the supported
# fallback and still executes the packaged AppImage payload.
# --wait：setsid 在部分环境会 fork 后立即退出，必须等子进程，否则
# `kill -0 $PID` 会把「setsid 已退出」误判为「AppImage 退出」。
setsid --wait xvfb-run -a env APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGE" >"$LOG" 2>&1 &
PID=$!
cleanup() {
  if kill -0 "$PID" 2>/dev/null; then
    kill -- "-$PID" 2>/dev/null || kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

for _ in $(seq 1 20); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "linux runtime smoke: AppImage exited during startup" >&2
    tail -40 "$LOG" >&2 || true
    # annotation 对匿名可读；job 日志匿名 403，失败原因不能只留在日志里。
    reason=$(tail -20 "$LOG" 2>/dev/null | tr '\n' '|' | head -c 1800)
    echo "::error title=Linux AppImage 启动失败::${reason}"
    exit 1
  fi
  sleep 0.5
done

echo "linux runtime smoke: OK (AppImage stayed alive for 10s; launch-only scope)"
