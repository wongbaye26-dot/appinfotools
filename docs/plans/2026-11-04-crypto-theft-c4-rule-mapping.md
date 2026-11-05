# C-4 — 10 条技术点规则映射（不拆重复 finding）

> **状态**：已实现并通过包级/根项目回归（2026-11-04）
> **决策**：不新增 10 张重复的 `SecurityFinding` 卡片；把 10 条规则 id 映射到五段链的 `TechniqueEvidence.ruleIds`
> **原因**：评估卡已经逐段呈现同一批事实，再拆 finding 会与旧 `*-CRYPTO-THEFT-RISK` 重复；产品已接受“只给风险证据、不给恶意判决”

---

## 0. 结论

- `CryptoTheftAssessment.chain[]` 每段现在带 `ruleIds[]`；
- JSON `security.cryptoTheft.chain[].ruleIds`、Markdown 证据链逐段输出；
- UI 盗 U 卡片在每段下面显示对应规则 id；
- 旧 `ANDROID/IOS-CRYPTO-THEFT-RISK` finding 保留为**摘要**，不再新增 10 张卡片。

| 验证项 | 结果 |
|---|---|
| `analysis_model` | 123 通过（地址替换用例新增 ruleIds 断言） |
| `apk_parser` | 203 通过 |
| `ipa_parser` | 226 通过 |
| 根项目 `flutter analyze` | No issues found |
| 根项目 `flutter test` | **1,747 通过 / 15 跳过 / 0 失败** |
| `dart format` | 377 files，0 changed |

## 1. 映射

| 段 | Android | iOS |
|---|---|---|
| capability | `ANDROID-THEFT-CHAIN`；`specialAccess` 时 `ANDROID-ACCESSIBILITY-ABUSE` | `IOS-THEFT-CHAIN` |
| source | 钱包+剪贴板写+地址 → `ANDROID-CLIPBOARD-ADDRESS-SWAP`；密钥+外发 → `ANDROID-MNEMONIC-EXFIL` | `IOS-CLIPBOARD-ADDRESS-SWAP`；`IOS-MNEMONIC-EXFIL` |
| injection | 悬空边 → `ANDROID-LOAD-GRAPH-DANGLING`；动态加载 → `ANDROID-PAYLOAD-DROPPED` | 注入 dylib → `IOS-INJECTED-DYLIB-LOADED`；悬空边 → `IOS-DANGLING-LOAD` |
| payload | 可疑载荷 → `ANDROID-PAYLOAD-DROPPED` | 可疑载荷 → `IOS-INJECTED-DYLIB-LOADED` |
| family | `ANDROID-THEFT-CHAIN` | `IOS-THEFT-CHAIN` |

> 10 条 MVP 规则均有落点；`ANDROID-MNEMONIC-EXFIL` 与 `IOS-MNEMONIC-EXFIL` 在 `keyMaterial && networkSink` 时出现。

## 2. 为什么不是 10 张 finding

1. 同一事实已经在五段链卡片里逐段呈现，再出 10 张卡是重复；
2. 旧 `*-CRYPTO-THEFT-RISK` 仍在，10 张新卡会与它重复；
3. 报告消费者可以按 `chain[].ruleIds` 检索规则，不需要解析 finding 正文；
4. 不改变“只给证据、不给恶意判决”的口径。

## 3. 兼容性

- `ruleIds` 是**新增字段**；旧消费者忽略即可；
- JSON schema v8 已把 `ruleIds` 加入 `techniqueEvidence` 的 required/properties，示例已同步；
- 旧 finding id 不变，现有基线/规则单测不受影响。

## 4. 下一步

- Phase E 官方基线（需要首批真实指纹）；
- 若产品坚持“每条规则一张卡”，再基于 `ruleIds` 生成 finding 即可，无需重新推导事实。
