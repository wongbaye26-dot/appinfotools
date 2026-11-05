# Phase E — 官方基线（Android 首个条目）

> **状态**：Android 官方基线加载/匹配/接线已实现并通过根项目回归（2026-11-04）
> **数据来源**：用户提供的 `17加固.apk`（外部路径 `/Users/wangbaye/Projects/test/17加固.apk`）
> **未做**：更多官方指纹、iOS 官方条目数据、独立来源核验（iOS 匹配逻辑已接线）
> **纪律**：只存公开指纹，不存应用二进制；匹配失败不冒充“官方”

---

## 0. 结论

用户提供的 APK 已经提取出首个 Android 基线条目，并完成端到端匹配：

| 字段 | 值 |
|---|---|
| packageId | `com.pwtma.tgewuir.ddmw` |
| 应用 label | `17⨾｡5`（加固/混淆后的 label，不建议作为展示名） |
| 证书 SHA-256 | `ea5ff6c485d14b51f064479904231706dbcd243e9ef61d670cb59c24b92e919f` |
| 签名方案 | v2 + v3 + v3.1 |
| 基线条目 id | `android.com.pwtma.tgewuir.ddmw` |

第二个条目（用户提供的官方更新 URL）：

| 字段 | 值 |
|---|---|
| packageId | `com.trim.music` |
| displayName | 飞牛音乐 |
| 证书 SHA-256 | `863ffbb78fec1d01f37f39f35f572fd99e2cb1d58bdaae70b7e85d90dad07257` |
| 签名方案 | v2 + v3 + v3.1 |
| 基线条目 id | `android.com.trim.music` |
| 来源 | `official-site`：`https://iso.liveupdate.fnnas.com/x86_64/app/FN_Music_1.0.3_00610141147.apk`（签名查询串已剥离，保留稳定 URL） |

端到端实测：

```
17加固.apk        → baseline=BaselineStatus.match, entry=android.com.pwtma.tgewuir.ddmw
FN_Music.apk      → baseline=BaselineStatus.match, entry=android.com.trim.music
```

## 1. 重要边界（必须看）

- 第一个条目（17加固）来自**用户提供的 APK**；`sources[0].type="other"`，notes 已写明“candidate baseline, not independently verified”。
- 第二个条目（飞牛音乐）来自用户提供的**官方更新 URL**；`sources[0].type="official-site"`。URL 里的签名查询串已剥离，避免过期 token 写进基线。
- 因此它当前只能证明“这个文件与这个指纹一致”，**不能**证明任何第三方 APK 是冒充/重签；要做后者，需要更多官方包或官方公布的指纹。
- 基线匹配只影响评估的 family 段与 `baselineMismatch`；**没有基线不会产生 P1**，只会是 `noBaseline/unavailable`。

## 2. 实现

| 文件 | 内容 |
|---|---|
| `packages/analysis_model/lib/src/official_baseline.dart`（新） | `BaselineStatus`、`OfficialBaselineEntry/Db`、`BaselineMatch` |
| `packages/analysis_model/lib/src/security_finding.dart` | `SecurityAnalysisResult.baseline` |
| `lib/utils/official_baseline_store.dart`（新） | 读取 `assets/baseline/official_baseline_v1.json`；解析/校验；`matchAndroid(packageId + certSha256)` |
| `assets/baseline/official_baseline_v1.json`（新） | 首个 Android 条目；已通过官方基线 schema 校验 |
| `lib/apkparser/parse_task.dart` | worker 内取证书 SHA-256 → 匹配基线 → 传给 `AndroidSecurityAudit.audit` |
| `lib/apkparser/apk_info.dart` | 启动解析前加载基线库 |
| `packages/apk_parser/lib/src/security/android_security_rules.dart` | `buildAndroidCryptoTheftFacts` 写入 `baselineMismatch/baselineEntryId` |
| `lib/utils/analysis_report.dart` | JSON `security.baseline` + Markdown `### 官方基线` |
| `lib/widgets/crypto_theft_card.dart` | 卡片显示 match/mismatch/noBaseline/unavailable |

### 匹配语义

- DB 不可用 → `unavailable` + `baseline.unavailable`；
- 无同包条目 → `noBaseline` + `baseline.no_entry`；
- 有条目但**实际证书指纹缺失** → `unavailable` + `baseline.fingerprint_unavailable`（不判 mismatch）；
- 有实际指纹但交集为空 → `mismatch` + `baseline.fingerprint_mismatch`；
- 交集非空 → `match`。

## 2.5 iOS 基线（已接线，暂无数据）

- `OfficialBaselineStore.matchIos`：Bundle ID + Team ID 交集；
- `IpaAnalysisReader.analyze(baselineDb:)` 在 worker 内匹配，结果进 `security.baseline` 与评估；
- `IpaParseTask.start(..., baselineDb:)`，UI 启动前加载基线库；
- Team ID 来自 `embedded.mobileprovision` 的 `TeamIdentifier`；App Store 分发包通常没有描述文件，此时是 `unavailable`，不会误判 mismatch；
- 当前基线资产只有 Android 条目，所以 iOS 目前实际都是 `noBaseline`。

## 2.6 基线不一致 finding

`baseline.mismatch` 现在同时产出：
- `ANDROID-BASELINE-MISMATCH` / `IOS-BASELINE-MISMATCH` P1 finding；
- 评估 `strongEvidence/P1/confirmed`；
- 文案 `theft.baseline_mismatch_*`（四语）。

## 3. 验证

| 项 | 结果 |
|---|---|
| 基线 JSON schema | 通过 `official-baseline-v1.schema.json` |
| `test/official_baseline_store_test.dart` | 6 通过（match/mismatch/noBaseline/unavailable/资产条目） |
| 根项目 `flutter test` | **1,755 通过 / 15 跳过 / 0 失败** |
| 根项目 `flutter analyze` | No issues found |
| 端到端样本 | `17加固.apk` → match；`FN_Music.apk` → match |

## 4. 下一步

1. 你们继续提供 APK（最好附官方来源 URL / 是否官方），我按同一流程提取更多条目；
2. iOS 官方包（Team ID + Bundle ID）接线；
3. 更多条目后，把 `mismatch` 作为 P1 强证据接入 finding（当前只进评估与 `security.baseline`）。
