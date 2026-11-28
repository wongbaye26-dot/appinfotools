# AppInfoTool 2.11.1 第五阶段：核心分析能力专项核验

日期：2026-11-28
范围：Evidence / Finding / Coverage / Artifact / Load Graph / Network Clues /
历史重开 / 报告导出。以**真实 APK** 端到端核验，不只看单测。

## 方法

- 新增 `tool/verify/verify_core_capabilities_test.dart`：真实包 → `getApkInfo` →
  `AnalysisBuilder.buildAndroid` → `ReportExtras.collect` →
  `AnalysisReport.renderJson` / `render`，然后逐项断言关键结构存在。
- 样本：`~/Downloads/217_0919155004.apk`（9.2 MB）与
  `~/Downloads/狐⤷狸⊻视⭏频⧙8-v3.20.apk`（9.7 MB），两份都是真实第三方 APK。
- 命令：

  ```bash
  VERIFY_APK=… VERIFY_OUT=/tmp/verify_report.json \
    flutter test tool/verify/verify_core_capabilities_test.dart
  ```

- 统计口径：只核对「有没有 / 键在不在」，不钉死数字（数字随样本变化）。

## 实测结果

以 `狐⤷狸⊻视⭏频⧙8-v3.20.apk` 为例（另一份同量级，结论一致）：

| 能力 | 实测 | 落盘位置（JSON） |
| --- | --- | --- |
| Finding | 13 条，规则涵盖权限、原生符号、证书过期、不可授予权限等 | `security.findings[]` |
| Evidence | 19 条，每条结论都有来源（文件/位置/细节） | `security.evidence[]` |
| Coverage | 18 个维度，`hasGaps: true`（2 个缺口），另带 `limitations` | `coverage.entries[]` |
| Artifact Inventory | 19 条，`entriesComplete: true`，无截断 | `security.artifacts.entries[]` |
| Load Graph | 1 条边，含 `nodes/edges/danglingEdgeIds/complete` | `security.loadGraph` |
| Network Clues | 1 条线索、0 个域名，见下方「数据质量」 | `network{domains,ips,clues}` |
| 权限分级 | 10 条权限，含 risk / protectionLevel / flags | `application.permissionDetails[]` |
| 库识别 | 识别 4 个 SDK（4 个组件命中），`dataVersion` 随规则包 | `libraries{...}` |
| 签名证书 | 本次 harness 未跑签名分析 → `certificates` 不出现（null 语义正确） | `signatureSummary` |

Markdown 报告同时含 `## Permissions` 分级表；有库识别结果时含 `## Libraries` 小节
（该样本有 4 个 SDK，因此两节都在）。

报告顶层共 20 个键：`reportSchemaVersion / reportId / generatedAt / analysisRun /
inputArtifact / fieldStatus / platformFacts / application / signatureSummary /
securitySummary / security / network / splitConsistency / findings / coverage /
diagnostics / engineVersions / rulesVersions / limitations / libraries`。

### 数据质量发现（不阻塞，但要记录）

- `network.clues` 出现 `value: ":C:"`、`context: ":C:"` 这类噪声：线索扫描器在
  混淆/加固 DEX 上会把短字符串误判为端点。当前只作为「线索」展示、不升级为结论，
  语义没错，但**信噪比差**，后续应加最小长度/字符集约束。
- 两份真实包都识别出 4 个 SDK，但 `native` 与 `dex` 分组为空、全部命中来自组件名 ——
  说明「组件 → SDK」这条链路有效，「DEX 包名 → SDK」在这两个加固包上无从命中。
  这与「不造假」一致：没命中就不写。

## 历史重开

- 现状（代码核验）：`AnalysisRun.snapshot` 在分析完成时由
  `lib/utils/analysis_run_recorder.dart` 写入（`renderJson` 快照），但**全仓库没有任何
  读取方** —— `grep "\.snapshot"` 只命中写入侧、序列化与 `report.snapshot.failed` 诊断。
- 后果：历史页「打开」= 用当前代码**重新解析原文件**，不是回放上次结论。
  - 好处：永远反映最新规则与最新代码；
  - 代价：文件被替换/删除、规则包升级后，历史结论无法原样复现；审计语义上
    「上次分析看到了什么」只能靠导出的报告文件，不能靠历史条目。
- 判定：**功能可用，但「历史重开」名不副实**。已在最终验收文档列为遗留风险，
  修复方向是让历史页优先渲染 `snapshot`（并提供「用当前规则重新分析」按钮）。

## 报告导出

- 共享导出入口 `lib/widgets/export_report_dialog.dart` 在渲染前调用
  `ReportExtras.collect`（权限分级、库识别、证书），失败只记日志、不阻断导出。
- JSON 契约 `docs/contracts/analysis-report-v11.schema.json`；Markdown/HTML 同一份数据。
- 端到端：本阶段 harness 直接调 `renderJson` / `render` 并断言键存在，均为通过。

## 本阶段判定

- 八项能力**全部有真实产物**，不是 UI 层拼装；报告层能复现同样的结论。
- 两项遗留：Network Clues 噪声、历史快照只写不读。均记录，不阻塞功能判定。
- 判定：**PASS（带两项已知限制）**。
