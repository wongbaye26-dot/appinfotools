# AppInfoTool 分析模块能力审计（全链路）

> 审计对象：**2.4.16**（`e8abc7b`，tag `v2.4.16`）
> 审计日期：2026-10-19
> 性质：**只读审计**。除一次性探针（审计后已删除）外不修改任何生产代码。
> 审计范围：解析层（`apk_parser` / `ipa_parser` / `analysis_model` / `archive_safety`）
> → 安全引擎 → 覆盖模型 → 报告与 JSON 导出 → 版本差异 → 界面呈现。
>
> **与 2026-10-18 那份安全能力审计的关系**：那份只审「安全引擎本身」，且分数是
> 实现方滚动累加的自评（§9–§22，65 → 95）。本份是**全链路独立复核**，口径不同、
> 权重不同，**两者分数不可直接比较**。上一轮的具体结论在本轮逐条复核，结果见 §6。

---

## 0. 结论与评分

**一句话：解析与取证这一层是扎实的；问题不在「能不能查到」，而在「查到的比例算得对不对」
与「结果能不能完整、一致地交付给用户」。**

三个最值得先修的：

1. **iOS 的可执行文件覆盖率会虚报全绿** —— `sun_signed.ipa` 有 28 个 bundle，只解析了 24 个，
   覆盖表仍写 `ios.executables 25/25 covered`（P1-1）。
2. **资源表覆盖用「语言数 + 密度数」当代理** —— 只要包里有 `resources.arsc` 但没多语言/多密度，
   就报「资源表缺失或无法解析」。本轮跑的 7 个 APK 夹具**全部**命中（P2-1）。
3. **`ANDROID-V1-ONLY-SIGNING` 分不清「只有 v1 签名」与「完全没签名」** ——
   项目自带的 `signed-v1-only.apk` 与 `signed-unsigned.apk` 产出**完全相同**的发现项（P2-2）。

综合评分 **76 / 100**。

| 维度 | 权重 | 得分 | 依据 |
|---|---:|---:|---|
| 解析广度与正确性 | 25 | **21** | 4 个包 12.7k+10k 行、边界校验完整；扣分见 P2-1、P2-2、P3-9 |
| 安全检测广度 | 20 | **15** | Android 18 规则 / 24 权限 / 36 标记 / 25 SDK；iOS 25 规则但仅 17 标记（P2-6、P2-7） |
| 检测深度（能证到哪一步） | 15 | **9** | 最强证据仍是「同一方法体内两个调用点」；无数据流、iOS 无字节码（§5，设计约束） |
| 覆盖诚实度 | 15 | **11** | 模型很好（19 维度 × 4 态 × 稳定 code），但两处分母错 + 一个恒真信号（P1-1、P2-1、P2-8） |
| 报告与呈现 | 10 | **7** | 导出缺字段、中文报告混英文、界面与报告不同步（P2-3～P2-5） |
| 工程健壮性 | 10 | **9** | 1,537 + 327 测试全绿、`analyze` 零问题、有界读取；扣分见 P3-9 |
| 文档准确性 | 5 | **4** | README 与实现基本一致，两处口径错（P3-10、P3-11） |

---

## 1. 审计口径（怎么测的）

| 手段 | 做法 | 用在 |
|---|---|---|
| 静态盘点 | 数 `ruleId` / `CodeMarker` / `PermissionRule` / `SdkDescriptor` / `CoverageEntry` / LOC | §2 |
| **生产路径探针** | 复刻 `parse_task.dart` 的调用序列（`ApkReader.open` → `parse` → DEX/原生库 → `scanHardeningSignals` → `AndroidSecurityAudit.audit`），不是直接调规则函数 | §3、§4 |
| 真实样本 | 7 个 APK 夹具（含 `signed-v1-only` / `signed-unsigned` 对照组）+ `sun_signed.ipa`（40 MB） | §3、§4 |
| i18n 键比对 | 把引擎里 298 个 `android.*` / `ios.*` 字符串 code 与 4 个完整语言包的叶子键逐条比对 | P2-4、P2-5 |
| 报告实测 | 用 zh-CN 渲染 Markdown 与 JSON，直接看输出里有什么、缺什么 | P2-3、P2-4 |
| 门禁实测 | `flutter test`、四个包 `dart test`、`flutter analyze --fatal-infos --fatal-warnings` | §3.3 |

探针只打印结果、不做断言 —— 审计要的是「实际产出了什么」，不是「我认为应该产出什么」。
探针在审计结束后删除，仓库保持干净（`git status` 仅剩自忽略的 `.codegraph/`）。

---

## 2. 模块地图与能力盘点

### 2.1 分层

```
                    ┌──────────────────────────────────────────────┐
  UI / 报告 / 差异   │ info_page · overview · analysis_report(2063) │
                    │ diff_page · package_diff_adapter · widgets   │
                    └───────────────▲──────────────────────────────┘
                                    │ PackageAnalysisResult（跨平台）
                    ┌───────────────┴──────────────────────────────┐
                    │ analysis_builder（逐字段合并 + 来源能力表）   │
                    └───────▲───────────────────────▲──────────────┘
                            │                       │
        ┌───────────────────┴──────┐   ┌────────────┴─────────────────┐
        │ apk_parser 12,782 行      │   │ ipa_parser 9,980 行          │
        │ AXML/ARSC/DEX/ELF/ZIP     │   │ plist/Mach-O/codesign/Assets │
        │ SecurityAudit 1,529 行    │   │ PrivacyAudit 1,579 行        │
        └───────────────┬───────────┘   └────────────┬─────────────────┘
                        └──────────┬─────────────────┘
                    ┌──────────────▼──────────────────────────────┐
                    │ analysis_model 1,604 行（零依赖）            │
                    │ FieldValue · SecurityFinding · Coverage      │
                    └──────────────▲──────────────────────────────┘
                    ┌──────────────┴──────────────────────────────┐
                    │ archive_safety 904 行（有界读取 / ZIP 预算） │
                    └─────────────────────────────────────────────┘
```

### 2.2 能力数字（静态盘点，逐项可复现）

| 项 | Android | iOS | 备注 |
|---|---:|---:|---|
| 规则编号（去重） | **28** | **26** | Android = 规则表 17 + `RULE-D-ESCALATED` + 4 条权限状态 + 6 条单点；iOS 含 1 条 `IOS-SCAN-COVERAGE`（覆盖陈述，不是风险规则） |
| 权限目录 / 标记 | 24 / **36** | — / **17** | Android 另有 10 条「权限必须有对应 API」的编目 |
| 原生符号标记 | 26（两侧共享） | 26 | 精确符号名，只匹配 UND |
| 服务类 SDK 前缀 | 25 | — | 统计/推送/验证码/登录/地图/崩溃/RTC |
| 覆盖维度 | **11** | **8** | 19 个稳定 id，全部有本地化名字 |
| 结果级限制说明 code | 59 条（`security.limitation_notes`） | 同左 | 全部有语言包键 |
| 测试 | 包内 104 | 包内 125 | 根 `test/` 另有 1,210 条；`analysis_model` 58、`archive_safety` 40 |

**Android 覆盖维度**：manifest / permissions / dex.structure / dex.strings /
dex.methodReferences / dex.callSites / nativeSymbols / nativeHardening / sdkInventory /
arsc / cleartextPolicy。

**iOS 覆盖维度**：infoPlist / usageDescriptions / privacyManifest / executables /
macho.strings / nativeSymbols / entitlements / signature。

### 2.3 数据流的三段设计（这是本项目最强的一处）

`SecurityFinding` 把 `dataSource` / `dataTransform` / `dataSink` 分开，其中
`dataTransform` 是**机器可读定位**（方法完整签名），`relationship` 是给人读的说明，
`limitation` 明写哪一段没证实。这个结构不是装饰：它使「同现」与「数据流」在类型层面
就无法混淆。本轮复核未发现任何一条发现项把 `suspected` 写成 `confirmed`。

---

## 3. 实测结果（生产路径）

### 3.1 Android 夹具（7 个）

| 夹具 | 权限/组件 | 发现项 | 关键覆盖状态 |
|---|---|---|---|
| `signed-v2-v3.apk` | 0 / 4 导出 4 | 4 | arsc `notCovered`（实际已解析，1 个资源） |
| `signed-v1-only.apk` | 0 / 4 导出 4 | **5**（含 `V1-ONLY-SIGNING`） | 同上 |
| `signed-unsigned.apk` | 0 / 4 导出 4 | **5**（含 `V1-ONLY-SIGNING`） | 同上 |
| `nsc-fixture.apk` | 0 / 1 导出 1 | 4（`RULE-D` P2） | NSC 已展开；arsc 误报 |
| `manifest-extra-fixture.apk` | 0 / 4 导出 4 | 5 | arsc 误报 |
| `attr-fixture.apk` | 1 / 3 导出 2，`debuggable=true` | 6（`DEBUGGABLE` P1） | arsc 误报 |
| `night-mode-resources.apk` | 0 / 0 | 2 | arsc 误报 |

**`signed-v1-only` 与 `signed-unsigned` 的输出逐行相同** —— 这是 P2-2 的决定性证据。

### 3.2 `sun_signed.ipa`（40.5 MB 真实包）

```
bundles=28  nested=24  executable=35,953,728 B  arch=[arm64]
analyze=407 ms（测试环境 JIT）
findings=11  limitations=5  diagnostics=31
coverage: ios.executables 25/25 covered
          ios.macho.strings 64,729,024 /（无 limit）
          ios.nativeSymbols 25/25
          ios.entitlements 8 /（无 limit）
```

11 条发现里含 `IOS-RULE-D-ESCALATED`（P1）、`IOS-PHOTO-LIBRARY`、`IOS-CAMERA`、
`IOS-NATIVE-SYMBOLS`（14 个符号）等；31 条诊断里 **25 条是 `ios.macho.parsed`**。

### 3.3 门禁（审计时实测，非引用 README）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `flutter test` | 0 | **1,537 通过 / 14 跳过 / 0 失败** |
| `packages/analysis_model` `dart test` | 0 | 58 |
| `packages/apk_parser` `dart test` | 0 | 104 |
| `packages/ipa_parser` `dart test` | 0 | 125 |
| `packages/archive_safety` `dart test` | 0 | 40 |
| `flutter analyze --fatal-infos --fatal-warnings` | 0 | No issues found |

合计 **1,864** 条测试（根 1,537 + 包 327）。

---

## 4. 问题清单

### P1-1 iOS 可执行文件覆盖分母 = 「传进来几个」，截断后仍报全绿 ✅ 可复现

**证据**（`sun_signed.ipa` 实测）：

```
container.bundles = 28
IpaAnalysisReader.maxNestedBinaries = 24   → nestedBinaries = 24
diagnostics 含 ios.nested.truncated（"only the first 24 of N nested bundles were parsed"）
coverage  ios.executables = covered 25 / limit 25
```

`targets` 由「主可执行文件 + 调用方传进来的 nestedExecutables」拼成
（`ios_privacy_audit.dart:329`），而调用方在 `ipa_analysis.dart:372` 就已经截断到 24。
于是「本次实际比对了几个」被当成了「包里一共有几个」。

**影响**：与上一轮修掉的 Android 原生库问题（266 个库只扫 24 个却写 24/24）**是同一个 bug**。
用户看到「可执行文件 25/25 已覆盖」，实际有 3 个 bundle 的代码从未被扫描；
而这条截断只出现在「解析诊断」里，覆盖面板与 Markdown 报告都读不到。

**建议**：`IpaAnalysis.analyze` 返回 `nestedBundleTotal`（或把 `truncated` 计数带出来），
审计用它做 `limit`；截断时 `status = partial`，并把 `ios.nested.truncated` 同时写进
`limitations`（现在只在 diagnostics）。**成本：小（两处传参）。**

---

### P2-1 `android.arsc` 的覆盖量是代理指标，会把「已解析」报成「缺失」 ✅ 可复现

**证据**：

```dart
final arscEntryCount = meta.locales.length + meta.densities.length;  // :641
...
status: arscEntryCount == 0 ? notCovered : covered
note:   'Resource table missing or unparsable'
```

探针在 `night-mode-resources.apk` 上实测：

```
arscParsed=true  resourceCount=4  locales=[]  densities=[]
C android.arsc  notCovered  0/-  note=android.arsc.missing
```

包里有 1,048 字节的 `resources.arsc`、解析器读出了 4 个资源，报告却说「资源表缺失或无法解析」。

**影响**：这是**假缺口**。它与本项目反复强调的「不能把能力边界说成数据缺陷」是同一类错误
（参见 2.4.13 审计 §21.1：把判据错误报成数据损坏）。覆盖率是给用户判断「这份结论有多可信」用的，
虚报缺口会让用户怀疑本来正确的部分。

**建议**：把真实的资源条目数传进 `audit`（`parse_task` 已经有 `arscResources`，
`_auditExtractedBaseApk` 也有 `reader.arscParser`），`arscEntryCount` 改成
「实际读到的资源数」；读不到时才 `notCovered`。**成本：小（加一个参数）。**

---

### P2-2 `ANDROID-V1-ONLY-SIGNING` 分不清「v1 签名」与「没签名」 ✅ 项目自带 A/B 夹具

**证据**：判据只有一句 `signingSchemes.v1Only`，而 `v1Only = parsed && schemeNames.isEmpty`
（`apk_signing_block.dart:103`）—— 即「没有 v2+ 签名块」，**完全不看 `META-INF/*.SF`**。

| 夹具 | 有 `META-INF/`？ | 产出的发现 |
|---|---|---|
| `signed-v1-only.apk` | 有（K.SF / K.RSA） | `ANDROID-V1-ONLY-SIGNING` p3 |
| `signed-unsigned.apk` | **无** | `ANDROID-V1-ONLY-SIGNING` p3（完全相同） |
| `nsc-fixture` / `attr-fixture` / `manifest-extra` / `night-mode` | **无** | 同样命中 |

规则摘要写的是「只有 v1（JAR）签名，没有 v2+ 签名块」，正文虽然加了一句
「only the v1 (JAR) signature, **if any**」，但**结论行与规则名仍是断言**。

**影响**：未签名包（`aapt2 link` 产物、内部调试包）会被报「只有 v1 签名」。
这与「v1-only 是重打包友好信号」的分析前提直接冲突 —— 一个根本没签名的包被当成
「用最弱方案签过名的包」。上一轮 §15.1 已经意识到「没有签名块无法区分 v1 与未签名」，
但当时只守住了 `parsed == false`，没处理 `parsed == true` 的这一半。

**建议**：`ApkMeta` 增加 `hasV1Signature`（归档里存在 `META-INF/*.SF` + `*.RSA/DSA/EC`，
`parse_task` 用一个 `listFiles` 就能判断）；判据改成
`v1Only && hasV1Signature`，无 v1 时改用 `ANDROID-UNSIGNED`（info，或干脆不报）。
**成本：小。** 这是本轮**性价比最高**的一条修复。

---

### P2-3 导出报告的覆盖面明显小于界面（Markdown 缺 11 组字段，JSON 只有 5 个身份字段）

**证据 1 — Markdown**：`analysis_report.dart` 里对这些字段的引用数为 **0**：

| 平台 | 界面能显示、Markdown 报告里没有 |
|---|---|
| Android | `nativeCodes`(ABI) / `densities` / `locales` / `supportsScreens` / `archiveType` / `splitApks` / `obbFiles` / **`icpFiling`(ICP 备案号)** |
| iOS | `urlSchemes` / `backgroundModes` / `icons` |

**证据 2 — JSON**（实测 `renderJson` 的键）：

```
顶层: reportSchemaVersion, reportId, generatedAt, inputArtifact, fieldStatus,
      application, signatureSummary, securitySummary, network,
      splitConsistency, findings, coverage, diagnostics, engineVersions,
      rulesVersions, limitations
application: [platform, appName, packageId, version, buildNumber, permissions]
```

Android 的 min/target/maxSdk、组件（含 `exported`/`permission`）、ABI、locales、densities、
容器结构、ICP；iOS 的 bundle 清单、Mach-O 架构、图标解析、entitlements、授权比对、
`PrivacyInfo` 字段 —— **全部不在 JSON 里**。

**影响**：JSON 目前实际上是「安全报告 + 五个身份字段」，不是「分析结果」。
README 把 Markdown / JSON 并列为报告出口，但两者信息量差一个量级；
依赖 JSON 做二次分析的用户拿不到平台事实。

**建议**：给 `PackageAnalysisResult` 写一个**唯一**的序列化（`toJson`），Markdown 与 JSON
都从这里取；并加一条守卫测试：遍历 `PackageAnalysisResult` 的每个 `FieldValue` 字段，
断言它出现在 JSON 里。**成本：中（一次性对齐，之后靠测试守住）。**

---

### P2-4 中文报告里混着硬编码英文标签

**证据**（zh-CN 实测输出；发现项正文是英文，是因为探针构造那条 finding 时没给
`messageCode`，这里要看的是**标签**）：

```markdown
### ANDROID-RULE-C [p1]

- **发现项:** OCR and upload clues co-occur.
- **Confidence:** suspected
- **Evidence:**
  - dexString (classes.dex): okhttp
- **Recommendation:** Review manually.
```

「发现项」走了 `t.security.findings`，紧邻的三行却是字面量英文（`analysis_report.dart:357/375/383`）。
同一份结果在界面里是有本地化标签的（`t.security.confidence_suspected` 等）。

另有两处同类：

- 详情页安全总览卡把 `'N findings'` 写死英文（`info_page.dart:1031`）；
- `_row` 的状态/来源列输出 `extracted` / `builtinParser` 这类机器拼写（`analysis_report.dart:1726`）。
  这一条是**有意的**（`FieldValueText` 文档里写明「状态名保留机器拼写」），但与全中文报告并置时
  仍需要一次解释；若坚持，建议在报告表头加一句「状态为机器标识」。

**影响**：中文用户的导出报告一半中文一半英文；英文用户看到的「**发现项:**」又是中文。
这是「文案要么全走 i18n、要么全不走」的破例。

**建议**：把 `Confidence` / `Evidence` / `Recommendation` / `N findings` 四个标签补进语言包；
**成本：极小。** 状态/来源的机器拼写保持现状并在表头解释。

---

### P2-5 解析诊断的本地化只覆盖 14 / 55，真实 IPA 有 25 条英文诊断进中文界面

**证据**：

- `AnalysisDiagnosticText._byKey` 只映射 **14** 个 code（`analysis_diagnostic_text.dart:60`），
  而 `packages/` 与 `lib/` 的生产代码共产出 **55** 个不同 code。
- `sun_signed.ipa` 实测 31 条诊断：`ios.info_plist.parsed` 1 条有键，
  其余 `ios.macho.parsed` × 25、`ios.provision.parsed`、`ios.icons.*`、`ios.nested.truncated` 等**全无键**。
- 这些诊断经 `AnalysisBuilder.buildIos(diagnostics: ios.allDiagnostics)` 进入界面「解析诊断」卡片
  与 Markdown 报告，渲染结果是英文原句，例如
  `thin Mach-O (64-bit, ARM64), 1 image parsed`。

**影响**：中文界面里一次真实 IPA 解析会显示 20+ 行英文。它们不是错误信息，而是常规解析记录 ——
用户会以为是程序没翻译完（事实如此）。

**建议**：优先补 4 类高频 code（`ios.macho.parsed` / `ios.provision.parsed` /
`ios.icons.*` / `ios.nested.truncated`），其余保持英文回退；并在 `i18n_coverage_test` 里
加断言：`macho.parsed` 这类**每次解析都会产出**的 code 必须有键。**成本：小。**

---

### P2-6 权限目录缺 8 类常见高危权限

**证据**：`permission_catalog.dart` 共 24 条，以下权限在 `packages/` 与 `lib/` 里的引用为：

| 权限 | 在权限目录？ | 其他引用 |
|---|---|---|
| `RECORD_AUDIO` | ✗ | 只出现在「权限↔API 交叉核对」表 |
| `READ_SMS` | ✗ | 同上 |
| `SYSTEM_ALERT_WINDOW`（悬浮窗） | ✗ | **全仓 0 处** |
| `REQUEST_INSTALL_PACKAGES`（安装应用） | ✗ | **全仓 0 处** |
| `ACCESS_BACKGROUND_LOCATION`（后台定位） | ✗ | **全仓 0 处** |
| `READ_CALL_LOG`（通话记录） | ✗ | **全仓 0 处** |
| `READ_CALENDAR`（日历） | ✗ | **全仓 0 处** |
| `POST_NOTIFICATIONS` | ✗ | **全仓 0 处** |

它们会落进 `ANDROID-PERMISSION-UNCATEGORIZED` 那一条 INFO 汇总（正文列名字 + 「请人工查阅文档」），
没有等级、没有用途说明、没有版本条件。

**影响**：悬浮窗与「安装其他应用」在国内应用里是最常被滥用的两个权限，目前与「读取传感器」同级 ——
都只是汇总桶里的一个名字。短信/录音虽然有组合规则 G 覆盖「来源 + 上传」，
但单独声明时没有条目。

**建议**：按「来源稀有度」补 4 条即可获得大部分收益：
`SYSTEM_ALERT_WINDOW`(P3)、`REQUEST_INSTALL_PACKAGES`(P2)、`ACCESS_BACKGROUND_LOCATION`(P3)、
`RECORD_AUDIO`(P3)。**成本：小（纯数据），但要同步升 `rulesVersion`。**

---

### P2-7 iOS 侧标记只有 17 个，且从不提取网络端点

**证据 1 — 标记**：Android 36 个，iOS 17 个。以下 API 全仓 0 处：

| 能力 | 应有标记 | 现状 |
|---|---|---|
| 健康数据 | `HKHealthStore` | 无 |
| 运动与健身 | `CMMotionManager` | 无 |
| 蓝牙 | `CBCentralManager` | 无 |
| 日历/提醒 | `EKEventStore` | 无 |
| 语音识别 | `SFSpeechRecognizer` | 无 |
| 广告追踪授权 | `ATTrackingManager` | 无 |
| 广告标识符 | `ASIdentifierManager` | 无 |

**证据 2 — 网络**：`IosPrivacyAudit` 从不构造 `NetworkFacts`（全文 `network:` 0 处），
所以 iOS 的 `security.network.domains/ips` **恒为空**，报告的「网络」一节在 iOS 上永远不出现。

**影响**：README「数据回传分析：识别网络库、上传接口与域名 / IP」在 iOS 上只做到前两项。
「这个 App 把数据发到哪」——用户最想知道的问题——iOS 侧答不了。
IDFA / ATT 缺失尤其明显：这是 iOS 隐私审计的标准项。

**建议**：先补 4 个标记（`ASIdentifierManager`、`ATTrackingManager`、`CMMotionManager`、
`CBCentralManager`）；域名提取可复用 `AsciiStrings` + 与 Android 相同的 TLD 规则，
把结果填进 `NetworkFacts`。**成本：中。**

---

### P2-8 `hasCoverageGaps` 恒为真，这个信号已经失去区分能力

**证据**：两个引擎都**无条件**追加说明：

```dart
limitations.add(AnalysisNote('android.offline_static_analysis', ...));
limitations.add(AnalysisNote('android.analysis.based_on_cooccurrence', ...));
// iOS: limitations.add(AnalysisNote('ios.offline_static_analysis', ...));
```

而 `hasCoverageGaps => findings.any(isInconclusive) || limitations.isNotEmpty`。
实测 8 个样本（7 个 APK + 1 个 IPA，含所有维度都 `notApplicable` 的包）全部 `gaps=true`。

**影响**：界面「覆盖不足」卡片与 JSON 的 `hasGaps` 永远为真 ——
一个恒真的警告等于没有警告。它与结构化的 `AnalysisCoverage.hasGaps`（有区分力）同名不同义，
消费方很容易混用。

**建议**：拆成两个语义：`hasDeclaredLimitations`（恒真的方法论声明）与
`hasActualGaps`（`coverage.gaps.isNotEmpty || findings.any(unknown)`）；
UI 与 JSON 用后者。**成本：小，但要同步改 3 处消费者。**

---

### P3（低危，逐条给出证据，不展开）

| # | 问题 | 证据 | 影响 / 建议 |
|---|---|---|---|
| P3-1 | `ios.macho.strings` 有 `covered` 无 `limit` | 实测 `64,729,024 / —`；`dex.strings` 已有 limit | 比例不可见。上一轮把 P3-3 记为「已修」，实际只修了 Android 与 `nativeSymbols` |
| P3-2 | `android.nativeHardening` 一格两个分母 | `status` 比「解析数 vs 全包唯一库数」，`covered/limit` 是「已加固数 / 解析数」 | 266 库只解析 10 个时，状态 `partial` 但比例显示 `10/10` |
| P3-3 | iOS `RULE-F` 证据为空 | `ios_privacy_audit.dart:1211` `evidence: const []` | 违反模型「evidence 不能为空」的约定；Android 侧已修，iOS 没跟上 |
| P3-4 | 关闭签名检查时 iOS 显示「无法确认」 | `verdictFromIos(null) => inconclusive`，Android `verdictFrom(null) => notChecked` | 同一设置在两个平台语义不同 |
| P3-5 | 安全总览卡的 `hasCoverageGaps` 参数从未使用 | `info_page.dart:978` 签名有、函数体 0 处引用 | 死参数；卡片不显示覆盖状态；`count==0 → 绿色` 分支在当前引擎下不可达（两个引擎至少产 1 条 INFO），但一旦规则变化就会把 11% 覆盖显示成绿色 |
| P3-6 | `ios.privacyManifest` 缺失标 `notApplicable`，说明却说「无法核对」 | 覆盖率代码 vs `ios.privacy_info.absent` 文案 | 状态与说明矛盾；iOS 17+ 目标应用应算缺口 |
| P3-7 | 未声明 `usesCleartextTraffic` 被当成 `false` | `android_security_rules.dart:183` | targetSdk < 28 的平台默认是允许 → 假阴性；且覆盖仍标 `covered` |
| P3-8 | 差异对比缺安全维度 | `package_diff_adapter.dart` 只比身份字段 + 权限/组件/ABI/locales/densities/原生符号/域名 | 安全发现、SDK 清单、`allowBackup`、明文策略、entitlements 的版本变化看不到 |
| P3-9 | 签名块解析失败只进日志 | `apk_reader.dart:255` `_log.warning` | 没有诊断、没有覆盖维度 → 「没读到」不可见 |
| P3-10 | README 测试数口径错 | README:186「1,537 个测试（根 + 四个包）」，实测根 1,537 + 包 327 = **1,864** | 少报 327 |
| P3-11 | 标记表注释漂移 | `code_markers.dart` 写「23 个标记」，实际 36 | 性能注释里的「16/23」也随之失效 |
| P3-12 | `NSPrivacyAccessedAPITypes` 未核对 | 全仓 0 处 | 隐私清单的「必需理由 API」声明拿不出来 |

---

## 5. 能力的真实边界（设计约束，不是缺陷）

| 做不到 | 后果 | 是否说清 |
|---|---|---|
| 数据流分析（寄存器/参数） | 只能说「两个调用点在同一方法体」 | 是（`relationship` + `limitation`） |
| 跨方法调用链 | 同现只在方法体粒度 | 是 |
| 反射 / 动态加载 / JNI | `DexClassLoader` 之后的代码不可见，只进「覆盖不足」 | 是 |
| 加固/脱壳 | 只报结构线索，看不到真实代码 | 是（`hardeningHints` + 覆盖说明） |
| iOS 字节码 | 没有方法级分析，只有字符串 + 符号 | 是（`ios.macho.strings` 维度） |
| 运行时行为 | 不装、不跑、不抓包 | 是（`includesRuntimeEvidence=false` + 每次的说明） |
| 厂商归因 | 明确不判断「是哪家加固」 | 是 |
| `Assets.car` 多平面变体 | 模式 0x02/0x03 不解，出图率约 50% | 是（按失败码分类，不报「数据损坏」） |

**这一节本身是加分项**：八条边界里有七条在数据模型或文案里有对应字段，
不是靠 README 口头承诺。

---

## 6. 与 2026-10-18 安全能力审计的对照

### 6.1 上一轮的结论：逐条复核

| 上一轮条目 | 当时结论 | 本轮复核 |
|---|---|---|
| P1-1 原生库覆盖 24/24 | 已修 | ✅ 已修（`nativeLibraryTotal` + `nativeSkipped` 都有消费者） |
| P1-2 `dex.strings` 无 limit | 已修 | ✅ 已修（实测 `50,648,616 / 458,461,352` 口径存在） |
| P2-1 iOS 主二进制 16 MiB 截断 | 已修 | ✅ 已修（64 MiB，`ios.macho.strings` 无截断） |
| P2-2 规则集中在图片链 | 已修 | ✅ 已修（6 类敏感来源 + 特殊访问 + 相机/录屏） |
| P2-3 iOS 符号只扫主二进制 | 已修 | ✅ 已修（实测 25/25） |
| P3-1 权限重复 | 已修 | ✅ 已修（精确去重） |
| P3-2 `RULE-F` 无证据 | 已修（Android） | ⚠️ 只修了 Android，iOS 仍是 `const []`（P3-3） |
| P3-3 覆盖条目缺 limit | 已修 | ⚠️ **部分**：`ios.macho.strings` 仍无 limit（P3-1） |
| §22 模式 0x02/0x03 | 明确不做 | ✅ 诊断准确（`deepmap2_variant`），不冒称数据损坏 |

### 6.2 本轮**新发现**（上一轮没看的维度）

上一轮的问法是「安全引擎还能加什么能力」，因此没有检查：

1. 覆盖分母的第二个实例（iOS 可执行文件）—— 与已修的 Android 那个同构；
2. 覆盖量用代理指标（`android.arsc`）；
3. 规则判据的 A/B 对照组（v1-only vs unsigned）；
4. **结果外化**：Markdown 字段缺失、JSON 覆盖不足、报告英文脚手架；
5. 诊断本地化覆盖率（14/60）；
6. 权限目录的缺口（8 类）；
7. 概览页状态色与覆盖缺口脱钩。

这七项里有五项属于「输出层」，而上一轮的评分维度里没有「输出层」——
这也解释了为什么上一轮能到 95 分，而本轮只有 76：**不是能力退步，是审计半径变大。**

---

## 7. 建议优先级

| 序 | 事项 | 对应 | 类型 | 成本 |
|---|---|---|---|---:|
| 1 | iOS 可执行文件覆盖分母 + 截断进 limitations | P1-1 | 诚实性 | 小 |
| 2 | `android.arsc` 用真实资源数 | P2-1 | 诚实性 | 小 |
| 3 | `V1-ONLY` 增加 `META-INF/*.SF` 判据（或改名 + 降级） | P2-2 | 正确性 | 小 |
| 4 | 报告四个英文标签进 i18n | P2-4 | 观感 | 极小 |
| 5 | `hasCoverageGaps` 拆成「声明」与「实际缺口」 | P2-8 | 诚实性 | 小 |
| 6 | 补 4 类高频诊断的本地化键 | P2-5 | 观感 | 小 |
| 7 | Markdown/JSON 共用一份序列化 + 字段守卫测试 | P2-3 | 交付完整性 | 中 |
| 8 | 权限目录补 4 条（悬浮窗/安装/后台定位/录音） | P2-6 | 能力 | 小 |
| 9 | iOS 补 4 个标记 + 域名提取 | P2-7 | 能力 | 中 |
| 10 | P3 表里 12 条按需清理 | — | 一致性 | 小～中 |

**不建议现在做的**：数据流分析、动态沙箱、加固脱壳（前两项规格明确不做，第三项是另一套工程）；
模式 0x02/0x03 的硬解（上一轮已用四种探测证明不可行）。

---

## 8. 附录：复现方式

探针脚本复刻 `lib/apkparser/parse_task.dart` 的调用序列，核心部分：

```dart
final reader = ApkReader();
await reader.open(path);
final meta = await reader.parse();
final dex = [for (final n in reader.listFiles(extension: '.dex'))
               if (reader.readFile(n) case final b?) DexBytes(n, b)];
final candidates = reader.listFilesWithSize(extension: '.so');
final selection = NativeSymbolScanner.selectLibraries(candidates);
final security = AndroidSecurityAudit.audit(
  meta: meta, dexEntries: dex,
  nativeEntries: natives,
  nativeLibraryTotal: NativeSymbolScanner.uniqueLibraryCount(candidates),
  nativeSkipped: selection.skipped,
);
```

iOS 侧：`ZipHelper.open` → `IpaAnalysisReader.analyze` → `IosPrivacyAudit.audit`（参数与
`info_page.dart:429` 完全一致）。

**关键证据的取法**：

| 结论 | 一行验证 |
|---|---|
| P2-1 | 打印 `reader.arscParser != null` + `getAllResources().length`，再对比 `coverage['android.arsc']` |
| P2-2 | 同一条探针跑 `signed-v1-only.apk` 与 `signed-unsigned.apk`，diff 两份 findings |
| P1-1 | `IpaAnalysis.container.bundles.length` vs `nestedBinaries.length` vs `coverage['ios.executables']` |
| P2-4/5 | `LocaleSettings.setLocaleRaw('zh_CN')` 后渲染 `AnalysisReport.render` |
| P2-3 | `jsonDecode(AnalysisReport.renderJson(...))['application'].keys` |

---

## 9. 一句话总结

这套分析模块的**取证质量**（证据可追溯、状态机、边界诚实）已经高于多数同类工具；
它现在的短板不在「查得深不深」，而在**分母、导出与语言这三件「把结论交付出去」的事**。
上面 10 条建议里有 6 条是「小」成本 —— 修完之后，这份报告里唯一还会被用户感知到的硬边界，
就只剩静态分析本身了。

---

## 10. 修复记录（审计后，2026-10-19）

> 本节在审计完成后追加。§0–§9 保持**审计当时**的原样（含 76 分与各项问题描述），
> 便于日后对照「当时的判断」与「后来的处理」。下面三项已修复，每项都附
> **修复前后用同一支探针测出的数字**。

### 10.1 P1-1：iOS 可执行文件覆盖分母

**改动**

| 文件 | 变更 |
|---|---|
| `lib/ipaparser/ipa_analysis.dart` | `IpaAnalysis.nestedBundleTotal`（新增，容器里含代码的 bundle 总数）；`_readNestedBinaries` 改为返回 `(binaries, total)` |
| `packages/ipa_parser/.../ios_privacy_audit.dart` | `audit(..., int? nestedBundleTotal)`；分母 = `1 + max(total, 传入数)`；`IOS-SCAN-COVERAGE` 的 `total`/`uncovered` 同口径；截断时额外产出一条 `ios.executables.truncated` 限制说明 |
| `lib/pages/info_page.dart` | 把 `parsed.nestedBundleTotal` 传给审计 |
| 文案 | `coverage.notes.ios_executables_truncated`、`security.limitation_notes.ios_executables_truncated`（6 个语言包） |

**前后对照（`sun_signed.ipa`，同一支探针）**

```
修复前  ios.executables -> covered 25/25            ← 28 个 bundle 只解析了 24 个
        scan-coverage finding: total=25 scanned=25 uncovered=(无)
        limitations 含截断说明: false

修复后  ios.executables -> partial 25/28  note=ios.executables.truncated {count:3,total:27}
        scan-coverage finding: total=28 scanned=25 uncovered=3
        limitations 含截断说明: true
```

**守卫**：`test/analysis_coverage_test.dart` 新增两条 —— 截断时分母必须是包里的总数，
且截断必须同时进 `limitations`；旧调用方不传 `nestedBundleTotal` 时分母不得小于传入数。

### 10.2 P2-1：`android.arsc` 的覆盖量

**改动**

| 文件 | 变更 |
|---|---|
| `packages/apk_parser/.../android_security_audit.dart` | `audit(..., int? arscEntryCount)`；删掉 `locales.length + densities.length` 的代理判据；`null` → `notCovered`（缺失），`0` → `notCovered` 但措辞是「空表」，`>0` → `covered` 且 `covered` 为真实条目数 |
| `lib/apkparser/parse_task.dart` | 传 `reader.arscParser == null ? null : arscResources.length` |
| `lib/apkparser/apk_info.dart` | 分包路径同样传 `reader.arscParser?.getAllResources().length` |
| 文案 | `coverage.notes.android_arsc_empty`（6 个语言包） |

**前后对照（5 个夹具）**

```
修复前  signed-v2-v3 / v1-only / unsigned / attr-fixture / night-mode
        android.arsc -> notCovered 0/-  note=android.arsc.missing   ← 全部误报

修复后  signed-v2-v3         arsc=1 -> covered 1
        signed-v1-only       arsc=1 -> covered 1
        signed-unsigned      arsc=1 -> covered 1
        night-mode-resources arsc=4 -> covered 4
        attr-fixture         arsc=1 -> covered 1
```

**守卫**：新增「locales / densities 非空但没传计数 → 仍须 `notCovered`」与
「空表用 `android.arsc.empty` 而不是 `missing`」两条。原有的
`结构正常的 DEX 下各维度都是 covered` 之前是靠 `meta.locales = ['en']`
**凑**出 `covered` 的 —— 那正是把缺陷写进了测试，现在改为显式传 `arscEntryCount`。

### 10.3 P2-2：`ANDROID-V1-ONLY-SIGNING` 与未签名

**改动**

| 文件 | 变更 |
|---|---|
| `packages/apk_parser/lib/src/models.dart` | `ApkMeta.hasV1Signature`（`bool?`，`null` = 未判定） |
| `packages/apk_parser/lib/src/apk_reader.dart` | `_detectV1Signature()`：`META-INF/` **顶层**的 `*.SF` 与**同名** `*.RSA/.DSA/.EC` 两件套齐全才算有 v1 |
| `packages/apk_parser/.../android_security_rules.dart` | `V1-ONLY` 增加 `hasV1Signature == true`；新增 `ANDROID-UNSIGNED`（INFO，`confirmed`）覆盖「两者都没有」 |
| `lib/utils/analysis_report.dart` + 6 个语言包 | 新规则的三条文案（message / limitation / recommendation）与四个 switch 的注册 |

**前后对照（A/B 夹具，这是决定性证据）**

```
修复前  signed-v1-only.apk   -> ANDROID-V1-ONLY-SIGNING/p3
        signed-unsigned.apk  -> ANDROID-V1-ONLY-SIGNING/p3     ← 完全相同
        两份输出的 findings 逐行相同

修复后  signed-v1-only.apk   (v1=true,  v1Only=true)  -> ANDROID-V1-ONLY-SIGNING/p3
        signed-unsigned.apk  (v1=false, v1Only=true)  -> ANDROID-UNSIGNED/info
        signed-v2-v3.apk     (v1=true,  v1Only=false) -> 两条都不报
```

**守卫**：`packages/apk_parser/test/android_security_rules_test.dart` 新增一组
「v1-only 与未签名必须分开」——包括 `hasV1Signature == null`（不猜）与
签名块读不出（`unreadable` 不能折成结论）两态；
`test/apk_signing_block_test.dart` 用三个真实夹具钉住 `hasV1Signature` 的取值。

### 10.4 门禁与影响面

- `flutter analyze --fatal-infos --fatal-warnings`：根与四个包均 **0 issue**
- `dart format --output=none --set-exit-if-changed`：**0 changed**
- `flutter test`：**1,544 通过 / 14 跳过**（审计时 1,537；新增 7 条：覆盖 4 + 签名夹具 3）
- 包级：`apk_parser` **109**（原 104，新增 5 条规则用例）、`ipa_parser` 125、
  `analysis_model` 58、`archive_safety` 40
- 规则数：Android 28 → **29**（README 的「19 条规则」按「规则表 18 + 升级变体 1」计）

**未在本轮处理**：§4 的其余 P2（P2-3 导出覆盖面、P2-4 英文标签、P2-5 诊断本地化、
P2-6 权限目录、P2-7 iOS 标记与域名、P2-8 `hasCoverageGaps` 恒真）与 P3 表。
它们都不影响以上三项的结论，但 P2-8 会让「覆盖不足」提示继续恒亮，建议紧随其后处理。
