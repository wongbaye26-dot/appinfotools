# AppInfoTool 2.10.6 模块完成度审计报告

- 审计日期：2026-11-27
- 审计对象：`5c4db5a chore(release): 2.10.6`（工作区干净）
- 版本：2.10.6
- 性质：**只读审计**。未修改生产代码、未提交、未发布；本报告是唯一新增文件。
- 结论口径：完成度回答「这个东西是否按产品承诺完整可用」，不回答「检测准确率是多少」。

---

## 0. 结论摘要

### 0.1 总评

**综合完成度：86 / 100（功能完整度 87，工程交付完整度 80）。**

这是一个已经可以日常使用、核心链路真实跑通的产品，不是演示项目：

- APK / XAPK / APKM / APKS 与 IPA 的纯 Dart 解析、图标、差异对比、报告导出、adb 安装、Windows 文件关联/缩略图都有实现和测试。
- 静态安全检测已形成「能力 → 来源 → 注入 → 载荷 → 家族」五段链，报告 schema v8，证据分级、覆盖范围、局限说明齐全。
- 本机门禁全绿：根测试 **1,843 通过 / 16 跳过**，5 个 package 共 **677 通过**；`flutter analyze --fatal-infos --fatal-warnings` 无问题；`dart format` 428 文件无改动；`flutter build bundle` 成功。
- 2.10.6 的 GitHub Release 与 CI 都存在且成功。

但「门禁绿」不等于「交付完整」。本次审计发现：

- **没有 P0**；
- **7 个 P1**：其中 1 个会直接给出误导性的安全结论（iOS 加密包），2 个让「真实样本 / 三平台产物验收」实际上没有守住，2 个让已经算出来的证据没有进入报告/界面，1 个是分析页失败态缺失，1 个是 Windows 缩略图默认行为与文档/同意相反；
- **一批 P2**：i18n 缺口、可访问性、Windows 安装残留、XAPK/APKS 密封、iOS 图标和基线、发布脚本细节等；
- **P3**：文档数字、变更日志、死代码、测试覆盖盲区。

### 0.2 与 2.9.0 审计相比

`docs/audit/2026-11-09-security-confidence-audit.md` 的 4 个 P1（Unicode 维度标签、Unicode/动态加载说明本地化、RULE-F 在截断 DEX 上仍给 confirmed）已在 2.10.2 修复并有测试守卫，本次复核确认修复有效。

本次分数没有比 2.9.0 更高，**不是功能倒退**，而是审计范围更宽、证据更严格：这次把「外部样本门禁、三平台运行验收、iOS 加密包、i18n 实际出图、报告字段完整性」都计入了完成度。2.9.0 审计主要看安全置信度，没有把这些交付项展开。

### 0.3 可信度边界（先说清楚）

- 这是**静态分析**工具；没有执行样本、没有联网、没有运行时行为证据。
- 官方基线只有 **2 条 Android、0 条 iOS**；没有官方样本库、没有 IOC/家族语料，不能对外声称召回率/准确率。
- 报告中的 `signatureVerified` 始终是 `false`；密封检查是**内容摘要一致性**，不是密码学签名验证。
- 本次没有在真实 Windows 桌面、真实 macOS 安装包、真实 Linux AppImage 上做运行验收；这些是审计限制，也是报告里的 P1。

---

## 1. 审计方法与本机证据

### 1.1 代码与仓库

| 项目 | 结果 |
|---|---|
| HEAD | `5c4db5a chore(release): 2.10.6` |
| 工作区 | clean |
| 版本一致性 | `pubspec.yaml` / CHANGELOG 顶部 / tag `v2.10.6` 一致 |
| 代码规模 | 约 85,183 行 Dart（不含生成文件）；100 个手写 lib 文件；108 个 package 源文件 |
| 测试规模 | 根目录 153 个 `*_test.dart`；package 50 个测试文件；105 个 fixture（约 984 KB） |
| 最近 CI | run 45794099537，`5c4db5a`，success |

### 1.2 本机实跑门禁

```text
flutter test                 1,843 passed / 16 skipped / 0 failed
analysis_model tests           141 passed
apk_parser tests               226 passed
ipa_parser tests               245 passed
archive_safety tests            40 passed
app_icon_extractor tests        25 passed
flutter analyze --fatal-infos --fatal-warnings   No issues found
dart format                     428 files, 0 changed
flutter build bundle            exit 0
```

跳过项主要是 `APPINFOTOOL_SAMPLES` 外部样本测试和 macOS 专用 codesign 用例。默认 CI 没有外部样本，因此这些测试在发布门禁里等价于「未执行」。

### 1.3 真实 IPA 样本实测（本次新增证据）

本机存在 `/Users/wangbaye/Projects/ipa`，其中 25 个文件、**4 个 IPA、0 个 APK**。用真实目录跑：

```sh
APPINFOTOOL_SAMPLES=/Users/wangbaye/Projects/ipa \
  flutter test test/real_samples_test.dart test/real_samples_ui_test.dart
```

结果：**8 通过 / 7 跳过 / 2 失败**。

失败不在解析器，而在真实样本 UI 测试的断言与样本选择：

- `test/real_samples_ui_test.dart:44` 的 `_firstSample` 按路径排序取第一个 IPA；当前是 `95-v1.8.7.ipa`。
- `:413` 断言该样本 `ios.icon.unresolved` 非空（「图标在 Assets.car 里，应当有未解析项」），实际为 `[]`。
- `:424` 断言该样本有 `ios.nested.truncated`（「27 个框架，超过 24 条上限」），实际诊断里没有；该样本只有 15 个 Mach-O image。
- 这两条断言显然是为另一个历史样本（更可能是 `sun_signed.ipa`）写的，却被 `_firstSample` 的「第一个」选中。

这件事本身是**测试选择器脆弱**，但它证明：**真实样本 E2E 门禁当前不是绿的，只是被 skip 掩盖了。** 如果只把 `APPINFOTOOL_SAMPLES` 配上就宣称「真实样本已验收」，结论不成立。

### 1.4 审计方式

- 5 个只读子审计并行：Android、iOS、UI/i18n、安装/系统集成、测试/CI/文档。
- 主审计复核了关键文件、行号、测试数量、README/CHANGELOG/工作流，并实际跑了门禁与真实 IPA 样本。
- 子审计的分数是「检查点加权」的主观分，用于排序，不是统计测量；报告中的事实以可复核的 file:line 和实跑结果为准。

---

## 2. 模块完成度

| 模块 | 分数 | 判断 |
|---|---:|---|
| Android 解析与安全 | **84** | 核心能力完整，证据层有两个 P1 断点，若干边界未闭环 |
| iOS 解析与安全 | **91** | 解析/图标/签名/密封主体强，但加密包结论有 P1，基线为空 |
| 界面与 i18n | **83** | 主流程完整，失败态、日韩核心安全卡、可访问性是明显短板 |
| 安装到设备与系统集成 | **91** | 功能面很全，Windows 文档/行为不一致和若干失败路径待修 |
| 测试 / CI / 构建发布 / 文档 | **80** | 测试数量可观，但「真实样本、三平台运行、macOS 签名」没有真正守住 |

**综合 86** 取五板块简单平均；若只看功能面约 87，只看工程交付约 80。

### 2.1 Android 解析与安全（84 / 100）

已实现且可复核：

- APK / XAPK / APKM / APKS 容器、AXML、`resources.arsc`、DEX、split 合并、manifest 损坏回退。
- 22 条组合规则、39 个 distinct ruleId、33 个权限目录项、65 个 CodeMarker、25 个 SDK 前缀、10 个加固壳、25 个 native 符号、29 条 Unicode 话术、13 个覆盖维度。
- APK v1/v2/v3 密封、split 证书一致性、官方基线匹配、五段链、Unicode 资源/字符串扫描。
- manifest 损坏时继续 DEX 审计，并将 `manifestUnparsed` 明确展示。
- 2.9.0 的 4 个 P1 已修，且有测试守卫（Unicode 维度、说明本地化、RULE-F 截断降级、v1-only 不等于 unsigned）。

主要缺口：

1. **P1：artifact inventory / load graph 算了但被丢弃。**
   `AndroidArtifactInventoryScanner.scan` 与 `AndroidLoadGraphScanner.scan` 的结果只作为 crypto-theft 中间量；`SecurityAnalysisResult` 没有 artifacts/loadGraph 字段（`packages/analysis_model/lib/src/security_finding.dart:553-567`），JSON 里直接写死 `'artifacts': null`、`'loadGraph': null`（`lib/utils/analysis_report.dart:2805-2806`），UI 也没有任何入口。用户看不到这两类证据，等于功能「实现了但不可用」。
2. **P1：覆盖模型只有 13 维，artifact/payload 截断不进覆盖。**
   截断只写进 `limitations`，而 `hasActualGaps`（`security_finding.dart:652-654`）只看 `coverage.gaps` 和 `UNKNOWN` 发现。于是「扫描被截断」时仍可能显示覆盖全绿。
3. **P2：XAPK/APKS 密封只做 v2→v1，没有 v3/v3.1**（`lib/apkparser/apk_info.dart:1024-1057`；主 APK 路径有 v3，`lib/apkparser/parse_task.dart:456-512`）。
4. **P2：split 一致性检查最多 8 个 split**（`apk_info.dart:1102`），且结果在 UI 不可见。
5. **P2：crypto-theft 的 `coverageIncomplete` 未计入 DEX 扫描截断**（`packages/apk_parser/lib/src/security/android_security_audit.dart:1855`）。
6. **P2：13 个 APK fixture 仍是 0 DEX / 0 `.so`**，真实解析路径主要靠外部样本；aapt2 回退路径不产出安全结果，UI 也不解释（`lib/apkparser/parse_task.dart:86`，`lib/pages/info_page.dart:932`）。
7. **P2：官方基线只有 2 条 Android，无密钥轮换 lineage；权限目录缺 `SEND_SMS` / `RECEIVE_SMS` / `WRITE_CONTACTS`。**
8. **P3：README 写 21 条 Android 规则，代码是 22 条；README 未列出密封/基线/crypto-theft/split/Unicode 等能力；E2E 重建 ZIP 会丢签名块。**

### 2.2 iOS 解析与安全（91 / 100）

已实现且可复核：

- IPA 容器、`Payload/*.app`、嵌套 bundle/framework/extension/watch 定位、二进制/XML plist。
- fat Mach-O、符号表、objc classref/selref、`ADRP+ADD/LDR` 调用点归属（`packages/ipa_parser/lib/src/security/ios_call_sites.dart`）。
- 根目录注入 dylib（`IOS-REPACKAGED`）、CodeResources v1/v2（64 条 / 64 MiB 预算）、分发类型、CMS 描述文件、macOS codesign。
- 20 个隐私能力标记、9 组权限选择子、用途说明/PrivacyInfo/必需理由 API、`IOS-RULE-F`、盗U五段链。
- 静态计数 36 个 iOS ruleId（隐私引擎 30 + 其他 6）；README 的「30 条」只覆盖隐私引擎。
- 图标：Assets.car 索引、LZFSE、ARGB/BGRA/GA、调色板、CgBI 规范化；文档记录真实语料出图率 50.6%。

主要缺口：

1. **P1：FairPlay 加密 IPA 没有被识别，否定结论会以 `confirmed` 呈现。**
   `packages/ipa_parser/lib/src/macho.dart` 不解析 `LC_ENCRYPTION_INFO`；只有 `lib/utils/macho_crypt_id.dart:71-72` 在 macOS codesign 路径里读 cryptid，和安全审计不同步。
   加密包的 `__TEXT` 是密文、字节完整可读，`IOS-RULE-F` 的 `noExecutable || incomplete` 条件（`packages/ipa_parser/lib/src/security/ios_privacy_audit.dart:1896-1918`）不会成立，于是给出 `confirmed` +「未发现上传」；覆盖页还会说 “Every executable was covered”（同文件 `:900-929`）。用户把 App Store 加密 IPA 当审计样本时，会得到误导性的「干净」结论。
2. **P2：iOS 官方基线 0 条**，`matchIos` 需要 Bundle ID + Team ID 交集，App Store 包通常无描述文件，iOS 端基本只会 `noBaseline/unavailable`，五段链的 family 段永不成立（`assets/baseline/official_baseline_v1.json`；`lib/utils/baseline_entry_extractor.dart:99-124`）。
3. **P2：CodeResources v1 静默不校验。** `_recordFromV1` 只认 `PlistString` 和 `PlistDict['hash']`（`packages/ipa_parser/lib/src/security/ios_code_resources_check.dart:245-255`）；真实 v1 `files` 的普通文件值是裸 `PlistData`（20 字节 SHA-1），会被整条跳过，最终 records 空、`entriesTotal=0`、`state=unknown`、无说明码。
4. **P2：盗U链在 iOS 只有 4/5 段可用。** `ios_crypto_theft_chain.dart:95-145` 不传 `networkSink`，`IOS-MNEMONIC-EXFIL` 不可达；family 段依赖 iOS 基线，而基线为空；剪贴板读写都取 `pasteboard.isNotEmpty`，钱包应用合法「复制地址」可能触发地址替换结论。
5. **P2：load graph 的 dangling edge 可能被读成注入证据。** 包外绝对 rpath、无法解析的 `@rpath` 等会建 `missing:`/`rpath:` 节点（`packages/ipa_parser/lib/src/security/ios_load_graph.dart:196-291`），链把全部 dangling 当 injection 证据（`ios_crypto_theft_chain.dart:29-43`），合法包可能得到 P2 可疑注入；尚未在干净语料上量化误报。
6. **P2：性能未达标。** 40.5 MB IPA 生产峰值 436–526 MB，专用探针 527.5 MB；安全耗时 2.2 s 达标。perf 探针不进 CI。
7. **P2/P3：图标出图率 50.6%，deepmap2 0x02/0x03 不支持；`IosCallSiteScanner` 569 行无直接测试；描述文件过期/授权给另一个应用仍不是 finding；无 iOS 商业加固壳名录。**

### 2.3 界面与 i18n（83 / 100）

已实现：

- 概览状态卡、最近文件、拖放、页头动作；六个详情 Tab；差异三态与导出；安装页 adb 指引；设置页七语言、主题、诊断、下载、关联、缩略图。
- 单文件与批量重命名；Markdown/JSON/full/securityOnly 导出；en/zh-CN/zh-TW/zh-HK 键对齐和占位符守卫；主题种子色。
- 六种语言切换；中英完整，日韩部分。

主要缺口：

1. **P1：分析页没有页面级空态/失败态。** `lib/pages/info_page.dart:1680-1737` 无论解析成功与否都渲染 `PageHeader + DetailTabView`；`apkInfo == null` 或解析失败只在 `:266 / :284` 弹一个 SnackBar，正文随后是一屏 `-`。用户分不清「文件没读到」和「文件里没有这个字段」——这正是该项目一直强调的区分。
2. **P2：日韩核心安全卡整块英文。** ja/ko 各缺 149 个键（11.64%），其中 `theft` 缺 47 个；`lib/gen/strings_ko.g.dart` 没有 `_TranslationsTheftKo`，`CryptoTheftCard`（`lib/widgets/crypto_theft_card.dart`）在韩语界面全部回退英文。README 只说「日韩部分完成」，没有指出核心安全结论仍然英文。
3. **P2：中文界面有硬编码英文。** `lib/pages/setting_page.dart:869/874/879` 的 Light/Dark/Auto；`lib/pages/detail_tab_view.dart:117` 的 `No data`；`lib/pages/info_page.dart:1538` 的 `default`。
4. **P2：可访问性几乎为零。** `lib` 下 0 个 `Semantics`/`semanticLabel`；18 个 IconButton 只有 12 个 tooltip；`lib/widgets/copy_icon_button.dart:44-64` 的点击区小于 48 px；没有 TextScaler 适配；键盘只有 Esc/Cmd+W；没有主题对比度测试。
5. **P2：响应式只覆盖概览（900 px）和侧栏（800 px）。** 分析/差异/设置/安装/详情没有断点；`lib/ui/shell/app_shell.dart:15` 注释里提到的 <600 折叠没有实现。
6. **P2：诊断本地化 14/57。** `lib/utils/analysis_diagnostic_text.dart` 其余 43 条回退英文。
7. **P2：24 个 UI 文件零测试**，包括 `crypto_theft_card.dart`、`manifest_partial_banner.dart`、`export_report_dialog.dart`、`export_diff_dialog.dart`、`detail_tab_view.dart`、`theme_manager.dart` 和 shell/provider 文件；61/85 个 UI 源文件有测试。
8. **P2：硬编码颜色有暗色对比度风险**（`lib/pages/overview_page.dart:418-428/1078-1108`、`lib/pages/info_page.dart:1065`、`lib/pages/setting_page.dart:1736`、`lib/widgets/platform_tag.dart:48`、`lib/widgets/android_detail_widgets.dart:257-263`）。

### 2.4 安装到设备与系统集成（91 / 100）

已实现：

- adb USB/无线配对/连接/断开、设备列表、force/downgrade/test/uninstall-first、多设备安装、XAPK/APKS split 选择 + OBB。
- `SelectableText` 日志、adb 缺失指引、8 类安装失败本地化。
- 缩略图：in-proc COM + 子进程解析、1.5 s 超时、WIC 有界解码、HKCU 注册、HKLM 检测。
- 文件关联、单实例互斥/WM_COPYDATA、Inno 安装器可选目录/语言/关联、macOS UTI。
- 2.8.7 的安装 P1 已修。

主要缺口：

1. **P2：停用缩略图可能假成功。** `windows/thumbnail/thumbnail_channel.cpp:319-361` 失败会抛 `PlatformException`；`lib/utils/system_thumbnail.dart:171-197` 返回 unknown；`lib/pages/setting_page.dart:765-796` 只看 `usable=false` 且 `wasUsable=true` 就显示「已停用」，即使 HKLM 注册仍在。`lib/widgets/system_icon_section.dart:65-77` 还可能先显示「DLL missing」。
2. **P2：Windows 缩略图默认行为与文档相反。** README:135-137 说「默认关闭，只在设置里点一次后启用，停用只删本项目两个键」；实际 `lib/config.dart:119-125` 默认 **true**，`lib/main.dart:106-112` 启动时自动注册，`windows/installer/appinfotool.iss:204-214` 安装时无条件写 HKCU 缩略图注册。这是用户告知/同意层面的实质不一致。
3. **P2：取消安装只杀本地 adb 客户端**（`lib/pages/install_page.dart:528-533`，`lib/utils/xapk_installer.dart:28-30,173`），设备侧安装可能继续，界面却显示已停止。
4. **P2：安装失败本地化只有 8 类**（`lib/pages/install_page.dart:1517-1545`）；缺 `USER_RESTRICTED`（MIUI 常见）、`VERIFICATION_FAILURE`、`TEST_ONLY`、`ABORTED`、`OLDER_SDK`、`CONFLICTING_PROVIDER`；XAPK 分支 `:460` 丢 `exitCode`（记为 -1）。
5. **P2：卸载不清理运行时 HKCU 文件关联。** `windows/runner/file_association_channel.cpp:346-410` 写 ProgID/OpenWithProgids，`iss:163-193` 只对 HKLM 做 `uninsdelete`，`:204-214` 只管缩略图；卸载后会留下「打开方式」幽灵项。
6. **P2：APKS `toc.pb` 字段号没有真实 `.apks` 验证。** `lib/utils/apks_toc.dart:10-17,42-46` 假定 `TableOfContents.entry=1`、`SplitApkEntry.path=1`；解析失败会静默列出全部 `.apk`（`lib/utils/xapk_installer.dart:123-132`）；测试字节是手造的（`test/apks_toc_test.dart`），没有真实 bundle fixture。
7. **P3：USB 热插拔不自动刷新**（`install_page.dart:105-123` 只在初始/恢复 + 手动 `:575`；README:99 说自动）；XAPK 日志缺原始 adb 输出；`.apkm` 可分析但安装拒绝；adb 缺失分支无测试；无卸载/应用管理 UI；`docs/notes/install-support-eval.md` 说没有 adb uninstall/pair，实际 `lib/utils/adb_service.dart` 都实现了。
8. **运行验收缺失：Windows 只编译并跑缩略图自测，没有真实安装/Explorer 验收；Linux AppImage 从未执行；macOS DMG 只挂载并验签，应用没启动。** `tool/windows_install_smoke.ps1` 是手动的，CI 里没有安装冒烟。

### 2.5 测试、CI、构建发布、文档（80 / 100）

已实现：

- 根测试 1,843 通过；package 677 通过；analyze/format 干净；CI 质量门禁在 Ubuntu 上执行。
- 三平台构建、Inno 安装器、AppImage、DMG、Release 上传都有工作流。
- 2.10.2 加了 coverage-note 注册守卫；2.10.5/2.10.6 修了发布下载占位和诊断复制。
- 版本号、tag、CHANGELOG 顶部一致。

主要缺口：

1. **P1：外部真实样本 E2E 不是发布依赖。** `.github/workflows/build.yml:150-152` 的 `external-samples` 只 `needs: quality`；`create-release`（`:845`）只依赖三个 build job，不依赖 `external-samples`。没有 `APPINFOTOOL_SAMPLES` 时所有外部样本测试跳过，Release 照常发布。本次本机启用后 **2 条 UI 失败**，证明这个门禁即使被打开也不是绿的。
2. **P1：三平台产物没有运行验收。** Linux AppImage 从未执行（`:713-839`）；Windows 安装器冒烟被移除，只剩手动脚本；macOS 只 `hdiutil` 挂载 + `codesign --verify`（`:689-705`），应用从未启动。README:150 也承认缩略图没有在真实 Windows 上验收。
3. **P1：macOS/iOS 签名测试不在 CI 跑。** 质量 job 只在 ubuntu（`:34-148`），macOS build job 不跑测试（`:621-709`），所有 codesign 用例在 CI 都被跳过；`test/ios_codesign_analyzer_test.dart` 等在本机也是 skip 多。
4. **P2：rc1/rc2 是 CI 修复试跑 tag，没有 CHANGELOG 段；发布 job 没有 prerelease 守卫**（`:1055/1113/1179`）。2.9.0-rc1 曾因 prerelease 表达式写坏被发成 stable，这个风险还在。
5. **P2：Scoop 资产名写死**（`:1088`）与实际 zip 名（`:611`）不一致，运行就会 404。
6. **P2：macOS 的 `build_runner` 少 `--delete-conflicting-outputs`**（`:667` vs `:73/164/233/764`）。
7. **P2：没有覆盖率门禁；8 个 `tool/*_test.dart` 不进 CI**（含 perf/memory/audit 探针）。
8. **P2：文档互相矛盾**：
   - `docs/plans/macos-build-and-signing.md:33` 说启用 App Sandbox；`macos/Runner/Release.entitlements` 明确故意不启用。
   - `docs/notes/install-support-eval.md:38-39` 说没有 adb uninstall/pair；`lib/utils/adb_service.dart` 已实现。
   - `docs/plans/V2.5.0-windows-manual-acceptance.md:18` 说 inno_bundle；实际是原生 `.iss`。
   - `README_en.md:85` 仍是 19 Android / 25 iOS；中文 README 是 21/30；代码是 22/36。
   - 中英 README 都声称「CI 在三平台跑同一门禁」，实际只有 Ubuntu 跑测试。
9. **P3：51 个 tag 对 45 个 CHANGELOG 段**，缺 2.3.2/2.3.3/2.3.5/2.3.6/2.3.7 和 rc1/rc2；2.9.0/2.10.0/2.10.1 的 CHANGELOG 缺测试门禁记录。
10. **P3：`lib/utils/riverpod_utils.dart` 13 行无引用；`vector_to_svg` 零测试。**

---

## 3. P1 清单（建议按此顺序修）

### P1-1 iOS FairPlay 加密包会给出误导性的「已确认未发现上传」

- 证据：`packages/ipa_parser/lib/src/macho.dart` 不解析 `LC_ENCRYPTION_INFO`；`lib/utils/macho_crypt_id.dart:71-72` 只在 macOS codesign 路径读 cryptid；`ios_privacy_audit.dart:1896-1918` 的 RULE-F 只按「没有可执行字节 / 截断」降 unknown。
- 影响：App Store 加密 IPA 的字符串、类名、符号都不可读，静态扫描会「什么都没看到」，报告却给 `confirmed` 的否定结论，覆盖页还说每个可执行文件都覆盖了。这是本次审计最严重的安全结论缺陷。
- 修法：在 Mach-O 解析层读 `LC_ENCRYPTION_INFO(_64).cryptid`，把「加密」作为一等事实进 `IpaAnalysis`；cryptid=1 时 RULE-F、能力类否定结论降 `unknown`，覆盖页/总览加「内容为密文，静态字符串结论不可用」横幅；补合成加密 Mach-O 测试。**不要**把 cryptid 只留在 codesign 展示层。

### P1-2 真实样本 E2E 既不阻塞发布，当前也不是绿的

- 证据：`.github/workflows/build.yml:150-152`（`external-samples` 只依赖 quality）、`:845`（Release 不依赖它）；本次实跑 8 通过 / 7 跳过 / 2 失败；`test/real_samples_ui_test.dart:44` 用「排序第一个 IPA」，`:413/:424` 的断言绑定的是另一个历史样本。
- 影响：发布流水线可以在「真实样本测试失败」的情况下出包；本地启用样本后测试也不绿。用户看到的「1,843 通过」不包含真实样本。
- 修法：
  1. 按「样本能力」选样本（含 27 框架 / Assets.car 未解析图标），或让每条断言在所选样本不满足前提时明确 skip，而不是假设固定文件名；
  2. 在 CI 增加可选的样本 job，并让 `create-release` 依赖它（没有样本时 job 以「未配置」失败或显式豁免，不能静默继续）；
  3. 至少保留一组「解析真实 IPA 不崩溃 + 报告可渲染」的冒烟测试，不依赖具体字段。

### P1-3 Android artifact inventory / load graph 计算后被丢弃

- 证据：`packages/analysis_model/lib/src/security_finding.dart:553-567` 无 artifacts/loadGraph 字段；`lib/utils/analysis_report.dart:2805-2806` 写死 `null`；UI 无入口；扫描器只在 `lib/apkparser/parse_task.dart:316,371,424-425` 作为 crypto-theft 中间量。
- 影响：「包内文件清单 / 加载图」被宣传为能力，但报告和界面都拿不到。对盗U检测，artifact inventory 和 load graph 是「注入/载荷」段的重要证据，丢掉后用户只能看到结论，看不到支撑。
- 修法：在 model 增加结构化字段，report schema v9（或 v8 的向后兼容扩展）输出，详情页加「证据」子页；保留扫描截断/条目上限的 coverage 状态。

### P1-4 覆盖模型不包含截断，`hasActualGaps` 可能假绿

- 证据：`packages/analysis_model/lib/src/security_finding.dart:640-654`；13 个覆盖维度；artifact/payload/DEX 截断只进 `limitations`；`android_security_audit.dart:1855` 的 `coverageIncomplete` 未计 DEX 截断。
- 影响：扫描只覆盖了一部分时，结构化覆盖仍全绿；界面/报告可能把「没扫完」显示成「没有缺口」。这与项目自己坚持的「没查到 ≠ 没有」相冲突。
- 修法：把 artifact、payload、DEX、native lib、split sampling 的截断做成显式 `CoverageEntry`（`partial` / `notCovered` + checked/total），并让 `hasActualGaps` 纳入；同时保持既有「limitations 不等于 gaps」的设计，避免所有样本都亮红灯。

### P1-5 分析页没有页面级空态/失败态

- 证据：`lib/pages/info_page.dart:1680-1737` 固定渲染 `PageHeader + DetailTabView`；`:266/:284` 只弹 SnackBar；失败后字段是一屏 `-`。
- 影响：用户无法区分「文件没解析」和「文件确实没有这个字段」，也无法重试/返回；对审计工具，这是结论可信度问题，不只是 UI 问题。
- 修法：`fileState` 增加明确状态（未选择 / 解析中 / 失败 / 部分成功 / 成功），页面级渲染空态/错误态/重试；`DetailTabView` 只在成功或部分成功时渲染。

### P1-6 三平台产物没有运行验收，macOS/iOS 签名测试不在 CI

- 证据：`.github/workflows/build.yml:713-839`（Linux 只构建）、`:689-705`（macOS 只挂载+验签）、`:34-148`（quality 只 ubuntu）、`:621-709`（macOS build 不跑测试）；Windows 只有 `tool/windows_install_smoke.ps1` 手动脚本。
- 影响：CI 绿只证明「能编译」，不证明「装完能启动、缩略图能出、文件关联能开、DMG 能装」。Windows 缩略图/注册表代码从未在真实桌面验证，是已承认的风险。
- 修法：至少做一条「安装 → 启动 → 打开一个包」的三平台冒烟；macOS 在 build job 跑 `flutter test`（或单独 macos-test job）；Windows 安装器冒烟恢复为可选 job，找不到稳定目录就显式标记「未执行」，不要静默。

### P1-7 Windows 缩略图默认行为与文档/用户同意相反

- 证据：`README.md:135-137` 说默认关闭、只在设置里启用；`lib/config.dart:119-125` 默认 `true`；`lib/main.dart:106-112` 启动自动注册；`windows/installer/appinfotool.iss:204-214` 安装时无条件写 HKCU。
- 影响：用户在「默认关闭」的承诺下安装，实际已被写入注册表；卸载清理也不完整（见 P2）。这是 Windows 用户告知/隐私层面的实质不一致。
- 修法：二选一——要么把默认改回 `false` 且安装器不写（推荐，符合 README），要么改 README/安装向导明确告知「默认启用、可在设置关闭」。不能保持现状。

---

## 4. P2 清单（按板块）

### Android

- XAPK/APKS 密封只做 v2→v1，没有 v3/v3.1（`lib/apkparser/apk_info.dart:1024-1057`）。
- split 一致性检查最多 8 个，结果 UI 不可见（`apk_info.dart:1102`）。
- crypto-theft `coverageIncomplete` 未计 DEX 截断（`android_security_audit.dart:1855`）。
- 13 个 APK fixture 全 0 DEX / 0 `.so`；aapt2 回退不产安全结果且 UI 静默（`parse_task.dart:86`，`info_page.dart:932`）。
- 官方基线仅 2 条，无密钥轮换 lineage；权限目录缺 `SEND_SMS`/`RECEIVE_SMS`/`WRITE_CONTACTS`。
- fake `.so` 只作为 hint，不生成 finding；E2E 重建 ZIP 丢签名块。

### iOS

- 图标出图率 50.6%，deepmap2 0x02/0x03 不支持（`assets_car.dart:292-293`）；无系统缩略图兜底。
- iOS 官方基线 0 条，family 段永不成立（`assets/baseline/official_baseline_v1.json`；`baseline_entry_extractor.dart:99-124`）。
- CodeResources v1 只认 String/Dict，裸 `PlistData` 被跳过（`ios_code_resources_check.dart:245-255`）；v1-only 无测试。
- 盗U链 iOS 4/5 段：`networkSink` 未接、family 依赖空基线、剪贴板读写不区分（`ios_crypto_theft_chain.dart:95-145`）。
- load graph dangling edge 被当注入证据（`ios_load_graph.dart:196-291`；`ios_crypto_theft_chain.dart:29-43`），未量化干净语料误报。
- 峰值 RSS 436–526 MB，未达预算；perf 探针不进 CI。
- `IosCallSiteScanner` 无直接测试；根目录 dylib 扫描仅 1 条测试；无 v1-only 密封用例。

### 界面 / i18n

- ja/ko 缺 149 键（11.64%），`theft` 47 键，韩语 `CryptoTheftCard` 全英文。
- 硬编码英文：`setting_page.dart:869/874/879`、`detail_tab_view.dart:117`、`info_page.dart:1538`。
- 0 个 Semantics；CopyIconButton <48 px；无 TextScaler；无对比度测试。
- 仅概览/侧栏响应式；`app_shell.dart:15` 的 <600 折叠未实现。
- 诊断本地化 14/57；暗色硬编码颜色有风险。
- 24 个 UI 文件零测试。

### 安装 / 系统集成

- 停用缩略图假成功（`thumbnail_channel.cpp:319-361`；`system_thumbnail.dart:171-197`；`setting_page.dart:765-796`）。
- 安装失败 localization 只 8 类；XAPK 丢 exitCode；取消只杀本地 adb。
- 卸载不清理 HKCU 文件关联，留幽灵项（`file_association_channel.cpp:346-410`；`iss:163-193`）。
- APKS `toc.pb` 字段号无真实样本验证，失败静默 fallback。
- USB 热插拔不自动刷新；XAPK 日志缺原始 adb 输出；`.apkm` 可分析不可安装；adb 缺失分支无测试；安装文档过期。

### 工程 / 发布

- rc tag 无 CHANGELOG、发布 job 无 prerelease 守卫。
- Scoop 资产名与 zip 名不一致（`build.yml:1088` vs `:611`）。
- macOS `build_runner` 缺 `--delete-conflicting-outputs`（`:667`）。
- 无覆盖率门禁；8 个 `tool/*_test.dart` 不进 CI。
- 文档矛盾（macOS sandbox、install 评估、inno_bundle、README_en 规则数、三平台门禁宣称）。
- 51 tag / 45 CHANGELOG 段；`riverpod_utils.dart` 无引用；`vector_to_svg` 零测试。

---

## 5. 安全检测能力边界（盗U场景）

### 5.1 现在能给出的结论

| 问题 | 现在能回答 | 不能回答 |
|---|---|---|
| 包内有没有可疑能力/来源/注入/载荷迹象 | 能，五段链 + 证据 + 覆盖说明 | 不能证明「没有」 |
| 是否与已知官方包一致 | 能（仅 2 条 Android 基线；iOS 0 条） | 不能覆盖未知官方包 |
| 是否被重打包/注入 dylib | Android 有 split 证书/密封；iOS 有根目录 dylib/CodeResources | 改名重打包、原地 patch 看不到 |
| 是否加密/加固 | Android 有壳/加固线索；iOS 缺 FairPlay 识别（P1） | 不能脱壳；不能看密文内容 |
| 是否有网络外传 | Android 有网络/上传线索；iOS 有标记但 `networkSink` 未接 | 不能证明实际外传 |
| 是否是「盗U木马」 | **不能下这个结论**；只输出发现、证据、置信度、未覆盖范围 | 不能给家族名、不能给召回率/准确率 |

### 5.2 建议的表述

- 可以说：「静态扫描发现 X 条能力/注入/载荷证据，覆盖 N/M 个可执行文件，另有 K 个未覆盖；未发现 Y」。
- 不能说：「这个包不是盗U」「这个包安全」「检出率 9x%」。
- 加密 IPA 在修复 P1-1 前，不应把「未发现上传」当作结论展示。

---

## 6. 修复路线图

### 第一批（发布前，P1）

1. iOS FairPlay cryptid 识别 + 否定结论降级（P1-1）。
2. 真实样本 selector 修正；`external-samples` 纳入 Release 依赖或明确的「未执行」阻断（P1-2）。
3. Android artifact/loadGraph 进 model/report/UI（P1-3）。
4. 覆盖模型纳入截断（P1-4）。
5. 分析页空态/失败态（P1-5）。
6. 三平台安装→启动冒烟；macOS 测试进 CI（P1-6）。
7. Windows 缩略图默认值/安装器行为与 README 对齐（P1-7）。

### 第二批（体验与正确性，P2）

- Android：XAPK 密封 v3、split 上限、DEX 截断、真实 fixture、权限目录。
- iOS：CodeResources v1、iOS 基线、networkSink、load graph dangling、图标兜底、内存预算。
- UI：日韩 theft 47 键、硬编码英文、a11y、响应式、诊断本地化。
- 安装：缩略图假成功、失败码、HKCU 关联清理、APKS 真实 toc、热插拔。
- 工程：rc 守卫、Scoop 资产名、macOS build_runner、覆盖率/探针门禁、文档纠错。

### 第三批（P3）

- README 数字与能力清单、CHANGELOG 缺失段、死代码、`IosCallSiteScanner` 单测、过期描述文件 finding、iOS 加固壳名录。

---

## 7. 本次审计的限制

1. 只读审计，没有在 Windows 真机、macOS 安装包、Linux AppImage 上运行；相关结论来自代码、CI 配置和文档，不是运行验收。
2. 本机真实样本只有 4 个 IPA、0 个 APK；Android 真实样本结论来自子审计和既有文档，没有在本机重新跑 APK 真实样本。
3. 没有重新做性能基准；内存数据引用 `docs/plans/2026-11-05-baseline-import-and-memory.md` 与探针代码。
4. 没有真实 App Store 加密 IPA 的当前样本可复现 P1-1；结论来自代码路径和 Mach-O 格式事实，修复时需要补合成样本。
5. 子审计分数是检查点加权的主观分；事实以本报告中的 file:line 和实跑结果为准。
6. 本次没有修改任何生产代码，也没有提交；报告新增在 `docs/audit/2026-11-27-module-completeness-audit.md`。

---

## 8. 附录：关键证据路径

- 本次门禁：`flutter test`、`flutter analyze --fatal-infos --fatal-warnings`、`dart format --output=none --set-exit-if-changed .`、`flutter build bundle`。
- 真实样本：`APPINFOTOOL_SAMPLES=/Users/wangbaye/Projects/ipa flutter test test/real_samples_test.dart test/real_samples_ui_test.dart`。
- iOS cryptid：`packages/ipa_parser/lib/src/macho.dart`、`lib/utils/macho_crypt_id.dart:71-72`、`packages/ipa_parser/lib/src/security/ios_privacy_audit.dart:1896-1918`、`:900-929`。
- Android artifact：`packages/analysis_model/lib/src/security_finding.dart:553-567`、`lib/utils/analysis_report.dart:2805-2806`、`lib/apkparser/parse_task.dart:316,371,424-425`。
- 覆盖：`packages/analysis_model/lib/src/security_finding.dart:640-654`、`packages/apk_parser/lib/src/security/android_security_audit.dart:1855`。
- 样本门禁：`.github/workflows/build.yml:150-152`、`:845`、`test/real_samples_ui_test.dart:44,413,424`。
- UI 空态：`lib/pages/info_page.dart:266,284,1680-1737`。
- i18n：`assets/i18n/*.json`、`lib/gen/strings_ko.g.dart`、`lib/widgets/crypto_theft_card.dart`。
- Windows：`lib/config.dart:119-125`、`lib/main.dart:106-112`、`windows/installer/appinfotool.iss:204-214`、`windows/thumbnail/thumbnail_channel.cpp:319-361`、`windows/runner/file_association_channel.cpp:346-410`。
- iOS 密封/基线：`packages/ipa_parser/lib/src/security/ios_code_resources_check.dart:30-231`、`lib/utils/baseline_entry_extractor.dart:99-124`、`assets/baseline/official_baseline_v1.json`。
