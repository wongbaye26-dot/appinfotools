# Changelog

## 2.4.1 — 2026-10-16

> 2.4.0 发布后用户报告的 3 项问题：导出报告全部失败、四个页面头部版式不一、
> 版本号跟进。根因与取证见 `docs/plans/V2.4.0_PROGRESS.md` §20。

### 修复

- **导出报告全部失败（`ENTITLEMENT_REQUIRED_WRITE`）。** 概览页与版本对比页的
  「导出报告」点下去只弹一句 `PlatformException(ENTITLEMENT_REQUIRED_WRITE, ...)`，
  **保存面板根本不出现**。根因不在 Dart 侧：`file_picker`(>=10) 的 macOS 端在弹
  面板**之前**就用 `SecTaskCopyValueForEntitlement` 检查
  `com.apple.security.files.user-selected.read-write`，值为 true 才继续。本应用
  刻意不开沙箱（重命名要在用户选中的文件旁边写文件，沙箱只授予那一个文件、不含
  它所在的目录），于是这个键从来没声明过 —— 而 user-selected 这一族授权在
  **非沙箱进程里是惰性的**：声明了不生效，不声明反而会被插件判成「没有权限」。
  两个 entitlements 文件补上该键（**不引入** `app-sandbox`，沙箱的开关只有它
  一个）。同一处检查也在 `pickFiles` 上，「打开文件」按钮本来也受影响。
  `test/macos_entitlements_test.dart` 解析 plist 钉住这两个键的取值，防止下次
  有人「顺手清理」掉它们而界面毫无征兆。
- **「用户取消保存」被报成「导出失败」。** 两个导出对话框各自把「面板返回
  null」与「写盘抛异常」混成一类处理，调用方只能靠 `null` / `true` / 异常对象
  三态去猜。弹面板 + 写盘收成一份 `ReportExporter`，结果做成**三态类型**
  （saved / cancelled / failed），取消不再报错；entitlement 类失败翻译成一句
  可操作的中文，而不是复述错误码。两个对话框原先各写一遍的实现随之删掉。

### 调整

- **四个页面共用同一个 `PageHeader`。** 此前四种做法：概览页没有页头（标题只在
  Hero 里显示当前包名）、分析页是 `AppBar` 里的标题 + 四个图标动作、版本对比页
  是页面内联的一个 `Row`、设置页是 `AppBar` 里一个孤立的标题。现在统一成
  **左边标题 + 副标题、右边操作**（就是版本对比页原来的做法），四页只差标题
  文字。分析页与设置页的 `AppBar` 一并去掉 —— 窗口拖动靠的是系统标题栏，
  Flutter 的 `AppBar` 并不提供 macOS 的拖动区，另两页本来就没有它。
- **概览页的三个动作（打开文件 / 查看详情 / 导出报告）移到页头右上角**，与版本
  对比页的「导出对比报告」同一个位置。原先它们竖排在 Hero 右侧，那一列比左侧
  文字列还高，Hero 因此多占约 56px。宽窗口用带文字的紧凑按钮，窄窗口只留图标
  （带 tooltip）—— 三个带文字的按钮在 660px 内容区里会把标题列挤到几十像素、
  标题一个字一行地竖排下去。
- **`PageHeader` 的标题与副标题各占一行**（窄窗口省略号截断）。副标题折行会把
  页头从 58px 撑到 78–98px，而概览页是固定一屏布局，多出来的每一像素都要从
  底部「最近文件」里扣。
- **概览页窄窗口的纵向间距收紧**（页头下 12→8、Hero 与统计之间 14→10、Hero
  内边距 18→16）：补上 58px 页头之后，最小窗口（内容区 660×600）正好差十几像素。

### 已知限制

- **本机无法构建 macOS 产物**（`flutter build macos` 在 SPM 解析那一步被沙箱
  拒绝，而且**退出码是 0**，只能靠产物时间戳判断成败）。三个平台的产物由 CI
  在打 tag 后构建 —— 本次的 entitlement 修复因此**只在 CI 产物上可验证**。

## 2.4.0 — 2026-10-16

> V2.4.0 的五个阶段（任务书与逐阶段取证见
> `docs/plans/V2.4.0_PROGRESS.md`）全部完成，另加三项计划外补强。
> 自 v2.3.7 起共 41 次提交；本地根测试 1067 通过 / 14 跳过，
> 四个 package 共 150 条；配真实样本后 1080 通过 / 1 跳过。

### 新增

- **版本对比（阶段 5，全新能力）。** 侧边栏新增「版本对比」页：选两个**已解析**的包，
  逐字段、逐集合地比较，三态呈现（新增 / 删除 / 变更）。字段级覆盖应用身份、
  SDK 区间、签名结论等 20 项，集合级覆盖权限、组件、原生符号、ABI、语言、
  屏幕密度、网络域名 / IP。可导出**独立的** Markdown 与 JSON 对比报告
  （两边的原始状态都带上，`hasChanges` 与「说不清」分开计数）。
  与单文件报告同一条原则：**机器 id 进 JSON，本地化名字进界面与 Markdown**。
- **iOS 签名材料加深（阶段 2）。** 新增解析 `CodeResources`（密封清单条目数）
  与 CMS 证书链的公开字段（条目数、证书、签名值、摘要）。仍**只做静态提取、
  不做验证** —— 与 `codesign` 的结论并列而不是合并，材料存在不等于签名有效。
- **iOS 隐私审计覆盖嵌套 Bundle（阶段 2）。** 用途说明审计原来只看主应用，
  现在嵌套 Bundle 的 `Info.plist` 与 Mach-O 也纳入，按 Bundle 汇总覆盖。
- **报告「技术摘要」段（阶段 4）。** 按八部分结构补齐，与既有各段并列。
- **报告 schema 升到 v4（阶段 4）。** `findings[]` 补 `messageCode` /
  `recommendationCode` / `relationshipCode` / `limitationCode`，`evidence[]` 补
  `detailCode` / `locationCode` —— 只增不改，老消费者忽略新字段即可。
- **证据可读化（阶段 4）。** 证据位置把类型描述符还原成类名、偏移标上单位，
  不再是一串 `Lcom/foo/bar;` 与 `+0x1a2b`。
- **覆盖维度名与全部发现项文案本地化（阶段 1.3 + B11）。** 15 个覆盖维度、
  33/33 条 Android/iOS 发现项、36 条结果级说明、以及关系的关联说明与局限
  全部改成「稳定 code + 英文回退」结构，中英日韩韩五语可用。
  「无法确认」与「低风险」不再混在一起。
- **解析诊断的本地化（第一批，计划外）。** 详情页「解析诊断」与报告里的
  诊断行，已迁移的 14 类改成中文框架 + 机器标识；**其中 4 条 `android.*`
  原先写的是中文**，英文 / 日文 / 韩文报告里会混进中文，现已改为英文回退。

### 修复

- **真实样本测试会因「目录里没有 APK」崩在 null-check 上**（阶段 1）。
  改为五种情况分别给出可理解的跳过原因，配 / 不配样本、只有 APK / 只有 IPA
  都能跑；CI 新增 job 执行包级测试与自包含夹具测试（实测 run#46 通过）。
- **UI 测试靠「把视口拉到 40000 高」让卡片进 widget 树**（阶段 1）——
  详情页是懒构建的 `ListView`，真实样本一长就失效。改为真实滚动定位。
- **覆盖率「受限」与「未覆盖」曾经显示成同一份绿色**（阶段 1）。
  覆盖度改为结构化输出（逐维度状态 + 覆盖量 + 说明），界面、Markdown、JSON
  读同一份数据。
- **Android 详情页一批字段读的是裸字段、用 `?? ""` 兜底**（阶段 1）——
  「文件里没有」与「我们没读到」在界面上长得一模一样，而结论相反。
  剩余 12 个字段改走统一模型，全库详情页 `?? ""` 归零。
- **`SetDiff` 把「我们没读到权限」算成「左边的权限全被删了」**（阶段 5.1
  自查发现并修正）。集合维度现在带 `comparable`，不可比时 `added`/`removed`
  一律为空 —— 与字段级刚立的「说不清不是差异」原本自相矛盾。
- **`tester.drag` 驱动不了满是 `SelectableText` 的详情页**（计划外）。
  触摸拖拽落在可选中的文本上时，文本选择的手势识别器赢得竞技场，列表一动不动；
  真实样本上的表现是「滚到 MD5 卡住，后面的 SHA-1 / SHA-256 永远看不到」。
  测试改为直接驱动 `ScrollPosition`（**产品代码未动**：桌面端 Flutter 默认
  不吃鼠标拖拽，滚轮与触控板走的是另一条通道）。
- **Android 包的签名结论写着「非 macOS」**（计划外）。`notChecked` 被映射到了
  iOS 专属的 codesign 文案，而它实际上只出现在 Android；改为平台中立措辞。
- **字段值的诊断说明是硬编码英文**（计划外）。`FieldValue` 补 `diagnosticCode`
  / `diagnosticArgs`，四处渲染收成一份实现；中文下现在是
  「aapt2 不报 maxSdkVersion」「设置里关闭了哈希计算」。

### 调整

- **Android 安全规则从硬编码 if 链抽成可配置规则表**（阶段 3），与 iOS 对齐；
  现有 finding 数量与等级不回归，有测试逐条驱动。
- **跨方法关联的措辞与置信度有测试钉住**（阶段 3）：「同方法内同现」与
  「跨方法」分开陈述，且**不因此抬高等级**。
- **Android 权限目录收口**（阶段 2）：版本条件说明、`EXPIRED` / `INERT` 状态、
  Android 15/16 的版本条件都在。
- **README / docs 标注过时**（阶段 1.6）：两个文档开头加「已过时」提示，
  不改正文；README 的功能清单补上「版本对比」。

### 已知限制

- **本机无法构建 macOS 产物**（`flutter build macos` 在 SPM 解析那一步被
  沙箱拒绝，而且**退出码是 0**，只能靠产物时间戳判断成败）。三个平台的产物
  由 CI 在打 tag 后构建。
- **`AnalysisDiagnostic` 的诊断文案只迁了第一批**：57 类里还有 43 类是英文
  （其中 12 类的文案来自其他层，要改结构）。未迁移的照旧显示英文原文。
- **差异报告不含发现项差异**：只比较字段与集合。
- **版本对比没有真实的两版本样本**：样本目录里只有一个真实 APK 与一个 IPA，
  端到端只验证到「同一个包与它自己」。

## 2.3.1 — 2026-10-15

> 本轮由用户报告的 6 项问题驱动，实现与取证过程见
> `docs/audit/2026-10-15-overview-drop-and-ui-fixes.md`。

### 修复

- **概览页的「统计」与「最近文件」恒为空。** `RecentFilesManager.load()` 在
  列表为空时返回 `const []`，而 `add()` 紧接着对它做 `removeWhere` 去重 ——
  不可变列表直接抛 `UnsupportedError`。调用点写的是 `unawaited(...)`，
  异常被彻底吞掉，于是**全新安装后第一次分析成功就炸**，界面上表现为
  「统计永远是 0、最近文件永远是空的」，而日志里一行都没有。
  `test/` 下此前完全没有最近文件的测试，这个缺陷因此长期无人发现。
- **一次拖放触发两次解析。** `IndexedStack` 会构建并布局**所有**子页
  （只画选中的那个），概览页与分析页的 `DropTarget` 渲染盒完全重叠；
  而 `desktop_drop` 的通道是全局扇出的，每个 target 再各自判「在不在界内」，
  重叠的盒子全都判定为在界内。拖一个文件到概览页会同时触发概览页的
  `pendingOpenRequest` 和分析页自己的 `openApk`，同一个文件解析两遍。
  改为 `enable: Visibility.of(context)`，让不可见的那一页把 target 关掉。
- **拖拽高亮可能永远擦不掉。** 复位只依赖 `onDragExited`，而这个回调平台
  并不保证送达。改为把 `onDragUpdated` 当心跳，配 5 秒看门狗自愈。
- **孤儿解析任务不取消。** 切换文件时代际变化只 `break` 出事件循环，
  没有取消 worker —— 它会继续把整个解析做完（真样本上是几秒 CPU 与几十 MB
  内存），而结果只会被丢掉。iOS 与 Android 两侧都补上了取消。
- **解析还没出结果时误报平台。** `FileState.platform` 派生自已到位的解析
  结果（这是刻意的），但 Hero 区在平台未知时一律渲染成 `Android`、
  应用名为空时渲染成「未加载文件」。

### 调整

- **概览页 Hero 区可展示的信息从 3 项增至 13 项**，且每一项都有复制入口：
  四个状态卡片（平台 / 大小 / 签名 / 安全）的值可复制，另新增「详细信息」
  网格（文件名 / 文件路径 / 版本 / 构建号 / 最低系统或最低 SDK / 目标 SDK /
  可执行文件 / SHA-256 / SHA-1 / MD5），哈希的 tooltip 会显示完整值。
  网格按可用高度自适应并内部滚动，列数由可用宽度决定 —— 这一页是固定一屏
  布局，Hero 长高了必须有东西让位。
- **复制入口下沉到 `TitleValueLayout`（`copyable` 默认 true）**与新增的
  `CopyIconButton`，两个详情页因此自动一致。顺带清掉三处因此重复的
  复制按钮、与 Tab 名重复的分组标题，以及飘在 Hero 卡片外面的那个复制按钮。
- **设置页与另两页对齐**：顶栏不再用 `inversePrimary`（不再是一片紫色），
  卡片圆角 8 → 12，分组标题改用 `titleSmall` + w600。

### 工程

- 测试从 **873** 增至 **910**（1 项跳过）。新增 `recent_files_test.dart`（9 例）、
  `drop_target_ownership_test.dart`（8 例）、`overview_layout_test.dart`（8 例）。
  新增用例全部做过反向验证：把修复去掉、确认测试真的变红，再恢复。
- `main()` 装上 `FlutterError.onError` 与 `PlatformDispatcher.onError` 的
  日志兜底，只记日志、不改渲染行为 —— 让 `unawaited` 里抛出的异常留下痕迹。
- **macOS 应用在本机跑不起来**（`flutter build` 被系统级 `sandbox-exec`
  拒绝），本轮所有取证靠渲染快照与单元测试完成，真实拖放未能复现。

## 2.3.0 — 2026-10-15

> 本版本的实现依据是 `docs/audit/2026-10-15-v2.3-baseline-audit.md`（先审计、
> 再修改），验收结果见 `docs/audit/2026-10-15-v2.3-release-acceptance.md`。

### 新增：安全检测的三层取证

**DEX 结构级解析**（此前只有字符串扫描）

- **结构**：DEX 头部与六个 id 段的解析 + 边界校验（`file_size` / `header_size`
  / `endian_tag` / 段越界 / adler32 校验和）。结构不可信时「没发现线索」
  这个结论不再成立，会明确说出来。
- **方法引用**：`method_ids` / `type_ids` 的流式遍历。`method_ids` 的条目只可能
  来自字节码 invoke 指令、方法签名或方法句柄，**不会**来自字符串字面量 ——
  因此「代码引用了」与「字符串里提到了」从此分开陈述。
- **调用点**：`class_defs → class_data_item → code_item` 的指令遍历
  （含指令宽度表与 switch / fill-array-data 载荷识别），能回答「在哪个方法的
  哪个偏移调用」，并识别「同一方法内同时出现多个标记」。

**原生库符号**（此前只统计文件名）

- Android：ELF 头 / 节表 / `.dynsym` / `.symtab`，提取导入与导出符号。
- iOS：Mach-O `LC_SYMTAB`（`nlist_64`），fat 二进制的切片偏移按规范处理。
- 按**精确符号名**匹配导入符号（`system` / `popen` / `dlopen` / `ptrace` /
  `socket` …），并给出 p3 级发现项。措辞守住「有能力 ≠ 调用过」。

### 新增：资源表与归档边界

- **`uiMode`（夜间模式）**：`ResTable_config` 的偏移 29，只有 `0x20` 算夜间。
- **资源引用环检测**：显式栈 DFS（不用递归，资源表可有几十万条目）。
  实测 `aapt2` 会接受环状颜色别名，因此环只说明「这些资源解析不了」，
  **不**作为篡改证据。
- **归档边界**：单条目解压上限 256 MiB、跨多层累计预算（`ZipBudgetTracker`）、
  EOCD 条目数与实际条目数一致性。
- **分包一致性校验**：抽检包名与 `versionCode`，截断时如实报告抽检了多少。

### 新增：iOS 规则补齐

- **规则 A / B / E**（此前只有 C / D / F），与 Android 侧同构。
- **`UIBackgroundModes` / `CFBundleURLTypes`** 两个 Info.plist 字段。
- **按 Bundle 的扫描覆盖率**：扫描范围从主可执行文件扩到「主 + 全部嵌套
  可执行文件」，并输出「覆盖了 N 个中的 M 个」，未覆盖的逐条列出。

### 新增：结构化覆盖率与报告

- **`AnalysisCoverage`**：四态（已覆盖 / 部分覆盖 / 未覆盖 / 本次不适用）
  + 覆盖量与上限 + 说明。UI、Markdown、JSON 读**同一份**数据。
  `notApplicable` **不算缺口**（「本次不适用」与「没查到」结论相反）。
- **报告八部分**：新增「网络端点」一节（域名与 IP 分两组）。
- **JSON**：`coverage.entries` 结构化、新增 `network` 一级字段、
  `application.permissions`、`signatureSummary` 的平台详情。
  `reportSchemaVersion` 1 → 3。

### 修复

- **分包安装包（XAPK / APKM / APKS）此前完全不跑安全审计** —— 审计的唯一调用点
  在只被内置引擎使用的 worker 里，因此分包路径的 `securityResult` 恒为 `null`。
- **`ApkReader.structureAnomaly` 在生产路径上永远不会被设置**：EOCD 校验只写在
  `openBytes` 里，而内置引擎走的是流式 `open`。该防护此前等于不存在。
- **Android 侧从不传 `diagnostics`**：详情页的「解析诊断」卡片与导出报告里
  永远是空的。与 iOS 侧此前修过的是同一个缺陷。
- **`renderIcon` 的 XML 分支要求 aapt2 存在**，把「有 arsc 就能渲染」那条能力
  挡死了 —— 没装 aapt2 的机器上 XML 图标静默画不出来且不留说明。
- **Android 详情页字段状态与统一模型不一致**：`unsupported` / `failed` 被渲染成
  `-`，等于把「我们没读到」说成「文件里没有」。
- **JSON 报告的导出范围不生效**（「仅安全检测」只影响建议文件名）。
- `.gitignore` 的 `*.apk` 把测试夹具一起忽略：本地全绿、CI 找不到文件。

### 工程

- 测试从 **602** 增至 **873**（11 项因未设置 `APPINFOTOOL_SAMPLES` 跳过）。
- 新增 `test/acceptance_test.dart`（样本矩阵 / 夹具完整性 / 性能基线）与
  `test/readme_consistency_test.dart`（中英文 README 结构一致性）。
- 测试夹具全部由公开工具真实产出（`aapt2` / `javac`+`d8` / NDK `clang` /
  macOS `clang`），期望值取自 `aapt2 dump` / `dexdump` / `llvm-readelf` /
  `llvm-nm` / `otool` / `nm`。

## 2.2.0 — 2026-10-15

- 概览页改为一屏响应式布局。
- 修复概览页若干「点了没反应」的入口。
- 重写关于页与中英文 README。

## 2.1.0 — 2026-10-15

- Hero 区改为「当前文件状态面板」。
- 修复三处「点了没反应」。
- 导入文件后不解析、入口重复、界面未国际化。
- 全新应用标识。

## 2.0.1 — 2026-10-14

- 补齐最后几处未国际化的文案。
- 修复 CI 版本同步：只在打 tag 时运行（此前 main 推送会把 pubspec 的版本
  改写成 `main`，三个平台的构建全部失败）。

## 2.0.0 — 2026-10-14

- 全新界面：侧边栏导航、Tab 详情页与平台专属视觉。
- 应用名统一为 AppInfoTool。
- 修复 APK 重命名失败，并支持 IPA 重命名。


## 1.1.0 — 2026-10-14

### 新增：安全检测引擎（V1.1）

- **Android 权限审计**：解析 `AndroidManifest.xml` 中的全部权限声明，包括 `maxSdkVersion` 版本条件与 `uses-permission-sdk-23` 特殊权限，逐项对照规则目录定级（P0–P3 / INFO / UNKNOWN）。
- **DEX 字符串线索扫描**：从 `classes.dex` 中提取可打印 ASCII 字符串，匹配 21 类标记（OCR、截图、媒体读取、上传、网络库、后台任务、第三方 SDK 等），并提取域名与 IP 地址。支持单文件 8 MiB、总计 48 MiB 的预算截断，超限部分如实记入覆盖不足。
- **iOS 隐私审计**：读取 `Info.plist` 的用途说明键、`PrivacyInfo.xcprivacy` 隐私清单，并扫描主 Mach-O 可执行文件的 API 符号线索。区分 `PHPickerViewController`（系统照片选择器，不需完整授权）与 PhotoKit（完整照片库），避免误报。
- **关联分析与风险定级**：
  - 相册 + OCR → P2（可能）
  - 相册 + OCR + 上传 → P1（疑似数据链路，未证实流）
  - 明文流量 + 敏感线索 → P1
  - 后台任务 + 敏感数据 + 回传 → P1
  - 未发现上传特征时显式产出 INFO，并说明「这不表示应用不存在上传行为」
- **六语言界面**：安全检测卡片、设置开关、报告导出支持 `en` / `zh-CN` / `zh-HK` / `zh-TW` / `ja` / `ko`。
- **报告导出**：Markdown 报告新增「安全检测」章节；新增 JSON 结构化安全报告导出（含 `ruleId`、`severity`、`confidence`、`evidence`、`limitations`）。
- **设置开关**：「启用安全检测」默认开启，可随时关闭。

### 数据模型

- 新增平台中立 `SecurityFinding` / `SecurityAnalysisResult` / `SecuritySeverity` / `SecurityConfidence` 等模型（`analysis_model` 包，零依赖）。
- `PackageAnalysisResult` 新增 `security` 字段，`AnalysisBuilder` 双平台均支持挂载。

### 测试

- 新增 10 项安全模型测试、7 项 DEX 扫描器测试、19 项 Android 安全审计测试、15 项 iOS 隐私审计测试、10 项应用层集成测试。
- 全量测试 593 通过 / 11 跳过。

## 1.0.0 — 2026-04-01

### 初始发布

- Android 包解析：APK / XAPK / APKM / APKS，支持 aapt2 与内置 Dart 解析器双引擎。
- iOS 包解析：IPA，支持 Info.plist、Mach-O、签名材料静态提取、图标解码（含 Apple CgBI）。
- 文件哈希：MD5 / SHA-1 / SHA-256。
- 签名验证：Android（apksigner）、iOS（codesign，macOS 专属）。
- 加固线索检测：容器结构异常、DEX 头部、AXML 布局异常等。
- 报告导出：Markdown 格式分析报告。
