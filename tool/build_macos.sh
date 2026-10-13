#!/usr/bin/env bash
#
# 构建 macOS 发行版，校验签名，并按项目既有约定打包成 DMG。
#
# 用法：
#   tool/build_macos.sh                # 构建 + 校验签名 + 打包
#   tool/build_macos.sh --no-package   # 只构建与校验，不打包
#
# 前置（缺任何一个都会在开头就报出来，不会跑到一半才失败）：
#   1. 完整 Xcode        —— xcode-select -p 必须指向 Xcode.app
#   2. CocoaPods         —— 本项目有 8 个 macOS 原生插件，必须经 CocoaPods 集成
#   3. Flutter SDK       —— 在 PATH 里，或用 FLUTTER_ROOT 指定
#
# 签名说明见 docs/delivery/macos-build-and-signing.md。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PACKAGE=1
for arg in "$@"; do
  case "$arg" in
    --no-package) PACKAGE=0 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

fail() { printf '\n[✗] %s\n' "$1" >&2; shift; for line in "$@"; do printf '    %s\n' "$line" >&2; done; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    [✓] %s\n' "$1"; }
info() { printf '    [i] %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------------------
step "检查前置条件"

# 定位 Flutter SDK。
#
# 不去要求用户先配好 PATH：绝大多数人装了 SDK 但没把它写进 shell 配置，
# 于是「找不到 flutter」这种与任务无关的报错会挡在最前面。实测踩过一次。
# 这里按「显式指定 → PATH → 常见安装位置」的顺序找，找到就把它的 bin 加进
# PATH —— 这样 `dart` 也会一起可用，两者必须来自同一个 SDK。
FLUTTER_BIN=""
if [ -n "${FLUTTER_ROOT:-}" ] && [ -x "${FLUTTER_ROOT}/bin/flutter" ]; then
  FLUTTER_BIN="${FLUTTER_ROOT}/bin"
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER_BIN="$(cd "$(dirname "$(command -v flutter)")" && pwd)"
else
  for candidate in \
    "$HOME/development/flutter" \
    "$HOME/flutter" \
    "$HOME/fvm/default" \
    "$HOME/.puro/flutter" \
    /opt/homebrew/opt/flutter \
    /usr/local/flutter \
    /opt/flutter
  do
    if [ -x "$candidate/bin/flutter" ]; then FLUTTER_BIN="$candidate/bin"; break; fi
  done
  # fvm / puro 的按版本目录
  if [ -z "$FLUTTER_BIN" ]; then
    for candidate in "$HOME"/fvm/versions/* "$HOME"/.puro/envs/*/flutter; do
      if [ -x "$candidate/bin/flutter" ]; then FLUTTER_BIN="$candidate/bin"; break; fi
    done
  fi
fi

if [ -z "$FLUTTER_BIN" ]; then
  fail "找不到 Flutter SDK" \
       "已查找：\$FLUTTER_ROOT、PATH、~/development/flutter、~/flutter、" \
       "        ~/fvm/default、~/.puro/flutter、/opt/homebrew/opt/flutter" \
       "指定位置再跑：FLUTTER_ROOT=/path/to/flutter tool/build_macos.sh" \
       "还没装的话：https://docs.flutter.dev/get-started/install/macos"
fi
PATH="${FLUTTER_BIN}:${PATH}"; export PATH
ok "flutter $(flutter --version 2>/dev/null | head -1 | awk '{print $2}')  (${FLUTTER_BIN})"

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEV_DIR" in
  */Xcode.app/Contents/Developer) ok "Xcode（${DEV_DIR}）" ;;
  "")
    fail "没有安装 Xcode" \
         "从 App Store 或 https://developer.apple.com/xcode/ 安装完整 Xcode（约 15 GB）" \
         "装好后执行：sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" \
         "            sudo xcodebuild -runFirstLaunch" ;;
  *)
    fail "Xcode 不完整：xcode-select 指向 $DEV_DIR" \
         "那是 Command Line Tools，Flutter 的 macOS 构建需要完整 Xcode" \
         "装好后执行：sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" \
         "            sudo xcodebuild -runFirstLaunch" ;;
esac

if command -v pod >/dev/null 2>&1 && pod --version >/dev/null 2>&1; then
  ok "CocoaPods $(pod --version 2>/dev/null)"
else
  # **不在这里失败。** Flutter 3.47 默认用 Swift Package Manager 集成插件，
  # 只有把 SPM 关掉时才需要 CocoaPods。硬性要求 CocoaPods 会把一条本来能走通的
  # 路堵死 —— 这个脚本的第一版就是这么写的，实测差点拦住一次正常构建。
  cat <<'EOF'

    [i] 没有可用的 CocoaPods。
        Flutter 3.47 默认用 Swift Package Manager（SPM）集成插件。本项目所有
        插件都已确认支持 SPM，因此**不需要** CocoaPods。

        若构建时报「The following plugins do not support Swift Package Manager」，
        说明某个插件（或其传递依赖）的版本太老。先试升级，别急着装 CocoaPods：

            flutter pub upgrade <包名>
            flutter pub get --enforce-lockfile

        （实测踩过一次：screen_retriever_macos 锁在 0.2.0 时不支持 SPM，
          升到 0.2.1+ 即可。）

        升级仍不行时才装 CocoaPods —— 它需要 Ruby >= 3.1，而 macOS 自带的是 2.6：
            brew install cocoapods        # 或先 brew install ruby 再 gem install
EOF
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  fail "xcodebuild 不可用" "先完成上面 Xcode 的安装与 xcode-select 切换"
fi
ok "xcodebuild $(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')"

# ---------------------------------------------------------------------------
# 1. 版本号（与 CI 一致：以 pubspec.yaml 为准）
# ---------------------------------------------------------------------------
VERSION="$(grep -E '^version:' pubspec.yaml | head -1 | awk '{print $2}' | cut -d'+' -f1)"
[ -n "$VERSION" ] || fail "读不到 pubspec.yaml 里的 version"
step "版本：$VERSION"

# ---------------------------------------------------------------------------
# 2. 依赖与代码生成
# ---------------------------------------------------------------------------
step "flutter pub get"
flutter pub get --enforce-lockfile

step "build_runner"
dart run build_runner build --delete-conflicting-outputs

# ---------------------------------------------------------------------------
# 3. 构建
# ---------------------------------------------------------------------------
step "flutter build macos --release"
flutter build macos --release

APP_PATH="build/macos/Build/Products/Release/APP详情工具.app"
[ -d "$APP_PATH" ] || fail "构建产物不存在：$APP_PATH" "构建报告成功但没有产物，请检查上面的输出"
ok "$APP_PATH"

# ---------------------------------------------------------------------------
# 4. 校验签名 —— 这是「注意签名问题」那一条的落点
# ---------------------------------------------------------------------------
step "校验签名"

# 4.1 结构完整性：密封有没有被破坏
if codesign --verify --strict --verbose=4 "$APP_PATH" 2>&1 | sed 's/^/    /'; then
  ok "签名密封完好（codesign --verify --strict 通过）"
else
  fail "签名校验失败" "上面是 codesign 的原话。不要把这个产物发出去。"
fi

# 4.2 签名**种类** —— ad-hoc 与 Developer ID 的可用范围完全不同，
#     必须打印出来，而不是只说一句「已签名」。
SIGN_INFO="$(codesign -d --verbose=4 "$APP_PATH" 2>&1 || true)"
echo "$SIGN_INFO" | grep -E '^(Identifier|TeamIdentifier|Signature|Authority|Sealed Resources)' | sed 's/^/    /' || true

if echo "$SIGN_INFO" | grep -q '^Signature=adhoc'; then
  cat <<'EOF'

    [!] 这是 **ad-hoc 签名**（CODE_SIGN_IDENTITY = "-"）。
        · 在本机（构建它的这台机器）可以直接双击运行。
        · 拷到别的 Mac 会被 Gatekeeper 拦下，对方需要「右键 → 打开」一次，
          或者执行：xattr -d com.apple.quarantine <app>
        · 想要「别人双击就能开」，必须有 Developer ID Application 证书并做公证。
          详见 docs/delivery/macos-build-and-signing.md
EOF
elif echo "$SIGN_INFO" | grep -q '^Authority=Developer ID Application'; then
  ok "Developer ID 签名（可分发；若已公证，别人双击即可打开）"
else
  echo "    [!] 未识别出 ad-hoc / Developer ID，请人工确认上面输出"
fi

# 4.3 权限声明
echo "    权限声明（entitlements）："
codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -E '^\s*\[Key\]' | sed 's/^/      /' || true

# ---------------------------------------------------------------------------
# 5. 打包
# ---------------------------------------------------------------------------
if [ "$PACKAGE" -eq 0 ]; then
  step "跳过打包（--no-package）"
  echo "    .app 位置：$APP_PATH"
  exit 0
fi

# 清掉构建过程中可能带上的本地扩展属性，避免把本机状态打进分发物。
xattr -cr "$APP_PATH" 2>/dev/null || true

DMG_PATH="build/macos/APKInfoTool-${VERSION}.dmg"
rm -f "$DMG_PATH"

if command -v create-dmg >/dev/null 2>&1; then
  step "打包 DMG（create-dmg，与 CI 一致）"
  create-dmg \
    --volname "APP详情工具 ${VERSION}" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon-size 100 \
    --icon "APP详情工具.app" 200 190 \
    --hide-extension "APP详情工具.app" \
    --app-drop-link 600 185 \
    "$DMG_PATH" \
    "$APP_PATH"
  ARTIFACT="$DMG_PATH"
else
  # 没有 create-dmg 就退回 zip。用 ditto 而不是 zip：
  # 它保留符号链接、权限与扩展属性，.app 打包必须这样。
  step "打包 zip（未安装 create-dmg，改用 ditto）"
  ARTIFACT="build/macos/APKInfoTool-${VERSION}.zip"
  rm -f "$ARTIFACT"
  ditto -c -k --keepParent "$APP_PATH" "$ARTIFACT"
fi

step "完成"
echo "    产物：$ARTIFACT"
echo "    大小：$(du -h "$ARTIFACT" | cut -f1)"
