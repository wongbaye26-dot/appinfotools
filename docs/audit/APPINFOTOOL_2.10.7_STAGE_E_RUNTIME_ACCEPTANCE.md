# AppInfoTool 2.10.7 — Stage E 三平台运行验收（P1-6）

- 日期：2026-11-27
- 起点 commit：`5c4db5a`（2.10.6）
- 终点 commit：`5c4db5a`（Stage E 未提交；工作区含 Stage A–E 未提交修改）
- 目标版本：2.10.7（尚未改版本号，应用内仍显示 2.10.6）
- 状态：**P1-6 部分完成，Stage E 不能判定通过；发布建议 NO-GO**
- 授权：用户 m03168 “继续”，仅执行 Stage E；任务书 m01674 要求每阶段等待人工验收

## 1. 结论先行

| 平台 | 安装 | 启动 | 分析 | 报告导出 | 其他 P1-6 项 | 结论 |
|---|---|---|---|---|---|---|
| macOS | ✅ 复制安装，codesign 校验通过 | ✅ | ✅ IPA；额外验证 APK | ✅ Markdown IPA；✅ JSON Android | 文件打开事件 ✅ | 本机可复现通过 |
| Windows | ❌ 未执行 | ❌ 未执行 | ❌ 未执行 | ❌ 未执行 | 缩略图/关联/卸载未执行 | **未验收** |
| Linux | ❌ 未执行 | ❌ 未执行 | ❌ 未执行 | ❌ 未执行 | AppImage 未执行 | **未验收** |

- 本机为 macOS，Windows/Linux 没有可用机器；本次**没有**伪造这两个平台的运行结果。
- 已为三个平台增加 CI **启动级**门禁，但 CI 尚未运行；启动通过也不等于分析/导出/缩略图/关联/卸载通过。
- 因此 P1-6 只能标记为**部分完成**，Stage E 不能作为“三平台验收完成”接受；按任务书发布原则，当前为 **NO-GO**。

## 2. 环境与产物

- 主机：`Darwin wangbayedeMacBook-Air.local 27.3.0 arm64`，macOS 27.3。
- 构建：`~/development/flutter/bin/flutter build macos --release`
  - 输出：`✓ Built build/macos/Build/Products/Release/AppInfoTool.app (83.1MB)`
- 安装方式：macOS 应用按惯例复制到 `/Applications`（未使用 DMG 挂载安装）：
  ```bash
  ditto build/macos/Build/Products/Release/AppInfoTool.app \
    /Applications/AppInfoTool-acceptance.app
  ```
  为避免覆盖本机原有的 `/Applications/AppInfoTool.app`，使用独立的 `AppInfoTool-acceptance.app`。
  记录完证据后已退出应用并删除该验收副本；构建产物仍在 `build/macos/Build/Products/Release/AppInfoTool.app`。
- 签名：`codesign --verify --deep --strict` 退出码 0；`codesign -dv` 显示 `Signature=adhoc`、`flags=0x2(adhoc)`、`valid on disk`、`satisfies its Designated Requirement`。这是 ad-hoc 签名，**不是** Developer ID 公证签名，不能据此声称可绕过 Gatekeeper 分发。

## 3. macOS 实际验收

### 3.1 启动与 IPA 文件打开

命令：

```bash
open -a "/Applications/AppInfoTool-acceptance.app" \
  /Users/wangbaye/Projects/ipa/sun_signed.ipa
```

- 应用进程启动并保持运行。
- 应用调试日志（`~/Library/Application Support/to.feng.app.apkinfotool.apkInfoTool/debug.log`）记录：
  - `_setupFileAssociationHandler: call.method=fileOpened`
  - `_buildMoreMenuButton: state.filePath=/Users/wangbaye/Projects/ipa/sun_signed.ipa`
  - `[PERF] computeFileHashes: 354ms (3 isolates, file read 3×)`
- 概览页显示：`sun_signed.ipa`、名称 `SUN`、Bundle ID `com.overall.sun`、版本 `v1.8.3 (183)`、平台 iOS、大小 `40.5MB`、签名 `验证失败`、安全 `17 项发现`。
- 详情页显示「应用信息」「文件信息」及 6 个标签；安全页「分析覆盖」显示 9 个维度、7 完成、2 缺口，并显示 `ios.nested.truncated: only the first 24 of 27 nested bundles were parsed`。
- 该样本未加密，因此没有出现 FairPlay 加密提示，符合预期；**本轮没有真实 FairPlay IPA**，加密 UI 分支仍只有合成样本测试证据。

### 3.2 Markdown 报告导出

- 通过「更多」→「导出解析报告」，在原生保存面板选择 Markdown、完整报告。
- 由于本机未授予屏幕录制权限，`screencapture` 失败（`could not create image from display` / `could not create image from window`）；改用 macOS Accessibility：
  - 对 Flutter 应用设置 `AXManualAccessibility` 后原生 AX 树才暴露按钮/文本；
  - `AXEnhancedUserInterface` 返回 `-25208`，不可用；
  - 保存面板为 `AXSheet`，目录 `ios-samples-20261105`，通过 `AXTextField` 填文件名后点击 `Save`。
- 导出文件：
  - 路径：`/Users/wangbaye/Projects/ios-samples-20261105/AppInfoTool-2.10.7-stage-e-report.md`
  - 大小：**44,147 bytes**
  - SHA-256：`be8d45b8b060f793399d8cc5508ca31477e06e5cd1a3dc5811b2a4a8b27a030c`
  - 内容：656 行；包含 `SUN`、`com.overall.sun`、`v1.8.3`、签名验证失败、17 项发现，以及 `IOS-RULE-D-ESCALATED`、`IOS-CRYPTO-THEFT-RISK`、`IOS-REPACKAGED`。
- 未单独导出该 IPA 的 JSON；JSON 导出在同一次运行中用 Android APK 验证（见 3.3）。

### 3.3 额外证据：macOS 上 APK 分析与 JSON 导出

P1-6 Windows/Linux 要求 APK 分析，macOS 额外验证同一套分析/导出链路：

```bash
open -a "/Applications/AppInfoTool-acceptance.app" \
  "/Users/wangbaye/Downloads/217_0919155004.apk"
```

- 日志：`[PERF] getApkInfo(builtin): total=300ms | ... audit=17`。
- 界面：Android 平台，应用名 `天⑄美`，包名 `com.rLWwwGuBbHicPiou.LMoMGx6edKHQP9Jv`。
- JSON 导出：
  - 路径：`/Users/wangbaye/Projects/ios-samples-20261105/AppInfoTool-2.10.7-stage-e-android.json`
  - 大小：**49,388 bytes**
  - SHA-256：`41b8d599ddbed7a8570d09a1daf8f892f35a65352035fcc194c7ffa537cb95df`
  - `reportSchemaVersion: 8`；`security` 含 `cryptoTheft, artifacts, loadGraph, seal, baseline`。
  - `security.artifacts`: `totalEntries=1601`、`inventoriedEntries=17`、`entriesComplete=true`、`skippedCodes=[]`。
  - `security.loadGraph`: `complete=true`、`danglingEdgeIds=[]`、`nodes=2`、`edges=1`。
  - 覆盖维度包含 Stage B 新增项：`android.artifacts` covered、`android.payloadProbe` partial、`android.loadGraph` covered、`android.nativeLibraries` covered、`android.splitSampling` notApplicable。
- 用 `python3 jsonschema` 以 Draft 2020-12 校验 `doc['security']` 对 `docs/contracts/crypto-theft-security-v8.schema.json`：**OK**。
  - 注意：该 schema 只描述报告里的 `security` 对象，不是整份报告；整份报告校验失败是预期行为，不能当作缺陷。

## 4. Windows 验收（未执行）

本机没有 Windows 主机，也没有可用 Windows runner 的交互式桌面；以下全部**未执行**：

- 安装器安装、开始菜单启动。
- APK 分析、Markdown/JSON 报告导出。
- Explorer 缩略图显示/停用/启用。
- `.apk` 文件关联与「打开方式」。
- 静默卸载及注册表/安装目录清理。

已提供 `tool/windows_install_smoke.ps1`（安装/注册表/卸载）与 `tool/runtime_smoke/README.md` 中的完整手动清单；CI 只增加了便携 zip 的**启动级**门禁，且本轮未运行 CI。不能把 CI 计划中的步骤写成“已验收”。

## 5. Linux 验收（未执行）

本机为 macOS，没有 Linux 主机或已构建的 AppImage；以下全部**未执行**：

- AppImage 启动（含无 FUSE 的 `APPIMAGE_EXTRACT_AND_RUN=1` 路径）。
- APK 分析。
- Markdown/JSON 报告导出。

已新增 `tool/runtime_smoke/linux.sh`，在 Xvfb 下做**启动级**检查；CI 步骤尚未运行。

## 6. CI 门禁变更（已写，未运行）

`.github/workflows/build.yml`：

- Windows：Create ZIP 后新增 `Runtime smoke (portable package, launch only)`，解压便携 zip 并用 `tool/runtime_smoke/windows.ps1` 启动 10 秒。
- macOS：Verify DMG 后新增 `Runtime smoke (launch only)`，用 `tool/runtime_smoke/macos.sh` 启动 `.app` 10 秒。
- Linux：apt 增加 `xvfb`；AppImage 构建后新增 `Runtime smoke (AppImage launch only)`，在 Xvfb 下启动 10 秒。
- `create-release` 仍依赖 `build-windows`、`build-macos`、`build-linux`、`external-samples`；因此这些 build job 中的启动 smoke 会成为发布依赖。
- 校验：PyYAML 解析通过；`git diff --check` 通过；`bash -n` 检查 macOS/Linux 脚本通过。
- macOS 启动脚本已本机实际运行：输出 `macOS runtime smoke: OK (app stayed alive for 10s; launch-only scope)`。
- **CI 未触发、未运行**；Windows PowerShell 脚本语法在本机无法用 PowerShell 解析，属未验证项。

## 7. P1-6 对照

| 要求 | 状态 | 证据/缺口 |
|---|---|---|
| Windows 安装/启动/APK/导出/缩略图/关联/卸载 | ❌ 未执行 | 无 Windows 环境；仅计划中的 CI 启动门禁 |
| macOS 安装/启动/IPA/导出 | ✅ 本机通过 | 复制安装、codesign、open IPA、Markdown 导出 |
| Linux AppImage/APK/导出 | ❌ 未执行 | 无 Linux 环境；仅计划中的 CI 启动门禁 |
| 适当 CI 运行门禁 | 🟡 已添加未运行 | 三平台启动 smoke；不覆盖分析/导出/缩略图/关联/卸载 |
| 未执行项如实记录 | ✅ | 本文第 4/5/6 节 |

**P1-6 结论：部分完成，不能标记为完成。**

## 8. 本阶段静态回归（Stage E 改动后重跑）

Stage E 只改脚本、workflow 和文档，没有改 Dart 代码；仍在本机重跑以下门禁：

| 命令 | 结果 |
|---|---|
| `~/development/flutter/bin/flutter test` | **1865 pass / 19 skip / 0 fail**；19 个 skip 中 16 个为未设置 `APPINFOTOOL_SAMPLES` 的真实样本用例，其余为平台相关跳过 |
| `~/development/flutter/bin/flutter analyze --fatal-infos --fatal-warnings` | **No issues found** |
| `~/development/flutter/bin/dart format --output=none --set-exit-if-changed .` | **451 files, 0 changed** |
| `git diff --check` | 无空白错误 |
| `python3 -c 'yaml.safe_load(...)'` | workflow YAML 解析通过 |
| `bash -n tool/runtime_smoke/{macos,linux}.sh` | 通过 |
| `tool/runtime_smoke/macos.sh build/.../AppInfoTool.app` | **OK**（本机启动 10 秒） |

未在本机重跑：`flutter build bundle`（Stage E 没有 Dart 改动；Stage D 最后一次为 exit 0）、全部 package tests（Stage E 没有 package 改动；Stage D 最后为 683 pass）。这些必须在 Stage G 重新执行。

## 9. 文件与工作区

Stage E 新增/修改（未提交）：

- 修改：`.github/workflows/build.yml`
- 新增：`tool/runtime_smoke/macos.sh`
- 新增：`tool/runtime_smoke/linux.sh`
- 新增：`tool/runtime_smoke/windows.ps1`
- 新增：`tool/runtime_smoke/README.md`
- 新增：本报告

Stage E 没有修改 Dart 生产代码；Stage A–D 的未提交修改仍在工作区。

## 10. 未执行项与风险

- Windows 全部运行验收未执行。
- Linux 全部运行验收未执行。
- CI 三平台启动 smoke 未运行；Windows 脚本语法未在本机 PowerShell 验证。
- macOS DMG 安装流程未执行（用 `.app` 复制安装替代）。
- macOS IPA JSON 导出未单独执行（Markdown 已导出；JSON 用 Android 样本验证）。
- 本机屏幕录制权限缺失，界面证据来自 Accessibility 树 + 导出文件，不是截图。
- 应用内版本仍显示 2.10.6；2.10.7 版本号尚未提升。

## 11. 发布建议

**NO-GO。**

理由：

1. P1-6 的 Windows/Linux 运行验收未完成。
2. P1-2 真实样本门禁仍未真正绿：无 Android 样本，CI 样本路径未配置；当前只能显式豁免，不能作为发布证据。
3. P1-7（Windows 缩略图默认行为）尚未实施，Stage F 未开始。
4. 尚未执行最终 Stage G 全量回归与发布流程验证。

在 Windows/Linux 真实桌面完成 `tool/runtime_smoke/README.md` 清单、提供真实样本或明确豁免、并完成 Stage F/G 之前，不应移动 tag 或发布 2.10.7。

## 12. 人工验收请求

请确认：

- 是否接受“macOS 本机通过、Windows/Linux 明确未执行”的 Stage E 部分验收状态；
- 是否继续 Stage F（Windows 缩略图默认关闭/启用行为统一）；
- Windows/Linux 是否有可用机器，或需要在 CI 触发后补验收证据。

在收到确认前，不进入 Stage F，不提交、不打 tag、不发布。
