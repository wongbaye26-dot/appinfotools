# 版本对比里的安全检测对比（2026-11-11）

## 背景

差异页（`lib/ui/diff/diff_page.dart`）此前只比「文件里写了什么」：清单字段、
权限、组件、原生库、域名，以及三个从发现项**反推**的安全字段
（`allowBackup` / 明文策略 / 第三方 SDK）。真正的审计结论 —— 命中了哪些规则、
最严重的是哪一条、五段链走到哪 —— 完全没进对比。

结果是：把 v1 和 v2 两个包放上去，界面上看不出「新版本多了三条风险」。
用户只能分别打开两个详情页，靠肉眼数。

## 加了什么

五个维度，两个标量两个集合，全部走既有的 `DiffSubject` 通道，
因此差异页、Markdown、JSON 三处**自动同源**（都调 `diffOf`）。

| id | 类型 | 含义 | 取值 / 成员 |
|---|---|---|---|
| `security.highestSeverity` | 字段 | 最严重的那条发现 | `p0`…`info`；一条都没有时 `none` |
| `security.findingCount` | 字段 | 发现项条数 | 整数 |
| `security.cryptoTheftLevel` | 字段 | 五段链等级 | `none` / `capabilityOnly` / `suspicious` / `strongEvidence` / `knownFamily` / `unknown` |
| `security.findings` | 集合 | 命中了哪些规则 | `ruleId`（稳定身份） |
| `security.coverageGaps` | 集合 | 哪些覆盖维度有缺口 | 覆盖维度 id |

## 口径（都是有意选择，不是遗漏）

### 1. 没做审计记 `notRequested`，不是「不产出」

`security == null` 表示设置里关掉了 `enableSecurityAudit`，或解析在安全阶段
之前就失败了。既有代码对 `nativeSymbols` / `network` 的做法是**不产出**维度，
但那在这里会造成误读：一侧不产出、另一侧有成员，`_diffSet` 会把它们整片算成
`removed`，界面上就是「新版本删掉了这些漏洞」。

代价是两侧都没审计时多出五条「无法比较」。这是有意的噪音 —— 差异页本来就把
「无法比较」与「没有差异」分开呈现，而「安全这块这次说不清」正是要说的。

### 2. 集合是**规则级**身份，次数交给 `findingCount`

`ANDROID-PERMISSION-WITHOUT-API` 会为每个权限请求各产一条发现。若把次数拼进
成员身份，「多命中两次」就变成一删一增，读起来像换了一条规则 —— 与组件身份串
「属性不进身份」是同一条原则（见 `_componentIdentities` 的注释）。

### 3. 覆盖缺口只收 `partial` / `notCovered`

`notApplicable` 不是缺口（Android 报告里的 iOS 维度不该算），
`CoverageEntry.isGap` 已经表达了这个口径，直接复用。

**空 `entries` 记 `unsupported` 而不是 `absent`**：那是「本引擎没有产出结构化
覆盖」，与「全覆盖」结论相反。

### 4. 等级存机器值，显示层映射

`security.highestSeverity` 存 `p1` 而不是 `P1`：JSON 要语言中立。映射放在
`DiffLabels._severityText`，与详情页的严重度 chip 一致（`P0` / `INFO` / `?`），
只有「一条都没有」需要翻译。

五段链等级的映射从 `crypto_theft_card.dart` 抽到
`DetailRenderer.cryptoTheftLevelLabel` —— 差异页要说「可疑 → 强证据」，
两处各写一份必然漂移，尤其 `knownFamily` 与 `strongEvidence` 共用一句话这种细节。

### 5. 集合成员换人话，但身份不变

`security.findings` 的成员是 `ruleId`，而规则 id 没有语言包（引擎不依赖 slang，
只有 `messageCode` 能翻）。`DiffLabels.findingTitles` 从**本侧**那条发现的
`messageText` 反查结论句，UI 与 Markdown 共用；认不出时原样显示 ruleId，
不留空白。

## 改动文件

- `lib/models/analysis/package_diff_adapter.dart`：`_securityFields` /
  `_securitySets` / `_ruleIds` / `_coverageGaps` / `_highestSeverity`
- `lib/utils/diff_labels.dart`：五个 id 的文案、两个值的格式化、`member()`、
  `findingTitles()`
- `lib/utils/diff_report.dart`：Markdown 成员走 `DiffLabels.member`
- `lib/ui/diff/diff_page.dart`：成员渲染走同一份映射
- `lib/utils/detail_renderer.dart`：新增 `cryptoTheftLevelLabel`（唯一定义）
- `lib/widgets/crypto_theft_card.dart`：改用共享映射
- `lib/utils/field_value_text.dart`：三个诊断 code 的本地化入口
- 6 个语言包：5 个新键 + `diff.severity_none` + 3 个 `field_diagnostic` 键

顺带修了一处**过期声明**：`diff.report_scope_note` 原文写着「发现项差异不在范围内」，
现在已经在范围内了，改成「安全发现按规则级对比；只是命中次数变多时看发现条数字段；
不对比运行时行为」。这句话会印在每份导出的差异报告末尾，不改就是明着说错。

## 验证

| 项 | 结果 |
|---|---|
| `dart format` | 416 files，0 changed |
| `flutter analyze --fatal-infos --fatal-warnings` | No issues |
| 根 `flutter test` | **1,798 通过 / 16 跳过 / 0 失败**（改动前 1,786） |

新增 12 条测试：

- `package_diff_adapter_test.dart`（8）：审计关掉记 `notRequested`；两侧都没审计
  全进「无法比较」且 `hasChanges == false`；新增规则进 `added`；同规则多命中只算
  一个成员；最严重等级取 `rank` 最小；覆盖缺口只收两类；空 `entries` 记
  `unsupported`；五段链等级变化是 `changed`。
- `diff_report_test.dart`（3）：成员显示成结论句而不是机器 id；等级/条数走字段表；
  没审计时进「无法比较」并带原因。
- `diff_page_test.dart`（1）：界面上规则按结论句显示，未变成员不进两组。

顺带修正一处既有断言：`同一个包和自己比` 的 `unknownFieldCount` 由 2 变 5 ——
新增的三个安全标量在「没审计」时同样是「说不清」，不能少报。

## 已知边界

- **同一规则的严重度变化不单独体现**：集合只回答「在不在」，`highestSeverity`
  只回答「最高那条」。要逐规则比等级，需要「按规则 id 做逐字段比较」，
  那是另一层设计（与组件属性差异同一个缺口）。
- 条数变化靠 `findingCount` 一个总数，不按规则拆。
- 两侧都只有静态证据：`includesRuntimeEvidence` 恒为 `false`，差异里也不会出现
  运行时行为。
- ja / ko 的 `field_diagnostic` 组此前**整体缺失**（回退英文），本次只补了这 3 个
  键，其余 15 个仍回退 —— 与审计报告 P2「ja/ko 缺 149 键」同一问题，未在本轮扩大。
