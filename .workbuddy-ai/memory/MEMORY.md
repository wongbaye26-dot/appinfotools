# AppInfoTool — 项目长期约定

> 详细逐日记录见同目录的 `YYYY-MM-DD.md`。本文件只放跨会话仍然有效的事实与约定。

## 仓库结构（V2.0 起）

根包 `apk_info_tool`（Flutter 桌面应用）+ 四个本地 package：

| 包 | 职责 | 依赖 |
|---|---|---|
| `packages/archive_safety` | 不可信 ZIP 的通用安全原语：`ZipBudget`、`ArchiveOpenResult`、`looksLikeZip`、`readArchiveHeader`、`looksStructurallyBroken` | archive |
| `packages/analysis_model` | 平台中立的「值 + 状态 + 来源 + 诊断」：`FieldValue<T>` / `FieldStatus` / `FieldSource` / `AnalysisDiagnostic` | **零依赖** |
| `packages/apk_parser` | 纯 Dart Android 解析：AXML、`resources.arsc`、组件、加固线索、容器结构 | archive, archive_safety |
| `packages/ipa_parser` | 纯 Dart iOS 解析：plist（XML + bplist00）、IPA 容器、Info.plist 字段、图标、Mach-O、签名材料**静态**提取（`_CodeSignature` / `embedded.mobileprovision` 的 CMS 载荷） | archive, archive_safety, analysis_model, xml |

应用层（`lib/`）：
- `lib/ipaparser/` —— IPA 解析编排。`ipa_analysis.dart`（纯函数流水线）、
  `ipa_parse_task.dart`（worker isolate）、`ios_codesign_step.dart`（**主 isolate**）。
- `lib/utils/ipa_bundle_extractor.dart` / `ios_codesign_analyzer.dart` —— 解包与 codesign。
- **解包 / codesign 不能放进 worker**：`Isolate.immediate` 不保证执行 `finally`，
  在里面写临时文件会留下垃圾。

**Android 与 iOS 解析器互不依赖**，只共享 `archive_safety` 与 `analysis_model`。
不要把某一侧的格式模型放进共享包，也不要让一侧依赖另一侧。

## 环境

- Flutter 3.47.7 stable / Dart 3.13.5，装在 `~/development/flutter`。
  需要 `export PATH="$HOME/development/flutter/bin:$PATH"`。
- **`flutter test` 必须设 `NO_PROXY=127.0.0.1,localhost,::1`**，否则环境代理会劫持
  `flutter_tester` 的本地 WebSocket。
- 本 shell 是 zsh：`$VAR` 不做分词；`grep` 的 `\|` 交替不可靠（用 `-E` 或 Grep 工具）。
- `lib/gen/` 与 `*.g.dart` / `*.freezed.dart` 被 gitignore，编译前必须先跑 build_runner。

## 质量门禁（与 CI 一致）

```
flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')
flutter analyze --fatal-infos --fatal-warnings
flutter test
# 逐包：for pkg in packages/*/; do (cd $pkg && dart analyze --fatal-infos --fatal-warnings); done
```

- 格式检查**必须用 `$(git ls-files -co --exclude-standard '*.dart')`**，不能是 `.`：
  生成物的格式化风格与 SDK 的 `dart format` 不一致（构造器初始化列表缩进、`=>` 换行），
  扫全树会永远失败。
- 用 `-co` 而不是只有 `-c`：**新增但还没 `git add` 的文件同样要被检查**。
  只用 `-c` 会漏掉它们，本地跑门禁通过、CI 才报错（实际踩到过三次）。
- 各 package 有**自己的** `analysis_options.yaml`（`include: package:lints/recommended.yaml`）
  + `lints` 依赖。不能靠继承根配置 —— 根配置的 `flutter_lints` 在子包上下文里解析不到，
  会导致逐包 analyze 完全没有 lint 规则。

## 测试约定

- 测试放在**根 `test/`** 目录（根包依赖了各 path package，因此能 import 它们）。
- **优先用真实产物做样本，不用手工拼的字节**：手工样本会带着与解析器相同的错误假设，
  等于自证。已有做法：
  - 二进制 plist / Info.plist：macOS `plutil -convert binary1` 生成，内嵌 base64，
    并与等价 XML 交叉比对
  - Mach-O：clang 编译真实 dylib，放 `test/fixtures/macho/`（含 README 记录编译命令），
    期望值取自 `otool`
  - PNG：用仓库内真实的 `assets/image/icon.png`
- **畸形/对抗性样本**才手工构造（没有工具能生成自引用 plist、越界偏移等），
  而它们断言的是「必须被拒绝」。
- 写测试后**做反向验证**：把修复去掉，确认测试真的会红。这一步抓到过多个空断言。
- **UI 测试要把 `APKInfoPage` 放进 `Scaffold`**（真实树是 `HomePage` 的 Scaffold）：
  直接当 `MaterialApp.home` 时，环境 `DefaultTextStyle` 是 `WidgetsApp` 的
  `_errorTextStyle`（monospace + 下划线 + w900），页面会以错误的字体渲染。
- **能渲染就渲染出来看**：把详情页用 `RepaintBoundary.toImage` 落成 PNG
  （加载系统字体 `/System/Library/Fonts/Supplemental/Arial Unicode.ttf` 与
  `Monaco.ttf`）比逐行读代码有效得多 —— 「容器」卡片上的 `Closure: ...` 和
  分组标题的色块都是这样发现的，读代码和断言都看不出来。

## UI 约定

- **两页（APK / IPA）用同一套版式**：`Card` + `TitleValueLayout`、同一套卡片顺序、
  同样的复制按钮与设置开关。区分靠**最前面那一行平台标识**（`Platform =
  Android / iOS` + `Icons.android` / `Icons.apple`），而不是把两页做成两种样子 ——
  两页字段名大量重叠（「版本名」在 Android 是 `versionName`、在 iOS 是
  `CFBundleShortVersionString`）。测试断言「每张卡片都是 Card + TitleValueLayout」，
  出现自定义壳就说明又分叉了。
- **`SelectableText` 的 `maxLines` 是高度预留，也是裁剪**，两件事都要当心：
  - 只给 `maxLines` 不给 `minLines` 时，一行内容也按 `maxLines` 行高排版
    （实测 `maxLines: 6` 的单行卡片 136px，补 `minLines: 1` 后 39px）。
    `TitleValueLayout` 因此把 `minLines` 默认成 1，并夹紧到 `maxLines` 以内
    （设置页允许把上限调到 0，写死的 1 会触发 `assert(minLines <= maxLines)`）。
  - 超过 `maxLines` 的行**根本不会被绘制**，不是溢出滚动。安全相关的长文本
    （签名、容器清单、诊断）一律不设上限。
- **不靠环境 `DefaultTextStyle` 继承字体**：没有 `Material`/`Card` 祖先的组件
  继承到的是 `WidgetsApp` 的报错样式。样式一律以 `theme.textTheme.*` 为基底
  `copyWith`。
- 平台视觉区分**不能只靠颜色**：主题色可被用户改，色觉障碍也存在。
  颜色只是强化，结构差异才是主力。
- 分组标题与卡片标题**不得同名**（四种语言里都得检查），否则界面上是两行
  一模一样的字。
- **能渲染就渲染出来看**：把页面用 `RepaintBoundary.toImage` 落成 PNG
  （加载系统字体 `/System/Library/Fonts/Supplemental/Arial Unicode.ttf`）比逐行
  读代码有效得多 —— 「容器」卡片上的 `Closure: ...`、分组标题的色块、图标有没有
  真的画出来，都是这样发现的。

## iOS 图标：Apple 的 CgBI（"PNG crush"）

Xcode 打包时会把 bundle 里的**彩色** PNG 换成 CgBI 变体，Flutter 的解码器读不了。
判定与变换**不要照抄博客，用 Apple 自己的工具当基准**：

```sh
PNGCRUSH=/Applications/Xcode.app/Contents/Developer/usr/bin/pngcrush   # Xcode 自带
$PNGCRUSH -iphone -q plain.png cgbi.png
$PNGCRUSH -revert-iphone-optimizations -q cgbi.png revert.png          # 基准
sips -s format png cgbi.png --out ref.png                              # 另一个基准
```

- 形态：签名后紧跟 `CgBI` 块、`IDAT` 是**裸 deflate**（无 zlib 头、无 adler32）、
  像素是 **BGRA 且 RGB 已按 alpha 预乘**；
- 布局是 `ch0=B, ch1=G, ch2=R, ch3=A`；反预乘用**整数截断** `v * 255 ~/ a`
  （16 个半透明样本 16/16 一致；四舍五入只有 12/16）；
- `pngcrush -iphone` 对灰度（0）与灰度+alpha（4）**不做**变换 → CgBI 只以
  **8 位 RGBA、非隔行**出现，其余形态应如实拒绝而不是猜着解；
- **预乘是有损的**：`A=0` 的颜色回不来。应用图标基本不透明，所以结果是精确的；
  别把半透明的情况说成「精确还原」；
- `archive` 的 `Inflate` 不读 zlib 头也不校验 adler32（正好是裸 deflate），
  `Deflate` 输出裸流，`ZLibEncoder` 才加头；
- **造 CgBI 夹具必须把直通 RGBA 编成 BGRA+预乘再写盘**，否则造出来的东西
  根本不是 CgBI；
- 读 PNG 尺寸**不能写死 `IHDR` 在偏移 12**，要走块链（CgBI 的 IHDR 前面还有
  一个块）；块必须四个部分齐全（长度 + 类型 + 数据 + CRC）。

## 解析安全约定

- 任何来自文件的长度/偏移**先验边界再使用**（bplist00、Mach-O 都如此）。
- 递归要有深度上限与环检测（二进制 plist 的引用可成环）。
- 解析**尽量不抛异常**：畸形部分停下来记诊断，保留已读到的数据。
- 字段缺失的语义必须区分：`absent`（文件里没有）/ `wrongType`（类型不符）/
  `failed`（读不出来）/ `unsupported`（该来源不提供）/ `hardenedUnknown`（可能被加固）/
  `notRequested`（本次没算）。
- **不得用虚构数据补空**；取不到就如实记录状态与原因。
- 外部命令一律用参数数组，绝不经 shell 拼接。
- **签名验证只交给受信任工具**（Android 用 `apksigner`，iOS 用 `codesign`），
  且只以工具的明确结论为准；`codesign -d` 这类「显示」子命令的输出**只是描述性
  信息**，不能当结论（实测它对签名已损坏的 bundle 照样退出 0）。
- 退出码 0 **还要求输出具备该工具特有的形态**，否则任何返回 0 的程序都会被读成
  「验证通过」。宁可报「无法确认」，也绝不凭空报「签名有效」。
- 「工具不可用」永远不等于「签名无效」：前者显示「无法确认」。
- **静态提取与验证必须分开**：本项目不自行实现签名算法。
- **`absent` 与其余状态在 UI 上必须渲染不同**：`absent` 是「文件里没有」，
  渲染成「-」；`failed` / `wrongType` 是「我们没读到」，必须带上状态名与原因。
  把后者渲染成空串等于把「读不到」说成「没有」。
- 新增 i18n 键后**必须重新生成**：`dart run slang`（或 `dart run build_runner build`），
  否则生成代码里没有该 getter。ja / ko 走 `fallback_strategy: base_locale` 回退，
  只改 en + zh-CN / zh-HK / zh-TW 即可。
- **带 `{占位符}` 的键是方法，不是 getter**。漏传实参不会编译报错，但会把函数
  对象插进字符串（界面上出现 `Closure: ...`）。`test/i18n_placeholder_usage_test.dart`
  扫源码兜住这一类，分析器看不见。

## 已知局限（写进代码，不粉饰）

- 归档层预算只统计**声明尺寸**；ZIP 头部少报尺寸时无法阻止分配，
  只能在读完后复核并拒绝解析。
- `Future.timeout` 不会终止子进程；签名路径已改用 `Process.start` + 显式 kill，
  但 kill 只及直接子进程（apksigner 是启动 java 的脚本，孙进程可能短暂存活）。
- aapt2 / XAPK 路径仍走 `Process.run`，未接入 worker isolate，**不可取消**。
- 跨平台 `flutter build` 未验证（本机无完整 Xcode）。
- 真实样本（加固 APK + 签名 IPA）的解析与界面端到端**已跑通**，但样本不进版本库，
  需设 `APPINFOTOOL_SAMPLES=/tmp/samples`；未设置时整体显式跳过。
  尚未执行的是**交互**部分：拖放、取消解析、导出报告。
- Android 侧没有任何 `AnalysisDiagnostic` 产出者，「解析诊断」卡片恒为空。
- `Assets.car` 里的图标不提取：那是 CoreUI 的 BOMStore，图像载荷是 **LZFSE**
  压缩（`bvx2` 块），需要 LZFSE 解码器。bundle 里直接存在的 `AppIcon*.png`
  已经能解（含 CgBI），`Assets.car` 的情况继续如实说明「取不到」。
- 未执行的**交互**路径：拖放、取消解析、导出报告。
- 沙箱不允许枚举进程（`ps` 报 `Operation not permitted`），
  「超时后无残留子进程」的断言在本机未真正执行。
- ZIP 里的符号链接被当作普通文件写出（不建链接，避免逃逸），
  因此依赖符号链接的 bundle 用 `codesign` 验证可能失败 —— 结果里会给出计数。
