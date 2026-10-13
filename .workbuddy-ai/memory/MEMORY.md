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

## 已知局限（写进代码，不粉饰）

- 归档层预算只统计**声明尺寸**；ZIP 头部少报尺寸时无法阻止分配，
  只能在读完后复核并拒绝解析。
- `Future.timeout` 不会终止子进程；签名路径已改用 `Process.start` + 显式 kill，
  但 kill 只及直接子进程（apksigner 是启动 java 的脚本，孙进程可能短暂存活）。
- aapt2 / XAPK 路径仍走 `Process.run`，未接入 worker isolate，**不可取消**。
- 跨平台 `flutter build` 未验证（本机无完整 Xcode）。
- 无真实 APK/IPA 样本，交付要求 7 未能产出。
- 沙箱不允许枚举进程（`ps` 报 `Operation not permitted`），
  「超时后无残留子进程」的断言在本机未真正执行。
- ZIP 里的符号链接被当作普通文件写出（不建链接，避免逃逸），
  因此依赖符号链接的 bundle 用 `codesign` 验证可能失败 —— 结果里会给出计数。
