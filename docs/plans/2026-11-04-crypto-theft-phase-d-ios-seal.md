# Phase D（iOS 切片）— CodeResources 摘要校验

> **状态**：iOS CodeResources v1/v2 摘要校验已实现并通过包级/根项目回归（2026-11-04）
> **范围**：`analysis_model` 密封模型 + `ipa_parser` 逐文件摘要比对 + 应用层摘要注入 + JSON/Markdown/UI
> **未做**：签名验证（本版本 `signatureVerified` 恒 false）、官方基线（Phase E）；Android v1/v2 密封均已完成，见 `2026-11-04-crypto-theft-phase-d-android-v1-seal.md` / `...-android-v2-seal.md`
> **纪律**：parser 包不新增 `crypto` 依赖；摘要函数由应用层注入；未执行样本、未联网

---

## 0. 结论

现在 IPA 的 `security.seal` 有真实内容了：解析 `_CodeSignature/CodeResources` 的 `files` / `files2`，对选中文件重算 SHA-1/SHA-256，逐条给出 `verified / mismatch / entryMissing / notChecked`。

| 验证项 | 结果 |
|---|---|
| `analysis_model` | **123 通过** |
| `apk_parser` | **196 通过** |
| `ipa_parser` | **226 通过**（+5 密封测试） |
| `archive_safety` / `app_icon_extractor` | 40 / 25 通过 |
| 根项目 `flutter analyze` | **No issues found** |
| 根项目 `flutter test` | **1,747 通过 / 15 跳过 / 0 失败** |
| `dart format` | **375 files，0 changed** |
| 新增依赖 | **0**（应用层复用已有 `package:crypto`） |

---

## 1. 实现

| 文件 | 内容 |
|---|---|
| `packages/analysis_model/lib/src/package_seal.dart`（新） | `ContentDigestFn`、`SealState`、`SealEntryCheck`、`SealCheck` |
| `packages/analysis_model/lib/src/security_finding.dart` | `SecurityAnalysisResult.seal`（可空；`withLimitation` 保留） |
| `packages/ipa_parser/lib/src/security/ios_code_resources_check.dart`（新） | 解析 CodeResources；v2 优先 `hash2`（SHA-256），回退 `hash`（SHA-1）；v1 支持 base64 SHA-1 / `hash` data；逐文件比对 |
| `packages/ipa_parser/lib/src/security/ios_privacy_audit.dart` | `audit(..., seal:)` 写入结果 |
| `lib/ipaparser/ipa_analysis.dart` | `analyze(..., digest:)` 在安全审计前算 seal；未注入摘要时 `seal == null` |
| `lib/ipaparser/ipa_parse_task.dart` | worker 内注入 `contentDigest`（在 worker 构造，跨 isolate 只传结果） |
| `lib/utils/content_digest.dart`（新） | 应用层实现：`sha256/sha1/md5` 小写 hex；未知算法返回 null、不抛异常 |
| `lib/utils/analysis_report.dart` | JSON `security.seal` + Markdown `### 密封校验` |
| `lib/widgets/crypto_theft_card.dart` | 卡片增加密封状态行（有值时） |
| `assets/i18n/*.json` | `theft.seal_*` 文案（4 个完整语言；ja/ko 回退英文） |

### 判据边界（写进实现，不靠 UI 文案兜底）

- **只验证摘要一致性，不验证签名**：`SealCheck.signatureVerified` 恒 `false`；报告不得写“签名有效”。
- **重签名会重算 CodeResources**：校验通过 ≠ 未被注入；它抓的是“改了文件但没重签”。
- 没有 CodeResources → `unsealed`；没有摘要函数 → `notChecked` + `seal.digest_unavailable`；绝不把“没算”写成 `verified`。
- 最多校验 64 个文件；超出记 `seal.entry_limit`，`entriesChecked/entriesTotal` 如实给。
- 只覆盖 CodeResources 清单里的文件；不反推“清单外新增文件”为 mismatch（那是另一类证据，避免误报）。

---

## 2. 验证

```bash
cd /Users/wangbaye/Projects/AppInfoTool
(cd packages/ipa_parser && dart test && dart analyze --fatal-infos --fatal-warnings)
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

新增 5 条单元：摘要一致 / 不一致 / 条目缺失 / 无 CodeResources / 摘要函数不可用。

### 性能（同一台机器，单次测量）

| 指标 | 本次 |
|---|---:|
| 两阶段首屏（静态结果） | **280 ms** |
| 安全结果到达 | **2,073 ms** |
| `analyze` 含安全+密封 | 1,870 ms |
| `analyze(securityAudit:false)` | 261 ms |

CodeResources 校验让安全阶段增加约 0.1–0.25 s（重算选中文件哈希），**不影响首屏**；具体增量随包内文件数变化。

---

## 3. 剩余（Phase D 未完成部分）

- **Android v1 MANIFEST 摘要**已做；**v2 内容摘要**（C11 剩余）未做。
- 本版本**不验签**：`signatureVerified` 恒 false；只有官方基线（Phase E）能给出“冒充/重签”的强证据。
- C-4 的 10 条技术点 finding 仍未拆分（评估卡已覆盖五段链）。
- Phase E 官方基线库仍未接入。

## 4. 下一步建议

1. Android C11（v1 MANIFEST + v2 内容摘要）——补上 Android 侧密封；
2. Phase E 官方基线（需要首批真实指纹）；
3. C-4 finding 拆分（建议先定“聚合 finding vs 保留评估卡”的产品口径）。
