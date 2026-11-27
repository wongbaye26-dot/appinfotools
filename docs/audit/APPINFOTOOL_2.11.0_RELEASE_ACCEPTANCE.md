# AppInfoTool 2.11.0 — Stage 6 样本回归与发布验收

- 分支：`feature/2.11.0`
- 起点 commit：`f8a65a8 feat(report): add HTML export and analysis history`
- 日期：2026-11-27
- 范围：固定样本清单回归、HTML 注入、发布验收记录
- 约束：真实样本、真实解析；不执行样本代码；不访问网络；不改解析规则；不发布 tag

## 1. 本轮新增

### 1.1 固定样本清单

新增：

- `test/support/sample_manifest.dart`
  - `APPINFOTOOL_SAMPLE_MANIFEST` 指向 JSON 清单；
  - 每项：`file` / `kind` / `sha256` / 可选 `expectedFindingRules` / `expectedEvidenceSources` / `expectedCoverageIds`；
  - SHA-256 在解析前强制校验；`file` 只允许裸文件名，不拼路径。
- `test/sample_regression_test.dart`
  - 清单内每个样本必须存在且 SHA 匹配；
  - 每个样本走真实解析，生成报告 JSON；
  - 若清单声明了 rule/evidence/coverage 期望，则逐项断言。
- `test/samples/manifest.example.json`
- `test/samples/README.md`
- 未设置 `APPINFOTOOL_SAMPLE_MANIFEST` 时测试显式跳过，不伪装成通过。

### 1.2 HTML 注入回归

新增 `test/html_report_escape_test.dart`：

- 应用名、包名、规则 ID、finding 文本、证据 source/location 均注入 `<script>` / `<img onerror>`；
- 断言输出不含原始标签/事件，且转义后的文本存在；
- 覆盖 HTML `<` `>` `/` 转义路径。

### 1.3 既有边界测试复用

以下边界已有测试，本阶段不重复造：

- ZIP 炸弹/解压上限/超大条目：`packages/archive_safety/test/archive_safety_test.dart`、`bounded_read_test.dart`、`bounded_read_memory_test.dart`。
- 路径穿越/绝对路径：`packages/archive_safety` 的路径校验测试。
- 取消/超时：`test/aapt2_task_test.dart`（取消、超时、重复取消）。
- 重复名/特殊归档：`test/xapk_real_fixture_test.dart`、`test/apks_toc_test.dart`。

## 2. 真实样本执行

本地样本目录 `/tmp/appinfotool-samples`（4 IPA + 2 APK），由脚本生成临时清单 `/tmp/appinfotool-manifest.json`：

```bash
APPINFOTOOL_SAMPLE_MANIFEST=/tmp/appinfotool-manifest.json \
APPINFOTOOL_SAMPLES=/tmp/appinfotool-samples \
flutter test test/sample_regression_test.dart
```

结果：

```text
00:01 +1: 清单中的文件存在且 SHA-256 匹配
00:09 +2: 每个样本都能解析并生成带能力证据的报告
All tests passed!
```

样本：

- 4 个 IPA：`95-v1.8.7.ipa`、`sun_nosigned.ipa`、`sun_signed.ipa`、`wnsr_signed.ipa`
- 2 个 APK：`217_0919155004.apk`、`狐狸视频8-v3.20.apk`

本次清单期望数组为空，验证的是「SHA 固定 + 可解析 + 可生成报告」；具体 finding/evidence/coverage 期望需要在长期样本清单里逐项补。

## 3. 自动化门禁

```text
flutter test
→ 1897 passed / 20 skipped / 0 failed

flutter analyze --fatal-infos --fatal-warnings
→ No issues found

dart format --output=none --set-exit-if-changed .
→ 472 files, 0 changed

flutter build bundle
→ exit 0
```

跳过项说明：

- 未配置 `APPINFOTOOL_SAMPLES` 的真实样本组；
- 未配置 `APPINFOTOOL_SAMPLE_MANIFEST` 的固定样本回归（1 项）；
- macOS 专属 codesign 用例。

## 4. 跨平台实际验收

macOS：

- 实际启动 debug app；
- 打开真实 IPA、APK；
- 分析页/历史页/报告导出路径已在 Stage 1–5 实际运行验证；
- Stage 5 历史页实际显示两条 SUCCESS run。

Windows：

- **未执行**。本机无 Windows 环境；
- 安装、启动、缩略图、文件关联、卸载均未在 2.11.0 重新验证。

Linux：

- **未执行**。本机无 Linux 环境；
- AppImage 启动/分析/导出未执行。

CI：

- **未执行**。Stage 6 没有触发 GitHub Actions；
- 三平台 build/runtime smoke 结果不能引用历史 run 冒充 2.11.0。

## 5. 发布结论

**NO-GO。**

阻断项：

1. Windows/Linux 运行验收未执行；CI 未运行。
2. 真实样本清单未配置到 CI；`APPINFOTOOL_REQUIRE_SAMPLES=1` 未在发布环境跑绿。
3. 历史页缺 widget 自动化测试（Stage 5 已知缺口）。
4. report schema 仍为 v8，AnalysisRun/evidence[] 迁移未完成（Stage 5 范围收缩）。
5. 未做 2.11.0 全量手工验收清单（安装/升级/卸载/多语言/暗色/窄窗口）。

已完成、可确认：

- 固定样本清单机制与 HTML 注入测试；
- 本地 6 个真实样本 SHA/解析/报告回归通过；
- 全量 Dart 测试、analyze、format、build bundle 通过；
- macOS 实机核心路径可用。

## 6. 未提交 / 后续

- 本轮代码已提交，见 Stage 6 commit。
- 建议下一步：
  1. 在 review 中确认 Stage 6 样本清单格式；
  2. 在 Windows/Linux 实机执行安装/启动/分析/导出；
  3. 配置 CI 样本清单与 `APPINFOTOOL_REQUIRE_SAMPLES=1`；
  4. 补历史页 widget 测试；
  5. 决定 report schema v9 迁移是否纳入 2.11.0。
- 不移动 tag、不发布 release。

## 7. 2026-11-28 追加：report schema v9

- 已完成 `reportSchemaVersion = 9`：
  - `analysisRun` 头（id/toolVersion/appName/platform/packageSha256/startedAt/completedAt/status）；
  - finding `evidenceIds`；
  - 聚合 `security.evidence[]`，条目带稳定 `ev_<12 hex>` ID；
  - 契约 `docs/contracts/analysis-report-v9.schema.json`。
- 历史 v8 快照保留可读；新报告写 v9。
- 因此原第 4 项阻断（“report schema 仍为 v8”）已解除。
- 发布结论仍为 **NO-GO**：Windows/Linux 实机、CI 样本门禁、历史页 widget 测试、全量手工验收仍未完成。
