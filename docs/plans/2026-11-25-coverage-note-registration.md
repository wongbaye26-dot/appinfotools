# 覆盖说明与维度名的注册闭环（2026-11-25）

对应 `docs/audit/2026-11-09-security-confidence-audit.md` 的 P1-1 / P1-2 /
P1-3 / P2-1 / P2-3。P1-4（`ANDROID-RULE-F` 在 DEX 截断时仍给 `confirmed`）
**不在本次范围**，它要改判定逻辑并加语义测试，单独一轮。

## 1. 问题：code 产出了，呈现层没接

引擎产出「稳定 code + 英文回退」，呈现层按 code 取本地化文案；取不到就
回退英文。这条设计本身是对的，但**没有任何守卫要求「引擎产出的每个 code
都必须有 case」**。于是：

| 缺陷 | 现象 |
|---|---|
| `android.dex.unicodeStrings` 无维度名 | 6 种语言的界面与 Markdown 直接显示机器 id |
| 4 条 `android.dex.unicode_strings.*` 无覆盖说明 | 中文界面显示英文原文 |
| `android.dex.dynamic_loading` 无局限说明 | 「运行时加载的 DEX 不在分析范围」这条最关键的警告是英文 |
| 守卫清单写死 16 个维度（实际 23） | 上面三条全绿通过 |

## 2. 改法：把「记得同步」换成门禁

### 2.1 补文案（6 个语言包）

- `coverage.dimensions.android_dex_unicodeStrings`
- `coverage.notes.android_dex_unicode_strings.{no_content,untrusted,truncated,scope}`
- `security.limitation_notes.android_dex_dynamic_loading` 早就存在，缺的只是 case

### 2.2 守卫改成从引擎源码提取

新增 `test/support/coverage_code_guard.dart`：

- `engineCoverageDimensionIds()` —— 抓 `CoverageEntry.noted(id: '…')`
- `engineCoverageNoteCodes()` —— 抓 `note:` 位上的 `('code', 'English…')` 元组
- `engineAnalysisNoteCodes()` —— 抓 `AnalysisNote('code', …)`

两个既有测试（`analysis_coverage_test.dart` / `i18n_coverage_test.dart`）
里写死的 16 个维度清单全部删除，改用提取结果；并加了「提取到太少就报错」
的自检，避免正则失效后循环一次都不跑、测试假通过。

新增 `test/coverage_note_registration_test.dart`：对提取出的每个 code，用
**哨兵字符串**构造 note，断言呈现层没有回退到哨兵。两条通道（覆盖说明 /
局限说明）各测一遍，并额外断言 zh-CN 的文案不等于英文原文 —— 只复制英文
也算「没翻译」。

## 3. 守卫第一次跑就抓出 6 条审计没列到的

审计报告只点了 Unicode 那 5 条，实际同类的还有：

| code | 文案所在分组 | 现象 |
|---|---|---|
| `android.sdk_inventory.no_dex` | `security.limitation_notes` | 覆盖网格显示英文 |
| `android.sdk_inventory.incomplete` | 同上 | 同上 |
| `android.native_hardening.not_provided` | 同上 | 同上 |
| `android.native_hardening.some_without_relro` | 同上 | 同上 |
| `ios.entitlements.empty` | 同上 | 同上 |
| `ios.entitlements.no_profile` | 同上 | 同上 |

成因是同一类：这些 code 既作为 `CoverageEntry.noteCode` 产出，也被
`limitationNoteText` 使用，但 case 只加在了后者。`cleartext_policy` 两条
此前踩过同一个坑（`analysis_report.dart` 里有注释），当时只补了那两条，
没有加守卫 —— 所以又发生了第二次。

**处理方式**：在 `coverageNote` 里补 case，文案直接取
`t.security.limitation_notes.*`。没有复制到 `coverage.notes`：两条通道说的
是同一件事，复制一份只会让措辞日后漂移。

## 4. 顺带：P2-3 注释与死键

`lib/apkparser/apk_info.dart` 的 `_auditExtractedBaseApk` 注释仍写「覆盖范围
仅限 base APK」，而 split 的 DEX / 原生库 / 资源字符串 / 证书 / 密封早就参与
分析。改成「清单、权限与资源表取自 base APK（分包清单不合并）」。

`android.split_apk.base_only` 已无生产者（`grep` 只有 switch、i18n、测试三处
引用），一并删除 switch case、6 个语言包的键与测试里的引用。

## 5. 验证

- 根 `flutter test`：**1,822 通过 / 16 跳过**（新增 6 条守卫）
- 五个包：40 + 141 + 222 + 245 + 25 = **673 通过**
- `flutter analyze --fatal-infos --fatal-warnings` 0 问题；`dart format` 0 changed
- 端到端（真实夹具 APK，zh-CN）：

  ```
  android.dex.unicodeStrings | DEX Unicode 字符串 | 没有可供 Unicode 扫描的 DEX string_ids 条目
  android.sdkInventory       | 第三方 SDK 清单   | 没有提供 DEX 内容，因此未建立第三方 SDK 清单
  android.nativeHardening    | 原生库加固       | 没有提供原生库内容，因此未读取二进制加固属性
  ```

  改前三处分别是机器 id 与英文原文。

## 6. 未做

- **P1-4**：`ANDROID-RULE-F` 在 DEX 预算截断时仍给 `confirmed`，正文不带
  「扫了 X/Y 字节」。已在同日单独完成，见
  `docs/plans/2026-11-25-rule-f-truncated-scope.md`。
- **P2-2**：ja / ko 仍各缺 149 键（本次新增的 5 条已补齐，历史缺口未动）。
- **P2-4**：官方基线仍是 2 条 Android / 0 条 iOS，需要真实官方样本。
