# V3 阶段 2 报告：文件浏览器（F04）与敏感信息（F01）

状态：**完成**（2026-11-28）

## 1. 目标（本阶段范围）

- F04：包内文件树、路径搜索、文本/Hex/图片预览，全部走预算。
- F01 前半：敏感信息扫描（规则、脱敏、指纹、显式查看），明文不落盘。
- 明确不做：文件导出、按需解压整棵树、修改包内容。

## 2. 主要变更

| 模块 | 文件 | 说明 |
| --- | --- | --- |
| 归档树 | `packages/archive_safety/lib/src/file_tree.dart` | 只读中央目录；嵌套归档用 `!` 分隔；条目/层数/字节三重上限 |
| 读包接线 | `lib/utils/package_archive_tree.dart` | 复用 `ApkReader`；嵌套解压共享 `BoundedReadLedger`；预览只读前缀 |
| 浏览器 UI | `lib/widgets/package_browser_panel.dart` | 树、搜索、文本/Hex/图片预览，挂在「文件」Tab |
| 敏感信息模型 | `packages/analysis_model/lib/src/v3/secret_{match,rules,scanner}.dart` | 8 条规则；脱敏值 + 值哈希 + 指纹 |
| 扫描服务 | `lib/utils/secret_scan_service.dart` | 文本条目 + DEX 字符串；`revealPlaintext` 按哈希核对重扫 |
| 面板 | `lib/widgets/secret_scan_panel.dart` | 独立「敏感信息」Tab（Android/iOS），可复制指纹/显式查看 |
| 报告 | `lib/utils/report_extras.dart`、`lib/utils/analysis_report.dart` | schema v12 新增 `secrets` 节（只写脱敏值） |

## 3. 公开接口

```dart
PackageArchiveTree.open(path)            // 建树（共享 budget ledger）
PackageArchiveTree.readEntry(path, maxBytes:)  // 支持 a.zip!b.txt
SecretScanner.scanText(text, location:, limits:)
SecretScanner.valueHashOf(value)          // 与 SecretMatch.valueSha256 一致
SecretScanService.scan(path)              // 文本 + DEX，返回脱敏命中
SecretScanService.revealPlaintext(path, match) // 二次确认后调用
```

## 4. 关键决策

1. **明文不进模型**：`SecretMatch` 只有 `redactedValue` 与 `valueSha256`；「显式查看」按需重扫并用哈希核对，不缓存明文。
2. **预览上限 256 KiB**：整条读取留给导出；避免点开 200 MB assets 把内存打满。
3. **嵌套只展开一层**：更深的归档记 `tree.nestedNotExpanded`，按需加载留给后续阶段，不在建树时递归解压。
4. **敏感信息独立 Tab**：与「安全检测」分开，避免把「包里写了密钥」误读成「规则命中风险」。
5. **报告 schema v12**：`secrets` 为空则整键不出现（缺失 ≠ 空数组），与 `libraries` 一致。

## 5. 兼容性

- 报告 schema 11 → 12：只新增可选 `secrets`，旧解析器可忽略；契约 `docs/contracts/analysis-report-v12.schema.json`。
- 历史索引未改；快照仍是原始 JSON 字符串。
- 无新增运行时依赖。

## 6. 测试

| 层 | 结果 |
| --- | --- |
| `packages/analysis_model` | 192 passed |
| `packages/archive_safety` | 46 passed |
| 根 `flutter test` | **2032 passed / 20 skipped** |
| `flutter analyze` | No issues found |

新增测试：文件树 6 条、敏感信息扫描 9 条、面板 3 条（脱敏/显式查看）、策略守卫 3 条、报告 v12 3 条、真实 APK 浏览 1 条。

## 7. 安全设计评审（2.7）

- 明文只存在于：用户点「查看明文」后的对话框内存；关闭即释放。
- 不写日志：`SecretScanService` 只 `log.warning` 记录失败原因，不打印字节或命中值。
- 不进报告：v12 只写 `redactedValue` 与哈希；测试断言导出 JSON/Markdown 不含样本明文。
- 键集固定：`test/secret_policy_test.dart` 断言 `SecretMatch.toJson` 没有 `value`/`plaintext` 字段。
- 风险残余：系统崩溃转储不在控制范围；「复制明文」会把值放进剪贴板（用户主动行为，已在确认文案中说明）。

## 8. 限制

- DEX 只扫 ASCII 字符串（MUTF-8 中文密钥不覆盖）。
- 规则是启发式：命中需人工判断，未命中不代表没有密钥。
- 预览不解析专有格式（`.arsc`、`.dex` 显示 Hex）。
- 文本条目上限 400 个，超出会截断并标记。

## 9. 未完成（后续阶段）

- 文件导出 / 批量导出（F04 扩展）。
- 敏感信息处置（误报标记、忽略规则）依赖 F06。
- SBOM（F03）与隐私清单（F02）在阶段 3。
- 报告 HTML 视图的 secrets 样式复用 Markdown 段落，未单独设计。

## 10. 下一阶段

阶段 3：F02 隐私与 SDK 清单 + F03 SBOM（CycloneDX），复用本阶段的 Component/指纹/证据模型。

## 11. 命令与提交

```
dart format lib test packages docs
flutter analyze
flutter test
```

提交：`095a1f4`、`451fab7`、`8a51f00`、本阶段收尾提交。

## 12. 结论

阶段 2 达成出口条件：文件树/搜索/预览可用，敏感信息可扫描且明文不落盘，报告可复现。**建议进入阶段 3**。
