#!/usr/bin/env bash
# 重新生成两个图标夹具（`icon-png.apk` / `icon-adaptive.apk`）。
#
# 为什么用脚本而不是手拼字节：手拼样本会带着与解析器相同的错误假设，
# 等于自证。这两个夹具是 **aapt2 link 的真实产物**，`resources.arsc` 与
# 二进制 XML 都由官方工具生成。
#
# 依赖：
#   - Android SDK build-tools（aapt2）
#   - 任一 Android platform 的 android.jar
#   - macOS 的 sips（只用于缩放图片）
#
# 用法：
#   tool/make_icon_fixtures.sh [--aapt2 PATH] [--android-jar PATH]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AAPT2="${AAPT2:-$HOME/Library/Android/sdk/build-tools/36.1.0/aapt2}"
ANDROID_JAR="${ANDROID_JAR:-$HOME/Library/Android/sdk/platforms/android-34/android.jar}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --aapt2) AAPT2="$2"; shift 2 ;;
    --android-jar) ANDROID_JAR="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

for f in "$AAPT2" "$ANDROID_JAR"; do
  [[ -f "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 两个 manifest：包名不同，便于在日志里区分是哪一个产物。
write_manifest() {
  local path="$1" package="$2" label="$3"
  cat > "$path" <<MANIFEST
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$package"
    android:versionCode="1"
    android:versionName="1.0">
  <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="34" />
  <application android:label="$label" android:icon="@mipmap/ic_launcher" />
</manifest>
MANIFEST
}

write_manifest "$WORK/AndroidManifest.xml" com.example.iconfixture "Icon Fixture"
write_manifest "$WORK/AndroidManifest-alt.xml" com.example.iconfixturealt "Icon Fixture Alt"

# ---- 1. PNG 图标 ----
mkdir -p "$WORK/res/mipmap-hdpi"
cp "$REPO_ROOT/assets/image/icon.png" "$WORK/res/mipmap-hdpi/ic_launcher.png"
sips -z 72 72 "$WORK/res/mipmap-hdpi/ic_launcher.png" >/dev/null
"$AAPT2" compile --dir "$WORK/res" -o "$WORK/png.zip"
"$AAPT2" link -o "$REPO_ROOT/test/fixtures/apk/icon-png.apk" \
  -I "$ANDROID_JAR" --manifest "$WORK/AndroidManifest.xml" "$WORK/png.zip"

# ---- 2. 自适应图标（只有 XML，没有位图）----
mkdir -p "$WORK/res2/mipmap-anydpi-v26" "$WORK/res2/drawable" "$WORK/res2/values"
cp "$REPO_ROOT/assets/image/icon.png" "$WORK/res2/drawable/ic_foreground.png"
sips -z 108 108 "$WORK/res2/drawable/ic_foreground.png" >/dev/null
cat > "$WORK/res2/mipmap-anydpi-v26/ic_launcher.xml" <<'ADAPTIVE'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@color/ic_launcher_background" />
  <foreground android:drawable="@drawable/ic_foreground" />
</adaptive-icon>
ADAPTIVE
cat > "$WORK/res2/values/colors.xml" <<'COLORS'
<?xml version="1.0" encoding="utf-8"?>
<resources><color name="ic_launcher_background">#FF223344</color></resources>
COLORS
"$AAPT2" compile --dir "$WORK/res2" -o "$WORK/adaptive.zip"
"$AAPT2" link -o "$REPO_ROOT/test/fixtures/apk/icon-adaptive.apk" \
  -I "$ANDROID_JAR" --manifest "$WORK/AndroidManifest.xml" "$WORK/adaptive.zip"

# ---- 3. 第二个 PNG 图标（内容与 #1 不同）----
#
# 用途：验证**规格 2.4 的第一条验收项** —— 两个内容不同的 APK 必须显示
# 不同的图标。CI 里比的是解码后的像素哈希，因此这两个包的图标必须真的
# 不一样：这里旋转 180° 并放大到 96px，xhdpi 档。
mkdir -p "$WORK/res3/mipmap-xhdpi"
cp "$REPO_ROOT/assets/image/icon.png" "$WORK/res3/mipmap-xhdpi/ic_launcher.png"
sips -r 180 -z 96 96 "$WORK/res3/mipmap-xhdpi/ic_launcher.png" >/dev/null
"$AAPT2" compile --dir "$WORK/res3" -o "$WORK/alt.zip"
"$AAPT2" link -o "$REPO_ROOT/test/fixtures/apk/icon-png-alt.apk" \
  -I "$ANDROID_JAR" --manifest "$WORK/AndroidManifest-alt.xml" "$WORK/alt.zip"

echo "generated:"
ls -l "$REPO_ROOT/test/fixtures/apk/icon-png.apk" \
      "$REPO_ROOT/test/fixtures/apk/icon-png-alt.apk" \
      "$REPO_ROOT/test/fixtures/apk/icon-adaptive.apk"
