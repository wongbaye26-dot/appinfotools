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

> **本文件是滚动记录**：§9 修完 7 项后 **74**，§10 第二轮后 **76**，§11 第三轮后
> **78**，§12 第四轮（清单配置维度 + 修正两处「输出正常但内容错」的解析缺陷）后
> **81**，§13 验证轮（NSC 真正展开 + 下载链修复）后 **82**，
> §14 第一档落地（sharedUserId / protectionLevel / 备份规则 / iOS entitlements）后 **84**，
> §15 第二档（签名方案 / WebView 桥 / 权限交叉核对 / iOS 组合规则）后 **86**，
> §16 第三档（原生库二进制加固 + 藏在 `lib/` 下的 DEX）后 **87**，
> §17 第四档（第三方服务类 SDK 盘点）后 **88**，
> §18 第五档（`Assets.car` 索引，不解像素）后 **89**。
> **§0 的表格是首轮基线，保留原样作为对照** —— 想看当前分数请看 §18.6。
>
> ⚠️ **§12.4(a) 的结论已被 §13.1 推翻**：那一节说「NSC 存在时不予判定」，
> 实测展开后那 3 个包确实允许明文 —— 原文保留并加了批注，不要照它实现。

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

## 12. 第四轮：清单配置类规则 —— 以及一个让前三轮结论部分作废的解析缺陷

新增 31 条测试，`flutter test` 1,377 → **1,408**（+14 skipped）。

### 12.1 三条新规则

清单层的三个经典缺陷此前**完全没被检查过**（`AndroidSecurityAudit` 只看权限、
代码线索与组件数）。它们的共同点是「完全可判定」：清单里写了就是写了。

| 规则 | 等级 | 判据 | 排除的误报 |
|---|---|---|---|
| `ANDROID-DEBUGGABLE` | **P1** | `android:debuggable="true"` | 未声明不报（平台默认 false） |
| `ANDROID-EXPORTED-COMPONENT` | P2（有 provider）/ P3 | `exported="true"` 且无 `android:permission` | 启动页（MAIN/LAUNCHER）必须导出，不报；`exported` 未声明不替平台猜默认值 |
| `ANDROID-ALLOW-BACKUP` | P3 | `android:allowBackup="true"` | 只报**显式** true；未声明时默认也是 true，但那样每个包都会报 |

### 12.2 真实样本验证暴露的根因：属性表 63 条里 51 条错位

规则写完、单测全绿之后，拿 5 个真实包跑了一遍：

```
=== 抖音-v40.7.0.apk ===
  debuggable=null allowBackup=null 组件=1891 导出=0 启动页=2
```

`导出=0` 在抖音上不可能。用 `aapt2` 独立核对：

```
$ aapt2 dump xmltree 抖音.apk --file AndroidManifest.xml | grep -c exported
642
```

于是查 `_kFrameworkAttrNames`。逐条比对 `aapt2 dump resources android-34/android.jar`
（1,545 条 attr 定义）后发现 **63 条里有 51 条 ID 对应错了名字**：

| 资源 ID | 我们表里写的 | aapt2 说的 |
|---|---|---|
| `0x0101000f` | `value` | **`debuggable`** |
| `0x01010010` | `resource` | **`exported`** |
| `0x01010018` | `debuggable` | **`authorities`** |
| `0x01010280` | `screenSize` | **`allowBackup`** |
| `0x010104ec` | `localeConfig` | **`usesCleartextTraffic`** |
| `0x01010527` 表里写 `0x010104d8` | `networkSecurityConfig` | `networkSecurityConfig` |

后果不是「少读一个字段」，而是**用错名字覆盖正确的名字**：
`_resolveStringOrResourceId` 是**表优先**的（因为混淆包会重写字符串池里的
属性名，而资源 ID 改不动）—— 表错了，就再也没有回退的机会。

**受影响的不只是这一轮的新规则**：`android:exported` / `debuggable` /
`allowBackup` / `usesCleartextTraffic` 在**所有真实包上都是 `null`**，也就是说：

- `RULE-D`（明文流量）**从上线起就在真实包上静默失效**；
- `AndroidComponent.exported` 恒为 `null`，组件导出情况从未被真正读取过
  （`AndroidComponent.permission` 是另一个属性，一直是好的）。

**为什么单测一直绿**：当时的用例都手工构造 `ApkMeta`，测的是「拿到一个
`bool` 之后规则怎么判」，而不是「这个 `bool` 能不能从字节里拿到」。
这是典型的自证循环 —— 期望值和实现共享同一个错误假设。

**修法**：

1. 表重写为 aapt2 权威值，并从 63 条**裁剪到解析器真正消费的 20 条** ——
   表里每多一条就多一条要守的错，而且会遮住字符串池回退。
2. 新增 `packages/apk_parser/test/fixtures/android_34_attrs.txt`（aapt2 输出的
   1,545 条快照，可复现），`framework_attr_names_test.dart` 逐条比对。
3. 新增 `test/fixtures/apk/attr-fixture.apk` —— 由 `aapt2 link` 真实产出的最小
   APK，走完整条「字节 → ApkMeta」链路，不再手工构造 `ApkMeta`。

### 12.3 第二个缺陷：每一个 `true` 都被读成 `false`

属性名读对之后，值还是错的：`debuggable: false`（应为 true）、
`exported: false`（应为 true）。

根因在 `_parseStartElement`：`tvData` 是 `readInt32()` 读的（**有符号**），
而 AXML 里 `true` 的规范编码是 `0xffffffff`，有符号即 `-1`。
`_resolveAttributeValue` 里写的是 `data == 0xffffffff` —— 永远不成立。

**这比「读不到」更糟**：读不到至少是 `null`，能被发现；读成 `false` 是一个
看起来很正常的具体值，没人会怀疑。改成平台侧的同一条判据
（`TypedData.getBoolean`：非 0 即真）。

### 12.4 修完之后新暴露的两个事实问题

属性一旦能读，规则就真的开火了 —— 于是两个此前不可见的问题立刻显形。

**(a) `RULE-D` 与 `networkSecurityConfig` 的优先级**

修完前两条之后，5 个真实包里 **4 个** `usesCleartextTraffic=true`，规则 D 以
**P1** 出现在 80% 的应用上。查 AOSP `ApplicationInfo`：API 24 起，
只要声明了 `android:networkSecurityConfig`，`usesCleartextTraffic` **就不再生效**。

于是当时的处理是：NSC 存在时这一维**不予判定**，覆盖率里单列一条
`android.cleartextPolicy`（partial + `android_cleartext_policy_unknown`）。

> **这一步走错了，§13.1 有完整记录。** 「属性被忽略」不等于「策略不成立」——
> 真正该做的是**打开那份 NSC**。展开后那 3 个包的
> `base-config cleartextTrafficPermitted="true"`，它们确实允许明文，
> 规则 D 原本就报得对；「不判定」反而会把这 3 个真发现静默吞掉。
> §13.1 已改为真正展开 NSC，证据也改为指向 NSC 文件而不是清单属性。

**(b) 导出组件列表刷屏**

抖音有 **159 个**导出且无 `android:permission` 的组件。全列出来是 6 KB 正文 +
159 行证据，读者只会跳过 —— 而「读者跳过」正是安全面板最该避免的结局。

改成：正文点名前 12 个（provider 优先，它最危险），明写「另有 N 个未列出」，
证据行上限 20。`count` 永远是真实总数，不缩水。

### 12.5 修复后的真实样本结果

| 样本 | debuggable | allowBackup | cleartext / NSC | 导出/未声明 | 触发 |
|---|---|---|---|---|---|
| `49af6cnn-1018.apk` | null | false | true / 无 | 17 / 6 | `EXPORTED-COMPONENT` **P2**（10 个）、`RULE-D-ESCALATED` **P1** |
| `app.apk` | null | false | null / 无 | 16 / 58 | `EXPORTED-COMPONENT` **P2**（11 个） |
| `抖音-v40.7.0.apk` | null | false | true / 有 | 195 / 1249 | `EXPORTED-COMPONENT` **P2**（159 个，点名 12 + 147） |
| `飞牛-v1.37.1.apk` | null | **true** | true / 有 | 11 / 47 | `EXPORTED-COMPONENT` P3（7）、`ALLOW-BACKUP` P3 |
| `飞牛TV-v1.4.1.apk` | null | false | true / 有 | 4 / 28 | `EXPORTED-COMPONENT` P3（2） |

`debuggable` 全为 `null` 是**正确**的：release 包不会声明它。

启动页排除也实测有效：飞牛TV 的启动页是 `SplashActivity`（被排除），
而 `MainActivity` 是另一个导出 activity（保留报告）—— 两者不是同一个组件。

### 12.6 对前三轮结论的影响

- 第 9–11 节的**能力扩展结论仍然成立**（那些规则读的是 DEX 字面量、权限、
  plist，与 AXML 属性表无关）。
- 但**凡是以 `usesCleartextTraffic` / `exported` / `debuggable` / `allowBackup`
  为前提的说法，在此之前的版本里都是未经验证的** —— 它们从未在真实包上读到值。
  本报告 §3 的实测表里没有这几项，正是因为当时读不到；现在补上了。
- 教训已经写进 `packages/apk_parser/lib/src/binary_xml.dart` 的注释与
  `framework_attr_names_test.dart` 的文件头：**框架属性 ID 只能从 android.jar
  取，不能凭印象写**；**期望值必须来自外部工具，不能从本项目的解析器取**。

### 12.7 评分影响

**78 → 81/100**：新增清单配置维度（3 条规则），同时修正了两处「输出看起来
正常但内容是错的」缺陷 —— 后者的价值高于前者，因为它影响的是**已有**结论的
可信度。

扣分项仍在：NSC 内容未展开（这一维现在明确标为「未判定」而非「已覆盖」）、
`Assets.car` 未实现、动态分析缺失。

## 13. 验证轮：把上一轮列的「未验证」逐项做掉（2026-10-18 深夜）

上一轮结尾列了五项没验证的东西。逐项做完的结果：**三项通过、一项部分通过、
一项做不到**，而且**抓到一个让真实下载 100% 失败的 bug**。

测试 1,408 → **1,430**。

| 项 | 结论 |
|---|---|
| NSC 的 XML 内容展开 | **做了**，并且**推翻了 §12.4(a) 的结论**（§13.1） |
| 界面目视 | **做到了**（换了条路，§13.2） |
| 真实 XAPK | **部分**：容器按规范自打、内层 APK 真实，但下载不到线上样本（§13.3） |
| 联网下载 | **做了**，抓到 `Content-Encoding` 缺陷，修复后端到端通过（§13.4） |
| Windows / Linux | **只能静态审计**，本机无法运行（§13.5） |

### 13.1 NSC 展开：上一轮的「不判定」是错的

上一轮的做法是「NSC 存在 → 明文策略不予判定」。理由是 `usesCleartextTraffic`
被平台忽略 —— 这一步推理没错，**结论错了**：属性被忽略不等于策略不成立，
真正该做的是**打开那份 XML**。

实现链路（三步都可能失败，每一步都记原因）：

```
android:networkSecurityConfig="@res/0x7f17001c"
  → ApkMeta.networkSecurityConfigResId          （从 @res/0x... 里取数字）
  → ArscParser.getFilePath(resId)               → res/8G.xml
  → archive.findFile(path) + ZipBudget.readEntry（有界读取）
  → BinaryXmlDecompressor.decompressToDocument  → NetworkSecurityConfigInfo
```

顺带补了 AXML 的**文本节点**：`<domain>api.example.com</domain>` 的域名在
`RES_XML_CDATA_TYPE` 里，而 `decompressToDocument` 此前是显式跳过 CDATA 的。
不补的话只能数出「有 2 条 domain-config」，说不出是哪两个域名。

真实样本复测（aapt2 独立核对过）：

| 样本 | NSC 路径 | base-config | 结论 |
|---|---|---|---|
| `抖音-v40.7.0.apk` | `r/7cm.xml`（资源混淆后的真实路径） | `cleartextTrafficPermitted=true` | **允许明文**，规则 D P1 正确 |
| `飞牛-v1.37.1.apk` | `res/8G.xml` | `true` | 同上 |
| `飞牛TV-v1.4.1.apk` | `res/8G.xml` | `true` | 同上 |
| `49af6cnn-1018.apk` | 无 NSC | — | 清单属性 `true`，规则 D P1 |
| `app.apk` | 无 NSC | — | 未声明，不报 |

**所以上一轮说的「3 个是事实错误」是错的** —— 它们本来就允许明文，
原来的报告是对的；如果按上一轮的「不判定」上线，这 3 个真发现会被静默吞掉。

改动：

- `AndroidRuleFacts.cleartextPolicy` 变成三态（`true` / `false` / `null`），
  优先级：NSC 已展开 → NSC 结论；NSC 声明了但没展开 → `null`；
  没有 NSC → 清单属性（未声明按「不主张允许」）。
- 证据指向**真正生效的那份配置**：有 NSC 时是
  `network security config (res/8G.xml) / base-config`，并新增
  `SecurityEvidenceSource.networkSecurityConfig`（否则界面上会打
  「AndroidManifest.xml」的标签，而证据行写的是 `res/8G.xml`，自相矛盾）。
- 规则 D 正文改成**来源中立**（「应用允许明文（非 TLS）流量」），
  哪儿写的由证据行回答 —— 两个来源各写一套文案会多出两个键和两条死键风险。
- 新增夹具 `nsc-fixture.apk`（aapt2 真实产出，base 禁止 + 域名放行），
  钉住 base/domain 的覆盖关系与域名文本。

### 13.2 界面目视：`toImage()` 跑不了，改走 web + 无头 Chrome

`RepaintBoundary.toImage()` 在本机**会让整个测试进程被 SIGKILL**（退出码 137，
连 `loading ...` 都不打印，关掉工具沙箱也一样）。对照实验：纯 widget 测试通过、
只取 `boundary.size` 通过、加一行 `toImage` 就死。

可行的替代：临时 Flutter web 工程（路径依赖本仓库）→ `flutter build web` →
`python3 -m http.server` → Chrome `--headless=new --screenshot`。
完整步骤与症状记在 `docs/notes/ui-snapshot.md`。

看到的东西（920px 宽，中文）：

- **抖音的导出组件卡片**：正文 12 个名字 + 「另有 147 个未列出」，约 10 行 ——
  截断生效，没有刷屏成 6 KB。
- **规则 D**：P1/P2 卡片正文都是中文，没有英文回退。
- **覆盖率面板**：出现「明文流量策略 1/1」，没有露出 `android.cleartextPolicy`
  这种机器 id。
- 三种夹具都没有溢出、没有竖排文字。

### 13.3 真实 XAPK：只做到「部分」

APKPure 的下载端点对非浏览器客户端一律 **403**（带浏览器 UA、带 Referer 都一样），
所以没能下载到一个线上 XAPK。

退一步：**容器按公开规范自己打，内层 APK 用 `aapt2` 真实产出**
（`aapt2 link --split` 生成 base + config split）。`manifest.json` 里刻意把
同一个分包列两次 —— 真实打包器合并脚本时很常见。

验证到的：`getSplitApks` 返回 **2** 条（去重生效）、返回的是**归档条目名**
而不是解包路径、两条都能被 `ApkReader` 解析（base 有 package/versionCode/
启动页，config split 没有应用级字段）。

**没验证到的**：真实 APKPure 打包器的边角字段、obb 展开、真机 `adb
install-multiple`。这部分仍然是空的。

### 13.4 联网下载：抓到 `Content-Encoding` 缺陷（本轮最值钱的一条）

第一次真的联网跑 `downloadDependencies`，build-tools **100% 失败**：

```
incomplete download: got 81933386 of 81667633 bytes
  from https://dl.google.com/android/repository/build-tools_r37_macosx.zip
```

收到的比声明的**多** 265,753 字节。根因：`HttpClient` 默认
`autoUncompress: true`，`Content-Length` 是**编码后**长度，而响应流给的是
**解码后**字节。于是「收到的 != 声明的」这条完整性检查把每一次正常下载都判成
传输中断。同一个原因还让索引下载的进度变成 **946%**
（`repository2-3.xml`：声明 44,547，实际 421,568）。

修法：

- 完整性检查只在 `compressionState == notCompressed` 时比字节数。
  真正的完整性由 `verifyArchiveChecksum`（SHA1）保证，那才是不可绕过的。
- 进度分母在编码过的响应上报 0（不定长），不再算出 >100%。

修复后真实下载通过：

```
[INFO] download repository index ok: https://dl.google.com/.../repository2-3.xml
[INFO] download archive ok: https://dl.google.com/.../build-tools_r37_macosx.zip
[INFO] checksum verified (SHA1): build-tools_r37_macosx.zip
DONE in 4490ms buildTools=37.0.0
aapt2=.../build-tools/37.0.0/aapt2 exists=true
aapt2 version exit=0
temp leftovers=[]            ← 临时目录清理生效
```

新增 `test/tool_download_encoding_test.dart`（2 条），用本地 gzip 服务复现；
**已验证这两条在旧实现下变红**（`incomplete download: got 332 of 203 bytes`）。

为什么以前没发现：所有下载测试都用本地 `file://`，这条分支一次都没走到。
这是「测试全绿但功能是坏的」的第三个实例（前两个是属性表与布尔值）。

### 13.5 Windows / Linux：只能静态审计

本机跑不了这两个平台的产物（`flutter build windows/linux` 只支持各自主机）。
能做的是：

- **CI 覆盖**：`build.yml` 有 `build-windows`（windows-latest）与
  `build-linux`（ubuntu-latest）两个 job，编译与打包在 CI 上有保障。
- **平台分支逐项核对**：`.exe` / `.bat` 后缀（`ToolPaths`、`command_tools`、
  `setting_page` 三处一致）、`PATH` 分隔符与 `PATHEXT` 查找、
  `chmod +x` 由 `!Platform.isWindows` 挡住、`explorer.exe` / `open` /
  `xdg-open` 三个分支齐全。
- **本轮新增代码的平台无关性**：NSC 展开用的路径来自 `resources.arsc`
  里的条目名（`/` 分隔），只用于 `archive.findFile`，**从不落到文件系统**，
  因此不受平台路径分隔符影响。

**没验证到的**：真机运行、文件关联注册、安装对话框里的 `adb` 调用。
这三项在 CI 上也只覆盖到「能编译」。

### 13.6 评分影响

**81 → 82/100**。加分来自「NSC 真的展开了」（把上一轮的一个假阴性风险消除），
以及下载链路的可用性修复。扣分项不变的部分：动态分析缺失、`Assets.car` 未实现、
真实 XAPK 与真机安装仍未验证。

> 这一轮的方法论收获比分数重要：**五个「未验证」里，两个一验就发现了真缺陷**
> （NSC 的结论是反的、下载 100% 失败），而它们都通过全绿的门禁。
> 「测试全绿」证明的只是「已写下的断言成立」，不证明「没写的那部分对」。

## 14. 第一档落地：把「数据已经在手但没人读」的四项接上

测试 1,430 → **1,456**。评分 **82 → 84**。

上一轮盘点出的第一档四项全部做完。**四项里有三项不是「缺功能」，而是
「数据解析出来了但没人消费」** —— 这类缺口的成本极低，但对结论的影响直接。

| 缺口 | 数据在哪 | 此前的错误结论 |
|---|---|---|
| `android:sharedUserId` | AXML（属性 id `0x0101000b`） | 共享沙箱完全不可见 |
| `android:protectionLevel` | AXML（`0x01010009`） | 写了 `android:permission` 就当受保护 |
| `fullBackupContent` / `dataExtractionRules` | AXML（`0x010104eb` / `0x0101063e`） | `allowBackup="true"` 就说整包可被备份 |
| iOS `get-task-allow` | `IosProvisioningProfile.entitlements` | iOS 侧没有 debuggable 这条规则 |

### 14.1 `protectionLevel`：不是新规则，是修正一条**误判**

`ANDROID-EXPORTED-COMPONENT` 此前的判据是「`android:permission` 非空 = 受保护」。
这条判据在 `normal` / `dangerous` 级自定义权限上**是错的** —— 任何应用都能
申请到这类权限（`dangerous` 只是要用户点一下同意），等于没有保护。

现在的判据：

1. 无 `android:permission` → 未保护；
2. `android:permission` 指向**本包 `<permission>` 声明**且
   `protectionLevel` 的 base 位 < 2（`normal` / `dangerous`）→ **仍未保护**；
3. 框架权限（`android.permission.*`）与别包声明的权限 → 看不到级别，
   **保守当成受保护**。

第 3 条是刻意的：猜错的方向必须偏向「不误报」。

正文措辞随之分叉 —— 有弱权限组件时用 `without an effective
android:permission guard`（`android.exported_component_weak[_many]`），
否则沿用原文案。否则正文说「没有 permission」而那个组件明明写着 permission，
读者会认为工具在乱报。

**真实样本的第一个实例**：抖音有 2 个导出 receiver
（`CardLifecycleReceiver` / `CardProjectStatusReceiver`）只由
`com.ss.android.ugc.aweme.permission.sendXiaoYiCardInfo` 保护，而这条权限
**没有声明 `protectionLevel`**（平台默认 `normal`）—— 任何应用都能申请。
导出组件计数 159 → **161**。

### 14.2 又一个「正文说了、证据里看不到」

证据上限 20 条，按类型排序（provider → service → receiver → activity）。
抖音那 2 个弱权限组件是 receiver，排在 activity 之前但整体仍在 161 个里靠后，
正好被挤出上限 —— 结果是正文说「effective guard」，20 条证据却全写着
「without android:permission」。

修法：**弱权限证据优先列**。原则是「正文声称了什么，证据里就必须有对应的一条」。

### 14.3 `protectionLevel` 是整数，不是字符串

`aapt2 dump xmltree` 显示 `protectionLevel(0x01010009)=0x00000002` ——
AXML 里存的是**整数标志位**。按字符串找 `"signature"` 永远找不到。

这是本项目第三次踩「值读到了但形态不对」：

| 次序 | 形态问题 | 后果 |
|---|---|---|
| 1 | 属性表 51/63 条 ID 错位 | 四个安全属性全读不到 |
| 2 | `true` = `0xffffffff`，被 `readInt32` 读成 `-1` | 每个 `true` 变 `false` |
| 3 | `protectionLevel` 是 int 不是 string | 新规则**永不生效** |

三次的共同点：**解析出了值，但比对时用的形态与真实形态不一致**。
现在的做法是解析层直接给出 `protectionLevelValue`（按位）与
`protectionLevelText`（`signature|privileged` 这种可读形态），
上层不再碰原始字符串。

### 14.4 备份规则：一条**事实上不成立**的发现

`allowBackup="true"` 与「数据真的会被备份」不是一回事：

- `fullBackupContent="false"`（API 23–30）→ 备份彻底关闭；
- `dataExtractionRules="false"`（API 31+）→ 同上；
- 两者指向一份 XML → 有例外清单，但具体排除了什么我们没展开。

现在：前两种**不报**；第三种照报，但把规则文件列进证据。

顺带修了一个措辞问题：实测飞牛写了 `fullBackupContent="true"` ——
这**不是这个属性的合法值**（合法值是 `false` 或一份 XML 资源）。
原先把任何非 `false` 的值都当「有规则清单」列出来，等于替平台解释了一个
无效值。现在只列 `@res/` 引用形态。

### 14.5 iOS：`get-task-allow` 补上两侧的不对称

`IosProvisioningProfile.entitlements` 从 V2.4.9 起就解析好了，
但 `security/` 下**零消费**。现在：

- **`IOS-GET-TASK-ALLOW`（P1）**：调试器可附加进程、读内存、替换代码。
  只认**布尔 true** —— `PlistString('true')` 不是平台写的形态，当成「读不懂」。
- **`IOS-PUSH-SANDBOX`（P3）**：`aps-environment="development"`。

**刻意不报** `keychain-access-groups` / `application-groups` /
`associated-domains`：正常应用里极其常见，一律报会让读者学会忽略整个面板 ——
而「读者忽略」比「漏报一条」更糟。

覆盖率新增 `ios.entitlements`：没有 `embedded.mobileprovision`
（App Store 分发把授权项放在签名里）时标 **notApplicable** 并说明原因。
「没看到」不能说成「已覆盖、没问题」。

### 14.6 真实样本复测

| 样本 | sharedUserId | 自定义权限 | 导出组件 | allowBackup |
|---|---|---|---|---|
| `49af6cnn-1018` | 无 | 3 条（3 条 signature） | 10 | 不报（`allowBackup=false`） |
| `app.apk` | 无 | 5 条（5 条 signature） | 11 | 不报 |
| `抖音-v40.7.0` | 无 | 19 条（18 条 signature，1 条默认 normal） | **161**（含 2 条弱权限） | 不报 |
| `飞牛-v1.37.1` | 无 | 1 条（signature） | 7 | 报，证据含规则文件 |
| `飞牛TV-v1.4.1` | 无 | — | 2 | 不报 |

`sharedUserId` 在这 5 个包里都没出现 —— 符合预期（该属性自 Android 10 起
已废弃，现代应用基本不用）。

### 14.7 评分影响

**82 → 84/100**。加分主要来自 `protectionLevel` 那条 —— 它不是新增能力，
而是**修正了一条会产生错误结论的判据**（把「有 permission」当成「受保护」）。

剩余的第一档之外缺口不变：签名方案 v2/v3、WebView/JS 桥、
权限与 API 的交叉核对、iOS 侧缺「敏感来源 + 上传」组合规则、
原生库二进制加固属性、`Assets.car`、SDK 盘点。

## 15. 第二档：签名方案、WebView 桥、权限交叉核对、iOS 组合规则

测试 1,456 → **1,491**。评分 **84 → 86**。

### 15.1 APK Signing Block：回答一个此前答不了的问题

签名结论此前**完全**交给 `apksigner`。两个后果：

1. 没装工具就一律「未验证」—— 但「有没有签名」是纯结构，能自己答；
2. 看不出「**只有 v1 签名**」。

第 2 点不是学术问题。v1（JAR 签名）只保护 ZIP **条目内容**的摘要，
**不保护 ZIP 结构** —— 往归档里塞入额外条目（额外的 dex / 资源 / so）
不会让 v1 失效。那是重打包最省事的形态。v2+ 把整份归档的摘要放进签名块，
塞条目就会失效。

实现：EOCD → 中央目录偏移 → 往前 24 字节校验 `APK Sig Block 42` →
按 pair 读 id。

```
[size:8][pairs][size:8][magic:16]      整块长度 = size + 8
每个 pair: [len:8][id:4][value: len-4]
```

**三次大小校验**，都不允许不可信长度决定内存分配：

| 校验 | 拒绝什么 |
|---|---|
| `declared < 24` | 明显不可能的声明 |
| `declared > 16 MiB` | 伪造的超大长度（实测能拦住改成 `0x7fffffff` 的包） |
| 头尾两个 size 不一致 | 长度被篡改 |

与 apksigner 逐条一致（5 个真实包 + 3 个夹具）。

**最重要的一条状态区分**：`parsed == false`（读不出）**绝不**折成
`v1Only`。`signed-unsigned.apk` 这个夹具就是为此存在的 —— 它证明
「没有签名块」这一个结构事实**无法**区分「v1 签名」与「完全没签名」，
要区分只有 apksigner 能做。这条边界写进了规则的 limitation。

### 15.2 WebView 桥：一次**被真实样本否掉的分级**

`addJavascriptInterface` 是 Android 最经典的 RCE 面，我一开始给了 P2。
真实样本立刻否掉了这个判断：

| 样本 | 命中 | 调用点来自 |
|---|---|---|
| `49af6cnn` | ✓ | Adjust、极验 Geetest、hCaptcha、神策 |
| `app.apk` | ✓ | 极光推送、Facebook AppEvents、网易易盾 |
| `抖音` | ✓ | 字节 webx / 小程序容器 |
| `飞牛` | ✓ | flutter_inappwebview 插件 |
| `飞牛TV` | ✗ | — |

**5 个包命中 4 个，调用点全部来自第三方 SDK，没有一个是应用自己写的。**
验证码、统计、社交分享这类 SDK 必须用 JS 桥才能工作 —— 它几乎是现代应用
的标配。P2 等于在 80% 的应用上出现，与 RULE-D 是同一类错误。

改成 P3，并且**正文与 limitation 都要说清**「多数来自第三方 SDK，
先看证据里的调用点」。这是这一轮唯一一次「写完之后被数据推翻」——
记录在这里，因为它比任何一条新规则都更有信息量。

### 15.3 权限 vs API：两处修正，一处新规则

iOS 早就有 `IOS-USAGE-WITHOUT-API`（声明了没用），Android 侧没有对应物。
新增 `ANDROID-PERMISSION-WITHOUT-API`（P3），但只对**判据明确**的权限做：

| 权限 | 代码证据 | 编目？ |
|---|---|---|
| `READ_CONTACTS` | `ContactsContract` | ✓ 必然要碰 |
| `READ_SMS` | `SmsManager` | ✓ |
| `ACCESS_FINE_LOCATION` | `LocationManager` | ✓ |
| `RECORD_AUDIO` | `MediaRecorder` **或** `AudioRecord` | ✓ 两个入口 |
| `WRITE_EXTERNAL_STORAGE` | 可能只走 `java.io.File` | ✗ **不编目** |

两道闸：**没扫过 DEX 就不判**（「没看到」不是「没有」）；`sdk23Only` 的
声明不参与（生效条件无法静态判定）。

顺带修了一个**既有误判**：`RECORD_AUDIO` 的代码证据此前只认
`MediaRecorder`，用 `AudioRecord` 直读 PCM 的应用会被判成「声明了没用」。

真实样本抓到 1 例：抖音声明了 `READ_CONTACTS`，40 个 DEX 里没有
`ContactsContract` 的任何引用。

### 15.4 iOS：补上缺的那条组合规则

Android 有 `ANDROID-RULE-G`，iOS 只有 A/B/C/E/F。新增 `IOS-RULE-G`，
分级按来源稀有度：

| 来源 | 等级 | 理由 |
|---|---|---|
| 通讯录 / 麦克风 | **P2** | 正常应用里「读这些 + 上传」并不常见 |
| 只有定位 | **P3**（`-COMMON`） | 几乎每个应用都有定位，P2 会让规则在九成应用上出现 |

三条规则各自成立、不合并：C 是图片链、E 要后台、G 只要两段。

### 15.5 评分影响

**84 → 86/100**。加分来自：

- 签名方案维度（此前完全空白，且 v1-only 是重打包的关键结构信号）；
- Android 侧补齐了「声明 vs 实现」的反向检查；
- iOS 补齐了组合规则的最后一块。

扣分项不变：动态分析缺失、`Assets.car` 未实现、原生库二进制加固属性未读、
SDK/追踪器盘点未做、真机验证没有。

## 16. 第三档：原生库二进制加固 —— 以及一个只在真实包上才看得见的发现

测试 1,491 → **1,520**。评分 **86 → 87**。

### 16.1 先量了一下，再决定报什么

这一档本来可以做成「5 条新规则」（NX / RELRO / BIND_NOW / canary / strip）。
先拿真实样本量了一遍 —— 4 个包的 **386 个** arm64 `.so`，逐个用
`llvm-readelf` 数：

| 属性 | 不满足的库数 |
|---|---|
| 可执行栈 | **0** |
| 缺 RELRO | **1**（Flutter 的 `libapp.so`）|
| 缺 BIND_NOW | **1**（同一个）|
| 未 strip | **0** |

NDK 默认就带 `-z relro -z now` 与 NX 栈。所以：

- 如果按「5 条规则」实现，真实包上的输出会是「386 条已加固」+ 1 条噪声；
- **那唯一 1 条噪声会命中所有 Flutter 应用** —— 而 Flutter 是常见技术栈。

最终只做**一条**规则：`ANDROID-NATIVE-EXEC-STACK`（P2）。没有哪种正常构建
需要可执行栈，出现即缺陷。其余属性进**覆盖率的数字**：

> 原生库加固 385/386 —— 1 个库缺少 RELRO（合法的构建选择，未作为发现报出）

这比「386 条已加固」有用得多，也比「静默不报」诚实得多。

### 16.2 三个二进制细节，每一个错了都不报错

| 细节 | 错法 | 后果 |
|---|---|---|
| `p_flags` 的位置 | 64 位在偏移 4，**32 位在偏移 24** | 读到 `p_offset`，一个看起来完全合理的地址值 |
| `DT_FLAGS` vs `DT_FLAGS_1` | 只查一个 | 另一种链接器版本写的标记读不到 |
| `.symtab` vs `.dynsym` | 用 `.symtab` 查栈保护 | strip 之后就永远查不到 |

第二条我自己也差点写错（只想查 `DT_FLAGS` 的 `BIND_NOW`）。

### 16.3 一个反例夹具，专门防「absence = 没开」

`hardening-default.so` 与 `hardening-canary.so` 是**同一份源码、同一套默认
flags**，唯一区别是后者显式加了 `-fstack-protector-all`。

结果：`hardening-default` **没有**导入 `__stack_chk_fail`。

所以「没有这个符号」不能读成「没开栈保护」—— 没有函数触发 canary 时这个符号
根本不会出现在 `.dynsym` 里。这条写进了测试名和注释，也写进了 README。

### 16.4 顺带抓到的：`lib/` 下藏着的 DEX

排查「为什么有 1 个库读不出」时看到的：

```
lib/arm64-v8a/libsm_impl.so   162,912 字节
00000000: 6465 780a 3033 3500   → "dex\n035"
```

**它不是 ELF，是一段 DEX 字节码。** 名字完全合规（`lib*.so`、在
`lib/arm64-v8a/` 下、以 `lib` 开头），所以：

- `unusualNativeLibraryName`（查命名）发现不了它；
- 只扫 `classes*.dex` 的工具完全看不到这段代码。

新增信号 `HardeningSignal.dexDisguisedAsNativeLibrary`（`strong` 级），
与既有的 `dexHeaderNotStandard` 是**反向**的两件事：

| 信号 | 含义 |
|---|---|
| `dexHeaderNotStandard` | 文件名像 DEX，内容不是 |
| `dexDisguisedAsNativeLibrary` | 文件名像原生库，**内容是 DEX** |

这是这一档唯一的「新检测」，而它不是设计出来的 —— 是读不出来的那 1 个库
逼出来的。**「读不出」这个状态本身携带信息**，如果当时按「跳过错过的库」处理，
它就永远看不见。

### 16.5 覆盖率口径

`android.nativeHardening` 的 `limit` 用**真正解析成功的库数**，不是传进来的
条目数 —— 与 `android.nativeSymbols` 同一个口径问题：用后者会把读不出的库
算成「已加固」。

有测试钉住这一条：一个正常库 + 一个不是 ELF 的「库」→ `covered=1, limit=1`。

### 16.6 评分影响

**86 → 87/100**。加分不多，因为这一维在真实包上确实几乎全绿；但补上它是必要的
—— `ElfHardening` 这个能力此前完全空白，而「有没有可执行栈」是唯一无法用
别的方式回答的问题。

剩下的第三档两项：`Assets.car`（图标提取）、SDK / 追踪器盘点。

## 17. 第四档：第三方服务类 SDK 盘点 —— 以及一次「在最需要它的包上返回 0」的返工

测试 1,520 → 1,520（新增 24 条在 `apk_parser` 包内）。评分 **87 → 88**。

### 17.1 先量，再决定收哪些前缀

这一档最容易做错的地方是「凭印象列一堆 SDK 前缀」。所以先拿 60 个候选在
4 个真实包（86 DEX / 431 MiB）上量了一遍：

| 前缀 | 4 个包里的命中数 |
|---|---|
| `okhttp3` | **4** |
| `com/google/gson` | **4** |
| `com/google/android/material` | **4** |
| `com/airbnb/lottie` | **4** |
| `com/geetest` | 1 |
| `com/hcaptcha` | 1 |
| `com/sensorsdata` | 1 |
| `com/tencent/bugly` | 1 |

前四个是**基础工具库**：HTTP 客户端、JSON、UI 组件、动画。它们在几乎每个
应用里都有 —— 列出来等于「每个应用都用了第三方库」，一句废话。

所以目录只收**有服务含义**的 24 个：统计归因 / 推送 / 验证码风控 /
社交登录 / 地图 / 崩溃上报 / 对象存储 / RTC。它们共同的特征是
**会把数据发到第三方服务器**，而「这个应用的数据会去哪」才是用户想知道的事。

### 17.2 返工：`string_ids` 取代字节扫描

第一版复用 `DexClueScanner`（暴力扫全部字节，单 DEX 8 MiB、总计 48 MiB）。
真实样本立刻打脸：**抖音 55 个 DEX 命中 0 个**，而直接搜原始字节能找到
175 次 `com/tencent/mm/opensdk`。

先量成本，才看清不是阈值问题：

| `maxTotalBytes` | 耗时 | 命中的服务类 SDK |
|---|---|---|
| 48 MiB（生产默认） | 1.9 s | **0 个** |
| 128 MiB | 5.2 s | 2 个 |
| 512 MiB | 14.4 s | 3 个 |

**是位置问题**：DEX 的 `string_data` 在文件后半部分
（头 → id 表 → class_defs → data），单文件 8 MiB 的上限把它整段截掉了。
抖音的 DEX 平均就有 8 MiB —— **在最需要这个功能的包上，它返回 0。**

改成按 `string_ids` 精确索引（`SdkInventoryScanner`）：读 DEX 头的
`string_ids_size` / `string_ids_off`，按每个 `string_id_item` 的 4 字节偏移
跳到 `string_data_item` 读前缀 —— 不需要扫全部字节，也不受字符串位置影响。

| 包 | 修复前 | 修复后 |
|---|---|---|
| 49af6cnn | 5 个 | **8 个**（6/6 DEX）|
| app.apk | 7 个 | **8 个**（5/5）|
| 抖音 | **0 个** | **5 个**（40/40）|
| 飞牛 | 1 个 | **2 个**（3/3）|

### 17.3 顺带修正一处分类

`Google Play services` 与 `Firebase` 原本归在 `analytics`。它们是**一组**
API（地图 / 认证 / 推送 / Analytics），不是「一个分析 SDK」——
实测 49af6cnn 里 `gms` 有 4,276 个类，归到 analytics 会让「分析 SDK」那一栏
永远排第一，盖住读者真正想看的 Adjust（211 个）。新增 `platform` 类别。

### 17.4 判据与边界

- **阈值 20 条引用**：真打包的 SDK 是几百到几千，配置字符串里提一句的是个位数；
- **边界必须精确**：`L<prefix>/` 或 `L<prefix>;` —— 否则 `com/tencent/mm`
  会吃掉 `com/tencent/mmkv`；
- **info 级 + independentCapability**：清单，不是风险结论；
- **目录里没有单段前缀**：`okhttp3` 这种没有 `/` 的前缀会把整片包名卷进来，
  有测试守着这一条。

### 17.5 覆盖率

新增 `android.sdkInventory`：`covered` / `limit` 用**真正读到的 DEX 数**，
`complete` 要求「没有读不出、没有截断」。实测抖音 40/40、飞牛 3/3。

这条覆盖率和 `android.dex.strings` **是两个不同的预算**（8 MiB/文件 vs
64 MiB/文件），因为两者服务的目不同 —— 前者要「找线索」，后者要「点清单」。
分开报才是诚实的。

### 17.6 评分影响

**87 → 88/100**。`SecurityCategory.thirdPartySdk` 这个类别在 Android 侧
从「零产出」变成了有实质内容的一维。

剩下的唯一一项是 `Assets.car`（iOS 图标提取）—— 它不属于安全分析，
是「包详情」的能力，且需要写一个 Apple 私有格式的解析器。

## 18. 第五档：`Assets.car` 索引 —— 能列出图，但不提像素

`ipa_parser` 54 → **74** 条测试。评分 **88 → 89**。

### 18.1 先确认「能验证到什么程度」，再定范围

`Assets.car` 是 Apple 私有格式，没有公开文档。开工前先查了两件事：

1. **有没有独立实现能核对？** 有 —— macOS 自带 `/usr/bin/assetutil --info`
   输出 JSON，含 `PixelWidth` / `PixelHeight` / `Encoding` / `SizeOnDisk` /
   `RenditionName`。这正好覆盖索引需要给出的每个字段。
2. **有没有工具能导出图？** **没有。** `assetutil --output` 是「清理废弃
   资产」，不是导出。

第 1 条让「做索引」可行；第 2 条决定了「做提取」要靠自己写解码器。

然后量了 5 个系统 `Assets.car` 的编码分布：**一个 PNG/JPEG 都没有**，
全是 ARGB/BGRA 原始像素**再经 LZFSE 压缩**（块内 `bvx2`）。1024×1024 图标
未压缩 4,194,304 字节、`SizeOnDisk` 311,137（13.5:1）。

所以范围定为：**做索引，不做解码**。这也是用户选的方向。

### 18.2 四个实测踩过的坑

| 坑 | 症状 | 正确做法 |
|---|---|---|
| **端序混用** | `RATC` 的版本读成 285212672 / 4077060096 | `BOMStore` 头与块表**大端**；`RATC` 与 `ISTC` 头**小端** |
| **块表条目数** | 按 `indexOffset` 处的 u32 读得 256，而真实块数 23/87 | 用头里的 `blockCount`；`indexOffset + 4` 起每 8 字节一条 |
| **4CC 反序** | 文件里 `BGRA`、`GA8 `、` 8AG` 看起来像乱码 | 反序后才是 `ARGB`、`GA8 `（与 assetutil 的 `Encoding` 一致）|
| **空壳 rendition** | 宽高齐全但块只 334 字节、内容全 0 | `embedsPixels`：压缩过 → 有；未压缩 → 块要装得下 `w×h` 字节 |

第二条是靠**自洽性约束**反解出来的：试了 `delta ∈ {0,4,8}` ×
`stride ∈ {8,12}` 六种布局，只有 `delta=4, stride=8` 能给出
「条目数 == blockCount」。

第四条是读 `assetutil` 输出时发现的：`SizeOnDisk: 334` 出现成千上万次
（Music.app 有 5,694 个）。实测这些块体全是 0 —— 它们是引用/占位，没有像素。
不区分的话，「有 6592 张图」这个数字里绝大多数是空的。

### 18.3 期望值只能是 assetutil

这是本项目一贯的做法，但在私有格式上尤其关键：任何「按我理解的字段偏移」
都必须拿独立实现核对，否则就是自证。

夹具 `test/fixtures/car/installer-progress.car` 是系统真实产物
（`/System/Library/CoreServices/Installer Progress.app`，18 KB、4 张图），
README 里存了 `assetutil --info` 的完整原始输出。

逐条对照结果：

| assetutil | 本项目 |
|---|---|
| `StorageVersion: 17` / `CoreUIVersion: 1011` | ✓ |
| `LowBatteryEmpty` 173×72 Gray 857B | ✓ `GA8 ` 857B |
| `LowBatteryEmpty@2x` 346×144 Gray 1332B | ✓ `GA8 ` 1332B |
| `LowBatteryFlashing` 30×72 ARGB 739B | ✓ `ARGB` 739B（空壳）|
| `LowBatteryFlashing@2x` 60×144 ARGB 1155B | ✓ `ARGB` 1155B |

### 18.4 措辞升级：从「需要解析器」到「里面有什么」

`IpaIconResolver` 原来对 `CFBundleIconName` 只说：

> the icon lives inside Assets.car, which needs an asset-catalog parser;
> it cannot be previewed directly

现在真的读一遍容器：

> the icon lives inside Assets.car: 3 image(s) with pixel data, but none is
> named like AppIcon, so the asset for CFBundleIconName=AppIcon cannot be
> identified without parsing the RENDITIONS index. **The pixel data is
> LZFSE-compressed in any case, so it could not be previewed without a
> decoder either**

差别不只是信息量：「需要一个解析器」是**我们的实现状态**，而
「像素被 LZFSE 压缩了」是**这个文件的客观事实**。后者才是用户能据此判断的。

三种状态严格分开：解析成功 / 索引解析失败 / 容器读不出。混成一句就会分不清
「没有图」与「我们没读到」。

### 18.5 还没做的

| 项 | 理由 |
|---|---|
| 资产名（`AppIcon` / `AppIcon_Assets/...`） | 要解析 `RENDITIONS` 的 CPI key，其字段布局随 `StorageVersion` 变且无文档 |
| 提取像素 | 需 LZFSE 解码器（500–700 行）+ PNG 编码器（~200 行） |

**验证办法是有的**：macOS 有 `libcompression`，可以写个小 C 程序用
`COMPRESSION_LZFSE` 压缩一段已知数据生成夹具，期望值就是原始字节 ——
不必自证。这条路没走，但记在 `docs/notes/assets-car.md` 里了。

### 18.6 评分影响

**88 → 89/100**。补上了 `Assets.car` 这个「全仓 0 处实现」的空白，但只到
索引层 —— 图标预览仍然要裸 PNG。加分有限是应该的。

## 19. 第六档：LZFSE 解码 —— 纯 Dart 实现，与 Apple 逐字节一致

`ipa_parser` 74 → **98** 条测试（+24）。评分 **89 → 91**。

§18.5 写了两条「还没做的」，第二条是「提取像素：需 LZFSE 解码器
（500–700 行）+ PNG 编码器（~200 行）」。这一档把它做完，**没有引入任何新依赖**。

### 19.1 先建验证手段，再写解码器

§18.5 末尾留了一句：「macOS 有 `libcompression`，可以写个小 C 程序用
`COMPRESSION_LZFSE` 压缩已知数据生成夹具，期望值就是原始字节 —— 不必自证。」

这一档就是照这条走的。`test/fixtures/lzfse/make_fixtures.c` 是个 40 行的 CLI，
只调 `compression_encode_buffer`；6 个夹具全部由系统库真实压缩产出：

| 夹具 | 原始 | 压缩后 | 刻意覆盖的路径 |
|---|---:|---:|---|
| `empty` | 0 | 12 | 只有 `bvx$` 结束块 |
| `zeros` | 8,192 | 151 | 54:1；M 值取到上限 2359 |
| `repeated-text` | 9,000 | 213 | 常规匹配 |
| `incompressible` | 4,096 | 4,327 | 走 `bvx-` 未压缩块（输出比输入大）|
| `pixel-like` | 16,896 | 13,940 | 类 BGRA 像素：渐变 + 少量噪声 |
| `multi-block` | 95,105 | 11,982 | **多块，且回溯跨块** |

于是「解码 `.lzfse` 得到 `.bin`」这条断言的含义是：
**我们的纯 Dart 实现与 Apple 自己的实现逐字节一致**。这比「解出来看着像图」
强得多，而且是可复现的（随机数据用固定种子）。

再往上还有一层验证：同一套解码器解过 `Chess.app` 的 1024×1024 图标
（3 个块、**2,086,192 字节**），与 Apple 开源参考实现
[`lzfse`](https://github.com/lzfse/lzfse) 编成的 CLI 输出比对 —— **IDENTICAL**。
样本 2 MB，不入库。

### 19.2 最贵的一个 bug：回溯距离是整个输出流的

我最初按「一个块一个输出缓冲区」实现，块内偏移各算各的。6 个小夹具里有
`multi-block` 也全绿 —— 因为那个夹具的块间回溯恰好没触发。

一到真实图标就崩在第二块：

```
L=4  D=12339  at  dst_off=1805271     ← 距第一块起点已 1.0 MB
```

`D=12339` 指向的是**上一块已经解出来的字节**。LZFSE 的匹配距离是全流距离，
不是块内距离。改成单块共享输出缓冲区、`dst` 用全流绝对偏移后，才与参考实现
逐字节一致。

这个 bug 的形状值得单列：**「小样本全绿」在这里不是覆盖率不够，是结构假设错了**。
所以 `multi-block` 那个夹具从「可选」变成「必须有」。

### 19.3 两个格式事实

两处都写在 `test/fixtures/lzfse/README.md` 里，因为它们**没有文档可查**、
而且错了都不一定立刻看出来：

1. **`packed_fields` 在偏移 8**（`u32 magic` + `u32 n_raw_bytes` 之后，结构体是
   packed）。按 12 算会读出 `header_size=1095911234` 这种值 —— 用
   「`header_size + litpay + lmdpay` 必须等于块长」这条约束反解才确认唯一解。
2. **`bvx$` 只有 4 字节**，没有附加的长度字段。当成 8 字节会让所有末尾块的
   对齐判断错位。

顺带确认：**FSE 频率表在流内**，不是外挂参数。这一点是从 `litpay` 的消耗量
对齐反推出来的。

### 19.4 通道顺序是让 CoreGraphics 说的，不是查文档查的

`ARGB` 这个名字按字面理解会得到 B、G、R、A 的顺序 —— **是相反的**。
正确顺序是内存字节 `B,G,R,A`。

验证办法不是抄文档，是让系统自己解释：用
`kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little` 从一个已知字节
序列构造 `CGImage`，再画进标准 RGBA 上下文读回。

| 输入字节 | 读回 | 结论 |
|---|---|---|
| `[10, 20, 30, 255]` | `[30, 20, 10, 255]` | byte0 = **B**（`[2,1,0,3]`） |
| `[77, 200]`（`GA8 `） | `[77, 77, 77, 200]` | byte0 = 灰度（`[0,1]`） |

为什么值得专门验证：**顺序错了代码照样跑、照样出图**，只是红蓝互换 ——
在多数图标上肉眼看不出来。这类「静默错误」比崩溃危险。

### 19.5 明确报出来的边界

**不是每个 rendition 的 payload 都是裸像素。**

| 容器 | 可提取 | 比例 |
|---|---|---:|
| `installer-progress.car` | 2 / 3 | 67% |
| FindMy.app | 11 / 57 | 19% |

部分块解码后长度**正好**等于 `W×H×bpp`（FindMy 里很多，如 `366×104 ARGB`
→ 152,256 字节），这类直接出图。但**大图标常常不是**：Chess 的 1024×1024
解出 2,086,192 字节，而 `1024×1024×4 = 4,194,304`。这些 payload 里还有一层
没搞清的封装（内容约 90% 是零、有约 1026 字节的周期结构）。

处理方式：报 `pixel_size_mismatch`，并把「解出多少 / 期望多少」写进诊断。
**不猜、不截断、不拉伸。** 一张错的 1024×1024 图标，用户看不出来是错的。

**两个不支持的块类型是报出来的。** `bvx1`（v1 头）无工具产出、无样本；
`bvxn`（LZVN）在实测的 **951 张**真实光栅图里出现 **0** 次。两者抛带稳定
code 的异常（`block.unsupported_v1` / `block.unsupported_lzvn`）——
凭猜写的解码器会「能跑但结果错」，那是最坏的一类 bug。

### 19.6 按不可信输入写

`Assets.car` 里的字节来自 IPA，是**攻击者可控**的。所以解码器侧的测试里
专门有这四条：

| 攻击面 | 处理 |
|---|---|
| 伪造的 `n_raw_bytes`（声明解出几个 G） | 输出上限拦住 |
| 篡改的 FSE 频率表 | `block.bad_freq`，不做猜测 |
| 截断的压缩块 | **抛异常**，不返回半截数据 |
| 未知魔数 | `block.bad_magic`，并把魔数带出来 |

「返回半截数据」在这里尤其糟：上层会把它当成功，编出一张下半截是黑块的图。

### 19.7 还没做的

| 项 | 理由 |
|---|---|
| 资产名（`AppIcon` / `AppIcon_Assets/...`） | `RENDITIONS` 的 CPI key，字段布局随 `StorageVersion` 变且无文档 |
| 大图标 payload 的外层封装 | 已知「90% 零 + ~1026 字节周期」，成因未明；现有样本不足以反解 |
| `bvx1` / `bvxn` | 无样本、无工具产出 —— 宁可明确不支持 |

### 19.8 评分影响

**89 → 91/100**。`Assets.car` 这条链现在从「列出图」走到了「真的取出图」，
且正确性有独立实现背书（不是自证）。

加分没有更多的原因是：**能真正出图的比例只有 19%–67%**，大图标那条路还断着。
这不是「实现了 90%」，而是「这个格式比文档（不存在）透露的更深」——
把它如实报出来，比虚报一个 100% 更有用。

## 20. 第七档：`RENDITIONS` 键索引 —— 以及上一节两条「还没做的」都是错的

`ipa_parser` 98 → **112** 条测试。评分 **91 → 93**。

§19.7 列了两条「还没做的」：资产名、大图标的外层封装。这一档把两条都做掉了，
而第二条**根本不是「封装」** —— §19 的诊断错了。

### 20.1 键索引：三条结构都是反解出来的

```
KEYFORMAT 块（"tmfk"，其余字段小端）
  0x08 u32 属性个数 N；0x0C 起 N × u32 属性编号（有序）

键签名 = 2 × N 字节：N 个 u16 小端字段，顺序与 KEYFORMAT 一致
  每个 ISTC 块在**块表里**的前一块就是它自己的键，长度恰为 2N
  字段 17（kCRThemeIdentifierName）= 资产名哈希

名字表：一块字符串 + 紧随其后的稀疏键
  稀疏键 = u32 0 + u16 个数 M + M × (u16 属性编号, u16 值)，总长恰 6+4M
```

反解靠的是**自洽性约束**，不是猜：

| 结构 | 线索 |
|---|---|
| 字段是小端 u16 | 稀疏键里的 `03 00` 按大端是 768（不可能是字段数），按小端是 3 |
| 签名 = 2N | 83 个容器里**每一个** ISTC 的前一块长度都恰好是 2N |
| 前一块是它的键 | 块表顺序（不是文件偏移顺序）；正例 25,986 条，反例 0 条 |

### 20.2 怎么证明不是自证

- `assetutil --info` 的 `Key Format` 名字数组与解析出的编号数组**逐位对应**
  （8 / 11 / 12 / 14 / 17 项都见过 —— 编号不是写死的），
  `NameIdentifier` 与键里 17 号字段**逐条相等**。
- **83 个容器 / 25,986 个 ISTC**：按 `(SizeOnDisk, 资产名)` 多重集比对，
  除 `PackedImage`（图集成员，本来就无资产名）外**零差异**。
- 7,500 个名字、16 位哈希**零碰撞** —— 但仍按「可能碰撞」处理：
  撞了就报「不确定」，不随手挑一个。

夹具 `test/fixtures/car/appicon-ios.car` 是 `actool` 真实编译的 iOS 目录
（28 KB，3 个资产 + 1 个图集 + 2 个空壳），README 存了完整命令与
`assetutil` 原始输出。**这是本轮最值钱的一步**：有了可重复生成的真样本，
后面那条 bug 才能被定位。

### 20.3 §19 的诊断是错的：不是「外层封装」，是多流

§19.5 说大图标 payload 里「还有一层本文没搞清的封装（内容 90% 是零、
有约 1026 字节的周期结构）」。真实结构是：

```
[KCBC 头 20B][bvx2 … bvx$][KCBC 头][bvx2 … bvx$]…[bvx2 … bvx$]
```

一个 `ISTC` 块里的像素是**若干段串接的 LZFSE 流**。`actool` 的 1024×1024
图标是 4 个流：3 × 1,396,736 + 4,096 = 4,194,304 = 1024²×4。只解第一个流
自然「少了 2/3」——「周期结构」其实是「每段 341 行」的错觉。

`KCBC` 头（`"KCBC"` + 8 字节 0 + u32 行数 + u32 紧随其后的流字节数）**不是必需的**：
Chess.app 的块里流与流之间只有 4 字节记录。所以实现是「解完一段，在有界窗口内
找下一个流头」，最终由**总字节数必须精确等于 W×H×bpp** 把关。

修后实测（84 个容器 / 3,244 张可尝试的图）：

| 指标 | 值 |
|---|---:|
| 出图 | **1,428（44.0%）** |
| 其中**多流**（修复前必定失败） | **191** |
| 真实 iOS 应用 1024 图标 | 解出 4 MiB → 458 KB PNG，**95 ms** |

### 20.4 又一处「结论看着合理但是错的」

`installer-progress.car` 里 739 字节的 `LowBatteryFlashing.png` 一直作为
「空壳」的**样例**写在 §18.2、`docs/notes/assets-car.md` 和测试里。
它其实有 `dmp2` 描述符（`dmp2 04 01 0a 04 1e 00 48 00`，30×72 与 `ISTC`
声明一致）—— 是 deepmap2 压过的真图。

新增 `CarCompression.deepmap2`：**有像素，但我们不解这个码**。
「我们解不了」与「没有像素」是两件事，混在一起就是假阴性。

实测分布（84 个容器 / 19,737 个光栅块）：`bvx*` 3,194、纯 `dmp2` 284、
两者都有 2,595（那时像素仍是 LZFSE，所以判定第一优先永远是 `bvx`）、
无标记且块装不下 12,612（真空壳）。

### 20.5 剩下的边界

| 失败码 | 数量 | 成因 |
|---|---:|---|
| `pixel_size_mismatch` | 1,335 | 已确认两种：payload 是 1 字节/像素（LaunchImage 类）；或解出的比预期**多**（Chess 某 1024 图层 7,341,104 vs 4,194,304、BrandMark 80×80 44,880 vs 25,600）|
| `unsupported_deepmap2` | 284 | 不解这个码 |
| `lzfse_block.unsupported_lzvn` | 109 | **后续** chunk 是 LZVN。§19 说「光栅图里 0 次」只在「首流」意义上成立 |
| `unsupported_format` | 88 | `RGBW` / `ATAD` 等 |

**「解出的比预期多」这一类还不清楚。** 记在这里，不猜。

### 20.6 评分影响

**91 → 93/100**。补齐的是一条完整的用户可见链路：`CFBundleIconName` →
资产名 → 精确取图 → PNG → 界面预览。之前这条链在第三步断掉，
用户看到的是「需要一个解码器」；现在是「1024×1024，95 ms」或者
「这个容器里有 12 个资产，没有叫 AppIcon 的」。

没有加更多，是因为 44% 的出图率意味着**多数 rendition 仍然取不到**，
而剩下那一半的成因还没查清。

## 21. 第八档：索引色 —— 最大的一块失败其实是「判据错了」

`ipa_parser` 112 → **121** 条测试。评分 **93 → 95**。
**出图率 44.0% → 50.6%**（3,244 张可尝试的图里 1,642 张成功）。

### 21.1 214 张 1 字节/像素的图是索引色

§20.5 把 `pixel_size_mismatch` 记成「成因未明」。其中 1 字节/像素的那一类
（214 张）其实是**调色板索引色**：

```
"dmp2" | 04 01 0a 04 | u16 宽 | u16 本块行数 | u16 条目数 | u16 每条字节数
       | 条目数 × 每条字节数 的调色板（BGRA）
       | u32 紧随其后的流字节数
```

**ISTC 的 `pixelFormat` 写着 `ARGB`，落盘却是每像素 1 字节的索引。**
那个字段是「解码后的目标格式」，不是存储形态。按它算期望字节数
（`w×h×4`）自然对不上 —— 报出的「解出 2,740,500、期望 10,962,000」
不是数据缺陷，是**我的判据错了**。

这条与 §12.4(a)（NSC 那次）是同一类错误：**从「字段这么写」推出
「数据一定是那样」**。

### 21.2 分块与「按块换调色板」

```
LaunchImage 1125×2436:  rows 0..931 / 932..1863 / 1864..2435
                        调色板 252 / 240 / 244 条
                        932+932+572 = 2436 ✓
```

`actool` 按约 1–1.5 M 像素切条带，**每块一份独立调色板**，索引数据是拼接的。
用第一份套全图：932 行整片颜色错，而画面仍然「像一张图」——
**这是本轮最危险的一处**，因为没有任何报错。

### 21.3 验证：三色 ground truth

| 夹具（`actool` 编译，像素值由脚本决定） | 结果 |
|---|---|
| `palette-single.car` 300×300 单块 | 三段 = 红/绿/蓝，**逐像素相等** |
| `palette-banded.car` 1500×1000 两块 | 块 1 有 3 条板、块 2 只有 **1** 条；边界 y=699 行平均色差 **0.00** |

第二个夹具是专门为「按块换板」造的：块 2 全蓝，若套块 1 的板会变红。
0.00 的差值把这件事钉死了。

真实样本：`bi-ying` 的启动图 → 1.5 MB PNG、303 ms；块边界 y=932 / 1864
的行间色差 7.89 / 16.85，都在全图 p99（30.65）内，**无台阶**。

### 21.4 调色板也是 BGRA —— 同一条「名字骗人」的规则

三色图里索引 0 落在图像**右侧的蓝色区**，而调色板[0] 是 `ff 00 00 ff`：
只有按 BGRA 读才是蓝。这与 §19.4 里 CoreGraphics 给出的
`ARGB → B,G,R,A` 是同一条规则，两处独立验证、结论一致。

### 21.5 误报面：0

84 个容器里「解出字节数 == 像素数」的块共 214 个，**全部**带完整调色板，
没有一个是「真灰度」。判据零误报。

保留双重闸门：

1. **解析阶段**结构自洽 —— 参数四字节、宽 == ISTC 宽、条目数 ∈ 1..256、
   stride ∈ {3,4}、**各块行数之和 == ISTC 高度**，任一不成立就整体放弃
   （半套调色板比没有糟糕得多）。
2. **映射阶段**索引 < 该块条目数 —— 越界报 `palette_index_overflow`，
   **不**截断到 0 号色。

### 21.6 剩下的

| 失败码 | 数量 |
|---|---:|
| `pixel_size_mismatch` | 1,121 |
| `unsupported_deepmap2` | 284 |
| `lzfse_block.unsupported_lzvn` | 109 |
| `unsupported_format` | 88 |

`7 字节/像素`（ARGB）与 `3 字节/像素`（GA8）是**另一套多层结构**（模式 `02`）。
实测平面 0 常为全 255（alpha），其余平面与可见图像对不上。
**没有把握就不做** —— 硬解很容易得到「像图但颜色错」的结果，
那比明确报「不解」糟得多。

### 21.7 评分影响

**93 → 95/100**。这一档的价值不只是 6.6 个百分点的出图率，而是
**把一个「缺陷」改判成「判据错了」**：报告不再声称「解出 2,740,500，
期望 10,962,000」这种让人以为数据损坏的话。

没有更高，是因为剩下 1,121 张仍未解，且都属同一类未文档化的多层编码。
