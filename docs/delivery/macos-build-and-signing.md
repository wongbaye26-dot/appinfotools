# macOS 打包与签名说明

> 本文只讲**已经核实的事实**与**可执行的命令**。凡未在本机验证过的，都明确标注。

## 1. 结论先说

| 你想做什么 | 需要什么 | 当前状态 |
|---|---|---|
| 在**构建它的这台机器**上运行 | **什么都不需要**（ad-hoc 签名即可） | ✅ 工程已配好 |
| 拷给**别的 Mac** 运行 | 不需要证书，但对方要「右键 → 打开」一次 | ⚠️ 可用，但体验差 |
| **正式分发**（别人双击就能开） | **Developer ID Application 证书** + **公证（notarization）** | ❌ 本机 0 个签名身份 |

本机实测：`security find-identity -v -p codesigning` → **0 valid identities found**。
也就是说除了 ad-hoc，做不了别的签名。

## 2. 当前工程里的签名配置（已核实）

`macos/Runner.xcodeproj/project.pbxproj`：

```
CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;
"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";     <- ad-hoc
CODE_SIGN_STYLE = Automatic;
```

`-` 就是 **ad-hoc 签名**：Xcode 用本机生成的临时身份签，不需要任何证书。
这是 Flutter 模板的默认值，也是**本地开发与自用**的正确选择。

`macos/Runner/Release.entitlements` 声明了三条权限：

| 权限 | 为什么需要 |
|---|---|
| `com.apple.security.app-sandbox` | 启用沙盒（分发的前提） |
| `com.apple.security.files.user-selected.read-write` | 读用户选中的 APK/IPA |
| `com.apple.security.network.client` | 下载 aapt2 / apksigner 需要出站网络 |

### 沙盒带来的两个真实约束（首次签名构建后需要实测确认）

1. **只能读用户显式选中的文件**。通过文件选择器、拖放、或 Finder「打开方式」
   进来的文件会获得沙盒扩展，可以读；**通过命令行参数传入的路径不行**。
   `lib/main.dart` 里的 `apkByArgs`（命令行参数）在沙盒下拿不到权限 ——
   从 Finder 双击、拖放、选择文件这三条路不受影响。
2. **下载的工具必须落在沙盒容器内**。已核实：`ToolPaths.appSupportDir` 用的是
   `getApplicationSupportDirectory()`（`path_provider_foundation`），而 macOS 在
   沙盒下会把 `~/Library/Application Support/<bundle-id>` **自动重定向到容器内**
   （`~/Library/Containers/<bundle-id>/Data/...`），所以默认路径是安全的。
   但 `Config.downloadDir` 若被用户设成**容器外的绝对路径**，写入会被沙盒拒绝 ——
   设置界面应当对这种情况给出提示。**这一条尚未实测**（本机无法构建），
   首次出包后应当专门验证一次。

## 3. 构建命令

```sh
tool/build_macos.sh                # 构建 + 校验签名 + 打包 DMG
tool/build_macos.sh --no-package   # 只构建与校验
```

脚本会：检查 Xcode / CocoaPods → 同步版本号（取自 `pubspec.yaml`）→
`pub get --enforce-lockfile` → `build_runner` → `flutter build macos --release`
→ **`codesign --verify --strict` 校验密封** → **打印签名种类**（ad-hoc 还是
Developer ID）→ 打包（有 `create-dmg` 就出 DMG，否则用 `ditto` 出 zip）。

产物：`build/macos/APKInfoTool-<版本>.dmg`，与 CI 的约定一致。

## 4. 前置安装（一次性）

```sh
# 1. 完整 Xcode（约 15 GB，从 App Store 或 developer.apple.com 安装）
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch

# 2. 打包 DMG 用（可选，没有就退回 zip）
brew install create-dmg
```

`flutter doctor` 里 Xcode 那一项应当变成 `[✓]`。

### 4.1 插件集成：Swift Package Manager 优先，CocoaPods 是退路

本项目有 8 个 macOS 原生插件。**Flutter 3.47 默认用 Swift Package Manager（SPM）
集成它们，因此通常不需要 CocoaPods。** `tool/build_macos.sh` 不再把缺少
CocoaPods 当成错误，只在缺少时打印说明。

什么时候才真的需要 CocoaPods：构建时看到
`Adding Swift Package Manager integration` 之后失败。那时：

```sh
sudo gem install cocoapods      # 权限受限时：brew install cocoapods
```

**注意**：CocoaPods 需要 Ruby >= 3.1，而 macOS 自带的系统 Ruby 是 2.6 ——
在系统 Ruby 上装不上（`securerandom` 等依赖会拒绝安装；即使钉住版本装到
1.16.2，运行时也会因 `activesupport` 报 `uninitialized constant Logger` 而失败）。
需要先有 Ruby 3（`brew install ruby` 或 rbenv）。

## 5. 如果要正式分发

### 5.1 需要的材料

1. **Apple Developer Program** 会员（个人/公司，99 美元/年）。
2. **Developer ID Application 证书**（不是 "Apple Development"，也不是
   "Mac App Distribution"）—— 在 developer.apple.com 或 Xcode 的
   Settings → Accounts → Manage Certificates 里创建。
3. 证书导入本机钥匙串后，`security find-identity -v -p codesigning` 应当能看到它。

### 5.2 改动点

把 `macos/Runner.xcodeproj/project.pbxproj` 里 Runner 目标的 Release 配置改成：

```
CODE_SIGN_IDENTITY = "Developer ID Application";
CODE_SIGN_STYLE = Manual;
DEVELOPMENT_TEAM = <你的 10 位 Team ID>;
```

（或者留在 Xcode 里用 GUI 选，避免手改 pbxproj。）

### 5.3 公证

```sh
# 用 app-specific password 或 API Key，不要用 Apple ID 密码
xcrun notarytool submit build/macos/APKInfoTool-<版本>.dmg \
  --apple-id <你的 Apple ID> --team-id <Team ID> --password <app-specific-password> \
  --wait

# 公证通过后把票据装订到分发物上，别人离线也能验证
xcrun stapler staple build/macos/APKInfoTool-<版本>.dmg
```

验证：

```sh
spctl -a -vvv -t install build/macos/APKInfoTool-<版本>.dmg   # 应当 accepted / Notarized
```

### 5.4 CI 现状：**没有任何签名或公证步骤**

`.github/workflows/build.yml` 的 `build-macos` 任务只做
`flutter build macos --release` + `create-dmg`，**没有** `codesign`（用 Developer ID）
也**没有** `notarytool`。因此 CI 产出的 DMG 里装的是 **ad-hoc 签名、未公证**的 app，
用户下载后会被 Gatekeeper 拦下，需要「右键 → 打开」。

这不是缺陷，而是一个**需要明确决策的点**：

- 如果这个工具只自己用 / 给同事用 —— 现状够用，但要在下载页写清楚安装方法。
- 如果要公开分发 —— 必须补上 5.2 与 5.3，并把证书与密码放进 GitHub Secrets。

## 6. 未验证的部分

| 项目 | 状态 |
|---|---|
| `tool/build_macos.sh` 的完整流程 | **未执行** —— 本机无 Xcode / CocoaPods，脚本只验证到「前置检查」这一步（已确认它能正确报出缺什么） |
| 沙盒下的文件访问与工具下载 | **未执行** —— 需要首次签名构建后实测（见 2 的两条约束） |
| Developer ID 签名与公证 | **未执行** —— 本机 0 个签名身份 |
| DMG 在别的 Mac 上的打开体验 | **未执行** —— 需要第二台机器 |
| 完整的 `flutter build macos --release` | **未执行** —— 见 6.1 |

### 6.1 为什么这个仓库里没有产出 .app

在自动化执行环境里跑不通，两条路都被堵住，且**都与工程本身无关**：

| 路径 | 阻塞点 | 实测证据 |
| --- | --- | --- |
| SPM（默认） | 执行环境限制嵌套沙箱 | `swift package resolve` 报 `sandbox-exec: sandbox_apply: Operation not permitted`；`sandbox-exec -p '(allow default)'` 能过、严格 profile 被拒 |
| CocoaPods（退路） | 系统 Ruby 2.6 太老 | 钉住版本装到 1.16.2 后仍报 `uninitialized constant ActiveSupport::LoggerThreadSafeLevel::Logger` |

**在普通终端里不受此限制** —— 直接执行：

```sh
tool/build_macos.sh
```

