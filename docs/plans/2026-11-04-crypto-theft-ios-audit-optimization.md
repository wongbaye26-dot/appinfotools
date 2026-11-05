# iOS 安全审计优化 — 字符串扫描预筛

> **状态**：已实现并通过包级/根项目回归（2026-11-04）
> **样本**：`sun_signed.ipa`（40.5 MB，仓库根，只读）
> **目标**：降低既有 `IosPrivacyAudit` 的 2.49 s 字符串扫描成本，不改变检测口径

---

## 0. 结论

| 指标 | 优化前 | 网络预筛后 | 标记预筛后 |
|---|---:|---:|---:|
| 完整解析（含安全审计） | 2,760.8 ms | 1,848.6 ms | **1,791.1 ms** |
| 安全审计增量 | 2,490.3 ms | 1,575.8 ms | **1,521.2 ms** |
| Phase B 事实层 | 4.8 ms | 5.2 ms | 5.3 ms |
| `ipa_parser` 测试 | 221 | 221 | **221** |
| 根项目测试 | 1,746 | 1,746 | **1,746** |

总计：**-35.1%**（2,760.8 → 1,791.1 ms）；安全审计本身 **-38.9%**。
Phase B 事实层仍约 5 ms，说明收益来自既有扫描路径的预筛，不是少扫了事实。

---

## 1. 问题

`IosPrivacyAudit` 对主可执行文件 + 27 个嵌套可执行（合计约 68 MB）逐条提取 ASCII 字符串，然后对**每一条**字符串执行：

1. `NetworkEndpoints.collect`：3 个正则（URL / 裸域名 / IPv4）；
2. `IosCryptoSignals.collect`：`toLowerCase` + 钱包/剪贴板标记循环 + 链上地址正则；
3. `_markers` 循环：17 个 `contains`。

2.49 s 里很大一部分是「对不可能命中的字符串也跑完整匹配」。

## 2. 改动

| 文件 | 改动 |
|---|---|
| `packages/analysis_model/lib/src/network_endpoints.dart` | `collect` 开头：`if (!value.contains('.')) return;` —— URL host / 域名 / IPv4 都要求点，没有点的串直接跳过 3 个正则 |
| `packages/ipa_parser/lib/src/security/ios_crypto_audit.dart` | `IosCryptoSignals.collect`：先用合并标记正则预筛；既无标记又短于 34 字符（最短链上地址）的串直接返回；地址正则只在需要时跑 |
| `packages/ipa_parser/lib/src/security/ios_privacy_audit.dart` | 17 个 `_markers` 的 `contains` 前先跑一次合并正则；无命中直接跳过 |

### 正确性

- 网络模式全部要求主机名含点（URL / 裸域名 / IPv4），提前返回不丢结果；`analysis_model` 123 条测试全过。
- 链上地址最短形态是 TRON 的 34 字符（`findCryptoAddresses` 原本就有这条早退），预筛阈值与它一致。
- 合并正则只做**预筛**：真正记录仍走原循环，`caseSensitive` 标记（如 `PrivateKey`）不会被预筛改写。
- 没有改扫描预算、没有改标记表、没有降覆盖；`ipa_parser` 221 条测试全过。

## 3. 复测

```bash
cd /Users/wangbaye/Projects/AppInfoTool
(cd packages/analysis_model && dart test)
(cd packages/ipa_parser && dart test && dart analyze --fatal-infos --fatal-warnings)
flutter analyze --fatal-infos --fatal-warnings
flutter test
flutter test tool/perf_probe_test.dart
```

实测：1,791.1 ms 完整解析 / 1,521.2 ms 安全审计增量；根项目 1,746 通过 / 15 跳过、analyze 零问题。

## 4. 剩余

- 两阶段返回已完成：静态结果 **295 ms** 先到，安全结果约 **1.8 s** 后到；见 `2026-11-04-crypto-theft-ios-two-phase.md`。
- 1.52 s 仍是后台最大单项；继续压需要动 `AsciiStrings.extract` 的逐串分配或并行扫描。
- 不建议在未审计的情况下直接砍扫描预算。
