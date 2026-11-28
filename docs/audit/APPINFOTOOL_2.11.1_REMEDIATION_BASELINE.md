# AppInfoTool 2.11.1 整改基线（只读审计）

- 审计日期：2026-11-28
- 审计对象：`/Users/wangbaye/Projects/AppInfoTool`，分支 `feature/2.11.0`，HEAD `cfcbaa5`
- 发布基线：Release `v2.11.0`（tag 对象 `0cf0060` → commit `cfcbaa5`），仓库 `wongbaye26-dot/appinfotools`
- 审计方式：只读。所有结论来自本次实跑命令或代码/测试引用；不引用旧计划推断实现状态。
- 环境限制：本机无 GitHub 写凭据（`git push` 走 SSH key，可用；API 写操作不可用）；无 `idevice_id` / `ideviceinstaller`；无 Windows / Linux 实机；无 Apple 签名证书。

---

## 0. 结论摘要

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 工作区 | 干净，仅 1 个未跟踪文件（上一轮审计报告） | `git status --porcelain` |
| main 与 2.11.0 | main 停在 2.10.6，落后 **38** 个提交，无 PR | `git log`、GitHub API |
| PR 状态 | **0** 个（open + closed 均 0） | `GET /pulls?state=all` |
| 分支保护 | **无法验证**（匿名 API 返回 401），需带 token 复核 | `GET /branches/main/protection` |
| 样本豁免 | 生效中：文件存在即豁免，Release 正文自动加警告 | `.github/workflows/build.yml:200,1103` |
| 验收文档 | 仍为 **NO-GO**，与已发布事实冲突 | `APPINFOTOOL_2.11.0_RELEASE_ACCEPTANCE.md` |
| AAB | 只读包名/版本/SDK/标签/图标/DEX/原生库；**组件、权限、uses-feature、debuggable、compileSdk 未解析** | `aab_reader.dart:15-35,376-455` |
| IPA 安装页 | 只有文件名与大小；**不解析 IPA 元数据** | `install_page.dart:194-215,979+` |
| ja / ko | 各缺 **146** 个键（theft 47、report 45、field_diagnostic 15、analysis_diagnostic 14、settings 11、overview 7、apk_info 5、home 1、signature 1） | 键集对比脚本 |
| 对比页 DEX | 槽卡与右栏有 DEX；**字段差异表无 DEX 行** | `diff_page.dart:815,1765`、`diff.fields.*` |
| iOS 安装 E2E | 未执行；本机无工具、无设备；测试均为单测 | `test/ios_install_service_test.dart` |
| 核心证据链 | Evidence / Finding / Coverage / Artifact / Load Graph / Network Clues **均已实现并导出**（schema v11） | 见第 11 节 |
| 三平台验收 | CI 构建通过；**Windows / Linux 无人工验收记录**；macOS job 不跑测试 | workflow、docs 检索 |

门禁实跑（本次）：`flutter analyze` 无问题；`flutter test` **2005 passed / 20 skipped**。

---

## 1. Git 分支、HEAD 与工作区

```
$ git branch --show-current
feature/2.11.0
$ git rev-parse HEAD
cfcbaa5dc9c0961b736bd6cde304cd7232b261c8
$ git status --porcelain
?? docs/audit/2026-11-28-post-release-audit.md
```

- HEAD 提交：`cfcbaa5 ci(release): 支持仓库内文件显式豁免真实样本门禁`（2026-11-28 15:00:32 +0700）。
- 未提交内容只有上一轮审计报告；**没有进行中的代码改动**。
- 结论：整改可以从干净状态开始；审计报告可一并提交。

## 2. main 与 v2.11.0 的提交关系

```
$ git log --oneline origin/main -1
5c4db5a chore(release): 2.10.6
$ git rev-list --count origin/main..HEAD
38
$ git rev-list --count HEAD..origin/main
0
$ git merge-base origin/main HEAD
5c4db5a
$ git tag --list 'v2.11*' --format='%(refname:short) %(objectname:short) -> %(*objectname:short)'
v2.11.0 0cf0060 -> cfcbaa5
```

- 2.11.0 的 38 个提交全部**只在 `feature/2.11.0`**；`main` 无任何 2.11 内容。
- `v2.11.0` 是 annotated tag，指向 `cfcbaa5`，与 HEAD 一致。
- 任务书「保留已有 v2.11.0 发布 Tag、不得移动/删除」在本基线成立：tag 与 release 已发布，后续整改应走 **2.11.1 新 tag**，不动 `v2.11.0`。

## 3. PR 状态与分支保护

```
$ curl -s "https://api.github.com/repos/wongbaye26-dot/appinfotools/pulls?state=all&per_page=10"
[]                      # 0 个 PR（open / closed / merged 均无）
$ curl -s -o /dev/null -w "%{http_code}" ".../branches/main/protection"
401                     # 需要认证，匿名不可读
$ curl -s ".../repos/wongbaye26-dot/appinfotools"
default_branch=main, fork=false, pushed_at=2026-11-28T08:00:42Z
```

- 结论：从未开过 PR；`main` 分支保护规则**当前无法验证**（不是「没有保护」，是「读不到」）。
- 整改时合并方式（直接 push / PR / squash）取决于维护者权限；仓库具备 SSH push 能力，但仓库设置未知。

## 4. `.github/allow-no-samples` 的实际影响

文件内容（`.github/allow-no-samples`，424 B）：说明「本次未跑真实样本 E2E、理由、撤销方式（删除本文件）」。

工作流中的生效点：

- `build.yml:160`：`APPINFOTOOL_ALLOW_NO_SAMPLES` 来自仓库变量。
- `build.yml:200`：`if [ -n "$APPINFOTOOL_SAMPLES" ]` → 要求样本；`elif [ "$APPINFOTOOL_ALLOW_NO_SAMPLES" = "1" ] || [ -f .github/allow-no-samples ]` → 置 `APPINFOTOOL_REQUIRE_SAMPLES=0` 并 warning；`elif refs/tags/*` → 直接失败。
- `build.yml:942-944`：`create-release` 的 `needs` 含 `external-samples`，且要求其 result == success。
- `build.yml:1103-1106`：Release 正文自动插入「真实样本未验证」警告与豁免理由。

实际影响：

1. **没有样本也能发布**：豁免让 `external-samples` 成功，`create-release` 照常执行（v2.11.0 即如此）。
2. **不是静默**：日志有 warning，Release 正文有警告段（已核对 Release body 首段）。
3. **长期生效**：文件在仓库里，后续任何 tag 默认继续豁免，直到删除。
4. **与验收文档冲突**：验收文档仍写 NO-GO（见第 5 节）。

## 5. 2.11.0 验收文档与 Release 正文的一致性

`docs/audit/APPINFOTOOL_2.11.0_RELEASE_ACCEPTANCE.md`：

- `:117` 附近：「**NO-GO。**」；阻断项含「Windows/Linux 运行验收未执行；CI 未运行」「真实样本清单未配置到 CI」等。
- `:154`、`:161` 两次追加说明：schema v9 与历史页测试两项阻断已解除，但「发布结论仍为 **NO-GO**：Windows/Linux 实机、CI 样本门禁、全量手工验收仍未完成」。

Release 正文（API 实测）：

- 首段为「> **真实样本未验证。** 本次发布由仓库内 `.github/allow-no-samples` 显式豁免…」+ 豁免理由。
- 之后是 CHANGELOG 2.11.0 段落，无 NO-GO 声明。

结论：**Release 正文与豁免机制一致，但与验收文档的 NO-GO 结论冲突**。2.11.1 需要把验收文档改成「有条件发布 + 补测计划」，否则仓库内同时存在两种相反结论。

## 6. AAB 当前解析字段与缺失字段

已解析（`packages/apk_parser/lib/src/aab/aab_reader.dart:15-35` 的 `AabInfo`，取值在 `:376-455`）：

| 字段 | 来源 |
| --- | --- |
| `packageName` / `versionCode` / `versionName` | `base/manifest/AndroidManifest.xml` 根属性（字符串或资源引用） |
| `minSdkVersion` / `targetSdkVersion` | `<uses-sdk>` |
| `label` / `labels` / `iconPaths` / `mainIconPath` | `<application android:label / android:icon>` + `base/resources.pb` |
| `dexEntries` / `nativeLibraries` / `fileCount` / `totalUncompressedBytes` / `structure` | ZIP 条目扫描 |
| `locales` / `densities` | 资源表 |
| `failureReason` / `resourceFailure` | 清单/资源读取失败原因 |

**未解析**（对 `aab_reader.dart` 检索 `uses-permission|uses-feature|debuggable|compileSdk|activity|service|receiver|provider` 无命中）：

- `<uses-permission>` / `<uses-permission-sdk-23>`
- `<uses-feature>`（含 `required`）
- `<application android:debuggable>`
- `<manifest android:compileSdkVersion>`（以及 `compileSdkVersionCodename`）
- 组件：`activity` / `activity-alias` / `service` / `receiver` / `provider`
- 启动 Activity（需组件 + intent-filter 解析）

现有 UI 对 AAB 的处理是**主动隐藏**不适用区块：签名分析跳过（`lib/pages/info_page.dart:2984-2988`）、原生库/分包区块按 `archiveType != 'AAB'` 隐藏（`:2916`）。这符合「AAB 无安装语义」，但不能替代「组件/权限本来是清单事实」。

扩展点明确：`AabXmlElement` 已能按元素名取子节点（`root.child('uses-sdk')`、`application?.child(...)`），`AabInfo` 只需加字段并填充；测试侧已有 `packages/apk_parser/test/aab/support/aab_builder.dart` 可造 protobuf 清单。

测试现状：`packages/apk_parser/test/aab/{proto_test,aab_resources_test,aab_reader_test}.dart` 与 `test/aab/aab_integration_test.dart`；**无组件/权限/feature 测试**。

## 7. IPA 安装页的数据来源

- 选择 `.ipa` 时走独立分支：`lib/pages/install_page.dart:194-215` 只设置路径，**跳过 APK 解析**（注释写明「.ipa 不走 APK 解析流水线」），随后 `_refreshIos()` 枚举设备。
- 文件卡 `_buildFileCard`（`install_page.dart:979+`）取 `_apkInfo`：
  - `.ipa` 时 `_apkInfo == null`，因此 `name = basename(path)`、`version = null`、`abis = []`、`minSdk = null`。
  - 结果：安装页的 IPA 只有文件名、大小与格式角标；**没有应用名、Bundle ID、版本号、Build Number、图标**。
- 设备侧数据来自 `lib/utils/ios_install_service.dart`（`idevice_id -l` / `ideviceinfo` / `ideviceinstaller`），与 IPA 文件本身无关。
- 项目里已有完整 IPA 解析能力（`packages/ipa_parser` + `lib/ipaparser/*` + `info_page` 的 IPA 路径），只是安装页没有接。

## 8. ja / ko 缺失的 146 个键

以 `assets/i18n/en.json` 为基准对六语言做键集对比（本次脚本实测）：

| 语言 | 键数 | 缺失 |
| --- | --- | --- |
| en | 1689 | 0 |
| zh-CN | 1689 | 0 |
| zh-HK / zh-TW | 1689 | 0 |
| ja | 1543 | **146** |
| ko | 1543 | **146** |

缺失分组（ja 与 ko 完全相同）：

| 组 | 数量 | 说明 |
| --- | --- | --- |
| `theft` | 47 | 盗 U / 加密资产相关界面文案 |
| `report` | 45 | 报告导出（表格列名、库识别小节等） |
| `field_diagnostic` | 15 | 字段诊断 |
| `analysis_diagnostic` | 14 | 解析诊断 |
| `settings` | 11 | 设置页新增卡片 |
| `overview` | 7 | 概览新增文案 |
| `apk_info` | 5 | 清单/权限/证书 |
| `home` | 1 | 首页 |
| `signature` | 1 | 签名 |

`test/i18n_coverage_test.dart:356-364` 明确只钉住「已补齐」的四组（coverage/diff/ios_info/security），并注明 `report` / `field_diagnostic` / `analysis_diagnostic` 等仍未补齐，**不允许**把「键集全等」直接加为断言否则会立刻变红。

任务书要求「不得用未经审核的机械直译冒充最终翻译」：基线确认这 146 条目前是**结构性缺失**（回退英文），补全需要人工/审核翻译，并逐条保留占位符。

## 9. 版本对比页的 DEX 展示

- 有：槽卡元信息行 `'$dex DEX'`（`lib/ui/diff/diff_page.dart:815-820`）。
- 有：右栏「新增 DEX」指标（`:1765`），仅在 `dexRight > dexLeft` 时出现。
- 有：叙述句 `narrative_dex`（`:1837`）与复核清单项 `check_dex`（`:1994`）。
- **没有**：字段差异表里的 DEX 行 —— `diff.fields.*` 键集无 dex（`assets/i18n/en.json` 的 `diff.fields` 仅 file/app/android/ios/signature/security 六类），表体数据由 `_comparablePair` 的字段列表生成，未包含 DEX 数量。

因此任务书 D「增加 DEX 数量展示」应理解为**在字段差异表中增加一行**（`dex.count`），而不是从零实现 DEX 统计。

## 10. iOS 安装服务的真实 E2E 条件

本机实测：

```
$ command -v idevice_id        → 未找到
$ command -v ideviceinstaller  → 未找到
```

- 现有测试：`test/ios_install_service_test.dart`（12 条，全部为解析/PATH 探测/缺工具的单元测试）；`test/ios_install_page_test.dart` 注入空工具链与空设备列表。
- 真实 E2E 的前置条件：
  1. macOS（本机满足）；
  2. `brew install libimobiledevice ideviceinstaller`（未满足）；
  3. 一台解锁并「信任此电脑」的 iOS 设备（未满足）；
  4. 一个用开发证书签名的 `.ipa`（本机无 Developer ID / 开发证书，`security find-identity` 为 0）；
  5. 设备端已开启开发者模式（iOS 16+）。
- CI 侧：`build.yml` 的 macOS job 只构建，不跑 `flutter test`（grep `flutter test` 仅出现在 ubuntu quality job 与 external-samples job），因此**即使有设备也不能靠 CI 验证**。

## 11. Evidence / Finding / Coverage / Artifact / Graph / Network Clues 实际完成度

逐项核验（模型 + 产出 + 导出 + 测试）：

| 能力 | 模型 | 产出 | 导出（JSON） | 导出（Markdown） | 界面 | 测试 |
| --- | --- | --- | --- | --- | --- | --- |
| Evidence | `SecurityEvidence`（id/source/location/locationCode/detailCode） | 扫描器产出，finding 通过 `evidenceIds` 关联 | `security.evidence[]`（`analysis_report.dart:3128`） | 证据小节 | 安全 Tab | `test/security_evidence_card_test.dart` 等 |
| Finding ↔ Evidence | `SecurityFinding.evidenceIds` | 每条 finding 携带 | 随 finding 输出（`:2925`） | 有 | 有 | 有 |
| Coverage | `CoverageEntry{id,status,covered,limit,note,noteCode,noteArgs}` + `AnalysisCoverage.applicable/gaps` | 13 个维度，截断/失败进 `noteCode` | 报告覆盖小节 | 有 | 覆盖卡 | `test/analysis_coverage_test.dart` |
| Artifact Inventory | `SecurityAnalysisResult.artifacts`（`security_finding.dart:607`） | DEX/SO/资源等条目 | `security.artifacts`（`:3142`，含 `null` 语义） | 有 | `SecurityEvidenceCard`（`info_page.dart:1256`） | `test/security_evidence_card_test.dart:20`、`test/analysis_report_test.dart` |
| Load Graph | `SecurityAnalysisResult.loadGraph`（`:611`） | 边/节点 | `security.loadGraph`（`:3145`） | 有 | 图视图 | `test/security_evidence_card_test.dart:33`、`test/analysis_report_test.dart` |
| Network Clues | `NetworkFacts`（`security_finding.dart:589`） | DEX/字符串/IPA 提取 | 顶层 `network{domains,ips,clues[]}`（含 `sourcePath`/`context`） | `_networkSection` | 安全 Tab | `packages/analysis_model/test/network_endpoints_test.dart` |
| AnalysisRun | `AnalysisRun` + `AnalysisRunRepository` | 每次解析落库，running→terminal | 快照 = `AnalysisReport.renderJson`（**默认参数，不含 ReportExtras**，故有 security/evidence/artifacts/loadGraph/network/coverage，不含 permissionDetails/libraries/certificates） | — | 历史页只读摘要；**快照已落库但当前没有任何 UI 读取**（grep `.snapshot` 仅写入侧） | `test/analysis_run_recorder_test.dart` |
| 历史重新打开 | `history_page.dart:17` 注释 | 「打开原包 = 重新解析」，不复用旧结果；快照仅归档，无「查看快照」入口 | — | — | 历史页 | `test/history_page_test.dart` |

结论：**这六项在 2.11.0 已实现并可从报告复现，不需要重做**。Phase 5 的工作是「核验 + 记录」，不是开发；唯一需要注意的是覆盖维度对截断的表达是否完整（`android_load_graph.dart:127` 已有 budget 截断标记，DEX unicode 字符串有 `android.dex.unicode_strings.truncated` 覆盖项）。

## 12. Windows / Linux 实际运行验证情况

- CI：`build-windows`（windows-latest）产出 Setup.exe / zip / thumbnail-selftest；`build-linux`（ubuntu）产出 AppImage；两者均为**构建 + 启动冒烟**级别，无人工安装/运行记录。
- 文档检索（`grep -rn "Windows 11\|Windows 10\|Ubuntu 2" docs/audit/*.md`）：**无命中**，即没有 2.11.0 的 Windows/Linux 实机验收记录。
- 已知未验证点：Windows 安装器注册表写入与缩略图（`tool/windows_install_smoke.ps1` 已不在 `tool/` 目录）、文件关联、卸载清理；Linux AppImage 的桌面集成与首次启动。
- macOS：本机可运行（87.7 MB 包冒烟通过），但无公证；CI macOS job 不跑测试。

---

## 13. 与任务书假设的差异（重要）

| 任务书假设 | 基线实测 | 处理 |
| --- | --- | --- |
| main 落后 38 提交 | 一致（38） | Phase 2 合并 |
| 存在 `.github/allow-no-samples` 豁免 | 一致，且 Release 正文已带警告 | Phase 2 恢复样本后删除 |
| 对比页 DEX 缺失 | **部分**：槽卡/右栏有，字段表无 | Phase 3-D 只补字段表行 |
| AAB 缺组件/权限等 | 一致，且缺 uses-feature/debuggable/compileSdk | Phase 3-A |
| IPA 安装页缺元数据 | 一致，且完全不解析 IPA | Phase 3-B |
| ja/ko 缺 146 键 | 一致 | Phase 3-C |
| Evidence/Artifact/Graph/Network 待核验 | **已实现且已导出** | Phase 5 只核验，不重写 |
| Windows/Linux 未验收 | 一致（无记录） | Phase 4 需实机或显式标记未验证 |
| 分支保护规则 | **读不到**（401） | 需维护者提供或跳过 |

## 14. 2.11.1 建议范围与验收标准（供阶段 2–5 使用）

1. **发布流程（Phase 2）**
   - 合并 `feature/2.11.0` → `main`（PR 或直接 push，取决于保护规则）。
   - 不动 `v2.11.0` tag/release；2.11.1 用新 tag。
   - 更新 `APPINFOTOOL_2.11.0_RELEASE_ACCEPTANCE.md`：把 NO-GO 改为「有条件发布（2.11.0）+ 2.11.1 补测」。
   - 有样本后删除 `.github/allow-no-samples`，并验证「无样本 tag 必须失败」。
   - 验收：`git rev-list --count origin/main..HEAD == 0`；无豁免文件时 tag CI 在 `external-samples` 失败。

2. **AAB 增强（Phase 3-A）**
   - `AabInfo` 增 `components`/`permissions`/`features`/`debuggable`/`compileSdkVersion`。
   - 接入 `ApkInfo`（`android_permissions_panel`、组件面板可复用）。
   - 测试：`aab_builder` 造含权限/feature/组件的清单；断言 UI 与报告。
   - 验收：AAB 详情页出现「权限/组件」且与清单一致；无字段时仍显示「未读取」而非 0。

3. **IPA 安装元数据（Phase 3-B）**
   - 安装页对 `.ipa` 调现有 IPA 解析（applicationName/bundleId/version/build/icon），复用 `RecentAppIcon`。
   - 验收：拖入 IPA 后文件卡显示名称·版本、Bundle ID、图标；解析失败回退文件名且不阻断安装。

4. **国际化（Phase 3-C）**
   - 补 146 键 × ja/ko（人工审核），保留占位符。
   - 把 `test/i18n_coverage_test.dart` 的 `migratedGroups` 扩到全部组（或加「键集全等」断言）。
   - 验收：六语言键集相等；ja/ko 无英文复制；占位符校验通过。

5. **对比页 DEX（Phase 3-D）**
   - 字段表增 `dex.count` 行（`diff.fields.dex_count`），保留现有集合差异。
   - 验收：`test/v4_diff_test.dart` 断言该行随 DEX 变化出现；右栏「新增 DEX」不回退。

6. **验证与性能（Phase 4）**
   - 记录同一批样本在 2.10.6 / 2.11.0 的耗时与峰值内存（`tool/perf_probe_*.dart` 可复用）。
   - Windows/Linux 若无实机，必须在验收文档显式写「未验证」，不得写「通过」。
   - iOS E2E 若无法执行，同样显式标记，并给出前置条件（第 10 节）。

## 15. 仍未解决的风险（基线时点）

1. 样本门禁仍被文件豁免；真实样本 E2E 在 CI 从未绿过。
2. `main` 与发布物不一致（38 提交差）。
3. 验收文档 NO-GO 与 Release 事实冲突。
4. 分支保护规则不可读，合并策略需人工确认。
5. Windows 安装器/缩略图/文件关联未在真机验证；Linux AppImage 未人工验收。
6. macOS 未公证；无 Developer ID。
7. ja/ko 146 键缺失（用户可见）。
8. AAB 组件/权限缺失，导致 AAB 的安全审计能力弱于 APK。
9. IPA 安装页无元数据，用户难以确认装的是哪个包。
10. 性能只有历史基线，无 2.11.0 vs 2.10.6 的同样本对比。
11. `AnalysisRun.snapshot` 只写不读：历史页没有「查看归档快照」入口，审计价值未兑现（Phase 5 需要决定是补入口还是明确只做重解析）。

---

## 附：本次审计命令记录

```bash
git branch --show-current && git rev-parse HEAD && git status --porcelain
git log --oneline origin/main -1 && git rev-list --count origin/main..HEAD
git tag --list 'v2.11*' --format='%(refname:short) %(objectname:short) -> %(*objectname:short)'
curl -s "https://api.github.com/repos/wongbaye26-dot/appinfotools/pulls?state=all"
curl -s -o /dev/null -w "%{http_code}" ".../branches/main/protection"
cat .github/allow-no-samples && grep -n "allow-no-samples" .github/workflows/build.yml
curl -s ".../releases/tags/v2.11.0"   # body / assets
grep -n "uses-permission\|uses-feature\|debuggable\|compileSdk\|activity" packages/apk_parser/lib/src/aab/aab_reader.dart
python3  # 六语言键集对比
grep -rn "dex" lib/ui/diff/diff_page.dart
command -v idevice_id; command -v ideviceinstaller
grep -rn "artifacts\|loadGraph" packages/analysis_model/lib/src/security_finding.dart lib/utils/analysis_report.dart
command -v flutter && flutter analyze && flutter test
```
