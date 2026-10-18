# AppInfoTool 安全分析能力审计（APK / IPA）

> 审计对象：**2.4.13**（提交 `870a8aa`，tag `v2.4.13`）
> 审计日期：2026-10-18
> 性质：**只读审计**。本文件不修改任何生产代码；文中每个结论都标了「怎么测的」。
> 审计范围：Android 侧（`packages/apk_parser` + `analysis_model`）与 iOS 侧
> （`packages/ipa_parser` + `analysis_model`）的**静态安全分析**能力。

---

## 0. 结论与评分

**一句话：这套分析在「图片 → OCR → 上传」这一条链上做到了可复核的取证，
在其余敏感数据类型上基本只有权限条目，没有「能力 + 去向」的关联；
而覆盖率的口径有两处会让人高估实际扫描量。**

综合评分 **65 / 100**。

| 维度 | 权重 | 得分 | 依据 |
|---|---:|---:|---|
| 检测广度（能覆盖多少类风险） | 20 | **11** | 组合规则 6 条里 4 条是图片链；短信/通讯录/定位/录音/无障碍/动态加载**没有任何标记**（§4 P2-2） |
| 检测深度（能证到哪一步） | 20 | **9** | 最强证据是「同一方法体内两个调用点同现」，**没有数据流**；iOS 侧没有字节码（§6） |
| 证据可追溯 | 15 | **13** | 每条发现项带来源 + 文件内位置（DEX 还带指令偏移）；扣 2 分见 P3-2 |
| 覆盖诚实度（缺口是否如实报告） | 20 | **12** | 有 8/7 个覆盖维度 + 逐条未覆盖说明；但**原生库比例虚高**、字符串扫描比例不可见（P1-1、P1-2） |
| 误报控制 | 15 | **12** | 等级/置信度分级克制，措辞明确区分「同现」与「数据流」；扣分见 P3-1 |
| 工程健壮性 | 10 | **8** | 343 MB 包端到端 13.5 s；加固样本可解析；解压有界；扣分见 P1-2 |

> 深度的 9/20 里有一部分是**刻意的设计约束**（静态、不反汇编、不下恶意结论、
> 不做厂商归因）。这是规格要求，不是实现缺陷 —— 但用户需要知道它意味着什么，
> 所以仍然按「能力」扣分（§6 有单独说明）。

---

## 1. 审计口径（怎么测的）

| 手段 | 具体做法 | 用在 |
|---|---|---|
| 静态计数 | 在 `packages/*/lib/src/security/` 与 `analysis_model` 里数 `ruleId` / `CodeMarker` / `PermissionRule` / `NativeSymbolMarker` / `CoverageEntry` | §2 |
| 生产路径实测 | 写一次性探针，**复刻 `parse_task.dart` 的调用序列**（`ApkReader.open` → `parse` → 收集 DEX/原生库 → `scanHardeningSignals` → `AndroidSecurityAudit.audit`），不是直接调规则函数 | §3 |
| 真实样本 | 5 个真实 APK + 1 个真实 IPA（见 §3 表） | §3、§4 |
| 交叉核对 | 覆盖率数字与「实际条目数」对照（`.so` 条目数、DEX 字节数、可执行文件字节数） | P1-1、P1-2、P2-1 |
| 缺口反查 | 对 13 个常见敏感 API 逐个 grep 标记表，确认「有没有」 | P2-2 |

**样本清单**（都在本机 `~/Downloads` 与仓库根，非仓库资产）：

| 样本 | 大小 | 性质 |
|---|---:|---|
| `抖音-v40.7.0.apk` | 343.2 MB | 超大正常包，55 个 DEX |
| `49af6cnn-1018.apk` | 71.0 MB | 加固样本（72 MiB 零填充清单 + 100 条诱饵条目） |
| `飞牛TV-v1.4.1.apk` | 49.1 MB | 小包，1 个 DEX |
| `澳門上葡京-v6.9.76.apk` | 70.8 MB | 加固/混淆类样本 |
| `138_1018191005.apk` | 76.3 MB | 单 DEX 大包（无上传线索） |
| `sun_signed.ipa` | 40.5 MB | 真实 IPA，27 个嵌套 bundle |

---

## 2. 能力盘点（静态计数）

### 2.1 Android

| 项 | 数量 | 说明 |
|---|---:|---|
| 组合规则 | **6** | `ANDROID-RULE-A/B/C/D/E/F`（D 有 `-ESCALATED` 变体） |
| 单点能力规则 | **5** | `-OCR-CAPABILITY`、`-UPLOAD-API`、`-NETWORK-ENDPOINTS`、`-NETWORK-CLIENT`、`-NATIVE-SYMBOLS` |
| 权限派生规则 | **24 + 4** | 24 条权限目录 + `EXPIRED` / `INERT` / `SDK23-CONDITIONAL` / `UNCATEGORIZED` |
| 代码标记 | **22** | 字面量子串匹配（区分大小写），覆盖 OCR / 截图 / 相册 / 上传 / 网络客户端 / 后台 / 第三方 SDK |
| 原生符号标记 | **26**（与 iOS 共享） | 命令执行、动态加载（`dlopen`/`dlsym`）、反调试（`ptrace`）、网络、系统属性 |
| 覆盖维度 | **8** | manifest / permissions / arsc / dex.structure / dex.strings / dex.methodReferences / dex.callSites / nativeSymbols |
| 证据来源枚举 | **11** | manifest / infoPlist / privacyInfo / dexString / dexMethodReference / machoSymbol / nativeSymbol / zipEntry / provisioning / runtime / other |
| 风险分类 | **9** | photoAccess / ocrImage / dataExfiltration / network / thirdPartySdk / backgroundTask / deviceData / configuration / other |

### 2.2 iOS

| 项 | 数量 | 说明 |
|---|---:|---|
| 规则 | **21** 个 `ruleId`（15 个静态 + 6 个条件变体） | 含 `IOS-USAGE-WITHOUT-API`（2.4.13 新增） |
| 代码标记 | **10** | PhotoKit / PHPicker / PhotosUI / AVCapture / Vision OCR / 剪贴板 / NSURLSession / multipart / Alamofire / AFNetworking |
| 原生符号标记 | **26**（共享同一张表） | 与 Android 完全一致 |
| 覆盖维度 | **7** | infoPlist / usageDescriptions / privacyManifest / executables / macho.strings / nativeSymbols / signature |

**iOS 与 Android 的结构差异**（不是实现偏好，是平台差异）：
iOS 没有「权限清单」，只有 `Info.plist` 的用途说明键；「应用能不能访问某类数据」
只能靠 Mach-O 里的 API 字符串/符号推断。因此 iOS 侧多了一类 Android 没有的规则：
**声明 vs 实现的对照**（`IOS-PHOTO-LIBRARY-NO-USAGE`、`IOS-CAMERA-NO-USAGE`、
`IOS-USAGE-WITHOUT-API`）。

---

## 3. 实测结果（生产流水线，真实样本）

| 样本 | DEX | 原生库（选中/全部条目） | 发现项 | 覆盖缺口 |
|---|---:|---|---:|---|
| 抖音 | 55 | **24 / 267** | 30 | 8 维全有，strings 与 callSites `partial` |
| 49af6cnn | 6 | **24 / 81** | 26 | 同上 |
| 飞牛TV | 1 | 12 / 29 | 21 | strings `partial` |
| 澳門上葡京 | 5 | 24 / 81 | 26 | strings `partial` |
| 138_1018 | 1 | 1 / 2 | 20 | strings `partial` |
| `sun_signed.ipa` | — | 25 个可执行文件 | 10 | 7 维，`macho.strings` `partial` |

### 3.1 发现项分布（抖音，30 条）

| 类别 | 条数 | 代表 |
|---|---:|---|
| 权限条目 | 21 | 19 条目录条目 + `-INERT` + `-EXPIRED`；多数 INFO，`QUERY_ALL_PACKAGES`/定位/通讯录/剪贴板为 P3 |
| 权限汇总 | 1 | `-UNCATEGORIZED`（19 条未知权限合成一条，不刷屏） |
| 能力单点 | 5 | `-OCR-CAPABILITY`、`-UPLOAD-API`、`-NETWORK-ENDPOINTS`、`-NETWORK-CLIENT`、`-NATIVE-SYMBOLS`（12 个符号） |
| **组合结论** | 3 | `RULE-B`(P2)、`RULE-C`(P1，**带 dataTransform**)、`RULE-E`(P1) |
| 合计 | **30** | 与实测 `findings=30` 一致 |

`RULE-C` 的中间跳在真实样本上确实被填上了 —— 2.4.13 的 B-5 改动在生产路径生效。

### 3.2 覆盖维度实际状态（抖音）

```
android.manifest         covered
android.permissions      covered  265
android.arsc             covered  7
android.dex.structure    covered  55/55
android.dex.methodReferences covered 55/55
android.dex.callSites    partial  15,863,065
android.dex.strings      partial  50,648,616   ← 见 P1-2
android.nativeSymbols    covered  24/24        ← 见 P1-1
```

`hasCoverageGaps = true`（六个样本全部如此），并有 62 条逐项未覆盖说明
（其中 51 条是 `android.dex.budget`）。

---

## 4. 问题清单

### P1-1 原生库覆盖率虚高：267 个 `.so` 只扫了 24 个，报告写「24/24 已覆盖」 ✅ **已修（§9）**

**证据**（实测）：

```
抖音：.so 条目 267，唯一库名 266，选中 24，跳过 242
49af6cnn：.so 条目 81，唯一库名 81，选中 24，跳过 57
澳門上葡京：.so 条目 81，选中 24
138_1018：.so 条目 2，选中 1（同一个库的两个 ABI —— **属于合理的去重**）
覆盖表：android.nativeSymbols = covered 24/24
```
`.so` 条目数用 `unzip -l | grep -c '\.so$'` 独立核对过，与解析器一致。

**必须区分两种「跳过」**：同库多 ABI 的去重是**正确的**（一个库看一个 ABI 就够）；
本次的问题只出在**唯一库**上 —— 抖音 266 个唯一库名只看了 24 个，
49af6cnn 81 个唯一库名只看了 24 个。

**根因**：`NativeSymbolScanner.selectLibraries` 按「同库只取一个 ABI + 单库 32 MiB +
总量 96 MiB + 最多 24 个」挑选，挑剩下的放进 `NativeLibrarySelection.skipped`；
但 `CoverageEntry` 的 `limit` 用的是**传入审计的条目数**（= 选中数），
而 `skipped` **没有任何消费者**（`grep -rn "\.skipped" lib/` 零命中）。

**影响**：用户在「覆盖」一栏看到「24/24」，会以为原生层全查过了；实际只有 9%。
报告里连一句「另有 242 个库未扫描」都没有。

**建议**：`CoverageEntry.limit` 用「全包 `.so` 唯一库名数」，并把 `skipped`
作为 `AnalysisNote` 送进 `limitations`（措辞用「未扫描」，不用「未覆盖」以外的推断）。
优先级：**高**（这是诚实性问题，不是能力问题）。

---

### P1-2 大包的字符串线索只扫了约 11%，而覆盖表看不出比例 ✅ **已修（§9）**

**证据**：`DexClueScanner` 的预算是**单 DEX 8 MiB + 总量 48 MiB**。

```
抖音：55 个 DEX，DEX 总字节 437.2 MiB
      实际扫到的字符串字节 = 50,648,616（48.3 MiB）≈ 11%
      51 条 android.dex.budget 未覆盖说明
覆盖表：android.dex.strings = partial, covered 50,648,616, limit = null
```

**注意口径差别**：`methodReferences` 与 `callSites` 是 **55/55 全覆盖**（这是耗时大头，
9.6 s），只有**字符串**扫描受预算限制。也就是说：
「用了哪些方法」是完整的，「字符串里出现了什么」只看了约 1/9。

**影响**：域名、SDK 名字、可疑字面量（`upload`、`OCR`、`http://`）在未扫到的
DEX 里出现时，会**静默漏报**。`partial` 状态是诚实的，但 `limit = null` 让读者
算不出「扫了多少比例」。

**建议**：给 `dex.strings` 的 `CoverageEntry` 补 `limit`（DEX 总字节），
让界面能显示「48.3 / 437.2 MiB」。优先级：**高**（一行改动，直接提升可读性）。

---

### P2-1 iOS 主可执行文件有 47% 没被扫描

**证据**：

```
sun_signed.ipa：主可执行文件 35,953,728 B（34.3 MiB），单文件上限 16 MiB
              嵌套可执行文件合计 28,775,296 B，最大单个 9,036,592 B（未超限）
              scanned = 16,777,216 + 28,775,296 = 45,552,512（与覆盖表一致）
```

**影响**：主二进制后 19.2 MiB 的字符串与 API 线索**完全没看**。
2.4.13 修 `IOS-USAGE-WITHOUT-API` 的误报，根因就是这块（`AVCapture` 在 16 MiB 之后）。

**现状是诚实的**：`macho.strings = partial`，且有 `ios.executable.over_budget` 说明。
缺的只是「比例」：`covered 45,552,512` 没配 `limit`（全部可执行文件字节）。

**建议**：同 P1-2，补 `limit`；另外考虑把「主可执行文件」的预算单独提到 64 MiB
（真实 App 的主二进制 30–80 MB 很常见，16 MiB 太小）。优先级：**中**。

---

### P2-2 规则高度集中在「图片链」，其余敏感数据类型没有关联规则 ✅ **已修（§9）**

**证据**：对 13 个常见敏感 API 逐个 grep 标记表，**全部为零命中**：

| 未编目的 API | 对应的现实风险 |
|---|---|
| `DexClassLoader` / `PathClassLoader` | 动态加载 / 热更新 / 加固壳，是「运行时行为与静态分析不一致」的主因 |
| `AccessibilityService` / `BIND_ACCESSIBILITY_SERVICE` | 无障碍滥用（读屏、自动点击、盗取验证码） |
| `DeviceAdminReceiver` / `BIND_DEVICE_ADMIN` | 设备管理器（防卸载、锁屏） |
| `SmsManager` | 短信读取/发送（验证码窃取） |
| `TelephonyManager` | 设备标识（IMEI/IMSI）—— 分类里有 `deviceData`，但没有标记 |
| `ContactsContract` | 通讯录读取 |
| `LocationManager` | 定位（只有权限条目，没有 API 能力） |
| `MediaRecorder` | 录音 |
| `ClipboardManager` | 剪贴板（只有 Android 10+ 的 `READ_CLIPBOARD` 权限被编目） |
| `NotificationListenerService` | 通知读取（含验证码） |

**影响**：`ANDROID-RULE-A…F` 里 **4 条是图片链**（A 相册、B 图像+OCR、C 三段、E 后台+敏感+上传）。
「通讯录 → 上传」「短信 → 上传」「定位 → 上传」「设备标识 → 上传」这类
**最常见的外传模式，一条组合规则都没有**，只有一条 INFO 级权限条目。

**建议**：不要一次加十条规则。先加 3 个标记（`DexClassLoader`、`TelephonyManager`、
`ContactsContract`）+ 1 条组合规则「敏感数据来源 + 上传」（复用 RULE-C 的同现框架，
`dataSource` 换成对应类型）。优先级：**中高**（这是能力缺口里最影响实用性的）。

---

### P2-3 iOS 原生符号只扫主可执行文件

**证据**：`IosPrivacyAudit` 调用 `IosNativeSymbolAudit.scan(executableBytes: ...)`，
只传主可执行文件；`ios.nativeSymbols = covered 1`，而同一份 IPA 有 25 个可执行文件
（字符串扫描是 25/25）。

**影响**：App Extension / 框架里的 C/C++ 代码（`system`、`dlopen`、`ptrace`）
不会被符号层看到。`sun_signed.ipa` 的 9 个符号全部来自主二进制。

**建议**：把 `nestedExecutables` 的字节也传给符号扫描（`MachOParser` 已能解析嵌套
Mach-O），或至少在覆盖说明里写明「只扫了主可执行文件」。优先级：**中**。

---

### P3-1 权限重复声明 → 重复的发现项

**证据**：抖音的 manifest 里 `ACCESS_COARSE_LOCATION` 与
`FOREGROUND_SERVICE_MEDIA_PROJECTION` 各声明两次，审计产出**两条完全相同**的
`ANDROID-PERMISSION-ACCESS_COARSE_LOCATION`（severity/confidence/evidence 全同）。

**影响**：界面出现重复卡片；`UNCATEGORIZED` 的计数也可能被抬高。
不影响结论，只影响观感与「这条到底有几个问题」的判断。

**建议**：审计入口对 `meta.permissions` 去重（保留首次出现顺序）。优先级：**低**（一行）。

---

### P3-2 `ANDROID-RULE-F` 的证据为空，违反模型自己的约定

**证据**：`138_1018191005.apk` 上产出 `ANDROID-RULE-F [info/confirmed] ev=0`。
而 `SecurityFinding.evidence` 的文档写着「空列表意味着这条发现没有依据 —— 不允许出现」。

**说明**：RULE-F 是「未发现上传特征」的**否定结论**，语义上确实没有「命中的证据」。
但它仍应给出「查了什么」的依据（例如「扫描了 1 个 DEX / N 个调用点，未命中上传标记」），
否则它与「根本没查」在数据上无法区分。

**建议**：给 RULE-F 补一条证据（`dexMethodReference` 来源 + 「已扫描 N 个 DEX」）。
优先级：**低**。

---

### P3-3 覆盖条目普遍缺 `limit`，比例不可见

**证据**：六个样本的 `dex.strings` / `dex.callSites` / `macho.strings` / `nativeSymbols`
的 `limit` 多为 `null` 或「选中数」。

**影响**：覆盖表能说「partial」，但说不出「扫了多少」。
`covered` 是字节数时尤其难读（50,648,616 是多少比例？）。

**建议**：统一约定 —— 有「总量」概念的维度必须给 `limit`；没有的（如 manifest）
显式标 `notApplicable` 而不是留空。优先级：**中**（与 P1-1/P1-2/P2-1 是同一件事）。

---

## 5. 误报风险与措辞

| 风险点 | 现状 | 评价 |
|---|---|---|
| 「同现」被读成「数据流」 | `RULE-B/C/E` 全部 `confidence: suspected`，`relationship` 明确写「未证实哪一段」 | 好。措辞是这套工具最强的地方 |
| 权限被读成「恶意」 | 大多数权限 `INFO`；只有广泛存储 `P2`，措辞是「需人工复核」 | 好 |
| 符号存在 = 被调用 | `RULE-A` 的 limitation 明确写「符号存在不代表运行时会调用」 | 好 |
| iOS 声明 vs 实现 | 2.4.13 已修掉一个真实误报（扫描截断导致「声明了相机但没实现」） | 好，且留下了回归用例 |
| 重复发现项 | 见 P3-1 | 观感问题 |
| 加固样本 | `49af6cnn` 的 100 条诱饵条目被识别为 `decoyArchiveEntries`，未导致误判 | 好 |

**一处需要提醒用户的措辞**：`IOS-RULE-D-ESCALATED` 在 `sun_signed.ipa` 上给 `p1`
（`confirmed`）。它的依据是「ATS 允许任意明文 + 存在敏感线索」，`confirmed` 指的是
「配置事实已确认」，不是「风险已确认」—— 但用户容易把 `P1 + confirmed` 读成
「高危已确认」。建议在 UI 上把「配置事实的置信度」与「风险的置信度」分开表达。

---

## 6. 能力的真实边界（设计约束，不是缺陷）

这些是**静态分析 + 不做动态执行**的必然结果，写在这里是为了让用户知道
「报告说没有」意味着什么：

| 做不到 | 后果 | 报告是否说清 |
|---|---|---|
| 数据流分析（寄存器/参数传递） | 只能说「两个调用点在同一方法体」，不能说「这个数据流到了那里」 | 是（`relationship` + `limitation`） |
| 跨方法/跨类追踪 | 同现只在**方法体**粒度，跨方法调用链不追踪 | 是 |
| 反射 / 动态加载 / JNI | `DexClassLoader` 之后的代码完全不可见 | 是（`android.offline_static_analysis`） |
| 加固/脱壳 | 只能报「结构异常线索」，看不到真实代码 | 是（`hardeningHints` + 覆盖说明） |
| iOS 字节码 | iOS 侧**没有**方法级分析，只有字符串 + 符号 | 是（`ios.macho.strings` 覆盖维度） |
| 运行时行为 | 不做动态沙箱（规格明确不做） | 是 |
| 厂商归因 | 明确不判断「是哪家加固」 | 是 |

---

## 7. 建议（按优先级）

| 序 | 事项 | 类型 | 成本 |
|---|---|---|---|
| 1 | 原生库覆盖率口径改成「全包唯一库名」，并把 `skipped` 送进未覆盖说明（P1-1） | 诚实性 | 小 |
| 2 | `dex.strings` / `macho.strings` / `nativeSymbols` 补 `limit`（P1-2、P2-1、P3-3） | 诚实性 | 小 |
| 3 | 加 3 个标记（`DexClassLoader`、`TelephonyManager`、`ContactsContract`）+ 1 条「敏感来源 + 上传」组合规则（P2-2） | 能力 | 中 |
| 4 | iOS 原生符号扫描纳入嵌套可执行文件（P2-3） | 能力 | 中 |
| 5 | 权限去重（P3-1） | 观感 | 极小 |
| 6 | `RULE-F` 补证据（P3-2） | 一致性 | 极小 |
| 7 | 把「主可执行文件」的 iOS 扫描预算从 16 MiB 提到 64 MiB（P2-1） | 能力 | 小（但要重测性能） |

**不建议现在做的**：数据流分析、动态沙箱、加固脱壳 —— 前两项规格明确不做；
第三项需要另一套工程（不是规则能解决的）。

---

## 8. 与上一轮审计的关系

`docs/audit/APPINFOTOOL_COMPLETENESS_AUDIT_2026-10-18.md`（82.5/100）审的是
**整个项目**的完成度（解析、UI、i18n、发布流程都算）。
本文件只审**安全分析能力**这一块，口径更窄、证据更硬（全部是生产路径实测）。
两份报告不冲突：项目整体完成度高，但**安全分析的广度与深度仍是短板**。

---

## 9. 修复记录（2026-10-18，同日晚）

本轮修掉 §7 建议表的前三项。**都按「先写测试再改实现」做的**，共新增 **19 条测试**
（`test/audit_coverage_honesty_test.dart` 9 条、`test/android_sensitive_source_rule_test.dart`
10 条），`packages/apk_parser` 的规则表守卫同步更新。

### 9.1 P1-1 原生库覆盖口径（已修）

`AndroidSecurityAudit.audit` 新增两个参数：

| 参数 | 含义 |
|---|---|
| `nativeLibraryTotal` | 全包**唯一库名**数（含未被选中的） |
| `nativeSkipped` | `selectLibraries` 挑剩下的库 |

覆盖条目的 `limit` 改用前者，`status` 把 `nativeSkipped.isNotEmpty` 也算作 `partial`，
并新增一条 `android.native_symbols.not_scanned` 说明（带数量）。

**真实样本前后对照**（同一份 抖音 343 MB）：

| 项 | 修前 | 修后 |
|---|---|---|
| `android.nativeSymbols` | `covered 24/24` | **`partial 24/266`** |
| 未扫描说明 | 无 | **`{count: 242}`** |

`49af6cnn`：`24/24` → `partial 24/81`，说明 `{count: 57}`。
`飞牛TV` / `138_1018` 本来就是全扫（12/12、1/1），修后仍 `covered` —— **没有制造假缺口**。

### 9.2 P1-2 / P3-3 覆盖比例（已修）

`android.dex.strings` 的 `limit` 改为 **DEX 总字节**。真实样本现在能直接算出比例：

| 样本 | covered | limit | 比例 |
|---|---:|---:|---:|
| 抖音 | 50,648,616 | 458,461,352 | **11.0%** |
| 49af6cnn | 39,580,304 | 44,009,784 | 90.0% |
| 飞牛TV | 8,388,608 | 9,517,584 | 88.1% |
| 138_1018 | 8,388,608 | 145,406,681 | **5.8%** |

`138_1018` 那个数字是这次新增口径才看出来的：**一个 145 MB 的单 DEX，只扫了前 8 MiB**。

### 9.3 P2-2 敏感数据来源（已修）

**三个新标记**（`code_markers.dart`）：

| 标记 | 字面量 | 消费者 |
|---|---|---|
| `device-id` | `TelephonyManager` | 规则 G |
| `contacts` | `ContactsContract` | 规则 G |
| `dynamic-loading` | `DexClassLoader` | 「覆盖不足」说明 `android.dex.dynamic_loading` |

**新规则 `ANDROID-RULE-G`**：`hasSensitiveSource && hasUploadCapability` → **P2 / suspected**。
比规则 C 低一档是有意的：读设备标识/通讯录极常见（很多 SDK 都读），单凭同现不足以 P1。

三条防误报的约束写进了测试：

1. **只有来源、没有上传 → 不报**；
2. **只有上传、没有来源 → 不报**；
3. **只有字符串线索时 `dataTransform` 留 null** —— 没有方法上下文就不编中间跳。

`DexClassLoader` 不产出风险结论，只进「覆盖不足」：被加载的代码不在归档里，
静态分析的结论对那部分**不成立**。这条比报一条「疑似动态加载风险」诚实。

### 9.4 门禁（前三项修完时的中间态；四项全部修完见 §9.9）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `dart format --set-exit-if-changed $(git ls-files -co ...)` | 0 | 252 文件 / 0 changed |
| `flutter analyze --fatal-infos --fatal-warnings` | 0 | No issues |
| `flutter test` | 0 | **1,322 通过 / 14 跳过 / 0 失败**（修前 1,303，+19） |
| `packages/apk_parser` | 0 | **69**（+1：规则 G 的逐条驱动） |
| 其余三包 | 0 | 58 / 40 / 54 |
| `PERF_APK=抖音… perf_probe_apk_test.dart` | 0 | 端到端 **14.13 s**（此前 13.5–13.9 s 区间）；字符串扫描 1.67 → 1.75 s —— 多 3 个标记约 +14% 的标记比较，属预期 |

### 9.5 P2-3 iOS 原生符号纳入嵌套可执行文件（已修）

`IosNativeSymbolAudit.scan` 新增 `nested`（`IosNativeImage = ({path, bytes})`），
主可执行文件与嵌套走**同一段**解析逻辑。`IosNativeSymbolResult` 新增
`imagesAttempted` / `scannedPaths`，覆盖条目的 `limit` 用前者。

**真实样本前后对照**（`sun_signed.ipa`）：

| 项 | 修前 | 修后 |
|---|---|---|
| `ios.nativeSymbols` | `covered 1 / null` | **`covered 25/25`** |

### 9.6 P3-1 权限去重（已修）

`AndroidSecurityAudit.audit` 入口按 `(name, maxSdkVersion, sdk23Only)` **精确去重**。
只去精确重复：同名但 `maxSdkVersion` 不同的是两条不同的声明（一条可能已过期、
一条仍然生效），合并会把版本条件吃掉 —— 这条有单独用例守着。

覆盖表的 `android.permissions` 计数同步改用去重后的数量。

### 9.7 P3-2 `RULE-F` 补证据（已修）

否定结论现在带一条 `dexMethodReference` 证据：
「N 个 DEX / M 个调用点已扫描，未命中上传标记」（`detailCode: rule_f.scope`，
6 个语言包）。没有它，「没发现」与「根本没查」在数据上无法区分。

### 9.8 P2-1 iOS 单文件扫描预算 16 → 64 MiB（已修）

`_Budget.maxBytes` 改为 64 MiB。原值 16 MiB 让 `sun_signed.ipa` 主可执行文件
（34.3 MiB）的后 47% 完全没扫 —— B-6 那个「声明了相机但没实现」的误报就是它。

同时把预算做成**可注入**（`audit(scanBudgetBytes:)`，文档标注测试用）：
否则验证「截断时不判缺失」要真造 64 MiB 夹具，用例会慢几十倍。

**真实样本前后对照**：

| 项 | 修前 | 修后 |
|---|---|---|
| `ios.macho.strings` | `partial 45,552,512` | **`covered 64,729,024`** |
| `IOS-CAMERA` | **缺失**（`AVCapture` 在 16 MiB 之后） | `p3/suspected`，正常产出 |

`IOS-USAGE-WITHOUT-API` 不再误报（声明与实现都对上了）。
代价：静态解析 222.6 → **239.9 ms**（+7.8%，同一量级）。

### 9.9 门禁（四项全部修完实测）

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `dart format --set-exit-if-changed $(git ls-files -co ...)` | 0 | 0 changed |
| `flutter analyze --fatal-infos --fatal-warnings` | 0 | No issues |
| `flutter test` | 0 | **1,335 通过 / 14 跳过 / 0 失败** |
| `packages/apk_parser` | 0 | 69 |
| 其余三包 | 0 | 58 / 40 / 54 |

新增测试：`test/audit_permission_and_rulef_test.dart`（6 条）、
`test/ios_native_symbols_nested_test.dart`（7 条），加上前一轮的 19 条，
**本轮（§9）共新增 32 条**。

### 9.10 §7 建议表的完成情况

| 序 | 事项 | 状态 |
|---|---|---|
| 1 | 原生库覆盖口径 + `skipped` 说明 | ✅ |
| 2 | `dex.strings` / `macho.strings` / `nativeSymbols` 补 `limit` | ✅ |
| 3 | 三个标记 + 「敏感来源 + 上传」规则 G | ✅ |
| 4 | iOS 原生符号纳入嵌套可执行文件 | ✅ |
| 5 | 权限去重 | ✅ |
| 6 | `RULE-F` 补证据 | ✅ |
| 7 | iOS 主可执行文件预算 16 → 64 MiB | ✅ |

**评分：65 → 74/100。** 变化来自三处：

- **覆盖诚实度 12 → 19**：三处比例/分母都改成能算的，未扫描的库有了说明；
- **检测广度 11 → 12**：多了「设备标识/通讯录 → 上传」一条链；
- **工程健壮性 8 → 9**：iOS 主二进制不再被 16 MiB 截掉近一半。

深度仍是 9/20（无数据流、iOS 无字节码），这是设计约束，不是这几项能改的。

---

## 10. 第二轮能力扩展（2026-10-18，同日晚）

§9 修完七项后，继续补**检测广度**。新增 19 条测试，`flutter test` 1,335 → **1,354**。

### 10.1 敏感来源从 2 类扩到 6 类

规则 G 现在覆盖：设备标识、通讯录、**短信**（`SmsManager`）、**定位**
（`LocationManager`）、**录音**（`MediaRecorder`）、**剪贴板**（`ClipboardManager`）。

**按来源稀有度分级**（真实样本逼出来的）：5 个样本里 4 个都同时有「设备标识 /
定位 / 剪贴板 + 上传」—— 一律 P2 会让这条规则在九成应用上出现，读者会学会
忽略它。现在：

| 来源 | 等级 | 理由 |
|---|---|---|
| 通讯录 / 短信 / 录音 | **P2** | 正常应用里「读这些 + 上传」并不常见 |
| 定位 / 剪贴板 / 设备标识 | **P3** | 几乎每个应用都有（地图、剪贴板同步、统计 SDK） |

### 10.2 新增 `ANDROID-SPECIAL-ACCESS`（P3/confirmed）

无障碍服务 / 设备管理器 / 通知监听。这三类能力一旦被滥用，危害远大于普通权限
（读屏、自动点击、盗取验证码、防卸载），但正常应用也确实在用（自动化、
密码管理器、手表配套），所以只到 P3，`confirmed` 指的是**声明事实**已确认。

### 10.3 真实样本抓到的第二个误报（本轮最重要）

第一版用 DEX 字面量判（`AccessibilityService` / `DeviceAdminReceiver` /
`NotificationListenerService`），**飞牛TV 立刻误报「无障碍服务」**。查证据发现
它来自 Material 的 `MaterialAutoCompleteTextView` 查询
`AccessibilityServiceInfo` —— 子串匹配把 UI 库的正常调用算成了无障碍服务。

**改判据**：不用 DEX 字面量，改用**清单层组件的 `android:permission`**：

```
android.permission.BIND_ACCESSIBILITY_SERVICE          → accessibility
android.permission.BIND_DEVICE_ADMIN                   → device_admin
android.permission.BIND_NOTIFICATION_LISTENER_SERVICE  → notification_listener
```

这是「提供该能力的组件必须声明 BIND 权限」这一平台约束的直接落地，比在字节码里
找类名可靠得多。修后实测：

| 样本 | BIND 权限组件 | 是否报 SPECIAL-ACCESS |
|---|---|---|
| 抖音 | `BIND_ACCESSIBILITY_SERVICE`（1 个） | ✅ 报 `{sources: [accessibility]}` |
| 飞牛TV | 无 | ❌ 不报（误报消失） |
| 49af6cnn / 138 | 只有 `BIND_JOB_SERVICE` | ❌ 不报 |

回归用例已补：`AccessibilityServiceInfo` 出现在 DEX 里**不算**无障碍服务。

### 10.4 教训

**「子串匹配一个类名」在真实样本上极容易误伤。** 同一个词根下往往有一个
「查询它」的 API（`AccessibilityServiceInfo`、`AccessibilityManager`），而
查询方可能是完全无关的 UI 库。判「谁提供了某能力」时，优先找**声明式证据**
（清单权限、组件声明），而不是代码里的类名。

### 10.5 评分影响

**74 → 76/100**：检测广度 12 → 14（多了 4 类数据来源 + 3 类特殊访问能力）。
覆盖诚实度、深度、证据可追溯不变。

---

## 11. 第三轮：iOS 三类能力的双向对照 + Android 相机与录屏

新增 23 条测试，`flutter test` 1,354 → **1,377**。

### 11.1 iOS：通讯录 / 定位 / 麦克风的「声明 vs 实现」

相册与相机早就有两个方向的检查，这三类此前只有一个方向（甚至没有）。现在补齐：

| 方向 | 规则 | 等级 | 含义 |
|---|---|---|---|
| 有 API、没声明 | `IOS-USAGE-MISSING-FOR-API` | **P2** | 运行时系统拒绝请求、上架被拒 |
| 有声明、没 API | `IOS-USAGE-WITHOUT-API` | info / unknown | 过度声明（隐私标签不准） |

新标记（只取「读取/录制专用」的类名）：

| 能力 | 标记 | 用途说明键 |
|---|---|---|
| 通讯录 | `CNContactStore` / `ABAddressBook` | `NSContactsUsageDescription` |
| 定位 | `CLLocationManager` | `NSLocation*`（三个键都算） |
| 麦克风 | `AVAudioRecorder` / `AVAudioEngine` | `NSMicrophoneUsageDescription` |

**刻意不收 `AVAudioSession`**：播放音频也要用它，收了等于每个音视频应用都被报。

### 11.2 真实样本抓到的第三个误报

`sun_signed.ipa` 报了「声明了麦克风但没实现」。查证据：它有 `AVCapture` ——
**`AVCaptureSession` 配上音频输入同样能录音**，而它留的符号就是 `AVCapture`。

修法：麦克风的**反向**检查把 `camera` 也算作实现证据。修后该误报消失。
（正向检查不变：`AVAudioRecorder` 出现但没声明才报 —— 那才是硬缺陷。）

### 11.3 Android：Camera2 / Camera1 与 MediaProjection

- **相机 API 此前一个标记都没有**：「能不能拍照」只能从 CAMERA 权限推。
  新增 `android.hardware.camera2`（覆盖 CameraManager / CameraDevice /
  CameraCaptureSession）与 `android.hardware.Camera`，都归 `photoAccess` ——
  于是相机现在会参与「图像输入 + OCR」的组合判定。
- **MediaProjection 从 OCR 里摘出来**：它原来挂在 `ocrImage` 下，于是「录屏」
  会被算成「文字识别能力」。两件事完全不同：录屏抓整块屏幕画面（可能含验证码、
  聊天记录），OCR 是识别图片里的字。现在单列 `ANDROID-SCREEN-CAPTURE`
  （P3 / independentCapability），并不再污染 OCR 线索。

真实样本：抖音与飞牛TV 都命中录屏（P3）—— 投屏/共享功能很常见，P3 合适。

### 11.4 评分影响

**76 → 78/100**：检测广度 14 → 16（iOS 三类能力双向、Android 相机与录屏）。
