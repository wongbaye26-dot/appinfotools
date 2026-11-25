# 规则 F 的否定结论不能超出实际扫描范围（2026-11-25）

对应 `docs/audit/2026-11-09-security-confidence-audit.md` 的 **P1-4**，也是
`docs/notes/report-quality-review.md` 在 2026-10-22 就点名、一直没闭环的那条。

## 1. 问题

`ANDROID-RULE-F` 是**否定结论**：「本次没发现上传特征」。

- `_matchesRuleF` 只看 `uploadClues.isEmpty`；
- `_buildRuleF` 只要 `hasDexContent` 就给 `confidence: confirmed`；
- 正文只有一句「within the current analysis scope」，不带任何数字。

加固包最常见的形态是单个 DEX 超过 8 MiB 的扫描预算，只扫到前一段。此时
`uploadClues` 为空只说明「扫过的那段没有」，报告却说 `confirmed` +「未发现」，
读者会理解成「这个应用不上传」。

## 2. 判定：什么算「不完整」

新增 `_RuleFScope`，从两个扫描结果里取三件事：

| 来源 | 含义 |
|---|---|
| `scan.skippedForBudget` | 单文件超出字节预算，后面的字节没扫 |
| `methodScan.truncatedForBudget` | 方法体遍历被预算截断 |
| `methodScan.notTraversable` | DEX 结构不可遍历，方法引用一条也解不出 |

任一非空 → `incomplete`。字节总数按「已扫 + 每个被跳过文件的剩余」算，
`percent` 向下取整（部分扫描绝不给 100%，与 `DexBudgetSkip.percent` 同一口径）。

**`desyncedBodies` 不算在内**：它说明「读到的调用点不可信」，是解析质量问题，
不是覆盖缺口；那条已经作为 `android.dex.desynced_bodies` 覆盖说明单独呈现。
把它折进这里会让大量正常包被降级，信号反而变差。

## 3. 改法

- **仍然产出这一条。** 不完整时若改成不产出，读者看到的是空列表 —— 那正是
  规则 F 存在的理由（「没查」与「没有」必须能分开）。`_matchesRuleF` 因此
  不变，注释里写清了为什么。
- **置信度**：`noDex || incomplete` → `unknown`，只有扫全了才是 `confirmed`。
- **正文**：不完整时换成新 code `android.rule_f_truncated`，带
  `{scannedBytes}` / `{totalBytes}` / `{percent}` / `{skippedDex}` /
  `{unanalysedDex}`；结尾仍是「这不代表应用不上传」。
- **证据**：`rule_f.scope` 增加三个参数，从「扫了几个 DEX / 几个调用点」
  变成「…，覆盖 X / Y 字节（Z%）」—— 完整扫描时也显示，读者能直接看到底数。
- **局限**：不完整时换 `android.rule_f.limitation_incomplete`（只覆盖已扫描
  部分）；`noDex` 与完整扫描沿用原有两个 code。

## 4. 测试

- `packages/apk_parser/test/android_security_rules_test.dart` 新增 4 条：
  扫全 → `confirmed` + `android.rule_f`；补 9 MiB 零字节 → `unknown` +
  `rule_f_truncated` + `percent < 100` + `skippedDex == 1`；非 DEX 字节 →
  `skippedDex == 0` 但 `unanalysedDex ≥ 1`（证明结构路径也降级）；
  不完整时仍然只产出一条、不退回空列表。
- `test/audit_permission_and_rulef_test.dart` 新增 1 条渲染断言：中文正文
  含「字节」「%」「不能据此认为」，不含 `{`，局限写「只覆盖已扫描的部分」。
- `test/android_security_audit_test.dart` 里那条「引擎真的把 code 挂上去」
  改用**真实** `real-netprobe.dex` 而不是手拼字符串 —— 非 DEX 字节现在会走
  不完整分支，原夹具测的已经不是它想测的常规路径。

## 5. 验证

- 根 `flutter test`：**1,827 通过 / 16 跳过**
- 五包：40 + 141 + **226** + 245 + 25 = **677 通过**
- `flutter analyze --fatal-infos --fatal-warnings` 0 问题；`dart format` 0 changed
- `test/security_finding_code_registration_test.dart` 自动扫到新 code
  并确认注册（`messageCode` → `findingText`，`limitationCode` →
  `limitationText`），无需手工维护清单

## 6. iOS 侧（同日补齐）

`IOS-RULE-F` 是同一个形态：`ios_privacy_audit.dart` 里只看
`executableBytes` 是否为空就给 `confirmed`，不看 `truncated` / `unscanned`。

改法与 Android 对齐，但事实来源不同：

| 判定 | iOS 字段 |
|---|---|
| 字节没扫全 | `truncated`（单个可执行文件超过 `budgetBytes`） |
| 文件根本没读到 | `unscanned`（嵌套预算耗尽、`bytes == null`） |

- 新增 `overBudgetCount` 计数（`truncated` 只是布尔，写不出「几个」）。
- `noExecutable || overBudgetCount > 0 || unscanned.isNotEmpty` → `unknown`。
- 新 code：`ios.rule_f_truncated`（带 scannedBytes/totalBytes/percent/
  overBudget/unread）+ `ios.rule_f.limitation_incomplete`。
- 证据此前**完全没有本地化**（纯英文字符串），中文界面上一直是英文。这次
  加了 `ios.rule_f.scope` detail code + 6 语言模板，与 Android 的
  `rule_f.scope` 同构。
- `phraseSignals.truncated` / `callSiteTruncated` **不算**：它们影响的是
  中文话术与调用点归因，不是「上传标记扫没扫到」；折进来会让正常包被降级。

测试（`test/ios_privacy_audit_test.dart` +4）：扫全 → `confirmed`；预算压到
16 字节 → `unknown` + `overBudget == 1` + `percent < 100`；嵌套二进制
`bytes: null` → `unread == 1` 且 `overBudget == 0`（证明是「没读到」路径）；
zh-CN 下正文与证据都是中文且无未替换占位符。

## 7. 仍然没做

- 运行时证据仍然为零，`signatureVerified` 恒 `false`（审计 2.3 第 2 条）。
- 本机没有真实 IPA 样本（`APPINFOTOOL_SAMPLES` 未设置），iOS 侧只有单测
  覆盖，没有真实包上的端到端数字。Android 侧用真实 APK 验过。
