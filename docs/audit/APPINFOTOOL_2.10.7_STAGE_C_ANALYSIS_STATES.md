# AppInfoTool 2.10.7 — Stage C 验收报告（分析页状态）

## 1. 范围与结论

- 阶段：C（P1-5 分析页空态与失败态）。
- 起点 commit：`5c4db5a`（v2.10.6，工作区带 Stage A/B 未提交改动）。
- 本阶段结论：**P1-5 已完成**；页面级 Empty / Loading / Success / Partial / Failure 五态已实现，失败态不再渲染无意义详情，空态/失败态提供动作入口，失败与部分解析提供重试。
- 未提交、未移动 tag、未发布。

## 2. P1-5 对照

| 要求 | 实现 |
| --- | --- |
| Empty | 未选择文件时显示 `AnalysisStatePanel`，标题/说明/「打开安装包」按钮；不构建详情卡片。 |
| Loading | 已选文件、正在解析且尚无结果时显示进度、阶段文案和可用的取消按钮；不构建详情卡片。 |
| Success | 已有完整结果时进入原 `DetailTabView`。 |
| Partial | 已有结果但 `ApkInfo.parseFailureReason != null` 或 iOS 诊断含 error 时，显示页面级部分解析提示并保留详情；提示带重试。 |
| Failure | 无可用结果且打开/解析失败时显示失败面板，不再渲染 `-` 占位详情；显示失败原因和重试按钮。 |
| 失败原因可读 | 容器打开失败使用既有 `DetailRenderer.openFailure`；其余异常不再把 `toString()` 直接上屏，使用本地化通用失败说明，原始异常写日志。 |
| 重试 | 失败面板与部分提示均可对当前路径重新调用 `openApk`；文件不存在时重试会重新检查路径。 |
| 结果不被错误覆盖 | 已有结果时，迟到的失败标记不会把结果页替换成失败页（`resolveAnalysisPageStatus` 优先返回 success/partial）。 |
| 切换/关闭清理 | 打开不存在路径和关闭文件都会取消在跑任务、递增代际号、清空 parsing/stage，避免旧任务把结果写回新路径。 |

## 3. 修改文件

新增：

- `lib/utils/analysis_page_status.dart`：纯函数 `resolveAnalysisPageStatus` 与 `AnalysisPageStatus`。
- `lib/widgets/analysis_state_panel.dart`：`AnalysisStatePanel`（空/加载/失败）与 `AnalysisPartialBanner`（部分解析）。
- `test/analysis_page_state_test.dart`：5 个纯函数测试 + 4 个页面 widget 测试。

修改：

- `lib/pages/info_page.dart`：新增 `_failureMessage`、`_setFailure`、页面状态判定、`_buildAnalysisContent`；在 Android/iOS 打开、解析失败、取消、成功路径维护失败状态；`openApk`/`closeApk` 清理任务与解析状态；失败态不再构建详情卡片。
- `assets/i18n/{en,zh-CN,zh-TW,zh-HK,ja,ko}.json`：新增 `analysis_state` 分组（12 个键），六种语言均为实际翻译。
- 生成文件 `lib/gen/strings*.g.dart` 由 build_runner 刷新；生成文件不纳入提交。

## 4. 测试与命令

| 命令 | 结果 |
| --- | --- |
| `flutter test test/analysis_page_state_test.dart` | 9 pass |
| `flutter test` | **1,865 pass / 16 skip / 0 fail** |
| `flutter test`（packages：analysis_model / apk_parser / ipa_parser / archive_safety / app_icon_extractor） | **142 / 226 / 250 / 40 / 25 = 683 pass** |
| `flutter analyze --fatal-infos --fatal-warnings` | No issues found |
| `dart format --output=none --set-exit-if-changed .` | 450 files, 0 changed |
| `flutter build bundle` | exit 0 |

说明：Stage C 只改 UI/状态与文案，包测试数量与 Stage B 相同（683）；root 从 1,856 增至 1,865，增量来自 9 个新测试。

## 5. 覆盖面与未执行项

- 已验证：无文件空态、解析中加载态、文件不存在失败态、部分解析（`parseFailureReason`）保留详情、状态优先级纯函数。
- **未完成**：用真实损坏 APK 触发页面级解析失败的 widget 测试。尝试构造临时坏包并通过 `openApk` 走真实解析，测试在 fake-async 下等待解析任务超过 60 秒，已移除该用例（未用 skip 掩盖）。页面失败分支本身由文件不存在路径和代码审查覆盖；解析器层的打开失败已有既有测试。
- 未运行外部真实样本（`APPINFOTOOL_SAMPLES` 未配置，Stage D 范围）。
- 未运行三平台安装/运行验收（Stage E 范围）。
- 未提交、未打 tag、未发布；等待人工验收后再进入 Stage D。

## 6. 验收判定

- P1-5：**通过**（页面级五态、失败不渲染详情、重试入口、本地化、UI 测试）。
- 遗留风险：真实损坏包页面级失败路径没有端到端 widget 测试；已如实记录，不以“全部验证”表述。
- 下一阶段：D（真实样本 E2E），需人工确认本报告后开始。
