# AppInfoTool 2.10.7 — P1 整改总验收报告

- 起点 commit：`5c4db5a`（`v2.10.6`）
- 终点状态：**未提交工作区**，HEAD 仍为 `5c4db5a`；没有 2.10.7 commit、tag 或 release
- 版本字段：仍为 `2.10.6`（本轮未 bump；NO-GO，不能把当前工作区当成已发布 2.10.7）
- 任务来源：`docs/audit/2026-11-27-module-completeness-audit.md` 的 7 个 P1；用户 2.10.7 任务书
- 最终结论：**NO-GO（不发布）**

## 1. 执行摘要

Stage A–G 已按任务书顺序执行，未一次性修改全部 P1。代码侧回归门禁通过：

| 门禁 | 结果 |
| --- | --- |
| 根 `flutter test` | **1871 passed / 19 skipped / 0 failed** |
| 包测试 | **683 passed**（analysis_model 142、apk_parser 226、ipa_parser 250、archive_safety 40、app_icon_extractor 25） |
| `flutter analyze --fatal-infos --fatal-warnings` | **No issues found** |
| `dart format --output=none --set-exit-if-changed .` | **452 files, 0 changed** |
| `flutter build bundle` | **exit 0** |
| `git diff --check` | **OK** |

但发布仍为 **NO-GO**，核心原因不是静态测试，而是任务书要求的真实证据尚未闭环：

1. 真实样本门禁仍不可作为发布门禁：固定语料 `/Users/wangbaye/Projects/ipa` 只有 **4 IPA / 0 APK**；本轮补用本机 2 个 APK 组成临时混合目录后，真实样本套件 **19 passed / 1 skipped / 0 failed**，证明 Android 代码路径可跑通，但样本目录是 `/tmp` 临时证据，CI 样本源仍未配置，发布环境无同等的可重复语料。
2. 三平台运行验收未完成：macOS 有真实证据；Windows、Linux 未执行。CI 新增的启动级 smoke **尚未在 CI 运行**。
3. Windows 缩略图/安装器只完成代码与文档整改，未在 Windows 真机验收；安装器 `.iss` 未编译。
4. 因此 P1-2、P1-6、P1-7 不能标记为“已通过”。

## 2. P1 对照总表

| P1 | 内容 | 状态 | 主要证据 |
| --- | --- | --- | --- |
| P1-1 | iOS FairPlay 加密识别 | **完成（合成验证）** | `LC_ENCRYPTION_INFO(_64)` 解析；`IOS-ENCRYPTED-BINARY`；`ios.encryption` 覆盖；RULE-F 降级；UI banner；合成 Mach-O + 审计测试 |
| P1-2 | 真实样本 E2E | **部分完成** | 能力选择器、通用 parse/report smoke、发布依赖与 tag 阻断已实现；临时混合语料 19/1/0 通过；CI 样本源与固定语料仍未闭环 |
| P1-3 | Android Artifact Inventory / Load Graph | **完成** | 正式模型字段、报告 JSON、`SecurityEvidenceCard`；v8 schema 原本已定义 keys；真实 APK 导出验证 |
| P1-4 | 覆盖模型纳入截断 | **完成** | `android.artifacts`、`android.payloadProbe`、`android.loadGraph`、`android.nativeLibraries`、`android.splitSampling`；payload cap 真实计数；split 声明总数 |
| P1-5 | 分析页空态/失败态 | **完成（有未执行项）** | `AnalysisPageStatus` 五态、`AnalysisStatePanel`、失败不渲染详情、重试；9 个新测试 |
| P1-6 | 三平台运行验收 | **部分完成** | macOS 实际安装/启动/IPA 分析/导出；Windows/Linux 未执行；CI 启动 smoke 未运行 |
| P1-7 | Windows 缩略图默认行为 | **代码完成，运行未验收** | 默认 false、启动不注册、安装器不注册、设置页显式启用、停用真实确认、README 对齐；无 Windows 真机 |

任务书原则是不把未完成 P1 描述为完成；因此上表的状态是最终口径。

## 3. 各阶段与报告

| 阶段 | 范围 | 报告 |
| --- | --- | --- |
| A | iOS FairPlay | [APPINFOTOOL_2.10.7_STAGE_A_IOS_FAIRPLAY.md](APPINFOTOOL_2.10.7_STAGE_A_IOS_FAIRPLAY.md) |
| B | Android 证据/覆盖 | [APPINFOTOOL_2.10.7_STAGE_B_ANDROID_EVIDENCE.md](APPINFOTOOL_2.10.7_STAGE_B_ANDROID_EVIDENCE.md) |
| C | 分析页状态 | [APPINFOTOOL_2.10.7_STAGE_C_ANALYSIS_STATES.md](APPINFOTOOL_2.10.7_STAGE_C_ANALYSIS_STATES.md) |
| D | 真实样本 E2E | [APPINFOTOOL_2.10.7_STAGE_D_REAL_SAMPLES.md](APPINFOTOOL_2.10.7_STAGE_D_REAL_SAMPLES.md) |
| E | 三平台运行验收 | [APPINFOTOOL_2.10.7_STAGE_E_RUNTIME_ACCEPTANCE.md](APPINFOTOOL_2.10.7_STAGE_E_RUNTIME_ACCEPTANCE.md) |
| F | Windows 缩略图默认 | [APPINFOTOOL_2.10.7_STAGE_F_THUMBNAIL_DEFAULT.md](APPINFOTOOL_2.10.7_STAGE_F_THUMBNAIL_DEFAULT.md) |
| G | 统一回归与发布验收 | 本报告 |

## 4. 关键实现与证据

### P1-1 iOS FairPlay

- `packages/ipa_parser/lib/src/macho.dart`：解析 `LC_ENCRYPTION_INFO` / `LC_ENCRYPTION_INFO_64`，新增 `MachOEncryptionInfo` 与 `MachOImage.encryption`；没有可读命令时保持 `null`，不当作“已确认未加密”。
- `IosPrivacyAudit`：`IOS-RULE-F` 在加密时降为 `unknown` 并使用 `ios.rule_f_encrypted`；新增 `IOS-ENCRYPTED-BINARY` meta finding 与 `ios.encryption` 覆盖；`IOS-SCAN-COVERAGE` 明确密文不可读；crypto-theft 增加 `encryptedBinary` 盲区。
- `lib/ipaparser/ipa_analysis.dart` 暴露 `isMainEncrypted` / `encryptedExecutablePaths`；`info_page` 显示 `SecurityNoticeBanner`；报告 Markdown/JSON 有本地化文本。
- 未执行：真实 FairPlay IPA（语料没有）；只有合成 Mach-O/合成审计测试。

### P1-2 真实样本 E2E

- `test/real_samples_ui_test.dart` 不再用“按文件名排序的第一个 IPA”选择特征样本；改为解析全部 IPA，并按 `toolExecuted`、图标候选/未解析、`ios.nested.truncated` 等**观察到的能力**选择。
- 新增 `test/real_samples_smoke_test.dart`：每个真实样本解析、Markdown 渲染、JSON 解码。
- `.github/workflows/build.yml` 的 `external-samples` 增加 tag 门禁：未配置 `APPINFOTOOL_SAMPLES` 且未显式 `APPINFOTOOL_ALLOW_NO_SAMPLES=1` 时，发布 tag 直接失败；`create-release` 依赖 `external-samples` 成功。
- 实际结果：
  - `APPINFOTOOL_SAMPLES=/Users/wangbaye/Projects/ipa`（4 IPA / 0 APK）：**10 passed / 10 skipped / 0 failed**；`APPINFOTOOL_REQUIRE_SAMPLES=1` 时 **exit 1**，报“缺少 Android 样本”，证明门禁不是静默跳过。
  - 临时混合语料 `/tmp/appinfotool-samples`（4 IPA + 2 个本机 APK，6 文件）：`APPINFOTOOL_REQUIRE_SAMPLES=1` 下 **19 passed / 1 skipped / 0 failed**，真实 Android 解析、详情页、版本对比、报告 JSON/Markdown 均实际执行。
  - 混合语料首次运行暴露了测试夹具的硬编码，而不是产品解析缺陷：Android 版本对比曾要求 `android.permissions` 至少 30 条（实际 10 条），并要求文件名 `hardened.apk`（真实样本名为 `217_0919155004.apk` / `狐...apk`）。已改为按实际样本的权限集合数量比较、按样本 basename 生成对比路径；这是让断言对任意真实 APK 成立，不是放宽到“空集合也算通过”。
- 未执行/未闭环：真实 Android 只覆盖本机 2 个 APK，不是仓库内固定语料；CI 的 `APPINFOTOOL_SAMPLES` 仍未配置；`ios.icon.unresolved` 非空分支仍无真实样本。

### P1-3 Android 证据模型

- `SecurityAnalysisResult` 新增 `ArtifactInventory? artifacts`、`LoadGraph? loadGraph`，并在 `withFinding` / `withLimitation` 中保留。
- `AndroidSecurityAudit.audit` 返回已计算的 inventory/loadGraph；`AnalysisReport` 的 `security.artifacts` / `security.loadGraph` 不再硬编码 `null`。
- v8 schema 原本就声明了这两个 key 及 `$defs`，因此 `reportSchemaVersion` 保持 8，不制造无意义的 schema 版本升级。
- `SecurityEvidenceCard` 展示制品数量/截断、加载链节点/边/悬空边/完整性。
- macOS 上真实 APK 导出 JSON：`security.artifacts.totalEntries=1601`、`inventoriedEntries=17`、`entriesComplete=true`；`security.loadGraph.complete=true`、`nodes=2`、`edges=1`；`jsonschema` 校验 `security` 对象通过。
- 范围限制：inventory 是 base APK ZIP entries；split 的覆盖由 `android.splitSampling` 表达，没有把 split 合并进 inventory。

### P1-4 覆盖截断

- 新增五个维度：`android.artifacts`、`android.payloadProbe`、`android.loadGraph`、`android.nativeLibraries`、`android.splitSampling`。
- payload 调用方 cap 64 以前会隐藏“还有候选”，现在会统计全部候选并设置 `complete=false` / `payload.candidates_skipped`；报告覆盖写 `entriesProbed/entriesTotal`。
- split 报告传入声明的 split 总数与成功审计数，提取 cap 50 不再掩盖未审计的 split。
- 这些是实际 gap 时，`hasActualGaps` 会为 true；没有把无关 limitations 全部转成 gaps。

### P1-5 分析页状态

- `lib/utils/analysis_page_status.dart`：Empty / Loading / Success / Partial / Failure 判定。
- `lib/widgets/analysis_state_panel.dart`：空态、加载态、失败态、部分状态面板与重试。
- `lib/pages/info_page.dart`：失败/加载/空态不再构建 `DetailTabView`，避免满屏 `-`；打开、解析失败、取消、重试清理状态。
- 新增 `test/analysis_page_state_test.dart`：5 个纯状态测试 + 4 个 widget 测试。
- 未执行：真实损坏 APK 触发页面级失败的真实解析 widget 测试。尝试时在 fake-async 下等待解析任务超过 60 秒，已移除；没有用 skip 掩盖。页面失败分支由文件不存在路径和代码审查覆盖。

### P1-6 三平台运行验收

| 平台 | 安装 | 启动 | 分析 | 导出 | 结论 |
| --- | --- | --- | --- | --- | --- |
| macOS | ✅ 复制到 `/Applications`，codesign 通过 | ✅ | ✅ IPA（真实 `sun_signed.ipa`）；额外 APK | ✅ Markdown IPA；✅ JSON Android | 本机实际证据 |
| Windows | ❌ | ❌ | ❌ | ❌ | 未执行 |
| Linux | ❌ | ❌ | ❌ | ❌ | 未执行 |

- macOS 当前构建再次执行：`flutter build macos --release` → 83.1 MB；复制安装、`codesign --verify --deep --strict` OK；`open` 真实 IPA 后日志出现 `fileOpened` 与 `/Users/wangbaye/Projects/ipa/sun_signed.ipa`、hash 计算完成。
- Stage E 的 Markdown/JSON 导出证据保留：
  - Markdown 44,147 bytes，SHA-256 `be8d45b8b060f793399d8cc5508ca31477e06e5cd1a3dc5811b2a4a8b27a030c`
  - JSON 49,388 bytes，SHA-256 `41b8d599ddbed7a8570d09a1daf8f892f35a65352035fcc194c7ffa537cb95df`
- 新增 `tool/runtime_smoke/{macos.sh,linux.sh,windows.ps1}` 与 `tool/runtime_smoke/README.md`；CI 的 Windows/macOS/Linux 构建 job 增加启动级 smoke。**CI 未运行**，且启动 smoke 不等于分析/导出/缩略图/关联/卸载验收。
- 未执行：Windows/Linux 全部运行项；Windows 安装器、缩略图、文件关联、卸载；CI 三平台 smoke。

### P1-7 Windows 缩略图

- `Config.systemIconEnabled` 默认 `false`；启动不再自动注册；安装器删除全部缩略图 `[Registry]` 写入。
- 设置页只有显式点击才启用；停用后按真实注册表状态刷新。未知状态、HKCU 残留、HKLM 残留、失败分别处理，不再假报成功。
- 升级不静默删除旧版 HKCU 注册；README 中英文已说明。
- 测试：`test/system_thumbnail_section_test.dart` 28 passed（新增 5 个诚实性分类测试），`test/system_thumbnail_defaults_test.dart` 守默认 false。
- 未执行：Windows 真机安装/升级、资源管理器缩略图、无管理员权限下 HKLM 清理、安装器编译。

### Stage G 额外发现并修复

发布流程核对发现 `create-release` 的 `if` 只检查了 Windows/macOS/external-samples 成功，**漏了 Linux build 结果**，与 `needs` 不一致：Linux 失败时仍可能进入 release。已在 `.github/workflows/build.yml:899` 加上 `needs.build-linux.result == 'success'`，并用 PyYAML 解析确认 `needs` 四项全部被条件覆盖。这是发布门禁的真实修复，不是文档修饰。

## 5. 修改文件清单

以下不含本地 `.memsearch/` 缓存，也不含被 gitignore 的 `lib/gen/*` 生成文件（本轮已重新生成）。

**修改（32 个）**

```text
.github/workflows/build.yml
README.md
README_en.md
assets/i18n/en.json
assets/i18n/ja.json
assets/i18n/ko.json
assets/i18n/zh-CN.json
assets/i18n/zh-HK.json
assets/i18n/zh-TW.json
lib/apkparser/apk_info.dart
lib/apkparser/parse_task.dart
lib/config.dart
lib/ipaparser/ipa_analysis.dart
lib/main.dart
lib/pages/info_page.dart
lib/pages/setting_page.dart
lib/utils/analysis_report.dart
lib/utils/system_thumbnail.dart
packages/analysis_model/lib/src/security_finding.dart
packages/analysis_model/test/analysis_model_test.dart
packages/apk_parser/lib/src/security/android_security_audit.dart
packages/ipa_parser/lib/src/macho.dart
packages/ipa_parser/lib/src/security/ios_crypto_theft_chain.dart
packages/ipa_parser/lib/src/security/ios_privacy_audit.dart
test/analysis_coverage_test.dart
test/analysis_report_test.dart
test/coverage_note_registration_test.dart
test/ios_detail_page_test.dart
test/ios_privacy_audit_test.dart
test/real_samples_ui_test.dart
test/system_thumbnail_section_test.dart
windows/installer/appinfotool.iss
```

**新增**

```text
docs/audit/APPINFOTOOL_2.10.7_STAGE_A_IOS_FAIRPLAY.md
docs/audit/APPINFOTOOL_2.10.7_STAGE_B_ANDROID_EVIDENCE.md
docs/audit/APPINFOTOOL_2.10.7_STAGE_C_ANALYSIS_STATES.md
docs/audit/APPINFOTOOL_2.10.7_STAGE_D_REAL_SAMPLES.md
docs/audit/APPINFOTOOL_2.10.7_STAGE_E_RUNTIME_ACCEPTANCE.md
docs/audit/APPINFOTOOL_2.10.7_STAGE_F_THUMBNAIL_DEFAULT.md
docs/audit/APPINFOTOOL_2.10.7_P1_REMEDIATION_ACCEPTANCE.md（本报告）
lib/utils/analysis_page_status.dart
lib/widgets/analysis_state_panel.dart
lib/widgets/security_evidence_card.dart
lib/widgets/security_notice_banner.dart
packages/ipa_parser/test/macho_encryption_test.dart
test/analysis_page_state_test.dart
test/real_samples_smoke_test.dart
test/security_evidence_card_test.dart
test/system_thumbnail_defaults_test.dart
tool/runtime_smoke/README.md
tool/runtime_smoke/linux.sh
tool/runtime_smoke/macos.sh
tool/runtime_smoke/windows.ps1
```

原有只读审计报告 `docs/audit/2026-11-27-module-completeness-audit.md` 仍在工作区，未修改。

## 6. 实际执行命令与结果

```text
~/development/flutter/bin/flutter test
→ 1871 passed / 19 skipped / 0 failed

packages/analysis_model: 142 passed
packages/apk_parser: 226 passed
packages/ipa_parser: 250 passed
packages/archive_safety: 40 passed
packages/app_icon_extractor: 25 passed

~/development/flutter/bin/flutter analyze --fatal-infos --fatal-warnings
→ No issues found

~/development/flutter/bin/dart format --output=none --set-exit-if-changed .
→ 452 files, 0 changed

~/development/flutter/bin/flutter build bundle
→ exit 0

APPINFOTOOL_SAMPLES=/Users/wangbaye/Projects/ipa \
  flutter test test/real_samples_test.dart test/real_samples_ui_test.dart test/real_samples_smoke_test.dart
→ 10 passed / 10 skipped / 0 failed

APPINFOTOOL_REQUIRE_SAMPLES=1 APPINFOTOOL_SAMPLES=/Users/wangbaye/Projects/ipa \
  flutter test test/real_samples_smoke_test.dart
→ exit 1（刻意失败：缺少 Android 样本；证明发布门禁不是静默跳过）

APPINFOTOOL_REQUIRE_SAMPLES=1 APPINFOTOOL_SAMPLES=/tmp/appinfotool-samples \
  flutter test test/real_samples_test.dart test/real_samples_ui_test.dart test/real_samples_smoke_test.dart
→ 19 passed / 1 skipped / 0 failed（临时混合语料：4 IPA + 2 APK）

flutter build macos --release
→ ✓ Built .../AppInfoTool.app (83.1MB)

bash tool/runtime_smoke/macos.sh build/macos/Build/Products/Release/AppInfoTool.app
→ macOS runtime smoke: OK (app stayed alive for 10s; launch-only scope)

git diff --check
→ OK
```

## 7. 未执行项与剩余限制

1. **真实 Android E2E 已在临时语料执行，但未进入可重复门禁**：`/Users/wangbaye/Projects/ipa` 仍是 4 IPA / 0 APK；`/tmp/appinfotool-samples` 的 4 IPA + 2 APK 跑通 19/1/0，但目录不在仓库、CI 未配置样本源。
2. **真实 FairPlay IPA 未执行**：语料没有加密 IPA；只有合成测试。
3. **“图标存在但未解析”真实分支未执行**：现有 4 个 IPA 的未解析图标列表为空，测试显式 skip。
4. **Windows 全链路未执行**：安装、升级、启动、APK 分析、报告导出、缩略图、文件关联、卸载。
5. **Linux AppImage 未执行**：启动、APK 分析、报告导出。
6. **CI 未运行**：Stage D/E 修改的 workflow 与新增启动 smoke 未在 GitHub Actions 实际执行；三个平台的 job 未验证。
7. **Windows 安装器未编译**：`windows/installer/appinfotool.iss` 的修改只做了静态检查，需 Windows Inno Setup 编译。
8. **Windows 缩略图运行行为未验收**：启用/停用、HKLM 清理、Explorer 显示均未实机验证。
9. **真实损坏 APK 的页面级失败 widget 测试未执行**：在 fake-async 下挂起超过 60 秒，已移除；页面状态由纯函数测试、文件不存在路径与代码审查覆盖。
10. **Stage E 报告导出证据来自 Stage E 构建**；Stage G 当前构建重新验证了安装/启动/IPA 打开，但没有重新执行完整导出流程。
11. **版本未 bump**：`pubspec`、CHANGELOG、tag 仍为 2.10.6；本轮没有 2.10.7 发布物。

## 8. 遗留 P2/P3（不阻塞本轮 P1 结论，但不能忽略）

- iOS CodeResources v1 对裸 `PlistData` 仍会静默跳过；iOS 官方基线仍为 0 条；iOS 调用点分析仍不是数据流分析。
- 真实样本覆盖：固定语料 0 APK；本机临时语料 2 APK 已跑通；仍无 FairPlay、无未解析图标样本，无法证明官方/CI 全链路。
- 性能基线：IPA 峰值 RSS 436–526 MB，缺 profile 模式堆分析。
- UI 可访问性仍弱：0 个 Semantics、部分按钮无可访问名称、无 TextScaler 覆盖。
- 诊断文案本地化 14/57；ja/ko 仍有历史缺失键（本轮新增键已补齐，不等于全量补齐）。
- APKS `toc.pb` 字段仍缺真实 `.apks` 验证；安装取消仍只杀本地 adb client；HKCU 文件关联清理不完整。
- README_en 规则数、CHANGELOG/tag 对齐、死代码 `riverpod_utils.dart` 等既有 P2/P3 未处理。
- Windows 缩略图/文件关联的历史机器级注册、路径不一致等边界仍未真机验证。

## 9. 发布建议：NO-GO

代码侧门禁全绿，但发布前置条件未满足：

1. **真实样本门禁仍不可重复**：本机临时混合语料已跑通，但固定语料与 CI 样本源仍未配置；发布环境无同等的可验证语料。
2. **三平台运行验收未完成**：Windows/Linux 全部未执行。
3. **Windows 缩略图与安装器未真机验收**。
4. **CI 未实际运行**；新增启动 smoke 与 workflow 条件只是静态验证。
5. 当前没有 2.10.7 commit/tag；按任务书不得自动发布。

### GO 的前置条件

1. 提供可重复的 Android 样本源（本机已用 2 个 APK 验证；需放进固定目录或 CI 变量），让 `APPINFOTOOL_REQUIRE_SAMPLES=1` 的样本门禁在发布环境真实通过；或在 Release 说明中显式记录 `APPINFOTOOL_ALLOW_NO_SAMPLES=1` 豁免及其风险。
2. 在 Windows 完成安装/启动/APK 分析/导出/缩略图/关联/卸载验收。
3. 在 Linux 完成 AppImage 启动/APK 分析/导出验收。
4. 在 CI 实际运行 Windows/macOS/Linux 构建与启动 smoke，确认 `create-release` 四个依赖全部生效。
5. 完成 Windows 安装器编译与缩略图真机验收。
6. 人工确认后创建 2.10.7 commit/tag/release；本轮不自动执行。

## 10. 结论

- Stage A–G 的代码、测试、文档整改已落地，静态质量门禁通过。
- P1-1、P1-3、P1-4、P1-5 有完成证据；P1-2 的本地临时混合语料已 19/1/0 通过，但固定语料/CI 样本源仍未闭环；P1-6、P1-7 仍有真实环境缺口，不能标记为全部完成。
- 当前工作区 **不是** 可发布版本；发布结论 **NO-GO**。
- 未创建 commit、未移动 tag、未发布 Release。
