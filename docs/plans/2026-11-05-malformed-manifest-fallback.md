# 损坏 AndroidManifest.xml 的部分解析回退

> **触发样本**：`/Users/wangbaye/Downloads/224_1105154007.apk`
> **日期**：2026-11-05

## 现象

`ApkReader.parse()` 返回 `null`，应用显示解析失败。

## 根因

根 `AndroidManifest.xml` 不是合法 AXML：

- XML chunk 头正常（`03 00 08 00`），
- 但 offset 8 的 chunk type 是 `0x7ff4`，不是 string pool 的 `0x0001`；
- ZIP 里该条目的 CRC 也坏了（`a266f751` vs `a266f750`）；
- 包内还有 185 个路径里包含 `AndroidManifest.xml` 的诱饵条目，但没有一个能解析出 manifest。

因此不是“找不到 manifest”，而是“文件在、但内容被破坏/混淆”。

## 修复

`ApkReader.parse()` 在 manifest 缺失/被拒绝/不可解析时：

1. 不再直接返回 `null`；
2. 尝试解析 `resources.arsc`，从包 chunk 取包名（新增 `ArscParser.packageName`）；
3. 构造部分 `ApkMeta`：`packageName` 有值、`manifestParseFailure` 标明原因；
4. 继续 DEX/签名/安全审计。

`parse_task` / XAPK 审计把 `manifestParsed: false` 与
`manifestFailureReason` 传进 `AndroidSecurityAudit`，报告会明确说
“权限/组件未覆盖”，而不是“没有声明”。

## 样本结果

```
packageId = com.kAUttBfYwiUjVBQk.nZcnELJpVBSQRJUd
manifestUnparsed = true
manifestParseFailure = ... Invalid String table identifier 0x7ff4
security findings = 2
```

版本、组件、权限仍不可得 —— 这些字段保持“没读到”，不猜。

## 测试

- 新增 `test/apk_manifest_fallback_test.dart`：把正常 APK 的 manifest 替换成
  损坏 AXML，断言仍能拿到包名且 `manifestUnparsed=true`。
- 根项目 1,770 通过；`apk_parser` 216 通过；analyze/format 全绿。
