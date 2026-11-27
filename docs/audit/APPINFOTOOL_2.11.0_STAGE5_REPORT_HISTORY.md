# AppInfoTool 2.11.0 — Stage 5 报告与历史

- 开始 commit：`cb9af61 feat(network): add structured static network clues`
- 分支：`feature/2.11.0`
- 日期：2026-11-27
- 范围：F08 JSON/HTML 报告、F09 分析历史/重新打开
- 约束：只使用真实解析数据；不执行样本、不访问网络；不改解析规则；不发布 tag

## 1. 完成内容

### 1.1 HTML 报告

新增 `lib/utils/html_report.dart`：

- 输入是 `AnalysisReport.renderJson` 的 `Map`，不重新解析安装包。
- 输出单文件 HTML，内联 CSS，无 JavaScript、无外部字体或图片。
- 章节：应用/文件头、发现、覆盖范围、静态网络线索、结构证据、页脚。
- 所有动态值经过 HTML 转义；发现中的证据按 source/location/detail 展示。
- “仅安全检测”范围复用 JSON 的 `securityOnly` 过滤，不伪造额外章节。
- 报告标题、章节、静态声明、空态和页脚使用应用当前语言（6 语言），不再硬编码中文。

`lib/utils/analysis_report.dart` 新增：

```dart
static String renderHtml(
  PackageAnalysisResult result,
  Translations t, {
  required DateTime generatedAt,
  bool securityOnly = false,
})
```

`lib/widgets/export_report_dialog.dart`：

- `ExportFormat` 增加 `html`。
- 导出格式选择增加 HTML；扩展名 `.html`；内容走 `AnalysisReport.renderHtml`。
- Markdown / JSON 行为不变。

### 1.2 分析历史

新增 `lib/pages/history_page.dart`：

- 从 `AnalysisRunRepository` 读取最近 100 条 run。
- 空态：`history.empty_title/body`。
- 列表项：平台图标、应用名、状态、包路径、开始 → 完成时间（本地时区）、重新打开、删除。
- 重新打开：原包存在时请求打开并跳转分析页；原包不存在时给出提示，不伪造快照。
- 删除：二次确认后只删除本地 run 快照，不碰原始安装包。
- 刷新按钮。

导航：

- `AppNavigation` 新增“历史”（位于分析与对比之间）。
- Sidebar、TopBar 页面标题同步。
- `AppShell` 新增 `history` 页面 key。
- `IndexedStack` 每个子页包 `TickerMode(enabled: 仅当前页)`，避免历史页加载 spinner 在其它页面持续动画导致 widget 测试无法 settle。

i18n（6 语言）：

- `nav.history`
- `history.title/subtitle/empty_title/empty_body/open/delete/delete_title/delete_body/missing/refresh`

### 1.3 报告与历史的边界

- HTML/Markdown/JSON 都是报告导出，不写历史。
- 历史保存的是分析完成时的 `AnalysisReport.renderJson` 快照；查看历史不会重新解析。
- 重新打开当前实现为“打开原包并重新分析”，不是从快照恢复完整 UI。快照本身已保存，可供后续 History 详情页使用。
- 历史删除只影响本地快照，不影响原包、最近文件列表或缓存图标。

## 2. 实际验证

### 2.1 自动化

```text
flutter test
→ 1896 passed / 19 skipped / 0 failed

flutter analyze --fatal-infos --fatal-warnings
→ No issues found

dart format --output=none --set-exit-if-changed .
→ 469 files, 0 changed

flutter build bundle
→ exit 0
```

HTML 报告测试：

```text
test/analysis_report_test.dart
→ 43 passed
```

覆盖：

- HTML 以 `<!doctype html>` 开头；
- 含应用名、包名、覆盖缺口、静态声明；
- 不含 `<script>`；
- 标题、章节与声明使用当前语言。

分析历史仓库已有测试（Stage 1）：

- roundtrip、id、CRUD/list、索引重建、损坏文件、路径穿越、prune、running 保护、坏 JSON。

### 2.2 实际运行

- macOS debug app 打开历史页；
- 实际显示两条本地 run：
  - `天⑄美` / `217_0919155004.apk` / SUCCESS；
  - `SUN` / `sun_signed.ipa` / SUCCESS；
- 两个条目均有开始/完成时间、重新打开、删除；
- 无布局异常、无未捕获异常。

### 2.3 未执行 / 已知限制

- 没有保留历史页 widget 测试：早期尝试使用 `pumpAndSettle` 时被加载 spinner 挂住，测试文件已移除；历史页当前只有仓库层测试 + 手工运行证据。这是测试缺口，不是“通过”。
- “重新打开”重新解析原包，不复用快照渲染历史结果；若原包被删除会明确提示。
- HTML 报告没有 PDF、分页、附件归档；只用内联 CSS。
- 历史列表最多 100 条，仓库最多保留 100 个 run（running 不裁剪）。
- 报告 HTML 仍不包含 artifact/load graph 的完整表格，只显示结构计数；完整数据在 JSON 快照中。

## 3. 修改文件

新增：

- `lib/utils/html_report.dart`
- `lib/pages/history_page.dart`

修改：

- `lib/utils/analysis_report.dart`
- `lib/widgets/export_report_dialog.dart`
- `lib/ui/shell/navigation_item.dart`
- `lib/ui/shell/sidebar.dart`
- `lib/ui/shell/app_shell.dart`
- `lib/ui/shell/v4_top_bar.dart`
- `assets/i18n/{en,zh-CN,zh-TW,zh-HK,ja,ko}.json`
- `test/analysis_report_test.dart`

## 4. 结论

- F08：HTML 报告完成，JSON 保持 schema 8，历史快照保存真实报告 JSON。
- F09：历史列表、打开原包、删除快照完成；快照恢复 UI 留作后续。
- 未提交 release/tag。

Stage 5 状态：**功能完成，测试覆盖不完整；GO 到 Stage 6 前需接受该测试缺口。**
