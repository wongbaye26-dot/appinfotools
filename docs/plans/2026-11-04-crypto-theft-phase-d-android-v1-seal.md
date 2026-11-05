# Phase D（Android v1 切片）— MANIFEST 摘要校验

> **状态**：Android v1（JAR）MANIFEST 摘要校验已实现并通过包级/根项目回归（2026-11-04）
> **范围**：`apk_parser` 的 `ApkSealCheck` + `AndroidSecurityAudit`/`parse_task` 接线 + 应用层摘要注入
> **未做**：签名验证（`signatureVerified` 恒 false）、官方基线（Phase E）；v2 内容摘要已完成，见 `2026-11-04-crypto-theft-phase-d-android-v2-seal.md`
> **纪律**：`apk_parser` 不新增 `crypto` 依赖；摘要函数由应用层注入

---

## 0. 结论

Android 的 `security.seal` 现在有真实内容：解析 `META-INF/MANIFEST.MF` 的逐条目 `SHA-256-Digest` / `SHA1-Digest`，重算并比对，给出 `verified / mismatch / entryMissing / notChecked`。

| 验证项 | 结果 |
|---|---|
| `analysis_model` | 123 通过 |
| `apk_parser` | **201 通过**（+5 v1 密封测试） |
| `ipa_parser` | 226 通过 |
| `archive_safety` / `app_icon_extractor` | 40 / 25 通过 |
| 根项目 `flutter analyze` | **No issues found** |
| 根项目 `flutter test` | **1,747 通过 / 15 跳过 / 0 失败** |
| `dart format` | **377 files，0 changed** |
| 新增依赖 | 0 |

---

## 1. 实现

| 文件 | 内容 |
|---|---|
| `packages/apk_parser/lib/src/security/apk_seal_check.dart`（新） | 解析 MANIFEST.MF（支持 RFC 822 续行）；按 `Name:` + `SHA-256-Digest` / `SHA1-Digest` 逐条比对；`scheme='apk.v1.manifest'` |
| `packages/apk_parser/lib/src/apk_reader.dart` | 暴露 `archive` getter（worker 内做密封校验用） |
| `packages/apk_parser/lib/src/security/android_security_audit.dart` | `audit(..., seal:)` 写入结果 |
| `lib/apkparser/parse_task.dart` | worker 内用 `contentDigest` 计算 v1 密封；传审计 |
| `packages/apk_parser/test/apk_seal_check_test.dart`（新） | 一致 / 不一致 / 条目缺失 / 无 MANIFEST / 摘要函数不可用 |

### 边界

- **只验证 v1 摘要，不验证签名**：`signatureVerified` 恒 `false`。
- **v1 不保护 ZIP 结构**：塞入额外条目不会让 v1 摘要失效；这部分需要 v2 内容摘要 + 官方基线，当前未做。
- 最多 64 条；超出记 `seal.entry_limit`，状态置 `notChecked`，不冒充 `verified`。
- 只校验 MANIFEST 里列出的条目；不把“清单外新增文件”直接判 mismatch（避免把正常打包差异误报成篡改）。
- 没有 MANIFEST → `unsealed`；摘要函数不可用 → `notChecked`。

## 2. 验证

```bash
cd /Users/wangbaye/Projects/AppInfoTool
(cd packages/apk_parser && dart test && dart analyze --fatal-infos --fatal-warnings)
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

实测：201 / 123 / 226 / 40 / 25 全过；根项目 1,747 通过 / 15 跳过、analyze 零问题。

## 3. 剩余 / 下一步

1. **APK v2 内容摘要（C11 剩余部分）**：解析 APK Signing Block 的 signed data，按 AOSP 1 MiB 分块规则重算；这是 Android “后加代码”最关键的离线证据。
2. 签名验证仍交给 `apksigner`；本版本不自己实现密码学验签。
3. C-4 finding 拆分、Phase E 官方基线仍未做。

> 注意：v1 校验通过**不代表**包未被重打包；当前 Android 的强证据仍依赖 v2 + 官方基线。
