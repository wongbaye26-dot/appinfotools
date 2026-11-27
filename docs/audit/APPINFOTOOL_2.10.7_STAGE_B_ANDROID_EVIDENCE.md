# AppInfoTool 2.10.7 — Stage B（Android 证据模型与覆盖模型）阶段验收报告

- 阶段：B（仅 Stage B；C–G 未开始）
- 基线版本：2.10.6
- 起点 commit：`5c4db5a chore(release): 2.10.6`
- 起点 tag：`v2.10.6`
- 当前工作区：Stage A + Stage B 修改尚未提交（无新 commit、无新 tag）
- 任务来源：`docs/audit/2026-11-27-module-completeness-audit.md` P1-3、P1-4；用户 2.10.7 任务书
- 验收状态：**本阶段实现完成，等待人工验收后进入 Stage C**

## 1. 本阶段解决的问题

审计 P1-3：Android 侧其实已经计算了 `ArtifactInventory` 与 `LoadGraph`，但 `SecurityAnalysisResult` 没有对应字段，报告 JSON 硬编码为 `null`，UI 也从不展示 —— 计算完就丢，用户无法核对“这份结论看过了哪些制品、加载链是否完整”。

审计 P1-4：artifact / payload / native / split 的截断只出现在 `limitations` 文本里，没有进入结构化 `AnalysisCoverage`；`hasActualGaps` 可能在真实截断发生时仍为 false。payload 的调用方 cap 64 还会把“还有候选没探测”隐藏成 `complete=true`。

本阶段把证据与覆盖范围补齐：

- `ArtifactInventory`、`LoadGraph` 进入正式 `SecurityAnalysisResult`；
- 报告 JSON 输出两者（v8 schema 早已声明这两个键，本次只是把值接上，不升版本）；
- UI 新增结构化证据卡片；
- 新增 5 个 Android 覆盖维度，真实截断进入 `partial` / `hasActualGaps`；
- payload 候选计数改为“先数全量，再按预算探测”，不再假报完整；
- split 审计传入“声明总数 / 实际审计数”，提取上限不再隐藏未审计分包。

## 2. 修改文件清单

### 生产代码

| 文件 | 改动 |
| --- | --- |
| `packages/analysis_model/lib/src/security_finding.dart` | `SecurityAnalysisResult` 新增 `ArtifactInventory? artifacts`、`LoadGraph? loadGraph`；构造函数与 `withFinding` / `withLimitation` 均保留 |
| `packages/apk_parser/lib/src/security/android_security_audit.dart` | 结果返回 artifacts/loadGraph；新增 `splitTotal` / `splitAudited` 参数；新增 `android.artifacts`、`android.payloadProbe`、`android.loadGraph`、`android.nativeLibraries`、`android.splitSampling` 五个覆盖维度 |
| `lib/apkparser/parse_task.dart` | `_probePayloads` 统计全部候选，cap/尺寸/读取失败计入 skipped，返回真实 `entriesTotal` 与 `complete=false` |
| `lib/apkparser/apk_info.dart` | base 分包路径同样修正 payload 计数；传入 split 声明总数/实际审计数 |
| `lib/utils/analysis_report.dart` | 报告 JSON 接入 `_artifactInventoryJson` / `_loadGraphJson`；新增 5 个维度名与 11 条覆盖说明的本地化分发 |
| `lib/widgets/security_evidence_card.dart` | 新增结构化证据卡片（制品数量/总数/截断；加载链节点/边/悬空边/完整性） |
| `lib/pages/info_page.dart` | Android/iOS 共用的安全卡片区在概览后插入证据卡（仅当 artifacts/loadGraph 非空） |
| `assets/i18n/{en,zh-CN,zh-TW,zh-HK,ja,ko}.json` | 新增 5 个覆盖维度、11 条覆盖说明、6 条证据卡文案；6 种语言均实际翻译 |

### 测试

| 文件 | 改动 |
| --- | --- |
| `test/analysis_coverage_test.dart` | 新增 artifact/loadGraph 进入结果、artifact 截断、payload partial、loadGraph partial、split 8/12 partial、native 1/3 partial、缺省 notCovered 等测试 |
| `test/analysis_report_test.dart` | 新增 JSON 中 artifacts/loadGraph 非空、schema 仍为 8 的测试 |
| `test/security_evidence_card_test.dart` | 新增证据卡渲染与“两项皆空不渲染”测试 |
| `packages/analysis_model/test/analysis_model_test.dart` | 新增 copy 方法保留 artifacts/loadGraph 的测试 |
| `test/coverage_note_registration_test.dart` | 覆盖说明参数夹具补齐 `probed/nodes/edges/covered/audited` |

### 生成物

- `dart run build_runner build --delete-conflicting-outputs` 重新生成 `lib/gen/strings*.g.dart`；该目录被 `.gitignore` 忽略，不进入提交。
- 生成物随后经 `dart format` 格式化，否则全仓格式门禁会把生成文件算作未格式化。

## 3. P1-3 对照

| 任务书要求 | 实现与证据 | 状态 |
| --- | --- | --- |
| 将已计算的 Artifact Inventory 纳入正式分析模型 | `SecurityAnalysisResult.artifacts` 为强类型字段；审计结果原样返回；`analysis_coverage_test` 用 `same(inventory)` 断言不是重建/丢弃 | 完成 |
| 将 Load Graph 纳入正式分析模型 | `SecurityAnalysisResult.loadGraph`；`same(graph)` 断言 | 完成 |
| 修改报告序列化 | `security.artifacts` / `security.loadGraph` 输出完整结构；JSON 测试断言 `totalEntries`、`entriesComplete`、节点/悬空边 | 完成 |
| 修改报告 schema | v8 schema 已声明 `artifacts`/`loadGraph` 与 `$defs`，本次无需改结构，`reportSchemaVersion` 保持 8；用真实渲染的 `security` 对象对 schema 校验 0 错误 | 完成（无版本号变更，理由见 §6） |
| 在 UI 中展示结构化证据 | `SecurityEvidenceCard` 展示制品/加载链数量、截断、悬空边、不完整状态；空数据不渲染，避免暗示“查过” | 完成 |
| 保留扫描限制、截断及采样状态 | 制品 `entriesComplete/skippedCodes`；加载链 `complete/danglingEdgeIds`；payload `entriesProbed/entriesTotal/complete`；split `splitAudited/splitTotal` 均进入模型或覆盖 | 完成 |
| 保证旧报告兼容 | 两个字段可为 null；旧报告/旧调用方不传时输出 `null`，v8 消费方仍可解析；无字段删除、无格式变更 | 完成 |

## 4. P1-4 对照

| 任务书要求 | 实现与证据 | 状态 |
| --- | --- | --- |
| Artifact 截断 | `android.artifacts`：`entriesComplete=false` → `partial`，说明截断；未提供 → `notCovered` | 完成 |
| Payload 截断 | `android.payloadProbe`：`entriesTotal` 为**全部候选**，`complete=false` → `partial`，covered/limit 为探测数/候选数；调用方不再因 cap 64 假报 complete | 完成 |
| DEX 截断 | 既有 `android.dex.structure` / `strings` / `unicodeStrings` / `methodReferences` / `callSites` 保持不变；截断时既有逻辑已降 `partial` 或 UNKNOWN | 完成（复用既有维度） |
| Native Library 截断 | 新增 `android.nativeLibraries`：选中/读取少于唯一库总数或存在 skipped → `partial`，covered/limit 为已扫/总数 | 完成 |
| Split Sampling | 新增 `android.splitSampling`：`splitAudited < splitTotal` → `partial`；调用方传声明总数，提取上限 50 不会隐藏未审计分包 | 完成 |
| 相关限制进入结构化 Coverage | 五个维度均为 `CoverageEntry`，带 status、covered、limit、noteCode、args | 完成 |
| `hasActualGaps` 正确识别覆盖缺口 | `partial` / `notCovered` 进入 `coverage.gaps`；测试断言 artifact/payload/loadGraph/split/native 截断时 `hasActualGaps=true` | 完成 |
| 不将无关 limitations 全部转换为 gaps | 只新增上述真实截断维度；`android.signature`、crypto-theft 的既有方法论 `limitations` 未被改写为 coverage 缺口 | 完成 |

## 5. 实际执行命令与结果

### 5.1 针对性测试

```text
~/development/flutter/bin/flutter test test/analysis_coverage_test.dart
→ 42 passed

~/development/flutter/bin/flutter test test/analysis_report_test.dart
→ 42 passed

~/development/flutter/bin/flutter test test/security_evidence_card_test.dart
→ 2 passed

~/development/flutter/bin/flutter test test/coverage_note_registration_test.dart
→ 6 passed

~/development/flutter/bin/flutter test test/android_security_audit_test.dart
→ 60 passed

(cd packages/analysis_model && flutter test test/analysis_model_test.dart)
→ 41 passed
```

### 5.2 全量回归

```text
~/development/flutter/bin/flutter test
→ 1856 passed / 16 skipped / 0 failed（exit 0）
```

基线为 1850 / 16；本阶段净增 6 个测试，无删测、无新增 skip。

```text
(cd packages/analysis_model && flutter test)        → 142 passed
(cd packages/apk_parser && flutter test)            → 226 passed
(cd packages/ipa_parser && flutter test)            → 250 passed
(cd packages/archive_safety && flutter test)        → 40 passed
(cd packages/app_icon_extractor && flutter test)    → 25 passed
→ 包测试合计 683 passed
```

基线为 682；净增 1 个模型测试。

### 5.3 静态检查、格式与构建

```text
~/development/flutter/bin/flutter analyze --fatal-infos --fatal-warnings
→ No issues found!

~/development/flutter/bin/dart format --output=none --set-exit-if-changed .
→ 447 files, 0 changed（exit 0）

~/development/flutter/bin/flutter build bundle
→ exit 0
```

### 5.4 报告 schema 校验

用现有测试夹具渲染完整报告，取出 `security` 对象，对：

`docs/contracts/crypto-theft-security-v8.schema.json`

以 Python `jsonschema`（Draft 2020-12）校验：

```text
schema_errors 0
artifacts_keys ['entries', 'totalEntries', 'inventoriedEntries', 'entriesComplete', 'skippedCodes']
loadGraph_keys ['nodes', 'edges', 'danglingEdgeIds', 'complete']
```

说明：这是对**序列化形状**的校验；样本为合成测试数据，不代表真实 APK 的字段取值均已覆盖。

### 5.5 未执行项

- 外部真实 APK/XAPK 的端到端验证：属于 Stage D，未执行。
- 三平台安装/运行验收：属于 Stage E，未执行。
- 大包/超大 split 包的性能与内存复测：本阶段未执行，留作后续回归项。
- Windows/macOS/Linux 实机 UI 截图验收：属于 Stage E，未执行。

## 6. 设计说明与边界

- **为什么 schema 版本仍是 8**：`docs/contracts/crypto-theft-security-v8.schema.json` 在 2.10.6 已声明 `security.artifacts` / `security.loadGraph` 及其 `$defs`，只是生产代码一直输出 `null`。本阶段是把“已声明的契约”接上值，没有新增/删除/改名字段，因此不升版本。若验收要求“只要行为变化就升 schema”，需要另行升级 v9 并迁移旧报告；当前未做。
- **XAPK/APKS 的制品清单范围**：`ArtifactInventory` 仍来自 base APK 的 ZIP 条目；分包制品不合并进同一清单，分包的“声明总数 / 实际审计数”由 `android.splitSampling` 表达。因此证据卡展示的是 base 清单，不是整个 XAPK 所有 split 条目的并集。这是本阶段明确保留的范围限制。
- **payload 候选计数**：`PayloadProbeResult.entriesTotal` 现在表示“候选总数”，不只是“实际传入扫描器的数量”；调用方 cap 64、单文件 8 MiB 上限、读取失败都计入 skipped 并使 `complete=false`。
- **不判断恶意性**：新增字段只描述“看过什么、完整不完整”，证据卡与报告措辞不输出“恶意/木马”结论。
- **iOS 侧**：`artifacts`/`loadGraph` 仍为 null；v8 schema 允许 null，iOS 不伪造空对象。

## 7. 遗留问题

1. 真实 XAPK/APKS 样本上的 split 采样覆盖未做端到端验证（Stage D）。
2. 制品清单为 base-only；若产品要求“整包制品清单”，需把 split 条目合并进 inventory，属于后续增强而非本阶段 P1。
3. 未做超大包/超多 split 的峰值内存复测。
4. 无 commit、无 tag、未发布；Stage C–G 未开始。

## 8. 阶段结论

- **Stage B：PASS（待人工确认）**。P1-3 的强类型模型、报告序列化、schema 形状校验、UI 证据卡，以及 P1-4 的五个结构化覆盖维度、payload 真实计数、split 采样上限均有实际命令与测试证据。
- **发布建议：NO-GO**。2.10.7 的 P1-2、P1-5、P1-6、P1-7 尚未实施；真实样本门禁与三平台运行验收尚未执行。
- 请确认是否接受 Stage B；接受后再进入 Stage C（分析页空态/失败态）。本阶段不移动 tag、不发布。
