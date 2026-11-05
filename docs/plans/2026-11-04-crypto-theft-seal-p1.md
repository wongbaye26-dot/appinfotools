# 密封不一致 → P1（Phase D 收口）

> **状态**：已实现并通过包级/根项目回归（2026-11-04）
> **问题**：`security.seal` 早就能算出 `mismatch`，但评估只吃 `baselineMismatch`；没有别的信号时不会产生 P1
> **完成**：`SealCheck.mismatch` 进入 `CryptoTheftFacts.sealMismatch`，并产出 `ANDROID-APK-SEAL-MISMATCH` / `IOS-SEAL-MISMATCH` finding

---

## 0. 结论

- 密封不一致现在**独立于钱包语境**产生 P1：`strongEvidence / p1 / confirmed`；
- 同时产出事实级 finding `ANDROID-APK-SEAL-MISMATCH` / `IOS-SEAL-MISMATCH`；
- UI/JSON/Markdown 已有的 `security.seal` 继续显示路径、期望/实际摘要前缀；
- 文案已加 `theft.seal_mismatch_*`，四语齐全（ja/ko 回退英文）。

| 验证项 | 结果 |
|---|---|
| `analysis_model` | **124 通过**（+1 sealMismatch 判级） |
| `apk_parser` | **204 通过**（+1 seal finding 测试） |
| `ipa_parser` | **227 通过**（+1 iOS sealMismatch 判级） |
| 根项目 `flutter test` | **1,753 通过 / 15 跳过 / 0 失败** |
| 根项目 `flutter analyze` | No issues found |
| `dart format` | 380 files，0 changed |

## 1. 实现

| 文件 | 改动 |
|---|---|
| `packages/analysis_model/lib/src/crypto_theft.dart` | `CryptoTheftFacts.sealMismatch`；`_levelOf` 在 `sealMismatch || baselineMismatch` 时返回 strongEvidence/P1/confirmed |
| `packages/apk_parser/lib/src/security/android_security_rules.dart` | builder 接收 `SealCheck`，写 `sealMismatch` |
| `packages/apk_parser/lib/src/security/crypto_theft_chain.dart` | `assess(..., seal:)` |
| `packages/apk_parser/lib/src/security/android_security_audit.dart` | `seal.mismatch` → `ANDROID-APK-SEAL-MISMATCH` finding（P1/confirmed） |
| `packages/ipa_parser/lib/src/security/ios_privacy_audit.dart` | `seal.mismatch` → `IOS-SEAL-MISMATCH` finding |
| `lib/utils/analysis_report.dart` | `seal.mismatch` finding 文案/建议/局限本地化 |
| `assets/i18n/*.json` | `theft.seal_mismatch_message/review/limitation` |

### 边界

- `seal.state == mismatch` 才是 P1；`unsealed / notChecked / unknown` **不**产生 P1（避免把“没查”当成“被改”）；
- 摘要不一致只证明“内容与密封记录不同”，不证明“谁改的”；报告 still `signatureVerified=false`；
- `SealCheck` 的最多 64 条限制仍生效；partial 时不会冒充 verified。

## 2. 顺手修复

`samples` 审计时发现 `ChainStage.name` 在 `flutter test` 运行时不可用（`NoSuchMethodError`），已加稳定 `ChainStage.code` getter，报告 JSON 改用 `code`；否则真实报告在导出时会崩。

## 3. 下一步

1. iOS 官方基线（Team ID）；
2. baseline mismatch 拆成独立 finding（当前只在评估/JSON/UI）；
3. Split/XAPK 路径接入 seal/baseline/artifacts；
4. C-4 是否拆 10 张卡（目前规则 id 映射）。
