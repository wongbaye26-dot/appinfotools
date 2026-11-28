# AppInfoTool 2.11.0 基线审计（Stage 0）

> 审计日期：2026-11-27  
> 审计范围：当前工作区，只读审计；未修改业务代码。  
> 目标版本：2.11.0 “Security Intelligence & Evidence Center”  
> 当前版本：2.10.6  
> 结论：**UI V4 已完成但未提交；F01–F10 均不存在完整实现；2.11.0 需要以适配层为主，不能直接按“已有能力”接 UI。**

---

## 1. 基线事实

| 项目 | 实际值 |
|---|---|
| 工作目录 | `/Users/wangbaye/Projects/AppInfoTool` |
| 分支 | `main` |
| HEAD | `5c4db5a`（2026-11-26 `chore(release): 2.10.6`） |
| Tag | `v2.10.6` |
| Pubspec 版本 | `2.10.6` |
| 最新 tag | `v2.10.6`（`v2.10.5`、`v2.10.4`、`v2.10.3`、`v2.10.2` 依次在前） |
| 工作区 | **脏**：73 个路径有变化（V4 UI + 2.10.7 P1 整改） |
| 最新审计 | `docs/audit/2026-11-27-module-completeness-audit.md`、`docs/audit/APPINFOTOOL_2.10.7_P1_REMEDIATION_ACCEPTANCE.md` |
| 当前测试基线 | root 1875 pass / 19 skip；packages 683 pass；analyze clean；format 457/0；build bundle 0 |

### 1.1 工作区未提交内容

V4 UI 与 2.10.7 整改均未提交，主要包括：

- V4 主题/壳/侧栏/顶部栏：`lib/theme/v4_theme.dart`、`lib/ui/shell/{app_shell,sidebar,v4_top_bar,v4_command_palette}.dart`、`lib/ui/shell/page_header.dart`。
- 页面：`lib/ui/overview/overview_page.dart`、`lib/pages/info_page.dart`、`lib/pages/install_page.dart`、`lib/pages/setting_page.dart`、`lib/ui/diff/diff_page.dart`。
- 2.10.7：iOS FairPlay（`packages/ipa_parser/lib/src/macho.dart`、`ios_privacy_audit.dart`）、Android artifacts/loadGraph（`SecurityAnalysisResult`、`android_security_audit.dart`）、页面状态、样本门禁、缩略图默认关闭。
- 大量 `docs/audit/`、`docs/prototypes/` 未跟踪文件。

**审计判断：** 2.11.0 不能在未提交的 73 文件基线上直接叠加。Stage 1 开始前必须先决定并执行一次 V4/2.10.7 基线提交（或建独立分支快照），否则后续无法区分“2.11 改动”与“2.10.7/V4 改动”，也无法可靠回滚。

---

## 2. 总体结论

当前代码已经具备一套**平台中立的安全分析模型**（findings / evidence / coverage / artifacts / loadGraph），但它是 2.10.x 的“单次分析结果对象”，不是 2.11.0 的“分析记录 + 证据中心 + 历史库”。

按 F01–F10 对照：

| 功能 | 现状 | 判断 |
|---|---|---|
| F01 AnalysisRun + 持久化 | 无 AnalysisRun，无分析 ID；只有 `RecentFileEntry` 的最近文件元数据 | ❌ 缺失 |
| F02 Evidence 中心 | `SecurityEvidence` 已嵌入 finding，有真实 source/location；无 Evidence ID、分类、搜索、详情、全局列表 | 🟡 部分 |
| F03 Finding 关联证据 | `SecurityFinding` 有 ruleId/severity/confidence/evidence；无独立 Evidence 引用、无筛选/详情闭环 | 🟡 部分 |
| F04 Coverage | `AnalysisCoverage` + 13 个 Android 维度/10 个 iOS 维度；缺 failed/notScanned、scanner 级 discovered/scanned/skipped/budget | 🟡 部分 |
| F05 Artifact Inventory | 已有真实 inventory 模型与 Android scanner，接入报告/UI 摘要；无逐文件 SHA、无 split inventory、无表格/搜索/筛选 | 🟡 部分 |
| F06 Android Load Graph | 已有真实 Android scanner + 模型，序列化到报告，UI 只有计数 | 🟡 部分 |
| F07 Network Clues | 有 DEX/iOS 静态 domain/IP 提取，写入 `NetworkFacts`；无 URL/IPv6/API/WebSocket、无来源/证据关联、无 UI 列表 | 🟡 部分 |
| F08 JSON/HTML 报告 | JSON/Markdown 已有（schema v8）；无 HTML，无 AnalysisRun 头，无 top-level evidence，无 toolVersion/status/time | 🟡 部分 |
| F09 历史/复查 | 无分析结果保存/重开；只有最近文件路径 | ❌ 缺失 |
| F10 样本回归 | 已有真实样本测试、smoke、tag 发布门禁；无固定样本矩阵/期望基线，CI 样本变量未配置 | 🟡 部分 |

---

## 3. 当前架构与真实调用链

### 3.1 Android 入口

- `lib/apkparser/apk_info.dart:299` `getApkInfo(...)`
- `lib/apkparser/parse_task.dart` 解析任务/进度事件；构建 `SecurityAnalysisResult`。
- `packages/apk_parser/lib/src/security/android_security_audit.dart:audit(...)`
  - 入参已包含：`ArtifactInventory? artifacts`、`LoadGraph? loadGraph`、`PayloadProbeResult? payloadProbe`、`SealCheck? seal`、`BaselineMatch? baseline`、`nativeLibraryTotal`、`nativeSkipped`、`splitTotal`、`splitAudited`。
  - 返回 `SecurityAnalysisResult`，`artifacts`/`loadGraph` 已进入结果。
- `packages/apk_parser/lib/src/security/artifact_inventory_scanner.dart` 生成 inventory。
- `packages/apk_parser/lib/src/security/android_load_graph.dart` 生成 load graph。

### 3.2 iOS 入口

- `lib/ipaparser/ipa_parse_task.dart:84` `IpaParseTask`。
- `lib/ipaparser/ipa_analysis.dart:252` `IpaAnalysisReader`。
- `lib/ipaparser/ipa_analysis.dart:678` 调用 `IosPrivacyAudit.audit(...)`。
- `packages/ipa_parser/lib/src/security/ios_privacy_audit.dart:318` `IosPrivacyAudit.audit(...)`。
  - 2.10.7 已加入 `MachOEncryptionInfo` / `IOS-ENCRYPTED-BINARY` / `ios.encryption` 覆盖 / `IOS-RULE-F` 加密降级。
  - 返回 `SecurityAnalysisResult`；inventory/loadGraph 目前仍为 iOS 的 null 或平台内解析结果。

### 3.3 UI 统一结果

- `lib/providers/info_page_provider.dart:101` `FileState`。
  - 字段：`filePath`、`fileSize`、`apkInfo`、`ipaAnalysis`、`iosCodeSign`、`md5Hash`、`sha1Hash`、`sha256Hash`、`signature`、`securityResult`。
  - `FileState.analysis` 派生 `PackageAnalysisResult`（不是持久化记录）。
- `lib/models/analysis/package_analysis_result.dart:297` `PackageAnalysisResult`。
  - 平台中立字段 + `android`/`ios` + `security` + `splitConsistency` + `diagnostics`。
  - 无 analysisId、开始/结束时间、run status、toolVersion。
- `lib/pages/info_page.dart`
  - `_buildAndroidCards` / `_buildIosCards` 直接消费 `FileState`/`PackageAnalysisResult`。
  - 安全区消费 `SecurityAnalysisResult`；平台 tab 为 `overview/manifest/components/permissions/security/files/infoPlist/frameworks/signature/diagnostics`。
  - `SecurityFindingCard` 直接展示 finding 内嵌的 evidence；没有全局 Evidence 中心。

### 3.4 报告

- `lib/utils/analysis_report.dart:29` `AnalysisReport`。
- `reportSchemaVersion = 8`（`:2677`）。
- `render(...)` Markdown；`renderJson(...)` JSON（`:2691`）。
- JSON 顶层（实际）：`reportSchemaVersion`、`reportId`、`generatedAt`、`inputArtifact`、`fieldStatus`、`platformFacts`、`application`、`signatureSummary`、`securitySummary`、`security{cryptoTheft,artifacts,loadGraph,seal,baseline}`、`network{domains,ips}`、`splitConsistency`、`findings`（evidence 内嵌）、`coverage{hasGaps,entries}`、`diagnostics`、`engineVersions`、`rulesVersions`、`limitations`。
- 缺少：`analysis.id/toolVersion/status/startedAt/completedAt`、顶层 `evidence[]`、顶层 `graph`、`networkClues[]`、`artifacts[]` 的哈希/搜索字段、HTML 渲染。
- `lib/utils/report_exporter.dart` 只负责把已生成文本通过 FilePicker 保存；没有报告归档/历史/HTML。

### 3.5 最近文件/持久化

- `lib/utils/recent_files.dart:8` `RecentFileEntry`，`:66` `RecentFilesManager`。
- 存储于 `shared_preferences`（`Config.recentFiles`），最多 10 条，按路径去重；字段只有 `path/size/analyzedAt/platform/iconFile`。
- **没有** AnalysisRun、findings、evidence、coverage、artifact、loadGraph、report 的持久化。
- `path_provider: ^2.1.2` 与 `shared_preferences: ^2.3.3` 均已在 pubspec 中，可用于本地报告/记录存储，无需引入新的大型数据库依赖。

---

## 4. 功能逐项审计

### F01 统一分析结果与持久化（P0）

**现状：缺失。**

- `PackageAnalysisResult` 是纯内存派生对象；关闭/切换文件后不可恢复。
- 没有 analysisId、run status、start/complete time、toolVersion、analysis↔file 持久关联。
- 没有 `AnalysisRun` 模型/仓库/序列化/迁移。
- 现有 `RecentFilesManager` 只保存路径和时间，不能重新打开分析结果。

**可复用：**

- `PackageAnalysisResult` 的字段投影可作为 AnalysisRun 的 `result` 载荷。
- `path_provider` 可用于 `ApplicationSupportDirectory` 下按 run 存 JSON；`shared_preferences` 可存索引。无需引入数据库即可满足 P0 规模。
- `FileState.analysis` 的派生方式可作为“构建 run 载荷”的唯一入口，避免 UI 与持久化各自拼数据。

**最小改造：**

1. 新模型 `AnalysisRun`：`id`、`toolVersion`、`file identity`、`startedAt/completedAt`、`status`、`platform`、`result`（现有结果）、`limitations`。
2. `AnalysisRunRepository`：JSON 文件 + 索引；写入原子化（临时文件 rename）。
3. 解析开始创建 run（queued/running），解析结束按实际结果 success/partial/failed/cancelled。
4. `FileState` 增加 `runId`；UI 只读 run，不直接持久化。
5. 历史列表复用 `RecentFiles` 的 UI 位置，但数据源改为 run 索引；旧 recent 数据做兼容迁移或只读展示。

**风险：** 不能把 `RecentFileEntry` 直接升级成 AnalysisRun（缺 findings/evidence/coverage）。必须新增模型，旧数据只做迁移入口。

### F02 Security Evidence 中心（P0）

**现状：部分实现，但没有“中心”。**

- `SecurityEvidence`（`packages/analysis_model/lib/src/security_finding.dart:256`）只有：
  `source`、`location`、`locationCode/Args`、`detail`、`detailCode/Args`。
- 无 Evidence ID、analysis ID、category/type、raw/normalized、confidence、offset、archive entry、extractor ID、metadata。
- evidence 只作为 `SecurityFinding.evidence` 内嵌；同一证据不能跨 finding 去重/关联。
- UI 仅在 finding 卡片里展示 `_EvidenceTile`；没有列表、分类筛选、搜索、详情、导出。
- JSON 只在 finding 内输出 `evidence`，没有顶层 `evidence[]`。

**可复用：**

- `SecurityEvidence.source/location/detail` 已来自真实扫描；扩展字段时可保留原语义。
- Android/iOS 的 finding evidence 已有稳定 `locationCode/detailCode`，可作为 Evidence 的显示文案来源。

**最小改造：**

1. 新 `Evidence` 实体：`id`、`analysisId`、`category`、`type`、`title/description`、`sourceFile`、`archiveEntry`、`offset`、`extractorId`、`rawValue`、`normalizedValue`、`confidence`、`metadata`。
2. 由现有 `SecurityEvidence` 生成，**不改变扫描器**；ID 使用 `analysisId + source + location + detail hash` 的稳定派生。
3. Finding 增加 `evidenceIds`，保留旧 `evidence` 兼容字段；报告同时输出顶层 evidence 与 finding 引用。
4. 先做“真实来源必填”校验：无 source/location 的 evidence 拒绝进入正式列表。

**风险：** 当前 evidence 的 `location` 可能只是描述，不是文件路径/offset；不能为了满足字段而伪造 offset。缺失 offset 必须为 null，并在 UI 展示“未提供”。

### F03 Finding 与证据关联（P0）

**现状：部分实现。**

- `SecurityFinding`（`:302`）已有 ruleId/platform/category/severity/confidence/finding/evidence/recommendation/limitation/messageCode/relationship/dataSource/sink/transform/isMeta/blindSpots。
- 没有 Finding ID、rule pack ID、独立 evidence ID 列表；没有统一风险等级映射表（当前直接用 `SecuritySeverity`）；没有全局筛选/分类浏览。
- UI `SecurityFindingCard` 只按发现展示，默认按 tab/严重度分组，没有“按证据反查 finding”。

**可复用：**

- 现有 `countBySeverity`、`highestRiskFinding`、`hasActualGaps`、`messageCode`/`recommendationCode`/`limitationCode` 语言层已经成熟。
- 现有 ruleId 命名可继续作为 2.11 的 rule ID，不需要改规则。

**最小改造：**

1. 给 finding 增加稳定 `id`（`analysisId + ruleId + primary evidence location hash`）与 `evidenceIds`。
2. 增加规则元数据表：`ruleId → title/description/recommendation/limitation`，当前代码里的 switch 文案可迁移/复用。
3. UI 先做筛选/搜索/详情，不重写 detection。
4. 保留 `evidence` 内嵌字段作为旧报告兼容；新报告以 ID 引用为准。

**风险：** 同一 rule 多次命中同一证据时 ID 必须稳定；不能用随机 UUID，否则历史对比失效。

### F04 Coverage（P0）

**现状：部分实现。**

- `AnalysisCoverage`（`analysis_coverage.dart:132`）只有 `entries`；`CoverageEntry`（`:42`）字段 `id/status/covered/limit/note/noteCode/noteArgs`。
- `CoverageStatus`（`:5`）只有 `covered/partial/notCovered/notApplicable`。
- Android 13 个维度、iOS 10 个维度（2.10.7 加 `ios.encryption`）；Stage B 加 `android.artifacts/payloadProbe/loadGraph/nativeLibraries/splitSampling`。
- 缺 `failed`/`notScanned`；缺 scanner 级 `itemsDiscovered/itemsScanned/itemsSkipped/budget/affectedArtifacts`。
- 现有覆盖率是“维度级”，不是“扫描器执行记录”；UI/JSON 已有展示。

**可复用：**

- Android/iOS audit 已有真实扫描/截断/预算数据（`nativeSkipped`、`splitTotal/splitAudited`、`payloadProbe.entriesProbed/entriesTotal`、`artifacts.entriesComplete/skippedCodes`）。
- 现有 `CoverageEntry.noted` 与报告 `coverage.entries` 可平滑扩展。

**最小改造：**

1. 扩展 `CoverageStatus`：增加 `failed`、`notScanned`；明确 `notApplicable` 不计 gap。
2. 扩展 `CoverageEntry`（或新增 `CoverageScannerEntry`）：`itemsDiscovered/itemsScanned/itemsSkipped/budget/affectedArtifacts/scannerId/limitation`。
3. 每个 scanner 返回自己的执行记录，audit 汇总；不要从 finding/limitation 反推。
4. 报告/UI 增加模块级明细；总体百分比必须保留模块失败/未扫描标记。
5. 对旧报告：缺字段按旧维度读取，不视为失败。

**风险：** 当前 `CoverageStatus.covered` 的含义是“维度覆盖”，扩展 status 会影响 `hasActualGaps` 和所有语言键；必须加迁移测试。

### F05 Artifact Inventory（P0）

**现状：部分实现。**

- `ArtifactInventory`/`ArtifactEntry` 模型已存在（`artifact_inventory.dart:12/155`）。
- Android scanner（`packages/apk_parser/lib/src/security/artifact_inventory_scanner.dart`）扫描 base APK ZIP entries，`defaultMaxEntries=2000`，排序后截断；`entriesComplete=false` + `inventory.entries_truncated`。
- 关键缺口：
  - `sha256` **从不填充**；
  - `contentScanned` 恒为 false、`skipCode='not.selected'`；
  - 只做 base APK，不合并 split inventory；
  - 无文件搜索/筛选/排序/哈希 UI；
  - 报告只是 `security.artifacts` 对象；无顶层 artifacts 数组。
- 2.10.7 Stage B 已把 inventory 接入 `SecurityAnalysisResult`、JSON、`SecurityEvidenceCard` 摘要。

**可复用：**

- ZIP entry facts 已有 path/kind/origin/size；归档安全机制（`packages/archive_safety`）可复用，绝不能绕过。
- `splitTotal/splitAudited` 已有 split 覆盖；inventory 合并可先按 `split:<label>/<path>` 路径前缀，不重构 APK 读取。

**最小改造：**

1. 增加可选 `sha256` 计算入口，仅对已扫描/用户请求的 artifact 计算，避免全包哈希拖慢解析。
2. 合并 split entries 为同一 inventory（保留 `origin`/`source split`），并记录截断。
3. 修正 `contentScanned`/`skipCode` 语义：实际扫描的 artifact 标记 true；未扫描明确 notSelected/budgetSkipped。
4. UI 增加 artifact 表格（筛选/搜索/大小排序/哈希复制），放在现有 Files 或 Security tab，不新建壳。
5. 报告输出顶层 `artifacts[]` 或保留 `security.artifacts` 并增加条目哈希；需在 Stage 1 schema 里定。

**风险：** 全量 SHA-256 成本高；大包可能超时。必须按需计算并保留预算/失败状态。

### F06 Android Load Graph（P1）

**现状：部分实现。**

- `LoadGraph`/`LoadNode`/`LoadEdge` 已存在（`load_graph.dart:7`）。
- `AndroidLoadGraphScanner` 已从 DEX/native/resource facts 生成真实节点/边；2.10.7 Stage B 接入结果与 JSON。
- 关键缺口：
  - 节点/边没有独立 ID（边只有 fromId/toId 复合语义）；
  - 边没有 evidence IDs、没有 inferred 标记；
  - UI 只有 `SecurityEvidenceCard` 的 counts（nodes/edges/dangling），没有图/表；
  - iOS 无 load graph。
- 报告 `security.loadGraph` 已有 nodes/edges/danglingEdgeIds/complete。

**可复用：**

- 现有 scanner 的节点/边生成逻辑就是真实依据；不要重写 DEX 解析。
- 现有 `LoadEdge.source/location` 可作为 Evidence 来源。

**最小改造：**

1. 给 `LoadEdge` 增加 `id`、`evidenceIds`、`inferred=false`（默认 false）；`LoadNode` 尽量关联 `artifactPath`。
2. 校验所有 edge 的 from/to 均存在；`danglingEdgeIds` 已有，保留。
3. UI 增加表格优先（Nodes/Edges/Dangling），图形视图可选；大数据降级。
4. 报告输出 `graph.nodes/edges`（已有）并补充 evidence IDs/inferred。

**风险：** 不能为了 UI 图形补造节点；边的 evidence 只能来自真实 DEX/native 引用记录。

### F07 Network Clues（P1）

**现状：部分实现，范围明显小于说明书。**

- `NetworkFacts`（`network_facts.dart:5`）只有 `domains`、`ips`。
- `NetworkEndpoints`（`network_endpoints.dart:17`）从字符串提取；`maxEndpoints=50`；domain TLD 白名单；只支持 IPv4。
- Android audit `:2012` 写入 `NetworkFacts(domains: scan.domains, ips: scan.ips)`；iOS audit `:2445` 写入 domainSet/ipSet。
- 没有 URL、IPv6、API endpoint、WebSocket 类型；没有 source artifact/evidence ID；报告只有 `network.domains/ips`；无 UI 网络线索列表。

**可复用：**

- 现有 `NetworkEndpoints` 的正则、去重、白名单、预算限制可作为基础。
- DEX 字符串/iOS strings 扫描已有真实数据源。

**最小改造：**

1. 新 `NetworkClue`：`id`、`type`、`rawValue`、`normalizedValue`、`sourceArtifact`、`evidenceIds`、`confidence`、`metadata`。
2. 在现有 extractor 上增加 URL/WebSocket 识别；IPv6 只在可靠解析时支持；不要主动联网。
3. 每个 clue 记录来源 artifact 路径（真实扫描路径），无来源不进入正式列表。
4. UI 增加列表 + 搜索/复制/来源跳转；文案必须写“静态线索，不代表运行时访问”。
5. 报告输出 `networkClues[]`，保留旧 `network` 兼容。

**风险：** URL 正则误报、超长字符串、国际化域名；必须有过滤/去重测试。IPv6 解析错误率高，宁可不支持也不要误报。

### F08 JSON/HTML 报告（P1）

**现状：部分实现。**

- Markdown + JSON 已有，`reportSchemaVersion=8`。
- JSON 覆盖较全（fieldStatus、platformFacts、security、coverage、findings/evidence 内嵌、network），但：
  - 无 `analysis.id/toolVersion/status/startedAt/completedAt`；
  - 无顶层 `evidence[]`；
  - 无顶层 `graph`（现在在 `security.loadGraph`）；
  - 无 `networkClues[]`；
  - 无 HTML。
- `ReportExporter` 只保存文本；`ExportReportDialog` 只有 Markdown/JSON。
- HTML 转义完全未实现（因为没有 HTML）。

**可复用：**

- `AnalysisReport.renderJson` 是唯一 JSON 出口，应扩展而不是另建一套。
- Markdown 渲染可拆出 HTML 复用同一数据映射；但不要直接把 Markdown 当 HTML。

**最小改造：**

1. Stage 1 定义 2.11 报告 schema（`schemaVersion: "2.11"` 或 `2.0`），明确 analysis header、evidence、graph、networkClues、artifacts 位置。
2. 保留 `reportSchemaVersion=8` 旧报告读取/兼容；新报告加版本字段。
3. 新增 `AnalysisReport.renderHtml`，所有样本内容必须 `HtmlEscape`；禁止字符串拼 script。
4. UI 导出选项加 HTML；失败显示明确错误。
5. 报告必须从 AnalysisRun 渲染，不是从 UI 临时状态拼。

**风险：** 不能直接改 v8 schema 的必填字段导致旧报告不可读；先做版本分支/迁移测试。

### F09 历史与复查（P1）

**现状：缺失。**

- 无保存的 findings/evidence/coverage 结果；`RecentFiles` 只记录路径，文件移动/删除后无法复查。
- 无历史列表筛选项（名称/平台/状态/哈希）；无删除确认。

**最小改造：**

- 依赖 F01 的 `AnalysisRunRepository`；历史页复用现有 Overview 的 recent 区域，增加筛选/删除。
- 重新打开历史时只读 run，不重新解析（除非用户主动“重新分析”）。
- 文件路径变化不能覆盖旧 run：以 runId + sha256 为主键，路径只作展示。

### F10 样本回归（P0）

**现状：部分实现。**

- 已有：
  - `test/real_samples_test.dart`、`test/real_samples_ui_test.dart`、`test/real_samples_smoke_test.dart`；
  - `APPINFOTOOL_SAMPLES` / `APPINFOTOOL_REQUIRE_SAMPLES`；`APPINFOTOOL_ALLOW_NO_SAMPLES` 显式豁免；
  - CI `.github/workflows/build.yml:151-193` external-samples job；`:897-899` create-release 依赖 external-samples；
  - `tool/runtime_smoke/*` 启动冒烟。
- 缺：
  - 固定样本矩阵/样本 SHA/来源/许可/预期 Evidence/Finding/Coverage；
  - 异常包/超预算/恶意 HTML 等专项回归；
  - CI 目前未配置 `APPINFOTOOL_SAMPLES` 仓库变量，发布 tag 会被门禁阻断（这是正确行为，但需要配置/豁免决策）；
  - 本地混合语料 `/tmp/appinfotool-samples` 不是稳定资产。

**最小改造：**

- 建立 `test_samples/` 或外部配置清单（不能把大样本提交仓库）；用 manifest 记录 SHA/预期。
- 把 2.11 新增关系校验（evidence 引用、graph 边、artifact 哈希、coverage 完整性、report 一致性）加入 sample smoke。
- 保持现有 tag 门禁，配置样本前不发布。

---

## 5. UI V4 现状与 2.11 接入点

V4 UI 已完成（未提交），页面结构：

- Shell：`lib/ui/shell/app_shell.dart`（顶部栏 + 浮动侧栏 + IndexedStack）。
- Overview：`lib/ui/overview/overview_page.dart`（hero + posture + 统计 + 最近文件）。
- Analysis：`lib/pages/info_page.dart`（平台 7 tab + 3 列 facts grid + right rail）。
- Diff：`lib/ui/diff/diff_page.dart`（字段表 + 集合表 + summary rail）。
- Install：`lib/pages/install_page.dart`（两栏 + 深色日志）。
- Settings：`lib/pages/setting_page.dart`（左栏 + 混合卡片网格）。
- States：`lib/widgets/analysis_state_panel.dart`。

2.11 接入原则（不重做 UI）：

| 页面 | 接入方式 | 现有落点 |
|---|---|---|
| Overview Active | run 状态/风险摘要/历史/coverage | `_buildCurrentFilePanel`、`_buildPostureCard` |
| Android Analysis | Finding/Evidence/Artifact/LoadGraph/Network | 现有 `security` tab + 新增数据卡/表 |
| iOS Analysis | Mach-O/签名/Artifact/Coverage/限制 | 现有 `frameworks`/`signature`/`security`/`diagnostics` tab |
| Diff | 只读现有结果，预留安全差异数据接口 | `lib/ui/diff/diff_page.dart` |
| Install | 不重构 ADB | 保持不变 |
| Settings | 报告/历史设置 | `lib/pages/setting_page.dart` |
| States | run queued/running/partial/failed/cancelled | 现有 `AnalysisPageStatus` 仅页面态，需与 run status 映射 |

关键约束：当前 `AnalysisPageStatus` 是 `empty/loading/partial/failure/success`，不是 run 状态机；2.11 需要新增 run status 并明确映射，不能混用。

---

## 6. 最小必要改造方案（建议 Stage 1–6）

### Stage 1（P0，先做）

- 新增 `AnalysisRun` + `AnalysisRunRepository`（JSON 索引 + 单 run 文件，`path_provider`）。
- `FileState` 增加 `runId`/run status；解析开始/结束创建和落盘。
- 不改变解析器/规则/UI 壳；只在 `FileState.analysis` 出口组装 run payload。
- 兼容旧 `RecentFiles`：迁移为“无结果旧记录”，不伪造 findings。
- 验收：重启后历史可读；同文件新分析不覆盖旧 run；损坏 run 文件可跳过并诊断。

### Stage 2（P0）

- 新 `Evidence` 实体 + ID/analysisId/category/type/raw/normalized/confidence/offset（可空）。
- 由现有 `SecurityEvidence` 适配生成；Finding 增加 `evidenceIds`；报告加顶层 `evidence[]`。
- Coverage 增加 failed/notScanned/scanner 统计；Android/iOS audit 写入真实执行记录。
- 验收：每个 finding 的 evidenceIds 都有效或显式 limitation；无来源 evidence 拒绝进入列表。

### Stage 3（P0/P1）

- Artifact：split 合并、按需 SHA-256、contentScanned 真实化、UI 表格。
- LoadGraph：edge id/evidenceIds/inferred、表格优先；图视图可选。
- 验收：artifact 数量与归档一致；edge 端点有效；哈希与外部工具一致。

### Stage 4（P1）

- NetworkClue 模型 + URL/IPv6/WebSocket（按可靠能力）；来源 artifact/evidence；UI 列表和报告。
- 不做主动联网。

### Stage 5（P1）

- 2.11 报告 schema + HTML；从 AnalysisRun 渲染；HTML 全量转义；历史复查入口。
- 保留 v8 旧报告兼容读取。

### Stage 6（P0）

- 固定样本矩阵/期望值/回归脚本；补齐异常包、超预算、HTML 注入、关系完整性、报告一致性测试。
- 跨平台实际运行记录；未执行平台明确标注。

---

## 7. 风险与审计结论

### 7.1 主要风险

1. **基线未提交**：V4 + 2.10.7 共 73 文件未提交，直接开发 2.11 会导致 diff/回滚不可控。这是 Stage 1 前的第一阻断。
2. **模型扩展会碰 schema**：当前 `SecurityAnalysisResult`/报告 v8 已被 2.10.x 消费；新增字段必须保持旧报告可读。
3. **Evidence 位置真实性**：现有 evidence 的 location 不一定是文件路径/offset。不能为了字段完整而伪造，必须允许 null 并标限制。
4. **Artifact 全量哈希性能**：大包/多 split 全量 SHA 会显著拖慢；必须按需/预算。
5. **Coverage 语义扩展**：新增 failed/notScanned 会影响 `hasActualGaps`、UI 文案、报告；需要迁移测试。
6. **样本门禁**：CI 未配置 `APPINFOTOOL_SAMPLES`，tag 发布会被阻断；这是预期安全行为，但需要产品决策配置真实样本或明确豁免。
7. **UI V4 未提交**：2.11 的数据卡/表格必须接在现有 V4 组件里，不能再改主题/壳；先冻结 V4。

### 7.2 审计结论

- 2.11.0 的基础不是“从零开始”：`PackageAnalysisResult`、`SecurityAnalysisResult`、`AnalysisCoverage`、`ArtifactInventory`、`LoadGraph`、`NetworkFacts`、`AnalysisReport` 都是可复用的真实资产。
- 但 F01/F09 完全缺失，F02/F03/F04/F05/F06/F07/F08/F10 都只是“部分数据已存在”，离说明书要求还有结构、ID、持久化、UI、报告五类差距。
- **不能直接进入功能开发**。Stage 1 必须先落 AnalysisRun + 持久化，并冻结 V4/2.10.7 基线；否则后续 evidence/coverage/report 都会建立在临时状态上。

### 7.3 Stage 0 验收状态

- [x] Git/版本/工作区确认
- [x] 当前 UI V4 页面/结构确认
- [x] Android/iOS 分析入口确认
- [x] SecurityFinding/Evidence/Coverage/Artifact/LoadGraph/Network 模型确认
- [x] 报告导出能力确认
- [x] 历史/持久化能力确认
- [x] 可复用/部分/缺失模块清单
- [x] 最小改造阶段建议
- [ ] 基线提交/分支冻结（需要用户决策后执行，Stage 0 未做）

**建议：** 先由用户确认是否将当前 V4 + 2.10.7 变更提交为一个基线 commit（或建 `release/2.11` 分支），然后再开始 Stage 1。2.11.0 的 P0 目标应以 F01/F02/F03/F04/F05/F10 为第一闭环；F06/F07/F08 作为 P1 在闭环后接入。
