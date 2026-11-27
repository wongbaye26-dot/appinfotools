# AppInfoTool 2.11.0 — Step 2：历史页测试与语义收口

- 分支：`feature/2.11.0`
- 起点 commit：`5f360d6 feat(report): bump report schema to v9 with evidence links`
- 日期：2026-11-28
- 范围：F09 历史页自动化测试、历史“重新打开”产品语义
- 约束：真实 run；不改解析规则；不伪造快照恢复

## 1. 历史页 widget 测试

新增 `test/history_page_test.dart`：

- 通过 `HistoryPage(loader: ...)` 注入确定性的 run 列表，避免测试环境真实 I/O / 无限 spinner；
- 断言：
  - 应用名 `SUN`
  - 状态 `SUCCESS`
  - 原始包路径
  - 删除入口
- 使用真实 `AnalysisRunSummary.fromRun` 构造，不复制字段。

实现细节：

- `HistoryPage` 增加可选 `loader`（测试用）与 `repository`（备用注入）；
- 生产路径仍从 `analysisRunRepositoryProvider` 读取 ApplicationSupportDirectory；
- 页面已有 `TickerMode` 关闭离屏动画，避免 AppShell 测试卡在 `pumpAndSettle`。

## 2. 产品语义：`重新打开` → `重新分析`

历史记录现在明确为：

- **快照是审计证据**：保存当次 `AnalysisReport.renderJson`，不随后续版本改写；
- **“重新分析”**：重新解析原始安装包，得到当前版本的新结果；
- **不会**把旧快照直接注入当前 UI——旧快照与当前规则/模型可能不一致，直接展示会伪造“当前结果”；
- 原始包不存在时：明确提示“原始安装包已不存在”，保留记录供删除/审计，不做假打开。

因此 UI 文案从“重新打开”统一改为“重新分析 / Re-analyze / 再解析 / 다시 분석”，副标题同步说明“重新分析原包”。

## 3. 已知限制（明确接受）

- 旧快照不能在 UI 中恢复为完整分析页；
- 历史记录暂不支持“查看快照 JSON/HTML”入口；
- 原始包被移动/删除后，只能看到历史元数据并删除记录；
- 这些限制不阻塞 2.11.0 的历史列表/删除/重分析主流程。

## 4. 门禁

```text
flutter test
→ 1900 passed / 20 skipped / 0 failed

flutter analyze --fatal-infos --fatal-warnings
→ No issues found

dart format --output=none --set-exit-if-changed .
→ 474 files, 0 changed

flutter build bundle
→ exit 0
```

## 5. 结论

- Step 2（历史页测试 + 语义定义）完成。
- 未提交 tag/release。
- 下一项：Windows/Linux 实机验收。
