# AppInfoTool 各功能板块完成度审计报告

> **审计对象**：AppInfoTool **2.8.7**（commit `b7adbc5`，tag `v2.8.7`，2026-10-22 发布）
> **审计日期**：2026-11-04
> **审计性质**：只读审计。除本报告与一次性工作目录外，未修改任何生产代码、测试或配置。
> **审计范围**：README 声明的全部功能板块（包解析 / 安全检测 / 安装与系统集成 / 界面与国际化）+ 工程质量与发布链路。
> **方法**：5 路并行静态审计（Android、iOS、界面、安装、工程质量），逐能力点回代码取证；Lead 独立运行全量质量门禁并回读抽查关键结论。

---

## 0. 结论摘要

### 0.1 三个分数

| 视角 | 分数 | 口径 |
|---|---:|---|
| **功能兑现率**（声明范围） | **94 / 100** | README 声明的 178 个能力点，按 ✅1 / 🟡0.75 / 🟠0.5 / ⛔0 加权 |
| **工程质量与交付验证** | **78 / 100** | 测试覆盖 24/30、CI 门禁 23/25、构建发布 17/25、文档一致 14/20 |
| **综合交付成熟度**（参考） | **90 / 100** | 功能 94 × 0.8 + 工程 78 × 0.2 |

> 这三个数不能互相替代：**功能基本做完了，但"最后一段验证"没跟上**。只看功能，这是一个完成度很高的项目；看"发布出去能不能稳定兑现"，还有明显欠账。

### 0.2 一句话结论

**解析与安全引擎是项目最强的一块（94–99 分，且有真实夹具与独立参照工具交叉验证）；安装/系统集成与界面 88–95 分，主体可用但有若干"用户会撞上"的接缝；真正的短板在工程质量与交付验证（78 分）——真实样本 E2E 在 CI 上结构性跳过且不阻塞发布，三平台产物没有运行时冒烟，文档与实现的同步靠人工。**

### 0.3 六个必须先知道的事实

1. **门禁全绿且是本次实跑**：`flutter test` 1,746 通过 / 15 跳过 / 0 失败；5 个包 447 条全绿（93/144/25/40/145）；`flutter analyze --fatal-infos --fatal-warnings` 零问题；`dart format` 345 文件 0 变更；`flutter build bundle` 通过。合计 **2,193 条测试**。
2. **上一轮审计的高价值缺陷确实修了**：v1-only 与未签名不再混同、资源表覆盖改真实条目数、iOS `NetworkFacts` 已构造、`ios.executables` 分母不再虚报、2.8.7 的照片选择器误判已修且 `IOS-RULE-A` 联动有测试、IPA 误装入口已从分析页删除。逐条见 §7。
3. **P1 共 6 条**：缩略图"停用"在安装版上无效且显示虚假状态；安装页不检测 adb 缺失；XAPK/APKM/APKS 完整元数据硬依赖外部 aapt2 且静默降级；语言选择器只给 3/6；Markdown 报告缺 11 组界面可见字段；发布说明写 macOS 11+ 而实际最低 12.0。
4. **README 有 7 处直接矛盾**（测试数、批量命名、缩略图默认关闭、aapt2"备用"、日志"逐行"、可选关联、macOS 版本），另有若干口径偏差。见 §6。
5. **README「已知局限」8 条逐条属实且披露诚实**：Assets.car 约 50% 出图与 deepmap2、键索引缺失、bvx1/bvxn、静态分析边界、扫描预算、签名验证依赖外部工具、ja/ko 部分覆盖、iOS 安装未实现。没有发现"把没查到说成没问题"的新增系统性隐瞒。
6. **工程质量 78 分的根因不是代码烂，而是验证链不闭环**：真实样本/签名链路在 CI 永不执行且 `external-samples` 不在发布依赖里；无覆盖率门禁；Windows/macOS/Linux 产物没有运行冒烟。CI 绿只能读成"编译与单测绿"。

### 0.4 如果只做五件事

1. 修缩略图"停用"的 HKLM/HKCU 不一致（P1-1）——这是"系统里还有改动却显示已关闭"。
2. 安装页把 `adbMissing` 显性化并给下载入口（P1-2）。
3. XAPK 元数据改用内置解析器兜底，或在 UI/README 明说依赖 aapt2（P1-3）。
4. 语言选择器补齐 6 项 + Markdown 报告补齐 11 组字段（P1-4 / P1-5）。
5. 改发布说明的 macOS 版本 + README 测试数（P1-6 / P2-2）——10 分钟的事。

---

## 1. 审计口径

### 1.1 基准

- **规范**：`README.md`（中文）与 `README_en.md` 的功能声明。
- **交付记录**：`CHANGELOG.md`——用于定位"声称已修"的条目，**不当作证据**。
- **证据**：生产代码、测试源码与夹具、本机实跑门禁。
- **历史线索**：`docs/audit/` 下 2026-10-13 至 10-19 的 10 份审计，只当假设，逐条回代码核实。

### 1.2 判定与计分

| 判定 | 含义 | 权重 |
|---|---|---:|
| ✅ 完成 | 生产实现 + 生产路径可达 + 有测试/门禁或可静态证明 | 1.00 |
| 🟡 基本完成 | 实现完整，但测试弱 / 边界未覆盖 / 呈现不完整 | 0.75 |
| 🟠 部分完成 | 缺子能力，或对典型场景不可靠 | 0.50 |
| ⛔ 未实现 | 声明存在但代码里没有 | 0 |
| ❓ 无法验证 | 需真机/他平台/外部样本 | 不计入分母 |

`功能兑现率 = Σ得分 / 计分能力点数`。**README 自己写进「已知局限」的边界不按"隐瞒"处理**，但会作为该能力点的边界记录（若限制让能力只剩部分场景，判 🟡/🟠）；同时在 §4 单列"已知限制"。

### 1.3 证据等级

- **A（实跑）**：本次 `flutter test` / `analyze` / `format` / `build bundle` / 包级 `dart test`。
- **B（代码+测试）**：实现定位到 `file:line`，且有测试断言行为。
- **C（代码静态）**：实现存在、生产路径可达，但只有静态证据（Windows C++、Inno 脚本）。
- **D（文档/未验证）**：只有文档叙述，或本次无法验证。

### 1.4 本次实测边界

- 本机 **macOS arm64**，Flutter 3.47.7 stable；**未在 Windows/Linux 真机运行**，Windows 侧 C++/Inno 全部为静态审查。
- **未配置 `APPINFOTOOL_SAMPLES`**：15 条真实样本/语料基线用例跳过（非失败）。
- 未查询远端 CI 历史与 Release 资产；未联网。
- 未运行内存/性能探针（`tool/` 下脚本不在 CI）。
- 详细限制见 §9.3。

### 1.5 与既有审计的关系

2026-10-18/19 的三份审计回答的是"能力够不够、结论诚不诚实"，本报告回答的是"**每个功能板块做到哪一步、声明兑现多少**"，口径与权重不同，**分数不可直接比较**。本轮对旧审计的 10 项修复做了逐条复核（§7），未重新评估已修复的问题。

---

## 2. 基线

### 2.1 版本与规模（实测）

| 项 | 数值 |
|---|---|
| 版本 / 提交 / tag | 2.8.7 / `b7adbc5` / `v2.8.7` |
| 发布节奏 | 41 个 tag（CHANGELOG 37 个版本段） |
| Dart 代码 | 107,567 行（生产 ≈ 64,455；测试 ≈ 43,112，占 40%） |
| 文件 | `lib/` 102 个（手写 87）；`packages/` 85 个源文件；根测试 136 个文件 |
| 测试 | 根 1,746 通过 + 15 跳过；包内 447；合计 **2,193** |
| 夹具 | 102 个 / 984 KB（全部真工具或真实构件） |
| 语言包 | 6 个；en/zh-CN/zh-TW/zh-HK 各 1,151 叶键，ja/ko 各 1,049 |
| 平台 | Windows / macOS / Linux 桌面；无 Android/iOS 宿主目标 |

### 2.2 架构

- 解析器拆成 4 个纯 Dart 包：`apk_parser`（15,118 行）、`ipa_parser`（12,552）、`analysis_model`（2,191）、`archive_safety`（904），加无 Flutter 依赖的 `app_icon_extractor`（991）。
- 依赖方向干净：两个解析器互不依赖，只共享 `analysis_model` 与 `archive_safety`；`app_icon_extractor` 可 `dart compile exe` 供 Windows 缩略图进程调用。
- UI 不承担二进制解析：`lib/apkparser` / `lib/ipaparser` 是应用侧编排层，解析全部落在包内。

### 2.3 质量门禁实测

| 检查 | 命令 | 结果 |
|---|---|---|
| 格式 | `dart format --output=none --set-exit-if-changed <345 files>` | ✅ 0 changed |
| 静态分析（根） | `flutter analyze --fatal-infos --fatal-warnings` | ✅ No issues found（15.8s） |
| 根测试 | `flutter test` | ✅ **1,746 pass / 15 skip / 0 fail**（58s） |
| 整包编译 | `flutter build bundle` | ✅ 从 `main.dart` 可达代码全部编译 |
| 包级测试 | 5 个包 `dart test` | ✅ 93 / 144 / 25 / 40 / 145 = **447** |
| 包级分析 | 5 个包 `dart analyze --fatal-infos --fatal-warnings` | ✅ 全部 No issues |

跳过项：13 条真实样本（未设 `APPINFOTOOL_SAMPLES`）、1 条安全语料基线、1 条仅非 macOS 执行的 codesign 互补用例。跳过均打印原因，未伪装成通过。

### 2.4 测试分布（近似，按文件名归类）

| 主题 | 文件 | 用例 |
|---|---:|---:|
| Android 解析/安全 | 47 | 617 |
| iOS 解析/安全 | 24 | 385 |
| 报告/差异/导出/覆盖 | 12 | 180 |
| UI/组件/交互/布局 | 14 | 158 |
| 安装/ADB/工具下载/运行时 | 10 | 94 |
| 文件/哈希/重命名/归档/样本 | 7 | 83 |
| i18n/README/验收/文档守卫 | 9 | 79 |
| 模型/工具/其他 | 13 | 126 |
| **合计** | **136** | **1,722（+循环展开 24 = 1,746）** |

### 2.5 测试覆盖的盲区

- 手写生产文件没有"完全零测试"的模块；唯一的零引用手写文件是 `lib/utils/riverpod_utils.dart`（死代码，应删）。
- 但 **22 个 UI 文件没有直接测试**（含两个导出对话框、`detail_tab_view` 的生产 TabBar 分支、`theme_manager`、`setting_provider`）。
- `test/readme_consistency_test.dart` 只校验 README 结构不变量，**不校验任何数字**——这是 README 测试数过期却无人报警的直接原因。
- 真实样本/签名/语料在 CI（ubuntu）约 20 条恒跳过；`tool/` 下 4 个测试脚本不在任何门禁。

---

## 3. 模块完成度总表

| # | 板块 | 计分点 | ✅ | 🟡 | 🟠 | ⛔ | ❓ | 完成度 | 一句话结论 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | Android 包解析 | 13 | 10 | 3 | 0 | 0 | 0 | **94** | 字段与结构齐全；容器格式元数据依赖 aapt2 |
| 2 | Android 安全检测 | 20 | 18 | 1 | 1 | 0 | 0 | **96** | 三层取证与覆盖模型扎实；权限目录仍缺 4 类 |
| 3 | iOS 包解析 + Assets.car 图标 | 21 | 19 | 1 | 1 | 0 | 2 | **96** | 纯 Dart LZFSE/键索引/调色板是亮点；出图率约 50% |
| 4 | iOS 安全检测 | 24 | 21 | 2 | 0 | 1 | 0 | **94** | 隐私/引用/签名链路强；缺分发类型分类 |
| 5 | 安装到设备（Android） | 17 | 11 | 4 | 2 | 0 | 0 | **88** | 无线/分包/选项完整；adb 缺失与 APKS 是接缝 |
| 6 | 外部工具链 | 9 | 9 | 0 | 0 | 0 | 0 | **100** | 三档发现、校验和硬控制、预算齐全 |
| 7 | Windows 资源管理器缩略图 | 11 | 10 | 0 | 1 | 0 | 1 | **96** | 架构与 CI 自检强；真机未验收 + 停用失效 |
| 8 | 文件关联 / 单实例 | 8 | 8 | 0 | 0 | 0 | 0 | **100** | UserChoice 不被抢、AppMutex 逐字一致 |
| 9 | Windows 安装包（Inno） | 8 | 7 | 0 | 1 | 0 | 0 | **94** | 4 语言/可选目录/卸载完整；"可选关联"被覆盖 |
| 10 | 界面（5 页 / 六 Tab / 对比 / 导出 / 重命名 / 主题） | 35 | 29 | 2 | 3 | 1 | 0 | **91** | 主体完整；批量命名未实现、Markdown 字段缺口 |
| 11 | 国际化 | 12 | 10 | 1 | 1 | 0 | 0 | **94** | 四语 0 缺失、ja/ko 真回退；选择器只给 3 项 |
| **合计** | **功能板块（1–11）** | **178** | **152** | **14** | **10** | **2** | **3** | **94.1** | 声明范围内基本完成 |
| 12 | 工程质量 / CI / 构建发布 / 文档 | — | — | — | — | — | — | **78** | 机制认真，但验证不闭环 |

> ❓ 三项：iOS 安装（属安装板块、README 已声明未实现）、`vector_to_svg`（Android 专用，不适用 iOS）、Windows 缩略图真机运行时。

**已知限制（README 已披露，不计为隐瞒）**：Assets.car 只解约一半（deepmap2 0x02/0x03）、无键索引只列 rendition 名、bvx1/bvxn 抛稳定错误码、静态分析看不到运行时加载、扫描预算上限、签名验证依赖外部工具、ja/ko 部分覆盖、iOS 安装未实现。

---

## 4. 分板块结论

### 4.1 Android 包解析 — 94

**判定**：13 点 → ✅10 / 🟡3。**证据等级 B**。

**做得好**：APK/XAPK/APKM/APKS 识别、manifest 四类组件与 `effectivelyExported`、arsc 多语言/密度/夜间模式、分包与 OBB、DEX/原生库结构、aapt2 备用引擎、自适应图标渲染、签名四态（v1/v2/v3/v3.1/未签名/只有 v1）、资源引用图环检测、ICP 备案号扫描。

**缺口**：
- 🟠 **容器格式的完整元数据硬依赖外部 aapt2**（`lib/apkparser/apk_info.dart:393-396` 缺失即抛、`:427-432` 静默 catch、`:435-478` 只用容器内 `manifest.json` 兜底），组件/ABI/屏幕/`debuggable`/`allowBackup` 在无 aapt2 时缺失，且字段显示为 `unknown does not report …` 而不是"解析器未运行"（P1-3）。
- 🟡 多语言应用名只有默认名有断言；屏幕档位无测试。
- 分包安全审计只覆盖 base APK（已写 limitation，README 未披露）；13 个 APK 夹具全部 0 DEX / 0 `.so`，真实归档端到端门禁缺位。

### 4.2 Android 安全检测 — 96

**判定**：20 点 → ✅18 / 🟡1 / 🟠1。**B**。

**规模实测**：规则表 21 条（含 7 条组合 A–G）+ 表外 15 种 ruleId = **36 个 distinct ruleId**；权限目录 **29** 条；CodeMarker **63** 条；SDK 前缀 **25** 个；加固壳 **10** 家；原生符号 **26** 个；覆盖维度 **12** 个 × 4 态。

**做得好的**：DEX 三层取证（字符串 → `method_ids` → 调用点偏移，1–4 跳调用链）、ELF 加固三态（`PT_GNU_STACK`/RELRO/BIND_NOW/canary）、networkSecurityConfig 真展开、组合规则等级随证据强度（P1/P2）、`UNKNOWN` 与 P3 严格分开、覆盖分母口径已修（nativeHardening 用全包唯一库数）。

**缺口**：权限目录仍缺 `READ_SMS` / `READ_CALL_LOG` / `READ_CALENDAR` / `POST_NOTIFICATIONS`（4/8，旧审计点名）；伪装 so 只作为加固线索、不产 `SecurityFinding`（`securityOnly` 导出会丢）；README 的"21 条 / 28 条"口径过时。

### 4.3 iOS 包解析与 Assets.car 图标 — 96

**判定**：21 点（20 解析 + 1 图标兜底）→ ✅19 / 🟡1 / 🟠1；另 2 项 ❓ 不计分。**B**。

**做得好**：二进制 plist、fat/thin Mach-O、嵌套 Bundle/Framework/Extension、URL Scheme、设备能力、后台模式；Assets.car BOMStore + RENDITIONS 键索引 + 调色板索引色（分块/每块独立调色板）+ **纯 Dart LZFSE**（与 `libcompression` 逐字节一致，支持块内多流串接）+ CgBI PNG 规范化。夹具 6 份真实 `.car`、6 组 libcompression LZFSE、真实 CgBI PNG。

**缺口**：
- 🟡 出图率 **50.6%**（3,244 张可尝试 → 1,642 成功），deepmap2 `0x02/0x03` 只报 `unsupported_deepmap2`；README 已披露，但用户视角仍是"一半图标取不到"。
- 🟠 分析页无系统缩略图兜底（`system_thumbnail.dart` 只服务 Windows 文件图标）。
- ❓ README 声称的"83 个真实容器 / 25,986 条目逐条核对"语料不在仓库，无法复现。

### 4.4 iOS 安全检测 — 94

**判定**：24 点 → ✅21 / 🟡2 / ⛔1。**B**。

**规模实测**：**34 个 distinct iOS ruleId**（隐私引擎 30 + crypto/jailbreak/native-symbols/repackaging 各 1）；隐私 marker 20 个；权限请求选择子 9 组；覆盖维度 10 个；越狱/漏洞利用标记 31 条。

**做得好的**：用途说明双向对照、`PrivacyInfo.xcprivacy` 必需理由 API、`__objc_methname` 选择子、`__objc_classrefs/selrefs`、LC_SYMTAB、签名/描述文件/授权不匹配/注入 dylib、越狱组件（P1/P2）、盗 U 能力组合、覆盖口径修复。

**缺口**：
- ⛔ **没有"企业签 / Ad-Hoc / App Store"分发类型分类**：描述文件只取 Team ID/有效期/application-identifier，`ProvisionsAllDevices` / `ProvisionedDevices` 未建模（`packages/ipa_parser/lib/src/ios_signature.dart:49-129`）。这是"这个包从哪来、能不能装"最常问的问题（P2-4）。
- 🟡 无 iOS 商业加固壳名录（README 的"10 家"是 Android `.so` 名）；报告 Markdown iOS 小节缺 URL Scheme/后台模式/图标统计（JSON 有）。
- 🟡 加固维度只有 cryptid/注入/越狱三类事实；健康数据仅靠 entitlements。

### 4.5 安装到设备（Android）— 88

**判定**：17 点 → ✅11 / 🟡4 / 🟠2。**B**（adb 交互无真机）。

**做得好**：USB 设备枚举、无线 `adb pair` / `connect` / `disconnect`（配对不补默认端口、连接省略 5555、失败 TCP 探测后重启 adb server 重试一次）、设备详情（品牌+型号+Android 版本）、记住无线设备、分包勾选、`-r/-d/-t` 与"安装前先卸载"、多设备顺序安装、取消、安装日志、IPA 误装入口已删除并二次校验。

**缺口**：
- 🟠 **adb 缺失零处理**：`AdbService.adbMissing` 被折成空列表（`lib/utils/adb_service.dart:336-343`），安装页只显示"没有找到设备"，点安装抛原始 `ProcessException`；下载入口只在设置页（P1-2）。
- 🟠 APKS 分包不可靠：无 `toc.pb` 解析，缺 `manifest.json` 时回退"列出全部 `.apk`"，会把 `universal.apk` / `standalones/*` 一起塞给 `install-multiple`；夹具只有 XAPK。
- 🟡 USB 热插拔需手点刷新；XAPK 日志不显示原始 adb 输出；取消只杀本地 adb 客户端，server 侧可能继续；`INSTALL_FAILED_*` 无映射。

### 4.6 外部工具链 — 100

**判定**：9/9 ✅。**B**。

三档发现（内置 → 系统环境 → 自定义）、Google 官方 + 用户源 + GitHub 镜像兜底、`https/file` 协议白名单、sha256→sha1→md5 校验（未声明即拒绝）、1 GiB/10 万条/256 MiB 解包预算、JRE 解压剥顶层目录、7 类下载错误分类与本地化。缺口仅在 `JRE 下载仅 Windows`（已声明）与下载 UI 无 widget 测试。

### 4.7 Windows 资源管理器缩略图 — 96（真机未验收）

**判定**：11 点 → ✅10 / 🟠1；1 项 ❓。**C（静态）**。

**做得好**：in-proc COM DLL 只起子进程（1.5s 超时即杀）、WIC 解码 + 尺寸/字节上限、自适应图标/WebP 如实回退文件图标、HKCU 注册与逐扩展名诊断、CI 像素哈希自检（`thumbnail_selftest`，退出码 11–17 硬门禁）、`app_icon_extractor` AOT 双格式。

**缺口**：
- 🟠 **安装版"停用"无效且虚假状态**：Inno 无条件写 HKLM 的 CLSID/ShellEx（`windows/installer/appinfotool.iss:196-213`），应用停用只删 HKCU（`windows/runner/thumbnail_channel.cpp:319-338`），状态也只读 HKCU（`:340-380`）→ 用户点停用后界面说"已停用"，Explorer 仍在调用（P1-1）。
- ❓ Explorer 真机调用、升级/移动/卸载后的缓存行为仍未验收（README 已如实披露）。

### 4.8 文件关联 / 单实例 / 安装包 — 98

**判定**：8 + 8 点 → 全部 ✅（安装包 7✅+1🟠）。**C（静态）**。

Windows 安装版机器级关联（5 扩展）+ 运行时 HKCU 补登记 + `HasUserChoice` 保护（不抢默认）+ `SHChangeNotify`；macOS 手动指引；单实例 `Local\AppInfoTool.SingleInstance` 与安装器 `AppMutex` 逐字一致、`WM_COPYDATA` 转发 + 2s 退化；Inno 4 语言、可选目录、卸载、DLL/helper/selftest 打包。

**缺口**：用户取消"是否关联"后，首次启动仍无条件 `registerAssociations`（`lib/main.dart:90-96`），在无 `UserChoice` 时会把 `.apk` 默认值写成我们（P2-7）；`.apkm` 可关联/解析但安装页拒收（P3）。

### 4.9 界面 — 91

**判定**：35 点 → ✅29 / 🟡2 / 🟠3 / ⛔1。**B（widget 测试为主）**。

**做得好**：概览页四状态卡/统计/最近文件/拖放唯一归属；详情六 Tab 与字段四态（extracted/absent/wrongType/failed/unsupported）；版本对比字段级 + 17 个集合级 + 三态 + "没读到 vs 没有"；分析报告 MD/JSON + 仅安全范围；图标 PNG/SVG/原始导出；导出三态；主题/主题色；重命名单文件两模式。

**缺口**：
- ⛔ **"批量命名"未实现**（README:128）：全仓 `renameFile` 调用均为单文件（P2-3）。
- 🟠 **Markdown 报告缺 11 组界面可见字段**（Android ABI/密度/语言/屏幕/archiveType/分包/OBB/ICP；iOS urlSchemes/backgroundModes/图标），JSON `platformFacts` 有、界面有、Markdown 没有（P1-5）。
- 🟡 六 Tab 非恒定（iOS 缺 URL Scheme 等时只有 5 个）；APK/IPA "语义一致"仅标签对位。
- 🟠 语言入口 3/6（见 4.10）；诊断本地化 14/57，真实 iOS 样本诊断仍英文。
- 22 个 UI 文件无直接测试；硬编码英文残留（`No data`、`Light/Dark/Auto`、`default`）。

### 4.10 国际化 — 94

**判定**：12 点 → ✅10 / 🟡1 / 🟠1。**A/B（脚本实测）**。

**实测**：6 个语言包；en/zh-CN/zh-TW/zh-HK 各 **1,151** 叶键、缺失 0；ja/ko 各 **1,049**、缺 **102（8.86%）**，两者缺失键集完全相同（report 45 / field_diagnostic 15 / analysis_diagnostic 14 / settings 11 / overview 10 / apk_info 5 / signature 1 / home 1）。占位符不匹配 0、空串 0；39 个分组 `extends *En`，ja/ko 缺失为编译期真回退；生成物与语言包逐键吻合。

**缺口**：
- 🟠 **语言选择器只有 Auto / English / 简体中文**（`lib/pages/setting_page.dart:822-845`），zh-TW/zh-HK/ja/ko 无法手选，只能被动命中系统语言；README "四种语言完整覆盖"在**可操作性**上不成立（P1-4）。
- 🟡 硬编码英文残留（设置页常驻 `Light/Dark/Auto` 最明显）。

### 4.11 工程质量 / CI / 构建发布 / 文档 — 78

**判定**：测试覆盖 24/30、CI 门禁 23/25、构建发布 17/25、文档一致 14/20。**A（门禁实跑）+ C（静态）**。

**做得好**：2,193 条测试全绿；6 个 analyze 目标零问题；CI 1,198 行，job 图完整（quality → external-samples/三平台 → create-release → 3 个 publish）；Windows 缩略图 selftest 是硬门禁（退出码 11–17 + Step Summary）；包级"无测试即失败"门禁；真实产物夹具策略；`--fatal-infos --fatal-warnings`；PR 不给写权限。

**缺口**：
- 真实样本/签名链路在 CI 结构性跳过，`external-samples` 不在 `create-release.needs`；无覆盖率门禁。
- 三平台产物无运行冒烟：Linux AppImage 从未执行；macOS 未公证、`universal` 无 `lipo` 断言；Windows 缩略图仅 DLL 自检。
- 文档 4 处与代码矛盾：发布页 macOS 11+（实际 12.0）、`macos-build-and-signing.md` 称启用沙盒（实际刻意关闭）、`install-support-eval.md` 说 APK 缺无线配对/卸载（已实现）、manual-acceptance 仍写 `inno_bundle`。
- README 测试数字过期（1,728+441 vs 1,746+447）；`readme_consistency_test` 不校验数字。
- 发布链细节风险：Linux 失败容忍 vs `create-release` 空 glob；Scoop `asset_name` 顺序与真实产物相反；macOS job `build_runner` 缺 `--delete-conflicting-outputs`（`build.yml:622`，其余 4 处都有）。
- 无覆盖率度量；`tool/` 下 4 个测试不在 CI；`riverpod_utils.dart` 死代码。

### 4.12 平台覆盖

| 平台 | 状态 | 未验证/风险 |
|---|---|---|
| Windows | 安装版 + ZIP + 缩略图 DLL + helper + selftest；Inno 4 语言 | 缩略图运行时真机未验收；停用 HKLM bug；无 ARM64 |
| macOS | universal DMG、ad-hoc 签名、`codesign --verify`、挂载复验 | 未公证；无 `lipo` 断言；用户需右键/去 quarantine（已文档化） |
| Linux | AppImage（linuxdeploy） | 从未执行；x86_64 only；desktop 文件缺 `Comment`/`StartupWMClass` |
| Android/iOS 宿主 | 无（桌面工具，不需要） | — |

---

## 5. 缺口清单

### P1（6 条，建议下个版本前修）

**P1-1 安装版「停用系统文件图标」无效，且界面显示虚假状态**
- 证据：`windows/installer/appinfotool.iss:196-213`（无条件写 HKLM CLSID + `.apk/.ipa` ShellEx）；`windows/runner/thumbnail_channel.cpp:319-338`（停用只删 HKCU）、`:340-380`（状态只读 HKCU）；`lib/config.dart:119` 默认 `true` + `lib/main.dart:104-112` 启动自动登记。
- 影响：安装版用户点停用后显示"未启用"，Explorer 仍调用本处理器——用户以为系统里没改动，实际还在。
- 修法：状态查询与停用同时处理 HKLM（需要管理员时明确提示），或安装器改为可选任务并让应用停用时写"HKCU 无效 CLSID"覆盖。
- 估算：0.5–1 天 + Windows 真机验证。

**P1-2 安装页对「adb 缺失」零处理**
- 证据：`lib/utils/adb_service.dart:149-150`（`adbMissing`）、`:336-343`（折成 `[]`）；`lib/pages/install_page.dart:240-254`、`:455-475`、`:503-506`；下载 UI 仅在 `lib/pages/setting_page.dart:1214+`。
- 影响：没装 adb/没配 PATH 的用户（桌面工具主要受众）只看到"没有找到设备"，无下一步；点安装得到原始 `ProcessException`。
- 修法：安装页检测 `adbMissing` 并给"下载 adb / 去设置"入口；把 `ProcessException` 映射成本地化文案。
- 估算：0.5 天。

**P1-3 XAPK/APKM/APKS 完整元数据硬依赖外部 aapt2，缺失时静默降级**
- 证据：`lib/apkparser/apk_info.dart:393-396`（aapt2 为空即抛）、`:427-432`（catch 只记 warning）、`:435-478`（`manifest.json` 兜底）；`lib/apkparser/analysis_builder.dart:295-311`（`unknown does not report …`）；README:221 把 aapt2 写成"备用解析引擎"。
- 影响：无 aapt2 时组件/权限/SDK 区间/ABI/屏幕缺失，界面把"没解析"显示成"来源不报告该字段"，容易被读成"包里没有"。
- 修法：容器路径对提取出的 base APK 直接跑内置 `ApkReader`（安全审计已经这么做），或至少产出显式诊断 `aapt2.not_available` + README 脚注。
- 估算：1–2 天（内置兜底）/ 0.5 天（只做诊断）。

**P1-4 语言选择器只给 3/6 项，README「四种语言完整覆盖」不可操作**
- 证据：`lib/pages/setting_page.dart:822-845`（Auto/English/简体中文）；`lib/gen/strings.g.dart:31-37`（AppLocale 6 值）；`lib/main.dart:155-161`（仅 Auto 走系统语言）。
- 影响：想用繁中（台/港）、日、韩的用户无法手选；`zh` 三变体共用 languageCode，保存值有歧义。
- 修法：下拉补齐 6 项并标注 ja/ko "部分覆盖"；持久化改用 locale 全名（含 country）。
- 估算：0.5 天 + 文案。

**P1-5 Markdown 分析报告缺 11 组界面可见字段**
- 证据：`lib/utils/analysis_report.dart` 对 `nativeCodes/densities/locales/supportsScreens/archiveType/splitApks/obbFiles/icpFiling/urlSchemes/backgroundModes/icon*` 的引用数为 **0**；JSON `platformFacts` 在 `:2301` 已输出（`package_analysis_result.dart:484+`），界面也显示。
- 影响：导出的报告是交付物，读者看不到 ABI/密度/语言/屏幕/分包/OBB/ICP、iOS URL Scheme/后台模式/图标统计；与界面/JSON 不一致。
- 修法：在 `_androidSection` / `_iosSection` 补这些小节，并加"界面字段 ⊂ Markdown"的守卫测试。
- 估算：1–2 天。

**P1-6 发布说明写 macOS 11+，实际最低 12.0**
- 证据：`docs/release-install-notes.md:27`；`macos/Runner.xcodeproj/project.pbxproj` 三处 `MACOSX_DEPLOYMENT_TARGET = 12.0`。
- 影响：macOS 11 用户按说明安装后打不开。
- 修法：文档改 12（或确认依赖后降到 11）。
- 估算：5 分钟。

### P2（12 条）

1. **真实样本 E2E 不阻塞发布、无覆盖率门禁**：`external-samples` 不在 `create-release.needs`，缺样本只 warning；CI 无 `--coverage`/codecov。影响："CI 绿"被读成"端到端已验证"。
2. **README 测试数字过期**：`README.md:245` / `README_en.md:249` 写 1,728 + 441；实测 1,746 + 447（合计 2,193）。`readme_consistency_test` 只校验结构不校验数字。
3. **「批量命名」未实现**：README:128 声明，代码只有单文件重命名（`lib/widgets/rename_file_dialog.dart`、两处调用）。要么实现多选，要么改声明。
4. **iOS 无企业签/Ad-Hoc/App Store 分发类型分类**：描述文件未建模 `ProvisionsAllDevices`/`ProvisionedDevices`；iOS 商业加固壳名录也缺。
5. **APKS 分包选择对真实包不可靠**：无 `toc.pb` 解析，缺 `manifest.json` 时列出全部 `.apk`，默认全选含 `universal.apk`/`standalones/*`；无 `.apks` 夹具。
6. **安装失败信息不可读**：`INSTALL_FAILED_*` 无映射（无线侧已做本地化）；XAPK 分支 drain 掉原始输出只报阶段/退出码；"取消"只杀本地 adb 客户端，server 侧可能继续。
7. **安装时取消「关联」被首次启动覆盖**：`lib/main.dart:90-96` 无条件 `registerAssociations`，无 `UserChoice` 时写 `.apk` 默认值；与 README:187-188"由你决定"有张力。
8. **权限目录仍缺 4 类常见高危权限**：`READ_SMS` / `READ_CALL_LOG` / `READ_CALENDAR` / `POST_NOTIFICATIONS` 落 `ANDROID-PERMISSION-UNCATEGORIZED`，无等级/用途/版本条件；目录 29 条 vs README 28。
9. **分包安全审计只覆盖 base APK（README 未披露）；伪装 so 不产 `SecurityFinding`**，`securityOnly` 导出会丢这条能力。
10. **13 个 APK 夹具全部 0 DEX / 0 `.so`**：真实 ZIP + Signing Block + 真实 DEX/.so 的组合无门禁；现由 `ZipEncoder` 合成 e2e 补偿（丢 Signing Block）。
11. **诊断本地化只迁移 14/57 个 code**：真实 iOS 样本的 `ios.macho.*` / `ios.info_plist.*` 诊断仍英文；四语言其余部分完整。
12. **文档与代码 4 处直接矛盾 + 发布链细节风险**：`macos-build-and-signing.md` 称启用沙盒（实际刻意关闭）；`install-support-eval.md` 说 APK 缺无线配对/卸载（已实现）；manual-acceptance 仍写 `inno_bundle`；Scoop `asset_name` 顺序与真实产物相反；macOS `universal` 无 `lipo` 断言/未公证；Linux AppImage 从未执行；`build.yml:622` 的 `build_runner` 缺 `--delete-conflicting-outputs`；Linux 失败容忍与 `create-release` 空 glob 存在冲突风险。

### P3（12 条，择要）

- USB 热插拔需手点刷新；`KnownDeviceStore` 也记 USB 设备占 8 条上限。
- XAPK `manifest.json` 用 `String.fromCharCodes` 解码，非 ASCII 包名/分包名会乱码。
- `.apkm` 可关联、可解析，但安装页拒收（入口不对称）。
- 缩略图 CMake 注释自相矛盾（selftest 是否进安装包）。
- `lib/utils/riverpod_utils.dart` 全仓零引用（死代码）；`vector_to_svg.dart` 零测试；`ZipBudgetTracker` 仍仅测试引用（跨层累计预算未接线）。
- `tool/` 下 4 个测试（perf/corpus/audit literals）不在任何 CI 门禁。
- CHANGELOG 缺 5 个历史 patch tag（2.3.2/3/5/6/7），2.3.0 段无 tag；41 tag vs 37 段。
- 旧审计文档部分缺统一"已过时"横幅；`V2.4.0_PROGRESS.md` 等历史快照易被误读为现状。
- `release-install-notes.md` curl 示例硬编码 `V=1.1.0`。
- 硬编码英文残留：`No data`、`Light/Dark/Auto`、`default`。
- 22 个 UI 文件无直接测试（两个导出对话框、`detail_tab_view` 生产 TabBar、`theme_manager`、`setting_provider`）。
- 屏幕档位、多语言应用名 per-locale 无断言；`ios_reference_tables_and_packer_test.dart` 里放的是 Android 加固壳用例（命名误导）。

---

## 6. 声明与实现的偏差（README 对账）

| # | README 声明 | 实测 | 判定 |
|---|---|---|---|
| 1 | 1,728 根测试 + 441 包内（`README.md:245`） | 1,746 根 + 447 包内（2,193） | ❌ 过期（P2-2） |
| 2 | Android 21 条规则 + 28 条权限（`:88`） | 规则表 21 + 表外 15 = 36 个 ruleId；权限 29 条 | ⚠️ 口径/数字旧 |
| 3 | iOS 30 条规则（`:88`） | 34 个 iOS ruleId（30 隐私 + 4） | ⚠️ 口径 |
| 4 | 四种语言完整覆盖（`:156-158`） | 翻译 0 缺失，但选择器只 3/6 | ❌ 可操作性（P1-4） |
| 5 | ja/ko 各缺约 10%（`:158`） | 102/1,151 = 8.86% | ✅ 保守准确 |
| 6 | 批量命名（`:128`） | 只有单文件 | ❌ 未实现（P2-3） |
| 7 | 系统文件图标默认关闭（`:135`） | 默认 `true` + 启动自动登记 + 安装器写 HKLM | ❌ 过时（P2-12） |
| 8 | adb 安装原始输出逐行显示（`:103`） | 单 APK 成立；XAPK/APKS 只报阶段 | ⚠️ 部分成立 |
| 9 | 安装时可选是否关联（`:173-188`） | 首次启动无条件补登记 | ⚠️ 被覆盖 |
| 10 | aapt2 是"备用解析引擎"（`:221`） | XAPK/APKM/APKS 完整元数据必需 | ❌ 未披露依赖（P1-3） |
| 11 | 发布说明 macOS 11+（`release-install-notes.md:27`） | 部署目标 12.0 | ❌ 用户可见错误（P1-6） |
| 12 | iOS 安装未实现（`:265`） | 属实 | ✅ 已披露 |
| 13 | Assets.car 约 50% 出图（`:61`） | 50.6% | ✅ 准确 |
| 14 | 签名验证依赖外部工具（`:263`） | 属实（工具缺失→UNKNOWN） | ✅ 准确 |
| 15 | 静态分析边界（DexClassLoader/预算/不脱壳） | 属实且有 limitation 输出 | ✅ 准确 |
| 16 | 文件关联支持 5 扩展 | macOS plist + Windows 安装器均含；安装页拒收 `.apkm` | ⚠️ 入口不对称 |
| 17 | 单实例 / 缩略图视图限制 / WebP 回退 | 与代码一致 | ✅ 准确 |

**结论**：README 在"能力边界"上诚实度很高（8 条已知局限逐条准确），但**在"数字、可操作性、默认状态"上落后于代码**，且这些漂移没有测试守护。

---

## 7. 历史审计遗留项复核

### 已修复（10-18/19 审计点名，本轮逐条回代码核实）

| 项 | 现状 | 证据 |
|---|---|---|
| v1-only 与未签名结论相同 | ✅ 已修 | `android_security_rules.dart:721-729` 用 `hasV1Signature` 互斥；`apk_signing_block_test.dart:99,115,220-240` |
| 资源表覆盖用 locales+densities 代理 | ✅ 已修 | 改用真实 `arscEntryCount`；`analysis_coverage_test.dart:167` |
| nativeHardening 覆盖分母 | ✅ 已修 | 全包唯一库数；`parse_task.dart:292-294`、`audit_coverage_honesty_test.dart` |
| `hasCoverageGaps` 恒真 | ✅ 已修 | 拆 `hasDeclaredLimitations` / `hasActualGaps` |
| iOS 从不构造 `NetworkFacts` | ✅ 已修 | `ios_privacy_audit.dart:583/1998` |
| 必需理由 API 读不出 | ✅ 已修 | `ipa_info_plist.dart:692`、`ios_privacy_audit.dart:1631` |
| `ios.executables` 分母虚报 | ✅ 已修 | `ios_privacy_audit.dart:463/1831` + 回归测试 |
| `ios.machoSites` 措辞像全看了 | ✅ 已修 | 覆盖文案已改 |
| PHOTO-PICKER 把框架引用当选择器 | ✅ 已修（2.8.7） | `ios_privacy_audit.dart:145`；RULE-A 联动测试 |
| iOS RULE-F 证据为空/文案说反 | ✅ 已修 | `ios_privacy_audit.dart:1699-1715` |
| JSON 缺平台事实 | ✅ 已修 | `analysis_report.dart:2301` + 3 条守卫测试 |
| 4 个英文标签 / 7 个 code 未注册 | ✅ 已修 | 有结构守卫测试 |
| 解压预算只看声明值 | ✅ 已修（2.4.14） | `BoundedReadLedger` / `bounded_read.dart`；CHANGELOG:2000+ |
| 加固证据正文英文 | ✅ 已修（2.4.14） | `hardening.dart:111` `android.container.anomaly` code |
| IPA 误装入口 | ✅ 已修（2.8.2） | `info_page.dart:1394-1402` 入口删除；安装页二次校验 |
| 无线配对取消黑屏 | ✅ 已修（2.8.6） | `install_page.dart:1325-1336` + 生命周期测试 |
| `No route to host` 误判 | ✅ 已修（2.8.5） | `adb_service.dart:425-459` 重启重试 |

### 仍未关闭

| 项 | 现状 | 本报告编号 |
|---|---|---|
| Markdown 报告缺字段 | ❌ 11 组（旧审计只修了 JSON 一半） | P1-5 |
| 诊断本地化 14/57 | 🟠 43 个未迁 | P2-11 |
| 8 类常见权限只补 4 类 | 🟠 4 类仍缺 | P2-8 |
| `AnalysisCoverage.hasGaps` 生产零引用 | 🟡 与 `hasActualGaps` 并存 | P3 |
| 13 个 APK 夹具 0 DEX/0 .so | 🟡 未变 | P2-10 |
| `vector_to_svg` 零测试 | 🟡 未变 | P3 |
| `ZipBudgetTracker` 未接线 | 🟡 仍仅测试引用 | P3 |
| 真实样本/语料门禁 | 🟡 CI 结构性跳过 | P2-1 |

---

## 8. 建议的下一步

### 8.1 发布前（0.5–1.5 天）

1. P1-6 改发布说明 macOS 版本（5 分钟）。
2. P1-4 语言选择器补齐 6 项（0.5 天）。
3. P1-1 缩略图停用/状态统一 HKLM+HKCU（0.5–1 天，需 Windows 验证）。
4. P2-2 更新 README 两处测试数字 + README_en（10 分钟）。
5. P1-3 至少加显式诊断与 README 脚注（0.5 天）；有余力再做内置解析兜底。

### 8.2 一周内（质量门禁）

1. 把 `external-samples` 纳入发布门禁（或有样本时失败即阻断），并在 Release 页标注"本次是否跑了真实样本"。
2. 加 `flutter test --coverage` + 最低覆盖率阈值（先设一个能守住现状的值）。
3. 三平台产物冒烟：Linux `--appimage-extract` + 启动；macOS `lipo -archs` 断言 + 启动一次；Windows 用 runner 直接跑 Setup 静默安装 + 启动。
4. 把 `readme_consistency_test` 扩展为"数字与门禁一致"，并把语言选择器项数、缩略图默认状态纳入断言。
5. 修 Scoop `asset_name`、macOS `build_runner` 参数、Linux 空 glob 风险。

### 8.3 两周内（功能补齐）

1. iOS 分发类型分类（企业/Ad-Hoc/App Store）+ 装前体检字段（`ProvisionsAllDevices`/`ProvisionedDevices`）。
2. Markdown 报告补 11 组字段 + 界面/Markdown 字段对等守卫。
3. APKS `toc.pb` 解析 / 分包过滤；安装失败 `INSTALL_FAILED_*` 映射；取消后的真实状态提示。
4. 批量命名（或多选）实现；`riverpod_utils.dart` 删除；零测试 UI 文件补关键断言。
5. 补 4 类权限目录；把"伪装 so"升级为 `SecurityFinding` 或在 `securityOnly` 里保留加固线索。

### 8.4 保持声明（明确不做）

- 不做 iOS 重签名（与产品定位冲突，README 已声明）。
- 不实现 deepmap2 `0x02/0x03`（已论证不可靠；保持"报不解"）。
- 不追求完全替代 aapt2（内置解析器已覆盖大部分；补兜底即可）。
- 暂不做 Windows ARM64 / Linux ARM（未声明）。

---

## 9. 附录

### 9.1 门禁实测命令与结果

```bash
cd /Users/wangbaye/Projects/AppInfoTool
export PATH="$HOME/development/flutter/bin:$PATH"

dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')
# Formatted 345 files (0 changed) — exit 0

flutter analyze --fatal-infos --fatal-warnings
# No issues found! (ran in 15.8s) — exit 0

flutter test
# 00:58 +1746 ~15: All tests passed! — exit 0

flutter build bundle
# exit 0

for pkg in packages/*/; do (cd "$pkg" && dart test); done
# analysis_model 93 / apk_parser 144 / app_icon_extractor 25 /
# archive_safety 40 / ipa_parser 145 — 全部 exit 0

for pkg in packages/*/; do (cd "$pkg" && dart analyze --fatal-infos --fatal-warnings); done
# 5 个包全部 No issues found — exit 0
```

环境：Flutter 3.47.7 stable，macOS arm64，commit `b7adbc5`。

### 9.2 规模与测试分布

- 生产代码：`lib/` 手写 87 文件 / 31,409 行；`packages/` lib 31,756 行 + `tool/` 848 行。
- 测试：根 136 文件 / 36,646 行；包内 26 文件 / 6,466 行。
- 夹具：102 文件 / 984 KB。
- 根测试主题分布见 §2.4；包内测试 447 条（93/144/25/40/145）。

### 9.3 审计限制与不可验证项

1. **平台**：只在 macOS 上跑了门禁；Windows C++/Inno、Linux AppImage 均是静态审查。Windows 缩略图运行时、文件关联真实注册表写入、单实例转发、安装器交互都未真机验证。
2. **真实样本**：未配置 `APPINFOTOOL_SAMPLES`，15 条真实样本/语料用例跳过。仓库内 `sun_signed.ipa` 让部分 iOS 真实样本测试得以执行，但 APK 大样本 E2E 未跑。
3. **远端 CI**：未查询 GitHub Actions 历史与 Release 资产，只审配置语义；"CI 是否真绿过"无法核实。
4. **性能/内存**：未运行 `tool/perf_probe*`、语料评估与内存 ΔRSS 探针；这些也不在 CI。
5. **分数性质**：功能兑现率是"声明范围"口径，不是产品质量认证；工程质量分是审计员按四维权重打的主观分，用于排序优先级，不宜当作 KPI。

### 9.4 分板块工作底稿

本次审计由 5 名审计员并行完成，分板块底稿共 1,365 行（Android 257 / iOS 259 / 界面 275 / 安装 225 / 工程质量 349），逐能力点带 `file:line` 与测试证据。底稿用于交叉核对，未随仓库提交；本报告 §4–§7 保留其结论与关键证据。

### 9.5 主要证据入口

| 主题 | 文件 |
|---|---|
| 解析器 | `packages/apk_parser/lib/src/`、`packages/ipa_parser/lib/src/` |
| 安全规则 | `packages/apk_parser/lib/src/security/android_security_rules.dart`、`packages/ipa_parser/lib/src/security/ios_privacy_audit.dart` |
| 报告导出 | `lib/utils/analysis_report.dart`、`lib/utils/report_exporter.dart` |
| 安装 | `lib/pages/install_page.dart`、`lib/utils/adb_service.dart`、`lib/utils/xapk_installer.dart` |
| 缩略图 | `windows/thumbnail/`、`windows/runner/thumbnail_channel.cpp`、`lib/utils/system_thumbnail.dart` |
| CI/发布 | `.github/workflows/build.yml`、`windows/installer/appinfotool.iss` |
| 测试 | `test/`、`packages/*/test/`、`test/fixtures/` |

---

**审计结论**：AppInfoTool 在 2.8.7 已经是一个**功能基本完整、解析与安全能力明显高于同类工具**的项目；它的主要风险不在"功能没做"，而在"**做了但最后一公里没验证**"与"**声明没有跟着代码更新**"。把 §8.1 + §8.2 做掉，整体成熟度会从 90 提升到 94 左右；§8.3 属于增强，不是发布阻塞项。
