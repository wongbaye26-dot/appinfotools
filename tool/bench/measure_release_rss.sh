#!/usr/bin/env bash
# 测量 AOT 发布包的解析内存（macOS）。
#
# 为什么需要它：`tool/bench/bench_parse_test.dart` 跑在 flutter_tester（JIT），
# 它的 RSS 不能代表发布包。这里启动真实的 Release .app，通过 Finder 的
# open-file 事件让它解析同一个包，采样进程 RSS。
#
# 用法：tool/bench/measure_release_rss.sh <App.app> <sample.apk> [idle-seconds]
set -euo pipefail

APP="${1:?用法: $0 <App.app> <sample.apk> [idle-seconds]}"
SAMPLE="${2:?缺少样本路径}"
IDLE="${3:-6}"

if [ ! -d "$APP" ]; then echo "找不到 app: $APP" >&2; exit 1; fi
if [ ! -f "$SAMPLE" ]; then echo "找不到样本: $SAMPLE" >&2; exit 1; fi

EXEC_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")"
BIN="$APP/Contents/MacOS/$EXEC_NAME"

# 干净启动：先退出旧实例，等它真的消失，避免复用已解析状态或采到旧进程。
pkill -f "$BIN" 2>/dev/null || true
for _ in $(seq 1 25); do
  pgrep -f "$BIN" >/dev/null 2>&1 || break
  sleep 0.2
done
open -n "$APP"
sleep "$IDLE"

# 取最新实例：`open -n` 会另起进程，旧实例可能仍在（缓存会让 RSS 偏低）。
COUNT="$(pgrep -f "$BIN" | wc -l | tr -d ' ')"
if [ "$COUNT" != "1" ]; then echo "实例数异常：$COUNT（期望 1）" >&2; exit 1; fi
# 取最新实例：`open -n` 会另起进程，旧实例可能仍在（缓存会让 RSS 偏低）。
PID="$(pgrep -f "$BIN" | sort -n | tail -1 || true)"
if [ -z "$PID" ]; then echo "进程未启动" >&2; exit 1; fi

idle_rss="$(ps -o rss= -p "$PID" | tr -d ' ')"
echo "idle_rss_kb=$idle_rss"

# 通过 file-open 事件触发解析（等价于 Finder 双击）。
open -a "$APP" "$SAMPLE"

peak="$idle_rss"
for _ in $(seq 1 100); do
  rss="$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ' || true)"
  [ -z "$rss" ] && break
  [ "$rss" -gt "$peak" ] && peak="$rss"
  sleep 0.2
done

echo "peak_rss_kb=$peak"
echo "delta_kb=$((peak - idle_rss))"
