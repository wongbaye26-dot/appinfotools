# 安全检测可信度评审

> 评审对象：`apk_parser` / `ipa_parser` 两个安全引擎的全部规则
> 日期：2026-10-22

## 一、盘子

**59 条规则**：Android 34 条，iOS 25 条。

| confidence | 条数 | 含义 |
|---|---|---|
| `confirmed` | 28 | 同一可追踪路径上的证据，或受信任工具的明确结论 |
| `suspected` | 14 | 多个线索同现，但静态分析未能证实数据流向 |
| `independentCapability` | 13 | 只看到独立能力（如只看到 OCR SDK） |
| `unknown` | 4 | 加固、混淆、解析失败，或检测范围之外 |

| severity | 条数 |
|---|---|
| `info`（事实清单，不是风险） | 25 |
| `p3` | 11 |
| `p2` | 14 |
| `p1` | 6 |
| 动态判定（按命中条件在 p2/p3 间取值） | 3 |

**25/59 是 info 级** —— 四成多的产出根本不声称「有风险」，只陈述事实。
这个比例本身说明了一件事：这套引擎的设计目标不是「多报」，是「把可核对的事实摆出来」。

---

## 二、按证据强度分四层（核心结论）

可信度不由 `confidence` 字段决定，由**证据类型**决定。同标 `confirmed` 的两条规则，
一条是「清单里写了 `android:debuggable="true"`」，另一条是「包里出现了某个类名」——
前者错不了，后者随时可能因为混淆而失真。

### L1 声明式事实 —— 几乎不会错

**证据**：`AndroidManifest.xml` 属性、`Info.plist` 键、签名块结构、ELF 头、归档条目布局。
**代表规则**：`DEBUGGABLE`、`ALLOW-BACKUP`、`SHARED-USER-ID`、`EXPORTED-COMPONENT`、
`PROVIDER-EXPOSED`、`SPECIAL-ACCESS`、`PERMISSION-*` 系列、`DEEPLINK`、`UNSIGNED`、
`V1-ONLY-SIGNING`、`NATIVE-EXEC-STACK`；iOS 的 `GET-TASK-ALLOW`、`ATS-EXCEPTION`、
`URL-SCHEMES`、`USAGE-DESCRIPTION`、`ENTITLEMENT-CAPABILITY`、`PRIVACY-TRACKING`、
`PUSH-SANDBOX`、`REPACKAGED`。

**能信到什么程度**：事实层面基本无懈可击 —— 唯一的失败模式是**解析器读错了**，
而不是推断错了。这类规则的风险不在「假阳性」，在「语义被误读」：例如
`EXPORTED-COMPONENT` 里 `exported` 为 `null` 时不判（默认值取决于 intent-filter
与 targetSdk，静态猜就是编造）—— 这是对的，但也意味着这类组件**我们看不见**。

**这一层做得比预期细的地方**：`PROVIDER-EXPOSED` 不只查 `android:permission`，
还分别看 `readPermission` / `writePermission`（两个方向都声明才算全关上，只声明一个
仍算半开），以及**本包声明权限的 `protectionLevel`** —— `normal` / `dangerous` 级的
自定义权限视为「名存实亡」。框架权限与别包声明的权限看不到级别，保守当成受保护
（猜错的方向偏向不误报）。

**但看不到代码**：provider 内部是否自己校验了 `callingPackage`，静态分析无从得知。
所以「导出且无有效权限」是事实，「数据可被任意应用读取」仍是推断。

### L2 符号与字符串 —— 「存在」可信，「被使用」不可信

**证据**：DEX 字符串池、`method_ids` 条目、Mach-O 的 `__objc_methname` /
`__objc_selrefs` / `__objc_classrefs`、`.so` 的 `.dynstr` / `.rodata`。
**代表规则**：`UPLOAD-API`、`NETWORK-CLIENT`、`OCR-CAPABILITY`、`THIRD-PARTY-SDK`、
`PACKER`、`MALWARE-INDICATORS`（部分）、`NATIVE-SYMBOLS`、`CRYPTO-THEFT-RISK`（部分）；
iOS 的 `NATIVE-SYMBOLS`、`PERMISSION-REQUEST`、`OCR-CAPABILITY`、`PHOTO-PICKER`、
`USAGE-WITHOUT-API`、`USAGE-MISSING-FOR-API`。

**能信到什么程度**：字符串常量**可以随便写**。一个应用把 `getPrimaryClip` 写进
一个从不调用的方法里，和真的调用了，在这一层看起来一样。所以这类规则一律标
`independentCapability` 或 `suspected`，不标 `confirmed` —— 标注是自洽的。

**真正的问题在漏报**：字符串加密 / 异或 / 混淆后，这一层完全失效。加固壳
（360、梆梆、腾讯乐固）正是这么干的 —— 此时引擎只剩 `ANDROID-PACKER` 一条
`info` 级提示，其余规则集体沉默。**沉默不等于干净**，这一点 limitation 里有写，
但用户很容易把「没报」读成「没问题」。

### L3 调用点 —— Android 独有，iOS 没有

**证据**：DEX `code_item` 里的 `invoke-*` 指令（含方法名与指令偏移），
以及「多条调用指令位于同一个方法体内」的共现。
**代表规则**：`ANDROID-RULE-C`（图片 → OCR → 上传）、`ANDROID-RULE-G`（标识/通讯录 → 上传）。

**能信到什么程度**：这是静态分析在没有数据流的前提下能拿到的最强证据 ——
「`NetProbe.open` 的调用指令在 `Lcom/foo/Bar;.baz()V` 的 `+0x10` 处」。
但它仍然只回答「有一条调用指令」，不回答「运行时会执行到」，更不回答
「OCR 的结果被传进了这个上传请求」。代码注释里对这条界线写得很清楚：

> 同一个方法里既有识别又有上传，不等于识别结果被送进了上传请求，
> 那要看寄存器与参数传递，属于数据流分析。

**iOS 完全没有这一层。** `ios_native_symbol_audit` 解析的是选择子引用表，
能说明「这个选择子被引用了」，但拿不到「在哪个函数的哪个位置被调用」——
因为没有反汇编。**这是两个平台之间最大的可信度差距**：同样是
`IOS-RULE-C`（p1，`suspected`）和 `ANDROID-RULE-C`（p1，`suspected`），
标着同样的等级，Android 那侧的底牌比 iOS 硬一档。

### L4 组合推断 —— 只提供线索，不下结论

**代表规则**：`RULE-A/B/E/F/G`、`CRYPTO-THEFT-RISK`、`MALWARE-INDICATORS`
（两侧都有）。

**能信到什么程度**：这一层的价值是**排序**，不是判定。把「能签走资产的材料」和
「能把它送出去的通道」摆在一起，让人知道先看哪里。它必然带假阳性 ——
正规钱包应用具备 `CRYPTO-THEFT-RISK` 列出的每一项能力，这一点写在正文和局限里。

**设计上做对的地方**：等级按「来源稀有度」分级。设备标识、定位、剪贴板 +
上传几乎每个应用都有，一律不给 P2；只有通讯录/短信/录音 + 上传才给 P2。
`ANDROID-WEBVIEW-BRIDGE` 从 P2 降到 P3 也是同一个理由 —— 实测 5 个真实包
有 4 个命中，且调用点全部来自第三方 SDK（极验、神策、极光、Facebook）。
**这是用真实数据校准过的，不是拍脑袋。**

---

## 三、标注自洽性抽查

挑几条容易标高的，逐条核对：

| 规则 | 标注 | 判断 |
|---|---|---|
| `ANDROID-DEBUGGABLE` p1/confirmed | 清单属性 | ✅ 事实，p1 合理（可被任意调试器附加） |
| `ANDROID-NATIVE-EXEC-STACK` p2/confirmed | ELF `PT_GNU_STACK` 含 `PF_X` | ✅ 结构事实；不说明「已被利用」，措辞里写了 |
| `ANDROID-V1-ONLY-SIGNING` p3/independentCapability | 签名方案事实 | ✅ 明确不声称「已被篡改」，有效性归 apksigner |
| `ANDROID-SPECIAL-ACCESS` p3/confirmed | 清单层权限声明 | ✅ 确认的是「声明了」，不是「在滥用」 |
| `IOS-JAILBREAK-TOOLKIT` p1/confirmed | 组件名匹配 | ⚠️ 见下 |
| `IOS-REPACKAGED` p2/confirmed | `.app` 根目录的 `.dylib` | ✅ 文件存在是事实；「被注入」的解释与事实在正文里分开写 |
| `IOS-USAGE-WITHOUT-API` info/**unknown** | 声明了用途但没找到 API | ✅ 敢标 `unknown` 是诚实的 —— 找不到可能只是我们没看到 |

**唯一想挑的是 `IOS-JAILBREAK-TOOLKIT` 的 p1。** 组件名（`kfd`、`multicast_bytecopy`）
确实是确定的，但「这个包里有内核 exploit」→「它能拿到设备完全控制权」中间还隔着
「这个组件真的被加载并触发」。p1 的依据是「存在即高危」，我认为可以接受，
但严格说 `confirmed` 描述的是**文件存在**，不是**能力生效**。

---

## 四、值得提升的地方（按性价比排序）

### 1. 补 iOS 的调用点级证据 —— 最大缺口，也最贵

现在 iOS 的判断止步于「选择子被引用」。要追上 Android，需要：

- 解析 `__TEXT.__text` 里的 `BL` / `BR` 指令，把 `__objc_msgSend` 的调用点与
  `__objc_selrefs` 的偏移对上；
- 或者更轻的做法：用 `__objc_selrefs` 的**引用计数与所在函数**做粗粒度归属
  （Mach-O 的 `LC_FUNCTION_STARTS` 给出函数边界，不需要完整反汇编）。

第二条是可行的中间态：不需要指令解码，只需要函数边界 + 引用位置。
代价是拿不到「同一个函数体内共现」，但至少能回答「这个选择子出现在几个函数里」。

**价值**：把 iOS 的 `RULE-C`（p1）从「疑似」推向「有调用点支撑」。

### 2. 「疑似」结论要给验证步骤，不只是风险描述

现在 `suspected` 级发现的 recommendation 是「手工核对 X 和 Y 的关系」。
用户拿到这句话仍然不知道**怎么核**。可以补一条「验证路径」：

> 动态验证：`adb shell am start -n <组件> --es <参数>` 触发深链，
> 同时 `adb logcat | grep <包名>` 看是否发起了上传请求。

这不是让工具做动态分析，是把「下一步怎么做」写清楚。

### 3. 覆盖率维度不对称：iOS 8 维 vs Android 12 维

| Android（12） | iOS（8） |
|---|---|
| `manifest` `permissions` `dex.structure` `dex.strings` `dex.methodReferences` `dex.callSites` `arsc` `signature` `nativeSymbols` `nativeHardening` `cleartextPolicy` `sdkInventory` | `infoPlist` `usageDescriptions` `privacyManifest` `executables` `macho.strings` `nativeSymbols` `entitlements` `signature` |

iOS 有而 Android 没有的：`privacyManifest`（隐私清单覆盖）。**这一条 Android 确实缺**
——Android 没有等价的「数据安全表单」自述。

iOS 缺的是 **`dex.callSites` 的对应物**（见上一节）与**资源维度**：Android 有 `arsc`，
iOS 连一个「`Assets.car` 解析成功与否」的覆盖项都没有 —— 图标解析失败时，
用户看不到「这一维我们没读出来」。

### 4. iOS 缺「上传能力」的独立规则

Android 有 `ANDROID-UPLOAD-API`（info 级，独立成项），iOS 的 `network-upload`
线索只喂给组合规则，不单独产出。两边不对称 —— 用户看 iOS 报告时会觉得
「这个应用有没有上传能力」这个问题没被回答。

### 5. 签名验证的降级路径

未装 `apksigner` / `codesign` 时，签名结论是 `unknown`。这是对的（不猜），
但可以做得更有用：**读 v2 / v3 签名块里的证书，给出 SHA-256 指纹**。
不做密码学校验（那确实该交给 apksigner），但用户可以拿指纹去和官方公布的比对。

现在拿不到指纹：`apk_signing_block.dart` 只枚举了签名块的 **pair ID**
（`0x7109871a` / `0xf05368c0` …），没有解出证书。要补这一层需要 DER / X.509 解析 ——
`ipa_parser` 里已经有 `der.dart` 与 `x509.dart`（描述文件就是靠它们解出来的），
可以直接搬过来用，不必重写。

### 6. 语料回归：把「预期结论」固化成测试

`tool/crypto_corpus_eval_test.dart` 是个好的开始（对真实样本跑规则、看命中）。
但目前**只有盗 U 一条链有语料评估**。其余 58 条规则的正确性靠零散的单测，
没有「这 12 个真实包各自应该报什么」的整体基线。

建议：把现有 12 个真实 IPA + 若干 APK 的**期望发现项清单**（ruleId + 等级）
写进一个 fixture 文件，跑一次比对。**任何规则的改动只要让某个真实包的结论变了，
就必须显式更新那份清单** —— 这比逐条单测更能防住「修 A 规则弄坏 B 规则」。

代价是：真实样本不能进仓库（体积 + 版权），所以这份基线只能本地跑，
或者用「样本指纹 + 期望结论」的形式（样本不进仓库，CI 跳过）。

### 7. 规则之间的「同一件事」没有被归并

一个真实包上，`SPECIAL-ACCESS`、`RULE-A`、`CRYPTO-THEFT-RISK` 可能同时命中，
都在说「无障碍能力」。现在它们是并列的三条发现，读者要自己串。
可以考虑在报告层加一个「能力视图」：把规则命中折算成「这个应用具备哪些能力」，
再按能力聚合 —— 规则是给分析者看的，能力是给决策者看的。

---

## 五、一句话结论

**这套引擎的可信度在同价位工具里属于上游**：它有证据分级、有覆盖率自述、
有「我们没看到」与「文件里没有」的严格区分，而且等级是用真实样本校准过的
（`WEBVIEW-BRIDGE` 从 P2 降到 P3、`privateKey` 移出判级、`mobilesubstrate`
不再算越狱组件 —— 这些都是被数据打回来改的）。

**它最薄的地方是 iOS**：证据层级比 Android 少一层（没有调用点），
覆盖率维度少四项且缺资源维度，还缺一条独立的上传规则。其次是**所有组合规则都停在
「疑似」**，而「疑似」之后没有给出可执行的验证路径。

**它最容易被误读的地方**：加固包上规则集体沉默，而「没报」会被读成「没问题」。
这一点 limitation 里写了，但值得在界面上更显眼 —— 比如安全页顶部在检测到
`ANDROID-PACKER` 时直接挂一条横幅：「这个包被加固过，以下结论的覆盖率很低」。
