# AppInfoTool 功能与完成度审计报告

- 审计日期：2026-11-28
- 审计对象：工作区（基于 `fb25078`，未提交改动 43 个 + 未跟踪文件 33 个）
- 版本：`pubspec.yaml` 仍为 **2.10.6**（本次改动未升版本、未写 CHANGELOG）
- 性质：**只读审计**。除本报告外未修改任何文件、未提交、未发布。
- 口径：完成度回答「产品承诺的能力是否完整可用」；不回答「检测准确率是多少」。

---

## 0. 结论摘要

**综合完成度：功能 90 / 100，交付就绪度 62 / 100。**

功能层面，这个项目已经从「APK 解析工具」长成了完整的静态分析桌面应用：Android / iOS 双平台解析、静态安全引擎、权限说明、证书详情、LibChecker 库识别、adb 安装、版本对比、报告导出、六语言界面，且核心链路都有测试覆盖。本次会话补齐的四块（概览信息、权限说明、签名信息、库识别）与 V4 界面重做均已落地并验证。

交付层面则相反：**76 个文件未提交、版本号与 CHANGELOG 未更新、README 与实现已经互相矛盾、macOS 包是 ad-hoc 签名**。这些不是功能缺陷，但会让「已经做完的东西」无法被可靠地交付与复现。

| 维度 | 评级 | 依据 |
|---|---|---|
| Android 包解析 | 完整 | APK/XAPK/APKM/APKS、manifest/arsc/图标、分包/OBB、特性/语言/启动 Activity |
| iOS 包解析 | 基本完整 | plist / Mach-O / 框架 / Assets.car（出图率约 50%）；安装未实现 |
| 静态安全引擎 | 基本完整 | Android 40 个规则 id + 33 条权限条目；iOS 39 个规则 id；覆盖范围与 UNKNOWN 语义完整 |
| 权限说明 | 完整 | 1102 条 protectionLevel 位掩码 + 33 条语义规则 + 五档风险分组 |
| 签名信息 | 完整（读取）/ 部分（验证） | v1 PKCS#7 与 v2/v3/v3.1 证书、三种指纹、DN/序列号/有效期；验证仍依赖 apksigner |
| 库识别 | 完整 | LibChecker 3053 条规则、197 个厂商 LOGO、原生库/组件/DEX 三类匹配、Kotlin/Compose 标记 |
| 界面（V4 原型） | 基本完整 | 概览/分析/对比/安装/设置/侧边栏已对齐；iOS 概览未对齐 |
| 安装到设备 | Android 完整 / iOS 缺失 | adb 有线/无线、分包、选项、历史、日志；iOS 按评估文档暂不实现 |
| 对比与历史 | 完整 | 字段级 + 集合级三态差异、导出、最近文件与历史页 |
| 报告导出 | 基本完整 | Markdown / JSON / HTML，schema v9；新数据未进报告 |
| 国际化 | 基本完整 | 6 语言、1630 键/语言；1 处硬编码英文 tooltip |
| 工程交付 | 不足 | 未提交、未升版本、未写变更日志、macOS 未签名公证 |

---

## 1. 审计方法与证据

### 1.1 代码规模

| 项目 | 数值 |
|---|---|
| `lib/` Dart 文件 | 140 个 / 74,688 行 |
| 五个内部 package | `apk_parser`、`ipa_parser`、`analysis_model`、`app_icon_extractor`、`archive_safety`（合计 41,036 行） |
| 测试文件 | 232 个 `*_test.dart` |
| i18n | 6 语言（en / ja / ko / zh-CN / zh-HK / zh-TW），每语言 1,630 键 |

### 1.2 本机门禁实跑

| 门禁 | 结果 |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test`（根） | **1,957 通过 / 20 跳过**（跳过项为需要 `APPINFOTOOL_SAMPLES` 的真实样本测试） |
| 包内测试 | `apk_parser` 265、`ipa_parser` 258（此前运行） |
| macOS release 构建 | 成功，`dist/AppInfoTool-2.10.6-macos-universal.zip`（35 MB，sha256 `8f35291d…`） |
| 冒烟运行 | 二进制启动后存活，无资产加载错误 |

### 1.3 仓库状态（关键）

```
43 个已修改文件（M）
33 个未跟踪文件（??）
packages/apk_parser/build/ 6.8 MB   ← 未忽略
packages/ipa_parser/build/  7.9 MB   ← 未忽略
```

未跟踪内容包含本次全部新增能力：`assets/data/android/`、`assets/libchecker/`、`lib/widgets/android_{permissions,libraries,signature,components,manifest_extras}_panel.dart`、`lib/utils/{android_metadata,libchecker_data,install_history,cache_manager}.dart`、`packages/apk_parser/lib/src/libraries/`、`tool/sync_libchecker_rules.py`、11 个新测试文件。

---

## 2. 功能矩阵（逐模块）

### 2.1 Android 解析 —— 完整

- 格式：APK / XAPK / APKM / APKS；分包与 OBB、容器结构（DEX / 原生库 / 顶层目录）。
- 清单：包名、版本、SDK 区间（含 API 37 与系统发布年月）、屏幕尺寸、密度（ldpi…xxxhdpi）、ABI、`debuggable`、`allowBackup`、`networkSecurityConfig`（展开 XML）。
- 新增：硬件/软件特性（必需 + 可选，带平台说明与中文名）、语言列表（标签 + 本地化名称 + 自称）、启动 Activity、编译 SDK、Application 类。
- 图标：`resources.arsc` + adaptive icon 渲染（`app_icon_extractor`）。

### 2.2 iOS 解析 —— 基本完整

- Info.plist、Bundle ID / 版本 / 最低系统 / 设备族、嵌套 Bundle 与 Framework、URL Scheme、后台模式、设备能力、用途说明。
- Mach-O 架构、加密标志（cryptid）、`__objc_classrefs` / `__objc_selrefs`、隐私清单 `PrivacyInfo.xcprivacy`。
- `Assets.car` 纯 Dart LZFSE 解码：出图率约 **50%**，deepmap2 多平面变体明确「不解」，不伪造结果。
- **缺失**：IPA 安装（`docs/notes/install-support-eval.md` 已说明门槛在签名，尚未实现）。

### 2.3 静态安全引擎 —— 基本完整

- Android：40 个规则 id（含跨字段组合规则）+ 33 条逐权限条目。
- iOS：39 个规则 id（含重打包、加密二进制、隐私、越狱工具、符号能力）。
- 统一模型：P0–P3 / INFO / **UNKNOWN** 严格分开；每条结论带证据、置信度、覆盖维度；覆盖不足不显示绿色。
- 设计边界（非缺陷）：不执行样本、不联网、无运行时证据；`hasRuntimeEvidence` 恒为 false。

### 2.4 权限说明 —— 完整

- `assets/data/android/protection.json`：1102 条 `protectionLevel` 原始位掩码（Android 37.0）。
- 33 条语义规则（`permission_catalog.dart`，`rulesVersion android-permissions-2026.11.1`）。
- 五档风险：high（16 个显式高危）/ sensitive（dangerous）/ normal / system（signature 等）/ unknown；固定注明「策略分级，不等于恶意」。
- 官方标题与说明跟随界面语言（6 语言，143 条有官方文案，缺失回退英文短名）。

### 2.5 签名信息 —— 读取完整，验证受限

- 读取：v1 `META-INF/*.RSA` 的 PKCS#7、v2/v3/v3.1 APK Signing Block；全部签名者与证书。
- 字段：主题/签发者 DN（RFC 4514）、序列号、有效期、签名算法、公钥算法与位数/曲线、SHA-256 / SHA-1 / MD5 指纹（冒号大写、可复制）。
- 界面：方案 chips + 状态 chip（通过/失败/未验证/未知）+ 每证书一卡 + 「本地读取，未验证」说明。
- 验证：仍依赖 `apksigner`；未安装时明确显示「未验证」而不是「无效」。

### 2.6 库识别 —— 完整

- 数据：LibChecker-Rules `dataVersion 50`，3053 条（3039 条可匹配），Apache-2.0，含 LICENSE。
- 匹配：`.so` 文件名（含加固壳交叉验证）、组件名 / Intent action、DEX 包名前缀；原生库按 ABI 合并且体积求和；未识别库按体积单列。
- 标记：Kotlin、Jetpack Compose、Flutter、Unity、商业壳。
- 图标：197 个厂商 SVG（`assets/libchecker/icons.json`，587 KB）经 `flutter_svg` 渲染，缺失时退回字母牌。
- 限制：数据离线打包，更新需手工运行 `tool/sync_libchecker_rules.py`。

### 2.7 界面 —— V4 原型对齐基本完成

- 概览：空态英雄区 + 引擎表 + 四统计卡 + 环境/流水线；解析态 hero/posture 等高、最近文件/会话日志等高、真实应用图标。
- 分析：9 个 Tab（概览 / 清单 / 组件 / 权限 / 库识别 / 安全 / 签名 / 文件 / 诊断），组件按类型分组并逐条渲染导出状态，特性卡在右栏底部。
- 对比 / 安装 / 设置 / 侧边栏：按原型重做；最近文件保留在侧边栏并可回打开。
- 已知不对称：**iOS 概览没有**「基本信息 / 证书摘要」卡（这两块只在 Android 路径），iOS 概览仍是旧版式。

### 2.8 安装（Android）—— 完整

- 有线自动发现、无线 `adb pair` / `connect` / 断开、记住设备。
- 设备详情：品牌 + 型号 + 系统版本 + ABI + 可用空间 + serial。
- 选项：`-r` 覆盖、卸载后装、`-d` 降级、`-t` 测试包、`-g` 授予全部运行权限。
- 安装历史（最多 10 条，持久化）、最近安装表、实时日志与复制、分包勾选。

### 2.9 对比 / 历史 / 报告 —— 完整（报告有缺口）

- 对比：字段级 + 集合级，三态（变化 / 新增 / 无法比较），可分 Tab 过滤、导出。
- 历史：分析历史页（侧边栏「管理」入口）。
- 报告：Markdown / JSON / HTML，schema v9，含覆盖范围与局限说明。

### 2.10 设置与系统集成 —— 大部分

- 工具路径（adb / Java / apksigner）、自动检测、依赖下载。
- 诊断日志导出、缓存清理（只清图标缓存与轮转日志）、外部样本目录状态。
- 文件关联、Windows 资源管理器真实图标（默认关闭，需手动启用）、单实例。
- 更新检查：按钮只打开 GitHub Releases 页面，不做版本比较。

### 2.11 国际化 —— 基本完整

- 6 语言、1630 键；本轮修掉了主题名、保护级别、「No data」「default」等硬编码英文。

---

## 3. 问题清单

### P1（交付风险，建议本周处理）

1. **76 个文件未提交，且包含全部新能力与 1.6 MB 数据资产。**
   没有任何一次提交可回溯；机器故障即全部丢失。`packages/*/build/`（14.7 MB）未忽略，会被误提交。

2. **重大功能未升版本、未写 CHANGELOG。**
   `pubspec.yaml` 仍是 2.10.6，CHANGELOG 顶部仍是「一键复制诊断信息」。本次新增权限面板、库识别、签名面板、V4 界面重做，却没有任何版本记录 —— 用户与审计都无法判断「2.10.6 到底包含什么」。

3. **macOS 产物为 ad-hoc 签名，未公证。**
   分发 zip 给测试者时需右键「打开」绕过 Gatekeeper；若后续对外发布，这是首个会撞上的门槛。

4. **报告 schema 与界面信息不一致。**
   界面已展示权限风险分组、protectionLevel、库识别结果，但 Markdown/JSON 报告仍只列原始权限名，`schema v9` 未包含这些新数据。导出报告不能复现界面结论。

### P2（一致性/文档）

5. **README 与实现漂移**：
   - 仍写「不含图标资源，界面上用首字母色块代替」——实际已内置 197 个 SVG；
   - 规则数量写「Android 21 条 + iOS 30 条」，实际约 40 + 39 个规则 id（`docs/notes/security-confidence-review.md` 又写 59 条）；
   - 未记录本次签名面板、组件面板、V4 界面。

6. **iOS 概览未与 Android 对齐**：缺少基本信息卡与证书摘要卡，版式仍是旧版。

7. **设置页「检查更新」tooltip 硬编码英文**（`lib/pages/setting_page.dart:1515`），且行为只是打开 Releases 页，名称有误导。

8. **安装历史只覆盖本工具发起的安装**；设置里「安装器默认注册」是构建期行为，运行期无法切换（行内已注明，但容易被误读为开关）。

9. **仓库卫生**：`test/_v4_diff_shot.dart` 是手工渲染脚本仍留在 `test/`；`docs/audit/` 存在 2.11.0 阶段文档，但应用版本是 2.10.6。

### P3（打磨/边界）

10. `Assets.car` deepmap2 变体不解（约 50% 出图率），已如实报告。
11. 权限 tooltip 里的标志位（`privileged` / `runtime` …）仍用英文标识符 —— 这些是 API 常量名，本地化收益有限，保持现状可接受。
12. 本地 20 个真实样本测试因未设 `APPINFOTOOL_SAMPLES` 跳过；CI 的 samples job 依赖私有归档。
13. LibChecker 规则更新为手工脚本；无在线更新与签名校验。

---

## 4. 测试与质量证据

| 项 | 结果 |
|---|---|
| 静态分析 | `flutter analyze` 无问题 |
| 根测试 | 1,957 通过 / 20 跳过 |
| 新增测试 | 权限面板、签名面板、库识别引擎（25 + 14）、库面板端到端、Metadata、Metadata 12 条、组件面板、卡片间距、缓存、安装历史、V4 diff、X509（8 条） |
| 关键回归守卫 | 签名证书 11 字段、权限位掩码 0x12、LibChecker 19 个上游匹配用例、组件导出状态、概览三等宽与等高 |
| CI | quality（format/analyze/test/compile）+ samples + Windows/Linux 构建 |

---

## 5. 建议路线（按优先级）

1. **P1-a**：`git add` 全部改动，拆成可审查提交（四块功能各一个 + UI 一个 + 数据资产一个）；把 `packages/*/build/` 写进 `.gitignore`；删除 `test/_v4_diff_shot.dart`。
2. **P1-b**：升版本到 **2.11.0**（或 2.10.7），补 CHANGELOG：权限说明、库识别、签名面板、V4 界面、iOS 用途说明。
3. **P1-c**：决定报告 schema v10 —— 至少把权限风险分组、protectionLevel、库识别分组写入 JSON/Markdown，保证导出可复现界面结论。
4. **P2-a**：README 数字与功能表同步；统一三份文档里的规则数量口径（以运行时 `countByType` 为唯一事实源）。
5. **P2-b**：iOS 概览补基本信息卡与证书摘要卡（复用 Android 的 `_AndroidBasicInfoCard` 思路）。
6. **P2-c**：`check_updates` 要么实现真实版本比较，要么改名「查看发布页」并本地化 tooltip。
7. **P3**：macOS 签名/公证排期；LibChecker 在线更新与规则签名留作后续。

---

## 6. 可信度边界

- 本报告基于源码阅读 + 本机门禁实跑，未在真实 Windows / Linux 桌面上做运行验收。
- 安全结论的准确率无法由测试证明：项目没有样本库、没有 IOC 语料，官方基线只有 2 条 Android、0 条 iOS。
- 「完整」在本文中指「承诺的功能存在且行为一致」，不代表「覆盖所有真实世界的畸形包」。

---

## 7. 整改记录（2026-11-28，同日）

P1-1、P1-2 已处理：

- **提交**：`feature/2.11.0` 上按能力拆成 6 个提交（`4163697` 仓库卫生 → `093c634` 数据与文案 → `df3e42e` Android 引擎/面板 → `9a0ed8e` V4 界面 → `f58430e` 文档 → `02fc2ef` 2.11.0 发布），工作区已干净。
- **忽略规则**：`packages/*/build/` 已加入 `.gitignore`；`test/_v4_diff_shot.dart` 已删除。
- **版本**：`pubspec.yaml` 升到 **2.11.0**，CHANGELOG 补 2.11.0 条目（权限说明 / 库识别 / 证书详情 / 概览补充 / V4 界面 / 国际化）。
- **复验**：`flutter analyze` 无问题；`flutter test` **1,957 通过 / 20 跳过**。

P1-4 已处理：报告 **schema v10** 收录 `application.permissionDetails`（风险 / protectionLevel /
位掩码 / 标志位）与顶层 `libraries`（SDK 分组、未识别原生库、Kotlin/Compose），
Markdown 增加权限分级表与「库识别」小节；契约文件 `docs/contracts/analysis-report-v10.schema.json`。
采集失败或缺少安装包路径时整块不输出 —— 不用空数组把「没跑」写成「没有」。
复验：`flutter test` **1,961 通过 / 20 跳过**。

P2-2 已处理：iOS 概览补齐「基本信息」（Bundle ID / 可执行文件 / 最低系统 / 设备族 /
架构 / 嵌套二进制）与「证书链」摘要卡（证书数量 + 主题 / 签发者 / 有效期 / SHA-256，
缺材料时显示「暂无数据」而不是空卡）。测试 +2：`test/ios_detail_page_test.dart`
「IPA 概览 — 基本信息与证书摘要」。复验：`flutter test` **1,963 通过 / 20 跳过**。

仍待处理：P1-3（macOS 公证）、P2-1（README 数字口径）、P2-3（检查更新改名）。

