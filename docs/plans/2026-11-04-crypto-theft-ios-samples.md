# iOS 样本审计记录（Ptv / 33 / wnsr）

> **日期**：2026-11-04｜**样本**：用户提供，只读，不入库
> **工具**：`IpaAnalysisReader.analyze` + `IosPrivacyAudit` + seal/baseline 注入

| 文件 | Bundle ID | Team ID | 版本 | cryptoTheft | seal |
|---|---|---|---|---|---|
| `Ptv_signed_v3.ipa` | `aecy.Edimension168ecy.app` | `N78F3MBNHS` | 8.5.5 | **suspicious / P2** | notChecked 64/1853 |
| `33-v8.5.5.ipa` | `awc.WenChun168wc.app` | `TQFDR236AM` | 8.5.5 | capabilityOnly / P3 | notChecked 64/1780 |
| `wnsr_signed.ipa` | `top.modely.wns`（Venetian） | `N78F3MBNHS` | 2.1.5 | **suspicious / P2** | notChecked 64/1436 |

## 证据链摘要

- `Ptv_signed_v3`：capability/source/injection/payload supported；`addressSwap`；P1 `IOS-RULE-D-ESCALATED`，P2 `IOS-REPACKAGED`/`IOS-RULE-A/G/E`；30 条发现。
- `33-v8.5.5`：capability/source/payload supported，injection false；`capabilityOnly`；P1 `IOS-RULE-D-ESCALATED`；29 条发现。
- `wnsr_signed`：capability/source/injection/payload supported；`addressSwap`；P2 `IOS-REPACKAGED`/`IOS-RULE-G`，P1 `IOS-RULE-D-ESCALATED`；14 条发现。

## 基线判断

**未加入官方基线**：Bundle ID 是随机形态，Team ID 是重签名常见团队，来源是博彩/第三方包；它们适合作为检测样本，不适合作为“官方”指纹。加入会让“官方匹配”变成假权威。

## 顺带改进

CodeResources 有上千条时，64 条预算优先给 `Info.plist` / `.dylib` / `Frameworks` / `PlugIns` / `Watch` / 根文件，资源放最后。样本仍因 64 条上限显示 `notChecked`（保守，不冒充 verified），但至少优先校验代码/清单。

## 验证

- 根项目 `flutter test`：**1,755 通过 / 15 跳过 / 0 失败**
- 根项目 `flutter analyze`：No issues found
- `dart format`：380 files，0 changed

---

## 追加：`Ptv_nosignet.ipa` / `sun_nosigned.ipa`

用户标注为“未签名”，但 `codesign --verify` 实测 **不是无效签名**：

| 文件 | Bundle ID | Team ID | codesign | 签名主体 |
|---|---|---|---|---|
| `Ptv_nosignet.ipa` | `aecy.Edimension168ecy.app` | `TQFDR236AM` | **verified** | Apple Distribution: GERCEK-KAAN MADENCILIK… |
| `sun_nosigned.ipa` | `com.overall.sun` | `9TSP2W4FWJ` | **verified** | Apple Development: Ufuk YASEF |

结论：

- 它们是**用第三方 Apple 证书重签**的包，不是“没有代码签名”的包；
- 静态材料里保留了 `_CodeSignature/CodeResources` 与描述文件，所以 engine 的 `seal` 能读到清单；
- `seal` 因为 64 条上限显示 `notChecked`（1780/189 条，优先验了 dylib/Frameworks）；
- 没有官方基线条目，因此 `baseline=noBaseline`；
- 如果产品口径是“不是官方发行人”，应该用**官方基线/Team ID** 表达，而不是把它叫“未签名”。

检测摘要：

- `Ptv_nosignet`：capabilityOnly/P3；source supported，payload supported；29 条；P1 `IOS-RULE-D-ESCALATED`。
- `sun_nosigned`：capabilityOnly/P3；source supported，payload supported；17 条；P1 `IOS-GET-TASK-ALLOW`、`IOS-RULE-D-ESCALATED`。
