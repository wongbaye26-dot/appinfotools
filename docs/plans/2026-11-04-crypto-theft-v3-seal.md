# APK v3-only 内容摘要校验

> **状态**：已实现并通过包级/根项目回归（2026-11-04）
> **问题**：Android 密封优先 v2；没有 v2 时直接回退 v1，v3-only 包没有内容摘要校验
> **完成**：`ApkSigningSchemes.v3Value` + `ApkSealCheck.checkV3`；回退顺序 v2 → v3 → v1

## 实现

- `apk_signing_block.dart` 暴露 v3/v3.1 pair 的原始值；
- `ApkSealCheck.checkV3` 与 v2 共用同一套分段/分块/EOCD 改写逻辑；
- `parse_task` 与 `_auditExtractedBaseApk` 的 `_checkSeal` 回退顺序：v2 → v3 → v1；
- JSON seal scheme 增加 `apk.v3.content`（schema 已更新）；
- 合成测试：v3-only signed data 的摘要一致 → `verified`。

## 边界

- 仍不验签；只证明“内容与 v3 signed data 记录一致/不一致”；
- 有 v2 时优先 v2（v2 已覆盖内容摘要）；
- v3.1 与 v3 结构相同，优先取 v3，其次 v3.1。

## 验证

| 项 | 结果 |
|---|---|
| `apk_parser` | **206 通过**（+1 v3 测试） |
| 根项目 `flutter test` | **1,755 通过 / 15 跳过 / 0 失败** |
| 根项目 `flutter analyze` | No issues found |
| `dart format` | 380 files，0 changed |
