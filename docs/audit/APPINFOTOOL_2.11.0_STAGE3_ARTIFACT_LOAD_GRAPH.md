# AppInfoTool 2.11.0 — Stage 3 Artifact Inventory / Load Graph 证据化

## 结论

Stage 3 完成：制品清单和 Android 加载链从“只有汇总计数”升级为可展开核对的真实证据表。数据仍来自现有扫描器，没有新增猜测、没有改规则。

## 制品清单

文件：`lib/widgets/security_evidence_card.dart`

- 新增“查看制品（N）”入口。
- 弹层表格显示：
  - 路径
  - 类型（dex / elf / manifest / resourceTable / asset* / signatureBlock…）
  - 声明大小
  - SHA-256（未计算显示 `—`）
- 清单被截断时保留警告与说明。
- 当前上限仍是 2000 条；条目来自 base APK 的 ZIP 目录。
- 明确限制：`sha256 == null` 表示**没有计算**，不是“哈希为空”；`contentScanned` 仍为 false，`skipCode = not.selected`。

## Android 加载链

- 新增“查看加载链（N）”入口。
- 弹层分两段：
  - 节点：id、kind、是否在包内（缺失节点标红）。
  - 边：`from → to`、加载类型、调用点位置。
- 悬空边数量仍在汇总卡中单独标出。
- 数据来自现有 `AndroidLoadGraphScanner`，仍保留其“同现而非参数级数据流”的限制说明。

## 未做 / 已知限制

- 没有为制品计算内容哈希；表格如实显示 `—`。
- 制品清单只覆盖 base APK，不含 split 制品。
- 加载链仍不解析原生 `dlopen/dlsym`、`Runtime.exec`，边是 loader 调用与路径字面量同现。
- 没有制品搜索/排序/过滤；表格按扫描器排序显示。

## 验证

```bash
flutter test                                      # 1892 passed / 19 skipped
flutter analyze --fatal-infos --fatal-warnings    # No issues found
dart format --output=none --set-exit-if-changed . # 465 files, 0 changed
flutter build bundle                              # exit 0
flutter test test/security_evidence_card_test.dart # 4 passed
```
