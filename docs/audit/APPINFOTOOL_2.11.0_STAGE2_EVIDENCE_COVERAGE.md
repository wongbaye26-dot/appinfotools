# AppInfoTool 2.11.0 — Stage 2 Evidence / Finding links / Coverage 执行状态

## 结论

Stage 2 完成：证据有了稳定 ID，Finding 可以直接给出 `evidenceIds`，安全结果能汇总去重后的证据列表，UI 增加证据中心；Coverage 增加 `notScanned` / `failed` 两种真实执行状态，并按缺口处理。

## 稳定证据 ID

文件：`packages/analysis_model/lib/src/security_finding.dart`

- `SecurityEvidence.id` 可选；未显式给定时用 FNV-1a 64 位从内容派生。
- 派生输入：source、location、locationCode、detailCode/detail、排序后的 detailArgs。
- 形式：`ev_<12 hex>`。
- 同一证据跨报告稳定；内容变化得到不同 ID。
- `SecurityFinding.evidenceIds` 与嵌入证据顺序一致。
- `SecurityAnalysisResult.evidence` 汇总所有 Finding 的证据，按 `evidenceId` 去重并保持首次出现顺序。

## 证据中心 UI

文件：`lib/widgets/security_evidence_center.dart`

- 安全页新增证据卡：标题、数量、前 4 条证据。
- 每行显示稳定 ID、本地化位置/详情、来源类型。
- 超过 4 条可打开 680×480 弹层查看全部。
- `SecurityFindingCard` 的每条证据也显示 ID，便于 Finding→证据追溯。
- 未找到证据时不渲染空卡，避免暗示“查过了”。

## Coverage 执行状态

文件：`packages/analysis_model/lib/src/analysis_coverage.dart`

- `CoverageStatus` 扩展：`notScanned`、`failed`。
- 两者都算缺口（gap）；`failed` 比 `notScanned` 更差，`notScanned` 比 `notCovered` 更差。
- 合并覆盖时按更差状态保留。
- Android 的 artifact inventory / payload probe / load graph 在结果为 null 时标记为 `notScanned`，不再笼统写 `notCovered`。
- 报告与 UI 的状态文案已补六语言。

## 未做 / 延后

- 报告 JSON 暂未写入 `evidence.id` / findings.`evidenceIds`：v8 安全子 schema 对 evidence 是 `additionalProperties: false`，需要 Stage 5 一并升级报告契约。
- 证据中心目前挂在“安全”tab，没有独立一级页面/搜索/按类别筛选。
- `failed` 状态已有模型与显示，但现有扫描器没有统一的失败结果对象，只有 null 走 `notScanned`；后续 Stage 3/4 接入扫描执行结果时再产生真实 `failed`。
- 没有改动解析规则、没有新增 mock 数据。

## 验证

```bash
flutter test                                      # 1890 passed / 19 skipped
flutter analyze --fatal-infos --fatal-warnings    # No issues found
dart format --output=none --set-exit-if-changed . # 465 files, 0 changed
flutter build bundle                              # exit 0
flutter test packages/analysis_model/test/analysis_model_test.dart # 44 passed
flutter test test/security_evidence_center_test.dart               # 2 passed
```
