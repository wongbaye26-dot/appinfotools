# APK / IPA「盗 U」恶意代码与动态库检测能力增强
## 开发设计说明（设计稿，不含实现）

> **状态**：设计稿 v1.1 + **Phase A 契约、Phase B 事实层、Phase C 引擎/UI/生产接线已实现并验证**（2026-11-04）
> **基线**：AppInfoTool `2.8.7`（commit `b7adbc5`，2026-10-22）
> **日期**：2026-11-04
> **范围**：Android APK（含 XAPK/APKS 的 base）与 iOS IPA 的**静态**检测能力增强
> **非目标**：不实现、不执行样本、不联网分析、不内置运行时沙箱；所有工作量与检出率均为**估算/目标**，未经语料实测的标 `未验证`
> **决策状态**：2026-11-04 已确认（D1 无语料 / D2 维护官方基线 / D3 只给证据）

---

## 决策记录（2026-11-04，已确认）

| # | 决策 | 对设计的影响 |
|---|---|---|
| **D1** | 不提供已知盗 U 样本 / 正规钱包样本 | **不做检出率承诺**；家族 IoC 匹配延期；验收改为"夹具 + 官方基线 + 覆盖诚实性 + 回归"；UI/README 不出现任何百分比 |
| **D2** | 维护 Top 20–30 钱包/交易所的官方证书/Team 基线 | **官方基线成为唯一 L4 路径**；新增基线维护规格、数据来源依赖、多证书集合匹配；不依赖恶意语料 |
| **D3** | 接受"只给风险证据、不给恶意判决" | 冻结 **PASS / HIT / UNKNOWN** 三态；P1 只用于事实级（基线不匹配 / 密封不匹配）；不出现"木马/恶意"定性 |

---

## 0. 结论先行

### 0.1 直接回答：能做，但只能做到"证据"，做不到"判决"

**能做。** 在现有静态分析引擎上，可以把「盗 U」检测从当前的**能力组合提示（L2）**升级为一条**分层静态证据链（L3）**：

1. **能力层**：是否具备盗 U 需要的代码能力（钱包/密钥材料/剪贴板/无障碍/悬浮窗/WebView/授权签名 API）；
2. **载荷层**：是否有可疑代码载体（伪装 DEX、assets/`lib` 载荷、加密/加壳 `.so`、注入 dylib/framework）；
3. **来源/完整性层**：这些代码是不是**后加进去的**（签名/证书/描述文件/CodeResources/加载链/包结构异常）；
4. **基线层**：是否命中官方基线（证书/Team；家族情报因无语料延期，见 D1）。

**但静态分析不能对任意未知包给出"这是盗 U 木马"的结论。** 能做与不能做的边界：

| 问题 | 静态分析能给什么 | 能否"证明" |
|---|---|---|
| 有没有盗 U 相关**能力**？ | 能力清单 + 调用点 + 原生库字符串/符号 | 能证明"能力存在"，不能证明"会使用" |
| 有没有**被添加**的代码/动态库？ | 签名/密封/布局/加载链异常；有官方基线时可判定冒充/重打包 | **有官方基线时可证明**；无基线时只能给"异常证据" |
| 是不是**已知**木马家族？ | 命中家族签名/IoC（**当前无语料，延期**） | 先不做；将来有合法情报再说 |
| 运行时到底做了什么？ | —— | **不能**，需要动态沙箱（本产品不做） |

### 0.2 检测能力等级（本文核心口径）

| 等级 | 定义 | 能回答的问题 | 本项目 |
|---|---|---|---|
| **L0** | 不检测 | —— | 基线之前 |
| **L1** | 单点特征（字符串/权限/文件命中，不判级） | "提到了什么" | 现状部分能力 |
| **L2** | 能力组合（多类能力同现，`independentCapability`） | "具备盗 U 所需能力组合" | **现状（2.8.7）** |
| **L3** | 结构/一致性证据（签名、密封、加载链、布局、载荷类型） | "包被改过 / 含额外代码 / 布局异常"——**事实级** | **MVP 目标** |
| **L4** | 官方基线命中（证书/Team；家族 IoC 延期） | "冒充官方包" | **二期目标（需基线库；不需要恶意语料）** |
| **L5** | 运行时确认（执行、脱壳、插桩、实际数据流） | "它确实偷了" | **不在本产品**（可预留外部导入） |

- **现状**：L2（`ANDROID-CRYPTO-THEFT-RISK` / `IOS-CRYPTO-THEFT-RISK`，`confidence` 固定 `independentCapability`）；局部有 L3 雏形（iOS `.app` 根目录 dylib 是**布局事实**，`IOS-REPACKAGED` 标 `confirmed`），但未成体系。
- **目标**：MVP 达到 **L3（证据链）**；二期补 **L4（官方基线）**；家族 IoC 因无语料延期（D1）。
- **L5 排除理由**：需真机/模拟器执行、脱壳、Frida 级插桩；与"安装前静态检查"定位冲突，且引入动态执行风险。产品内只做"建议送动态分析"的交接（现有 recommendation 已如此）。

### 0.3 哪些场景能判、能判到什么程度

| 场景 | 静态能得出的结论 | 等级/置信度 |
|---|---|---|
| 已知官方钱包包名/Bundle ID，但证书/Team 不一致 | 「冒充/重签」——**结构性事实** | L4 / confirmed（需基线库） |
| 官方包被注入 `.app` 根目录 dylib | 「存在正常构建不会出现的额外动态库」 | L3 / confirmed（文件事实） |
| 包内 `lib/xxx.so` 实为 DEX，且存在加载入口 | 「载荷类型与扩展名不符，运行时可被加载」 | L3 / suspected–confirmed |
| 主程序声明加载某 dylib/so，但包内不存在 | 「悬空加载边（可能运行时下载/解密）」 | L3 / suspected |
| 钱包 + 剪贴板写 + 地址字面量 + 网络上传 | 「地址替换能力链齐全」 | L2–L3 / suspected（正规钱包同样具备） |
| 中文假客服话术 + 助记词输入 + 网络外发 | 「助记词钓鱼链」 | L2–L3 / suspected |
| 加壳/加密/远程加载 | 「关键逻辑被保护，无法判定」 | **unknown**，必须显示"无法判断" |
| 服务端行为/社工过程 | 静态不可见 | 不可判 |

### 0.4 效果与验收口径（已按 D1 调整）

**没有测试语料，因此本方案不做检出率承诺，也不设精确率/召回率门槛。** 当前验收改为"能力/夹具/基线"三类可机器判定的检查：

| 验收类 | 检查 | 判定 |
|---|---|---|
| 能力/夹具 | 每条规则至少 1 正 1 负合成夹具；正例命中、负例不命中 | 100% 通过 |
| 覆盖诚实性 | 预算截断/加壳/工具缺失 → partial/unknown，不出现"未发现" | 全部用例 |
| 官方基线 | 官方包命中 `baselineMatch`；改证书/Team 的夹具命中 `baselineMismatch` P1 | 100% |
| 密封 | 篡改 1 字节 → `mismatch`；未注入 digest → `notChecked` | 100% |
| 回归 | 现有 2,193 条 + analyze/format | 全绿 |

**将来若有语料**（malicious/wallet/benign 达到 §11.2 的最小量），再启用原定的 P2+ 精确率/召回率门槛（A/B/C 阶段）；在此之前，README/CHANGELOG/UI **不得**出现任何检出率、准确率、"能检测 X%"的表述。

> 现有 50–65%（Android）/ 40–55%（iOS）是估计值（`CHANGELOG.md:531`），不是本方案的指标。

### 0.5 工作量（估算，未验证）

| 阶段 | 内容 | 估算 | 产出等级 |
|---|---|---:|---|
| A 契约 | 冻结模型/schema v8/规则 ID | 3 人日 | —— |
| B 事实层 | 制品清单/载荷探测/加载链 | 6 人日 | L2–L3 |
| C 判定层（**MVP 止于此**） | 证据链 + 规则 + UI/报告 | 6 人日 | **L3** |
| D 密封校验 | APK v1/v2 摘要、IPA CodeResources | 5 人日 | L3 |
| E 基线库 | 官方基线（证书/Team）维护与校验；**家族 IoC 因无语料延期** | 4 人日 | L4（仅基线） |
| **MVP（A+B+C）** | 双端 | **15 人日** | **L3** |
| **完整（A–E）** | 双端 | **≈24 人日** | **L3+ / 部分 L4** |

> 不含基线数据获取/维护、iOS 后台任务改造的额外测试成本、安全/法务评审。若含这些，建议按 **18–28 人日** 排期。

---

## 1. 诉求拆解与验收标准

用户要回答的是三个不同的问题，必须分开建模：

| # | 用户问题 | 需要的证据 | 回答形式 |
|---|---|---|---|
| Q1 | 这个包**有没有**盗 U 相关的代码/能力？ | 能力清单 + 调用点 + 原生库证据 | "具备以下能力组合"，P2/P3 + 证据链 |
| Q2 | 有没有**被添加**的恶意代码/动态库？ | 签名/密封/布局/加载链/基线对比 | "强证据/疑似/未发现/无法判断" |
| Q3 | 是不是**已知**木马家族？ | 家族签名/IoC 命中（**延期 D1**） | 本期不回答；接口保留 |

**验收标准（每阶段可机器判定）**：

1. **可解释**：每条结论可展开到具体文件/方法/偏移/符号/字符串；没有证据的结论不允许出现。
2. **可区分**：`已证实的事实` / `疑似关联` / `能力线索` / `无法判断` 四态严格分开。
3. **可复核**：Markdown、JSON、界面读同一份评估结果；新增字段不得只出现在其中一处。
4. **可回归**：现有 2,193 条测试全绿；`flutter analyze --fatal-infos --fatal-warnings` 零问题；`dart format` 干净。
5. **可复核**：无语料时不承诺量化；以夹具/基线/覆盖诚实性/回归判定。将来有语料再按 §11.2 补精确率/召回率。

---

## 2. 现状基线（2.8.7，已核实）

### 2.1 现有数据流

| 端 | 入口 | 输入 | 输出 |
|---|---|---|---|
| Android | `AndroidSecurityAudit.audit`（`packages/apk_parser/lib/src/security/android_security_audit.dart:94`），在 `lib/apkparser/parse_task.dart:277` 的 worker 中调用 | `ApkMeta`、DEX 字节、`NativeLibraryBytes`（24 库/96 MiB）、加固/容器/符号/覆盖统计 | `SecurityAnalysisResult` |
| iOS | `IosPrivacyAudit.audit`（`packages/ipa_parser/lib/src/security/ios_privacy_audit.dart:235`），**在 UI 主 isolate 同步调用**（`lib/pages/info_page.dart:429`） | Info.plist、主可执行文件字节（≤64 MiB）、嵌套可执行文件（≤24 个/32 MiB）、entitlements、`IpaLayoutFacts` | 同一模型 |

> ⚠️ **前置改造**：iOS 安全审计目前在 UI 线程同步执行。新增制品清单/哈希/CodeResources 校验会明显增加耗时，**必须先把 iOS 安全分析移入后台任务**（见 §5.4）。

### 2.2 现有「盗 U」规则

| 平台 | 规则 | 判级 | 置信度 | 证据 |
|---|---|---|---|---|
| Android | `ANDROID-CRYPTO-THEFT-RISK`（`android_security_rules.dart:993`，判据 `:952`） | 密钥材料+通道、或钱包+剪贴板+地址 → P2；仅单类信号 → P3 | 固定 `independentCapability` | DEX 字符串/方法引用、原生库字符串、manifest 权限、地址字面量 |
| iOS | `IOS-CRYPTO-THEFT-RISK`（`packages/ipa_parser/lib/src/security/ios_crypto_audit.dart:196`） | 同上（通道换成 pasteboard/地址） | 固定 `independentCapability` | ASCII 字符串、地址字面量 |

现有信号组：
- **钱包 SDK**：`wallet-web3j`、`wallet-walletconnect`、`wallet-metamask`、`wallet-trust`、`wallet-tokenpocket`、`wallet-imtoken`、`wallet-okx`、`wallet-binance`、`wallet-coinbase`、`wallet-secp256k1`、`wallet-keccak`、`wallet-erc20`、`wallet-trc20` 等；
- **密钥材料**：`wallet-mnemonic`、`wallet-bip39`、`wallet-bip32`（`privateKey` 只作线索、不参与判级，避免 OpenSSL 误报）；
- **剪贴板**：`clipboard-read` / `clipboard-write`；iOS `uipasteboard` / `generalpasteboard`；
- **通道**：Android 无障碍/设备管理/通知监听组件、短信权限、上传能力；iOS 写死地址。

### 2.3 现有可复用能力（方案基础）

| 能力 | 位置 | 可直接用于 |
|---|---|---|
| DEX 结构 + `string_ids` | `packages/apk_parser/lib/src/dex/dex_structure.dart` | 精确字符串索引、中文串（需新扫描器） |
| 方法引用 + 调用点 + 同方法体共现 | `.../dex/dex_method_bodies.dart`、`dex_method_scanner.dart` | 剪贴板/加载器/WebView/授权 API 的调用点定位 |
| 指令宽度表 + `invoke-*` | `.../dex/dex_instruction.dart` | 加载器参数的有限解析（新增） |
| ELF 头/节/符号/加固 | `.../native/elf.dart`、`elf_hardening.dart`、`security/native_symbol_scanner.dart` | `.so` 清单、节熵、导入符号、JNI_OnLoad |
| 加固/伪装信号 | `packages/apk_parser/lib/src/hardening.dart:11` | 缺失主 DEX、伪装 `.so`（内容是 DEX）、assets 代码、诱饵 ZIP 条目 |
| 壳识别 | `.../security/packer_catalog.dart` | 10 家商业壳（只识别不脱壳） |
| Mach-O 全量结构 | `packages/ipa_parser/lib/src/macho.dart:213` | 架构、`LC_LOAD_DYLIB`、`LC_RPATH`、`LC_ID_DYLIB`、UUID、符号、section bytes |
| iOS 引用表 | `.../security/ios_reference_tables.dart` | `__objc_classrefs`/`__objc_selrefs` → 类/选择子引用 |
| 描述文件/签名材料 | `packages/ipa_parser/lib/src/ios_signature.dart:142` | Team ID、有效期、entitlements、CodeResources 摘要 |
| 重打包布局 | `packages/ipa_parser/lib/src/ipa_layout.dart:15` | `.app` 根目录 dylib（实测 7/7 命中、0/3 误报） |
| 外部工具三态 | `lib/utils/signature_analyzer.dart`、`ios_codesign_analyzer.dart` | `apksigner`/`codesign` 结论、证书 SHA-256、TeamIdentifier、`Signature=adhoc` |
| 报告同源 | `lib/utils/analysis_report.dart` | Markdown/JSON/界面同一份评估 |
| 语料评估 | `tool/crypto_corpus_eval_test.dart` | malicious/wallet/benign 三档、宽/窄阈值、失败不进分母 |

### 2.4 现有差距（本方案要补的）

| 差距 | 影响 | 现状证据 |
|---|---|---|
| 没有**制品清单**（DEX/`.so`/Mach-O/dylib/framework/assets 载荷逐个记录路径/大小/架构/来源） | 无法回答"包里到底有哪些可执行代码、哪来的" | 只有零散文件名列表 |
| 没有**加载链**（谁加载了谁、目标是否在包内） | 无法区分"包内库"与"运行时下载/解密加载" | 只有 `hasDynamicLoading` 布尔 + 字符串 |
| 没有**完整性/来源校验**（iOS CodeResources 哈希、APK v1/v2 摘要、嵌套 Mach-O 签名） | 无法发现"被后加进去"的代码 | CodeResources 只数条目（`ios_signature.dart:779` 注释明确"不重算哈希"） |
| **只扫 ASCII 串** | **中文界面/钓鱼话术/中文域名全部漏掉**；DEX 的 MUTF-8 与 Swift 的 UTF-16 都不可见 | `packages/analysis_model/lib/src/ascii_strings.dart` 注释自述 |
| 没有**官方基线/家族情报库** | 无法证明冒充；未知家族只能给能力线索 | 无（基线本期做，家族延期） |
| 没有**官方基线**（钱包/交易所包名+证书） | 无法证明"冒充/重打包" | 无 |
| iOS 审计在 UI 线程 | 新增扫描会卡顿 | `info_page.dart:429` |
| Markdown 报告缺字段（审计 P1-5） | 导出的安全报告不完整 | `analysis_report.dart` 缺 11 组字段（见 2026-11-04 审计） |

### 2.5 实施前应先修的 3 个现存缺陷（本轮审计发现）

| # | 缺陷 | 证据 | 影响 |
|---|---|---|---|
| R7 | native 来源的地址证据被标成 `DEX string` | `android_security_rules.dart:1054-1060` | 复核会按错误来源查找 |
| R8 | CodeResources 只解析结构、不解哈希 | `ios_signature.dart:779-810` | 设计若假设"能验密封"是伪假设 |
| R9 | iOS findings 缺 `blindSpots`（Android 有） | `android_security_rules.dart:1017-1021` | 预算截断可能被读成"未发现" |

> 这 3 条不修，新增的 L3 证据会被错误呈现。建议纳入 Phase A（契约阶段）一并处理。

---

## 3. 威胁模型：盗 U 攻击链

### 3.1 资产与静态可观察形式

| 资产 | 敏感级 | 静态可观察形式 |
|---|---|---|
| 助记词/私钥/种子 | 极敏感 | `mnemonic`/`bip39`/`bip32`/`secp256k1` 字面量、密钥输入 UI、Keychain/Keystore 调用 |
| 剪贴板收款地址 | 敏感 | `ClipboardManager` / `UIPasteboard` 读写调用 |
| 交易签名授权（approve/permit/signTypedData） | 极敏感 | 选择器常量、JSON-RPC 方法名、WalletConnect 会话方法 |
| 账号凭证/验证码 | 敏感 | SMS/通知监听/读屏能力 |
| 攻击者收款地址 | 高 | 带校验和的链上地址字面量 |

### 3.2 攻击者与投递

| 投递方式 | 平台 | 静态可见性 |
|---|---|---|
| 仿冒钱包/交易所（独立 App，包名/图标/名称仿冒） | 双端 | **中**：包名/证书与官方基线比对；UI 文案需中文扫描 |
| 正规包重打包 + 注入代码/动态库 | 双端 | **中–强**：签名/证书、CodeResources、dylib 布局、加载链 |
| 企业签/Ad-Hoc 侧载包 | iOS | **强**：描述文件、Team ID、`Signature=adhoc`、注入布局 |
| 远程配置下发/热更新（运行时加载 DEX/JS/HTML） | 双端 | **弱**：只能看到加载器与远程地址，载荷不在包内 |
| 社工（假客服/空投/解冻/兼职） | 双端 | **弱**：只能扫 UI 文案/域名，不能证明行为 |

### 3.3 攻击链阶段 × 平台技术点

| 阶段 | Android 技术点 | iOS 技术点 | 静态可探测性 |
|---|---|---|---|
| **① 投递/驻留** | 重打包重签；`assets/` 内嵌 DEX/加密载荷；`lib*.so` 实为 DEX；多 dex；插件化；`DexClassLoader`/`InMemoryDexClassLoader` | `.app` 根 dylib；`LC_LOAD_DYLIB` 注入；重签名；`Frameworks/` 外库；嵌套 `.appex` | 中—强（结构可见，恶意性不可见） |
| **② 权限/能力获取** | 无障碍 `BIND_ACCESSIBILITY_SERVICE`、设备管理器、通知监听；`READ_SMS`/`RECEIVE_SMS`；悬浮窗；`REQUEST_INSTALL_PACKAGES`；`QUERY_ALL_PACKAGES` | 无等价权限面；`UIPasteboard`；后台网络；App Group/URL Scheme；屏幕录制 | 强（声明是事实） |
| **③ 资产获取** | 助记词/私钥处理；剪贴板读写；读屏/截图/OCR；`approve`/`permit`/`signTypedData`；WalletConnect | 同左；`UIPasteboard.general`；助记词输入框 | 强—中（能力可见，数据流不可见） |
| **④ 外传/替换** | multipart/OkHttp/Retrofit 上传；`SmsManager`；剪贴板写入替换；写死地址；Telegram Bot API；WebView JS 桥 | 网络上传；`UIPasteboard` 写入；写死地址；第三方 BaaS/自建域名 | 中（端点与地址可见，是否外传不可见） |
| **⑤ 抗分析** | 加固壳；字符串加密；`ptrace` 反调试；模拟器/root 检测；JNI 静态链接 | 二进制加密 `cryptid=1`；ObjC 名混淆；字符串加密；越狱检测；`PT_DENY_ATTACH` | 弱—中（能识别"有抗分析"，识别不出被保护内容） |

### 3.4 平台差异（不要照搬）

- **Android** 有真正的"无障碍 + 悬浮窗"组合，能读屏/模拟点击，是盗 U **最危险的通道**；iOS 没有等价能力，主要靠**假 UI 骗输入 + 剪贴板替换 + 假钱包**。
- **iOS** 的"安装"受签名约束，**企业签/Ad-Hoc/重签**是主流投递；`.app` 根目录 dylib 是实测强特征。
- **Android** 的"添加代码"常见形式：多 DEX / 伪装 `.so`（内容是 DEX）/ assets 里的 DEX / 动态加载；**iOS** 是：注入 dylib / Framework / 修改主二进制 / 重签。

---

## 4. 可探测性与置信度

### 4.1 技术点 × 静态可探测性

| 技术点 | Android | iOS | 需要的证据 | 主要误报来源 |
|---|---|---|---|---|
| 剪贴板地址替换 | **中** | **中** | 读/写剪贴板调用点 + 地址字面量 + 钱包语境（同方法体/共现） | 正规钱包/交易所、复制按钮 |
| 助记词/私钥外传 | **中** | **中** | 密钥材料标记 + 网络/上传 + 输入 UI（中文串） | 正规钱包、加密库、备份功能 |
| 无障碍/悬浮窗钓鱼 | **强（能力）** | 不适用 | `BIND_ACCESSIBILITY_SERVICE` 组件 + `SYSTEM_ALERT_WINDOW` + 钱包语境 | 输入法、辅助工具、自动化 App |
| iOS 剪贴板替换 | —— | **中** | `UIPasteboard` 类/选择子 + 地址 + 钱包框架 | 所有带"复制"的 App |
| WebView JS 桥/注入 | **中** | **中** | `addJavascriptInterface`/`evaluateJavascript`/`WKUserScript` + 钱包域名/地址 | 正常 H5 钱包、DApp 浏览器 |
| 授权/签名钓鱼（approve/permit） | **中** | **中** | `approve`/`permit`/`signTypedData`/`eth_sign` + 钱包语境 + 远程 URL | 正规钱包/DApp |
| 注入 dylib | —— | **强** | `.app` 根 dylib、`LC_LOAD_DYLIB` 异常路径、嵌套签名/Team | 用户自己注入的插件、企业工具 |
| 重签名/企业签 | **中** | **强** | 证书/Team/描述文件/`Signature=adhoc` | 企业内部分发、TestFlight |
| 官方包冒充 | **强（有基线）** | **强（有基线）** | 包名/Bundle ID + 证书/Team 与官方基线比对 | 官方换证书（需更新基线） |
| 可疑 `.so`/DEX 载荷 | **中** | **中** | 加载器 + 未解析库/资产载荷 + 节熵/字符串/符号 | 热修复、插件化、游戏引擎 |
| 加壳/加密 | **弱–中** | **弱–中** | 壳识别 + 节熵 + 字符串密度 + 覆盖缺口 | 正规加固（企业 App 常见） |
| 远程加载/热更新 | **弱** | **弱** | 加载器 + 远程地址 + 无本地载荷 | 热修复框架、H5 容器 |
| 官方基线 | **强** | **强** | 包名/Bundle ID + 证书/Team 与官方基线比对 | 官方换证书（需更新基线） |
| 家族情报 | 延期（无语料） | 延期（无语料） | 需恶意样本/IoC 库 | 无语料无法建立/验证 |
| 服务端行为/社工话术 | **不可** | **不可** | 运行时/服务端 | —— |

> **"强"指静态证据本身确定性高，不指"恶意"确定性高。** 例如"注入 dylib"能确定文件存在，但不能确定它做什么。

### 4.2 三个必须诚实回答的问题

**Q：没有原始官方包，能不能证明"被添加了恶意代码"？**

不能证明，只能给"异常证据"。可用替代证据（按强度排序）：
1. **签名/密封不一致**：Android v1/v2 摘要不符、未签名/证书异常；iOS `codesign` 失败、CodeResources 哈希不匹配、描述文件与 Bundle ID 不匹配；
2. **注入布局**：iOS `.app` 根目录 dylib（实测 7/7 命中、0/3 误报）、异常的 `LC_LOAD_DYLIB` 路径；
3. **加载链异常**：代码加载了包内不存在的库、从 assets/下载路径加载 DEX/so；
4. **载荷形态异常**：伪装 DEX 的 `.so`、assets 里的可执行文件、加密/加壳的本地库；
5. **官方基线**（若有）：包名/Bundle ID 匹配官方但证书/Team 不匹配。

**Q：正规钱包会不会被误报？**

会。正规钱包天然具备"钱包 SDK + 剪贴板 + 地址字面量 + 剪贴板替换实现"——这正是盗 U 的能力组合。因此：
- 单靠能力组合**永远不能**升到 P1/"恶意"；
- 必须引入**官方基线/签名来源/注入异常**才能升级；
- 没有基线的正规钱包，最多 P2 "需人工核对"，并在正文明确"正规钱包同样具备"。

**Q：加密/加壳/远程加载的包怎么办？**

只能给"无法判断"（`SecuritySeverity.unknown` / `unknown` confidence），并把缺口写进覆盖维度。**不允许**因为"没看到"就报"未发现风险"。

### 4.3 三态输出（PASS / HIT / UNKNOWN）

| 状态 | 含义 | UI 文案 |
|---|---|---|
| **PASS** | 本次覆盖范围内已检查、未发现证据 | "未发现（本次覆盖 X，未覆盖 Y）" |
| **HIT** | 有证据（能力/载荷/注入/官方基线） | "发现能力线索/疑似/强证据/与官方基线不一致"（家族命中延期） |
| **UNKNOWN** | 加壳/加密/预算截断/工具缺失/无基线，无法判定 | "无法判断（原因）+ 建议" |

> 现状风险：iOS 侧 findings 无 `blindSpots` 字段（R9），预算截断可能被读成"未发现"；必须补齐。

**D3 输出约束**：不输出"木马/恶意"；P1 只用于事实级（官方基线不匹配/密封不匹配）；其余最高 P2，且必须带"疑似/线索"措辞。

---

## 5. 总体架构

### 5.1 分层

```
┌───────────────────────────────────────────────────────────────┐
│ 呈现层  UI（盗 U 证据链卡片）/ Markdown / JSON / 安全章节导出    │
├───────────────────────────────────────────────────────────────┤
│ 关联层  CryptoTheftAssessment：五段证据链 + 缺失环节 + 判级      │
├───────────────────────────────────────────────────────────────┤
│ 证据层  SecurityFinding（技术点）/ ArtifactInventory / LoadGraph │
│         SealCheck / IocMatch                                    │
├───────────────────────────────────────────────────────────────┤
│ 采集层  Android：DEX/ELF/条目事实/签名材料                       │
│         iOS：Mach-O 清单/字符串(ASCII+UTF-16)/引用表/密封        │
├───────────────────────────────────────────────────────────────┤
│ 输入    已解析的 App 归档（不执行、不联网）                       │
└───────────────────────────────────────────────────────────────┘
```

### 5.2 新增组件（文件级建议，契约冻结 v1）

| # | 文件（新增/改） | 职责 | 输入 → 输出 | 预算 |
|---|---|---|---|---|
| C1 | `analysis_model/lib/src/container_facts.dart` | 平台无关的归档条目事实 | —— | —— |
| C2 | `analysis_model/lib/src/artifact_inventory.dart` | 制品清单模型 | —— | —— |
| C3 | `apk_parser/lib/src/security/artifact_inventory_scanner.dart` | APK 条目 → 分类清单（**不读内容**） | 条目事实 → `ArtifactInventory` | 条目 ≤20 000，清单 ≤2 000 |
| C4 | `ipa_parser/lib/src/security/ios_artifact_inventory.dart` | IPA 条目 → 清单（含 framework/bundle 归组） | 同上 | 同上 |
| C5 | `analysis_model/lib/src/load_graph.dart` | 加载链模型 | —— | —— |
| C6 | `apk_parser/.../android_load_graph.dart` | `loadLibrary`/`dlopen`/`System.load` 字面量 × 包内 `.so` 对账 | DEX 标记 + 原生串 + 清单 → `LoadGraph` | 边 ≤5 000 |
| C7 | `ipa_parser/.../ios_load_graph.dart` | `LC_LOAD_DYLIB`/`LC_RPATH`/`LC_ID_DYLIB` × 包内路径对账 | `MachOFile` + 清单 → `LoadGraph` | 边 ≤5 000 |
| C8 | `apk_parser/.../payload_probe.dart` | 载荷探测：魔数/熵/嵌套归档/伪装扩展名（读**有界**头部） | 条目头 ≤4 KiB × N → `PayloadSignal` | ≤256 条目、≤1 MiB |
| C9 | `ipa_parser/.../ios_payload_probe.dart` | 同上（`.bundle`/`.framework`/assets/`Frameworks/*.dylib`） | 同上 | 同上 |
| C10 | `analysis_model/lib/src/package_seal.dart` | 密封结果模型 | —— | —— |
| C11 | `apk_parser/.../apk_seal_check.dart` | APK v1 MANIFEST 摘要 + v2 内容摘要**比对** | 条目字节 + `ApkSigningSchemes` + `ContentDigestFn` → `SealCheck` | ≤64 条目 / 32 MiB |
| C12 | `ipa_parser/.../ios_code_resources_check.dart` | CodeResources `files/files2` 逐文件哈希比对 | 归档 + 摘要函数 → `SealCheck` | 同上 |
| C13 | `analysis_model/lib/src/crypto_theft.dart` | 证据链/评估模型 | —— | —— |
| C14 | `apk_parser/.../crypto_theft_chain.dart` | Android 证据链装配 + 判级（纯函数） | 规则事实 → `CryptoTheftAssessment` | O(信号数) |
| C15 | `ipa_parser/.../ios_crypto_theft_chain.dart` | iOS 同上 | 同上 | 同上 |
| C16 | `analysis_model/lib/src/ioc.dart` | 家族签名模型 + 匹配器接口（**延期，接口先留**） | —— | —— |
| C17 | `analysis_model/lib/src/official_baseline.dart` | 官方包基线模型（证书/Team，**必需**） | —— | —— |
| C18 | `apk_parser/lib/src/apk_reader.dart`（改） | 暴露一次遍历得到的条目事实表 | `Archive` → `List<ContainerEntryFact>` | 复用中央目录遍历 |
| C19 | `analysis_model/lib/src/security_finding.dart`（改） | 新证据来源 + `SecurityAnalysisResult` 新一级字段 | —— | —— |
| C20 | `lib/utils/crypto_theft_assessor.dart`（新） | 汇总：静态证据 + 签名/基线/IOC → 评估 | findings + signature + baseline + ioc | 纯函数 |
| C21 | `lib/utils/official_baseline_store.dart`（新） | 加载离线**官方基线**库（完整性校验/版本）；家族 IoC 延期 | 内置 JSON → DB | ≤1 MiB / ≤512 条 |
| C22 | `lib/widgets/crypto_theft_card.dart`（新）、`lib/utils/analysis_report.dart`（改）、`lib/pages/info_page.dart`（改） | 证据链卡片 + Markdown/JSON 同源导出 | —— | —— |

> **依赖约束**：`analysis_model` 保持零依赖；`apk_parser`/`ipa_parser` **不新增** `crypto` 依赖。哈希通过注入的 `ContentDigestFn` 由应用层实现（见 ADR-03）。IoC/基线库由应用层加载后注入审计（parser 包不读 Flutter assets）。

### 5.3 数据流

```
打开包
  → 解析（现有）
  → Android: parse_task worker 内跑安全审计（现有 + 新采集/规则）
  → iOS: 解析完成后，把安全审计移入后台任务（新），不再在 UI 线程跑
  → 静态结果先呈现（findings + coverage）
  → 签名工具（apksigner/codesign，可选）
  → CryptoTheftAssessor：静态证据 + 签名结论 + 官方基线（家族情报延期）
  → 最终 CryptoTheftAssessment 更新到 UI/报告/JSON
```

**两阶段原因**：签名/`codesign` 是外部进程，耗时且可能不可用；静态证据必须先出。评估要显式标注"签名未检查"，不能因为签名没跑就把"无法判断"显示成"未发现"。

### 5.4 iOS 审计移出 UI 线程（前置改造）

现状：`lib/pages/info_page.dart:429` 在解析完成后同步调用 `IosPrivacyAudit.audit`。新增制品清单/CodeResources 哈希/UTF-16 扫描会显著增加主线程耗时。

建议：
- 在 `lib/ipaparser/ipa_parse_task.dart`（或新建 `IpaSecurityTask`）里跑安全审计；
- 产出 `IpaParseSucceeded` 时带上 `security`；
- UI 只消费结果，保留取消/进度事件；
- 与 Android 的 `parse_task` 对齐；复用现有 `CancellableTask` 与生命周期测试（2.8.6 黑屏 bug 的教训）。

---

## 6. 数据模型与契约（字段级）

> 原则：**只增不改**，旧报告可读；`null` = 本次未做/不可得，`unknown` = 做了但判不出。**禁止**用空列表/空串表示二者。

### 6.1 归档条目与制品清单

```dart
class ContainerEntryFact {
  final String path;            // 归一化，'/' 分隔，稳定排序
  final int sizeBytes;          // 未压缩大小
  final int? compressedBytes;
  final int? compressionMethod; // ZIP method；非 ZIP 容器为 null
  final bool isDirectory;
}

enum ArtifactKind { dex, elf, machO, dylib, framework, staticLibrary,
                    nestedCodeBundle, assetArchive, assetBinary, assetText,
                    script, resourceTable, manifest, signatureBlock, unknown }

class ArtifactEntry {
  final String path;
  final ArtifactKind kind;
  final int sizeBytes;
  final String? sha256;             // null = 未哈希（未做/超预算），绝不填空串
  final bool contentScanned;
  final String? skipCode;           // 'budget.size' | 'budget.count' | 'not.selected'
  final List<String> suspicionCodes; // 'payload.encrypted' | 'payload.nestedArchive'
}

class ArtifactInventory {
  final List<ArtifactEntry> entries;
  final int totalEntries;
  final int inventoriedEntries;
  final bool entriesComplete;
  final List<String> skippedCodes;
}
```

### 6.2 加载链

```dart
enum LoadNodeKind { dex, elf, machO, dylib, framework, script, missing, unknown }
enum LoadEdgeKind { systemLoadLibrary, systemLoad, dexClassLoader,
                    inMemoryDexLoader, nativeDlopen, nativeDlsym,
                    machoLinkedLibrary, machoWeakLinked, machoRPath,
                    bundleEntryReference, unknown }

class LoadEdge {
  final String fromId;
  final String toId;
  final LoadEdgeKind kind;
  final SecurityEvidenceSource source;
  final String location;        // 调用点偏移 / load command 序号
  final bool presentInPackage;
}
class LoadGraph {
  final List<LoadEdge> edges;
  final List<String> danglingEdgeIds; // 目标不在包内 = 强信号
  final bool complete;
}
```

### 6.3 密封校验

```dart
enum SealState { verified, mismatch, entryMissing, unsealed, notChecked, unknown }

class SealEntryCheck {
  final String path;
  final SealState state;
  final String algorithm;            // 'sha256' | 'sha1' | 'md5'
  final String? expectedDigestPrefix; // 前 16 hex，够报告比对
  final String? actualDigestPrefix;
}
class SealCheck {
  final String scheme;   // 'apk.v1.manifest' | 'apk.v2.content' | 'ipa.codeResources.v1|v2'
  final SealState state; // 任一 mismatch → mismatch
  final int entriesChecked;
  final int entriesTotal;
  final List<SealEntryCheck> checks; // ≤64，mismatch 优先
  final bool signatureVerified;      // **恒 false**（本版本不验签）
  final List<String> noteCodes;      // 'seal.digest_unavailable' ...
}
```

> `SealState.verified` 只表示"摘要与密封清单一致"，**不表示签名有效**。UI/报告必须用"密封一致"而不是"签名有效"。

> 哈希实现由应用层注入 `ContentDigestFn`（见 ADR-03）；未注入时 `state=notChecked` + 覆盖 `notCovered`，**不得**显示 `verified`。

### 6.4 评估与证据链

```dart
enum TheftTechnique { addressSwap, clipboardHijack, mnemonicPhish,
                      keyExfiltration, approvalPhish, unknown }
enum ChainStage { capability, source, injection, payload, family } // 五段

class TechniqueEvidence {
  final TheftTechnique technique;
  final ChainStage stage;
  final String signalId;
  final bool supported;
  final List<SecurityEvidence> evidence;
}
class MissingLink {
  final ChainStage stage;
  final String whyCode; // 'missing.noSource' | 'missing.noSink' | ...
  final Map<String, Object> args;
}
class CryptoTheftAssessment {
  final String id;                       // 'android.crypto.theft' | 'ios.crypto.theft'
  final TheftTechnique? primaryTechnique; // null = 判不出
  final List<TechniqueEvidence> chain;   // 固定 5 段
  final List<MissingLink> missing;
  final SecurityConfidence confidence;
  final SecuritySeverity severity;
  final int? score;                      // 0..100；null = 未评分
  final String scoringVersion;           // 'theft-1.0'
  final String? familyId;                // 命中官方基线时非空（IoC 延期）
}
```

### 6.5 对既有模型的增量

| 位置 | 变更 | 兼容性 |
|---|---|---|
| `security_finding.dart:145` `SecurityEvidenceSource` | 新增 5 项：`artifactEntry`、`loadGraph`、`sealDigest`、`iocDatabase`、`officialBaseline`；**不加** `dexCallSite`（调用点继续用 `dexMethodReference`，避免同一事实两种来源） | 枚举增量；`label` switch 需补 5 个分支 |
| `SecurityAnalysisResult` | 新增可空字段 + 默认值：`cryptoTheft`、`artifacts`、`loadGraph`、`seal`、`iocMatches = const []` | 现有 100+ 处构造不改 |
| `SecurityAnalysisResult.withLimitation` | **必须补拷 5 个新字段** | 已知同类缺陷：`withDedupedEvidence` 曾漏拷 `*Code`；列入测试 |
| `CoverageEntry` | 新增维度（见 §6.6） | 纯增量 |

### 6.6 JSON schema 与覆盖维度

- `reportSchemaVersion` 7 → **8**（`analysis_report.dart:2196`）。纯增量：新增顶层 `security` 对象（`cryptoTheft` / `artifacts` / `loadGraph` / `seal` / `baseline`）；`securitySummary` 与既有键名/类型/含义不变；`iocMatches` deferred。
- 每个新块必须有 `status`（`covered|partial|notCovered|notApplicable|unknown`），沿用 `_fieldStatus` 命名。
- 新增 `CoverageEntry`：

| 维度 id | covered | limit |
|---|---|---|
| `android.artifacts` | `inventoriedEntries` | `totalEntries` |
| `android.loadGraph` | 已解析边数 | 检测到的加载点总数 |
| `android.payloadProbe` | 已探测条目数 | 需探测条目数 |
| `android.seal` | `entriesChecked` | `entriesTotal` |
| `ios.artifacts` / `ios.loadGraph` / `ios.payloadProbe` / `ios.seal` | 同上 | 同上 |
| `android.dex.unicodeStrings` / `ios.unicodeStrings` | 已扫字节/条数 | 总字节/总条数 |
| `crypto.theft.chain` | 已评估技术点数 | 适用技术点数 |

口径：`partial` 的分子分母必须来自**同一次遍历的同一计数**；分母不可得时 `limit=null` 并标 `notCovered`（沿用 `nativeLibraryTotal` 的教训）。

---

## 7. 检测规则与判级算法

### 7.1 规则清单（16 条设计；本期启用 14 条，2 条 IoC 延期）

**Android（9 条）**

| 规则 ID | 证据来源 | 判级条件 | confidence | 必需覆盖 |
|---|---|---|---|---|
| `ANDROID-THEFT-CHAIN` | 组合 | 五段链 ≥3 段且含 injection/payload → suspected；含 seal mismatch / 官方基线不匹配 → confirmed（IoC 延期） | suspected/confirmed | inventory + loadGraph + dex.strings + seal |
| `ANDROID-CLIPBOARD-ADDRESS-SWAP` | dexMethodReference + artifactEntry | 剪贴板写 API + 地址字面量 + 钱包语境，且**无**对应读来源 | P2 suspected | dex.methodReferences |
| `ANDROID-MNEMONIC-EXFIL` | dexMethodReference | 助记词/BIP39 标记 + 网络写出调用点同现 | P2 suspected | dex.callSites |
| `ANDROID-PAYLOAD-DROPPED` | artifactEntry + dexMethodReference | `payload.encrypted`/`nestedArchive` + `DexClassLoader`/`InMemoryDexClassLoader`/`dlopen` | P1 suspected | inventory + dex.strings |
| `ANDROID-LOAD-GRAPH-DANGLING` | loadGraph | `loadLibrary/dlopen` 目标不在包内且非系统库 | P2 suspected | loadGraph + inventory |
| `ANDROID-APK-SEAL-MISMATCH` | sealDigest | v1/v2 摘要不一致，或条目未列入密封清单 | **P1 confirmed** | seal |
| `ANDROID-ACCESSIBILITY-ABUSE` | manifest + dex.strings | 无障碍服务 + 剪贴板/地址/钱包任一 | P2 suspected | manifest + dex.strings |
| `ANDROID-OFFICIAL-BASELINE-MISMATCH` | officialBaseline | 包名命中官方基线，证书 SHA-256 不匹配 | **P1 confirmed** | inventory + baseline |
| `ANDROID-IOC-FAMILY-MATCH` | iocDatabase | **延期（D1 无语料）**；接口保留：strong 命中 P1 / weak P2 | confirmed/suspected | inventory + nativeSymbols |

**iOS（7 条）**

| 规则 ID | 证据来源 | 判级条件 | confidence | 必需覆盖 |
|---|---|---|---|---|
| `IOS-THEFT-CHAIN` | 组合 | 同 Android（含 seal/基线/IOC 触发 confirmed） | suspected/confirmed | inventory + loadGraph + machoSites + seal |
| `IOS-CLIPBOARD-ADDRESS-SWAP` | machoSymbol | `UIPasteboard` + 地址字面量 + 钱包框架 | P2 suspected | ios.macho.strings |
| `IOS-SEAL-MISMATCH` | sealDigest | 代码类条目实际摘要 ≠ CodeResources 记录 | **P1 confirmed** | seal |
| `IOS-INJECTED-DYLIB-LOADED` | loadGraph | 根目录 dylib 且被主二进制 `LC_LOAD_DYLIB` 引用（或 `@rpath` 可达） | P2 confirmed（文件+引用事实） | loadGraph + inventory |
| `IOS-DANGLING-LOAD` | loadGraph | `LC_LOAD_DYLIB`/`@rpath` 目标不在包内（含 `/Library/MobileSubstrate/…`） | P2 suspected | loadGraph |
| `IOS-OFFICIAL-BASELINE-MISMATCH` | officialBaseline | Bundle ID 命中官方基线，Team ID/证书不匹配 | **P1 confirmed** | inventory + baseline |
| `IOS-IOC-FAMILY-MATCH` | iocDatabase | **延期（D1 无语料）**；接口保留 | confirmed/suspected | inventory + machoSymbol |

**兼容**：现有 `ANDROID-CRYPTO-THEFT-RISK` / `IOS-CRYPTO-THEFT-RISK` 保留 1 个大版本，内部改为由 `CryptoTheftAssessment` 驱动，避免两套判据漂移；下一大版本 deprecated。

**启用顺序**：2 条 IoC 规则延期；MVP（A+B+C）只启用能力/加载链/载荷类规则；密封与基线规则在 D/E 完成后启用。

### 7.2 五段证据链

| 段 | 含义 | Android 事实 | iOS 事实 |
|---|---|---|---|
| capability | 具备盗 U 所需能力 | 钱包 SDK / 密钥材料 / 剪贴板 / 无障碍 / 短信 | 钱包框架 / 剪贴板 / 地址字面量 |
| source | 地址或密钥从哪来 | 剪贴板读、输入框 | `UIPasteboard.general.string` |
| injection | 代码从哪进来 | 动态加载 + 加密载荷、壳、悬空加载边 | 根目录 dylib + `LC_LOAD_DYLIB`、`@rpath` 重定向 |
| payload | 可疑载荷存在 | 高熵/嵌套归档/伪装扩展名/加固 | 同上（`.bundle`、`Frameworks`） |
| family | 归属已知家族/官方基线 | 官方基线命中（IoC 延期） | 官方基线命中（IoC 延期） |

### 7.3 判级（纯函数，可单测）

```
stages = 已 supported 的段集合
score  = (10*capability + 20*source + 30*injection + 25*payload + 35*family) / 120 * 100  // 归一化到 0..100
severity:
  if sealMismatch || ioc.strong || baselineMismatch        -> P1（confirmed）
  else if {injection, payload} ⊆ stages && walletCtx        -> P1
  else if injection ∈ stages && family ∈ stages             -> P1
  else if |stages ∩ {capability,source}| == 2 && injection∈stages -> P2
  else if walletCtx && source∈stages && capability∈stages  -> P3（线索）
  else if 任一能力事实                                       -> P3
  else                                                      -> 不产出（否定结论由 RULE-F 覆盖）
confidence:
  confirmed            : sealMismatch / ioc.strong / baselineMismatch
  suspected            : ≥2 段，且至少两段来自不同证据来源
  independentCapability: 仅 capability / 仅孤立事实
  unknown              : 某必需维度 status ∈ {partial, notCovered}
```

### 7.4 防误报分层（正规钱包不得被判木马）

1. **钱包语境是"合理性折扣"不是加分**：`walletCtx=true` 时纯 capability 组合最高 P3，永不单独进 P2。
2. **P1/P2 的门槛是"外部注入"或"载荷"**，不是"能力齐全"——正规钱包有私钥、剪贴板、网络，但没有 injection/payload。
3. **否定证据参与判级**：有剪贴板写但**无**地址来源、有地址但**无**剪贴板读 → 只报 P3 并写入 `missing`。
4. **官方基线命中优先于能力**：官方基线不匹配直接 P1（IoC strong 延期；此时能力常被混淆掉）。
5. **措辞强制**：`severity ≤ P2` 且 `confidence != confirmed` 时正文必须含 "triage lead, not a verdict"（或本地化等价句）。

### 7.5 "缺关键一环"的表达

`MissingLink(stage, whyCode)`，`whyCode` 归一：
`missing.noSource`（有替换无来源）、`missing.noSink`（有材料无去路）、`missing.payloadEncrypted`（载荷读不出）、`missing.notCovered.<dimension>`、`missing.shellPacked`。

**规则**：每个 `supported=false` 的段都必须有对应 `MissingLink`，由单测强制（链段数与 missing 覆盖一一对应）。

### 7.6 与 P0–P3 / 四态 confidence 的关系

不扩展枚举（ADR-06）。阶段信息放在 `CryptoTheftAssessment.chain`。`SecuritySeverity.unknown` 只用于"必需维度被截断导致无法判级"，并**必须**同时存在对应 `CoverageEntry.partial/notCovered`，否则视为缺陷（测试断言）。

---

## 8. 分技术设计

### 8.1 制品清单（Android / iOS）

**Android**
- 枚举：`classes*.dex`、`lib/<abi>/*.so`、`assets/**`（按扩展名/魔数）、`META-INF` 签名材料、分包（XAPK/APKS 只审 base 的问题要写明）。
- 记录：路径、大小、ABI、SHA-256（预算内）、是否被 DEX 引用（加载链）、是否命中壳/伪装/加密信号。
- 复用：`ApkReader.listFilesWithSize`、`NativeSymbolScanner.selectLibraries`（24 库/96 MiB）、`hardening.dart`。

**iOS**
- 枚举：主可执行文件、`.app` 根目录 dylib、`Frameworks/**` 二进制、嵌套 `.appex`/Watch/框架、`_CodeSignature/CodeResources`。
- 逐 Mach-O：架构、UUID、`LC_LOAD_DYLIB`/`LC_RPATH`/`LC_ID_DYLIB`、`LC_CODE_SIGNATURE` 是否存在、`cryptid`（现有 `macho_crypt_id.dart`）。
- 记录：路径、大小、架构、`Frameworks` vs 根目录、是否被主二进制引用、签名段存在性。
- 预算：解析前 N 个二进制（建议 64 个 / 64 MiB；现有嵌套上限 24 个，需评估是否提高）。

### 8.2 加载链（区分"包内"与"运行时下载/解密"）

**Android**
- 目标 API：`DexClassLoader` / `InMemoryDexClassLoader` / `PathClassLoader`、`System.loadLibrary(String)` / `System.load(String)`、`Runtime.exec`/`ProcessBuilder`、原生 `dlopen`（现有 `nativeSymbol`）。
- 参数解析（**新增，有限**）：在调用点附近向前找 `const-string` / `const-string/jumbo`，解析寄存器简单赋值（只处理"紧邻常量"与"单次 MOV"），失败标"未解析"，不猜；解析出的库名与制品清单比对：`presentInPackage`。
- 目标不在包内 → "悬空加载边"（P2 suspected，不直接判恶意）。
- 现有基础：`DexInsnWalkResult.invokes` 给出偏移，`DexInstructionTable` 宽度表可靠（已有 `dexdump` 对照测试）。

**iOS**
- `LC_LOAD_DYLIB`（含 weak/reexport/upward）路径解析；`LC_RPATH`；`LC_ID_DYLIB`。
- 异常判据：路径含 `/Library/MobileSubstrate/`、`/usr/lib/frida`、`@executable_path/../` 等非标准位置；同一镜像引用包内不存在的 dylib；`.app` 根目录 dylib（已有）。
- `dlopen`/`dlsym`/`NSClassFromString`：从符号表/字符串找引用（无字节码，不能给调用点；标 `machoSymbol`，置信度低于 DEX 调用点）。

### 8.3 载荷探测

| 检测 | 方法 | 误报控制 |
|---|---|---|
| `.so` 实为 DEX | 现有 `HardeningSignal.dexDisguisedAsNativeLibrary` | 升级为独立 finding（审计 P2-9） |
| assets 里的代码 | 扩展 `executableInAssets`：按魔数识别 DEX/ZIP/APK/ELF/Mach-O；记录大小/熵 | 正常 App 也会放 JS/模型；仅在"同时有加载器/钱包语境"时升级 |
| 加密/加壳 | 节熵 + 字符串密度（现有 `looksPacked`）+ 壳目录 | 正规加固也命中；只作为"看不清"的覆盖缺口 |
| 嵌入归档 | ZIP 内嵌 ZIP/APK/JAR；`assets/*.zip`、`*.jar` | 正常资源包/离线包；需要"加载器引用该路径"才升级 |
| iOS 注入库 | 根目录 dylib（现有）+ `Frameworks` 非常规命名/无签名段/Team 不一致 | 用户插件、企业工具；需结合签名/描述文件 |

**熵的用法**：只做辅助，不单独判恶意；节熵高 + 字符串密度低 + 无 `.dynsym` + 有加载器 → 可疑；正文写"这是遮挡，不是结论"。

### 8.4 密封/完整性校验

**iOS（可离线，最强）**
1. **CodeResources 哈希校验**（新增 C12）：
   - 解析 `_CodeSignature/CodeResources` 的 `files`（SHA-1 base64）与 `files2`（`hash2` SHA-256 / `hash` SHA-1）；
   - 对选中文件（`Info.plist`、`Frameworks/**`、`.app` 根文件、嵌套 bundle 的 `Info.plist`）重算哈希并比对；
   - 不匹配 → "签名后被修改"（`confirmed` 的文件事实）；
   - 清单有但文件缺失 / 有代码文件不在清单 → "新增/缺失"异常；
   - 预算：≤64 个文件 / 64 MiB；超出记 partial。
   - **边界**：重签名工具会重算 CodeResources，**校验通过不代表未被注入**；它抓的是"改文件没重签"。
2. **签名/描述文件**（复用现有）：`codesign --verify` 结论（工具缺失 → `toolUnavailable`，不是"无效"）；TeamIdentifier/Authority/`Signature=adhoc`/Identifier/CDHash；描述文件 App ID vs `CFBundleIdentifier`；`get-task-allow`、过期、`ProvisionsAllDevices`（当前未建模，需补字段）。
3. **官方基线比对**（二期）：Bundle ID + Team ID/证书 SHA-256 与官方基线；不匹配 → "冒充/重签"强证据。

**Android**
1. **签名/证书**（复用 `SignatureAnalysis`）：`apksigner` 结论、验证 scheme、签名者证书 SHA-256（`localCertificateSha256` / `signers[].sha256Digest`）；v1-only/未签名/debug 证书/自签名/多签名者；官方基线比对（二期）。
2. **v1 MANIFEST 摘要**（新增 C11）：解析 `META-INF/MANIFEST.MF` 每条目的 `SHA-256-Digest`（或 SHA1），重算比对；v1 只保护条目内容，不保护 ZIP 结构 → 额外条目可被检出（若清单未覆盖）。
3. **v2 内容摘要**（新增 C11）：解析 APK Signing Block 的 signed data（digest 算法 + 内容摘要），按 AOSP 分块规则重算（1 MiB 块 + 前缀）并比对；**不验签**（无密码学验签），因此只证明"内容与签名块记录的摘要一致/不一致"。
4. **边界**：攻击者重签后会生成新的摘要 → 上述校验通过；此时只能靠**官方基线**证明冒充。MVP 不自己实现 v2 签名验证（见 ADR-03）。
5. **结构**：v1-only、`META-INF` 异常、分包签名一致性、多 DEX/伪装 DEX/assets 代码、`debuggable`/`allowBackup`/cleartext。

> **结论**：iOS 侧离线完整性证据更强（CodeResources + 布局 + 描述文件）；Android 侧"被添加"的强结论依赖摘要校验 + 官方基线。设计上不夸大 Android 的离线证明力。

### 8.5 能力链（盗 U 行为形态）

| 技术点 ID | 判据 | 基线等级 | 置信度 | 缺失环节示例 |
|---|---|---|---|---|
| `T-CLIPBOARD-SWAP` | 钱包语境 + 剪贴板**写**调用点 + 地址字面量（+ 地址解析/校验代码） | P2 | suspected | "未找到地址来源（网络/输入）" |
| `T-SEED-EXFIL` | 密钥材料标记 + 网络/上传能力 + 输入 UI/WebView 表单 | P2 | suspected | "未找到把输入送到网络的路径" |
| `T-ACCESSIBILITY-UI-ABUSE`（A） | 无障碍服务组件 + 悬浮窗权限 + 钱包语境 | P2 | suspected | "未找到读取屏幕/点击的实现" |
| `T-WEBVIEW-INJECTION` | JS 桥/`evaluateJavascript`/`WKUserScript` + 钱包域名/地址 | P2 | suspected | "未找到被注入的 JS 内容（远程）" |
| `T-APPROVAL-PHISHING` | `approve`/`permit`/`signTypedData`/`eth_sign` + 钱包语境 + 远程 URL | P2 | suspected | "未证明签名请求来自外部页面" |
| `T-DYNAMIC-PAYLOAD` | 加载器调用 + 目标不在包内 / assets 载荷 / 加密节 | P3→P2（与钱包语境） | suspected | "载荷不在包内，无法检查" |
| `T-INJECTED-DYLIB`（iOS） | `.app` 根 dylib / 异常 `LC_LOAD_DYLIB` / 嵌套签名异常 | P2 | confirmed（文件事实）/ suspected（意图） | "不知道注入库做什么" |
| `T-REPACKAGED`（双端） | 签名/证书/描述文件/CodeResources 异常 | P2 | confirmed（异常事实） | "没有官方基线，无法证明是篡改" |
| `T-OFFICIAL-IMPERSONATION`（二期） | 官方基线：包名/Bundle ID 匹配但证书/Team 不匹配 | **P1** | confirmed | —— |
| `T-KNOWN-FAMILY`（**延期**） | 情报库命中（哈希/类名/库名/域名/地址/证书） | P1/P2（无可验证语料，先不启用） | confirmed（对已知） | "情报库版本/覆盖范围" |

### 8.6 中文/UTF-16 字符串（当前最大盲区之一）

现状：`AsciiStrings.extract` 只提取 ≥6 字符的 ASCII；DEX 的 MUTF-8 中文、Swift/ObjC 的 UTF-16 中文都看不到；`code_markers.dart` 注释明确"中文标记是死规则"。

设计：
- **DEX**：从 `string_ids`/`string_data` 解 MUTF-8（现有 `DexTables` 可读），过滤为 Unicode 文本；预算（如 20 万条/16 MiB）后匹配中文关键词（"助记词/私钥/导入钱包/收款地址/转账/授权/客服/解冻/空投/验证/节点/能量/带宽/归集"）与英文/拼音变体。
- **iOS**：扫描 `__TEXT,__cstring`（UTF-8）与 `__TEXT,__ustring`/UTF-16LE 段；Swift 小字符串优化可能不在段里，要写明"可能看不到"。
- **避免误报**：中文词只作为"能力/话术线索"，不单独判级；与钱包语境/加载器/网络组合才升级；命中原文进证据。
- **覆盖**：新增 `ios.unicodeStrings` / `android.dex.unicodeStrings` 覆盖维度；预算截断记 partial。

### 8.7 官方基线（L4 唯一路径）与家族情报（延期）

**D2 已确认：维护 Top 20–30 钱包/交易所的官方证书/Team 基线。** 这是本方案唯一能"证明冒充/重签"的静态路径，不依赖恶意语料。

**基线库**
- 内容：包名/Bundle ID + 证书 SHA-256 集合 + iOS Team ID 集合 + 官方来源（应用商店 URL/日期/获取方式）。
- 范围：先覆盖 Top 20–30 钱包/交易所（imToken、TokenPocket、MetaMask、Trust、OKX、Binance、Coinbase、Bitget、Bybit、Kraken、Uniswap、Phantom、Solflare…）；首批清单需产品确认。
- 匹配：
  - 包名/Bundle ID 命中 + 证书/Team **不在**基线集合 → `T-OFFICIAL-IMPERSONATION` **P1 confirmed**；
  - 命中且在集合内 → `baselineMatch`，用于**降低**能力链误报（官方包不因能力组合被判 P2）。
- 多证书：Play App Signing 轮换、历史签名、企业重签历史 → 基线按**集合**匹配，不能只存一张。
- 维护：JSON 内置 + 版本号 + 来源注释；更新走发版或签名的离线更新包（ADR-04）；每次更新记录"新增/移除/证据来源"。
- **数据来源是硬依赖**：基线需要官方安装包或公开的证书/Team 指纹。若连官方包也无法获取，基线只能"预置但未验证"，UI 必须标 `baselineUnavailable`，**不得**用它下 P1 结论。
- 法律：证书指纹/Bundle ID 是公开信息；**不分发官方包本体**；只存指纹，不存样本。

**家族/IoC 库（D1 明确延期）**
- 不提供恶意样本 → 无法建立/验证家族库；本期**不启用** `T-KNOWN-FAMILY`。
- 保留 `IocRule` / `IocMatch` 接口与 `ANDROID/IOS-IOC-FAMILY-MATCH` 规则 ID，待将来有合法语料/情报源时再启用。
- 将来接入时仍遵守：条目可解释、版本号、完整性校验、不自动上传。

---

## 9. 报告与 UI

### 9.1 安全 Tab 的"盗 U 风险"块

现状（`lib/pages/info_page.dart:916-1145`）：一块小结 + 一张 `SecurityFindingCard`；无发现时显示"未发现"。
扩展为固定 5 行（与五段链一一对应）：

| 行 | 展示 | 缺省态 |
|---|---|---|
| 能力 | 命中 marker chips + 条数 | `本次未发现钱包/密钥材料证据`（灰，不等于无风险） |
| 来源 | 剪贴板读 / 地址字面量（可复制） | `未观察到地址来源` |
| 注入 | 加密载荷 / 悬空加载边 / 根目录 dylib | `未观察到注入痕迹` |
| 载荷 | 可疑条目路径 + 原因码 | **`未覆盖（预算/加固）`** ← 用 unknown，不允许空白 |
| 基线 | 官方包匹配状态（match / mismatch / noBaseline / unavailable）+ 证书/Team 前 16 hex | `未命中官方基线`；不可用时明确 `基线不可用` |

顶部：`severity + confidence` 徽标 + `score`（若有）+ 一句"这是线索还是事实"的定性（confirmed 才可用"已证实"）。
底部"下一步动作"：3 条可执行项（导出去重后的地址清单、核对签名/密封结论、若为已安装应用则比对官方渠道包哈希）。

### 9.2 文案原则

- 事实与推断分开："文件存在/调用点存在"（事实）vs"通常意味着"（推断）；
- 正规钱包同源能力要写在正文："正规钱包也具备剪贴板/钱包 SDK"；
- "无法判断"必须给出原因（加壳/远程/预算/工具缺失）；
- 不显示百分比"可信度"（容易读成概率）；用四态 + 证据强度；
- **不出现"木马/恶意"定性**：P1 只用于事实级（官方基线不匹配/密封不匹配），其余最高 P2 且必须带"疑似/线索"措辞。

### 9.3 Markdown / JSON / i18n

- `## 盗 U 风险` 小节：结论、技术点表（ID/强度/等级/证据摘要/缺失环节）、来源/完整性、基线/情报版本、覆盖与局限、下一步。
- JSON：顶层 `security`（`cryptoTheft` / `artifacts` / `loadGraph` / `seal` / `baseline`）；schema 8；`iocMatches` deferred。
- `securityOnly` 导出必须包含盗 U 块与完整性结论（不能因为"不是 finding"被截掉）。
- 同时补齐 2026-11-04 审计的 P1-5：Markdown 的 ABI/密度/语言/屏幕/分包/OBB/ICP/URL Scheme/后台模式/图标字段。
- **同源硬约束**：golden 断言"JSON 新增顶层键集合 ⊆ Markdown 小节集合"；不允许 Markdown 省略 JSON 有的块（历史缺陷：`platformFacts` 曾只在界面有）。
- i18n：新增 `security.crypto_risk.*`（状态/技术点/缺失环节/基线/建议），6 语言；新增 code 必须有"未注册 code 守卫测试"。

---

## 10. 性能与资源预算（未实测，需基准校准）

| 项 | 目标 | 依据/风险 |
|---|---|---|
| 343 MB APK 总时长增量 | ≤ +15%（≈ +0.8 s，按现有 ~5.5 s 基线估算，**未实测**） | 清单复用中央目录一次遍历；不解压 |
| 41 MB IPA 增量 | ≤ +10%（≈ +0.3 s，**未实测**） | 同上 |
| 额外内存 | ≤ 96 MiB 峰值 | 复用已读字节，不整包载入 |
| 条目读取上限 | 清单 20 000 条 / 探测 256 条 / 每探测头 4 KiB / 合计 1 MiB | 超限写 `skippedCodes` |
| 摘要校验 | ≤64 条目、≤32 MiB；Dart SHA-256 按 150–400 MB/s 估 ≈0.1–0.25 s（**未实测**） | 注入实现（ADR-03） |
| 遍历次数 | 每种字节流只解一次：DEX 2 次（字符串+方法）现状不变；清单 0 次解压；探测只读头部 | 复用 `parse_task.dart:263` 已有选库结果 |
| 失败降级 | 任何组件异常 → 该块 `null` + `CoverageEntry.notCovered` + `AnalysisNote`；**绝不**让 audit 抛异常 | 与既有 `manifestParsed:false` 路径同构（`parse_task.dart:230`） |

**必须避免**：重复解压/重复遍历；在主 isolate 做大文件哈希；为了"全量"取消预算。超预算维度必须 `partial` 并说明。

---

## 11. 测试、语料与验收

### 11.1 测试分层

| 层 | 内容 | 数量目标 |
|---|---|---|
| 单元 | 每个扫描器纯函数：制品分类、加载链、熵、CodeResources/APK 摘要、官方基线匹配、判级表（IoC 匹配器延期） | 每组件 8–20 条 |
| 夹具 | 合成 APK/IPA：正常钱包、注入 dylib、伪装 so、assets DEX、Unicode 中文话术、v1-only、证书不匹配、篡改 1 字节、CodeResources 少/多/哈希不符、`@rpath` 指空 | 每技术点至少 1 正 1 负 |
| 集成 | 从 `ApkReader`/`IpaContainer` 到 `AnalysisReport` 的端到端（不执行样本） | 每平台 10+ |
| 报告 | Markdown/JSON golden、字段同源、schema v8、`securityOnly` | 10+ |
| 覆盖诚实性 | 预算截断/工具缺失/加壳 → partial/unknown，不误报"未发现" | 每维度 1–2 |
| 回归 | 现有 2,193 条全绿 + analyze/format | 全量 |

### 11.2 语料（当前不可用）与替代验证

**D1 已确认：没有已知盗 U / 正规钱包语料。** 因此：
- 不把 `malicious/wallet/benign` 语料评估作为当前验收或发布门槛；
- `tool/crypto_corpus_eval_test.dart` 保留，作为将来有语料时的评估入口（目录约定、宽/窄口径、解析失败不进分母的逻辑不变）；
- 当前用三类替代验证：
  1. **合成夹具**（主力）：按技术点造正/负样本——证书不匹配、`@rpath` 指空、CodeResources 少一条/多一条/哈希不符、v1 摘要篡改、伪装 `.so`、assets DEX、Unicode 中文话术、悬空加载边、注入根目录 dylib；
  2. **官方基线验证集**：D2 的官方包（只用于验证 `baselineMatch`，不作为恶意/良性语料）；
  3. **人工复核**：导出报告给分析人员逐条核对，记录误报/漏报（不进入自动化指标）。

> 若将来能提供语料，按下表执行（**当前不适用**）：

| 目录 | 分层 | 最小样本量 | 标注字段 |
|---|---|---|---|
| `malicious/` | 按家族：地址替换、助记词钓鱼、无障碍+短信、动态加载 payload、注入 dylib（iOS）、假交易所 | Android ≥100 / iOS ≥60（每家族 ≥15） | `sha256, platform, family, techniques[], expected(P2/P3/none), labeler×2, source, license` |
| `wallet/` | 主流钱包/交易所/DeFi | ≥40 | 同上 + `is_official` |
| `benign/` | 含**困难负样本**：带加密库、剪贴板、WebView、OCR、热修复各 ≥20 | ≥200 | 同上 |

- 标注：双人独立标注，分歧仲裁；`techniques` 用固定枚举。
- 解析失败：不进分母；无负样本时精确度印 `n/a`；<30 样本不报百分比。

### 11.3 禁止宣称（D1 后尤其重要）

- **当前没有语料 → 不得对外宣称任何"检出率/准确率/能检测 X%"**；README、CHANGELOG、UI、销售材料一致。
- 现有 50–65%（Android）/ 40–55%（iOS）是**估计**，不得作为指标或营销数字。
- 即使将来有语料：<100 malicious + <200 benign 不宣称；<30 样本不报百分比；样本 <10 的技术点只报 x/y。
- 不得宣称：能检测未知家族（IoC 已延期）、能证明恶意、覆盖率 100%、任何运行时行为结论。
- 官方基线可以宣称"与官方基线一致/不一致"（需注明基线版本与来源），但不能延伸为"该包安全/恶意"。

### 11.4 最小验收用例（MVP）

1. 官方钱包正版包（D2 基线可获取）→ `baselineMatch`，能力链不升 P1。
2. 同一包改证书重签 → `T-OFFICIAL-IMPERSONATION` P1。
2b. 基线不可用（无官方包/无指纹）→ `baselineUnavailable`，**不得**下 P1。
3. 官方钱包 + 注入根目录 dylib（iOS）→ `T-INJECTED-DYLIB` P2 + 签名/布局证据。
4. 普通 App + 剪贴板读写 + 地址字面量（无钱包）→ P3/不报，避免误报。
5. 钱包 + 剪贴板写 + 地址 + 网络上传 → `T-CLIPBOARD-SWAP` P2 suspected，缺失环节明确。
6. 加壳包 → `unknown` + "无法判断（加壳）"，不报"未发现"。
7. 中文假客服话术 + 输入框 + 网络 → `T-SEED-EXFIL` P2 suspected（依赖 Unicode 扫描）。
8. 预算截断（大包）→ 覆盖 partial，报告说明未扫字节。
9. 篡改 1 字节的夹具必出 `mismatch`；未注入 digest 实现时必为 `notChecked`（不得为 `verified`）。
10. 基线库完整性校验失败 → `notCovered` + "基线未启用"，不得静默变成"未匹配"。
11. 全部规则在无基线/无语料下仍可跑：只输出能力链/结构证据，P1 仅限密封 mismatch。

---

## 12. 路线图

| 阶段 | 目标 | 交付物 | 人日 | 依赖 | 主要风险 |
|---|---|---|---:|---|---|
| A 契约 | 冻结模型与 schema v8；修 R7/R8/R9 | 模型文件 + golden + 契约评审 | 3 | —— | 字段后期返工 |
| B 事实层 | 清单/探测/加载链 | C1–C9、C18、单测 | 6 | A | 条目表接口改动波及 worker |
| C 判定层（**MVP 止于此**） | 证据链 + 规则 + UI/报告 | C13–C15、C22 | 6 | B | 误报调参耗时 |
| D 密封校验 | APK v1/v2 摘要、IPA CodeResources | C10–C12、digest 注入 | 5 | A、B | 哈希实现与性能 |
| E 基线库 | 官方基线（证书/Team）维护与校验；**家族 IoC 延期** | C16/C17/C21、基线校验报告 | 4 | C | 官方包/指纹获取与基线维护 |

**Phase A 契约（已冻结）**：`docs/plans/2026-11-04-crypto-theft-phase-a-contracts.md`、`docs/contracts/*.schema.json`。

**Phase B 实现记录**：`docs/plans/2026-11-04-crypto-theft-phase-b-implementation.md`。

**Phase C-1 实现记录**：`docs/plans/2026-11-04-crypto-theft-phase-c1-engine.md`。

**Phase C-2 实现记录**：`docs/plans/2026-11-04-crypto-theft-phase-c2-ui-report.md`。

**Phase C-3 实现记录**：`docs/plans/2026-11-04-crypto-theft-phase-c3-wiring.md`。

> Phase C 的**呈现层已完成**（五段链卡片 + Markdown/JSON schema v8 + i18n），生产路径已接入 Phase B 事实；性能基线见 `docs/plans/2026-11-04-crypto-theft-performance-baseline.md`；加载链优化见 `docs/plans/2026-11-04-crypto-theft-load-graph-optimization.md`；iOS 字符串扫描优化见 `docs/plans/2026-11-04-crypto-theft-ios-audit-optimization.md`；两阶段返回见 `docs/plans/2026-11-04-crypto-theft-ios-two-phase.md`。Phase D iOS CodeResources 切片见 `docs/plans/2026-11-04-crypto-theft-phase-d-ios-seal.md`，Android v1 MANIFEST 切片见 `docs/plans/2026-11-04-crypto-theft-phase-d-android-v1-seal.md`，Android v2 内容摘要见 `docs/plans/2026-11-04-crypto-theft-phase-d-android-v2-seal.md`；Phase E Android 首个基线条目与 iOS 匹配接线见 `docs/plans/2026-11-04-crypto-theft-phase-e-official-baseline.md`（用户提供的 APK，标为 caller-provided，非独立官方来源）；C-4 规则映射见 `docs/plans/2026-11-04-crypto-theft-c4-rule-mapping.md`。

**MVP = A+B+C = 15 人日**（不含密封校验与官方基线，即 D/E）。全量 ≈24 人日（含缓冲）。  
**建议另加**：iOS 后台改造 + 安全/法务评审 + 語料采集，按 18–28 人日排期。

---

## 13. ADR（关键取舍）

**ADR-01：不做全量反汇编/数据流分析，用"调用点 + 同方法体 + 常量邻接"**
- 背景：要把"读剪贴板 → 替换 → 发送"证到 `confirmed` 只能靠指令级数据流。
- 选项：① smali 级遍历；② 停在 `method_ids` + 调用点；③ 引第三方反汇编器。
- 决策：②。理由：③ 违背"不引入重依赖"；① 估算 +3~5 倍解析时间与 2 人月，加固壳下依然失效。
- 后果：`confirmed` 只来自密封/官方基线（IoC 延期），其余最高 `suspected`。
- 反向条件：出现"必须逐跳证明"的合规要求，或 DEX 解析已 <1 s 有富余。

**ADR-02：不做运行时**
- 决策：`includesRuntimeEvidence` 保持 `false`；沙箱/动态插桩超出"静态分析工具"定位。
- 后果：解密后的 payload 永远看不见 → 用"载荷探测 + 悬空加载边"近似。
- 反向条件：产品转向"可执行检测"且具备隔离执行环境。

**ADR-03：哈希能力走注入端口，不新增包依赖**
- 背景：`apk_parser`/`ipa_parser` 依赖清单里没有 `crypto`；`analysis_model` 零依赖。
- 选项：① 给两个 parser 包加 `crypto`；② 定义 `typedef ContentDigestFn = String? Function(String alg, Uint8List bytes)`，由应用层注入；③ 包内手写 SHA-256。
- 决策：②。依赖方向不变、`analysis_model` 保持零依赖、实现单点（应用层已用 `package:crypto`，`lib/utils/file_hash.dart:6`）。
- 后果：未注入时 `state=notChecked`、覆盖标 `notCovered`（诚实降级）；③ 被否（需自测向量）。
- 反向条件：出现非 App 调用方需要独立校验 → 改 ①。

**ADR-04：离线内置官方基线库（IoC 延期，不做在线情报）**
- 选项：① 在线 API；② 内置 JSON + 手动导入；③ 不做。
- 决策：②——产品纪律"不联网分析"，库可审计、可回滚、无隐私外泄。
- 后果：情报滞后；需要团队持续维护。反向条件：需要日更情报 → 加"用户显式导入本地文件"通道（仍不联网）。

**ADR-05：新结果放一级字段，不塞进 `evidence`**
- 理由：消费者要能直接回答"包里有几个 .so""哪条加载边悬空"，不该解析证据文本（与 `network` 一级字段同一动机）。
- 后果：`SecurityAnalysisResult` 变宽、拷贝点增多 → 用测试兜住。

**ADR-06：不扩展 severity/confidence 枚举**
- 决策：阶段信息只放 `CryptoTheftAssessment.chain`；枚举扩张会破坏所有 `switch` 与本地化。
- 反向条件：UI 需要按阶段筛选时用 `TechniqueEvidence.stage` 过滤。

**ADR-07：官方基线是"证明冒充"的唯一静态路径**
- 决策：能力链最高 P2；只有官方基线不匹配/密封不匹配才到 P1（家族命中因 D1 延期）。
- 后果：未知应用最多"高度疑似"，不输出"木马"。
- 反向条件：用户提供官方包做差分（Phase 3）。

---

## 14. 合规 / 伦理 / 隐私边界

| 边界 | 要求 |
|---|---|
| 只做防御性静态分析 | 不提供脱壳、反混淆、绕过签名、免杀、注入教程；不输出可直接复用的攻击步骤 |
| 样本与 IoC 来源 | 每条样本记录 `sha256 / 来源 / 许可 / 获取日期`；无许可样本不入库；不下载用户包 |
| 不上传用户包 | 分析全本地；崩溃上报与遥测不得包含包内容、路径、地址 |
| 威胁情报更新 | 签名 + 版本号 + 灰度 + 一键回滚；离线可用；更新失败**不得**降级为"干净" |
| 误报的声誉影响 | P1/P2 必须附可复核证据；提供反馈/申诉入口；不自动向第三方上报"恶意"结论 |
| 数据最小化 | 证据只出现路径 + 哈希前缀（前 16 hex）；完整地址由用户显式展开 |
| 免责 | 结论为技术线索，不构成法律或投资建议；P2 以上建议人工复核或送动态分析 |

---

## 15. 风险登记表

| # | 风险 | 影响 | 触发信号 | 对策 | 负责人 |
|---|---|---|---|---|---|
| R1 | 正规钱包被标 P2，被读成"盗 U" | 声誉/法律 | wallet 语料误报 >30%；文案出现"木马" | 措辞门禁 + 置信度分层 + 申诉入口 | security / pm |
| R2 | 动态加载/加壳导致假阴性 | 虚假安全感 | `packed` 或预算截断命中 | 强制 UNKNOWN + 覆盖说明，禁止"未发现" | security / architect |
| R3 | 无基线却断言"被植入" | 结论不可证 | 无基线样本出现"恶意"措辞 | 文案评审 + L4 证据门禁 | docs / security |
| R4 | 官方基线库过期/错误 | 误判或漏判 | 更新无签名/无版本/无回滚 | 签名校验 + 灰度 + 回滚 + 离线兜底；IoC 延期 | devops / security |
| R5 | 样本许可与隐私不清 | 法律风险 | 样本缺 license 字段 | 语料入库强制字段 | pm / security |
| R6 | 畸形包导致挂起/崩溃 | 可用性 | 超大 nested/畸形 ELF | 归档预算 + 深度上限 + 环检测 | architect / qa |
| R7 | 证据来源错标（native 地址标成 DEX string） | 复核误导 | 地址证据 location 恒为 `DEX string` | 修正 source 枚举（`android_security_rules.dart:1054-1060`） | 实现 |
| R8 | CodeResources 只解析结构、不解哈希 | 高估密封校验能力 | 设计假设"能验密封" | 本方案 C12 补哈希；`signatureVerified` 恒 false | architect |
| R9 | iOS findings 缺 blindSpots | 截断被读成干净 | 预算截断时无提示 | 补齐与 Android 同构的盲区字段 | 实现 |
| R10 | 家族匹配牵连正规 App 的第三方 SDK（**IoC 延期，暂不适用**） | 误伤 | 同一 SDK 在多个良性包命中 | 区分"引入恶意 SDK"与"应用恶意" | security |
| R11 | 清单/加载链拖慢大包 | 体验 | 343MB 样本耗时 > +20% | 只读中央目录、条目上限、partial 记明 | architect |
| R12 | 新字段漏拷（结果被静默丢失） | 结论缺失 | `withLimitation` 后新字段为 null | 专项单测 + review checklist | qa |
| R13 | iOS 主线程改造引入生命周期 bug | 崩溃/黑屏 | 页面切换/取消/异步 setState | `CancellableTask` + 生命周期测试（2.8.6 教训） | 实现 / qa |
| R14 | **无语料 → 检测能力未被验证** | 无法证明效果；可能高估/低估 | 只有合成夹具，没有真实样本 | 不承诺指标；只用夹具/基线/人工验收；对外标注"未验证"；后续小范围试用收集反馈（不强制上传） | security / pm |
| R15 | 官方基线数据获取/维护失败 | L4 失效；冒充判定不可用 | 基线库为空/过期/无法校验 | 明确 `baselineUnavailable` 并降级；建立官方包/公开指纹来源清单与版本流程 | pm / security |

---

## 16. 已确认决策与剩余待定

### 16.1 已确认（2026-11-04）

| # | 决策 | 对实现的影响 |
|---|---|---|
| **D1** | 不提供已知盗 U / 正规钱包语料 | 不设检出率门槛、不宣称指标；家族 IoC 延期；验收=夹具+官方基线+覆盖诚实性+回归 |
| **D2** | 维护 Top 20–30 钱包/交易所官方证书/Team 基线 | 官方基线是唯一 L4；需要官方包/公开指纹来源；多证书集合匹配；基线不可用时诚实降级 |
| **D3** | 接受"只给风险证据、不给恶意判决" | 冻结 PASS/HIT/UNKNOWN；P1 只用于事实级（基线/密封不匹配）；禁止"木马/恶意"定性 |

### 16.2 仍需确认（不阻塞设计，阻塞实现）

1. **基线数据来源**：官方包或证书/Team 指纹由谁获取、如何验证、更新频率？若无法获取，基线只能"预置未验证"，L4 不生效。
2. **首批基线清单**：Top 20–30 具体是哪些钱包/交易所（含 Android 包名 + iOS Bundle ID/Team）。
3. **平台优先**：Android 优先 / iOS 优先 / 双端并行（建议双端 MVP；iOS 注入证据更强）。
4. **MVP 范围**：是否接受"MVP 不含密封校验与基线"（只到 L3 能力链），把 D/E 放二期？
5. **分包**：XAPK/APKS 目前只审 base APK；是否要把所有分包纳入？
6. **单一风险分**：是否要 0–100 分？建议只作排序/摘要，不作结论主依据。

---

## 17. 附录

### 17.1 现有代码入口（实施时先读）

| 主题 | 文件 |
|---|---|
| Android 审计编排 | `packages/apk_parser/lib/src/security/android_security_audit.dart` |
| Android 规则表 | `packages/apk_parser/lib/src/security/android_security_rules.dart` |
| DEX 结构/方法体 | `packages/apk_parser/lib/src/dex/dex_structure.dart`、`dex_method_bodies.dart`、`dex_method_scanner.dart` |
| 原生库/ELF | `packages/apk_parser/lib/src/native/elf.dart`、`elf_hardening.dart`、`security/native_symbol_scanner.dart`、`native_crypto_scan.dart` |
| 加固/壳 | `packages/apk_parser/lib/src/hardening.dart`、`security/packer_catalog.dart` |
| iOS 审计 | `packages/ipa_parser/lib/src/security/ios_privacy_audit.dart`、`ios_crypto_audit.dart`、`ios_repackaging_audit.dart`、`ios_reference_tables.dart` |
| Mach-O | `packages/ipa_parser/lib/src/macho.dart`、`macho_crypt_id.dart` |
| iOS 签名/密封 | `packages/ipa_parser/lib/src/ios_signature.dart` |
| iOS 布局 | `packages/ipa_parser/lib/src/ipa_layout.dart`、`lib/ipaparser/ipa_analysis.dart` |
| 模型 | `packages/analysis_model/lib/src/security_finding.dart`、`analysis_coverage.dart`、`crypto_address.dart` |
| 报告 | `lib/utils/analysis_report.dart`、`lib/utils/report_exporter.dart` |
| UI | `lib/pages/info_page.dart:916-1145`、`lib/widgets/security_finding_card.dart` |
| 语料评估 | `tool/crypto_corpus_eval_test.dart` |

### 17.2 术语

- **L0–L5**：本文的检测能力等级（§0.2）。
- **能力链**：多个独立证据指向同一盗 U 技术点，但未证明运行时行为。
- **官方基线**：已知官方应用的包名/Bundle ID + 证书/Team 指纹；用于判定冒充/重签。
- **家族/IoC**：已知恶意样本的哈希/类名/库名/域名/地址/证书等可匹配指标。
- **注入**：在原始包基础上增加/替换代码或动态库（重打包、dylib 注入）。
- **密封**：iOS `CodeResources` 对包内文件的哈希清单；Android 对应 APK 签名方案的摘要保护。
- **PASS/HIT/UNKNOWN**：已检查未发现 / 有证据 / 无法判断。

### 17.3 参考

- AOSP：APK Signature Scheme v2/v3（签名块结构、摘要覆盖范围、分块摘要规则）。
- Apple：Code Signing Guide、`CodeResources` 格式、`codesign` 输出。
- 项目内：`docs/audit/2026-11-04-module-completeness-audit.md`（现状评估）、`docs/notes/security-confidence-review.md`（规则可信度）、`docs/notes/install-support-eval.md`（iOS 签名/安装边界）。

---

**一句话总结**：可以做一个**有证据链的静态"盗 U 风险"检测引擎**：MVP 达到 L3（能力 + 载荷 + 来源/加载链 + 缺口）；在 D2 官方基线库到位后达到 L4（确认冒充/重签）；家族情报因 D1 无语料延期。**不要承诺"判定木马"**，那是 L5 动态分析的事。设计已按 D1–D3 收窄，确认 §16.2 的基线数据来源后即可按 Phase A 开工。
