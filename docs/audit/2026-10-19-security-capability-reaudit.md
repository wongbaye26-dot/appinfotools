# APK / IPA 安全分析能力复核审计

> 审计对象：**HEAD `6a1c82d`**（tag `v2.5.0` 之后 6 个提交）
> 审计日期：2026-10-19
> 性质：**只读复核**。除三支一次性探针（审计后已删除）外未修改任何生产代码。
> 审计范围：`apk_parser` 安全引擎 → `ipa_parser` 安全引擎 → `analysis_model` 发现/覆盖模型
> → 报告（Markdown / JSON）→ 界面 → 差异对比。
>
> **与既有两份审计的关系**
>
> | 文档 | 它回答的问题 | 分数口径 |
> |---|---|---|
> | `2026-10-18-security-analysis-capability-audit.md` | 「还能加什么能力」 | 实现方滚动累加自评（65 → 95） |
> | `2026-10-19-analysis-module-capability-audit.md` | 「全链路能不能把结论交付出去」 | 首次独立复核（76） |
> | **本份** | 「上一轮 10 项修复是否真的落地，剩下的还在不在，有没有新问题」 | 独立复核（**77**） |
>
> 三者权重不同，**分数不可直接比较**。本份的价值在「逐条复现」，不在分数本身。

---

## 0. 结论

**一句话：上一轮的三条高价值缺陷全部真修好了（有 A/B 对照与实测数字），本轮没有 P1；
剩下的问题集中在两端 —— iOS 的能力广度，以及「我们没看到」这件事仍然有 5 处不可见。**

三条最值得先修的：

1. **同一类「分母口径」缺陷还有第三处** —— `android.nativeHardening` 的 `covered/limit` 是
   「已加固数 / 已解析数」，而 `status` 比的是「已解析数 / 全包唯一库数」。266 个库只解析 10 个时，
   覆盖面板会把这一行显示成 `部分覆盖 … 8/10`，读起来像覆盖了 80%（P2-1）。
2. **`hasCoverageGaps` 恒为真，而真正有区分力的 `AnalysisCoverage.hasGaps` 在生产代码里 0 处使用**
   —— 14 个样本（13 APK + 1 IPA）全部 `gaps=true`；JSON 里两个「hasGaps」同名不同义（P2-3）。
3. **iOS 的「数据发到哪」答不了** —— `IosPrivacyAudit` 从不构造 `NetworkFacts`，
   实测 `domains=0 / ips=0`；标记只有 17 个（Android 36），缺 IDFA / ATT / 蓝牙 / 健康 / 运动（P2-6）。

综合评分 **77 / 100**。

| 维度 | 权重 | 得分 | 依据 |
|---|---:|---:|---|
| Android 检测广度 | 20 | **17** | 规则表 18 条（7 条组合）+ 表外 9 类单点 + 24 权限 + 36 标记 + 25 SDK + 26 原生符号；缺 8 类常见权限（P2-5） |
| iOS 检测广度 | 15 | **10** | 26 个 ruleId 但仅 17 标记、无网络端点、无必需理由 API（P2-6、P2-9） |
| 检测深度与证据强度 | 20 | **14** | 四级证据链（字符串 → `method_ids` → `invoke` 调用点 → 同方法体共现）实测成立；无跨方法、无数据流、iOS 无字节码 |
| 覆盖诚实度 | 15 | **11** | 19 维度 × 4 态模型很好，三处分母已修；但一处同类未修、`hasCoverageGaps` 恒真、签名块读不出不可见（P2-1～P2-3、P2-8） |
| 结果交付（报告 / 界面 / 本地化） | 15 | **10** | 界面覆盖面板完整；但 JSON 缺平台事实、Markdown 缺 11 组字段、4 个英文标签、诊断本地化 1/31、7 个 code 未注册（P2-2、P2-4、P2-7） |
| 正确性与误报控制 | 10 | **8** | v1-only / 未签名已分开、权限精确去重、NSC 真展开、缺失判据加 `!truncated`；扣分见 P2-10 |
| 工程与回归保障 | 5 | **5** | 1,924 条测试全绿、`analyze` 零问题、有界读取；但 13 个 APK 夹具 0 DEX / 0 `.so`（P2-11） |

---

## 1. 审计口径

| 手段 | 做法 | 用在 |
|---|---|---|
| 静态盘点 | 数 `ruleId` / `CodeMarker` / `PermissionRule` / `SdkDescriptor` / `CoverageEntry` / `NativeSymbolMarker` | §2 |
| **生产路径探针** | 复刻 `parse_task.dart` 与 `info_page.dart:429` 的调用序列（`ApkReader.open → parse → DEX/so → scanHardeningSignals → audit`；`ZipHelper.open → IpaAnalysisReader.analyze → IosPrivacyAudit.audit`） | §3 |
| 真实样本 | 13 个 APK 夹具 + `sun_signed.ipa`（40.5 MB，28 bundle）+ 12 个 DEX 夹具 + 10 个 `.so` 夹具 | §3 |
| **文案落地探针** | 在 zh-CN 下对每条真实发现调 `findingText / recommendationText / limitationText`，判断是否含 CJK，并与引擎产出的 code 集比对 | P2-7 |
| 门禁实测 | `flutter test`、5 个包 `dart test`、6 个 `analyze --fatal-infos --fatal-warnings` | §3.4 |

探针只打印，不断言。三支探针（`zz_audit_probe` / `zz_depth_probe` / `zz_i18n_probe`）审计后已删除，
`git status` 仅剩自忽略的 `.codegraph/`。

### 1.1 本次**没有**测到什么（先划边界）

| 没测 | 原因 | 后果 |
|---|---|---|
| 真实 APK（含 DEX / 原生库的大包） | 仓库里 13 个 APK 夹具**全部 0 DEX、0 `.so`**（探针实测） | 组合规则 A/B/C/E/G、`sdkInventory`、`nativeSymbols`、`nativeHardening` 只能靠单元级夹具驱动，端到端未跑 |
| `apksigner` 真实验签 | 本机未装 Android SDK | 只审了 `SignatureAnalyzer` 的解析与状态映射逻辑 |
| `codesign` 真实验签 | 需 macOS 且需解包出 `.app` | 同上 |
| 加固壳样本 | 无 | 只审了 `hardening.dart` 的判据结构 |
| 运行时行为 | 不装不跑（设计如此） | — |

上一轮审计用了 4 个真实包 / 86 个 DEX / 431 MiB；**本轮的 Android 数字因此偏「静态盘 + 单元级」**，
与上一轮的端到端结论互相补充，不能互替。

---

## 2. 能力盘点（可复现数字）

| 项 | Android | iOS | 取法 |
|---|---:|---:|---|
| 规则表条目（组合规则） | **18**（7） | — | `android_security_rules.dart` 的 `androidSecurityRules` |
| 报告中可能出现的 `ruleId` | **53**（27 静态字面量 + 24 权限 + 2 升级变体） | **26** | 全仓 `ruleId:` 字面量 + 动态拼接 |
| 权限目录 | **24** | — | `PermissionCatalog.rules` |
| 「权限↔必须有 API」编目 | **10** | — | `_permissionApiMarkers` |
| 代码标记（字符串/引用双层） | **36** | **17** | `codeMarkers` / `_markers` |
| 服务类 SDK | **25** | — | `sdkCatalog` |
| 原生符号标记（两侧共享） | **26** | **26** | `nativeSymbolMarkers` |
| 覆盖维度 | **11** | **8** | `AnalysisCoverage.entries` |
| 测试（根 + 包） | — | — | **1,567 + 357 = 1,924** |

**iOS 的 17 个标记**：photo-full-library / photo-asset / photo-picker / photos-ui / camera /
contacts / contacts-legacy / location / microphone / microphone-engine / ocr / ocr-image-request /
clipboard / network-session / network-upload / network-alamofire / network-afnetworking。

---

## 3. 实测结果

### 3.1 Android 夹具（13 个，生产路径）

| 夹具 | DEX | arsc | 发现项 | 关键 |
|---|---:|---:|---:|---|
| `signed-v1-only.apk` | 0 | 1 | 5 | `V1-ONLY-SIGNING` p3 |
| `signed-unsigned.apk` | 0 | 1 | 5 | **`UNSIGNED` info** ← 与上一行已分开 |
| `signed-v2-v3.apk` | 0 | 1 | 4 | 两条签名规则都不报 |
| `attr-fixture.apk` | 0 | 1 | 6 | `DEBUGGABLE` p1 + `PERMISSION-EXPIRED` |
| `nsc-fixture.apk` | 0 | 1 | 4 | `RULE-D` p2（NSC 已展开） |
| `manifest-extra-fixture.apk` | 0 | 1 | 5 | `RULE-D` |
| `night-mode-resources.apk` | 0 | 4 | 2 | `arsc covered 4` |
| 其余 6 个（icon / cyclic / no-night 等） | 0 | 1～4 | 2 | 只有 `UNSIGNED` + `RULE-F` |

**13/13 的 `android.dex.*` 全部 `notCovered`、`nativeSymbols` / `nativeHardening` 全部
`notApplicable`** —— 不是引擎的问题，是夹具里没有 DEX 与 `.so`。

`android.cleartextPolicy` 在 13/13 上都是 `covered 1/1`（见 P2-10）。

### 3.2 `sun_signed.ipa`（40.5 MB）

```
bundles=28  nested=24  nestedTotal=27  exe=35,953,728 B  analyze=422 ms
findings=11  limitations=6  diagnostics=31
coverage:
  ios.infoPlist          covered          -/-
  ios.usageDescriptions  covered          4/-
  ios.privacyManifest    notApplicable    -/-
  ios.executables        partial          25/28   ← 上一轮的 P1-1 已修
  ios.macho.strings      covered          64,729,024/—   ← limit 仍缺
  ios.nativeSymbols      covered          25/25
  ios.entitlements       covered          8/—
  ios.signature          notApplicable    -/-
network: domains=0  ips=0        ← iOS 从不产网络事实
```

11 条发现：`IOS-RULE-D-ESCALATED`(p1)、`IOS-PHOTO-LIBRARY`(p3)、`IOS-CAMERA`(p3)、
`IOS-PHOTO-PICKER`(info)、`IOS-NATIVE-SYMBOLS`(p3, 14 符号)、`IOS-URL-SCHEMES`、
`IOS-SCAN-COVERAGE`、4×`IOS-USAGE-DESCRIPTION`。

### 3.3 DEX 取证深度（12 个 DEX 夹具）

```
real-cooccurrence.dex   callSites=8  coOccurrences=1
  Pipeline.run  →  ocr-recognizetext @+0x0 , uploadimage @+0x3
real-separate.dex       callSites=7  coOccurrences=0
  Separate.doOcr  /  Separate.doUpload   （两个方法体，故意不同方法）
```

**「同一方法体内两个调用点」这个最强证据是真的**：`CodeCoOccurrence` 带调用者完整签名与
两个调用指令的字节偏移。这是全仓最强的静态证据，比「字符串里同时出现两个词」强两个数量级。

同时确认结构闸门有效：`bad-magic` / `header-file-size-mismatch` / `method-ids-size-absurd` /
`multiple-anomalies` 四种畸形 DEX 全部 `traversable=false`，方法引用与调用点均为 0，
且会各自产出 `android.dex.structure_anomaly` 限制说明 —— 不会把「读不了」说成「没有」。

### 3.4 门禁（实测）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `flutter test` | 0 | **1,567 通过 / 14 跳过 / 0 失败** |
| `analysis_model` `dart test` | 0 | 58 |
| `apk_parser` `dart test` | 0 | 109 |
| `ipa_parser` `dart test` | 0 | 125 |
| `archive_safety` `dart test` | 0 | 40 |
| `app_icon_extractor` `dart test` | 0 | 25 |
| 6 个 `analyze --fatal-infos --fatal-warnings` | 0 | 全部 No issues found |

---

## 4. 上一轮 10 项建议的复核

| 上一轮条目 | 声明状态 | 本轮复核（证据） | 结论 |
|---|---|---|---|
| P1-1 iOS 可执行文件覆盖分母 | 已修 | `ios.executables → partial 25/28`，`nestedBundleTotal=27` 从 `ipa_analysis.dart:347` 一路传到 `info_page.dart:443`；截断另有一条 `ios.executables.truncated` 限制说明（limitations 6 条） | ✅ **已修** |
| P2-1 `android.arsc` 用真实条目数 | 已修 | 5 个夹具实测 `covered 1/1/1/4/1`；`locales+density` 代理判据已删 | ✅ **已修** |
| P2-2 `V1-ONLY` 与未签名分开 | 已修 | A/B 对上：`signed-v1-only`（v1=true）→ `V1-ONLY-SIGNING`；`signed-unsigned`（v1=false）→ `UNSIGNED`；`signed-v2-v3` 两条都不报 | ✅ **已修**（本轮最高性价比的一条） |
| P2-3 Markdown/JSON 共用序列化 | 未做 | JSON 仍只有 `[platform, appName, packageId, version, buildNumber, permissions]`；`minSdk` / 组件 / ABI / locales / densities / ICP / entitlements / URL scheme 全仓 0 处 | ❌ **仍在**（P2-2） |
| P2-4 报告 4 个英文标签 | 未做 | `analysis_report.dart:357/375/383/387` 仍是字面量 `**Confidence:** / **Evidence:** / **Recommendation:** / **Limitation:**`；`info_page.dart:1035` 仍是 `'${n} finding(s)'` | ❌ **仍在**（P2-4） |
| P2-5 诊断本地化 14/55 | 未做 | `AnalysisDiagnosticText._byKey` 仍只有 14 个 code；`sun_signed.ipa` 实测 **31 条诊断只有 1 条** 能本地化（30 条英文进 zh-CN 界面，其中 `ios.macho.parsed` ×25） | ❌ **仍在且样本上更差**（P2-7） |
| P2-6 权限目录缺 8 类 | 未做 | 仍 24 条；`SYSTEM_ALERT_WINDOW` / `REQUEST_INSTALL_PACKAGES` / `ACCESS_BACKGROUND_LOCATION` / `RECORD_AUDIO` / `READ_SMS` / `READ_CALL_LOG` / `READ_CALENDAR` / `POST_NOTIFICATIONS` 在目录内 0 处 | ❌ **仍在**（P2-5） |
| P2-7 iOS 标记与域名 | 未做 | 仍 17 标记；`NetworkFacts(` 在 `ipa_parser` 0 处构造，实测 `domains=0 ips=0` | ❌ **仍在**（P2-6） |
| P2-8 `hasCoverageGaps` 恒真 | 未做 | `security_finding.dart:541` 未变；两个引擎仍无条件追加限制说明；14/14 样本 `gaps=true` | ❌ **仍在**（P2-3） |
| P3 表 12 条 | 部分 | 见 §5.3 | ⚠️ **部分** |

**净结果：3/10 真修，7/10 未动。** 三条修的都是「诚实性」类，说明优先级判断是对的；
未动的七条里，有三条（P2-3 / P2-5 / P2-7）是「用户能直接看到」的。

---

## 5. 问题清单

### P2-1 `android.nativeHardening` 的分母问的是另一个问题 ✅ 可复现

```dart
// android_security_audit.dart:1344
status: facts.nativeHardening.isEmpty ? notApplicable
        : (facts.nativeHardening.length == nativeLibraryTotal || ... )
            ? covered : partial,
covered: 已加固且 fullRelro+nonExecStack 的库数,   // ← 「加固得好不好」
limit:   facts.nativeHardening.length,            // ← 「我们解析了几个库」
```

面板渲染成 `部分覆盖  原生库加固  8/10`（`CoverageEntry.ratioText` → `coverageEntryLine`）。
真实覆盖率是 `10/266`。**这与上一轮已修的 P1-1（原生符号 24/24）、P2-1（arsc）是同一个 bug 的
第三个实例**，只是这次 `status` 是对的（`partial`），所以危害小一档。

**修法**：`covered/limit` 改成「已解析库数 / 全包唯一库数」（与 `android.nativeSymbols` 一致），
「加固得好不好」改成 note 里的一句话（现在已经有 `some_without_relro` 这个 note，机制是现成的）。
**成本：小（改两行 + 一条 note）。**

---

### P2-2 JSON 仍然只是「安全报告 + 五个身份字段」

实测 `renderJson` 的 `application` 键：

```
[platform, appName, packageId, version, buildNumber, permissions]
```

`minSdk / targetSdk / maxSdk / debuggable / components / nativeCodes / locales / densities /
supportsScreens / archiveType / splitApks / obbFiles / icpFiling / urlSchemes /
backgroundModes / icons / entitlements 清单 / 嵌套 bundle 清单 / Mach-O 架构`
—— **在 `analysis_report.dart` 里 0 处引用**。

上一轮已经指出，本轮**没有任何变化**。同时 Markdown 的 Android 小节也只有
min/target/maxSdk + debuggable + components + permissions + structure + signature，
**ICP 备案号一条都没有**（那是中文用户最常问的字段之一）。

补一句公平的话：`signatureSummary` 这一段**确实变好了**（新增 `signers` 的 subject/sha256/sha1/
算法/位数，iOS 新增证书链的 CN/有效期/序列号/`issuerLooksLikeApple`、`codeResources` 的密封条目数）。
说明「往 JSON 里加东西」这条路是走得通的，缺的是平台事实那一段。

**修法**：给 `PackageAnalysisResult` 写一个唯一的 `toJson`，Markdown 与 JSON 都从它取；
加一条守卫测试遍历每个 `FieldValue` 字段断言出现在 JSON 里。**成本：中。**

---

### P2-3 `hasCoverageGaps` 恒真，而真正有区分力的信号是死代码

```dart
// security_finding.dart:541
bool get hasCoverageGaps =>
    findings.any((f) => f.severity.isInconclusive) || limitations.isNotEmpty;
```

两个引擎都**无条件**追加至少两条方法论说明（`android.offline_static_analysis`、
`android.analysis.based_on_cooccurrence`；iOS 同理），因此 `limitations` 永不为空。
实测 **14/14 样本全为 `true`**，包括「所有维度都 notApplicable 的空包」。

更值得注意的是：**结构化的、有区分力的 `AnalysisCoverage.hasGaps` 在 `lib/` 里 0 处使用**
（只在 `test/analysis_coverage_test.dart` 与包内测试里）。而 JSON 出口写的是：

```dart
'hasGaps': security?.hasCoverageGaps ?? true,   // ← 恒真那个
```

于是同一份 JSON 里 `securitySummary.hasCoverageGaps` 与 `coverage.entries` 推出的真实结论
**在每一个样本上都相反**（本次 14/14：外层 `true`，结构化 `false`）。

**影响**：界面「覆盖局限」卡片永远出现（用户学会忽略它）；JSON 消费者拿不到可判断的缺口信号。

**修法**：拆成 `hasDeclaredLimitations`（恒真的方法论声明）与 `hasActualGaps`
（`coverage.gaps.isNotEmpty || findings.any(unknown)`）；JSON 的 `hasGaps` 用后者，
另加 `hasDeclaredLimitations`。**成本：小，但要同步 3 处消费者（界面卡片、JSON、`security_integration_test`）。**

---

### P2-4 报告与界面的硬编码英文标签（上一轮 P2-4，未动）

```markdown
### ANDROID-RULE-C [p1]

- **发现项:** ...            ← 走了 i18n
- **Confidence:** suspected  ← 字面量英文
- **Evidence:**              ← 字面量英文
- **Recommendation:** ...    ← 字面量英文
- **Limitation:** ...        ← 字面量英文
```

`info_page.dart:1035` 另有一处 `'${findings.length} finding(s)'`。
zh-CN 报告因此一半中文一半英文；en 报告里又只有一个中文标签（「发现项」）。
**成本：极小（4 个键 × 6 个语言包）。**

---

### P2-5 权限目录缺 8 类常见高危权限（上一轮 P2-6，未动）

| 权限 | 在目录 | 全仓其他引用 |
|---|---|---|
| `SYSTEM_ALERT_WINDOW`（悬浮窗） | ✗ | **0** |
| `REQUEST_INSTALL_PACKAGES`（装应用） | ✗ | **0** |
| `ACCESS_BACKGROUND_LOCATION` | ✗ | **0** |
| `RECORD_AUDIO` | ✗ | 只在「权限↔API」表里 |
| `READ_SMS` | ✗ | 同上 |
| `READ_CALL_LOG` / `READ_CALENDAR` / `POST_NOTIFICATIONS` | ✗ | **0** |

它们落进 `ANDROID-PERMISSION-UNCATEGORIZED` 一条 INFO 汇总（正文列名字 + 「请人工查阅文档」），
**没有等级、没有用途说明、没有版本条件**。悬浮窗与「安装其他应用」在国内样本里是最常被滥用的两个。

顺带一个待核项：目录里有 `READ_CLIPBOARD`——`android.permission.READ_CLIPBOARD` 是
**signature 级**权限，普通三方应用声明了也拿不到。建议核对保护级别，避免把它当成可获得的
能力来定级（本轮未做外部核验，标注为待查）。

**成本：小（纯数据），但要升 `rulesVersion`。**

---

### P2-6 iOS 的能力广度仍是 Android 的一半，且答不了「数据发到哪」

**标记**：17 vs 36。以下 API 全仓 0 处：

| 能力 | 应有标记 | 现状 |
|---|---|---|
| 广告追踪授权 | `ATTrackingManager` | 无 |
| 广告标识符 | `ASIdentifierManager` | 无 |
| 蓝牙 | `CBCentralManager` | 无 |
| 运动与健身 | `CMMotionManager` | 无 |
| 健康数据 | `HKHealthStore` | 无 |
| 日历/提醒 | `EKEventStore` | 无 |
| 语音识别 | `SFSpeechRecognizer` | 无 |

**网络**：`IosPrivacyAudit` 全文 0 处构造 `NetworkFacts`，实测 `domains=0 / ips=0`。
所以 iOS 报告里的「网络」一节**永远空白**，而 README「数据回传分析：识别网络库、上传接口与域名 / IP」
在 iOS 上只做到前两项。

`AsciiStrings` 与 Android 的 TLD 规则是现成的（`analysis_model` 零依赖），复用到 iOS 只是接线。
**成本：标记 4 条 = 小；域名提取 = 中。**

---

### P2-7 发现的四段文案：7 个 code 产出了但没注册，zh-CN 下静默回退英文 ✅ 已在真实样本上复现

用 zh-CN 渲染 `sun_signed.ipa` 的每条发现，逐段判是否含 CJK：

```
IOS-PHOTO-LIBRARY     finding=中文 recommendation=中文 limitation=中文
IOS-RULE-D-ESCALATED  finding=中文 recommendation=中文 limitation=中文
IOS-NATIVE-SYMBOLS    finding=中文 recommendation=英文 limitation=英文(251 字符) relationship=英文
```

原因：引擎产出的这 7 个 code **在对应 switch 里没有分支**（`=> null` → 回退英文原句）：

| code | 产出点 | 落空处 |
|---|---|---|
| `ios.native_symbols.relationship` | `ios_native_symbol_audit.dart:299` | `relationshipText` |
| `ios.native_symbols.limitation` | 同上 :305 | `limitationText` |
| `ios.native_symbols.manual_review` | 同上 :310 | `recommendationText` |
| `android.native_symbols.relationship/limitation/manual_review` | `android_security_audit.dart:810/816/821` | 同上 |
| `android.screen_capture.limitation` | 同上 :860 | `limitationText` |

这是「**漏注册 = 编译通过、静默回退英文**」那条铁律的第六次实例，而且这次落在**唯一真实 iOS 样本
必然出现**的发现项上（14 个原生符号）。

**为什么测试没拦住**：`i18n_coverage_test` 校验的是「语言包键集 ↔ 语言包键集」，
没有任何测试校验「引擎产出的 code ⊆ 呈现层的 switch 分支」。

**修法**：① 补 7 个分支（文案键大部分已存在，见 `t.security.native_symbols`）；
② 加一条**结构守卫**：扫描 `packages/*/lib` 里 `messageCode|recommendationCode|limitationCode|
relationshipCode` 的字面量集合，断言每个都在 `AnalysisReport` 的四个 switch 里出现。
**成本：小，收益最大的一条（一次拦住整类问题）。**

---

### P2-8 安卓签名块读不出时，零发现、零覆盖、零诊断

```dart
// apk_reader.dart:255
meta.signingSchemes = _readSigningSchemes();
if (meta.signingSchemes != null && !meta.signingSchemes!.parsed) {
  _log.warning('signing block: ${meta.signingSchemes!.failure}');   // ← 全仓唯一消费者
}
```

`ApkSigningSchemes.parsed == false` 时：
- `v1Only = parsed && schemeNames.isEmpty` → `false` → `V1-ONLY` 不报；
- `ANDROID-UNSIGNED` 要求 `hasV1Signature == false && v1Only` → 也不报；
- Android 的 11 个覆盖维度里**没有「签名材料」这一维**；
- 不产 `AnalysisDiagnostic`、不产 `AnalysisNote`。

于是「签名块结构被破坏」（这恰恰是重打包/篡改的典型痕迹）在报告里**完全不可见**，
只剩一行日志。而签名验证走 `apksigner` 时若工具不可用，结论是 `toolUnavailable` ——
两个「我们没看到」叠在一起，用户只会看到「签名：无法确认」。

**修法**：`parsed == false` 时产出一条 `AnalysisNote('android.signing_block.unreadable')`
并新增覆盖维度 `android.signature`（`notCovered` / `partial`）。**成本：小。**

---

### P2-9 iOS 隐私清单里的「必需理由 API」读不出来

`NSPrivacyAccessedAPITypes` 全仓 **0 处**（`NSPrivacyTracking` / `NSPrivacyTrackingDomains` /
`NSPrivacyCollectedDataTypes` 都有）。iOS 17+ 上架要求逐条声明使用 `NSPrivacyAccessedAPITypes`
里 API 的**理由**（UserDefaults / 文件时间戳 / 磁盘空间 / 系统启动时间等）。

于是「隐私清单审计」缺了最容易被 App Store 退回的那一节，而 `IOS-PRIVACY-INFO` 的正文
照旧说「声明已列出」——**读者会以为列全了**。

**修法**：解析该数组（`NSPrivacyAccessedAPIType` + `NSPrivacyAccessedAPITypeReasons`），
在 `IOS-PRIVACY-INFO` 的证据里列出；没声明时给一条 info。**成本：小～中。**

---

### P2-10 未声明 `usesCleartextTraffic` 被当成「不允许」，且覆盖标 `covered`

```dart
// android_security_rules.dart:183
return meta.applicationUsesCleartextTraffic ?? false;   // 注释说「不主张允许」
// 同一方法的文档第 3 条却写着：未声明时为 `null`
```

两处不一致（文档说 `null`、代码给 `false`）。后果有两层：

1. **假阴性**：`targetSdk < 28` 的应用，平台默认**允许**明文；不声明就是允许。
   判成 `false` → `ANDROID-RULE-D` 静默不报。
2. **覆盖不诚实**：`android.cleartextPolicy` 的 `status` 只看 `cleartextPolicy == null`，
   而这条分支永不为 `null` → 13/13 夹具都是 `covered 1/1`，**包括根本没声明该属性的**
   `manifest-extra-fixture`（targetSdk 34）。

**修法**：`cleartextPolicy` 按 `targetSdk` 分档：未声明时 `targetSdk >= 28 → false`、
`< 28 → true`、`targetSdk == null → null`；同步改文档第 3 条。**成本：小。**

---

### P2-11 13 个 APK 夹具全部 0 DEX / 0 `.so`，最有价值的规则没有端到端回归

探针实测：13/13 `dex=0 natives=0`。因此「ZIP → `ApkReader` → 提取 DEX / 选 `.so` → 审计」
这条**接线**在真实归档上从未被测过；组合规则 A/B/C/E/G 只靠手工构造的 `AndroidRuleFacts`
驱动（`android_security_rules_test.dart` 的两张表）。

这不是「测试少」，而是**测试的形态**漏了一层：引擎函数有覆盖，装配有覆盖，中间那层没有。
一旦 `parse_task.dart` 里少传一个参数（这类事本项目已踩过五次），单测全绿、真实包结论错。

**修法**：造**一个**带 2 个 `classes.dex`（复用 `real-cooccurrence.dex` / `real-separate.dex`）
和 2 个 `.so`（复用 `arm64-v8a-libnative.so` / `hardening-execstack.so`）的最小 APK，
断言端到端出现 `RULE-C`、`NATIVE-SYMBOLS`、`NATIVE-EXEC-STACK`。**成本：中（一次性夹具）。**

---

### P3（低危，逐条给证据）

| # | 问题 | 证据 | 建议 |
|---|---|---|---|
| P3-1 | `ios.macho.strings` 有 `covered` 无 `limit` | 实测 `64,729,024 / —`（`ios_privacy_audit.dart:1383`） | 加 `limit`（各可执行文件扫描预算之和） |
| P3-2 | `ios.entitlements` 有 `covered` 无 `limit` | 实测 `8 / —` | 同 P3-1 或改文案为「8 项」 |
| P3-3 | iOS `RULE-F` 证据为空 | `ios_privacy_audit.dart:1257` `evidence: const []` | 补 1 条「扫描了哪些文件/字节」的证据 |
| P3-4 | iOS `RULE-F` 的 limitation 文案已过时 | 文案说「Frameworks 不在覆盖内」，5b 起已扫 25 个镜像 | 改写为「已扫 N 个可执行文件，M 个未覆盖」 |
| P3-5 | 界面安全总览卡不显示覆盖状态 | `info_page.dart:984` 签名有 `hasCoverageGaps`、函数体 0 处引用；卡片只有数量与严重度芯片 | 用 `AnalysisCoverage.hasGaps` 加一行状态 |
| P3-6 | `ios.privacyManifest` 缺失记 `notApplicable` | 状态与 `ios.privacy_manifest.absent` 的「无法核对」措辞冲突 | iOS 17+ 目标算 `partial`；或文案改成「本次不作为缺口」 |
| P3-7 | 差异对比缺「安全发现」维度 | `package_diff_adapter.dart` 已比 permissions/components/ABI/locales/densities/原生符号/域名/签名结论/debuggable —— **比上一轮记录的更全**，但仍不比 `allowBackup` / 明文策略 / SDK 清单 / entitlements | 补 4 个集合维度 |
| P3-8 | README 测试数过期 | README:211「1,549 根 + 357 包」，实测 **1,567 + 357** | 改成实测值 |
| P3-9 | `cleartextPolicy` 的注释说 NSC「还没展开」 | 实际 `resolvedAllowsCleartext` 已实现 | 同步注释 |
| P3-10 | `ANDROID-UNSIGNED` 只有 INFO | 未签名包无法安装，是强信号 | 可考虑 P3，但会打中所有 `aapt2 link` 产物 —— 维持 INFO 也合理 |
| P3-11 | `RULE-C` 命中即 P1 | 只要求「图 + OCR + 上传」能力同现，未要求同方法体 | 同方法体 → P1、整包层面 → P2（已有 `coOccurrenceNote` 两档措辞，等级没跟着分） |

---

## 6. 真实边界（设计约束，不是缺陷）

| 做不到 | 后果 | 是否说清 |
|---|---|---|
| 数据流分析（寄存器/参数） | 只能说「两个调用点在同一方法体内」 | 是（`relationship` + `limitation`） |
| 跨方法调用链 | 共现止于方法体粒度 | 是 |
| 反射 / 动态加载 / JNI | `DexClassLoader` 之后不可见，进覆盖不足 | 是 |
| 加固/脱壳 | 只报结构线索 | 是（`hardeningHints`） |
| iOS 字节码 | 只有字符串 + 符号，无方法级分析 | 是（`ios.macho.strings`） |
| 运行时行为 | 不装、不跑、不抓包 | 是（`includesRuntimeEvidence=false` 恒假） |
| 厂商归因 | 明确不判断 | 是 |
| `Assets.car` 多平面变体 | 模式 0x02/0x03 不解 | 是（按失败码分类，不报数据损坏） |

这一节仍是加分项：八条里有七条在数据模型里有对应字段，不是 README 的口头承诺。

---

## 7. 建议优先级

| 序 | 事项 | 对应 | 类型 | 成本 |
|---|---|---|---|---:|
| 1 | 补 7 个未注册 code + 「code ⊆ switch」结构守卫 | P2-7 | 一致性 | 小 |
| 2 | `hasCoverageGaps` 拆成「声明」与「实际缺口」，JSON 两个都出 | P2-3 | 诚实性 | 小 |
| 3 | `android.nativeHardening` 分母改「已解析/全包唯一库」 | P2-1 | 诚实性 | 小 |
| 4 | 签名块读不出 → 诊断 + 覆盖维度 | P2-8 | 诚实性 | 小 |
| 5 | `cleartextPolicy` 按 targetSdk 分档 | P2-10 | 正确性 | 小 |
| 6 | 报告 4 个英文标签 + `N findings` 进 i18n | P2-4 | 观感 | 极小 |
| 7 | 权限目录补 4 条（悬浮窗/装应用/后台定位/录音） | P2-5 | 能力 | 小 |
| 8 | iOS 补 4 个标记（IDFA/ATT/蓝牙/运动）+ 域名提取 | P2-6 | 能力 | 中 |
| 9 | 带 DEX 与 `.so` 的最小 APK 夹具 | P2-11 | 回归保障 | 中 |
| 10 | `PackageAnalysisResult` 唯一 `toJson` + 字段守卫 | P2-2 | 交付完整性 | 中 |
| 11 | `NSPrivacyAccessedAPITypes` 解析 | P2-9 | 合规能力 | 小～中 |
| 12 | P3 表 11 条按需清理 | — | 一致性 | 小 |

**不建议现在做的**：数据流分析、动态沙箱、加固脱壳（前两项规格明确不做，第三项是另一套工程）；
`Assets.car` 模式 0x02/0x03 硬解（已用四种探测证明不可行）。

---

## 8. 复现方式

三支探针（审计后已删）各自的核心调用：

```dart
// Android：复刻 parse_task.dart
final reader = ApkReader(); await reader.open(path);
final meta = await reader.parse();
final dex = [for (final n in reader.listFiles(extension: '.dex'))
               if (reader.readFile(n) case final b?) DexBytes(n, b)];
final cand = reader.listFilesWithSize(extension: '.so');
final sel  = NativeSymbolScanner.selectLibraries(cand);
AndroidSecurityAudit.audit(
  meta: meta, dexEntries: dex, nativeEntries: natives,
  nativeLibraryTotal: NativeSymbolScanner.uniqueLibraryCount(cand),
  nativeSkipped: sel.skipped,
  arscEntryCount: reader.arscParser == null ? null : arsc.length,
);

// iOS：参数与 info_page.dart:429 完全一致
IosPrivacyAudit.audit(infoPlist: ..., executableBytes: ..., executablePath: ...,
  entitlements: ..., provisioningProfilePresent: ...,
  nestedBundleTotal: parsed.nestedBundleTotal, nestedExecutables: [...]);

// 文案落地：zh-CN 下逐条判 CJK
bool hasCjk(String s) => RegExp(r'[\u4e00-\u9fff]').hasMatch(s);
hasCjk(AnalysisReport.limitationText(f, t) ?? '')
```

**关键证据的取法**

| 结论 | 一行验证 |
|---|---|
| P2-1 | `coverage.entries.firstWhere((e) => e.id == 'android.nativeHardening')` 看 `covered/limit` 与 `status` 的语义是否同一问句 |
| P2-3 | 打印 `security.hasCoverageGaps` 与 `security.coverage.hasGaps`，14 个样本上都相反 |
| P2-7 | zh-CN 下对 `IOS-NATIVE-SYMBOLS` 调 `limitationText`，含 CJK = false |
| P2-8 | 构造一个签名块长度字段被改坏的 APK，`findings` 与 `coverage` 都不含任何签名相关条目 |
| P2-11 | 对 13 个夹具打印 `dex.length` / `natives.length`，全为 0 |

---

## 9. 一句话总结

上一轮把「分母」这件事修对了三处，剩下的同一类问题只剩一处，可以很快补齐；
真正拖分的是**输出层**（JSON 缺平台事实、诊断 30/31 英文、7 个 code 静默回退英文）
和 **iOS 的能力广度**（17 个标记、没有网络端点、没有必需理由 API）。
引擎本身——四级证据链、四态覆盖、边界诚实——已经比多数同类工具扎实得多；
现在的瓶颈不是「能不能查到」，而是「查到之后能不能完整、一致、以用户语言交出去」。

---

## 10. 修复记录（2026-10-19，审计后同轮完成）

§0–§9 保持**审计当时**的原样（含 77 分与各项问题描述），便于日后对照「当时的判断」
与「后来的处理」。本轮把 §7 的 12 条建议全部处理完，逐条附**修复前后的实测数字**。

### 10.1 P2-7：7 个 code 未注册 + 结构守卫

| 文件 | 变更 |
|---|---|
| `lib/utils/analysis_report.dart` | 四个 switch 补 7 个分支：`ios/android.native_symbols.{relationship,limitation,manual_review}` + `android.screen_capture.limitation` |
| `test/security_finding_code_registration_test.dart` | **新增**：扫 `packages/*/lib` 里四个 code 字段的值表达式，断言每个 code 都在**对应**的 switch 里有分支 |

守卫本身也验证过：临时删掉 `ios.native_symbols.limitation` 那一行，测试立刻报
`limitationCode: ios.native_symbols.limitation（应在 limitationText 里）`。

**修复前**（zh-CN，`sun_signed.ipa`）：`IOS-NATIVE-SYMBOLS` 的 recommendation / limitation
（251 字符）是英文。
**修复后**：四段全部中文。

守卫的边界写在测试注释里：它看得见四个字段的字面量（含三元分支），
**看不见**助手函数间接返回的 code（如 `_exportedMessageCode`）。

### 10.2 P2-3：`hasCoverageGaps` 拆成两个信号

| 文件 | 变更 |
|---|---|
| `analysis_model/security_finding.dart` | `hasCoverageGaps` → `hasDeclaredLimitations` + `hasActualGaps` + `coverageGapCount` |
| `analysis_report.dart` | Markdown 局限节改用 `hasDeclaredLimitations`（照实列出）；JSON `securitySummary` 输出 `hasActualGaps` / `hasDeclaredLimitations` / `coverageGapCount`；`coverage.hasGaps` 改用 `hasActualGaps` |
| `info_page.dart` | 总览卡接上真实缺口数（原来那个参数是死参数），局限卡片改用「声明」判断 |

**修复前**：14/14 样本 `hasCoverageGaps=true`；JSON 里外层 `hasGaps` 与结构化覆盖**在每个样本上都相反**。
**修复后**（`sun_signed.ipa`）：`hasActualGaps=true, gapCount=1`（只有 `ios.executables` 25/28 是缺口），
`hasDeclaredLimitations=true`。全绿的包现在会显示「没有缺口」。

`reportSchemaVersion` 5 → **7**（破坏性改名 + 新增 `platformFacts`）。

### 10.3 P2-1：`android.nativeHardening` 的分母

`covered/limit` 改成「已解析库数 / 全包唯一库数」，与 `status` 回答同一个问题；
加固质量（缺 RELRO）留在 note 里。

**修复前**：2 个库、1 个缺 RELRO → `covered=1, limit=2`（读起来像「覆盖一半」）。
**修复后**：`covered=2, limit=2`，note 仍是 `some_without_relro`。
**守卫**：`native_hardening_rule_test.dart` 的用例改成断言「覆盖数不受加固质量影响」。

### 10.4 P2-8：签名块读不出 → 诊断 + 覆盖维度

| 文件 | 变更 |
|---|---|
| `android_security_audit.dart` | 新增覆盖维度 `android.signature`（`notCovered` / `partial` / `covered` 三态）；`parsed == false` 时追加 `android.signing_block.unreadable` 限制说明 |
| 文案 | `coverage.notes.android_signature_*` ×3、`security.limitation_notes.android_signing_block_unreadable` |

**新增测试** `test/android_signature_and_cleartext_test.dart`：解析失败 → `notCovered` + 说明 +
限制说明，且两条签名规则都不报；可读 + v1 已判定 → `covered 1/1`；v1 未判定 → `partial`。

### 10.5 P2-10：`cleartextPolicy` 按 targetSdk 分档

未声明 `usesCleartextTraffic` 时取平台默认值：`targetSdk >= 28` → `false`、`< 28` → `true`、
`targetSdk` 未知 → `null`（`partial` + 新说明 `android_cleartext_policy_target_sdk_unknown`）。
文档第 3 条同步改掉（原文写「未声明时为 null」，与代码矛盾）。

**新增测试**：`targetSdk 26` 未声明 → 规则 D **必须报**（修复前漏报）；`targetSdk 34` 未声明 → 不报且覆盖 `covered`。

### 10.6 P2-4：报告标签本地化

`Confidence` / `Evidence` / `Recommendation` / `Limitation` 四个标签与 `N finding(s)`
进 6 个语言包（`report.label_*`、`report.findings_count`）。为避免英文单复数问题，
计数用名词短语「Findings: N」而不是「N findings」。

### 10.7 P2-5：权限目录 24 → 28

新增 `SYSTEM_ALERT_WINDOW`(P3) / `REQUEST_INSTALL_PACKAGES`(P2) /
`ACCESS_BACKGROUND_LOCATION`(P3, minApi 29) / `RECORD_AUDIO`(P3)，
`rulesVersion` → `android-permissions-2026.10.2`。
目录自带的守卫测试（每条规则在四个语言包里都有说明与风险说明）自动覆盖了新条目。

### 10.8 P2-6：iOS 标记 17 → 21，并产出网络端点

| 变更 | 说明 |
|---|---|
| 新增标记 | `ATTrackingManager` / `ASIdentifierManager` / `CBCentralManager` / `CMMotionManager` |
| 规则 G 扩展 | 蓝牙 / 运动 / 广告标识符也进「敏感来源 + 上传」的判据；稀有来源（通讯录/麦克风/蓝牙/追踪）→ P2 |
| 网络端点 | 新增 `analysis_model/network_endpoints.dart`，Android 与 iOS **共用**一份提取；`IosPrivacyAudit` 现在填 `NetworkFacts` |

**实测**（`sun_signed.ipa`）：`domains=50`（修复前 `0`），例如
`api-adservices.apple.com`、`api2.deepinstall.com`。

下沉到共享实现时暴露出一个**新问题**：Mach-O 里塞着大量 Web 资源，`something://` 后面
跟的常常不是主机名 —— 不校验时会产出 `.css` / `In` / `UA-Compatible` / `according` 这类垃圾。
因此加了主机名校验（至少两段、每段合法、TLD 在表内），并把 URL 里的 IP 归到 `ips`。
`test/network_endpoints_test.dart` 钉住了这两条。

### 10.9 P2-11：带 DEX 与 `.so` 的端到端用例

`test/android_security_e2e_test.dart`：用 `ZipEncoder` 现造 APK（清单与资源表复用
`signed-v2-v3.apk` 的真实条目，DEX 用 `real-cooccurrence` / `real-netprobe`，
`.so` 用 `libnative` / `hardening-execstack`），走 `ApkReader.open → parse → 选库 → audit`。

**断言**：`dex.structure` / `dex.strings` / `dex.methodReferences` / `nativeSymbols`（2/2）/
`nativeHardening`（2/2）全部 `covered`；出现 `ANDROID-OCR-CAPABILITY` / `ANDROID-UPLOAD-API` /
`ANDROID-NATIVE-SYMBOLS` / `ANDROID-NATIVE-EXEC-STACK`；上传证据落到 `code.call_site`
（带方法签名与指令偏移）；有上传能力时不再输出 `RULE-F`。

这是仓库里**第一条**真正跑通「ZIP 里取出 DEX 与 `.so`」的用例。

### 10.10 P2-2：JSON 的 `platformFacts`

`PackageAnalysisResult.toJson()` 输出平台事实，每个 `FieldValue` 就地带
`{value, status, source}`：

- Android：min/target/maxSdk、debuggable、permissions、archiveType、supportsScreens、
  densities、nativeCodes、locales、splitApks、obbFiles、**icpFiling**、components、structure、hardeningHints；
- iOS：bundle id / 名称 / 版本 / 最低系统、deviceFamily、queriesSchemes、urlSchemes、
  backgroundModes、executableName、architectures、container（含 bundle 清单）、
  nestedBinaries、icon、signatureMaterials、authorization、codeSignStatus、unavailableReason。

`renderJson` 在非 `securityOnly` 下输出该段。`test/analysis_report_platform_facts_test.dart`
钉住字段存在、`absent` 不被写成 0、以及「仅安全范围不输出平台事实」。

### 10.11 P2-9：必需理由 API

`IosPrivacyInfo.accessedApiTypes`（`NSPrivacyAccessedAPIType` + 理由码），
在 `IOS-PRIVACY-INFO` 的证据里列出。

顺带修掉一个连带 bug：`IosPrivacyInfo.isEmpty` 此前只看 tracking / trackingDomains /
collectedDataTypes，于是**只声明必需理由 API 的清单**（很常见的形态）会被判成 `absent`，
报告说「没有隐私清单」。

### 10.12 P3 表

| # | 处理 |
|---|---|
| P3-1 | `ios.macho.strings` 加 `limit`（参与扫描的文件总字节）。实测 `64,729,024 / 64,729,024` |
| P3-2 | **不改**：entitlements 是条目数，凑一个 `limit` 只会制造假比例；语义已在注释里写清 |
| P3-3 | iOS `RULE-F` 补证据（扫描范围 + 字节数），不再 `const []` |
| P3-4 | iOS `RULE-F` 的 limitation 文案改写：5b 起嵌套可执行文件**已**在覆盖内，旧文案说反了 |
| P3-5 | 总览卡接上覆盖状态（`hasActualGaps` + 缺口数），死参数消除 |
| P3-6 | **不改状态**（缺隐私清单在 iOS 17 前确实不是缺口），但说明补上「本次不计为覆盖缺口」 |
| P3-7 | 差异新增 4 个集合维度：`android.allowBackup` / `android.cleartextPolicy` / `android.thirdPartySdk` / `ios.entitlements`（前三条从发现项推导，标签里写明「按…推导」） |
| P3-8 | README 测试数与规则数改成实测值 |
| P3-9 | `cleartextPolicy` 的过时注释已随 P2-10 改掉 |
| P3-10 | **不改**：`ANDROID-UNSIGNED` 维持 INFO，理由见原条目（会打中所有 `aapt2 link` 产物） |
| P3-11 | `ANDROID-RULE-C` 按共现粒度分级：同方法体 P1 / 整包层面 P2 |

### 10.13 门禁（实测）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `flutter test` | 0 | **1,588 通过 / 14 跳过**（审计时 1,567） |
| `analysis_model` `dart test` | 0 | 65（原 58） |
| `apk_parser` `dart test` | 0 | 109 |
| `ipa_parser` `dart test` | 0 | 125 |
| `archive_safety` `dart test` | 0 | 40 |
| `app_icon_extractor` `dart test` | 0 | 25 |
| 6 个 `analyze --fatal-infos --fatal-warnings` | 0 | 全部 No issues found |
| `dart format --set-exit-if-changed` | 0 | 0 changed |

合计 **1,952** 条测试（审计时 1,924）。

### 10.14 未做的事

- **数据流 / 跨方法**：规格明确不做，本轮也没碰。
- **iOS 字节码级分析**：需要另一套 Mach-O 反汇编，不在本轮范围。
- **`Assets.car` 模式 0x02/0x03**：已用四种探测证明不可行。
- **加固脱壳**：另一套工程。

§6 的八条设计边界**一条都没变** —— 本轮改的是「分母、可见性与交付」，
没有把静态分析包装成动态分析。

---

## 11. 能力增强记录（2026-10-19，第二批）

§7 的 12 条修完之后，按「深度优先」又做了三项。§10 修的是**诚实性与交付**，
这一批动的是**证据强度**本身。

### 11.1 iOS 节级扫描 → 主动请求权限

**先纠正一个我在提案里的判断错误**：原计划是「按 `__objc_classname` 读类名表，
消掉『字符串里提到』的误报」。查了 Mach-O 布局后确认这条路走不通 ——
`__objc_classname` 只放**本二进制定义**的类，框架类（`PHPhotoLibrary` 等）不会
出现在那里，它们只在 `__objc_classrefs` 的指针里，要解析绑定信息才能拿到。

真正能用的是 **`__objc_methname`（选择子表）**：那里是二进制真正引用过的方法名，
包括 `requestTrackingAuthorizationWithCompletionHandler:` 这种。于是改成：

| 变更 | 位置 |
|---|---|
| `MachOSection` + 节表解析（`segment_command.sections[]`，32/64 位各一套偏移，逐条按 `cmdsize` 与文件长度双重限界） | `macho.dart` |
| `MachOFile.sectionBytes(file, segment:, section:)`：自动加切片偏移，越界返回 `null` | `macho.dart` |
| 9 个「请求权限」选择子（相册 / ATT / 摄像头麦克风 / 通讯录 / 前台定位 / 始终定位 / 麦克风 / 通知 / 健康） | `ios_privacy_audit.dart` |
| 新发现项 `IOS-PERMISSION-REQUEST`（info，`independentCapability`），证据定位到 `__TEXT,__objc_methname` | 同上 |
| 选择子表读不到时追加限制说明（`ios.permission_request.no_methname`） | 同上 |

**实测 `sun_signed.ipa`**：`__TEXT` 有 24 个节，`__objc_methname` 122,848 字节、
5,286 个选择子；命中 3 个权限请求 —— `PHPhotoLibrary`、`ATTrackingManager`、
`AVCaptureDevice`。

这是 iOS 侧第一条**不靠字符串扫描**的结论：它回答的是「代码会去申请什么」，
而用途说明只回答「应用被允许申请什么」。

**踩到的坑**：选择子带冒号，第一版用 `contains(selector)` 精确比对，7 个全部
没命中；改成前缀匹配后命中 3 个。这类「名字里带参数」的字符串，匹配方式必须
先看真实数据。

### 11.2 跨方法调用链（1–2 跳）

`DexMethodScanner` 在遍历 `invoke-*` 时顺手记两条边，**只围绕带标记的方法**，
因此规模与命中数同阶，不随 1586 万个调用点膨胀：

- `callersOfMarkerMethods`：被调用方带标记 → 记下调用方；
- `edgesFromMarkerCallers`：调用方已带标记 → 记下它调用了谁（走第二步用）。

`firstChainBetween()` 先找 1 跳（A 直接调 B），再找 2 跳（A → X → B），
`maxHops` 可关掉第二段。`coOccurrenceNote` 因此从两档变三档：

| 证据 | 关系说明 code | 等级 |
|---|---|---|
| 同一方法体 | `android.rule_c.relationship_method` | P1 |
| 调用链 1 跳 | `android.rule_c.relationship_chain` | P1 |
| 调用链 2 跳 | 同上（`hops=2`） | P2 |
| 整包层面 | `android.rule_c.relationship_package` | P2 |

`dataTransform` 在调用链情形下给的是**链路**（`A → X → B`），不是猜一个方法名。

**已知局限（写在代码注释与关系说明里）**：`edgesFromMarkerCallers` 只在该调用方
**已经被确认带标记之后**才记录，同一个方法体里标记出现之前的调用点会漏掉。
这是为了不把 1586 万个调用点全部拼成字符串的代价；要补全需要第二遍遍历，
实测成本约 +3.2 秒（343 MB 样本），本轮没做。

### 11.3 权限保护级别 + 授权项分级

**Android**：`PermissionRule` 增加 `protection`（normal / dangerous / special /
signature）。`READ_CLIPBOARD` 标为 signature —— 三方应用**拿不到**，按 P3 报是
假阳性。现在它单独成一条 `ANDROID-PERMISSION-NOT-GRANTABLE`（info），措辞改成
「声明了但系统不会授予，出现它通常说明代码来自系统应用或混淆产物」。

**iOS**：只补 4 个**稀有**能力授权项（network extension / HealthKit / HomeKit /
family controls），P3，一条 `IOS-ENTITLEMENT-CAPABILITY`。

**没有**收 `keychain-access-groups` / `application-groups` /
`associated-domains` —— 代码里原本就写明「刻意不收」，理由是几乎每个带登录或
分享的应用都有，报了只会让读者学会忽略整个面板。这一批沿用同一条判据，
没有为了「看起来更全」而推翻它。

### 11.4 门禁（实测）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `flutter test` | 0 | **1,595 通过 / 14 跳过**（上一批 1,588） |
| `analysis_model` / `apk_parser` / `ipa_parser` / `archive_safety` / `app_icon_extractor` | 0 | 65 / **115** / 125 / 40 / 25 |
| 6 个 `analyze --fatal-infos --fatal-warnings` | 0 | 全部 No issues found |
| `dart format --set-exit-if-changed` | 0 | 0 changed |

合计 **1,965** 条（上一批 1,952）。新增测试 3 个文件：
`ios_sections_and_permission_requests_test.dart`、`call_chain_test.dart`，
以及扩写的两个既有文件。

---

## 12. 能力增强记录（2026-10-19，第三批）

两项：**ATS 例外逐域**（把已经解析但没人用的数据接上）与**调用链补全**
（修掉上一批自己留下的两个缺陷）。

### 12.1 ATS 例外域名：从「只有域名」到「逐域标志」

`atsExceptionDomains` 此前是 `FieldValue<List<String>>`，而且**全仓 0 个消费者** ——
解析出来就一直躺着，报告和界面都看不到。

现在改成 `atsExceptions: FieldValue<List<IosAtsException>>`，每个域名带
`NSExceptionAllowsInsecureHTTPLoads` / `NSExceptionMinimumTLSVersion` /
`NSExceptionRequiresForwardSecrecy` / `NSExceptionIncludesSubdomains`。

关键判据是 `weakensTransport`：**只声明域名、不写任何标志时不算放宽** ——
那只是沿用默认策略。因此新发现项 `IOS-ATS-EXCEPTION` 的等级是分档的：

| 情况 | 等级 |
|---|---|
| 有域名允许明文 / 降到 TLS 1.0-1.1 / 关掉前向保密 | P3 |
| 只声明域名或只写 TLSv1.2 | info |

证据逐域给出具体标志（`old-tls.example.com: NSExceptionMinimumTLSVersion=TLSv1.0`），
不是一句「有例外域名」。

### 12.2 调用链：修掉上一批的两个缺陷

上一批（§11.2）交付的调用链有两个问题，这一批都修了：

**缺陷 1：拿 `coOccurrences` 当「带某标记的方法」的索引。**
`coOccurrences` 只收「同一个方法体里命中 **2 个以上**标记」的方法。只调用了一次
OCR 的方法根本不在里面 —— 而它恰恰是最常见的起点。结果就是 1 跳链路几乎永远
找不到。改成新增 `markersByCaller`（调用方 → 命中的标记 id）并用它建索引。

**缺陷 2：出边记录时机。**
原来在 `onCallSite` 里当场判断「这个调用方带不带标记」，而标记是遍历过程中
才陆续发现的 —— 标记**之前**的调用点会被漏掉，2 跳链路因此常断。改成
**按方法体积攒出边，方法体结束时（调用方变化 / DEX 边界）再判断**。
代价是每个方法体一个复用的 `Set`，不随 1586 万个调用点增长。

两个缺陷都由新加的用例钉住：
`只调用一个 OCR 方法的方法也是有效起点（不能依赖 coOccurrences）`。

**仍然做不到的**：跨 3 跳以上、以及经反射 / 动态代理的调用。这些不是「没优化」，
是「不做」—— 再远的调用关系在任何正常应用里都能凑出来。

### 12.3 门禁（实测）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `flutter test` | 0 | **1,598 通过 / 14 跳过**（上一批 1,595） |
| `analysis_model` / `apk_parser` / `ipa_parser` / `archive_safety` / `app_icon_extractor` | 0 | 65 / **116** / 125 / 40 / 25 |
| 6 个 `analyze --fatal-infos --fatal-warnings` | 0 | 全部 No issues found |
| `dart format --set-exit-if-changed` | 0 | 0 changed |

合计 **1,969** 条（上一批 1,965）。

---

## 13. 能力增强记录（2026-10-19，第四批）

两项：**ContentProvider 专项**与 **WebView 配置组合**。都来自「规则表里的明显空白」。

### 13.1 ContentProvider 从「导出组件」里拆出来

此前 provider 混在 `ANDROID-EXPORTED-COMPONENT` 的汇总里。真实样本上那个列表
能有 **159 个**组件（抖音），provider 虽然按类型排在最前，但读者看到的是
一长串类名 —— 看不出**暴露的是哪个 authority**，也看不出 `grantUriPermissions`
和 `readPermission` / `writePermission` 的状态，而这三件事恰恰决定数据能不能被拿走。

| 变更 | 位置 |
|---|---|
| 解析 `android:readPermission` / `android:writePermission` / `android:grantUriPermissions` | `manifest_parser.dart` + `AndroidComponent` |
| provider 从 `_unprotectedExported` 排除，新增 `_unprotectedProviders` | `android_security_rules.dart` |
| 新规则 `ANDROID-PROVIDER-EXPOSED`（P2），正文点名 authority，证据逐条给出 `permission` / `readPermission` / `writePermission` / `grantUriPermissions` / `guard` / `protectionLevel` | 同上 |

判据上的两个细节：

- **`readPermission` + `writePermission` 都声明才算关上两个方向**。只声明一个时
  记为 `partialPermission`，正文补一句「另一个方向仍然敞开」—— 此前只读
  `android:permission`，会把这种半开的 provider 误判成受保护。
- 弱权限（本包声明的 normal/dangerous 级）仍按「名存实亡」处理，并在证据里
  带上 `protectionLevel=normal`，不让读者自己去查。

**行为变更**：同一条 provider 不再同时出现在「导出组件」汇总里。四条既有测试
（`manifest_extra_fixture_test` / `manifest_attr_resolution_test` /
`android_manifest_hygiene_test`）已同步到新归属，规则表的顺序守卫与逐条驱动表
也补了新规则。

### 13.2 WebView：补一个开关，并按组合分级

| 变更 | 说明 |
|---|---|
| 新标记 `webview-file-url-access` | `setAllowFileAccessFromFileURLs` —— 与 `setAllowUniversalAccessFromFileURLs` 是**不同**的开关（前者允许 file:// 页面互读本地文件），漏掉会少算一半组合 |
| 分级 | 单有 JS 桥仍 P3（第三方 SDK 普遍如此，见原注释的样本表）；桥 + 任一 file:// 跨域开关 → **P2**，换 `android.webview_bridge_unsafe` 措辞，置信度 `suspected` |
| 证据 | 开关本身进证据（此前只在正文里提一句） |
| 顺带修一个本地化 bug | 开关列表此前是**英文句子直接拼进 `finding`**，中文界面上会出现「Also observed: JavaScript enabled」。改成传稳定 id（`js-enabled` / `universal-file-access` / `file-url-access`），由呈现层按语言组装 |

新增测试 `test/android_provider_and_webview_test.dart`（9 条），覆盖：
无权限 / 读写都声明 / 只声明一个 / `grantUriPermissions` / `exported=false`，
以及单桥 P3、两种组合 P2、中文界面不夹英文。

### 13.3 门禁（实测）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `flutter test` | 0 | **1,607 通过 / 14 跳过**（上一批 1,598） |
| `analysis_model` / `apk_parser` / `ipa_parser` / `archive_safety` / `app_icon_extractor` | 0 | 65 / **117** / 125 / 40 / 25 |
| 6 个 `analyze --fatal-infos --fatal-warnings` | 0 | 全部 No issues found |
| `dart format --set-exit-if-changed` | 0 | 0 changed |

合计 **1,979** 条（上一批 1,969）。

---

## 14. 能力增强记录（2026-10-19，第五批）

三项，都是「数据已经解析出来了，但报告里看不到」的那一类。

### 14.1 链接入口（`ANDROID-DEEPLINK`）

`IntentFilterInfo.schemes` 早就解析了，但只用来判断「组件是否导出」，**从没列出过
scheme 本身**。而「这个应用能被哪些链接唤起」是用户最常问的问题之一。

新规则 `ANDROID-DEEPLINK`（info）：

- 只收**导出**组件上的 scheme；启动页的 `MAIN`/`LAUNCHER` 排除 —— 它不是链接入口，
  算进来会让每个应用都多一条无意义记录；
- 正文给 scheme 清单与涉及的组件数，证据逐组件给 `schemes=` 与 `actions=`；
- 等级 info：一个 scheme 本身不是风险（登录回调、分享回跳都靠它），
  真正的风险（导出且无权限）仍由 `ANDROID-EXPORTED-COMPONENT` 负责。

**没有**给 `IntentFilterInfo` 加 host / path：模型里原本写着「边际价值低、
会显著膨胀模型」，这一批沿用该判断 —— scheme 才是「能不能被唤起」的关键。

### 14.2 证书固定（`ANDROID-CERT-PINNING`）

`network_security_config.dart` 的文件头明确写着「不判定 `<trust-anchors>` /
`<pin-set>` / `<certificates>`」，于是 `pin-set` 被整段跳过 ——
**「有没有做证书固定」完全不可见**，而它是传输安全评估的常规一项。

这一批补成**事实记录，判定边界不变**：

| 变更 | 说明 |
|---|---|
| `NscPinSet` 模型 | 域名、pin 条数、摘要算法、`expiration` 原文 |
| 解析 | `<pin-set>` 在 `base-config` 与 `domain-config` 下都收；`domain-config` 下的会展开到它的每个 `<domain>` |
| 新发现项 | 有 pin-set 才报（info）；**不做「未配置」的告警** —— 那会让每个应用都多一条 |
| 限制说明 | 明确写清：pin 是否与服务端证书匹配、过期时间是否已过，静态分析都判断不了 |

### 14.3 SDK 版本（`pom.properties`）

DEX 里只有类名，**没有版本**。用 Maven 构建的 SDK 常把
`META-INF/maven/**/pom.properties` 打进包里，那是唯一可靠的静态版本来源。

- `ApkReader.parse()` 读这份文件（有界读取 + 200 条上限），填进 `ApkMeta.mavenArtifacts`；
- `SdkInventoryScanner.scan` 按 **groupId 双向前缀**把版本挂到命中的 SDK 上
  （`com/adjust/sdk` ↔ `com.adjust.sdk`）；
- 发现项的正文与证据变成 `Adjust 4.33.0` —— 「哪个版本」往往比「有没有」更有用，
  已知漏洞是按版本判定的。

`SdkHit.version` 为 `null` 的含义写进了注释：**没有坐标文件**，不是「没有版本」。

### 14.4 顺带的分层调整

`parseNetworkSecurityConfig(bytes)` 拆成两层：字节 → 文档（`BinaryXmlDecompressor`）
与文档 → 事实（`parseNetworkSecurityConfigDocument`）。后者让测试可以直接构造
包内的 XML 模型来验证 `pin-set`，不必手拼二进制 AXML。

### 14.5 门禁（实测）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `flutter test` | 0 | **1,614 通过 / 14 跳过**（上一批 1,607） |
| `analysis_model` / `apk_parser` / `ipa_parser` / `archive_safety` / `app_icon_extractor` | 0 | 65 / **118** / 125 / 40 / 25 |
| 6 个 `analyze --fatal-infos --fatal-warnings` | 0 | 全部 No issues found |
| `dart format --set-exit-if-changed` | 0 | 0 changed |

合计 **1,987** 条（上一批 1,979）。

---

## 15. 能力增强记录（2026-10-19，第六批）

用户要求做三件「超出原设计边界」的事。**两件做了、一件没做**，逐条交代。

### 15.1 iOS 字节码级分析 → 做的是**结构化引用表**，不是反汇编

先纠正预期：完整 ARM64 反汇编器是几千行的工程（指令解码表、控制流恢复），
本轮没有做，也不建议在没有验证手段的情况下做 —— 解错一条指令，产出的
「调用点偏移」看起来完全正常，实际是垃圾。

**真正做成的**是 iOS 一直缺的那一级证据：`__objc_classrefs` / `__objc_selrefs`。

| 变更 | 说明 |
|---|---|
| `MachOSection` / `MachOSegment.vmAddress` | 段要带虚拟地址，否则链式修复解出的目标无法映射回文件偏移 |
| `LC_DYLD_CHAINED_FIXUPS` 解析 | 读 `dyld_chained_fixups_header` → `starts_in_image` → `dyld_chained_starts_in_segment.pointer_format` |
| 指针解码 | `PTR_64`（2）与 `PTR_64_OFFSET`（6）：rebase 取 36 位 target；bind 槽位走 `imports` 表取符号名（`_OBJC_CLASS_$_PHPhotoLibrary` → `PHPhotoLibrary`） |
| 新发现项 `IOS-REFERENCE-TABLES` | info，报解出多少个类 / 选择子引用，以及跳过了多少槽位 |

**实测 `sun_signed.ipa`**：3,094 个选择子引用、102 个类引用、3,196 个指针解出，
313 个跳过。`PHPhotoLibrary` / `ATTrackingManager` / `AVCaptureDevice` 都在
**类引用表**里 —— 这三个此前只能靠「整文件搜到这个词」判定。

**不做的部分**：ARM64E（PAC 认证）的指针格式不解，返回 `unsupported` 并写进
限制说明。理由同上：解错会产出看起来像真的垃圾，比不解析更糟。

顺带把「类表命中」接进了线索证据：`detail` 里会标 `(class table)`，
读者能区分「代码引用了这个类」与「这个词在包里出现过」。

### 15.2 跨 3 跳以上调用链 → 做了，带明确代价与上限

| 变更 | 说明 |
|---|---|
| `DexCallSite.callerMethodIndex` | 调用点带上调用者的 `method_idx`，调用图才能用**整数**建边 |
| `_buildCallGraph` | 第二遍遍历字节码，建 `Map<int, List<int>>`；500k 条边、每节点 64 条出边的上限 |
| `firstChainBetween` | 有完整图时走**逐层 BFS**（1–4 跳，保证最短）；没有时退回原来的 1–2 跳启发式 |
| RULE-C 局限文案 | 找到链路后不再写「不是调用图分析」—— 那正是它；改为「方法级最短路径，参数未跟踪」 |

**代价是显式的**：建图要多遍历一遍字节码（343 MB 样本约 +3.2 秒），所以只在
**OCR 与上传两组标记都命中**时才建图；其余包零额外成本。图被截断时
`deepGraphTruncated` 为 true，局限文案会换成「可能存在更长、未被找到的路径」。

**等级不变**：0–1 跳 P1，2 跳及以上 P2。跳数越多越像巧合，这一点没有为了
「支持更多跳」而放宽。

### 15.3 加固脱壳 → **没有做**，做的是识别 + 边界

脱壳需要在 ART 里把应用跑起来、在 `DexClassLoader` 加载后 dump 内存里的 DEX，
那是**动态分析**，与本项目「静态、不解包执行」的边界直接冲突。静态侧能做的
只有识别：

- 新增 `packer_catalog.dart`：10 家商业壳的原生库名特征（360 / 乐固 / 梆梆 /
  爱加密 / 阿里 / 网易 / 百度 / 顶象 / 几维 / 娜迦）；
- 新发现项 `ANDROID-PACKER`（info）：报出壳名与命中的库文件；
- **限制说明写死**：`does not unpack`，并且「没认出来的壳」只会表现为
  「没有检测到壳」，不会误报。

这一条的价值在于**解释力**：加固包上那些「没扫到 DEX 内容」的维度，
从此有了一句明确的归因，而不是让读者以为应用真的没有这些能力。

### 15.4 门禁（实测）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `flutter test` | 0 | **1,618 通过 / 14 跳过**（上一批 1,614） |
| `analysis_model` / `apk_parser` / `ipa_parser` / `archive_safety` / `app_icon_extractor` | 0 | 65 / **122** / 125 / 40 / 25 |
| 6 个 `analyze --fatal-infos --fatal-warnings` | 0 | 全部 No issues found |
| `dart format --set-exit-if-changed` | 0 | 0 changed |

合计 **1,995** 条（上一批 1,987）。
