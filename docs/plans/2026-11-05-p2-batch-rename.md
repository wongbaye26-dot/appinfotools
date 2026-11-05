# P2-3：批量重命名

> 日期：2026-11-05｜状态：已实现

## 改动

### 纯逻辑

新增 `lib/utils/batch_rename.dart`：

- `buildBatchRenamePlans`：应用名 / 应用名-版本，保留原扩展名；
- 文件名安全化（`\ / : * ? " < > |`、控制字符、尾部点/空格）；
- 同批冲突追加 ` (2)`、` (3)`；
- `batchRenameFiles`：就地 rename，失败回退 copy+delete，逐个记录结果。

### UI

新增 `lib/widgets/batch_rename_dialog.dart`：

- FilePicker 多选支持的包；
- 逐个 `getApkInfo` 取应用名/版本；解析失败退回文件名；
- 预览“原文件名 → 新文件名”；
- 可切换是否包含版本；
- 执行后显示成功数量 / 失败数量。

概览页页头新增“批量重命名”入口（`Icons.playlist_add_check`）。

## 测试

- `test/batch_rename_test.dart`：安全化、版本/无版本、冲突序号、真实落盘。

## 已知限制

- macOS 沙箱下就地 rename / copy 可能 EPERM；批量模式**不逐个弹保存面板**，
  因此这类文件会记为失败。单文件重命名仍保留三级回退（含保存面板）。
- 只改文件名，不改内容；不重新打开/刷新最近文件记录。

## 门禁

| 项 | 结果 |
|---|---|
| 根项目 `flutter test` | 1,780 通过 |
| 根项目 analyze | 0 问题 |
| `dart format` | 414 files，0 changed |
