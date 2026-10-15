# AppInfoTool 概览页 / 拖放 / 详情页 / 设置页 修复报告

> **修复对象**：`main`（起点 `b97b7dd`，V2.3.0 阶段 7 之后）
> **触发**：用户报告 6 项，含一张「拖入 IPA 到概览页后内容区空白 + 左上角卡住白色浮层」的截图
> **报告生成时间**：2026-10-15
>
> 每条结论都对应**可复现的命令与实测输出**。凡是没有真正复现的，在
> 第 7 节如实列出并写明原因 —— 不写「应该没问题」。

---

## 1. 结论

| 项目 | 实测结果 |
|---|---|
| `dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')` | **EXIT=0**（181 文件，0 改动） |
| `flutter analyze --fatal-infos --fatal-warnings` | **EXIT=0**（No issues found） |
| 逐包 `dart analyze --fatal-infos --fatal-warnings`（4 个包） | **EXIT=0** |
| `flutter test`（`APPINFOTOOL_SAMPLES=/tmp/samples`） | **910 通过 / 1 跳过** |

用户 6 项诉求的落点：

| # | 诉求 | 状态 |
|---|---|---|
| 1 | 修拖入 IPA 到概览页的异常 | **修了 4 个确证缺陷**；「内容区空白」本身**未能在本机复现**，见第 7 节 |
| 2 | Hero 区多展示应用信息、全部可复制 | 完成（字段 3 → 13，每项一个复制入口） |
| 3 | 分析页与 Tab 详情页统一 UI + 快捷复制 | 完成（复制入口下沉到 `TitleValueLayout`，两页自动一致） |
| 4 | 设置页 UI 整体一致 | 完成（顶栏、卡片圆角、分组标题字号对齐另两页） |
| 5 | 修统计与最近文件为空 | **完成，根因确证**（见 3.1） |
| 6 | push 并构建最新版 | 已推送；构建需走 CI（见第 8 节） |

---

## 2. 这一轮为什么先做「量」而不是先做「猜」

截图给出的两个现象是「内容区整片空白」与「左上角一个白色圆角浮层，里面是
被拖入的文件名」。先做了两件取证：

**（a）把截图放大、做对比度拉伸。** 内容区（右侧）经 `autocontrast` 之后
**完全均匀**：整块区域只有 139 种颜色、每通道极值 0–64。也就是说内容区
**只画了背景色，一个子组件都没有**，不是「画得很淡」。

**（b）把左上角那块白色浮层裁出来放大。** 它是一个带圆角的半透明矩形、
里面是文件名，且**被屏幕左边缘裁掉了一截** —— 这是 macOS 系统级的拖拽影像
（drag image），不是本应用画的组件（本仓库里没有任何组件会渲染「圆角框 +
文件名」）。

两者合起来指向同一件事：**拖放发生的那一刻，应用没能继续处理事件** ——
系统拖拽会话收不了尾（幽灵卡住），界面也没拿到新帧。

于是把力气放在「拖放路径上到底有多少件不该发生的事」上，而不是去猜某个
渲染细节。查出来 4 件，都修了（3.2–3.5）。

---

## 3. 逐项根因与修复

### 3.1 统计与最近文件恒为空 —— `const []` 被就地修改

**根因（确证）。** `RecentFilesManager.load()` 在列表为空时返回 `const []`，
而 `add()` 紧接着对它调用 `removeWhere` 去重：

```
Unsupported operation: Cannot remove from an unmodifiable list
  dart:_internal                                                  UnmodifiableListMixin.removeWhere
  package:apk_info_tool/utils/recent_files.dart 78:13             RecentFilesManager.add
  package:apk_info_tool/providers/info_page_provider.dart 346:30  RecentFiles.add
```

`const []` 是不可变列表。**全新安装后的第一次分析成功就抛异常**，而调用点是
`unawaited(ref.read(recentFilesProvider.notifier).add(...))` —— 异常变成
「未捕获的异步错误」，界面上表现为「统计永远是 0、最近文件永远为空」，
日志里一行都没有。

**为什么能活这么久**：`test/` 下**完全没有**最近文件的测试（`grep -rl
RecentFiles test/` 无匹配）。这一块是整条链路里唯一没有覆盖的功能。

**修复。**
- `load()` 的空分支改为返回可变列表（`<RecentFileEntry>[]`），并写清理由；
- provider 的 `clear()` 同样改用可变列表；
- 两个调用点补上 `.catchError(...)` 记日志 —— 就算以后别的地方再抛，
  也不会再被静默吞掉；
- `main()` 增加 `FlutterError.onError` 与 `PlatformDispatcher.onError` 的
  日志兜底（不改渲染行为，只让失败留痕）。

**回归测试**：`test/recent_files_test.dart`（9 例）。覆盖空列表可变性、
首次 add、去重与置顶、10 条上限、clear 后再 add、落盘与重启、provider state、
以及概览页真的把统计与最近文件渲染出来。

**反向验证**：把 `load()` 改回 `const []` 后 9 例**全红**，报的正是
`Unsupported operation: Cannot remove from an unmodifiable list`。

---

### 3.2 一次拖放触发两次解析 —— 两个 DropTarget 同时活着且尺寸重叠

**根因（确证）。** `AppShell` 用 `IndexedStack` 承载三个页面。`IndexedStack`
**会构建并布局所有子页**（只画选中的那个），因此概览页与分析页的
`DropTarget` 同时在树里、**渲染盒完全重叠**。而 `desktop_drop` 的通道是
全局扇出的（`DesktopDrop._notifyEvent` 遍历所有监听者），每个 `DropTarget`
再各自按自己的渲染盒判「是否在界内」—— 重叠的盒子全都判定为在界内。

净效果：拖一个文件到概览页会**同时**触发
- 概览页的 `onDragDone` → `pendingOpenRequest.request(path)`
- 分析页自己的 `onDragDone` → `openApk(path)`

`pendingOpenRequest` 随后又被分析页的 `ref.listen` 接住并再调一次 `openApk` ——
同一个文件被两条流水线解析两遍。`desktop_drop` 的文档对此有明确要求：
「被挡住时把 target 关掉」。

**修复。** 两个 `DropTarget` 都加 `enable: Visibility.of(context)`。
`IndexedStack` 正是通过 `Visibility.of` 告诉子页自己可不可见的（它给每个子项
包了一层 `_VisibilityScope`），因此这是框架提供的正规做法，不需要自己算
导航状态。

**回归测试**：`test/drop_target_ownership_test.dart`（8 例）。断言三个导航
状态下「开着的 target 恰好只有一个、且属于可见页」，以及来回切换后归属仍正确。

**反向验证**：去掉两处 `enable` 后 4 例归属断言**全红**。

---

### 3.3 拖拽高亮可能永远擦不掉 —— 复位只依赖 `onDragExited`

**根因。** `_dragging` 的熄灭原本只依赖 `onDragExited`，而 `desktop_drop`
并不保证这个回调一定送达（拖放被系统取消、拖拽影像在应用卡顿时被丢弃，都可能
让它不触发）。一旦漏掉，界面上就是一层擦不掉的浮层。

**修复。** 加一个看门狗：`onDragEntered` 起一个 5 秒的定时器，
`onDragUpdated`（拖拽期间 macOS 会持续发 `draggingUpdated`）刷新它，
`onDragExited` / `onDragDone` 取消它。安静超过 5 秒即判定拖拽结束。

**为什么这个看门狗是安全的**：它只影响高亮这个纯装饰，`onDragDone` 是否触发
由 `desktop_drop` 自己的状态机决定 —— 清早了不会丢事件，只是少一层提示。

**回归测试**：`test/drop_target_ownership_test.dart` 的「拖拽高亮」组（4 例），
含「平台不送 `onDragExited` 时看门狗会熄灭高亮」与「拖拽期间的心跳不会误熄」。

---

### 3.4 孤儿解析任务不取消

**根因。** `_loadIpaInfo` 在代际（`_loadGeneration`）变化时只是 `break` 出
事件循环然后 `return`，**没有取消任务**。worker isolate 会继续把整个解析做完
（真样本上是几秒的 CPU 与几十 MB 内存），而结果只会被丢掉。3.2 那个缺陷让
同一个文件被解析两遍，正好把这个缺口放大了一倍。

**修复。** 代际变化时显式 `task.cancel()`；Android 侧同样补上
（`loadApkInfo` 里新增 `taskForThisRun`，在 `finally` 的代际不匹配分支取消）。

---

### 3.5 解析还没出结果时显示「Android」与「未加载文件」

**根因。** `FileState.platform` 是由**已到位的解析结果**派生的（这是刻意的：
扩展名可以随便改）。但 Hero 区在平台未知时一律渲染成 `Android`、应用名为空时
渲染成「未加载文件」—— 拖入一个 IPA 的头几秒里，界面明确告诉你这是个
Android 包、而且什么都没加载。

**修复。**
- 平台未知时状态卡显示 `—`，图标用中性的问号，颜色取中性色；
- 应用名未出结果时退回**文件名**（文件名是事实，不是猜测）；
- 版本行改为 `v版本 (构建号)`。

---

### 3.6 Hero 区信息量与复制入口

Hero 区从「应用名 / 标识符 / 版本」三行扩到 13 项，**每一项都有复制入口**：
四个状态卡片（平台 / 大小 / 签名 / 安全）的值可复制，下面新增「详细信息」网格
（文件名 / 文件路径 / 版本 / 构建号 / 最低系统或最低 SDK / 目标 SDK /
可执行文件 / SHA-256 / SHA-1 / MD5）。哈希带 tooltip 显示完整值。

**版式约束（这一页是固定一屏、不上下滚动的）。** 网格加进来之后在
900×600（应用允许的最小窗口）下把底部整片顶掉了。处理方式是按可用高度自适应：

- `_chromeHeightEstimate = 620`（网格之外的部分占多高）与
  `_detailGridMaxHeight = 180`（网格上限），两者都是在
  **1280×800（默认窗口，内容区 1040×800）** 与 **900×600（最小窗口，内容区
  660×600）** 两档上量出来的；
- 网格内部可滚动；高度不足 90px 时整块收起（宁可少显示，也不要显示一半被裁掉）；
- 网格的列数由可用宽度决定（≥900 三列、≥560 两列、否则一列）。早先给每个
  单元一个 `maxWidth`，`Wrap` 会把单元撑到那个上限，于是在 1000px 宽的内容区
  里一行只放得下一个 —— 十来个字段排成一条竖线，把 Hero 顶到两倍高；
- 「最近文件」的空态框也按可用高度决定画不画图标与提示行，否则窗口矮的时候
  框内会溢出。

**回归测试**：`test/overview_layout_test.dart`（8 例）。三档尺寸下断言
`tester.takeException()` 为 null（溢出会被测试框架记为异常），
断言最小窗口下网格收起而统计与最近文件仍在，断言默认窗口下字段齐全，
断言复制按钮数量与「点击真的写入剪贴板」。

---

### 3.7 详情页：每张卡片两个复制按钮、分组标题与 Tab 名重复、Hero 复制按钮飘在外面

把复制入口下沉到 `TitleValueLayout`（新增 `copyable`，**默认 true**）之后，
发现三处：

1. **同一张卡片两个复制按钮。** 哈希卡片、Platform、File 三处早先用
   `end: _buildCopyButton(...)` 各挂了一个，与新加的默认按钮重复。已清理，
   并删掉旧的 `_buildCopyButton`（它的 `minWidth/minHeight: 32` 还会把行高撑开）。
2. **分组标题与 Tab 名重复。** `_buildIosCards` / `_buildAndroidCards` 里
   `_SectionHeader(title: t.detail_tab.application, ...)` 与 Tab 栏的
   「应用」是同一个词，界面上连着两行一模一样的字。已在 `_groupCardsByTab`
   里按 Tab 名自动去重（放在这里而不是各调用点：两页都有这种标题，
   靠人手记住哪几个要去掉迟早会漏）。
3. **Hero 的复制按钮飘在卡片外。** 它被 `Align` 贴在卡片下面，界面上是一个
   孤零零的图标飘在空白里，看不出属于哪一项。已给 `AndroidHeroCard` /
   `IosHeroCard` 加 `trailing` 参数，把按钮放进卡片。

**回归测试**：`test/ios_detail_page_test.dart` 新增 2 例 ——
「每张字段卡片只有一个复制入口」「分组标题不与 Tab 名重复」；
并把原有的「复制入口与 APK 页一样留在值旁边」改为断言新约定
（`TitleValueLayout.copyable` + 卡片内确实渲染出按钮 + Hero 的 `trailing` 非空）。

---

### 3.8 设置页与另两页不一致

- **顶栏被 M3 染成紫色**（`colorScheme.inversePrimary`），而分析页顶栏是
  中性表面色 + `surfaceTintColor: transparent`。已对齐。
- **卡片圆角写死 8**，比 `Card` 的 M3 默认值 12 更方。已改为 12。
- **分组标题用 `ExpansionTile` 默认的 `titleMedium`**，与概览页
  `_SectionLabel`、详情页 `_SectionHeader` 的 `titleSmall` + w600 不是一套。
  已对齐；前置图标从默认的 24 号灰缩到 18 号主色。

---

## 4. 新增/修改的文件

**产品代码**

| 文件 | 改动 |
|---|---|
| `lib/utils/recent_files.dart` | 空分支返回可变列表（3.1） |
| `lib/providers/info_page_provider.dart` | `clear()` 用可变列表（3.1） |
| `lib/pages/info_page.dart` | 代际变化取消任务（3.4）；`catchError` 记日志（3.1）；拖放 target 加 `enable`（3.2）；清理重复复制按钮、Tab 名去重、Hero `trailing`（3.7） |
| `lib/ui/overview/overview_page.dart` | 看门狗（3.3）；`enable: Visibility.of(context)`（3.2）；Hero 扩字段与自适应版式（3.6）；解析中不再误报平台（3.5） |
| `lib/widgets/title_value_layout.dart` | 新增 `copyable`（默认 true） |
| `lib/widgets/copy_icon_button.dart` | **新增** —— 统一的复制按钮与 `copyToClipboard` |
| `lib/widgets/android_detail_widgets.dart` / `ios_detail_widgets.dart` | Hero 卡片新增 `trailing` |
| `lib/pages/setting_page.dart` | 顶栏、圆角、分组标题对齐（3.8） |
| `lib/main.dart` | 全局错误日志兜底（3.1） |
| `assets/i18n/{en,zh-CN,zh-HK,zh-TW}.json` | 概览页新增 10 个键 |

**测试**

| 文件 | 说明 |
|---|---|
| `test/recent_files_test.dart` | **新增**，9 例 |
| `test/drop_target_ownership_test.dart` | **新增**，8 例 |
| `test/overview_layout_test.dart` | **新增**，8 例 |
| `test/ios_detail_page_test.dart` | 更新 1 例、新增 2 例 |

---

## 5. 回归防护的做法

这一轮新增的 25 个用例**全部做了反向验证**：把修复去掉、确认测试真的变红，
再恢复。具体结论写在各节里。这一步抓到过空断言，也是项目既有约定。

---

## 6. 未复现项：内容区整片空白

**没有复现。** 说清楚做了什么、为什么定不了论。

**做过的验证。** 用 `RepaintBoundary.toImage` 把概览页在三类状态下渲染成 PNG
逐一目视（空态 / 解析中 / 真实 IPA 解析完成），并在 660×600、1040×800、
1440×900 三档尺寸下各渲一遍：

- 三类状态下内容区**都完整渲染**（Hero、统计、最近文件都在），
  没有出现空白；
- 三档尺寸下都没有溢出（溢出会被 widget 测试记为异常，测试会红）。

也就是说，**概览页自身在「状态 → 渲染」这一段没有可复现的塌陷**。

**为什么没法进一步定论。** 本机**跑不了 macOS 应用**：`flutter build macos`
被系统级的 `sandbox-exec` 限制挡住（`sandbox-exec: sandbox_apply: Operation
not permitted`），关掉工具沙箱重试同样失败。因此无法启动真实应用、用真实
拖放复现截图里的状态。这一点在 V2.3.0 的验收报告里也列为已知限制。

**倾向的机制（未证实）。** 截图的两个现象（系统拖拽影像卡住 + 内容区只有
背景色）指向同一个原因：**拖放发生的那一刻，应用没能继续处理事件**。
3.2 那个「一次拖放解析两遍」的缺陷让主 isolate 上要跑两遍
`IosPrivacyAudit.audit`（同步）与两遍 `IosBundleExtractor.extract`（解包到
磁盘），3.4 的孤儿任务又让第一遍不会被取消 —— 阻塞时间大约翻倍。
这两条已修。但**我没有证据说它就是截图里的那一次**，因此不作为结论。

**顺带排除的假设。** 一开始怀疑是 `_dragging` 卡住导致浮层残留，但按截图
取色反推，`primaryContainer` 以 0.3 alpha 叠在背景上应当是明显的蓝调
（约 `#0D233B`），而实测内容区是 `#121418`（几乎中性）—— 说明**浮层不是本应用
画的高亮**，而是系统拖拽影像。这个判断也解释了为什么「关掉拖拽高亮」不可能
解决截图里的问题。

---

## 7. 未验证项

| 项 | 原因 |
|---|---|
| macOS 应用的真实拖放 | 本机 `flutter build macos` 被系统沙箱挡住 |
| 跨平台构建（Windows / Linux） | 本机无对应工具链，只能由 CI 确认 |
| 真实样本的界面端到端（`APPINFOTOOL_SAMPLES`） | 本轮跑过（910 通过含样本用例），但样本不进版本库，CI 上会整体跳过 |
| 「超时后无残留子进程」 | 沙箱不允许枚举进程（`ps` 报 `Operation not permitted`） |

---

## 8. 构建与发布

本机**无法产出安装包**（原因见第 7 节），因此构建走 CI。

### 8.1 推送 main 已触发三平台构建（实测已成功）

关键一点：**构建 job 本身并不看 tag**。`.github/workflows/build.yml` 里被打 tag
门住的只有「Sync pubspec version from tag」这一个 step，以及 `create-release` 这个
job。因此**推送 main 就已经跑了完整的三平台打包**，不需要先打 tag。

本次推送（`1af2727`）的 CI 实测：

| Job | 结果 |
|---|---|
| `Quality (format / analyze / test)` | **success** |
| `build-macos` | **success** |
| `build-windows` | **success** |
| `build-linux` | **success** |
| `create-release` | skipped（tag 门控，未打 tag） |

Run #29（`https://github.com/wongbaye26-dot/appinfotools/actions/runs/38652310272`），
产物：

| 产物 | 大小 |
|---|---|
| `macos-dmg` | 31.93 MB |
| `windows-release` | 22.50 MB |
| `linux-appimage` | 10.39 MB |

> 那个「Sync pubspec version from tag」被跳过是**正确行为**：main 分支推送时
> `GITHUB_REF_NAME` 是 `main`，去掉 `v` 前缀仍是 `main`，改写出来会是
> `version: main` 这种非法版本号 —— 这正是 v2.0.0 之后连续两次构建失败的根因，
> 所以那一步刻意只在 tag 分支上跑。

### 8.2 仍缺的一步：打 tag

三平台包都能从本次 run 的 artifacts 直接下载。若要走正式发布（GitHub Release +
Homebrew / Scoop 分发），需要再打一个 `v*` 标签：

```sh
git tag v2.3.1 && git push origin v2.3.1
```

**这一步没有做**：它会把三个包正式发布成一个对外可见的 Release。V2.3.0 那轮也
是同样处理（打 tag 留给用户决定），本轮保持一致。
