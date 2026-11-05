# 盗 U 检测能力 — Phase C-1 评估引擎实现报告

> **状态**：Phase C-1（评估引擎）**已实现并通过包级回归**；UI/报告见 Phase C-2（2026-11-04）
> **范围**：`CryptoTheftAssessment` 模型 + 纯函数判级 + Android/iOS 证据链适配 + 接入两端审计结果
> **未做（Phase C-2）**：安全 Tab 的盗 U 卡片、Markdown/JSON schema v8、i18n、iOS 审计后台化、新规则 finding
> **纪律**：未新增依赖；未改根 `lib/` UI/报告；未执行样本；未联网

---

## 0. 结论

评估引擎已落地：两端审计结果现在都带 `SecurityAnalysisResult.cryptoTheft`，五段链、缺失环节、level/severity/confidence/score 由**同一套纯函数**产出，不再各写一套阈值。

| 验证项 | 结果 |
|---|---|
| `analysis_model` | **123 条通过**（Phase B 111 + 评估器 12） |
| `apk_parser` | **195 条通过**（Phase B 193 + 链集成 2） |
| `ipa_parser` | **221 条通过**（Phase B 215 + 链集成 6） |
| 包级 `dart analyze` | 5 个包全部 **No issues found** |
| 根项目 `flutter analyze` | **No issues found** |
| 根项目 `flutter test` | **1,746 通过 / 15 跳过 / 0 失败** |
| 新增依赖 | **0** |

> 注意：当前只是**引擎**。界面/报告还没读 `cryptoTheft`，所以用户暂时看不到五段链；这是 Phase C-2 的工作。

---

## 1. 交付物

| 文件 | 行数 | 作用 |
|---|---:|---|
| `packages/analysis_model/lib/src/crypto_theft.dart` | 新建 | `CryptoTheftLevel` / `TheftTechnique` / `ChainStage` / `TechniqueStrength` / `TechniqueEvidence` / `MissingLink` / `CryptoTheftFacts` / `CryptoTheftAssessor` |
| `packages/analysis_model/lib/src/security_finding.dart` | +字段 | `SecurityAnalysisResult.cryptoTheft`（可空；`withLimitation` 保留） |
| `packages/analysis_model/test/crypto_theft_test.dart` | 新建 | 12 条：级别/缺失环节/score/unknown/基线 |
| `packages/apk_parser/lib/src/security/crypto_theft_chain.dart` | 新建 | Android 链装配（调用共享评估器） |
| `packages/apk_parser/lib/src/security/android_security_rules.dart` | + | `AndroidRuleFacts` 增加 `artifacts/loadGraph/payloadProbe`；`buildAndroidCryptoTheftFacts` 映射 |
| `packages/apk_parser/lib/src/security/android_security_audit.dart` | + | 审计参数与结果接入 `cryptoTheft` |
| `packages/apk_parser/test/crypto_theft_chain_test.dart` | 新建 | 审计必产出 assessment；空信号 = none |
| `packages/ipa_parser/lib/src/security/ios_crypto_theft_chain.dart` | 新建 | iOS 链装配（`IosCryptoSignals` + layout/loadGraph/payload） |
| `packages/ipa_parser/lib/src/security/ios_privacy_audit.dart` | + | 审计参数与结果接入 `cryptoTheft` |
| `packages/ipa_parser/test/ios_crypto_theft_chain_test.dart` | 新建 | 6 条：地址替换 P2、钱包 P3、注入+载荷 P1、悬空边 P2、unknown |

---

## 2. 判级规则（与契约 §7.3 对齐）

| 输入组合 | level | severity | confidence |
|---|---|---|---|
| 无信号、覆盖完整 | `none` | info | confirmed |
| 仅能力同现（钱包/密钥/剪贴板/地址） | `capabilityOnly` | P3 | independentCapability |
| 钱包 + 剪贴板写 + 地址字面量（无读来源也可） | `suspicious` | P2 | suspected |
| 密钥材料 + 网络外发 + 钱包 | `suspicious` | P2 | suspected |
| 悬空加载边 + 钱包 | `suspicious` | P2 | suspected |
| 注入 + 载荷 + 钱包 | `strongEvidence` | **P1** | suspected |
| 官方基线不匹配（Phase E） | `strongEvidence` | P1 | confirmed |
| 覆盖被截断且无足够证据 | `unknown` | unknown | unknown |

- 五段：`capability/source/injection/payload/family`；每个未支撑段必须对应一条 `MissingLink`。
- `score` 归一化 0–100（权重 10/20/30/25/35，总和 120）；`unknown` 时 `null`。
- `knownFamily` 枚举保留但 Phase C 不产出（IoC 延期）。
- **不输出**“木马/恶意”定性；P1 只给事实级（当前只有注入+载荷+钱包的强证据，Phase E 基线）。

---

## 3. 两端映射口径

### Android

- wallet/key/clipboard/address 来自现有 `_cryptoTheftSignals`；
- `specialAccess` 来自 `BIND_*` 组件；`webViewBridge` 来自现有 WebView 引用/线索；`networkSink` 来自上传能力；
- `dynamicLoading` 来自现有标记；`danglingLoad` 来自 Phase B `LoadGraph`；
- `suspiciousPayload` 来自 Phase B `PayloadProbeResult` / 清单 `suspicionCodes`；
- `packed` 来自 `NativeCryptoScan.looksPacked`；`coverageIncomplete` 来自 native 截断 / loadGraph / payload 不完整；
- `artifacts/loadGraph/payloadProbe` 目前是**可选参数**：`parse_task` 还没把 Phase B 扫描结果接进来，所以生产路径当前用的是现有信号（不阻断，但拿不到悬空边/载荷细节）。

### iOS

- wallet/key/pasteboard/address 来自现有 `IosCryptoSignals`；
- `injectedDylib` 来自 `IpaLayoutFacts`（`.app` 根目录 dylib）；
- `danglingLoad` 来自 Phase B `LoadGraph`；
- `suspiciousPayload` 来自 Phase B `PayloadProbeResult`；
- iOS 的 pasteboard 读/写无法从字符串层区分，两个布尔都置 true（source 段有支撑；地址替换仍按 wallet+write+address 判 P2）；
- `IosPrivacyAudit.audit` 的 `artifacts/loadGraph/payloadProbe` 同样是可选参数，UI 调用点暂未传。

---

## 4. 已验证用例

1. 空信号 → `none/info`，五段齐全、5 条 MissingLink。
2. 钱包+密钥+剪贴板 → `capabilityOnly/P3`，不判 P2。
3. 钱包+剪贴板写+地址 → `suspicious/P2`，缺失 `missing.noSource`，主技术点 `addressSwap`。
4. 动态加载+可疑载荷+钱包 → `strongEvidence/P1`，confidence 仍 `suspected`。
5. 悬空加载边+钱包 → `suspicious/P2`。
6. 覆盖不全+无信号 → `unknown/unknown`，score=null。
7. 加壳但无信号 → `unknown`，payload 缺失原因 `missing.shellPacked`。
8. 官方基线不匹配 → `strongEvidence/P1/confirmed`（Phase E 接线前由测试驱动）。
9. 五段全支撑 → score=100。
10. 缺失环节与未支撑段一一对应。
11. Android audit 空输入必产出 assessment（不是 null）。
12. iOS 注入 dylib + 载荷 + 钱包 → P1；悬空边 → P2。

---

## 5. 未做 / Phase C-2 清单（C-2 已完成 UI/报告，见 `2026-11-04-crypto-theft-phase-c2-ui-report.md`）

| 项 | 状态 |
|---|---|
| 安全 Tab 的“盗 U”五段链卡片 | 未做 |
| Markdown `## 盗 U 风险` 小节 | 未做 |
| JSON `security.cryptoTheft` + schema v8（当前 `reportSchemaVersion=7`） | 未做 |
| i18n 新 key（stage/missing/level/next） | 未做 |
| `ANDROID/IOS-*` 新规则 finding（10 条 MVP） | 未做；当前仍只有旧的 `*-CRYPTO-THEFT-RISK` finding |
| iOS 审计移入后台任务 | 未做；当前仍在 `info_page.dart:429` 主线程 |
| 把 Phase B `artifacts/loadGraph/payloadProbe` 从 `parse_task`/`ipa_parse_task` 传入审计 | 未做；当前参数默认 null |
| Android `PathClassLoader`/`Runtime.exec` 精确枚举、iOS weak/reexport 区分 | 契约已登记，Phase C-2 再评估 |

---

## 6. 复现命令

```bash
cd /Users/wangbaye/Projects/AppInfoTool
for p in analysis_model apk_parser ipa_parser archive_safety app_icon_extractor; do
  (cd packages/$p && dart test && dart analyze --fatal-infos --fatal-warnings)
done
flutter analyze --fatal-infos --fatal-warnings
```

实测：123 / 195 / 221 / 40 / 25 全过；5 个包 + 根项目 analyze 零问题；根项目 flutter test 1,746 通过 / 15 跳过；dart format 0 changed。
