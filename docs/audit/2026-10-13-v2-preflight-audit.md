# AppInfoTool V2.0 — 第一步：仓库审计与基线核查（实测）

- **日期**：2026-10-13
- **方法**：本地逐文件实测（`find` / 源码逐行阅读 / `pubspec.lock` 结构解析）。**未修改任何生产代码。**
- **范围**：`lib/`（34 个 dart）、`packages/apk_parser/`（12 个 dart）、`test/`（3 个）、平台层、CI、依赖锁定
- **与既有报告的关系**：本文**独立复核** `docs/audit/2026-10-13-audit-report.md` 第八节「整改执行记录」的全部声明，不采信其结论，只采信可复现的证据。

---

## 0. 执行摘要

1. **前一份审计报告声称的 T0/T1 整改，绝大部分是真实落地的**，有源码与文件系统证据（见第 4 节）。这一点必须肯定。其中 **2 条为「部分完成」**：`pubspec.lock` 的 `ref` 未同步（5.1）、`InstallDialog` 的 `mounted` 守卫只补了 1/8 处（5.11）。另有 **1 条初判有误**（5.8，`freezed` 实际在使用），已更正。
2. **【最重要】仓库交付时根本无法编译。** 实测 `flutter analyze` 报 4 个 `error`、`flutter test` 编译失败（5.13）。其中 3 个错误是前次「已完成」整改（T0-2、T1-9）的**连带破损** —— 因为当时没有任何 SDK，这些改动从未被编译过一次。**已修复**（commit `f2af93b`）。
3. **【已修复】CI 的 `quality` 门禁此前从未成功跑通过**：`flutter pub get` 因 `intl` 死锁而版本求解失败（5.12），`dart format` 会重排 37/49 个文件。经确认采用「对齐当前 stable」路线修复。
4. **当前基线（已实证，门禁全绿）**：`flutter pub get --enforce-lockfile` ✅、`dart format --set-exit-if-changed .` ✅ 0 changed、`flutter analyze --fatal-infos --fatal-warnings` ✅ **No issues found!**、`flutter test` ✅ **23 passed**、包内 `dart analyze` ✅ **No issues found!**。
5. **环境与版本控制两个硬阻塞已解除**：Flutter 3.47.7 stable 已安装；`git init` 完成，基线快照 `97bef24`，修复拆为 5 个可审查提交。
6. **V2.0 的目标能力中，Android 加固 APK 分析约 40% 已有基础可复用；iOS IPA 分析为 0**（全仓库无任何 plist / Mach-O / mobileprovision / codesign 相关代码，见第 6 节）。
7. **尚未完成**：跨平台 `flutter build`（本机无完整 Xcode）、真实 IPA 与加固 APK 样本解析（无样本）。**第一步（审计 + 基线）至此收口，可进入第二步。**

---

## 1. 运行环境（关键阻塞）

| 检查项 | 实测结果 | 命令/证据 |
|---|---|---|
| `flutter` | **不存在** | `which flutter` → not found |
| `dart` | **不存在** | `which dart` → not found |
| `~/flutter`, `~/development/flutter`, `~/fvm`, `~/sdks/flutter`, `/opt/flutter`, `/usr/local/flutter`, `~/.puro` | **均不存在** | `for d in ...; [ -e "$d" ]` 无输出 |
| `fvm` / `puro` / `asdf` / `melos` | **均未安装** | `which` → none |
| Homebrew cask `flutter` | **未安装** | `brew list --cask \| grep flutter` → 无 |
| Spotlight 搜索 `$HOME` 下 `bin/flutter` | **无结果** | `mdfind` → 空 |
| Xcode | **仅 Command Line Tools**，无完整 Xcode | `xcodebuild -version` → requires Xcode |
| Java | **OpenJDK 17.0.14 (JBR)** 可用 | `java -version` |

**结论**：
- 静态分析、单元测试、格式化、跨平台构建**全部无法在本机执行**。
- 本机也**无法产出真实 IPA / 加固 APK 样本的解析结果**（无 SDK 无法运行应用）。
- 唯一可做的验证是「源码级证据」与「结构级证据」，不能替代 `flutter test` 的绿色结果。

**Git 状态**：`git status` → `fatal: not a git repository`。目录中无 `.git`。因此：
- 无「基线 commit」可比对；本报告采用「文件系统快照 + 内容证据」作为基线替代。
- 第二步起要求的「每阶段独立提交」，需先 `git init` 或恢复 `.git` 才能满足。

---

## 2. 仓库结构与文件清单（实测）

```
AppInfoTool/
├── pubspec.yaml                 # 应用 apk_info_tool，SDK >=3.0.6 <4.0.0
├── pubspec.lock                 # ⚠️ archive ref: HEAD（见 5.1）
├── analysis_options.yaml        # ⚠️ linter.rules 全部注释掉（见 5.2）
├── build.yaml                   # slang: input_directory=assets/i18n
├── .github/workflows/build.yml  # quality 门禁已存在（见 4.9）
├── assets/
│   ├── i18n/{en,ja,ko,zh-CN,zh-HK,zh-TW}.json
│   └── image/{icon.png,icon_512.png}
├── docs/{audit,plans}/*.md       # 3 篇
├── lib/                         # 34 个 dart（应用层）
│   ├── main.dart                # 入口、窗口、生命周期、路由
│   ├── config.dart              # SharedPreferences 配置（含 flushAll）
│   ├── apkparser/
│   │   ├── apk_info.dart        # ★ 解析编排中枢（1469 行）
│   │   ├── adaptive_icon_renderer.dart  # 自适应图标渲染（72KB）
│   │   └── xapk_info.dart       # XAPK manifest 模型/解析
│   ├── models/split_type.dart
│   ├── pages/{home,info,install,install_dialog,setting,text_info}.dart
│   ├── providers/{home_page,info_page,setting,ui_config}_provider.dart
│   ├── theme/theme_manager.dart
│   ├── utils/                   # 16 个：zip_guard/zip_helper/tool_downloader/
│   │                            #   xapk_installer/vector_to_svg/file_hash/...
│   └── widgets/{title_value_layout,title_width_setting}.dart
├── packages/apk_parser/         # 本地 package（纯 Dart，无 Flutter 依赖）
│   ├── pubspec.yaml             # ⚠️ 同上 archive ref 一致性
│   ├── pubspec.lock
│   ├── lib/apk_parser.dart      # barrel 导出
│   ├── lib/src/
│   │   ├── apk_reader.dart      # 统一入口 + ZIP bomb 预算
│   │   ├── binary_xml.dart      # AXML 反编译（872 行，已加固）
│   │   ├── manifest_parser.dart # ★ Manifest → ApkMeta（222 行）
│   │   ├── arsc_parser.dart     # resources.arsc（528 行，已加固）
│   │   ├── models.dart          # ApkMeta / ResourceInfo / ActivityInfo
│   │   ├── byte_data_reader.dart
│   │   └── arsc/{string_pool,resource_value,type_spec}.dart
│   └── bin/{parse.dart,compare.dart}
├── test/{utils_test,split_type_test,widget_test}.dart
├── linux/ macos/ windows/       # 平台层
└── （无 ios/ 目录，无 android/ 目录）
```

**关键事实**：
- **`lib/apkparser/binary_xml.dart` 与 `lib/utils/byte_data_reader.dart` 已不存在** —— 实测 `ls` 返回 No such file，双副本分叉（T0-4）确已消除。
- 全仓库**不存在** `Info.plist` / `plist` / `Mach-O` / `mobileprovision` / `codesign` / `entitlements` 的任何实现代码（已 grep 全量源码，仅命中审计文档文字）。**IPA 能力为 0**。
- `lib/gen/` 不存在、无任何 `*.g.dart`（被 `.gitignore` 排除），因此**必须先跑 `dart run build_runner build` 才能编译** —— 测试无法在裸克隆上直接运行。

---

## 3. 实际调用链（源码证据）

### 3.1 文件进入（5 条入口，全部只认 Android 格式）

| 入口 | 位置 |
|---|---|
| 拖放 | `info_page.dart:493` `DropTarget.onDragDone` → 后缀白名单（apk/xapk/apkm/apks/zip）→ `openApk` |
| 文件选择 | `info_page.dart:41` `openFilePicker`（`allowedExtensions` 同上）→ `openApk` |
| 命令行参数 | `main.dart:42` `apkByArgs` → `info_page.dart:231` |
| macOS 文件关联 | `info_page.dart:195` `MethodChannel('file_association')` → `openApk` |
| 二次打开（macOS） | `info_page.dart:211` `setMethodCallHandler('fileOpened')` |

**没有任何 `.ipa` 分支**。拖放与文件选择器的后缀白名单都需要为 IPA 扩展。

### 3.2 解析主链

```
openApk (info_page.dart:59)
  └─ loadApkInfo (info_page.dart:85)      ← 持有 _loadGeneration 代次令牌
       ├─ computeFileHashes(...)  并行（可选）
       ├─ getSignatureInfo(...)   并行（可选，仅非 XAPK）
       └─ getApkInfo (apk_info.dart:256)
            ├─ [.zip]  _detectZipContentType (130)
            ├─ [.xapk/.apkm/.apks 或含 apk 的 zip]  XAPK 分支 (279–439)
            │     ZipHelper.open → parseXapkManifest → 解出 base.apk 到临时目录
            │     → aapt2 dump badging → parseApkInfoFromOutput
            └─ [其他]
                 ├─ Config.parserEngine == builtin
                 │    → _getApkInfoBuiltin (501)
                 │        apk_parser.ApkReader.open → parse()
                 │        → _applyMetaToApkInfo (557) → _generateTextInfo (607)
                 │        → apkInfo.loadIcon()
                 └─ 否则 aapt2 dump badging (447–498)
```

### 3.3 图标链（已全部指向加固后的包内解析器）

```
loadIcon (apk_info.dart:1239)
  └─ collectIconCandidates (1036)
       └─ AdaptiveIconRenderer（adaptive_icon_renderer.dart）
            ├─ preloadResourceTableFromArsc(arscResources)  ← builtin 路径，无需 aapt2
            └─ VectorToSvg.convert / convertAdaptiveIconData（utils/vector_to_svg.dart）
```

### 3.4 签名链

```
getSignatureInfo (apk_info.dart:685)
  └─ CommandTools.findApkSignerPath()
       └─ Process.run(apksigner, ['verify','--print-certs','--verbose', apkPath])
            timeout 120s；exitCode != 0 → throw
```

**现状缺口**：工具缺失时**直接 throw**，UI 显示 `signature_verify_failed: <异常>`；未区分「验证失败 / 工具不可用 / 结果未知」；不读取 `META-INF` 作为兜底（符合约束 4.3 方向，但状态建模缺失）。

### 3.5 状态管理

- Riverpod 3 + `riverpod_generator`（代码生成）+ `riverpod_annotation`。
- Provider：`currentApkInfoProvider` / `currentFileStateProvider` / `isParsingProvider` / `selectedIconIndexProvider` / `selectedLabelLocaleProvider`（均在 `providers/info_page_provider.dart`）。
- `FileState` 为**手写类**（非 freezed），`copyWith` 用 `??` 实现 → **无法置空字段**；且**无 `==`/`hashCode`**（T2-8 未修）。
- 代次令牌 `_loadGeneration`（`info_page.dart:39,86,167,184`）已存在并正确使用 → 快速切换文件不会串数据（T1-5 已修）。

---

## 4. 历史整改核验（逐条实测）

| 编号 | 报告声称 | 实测结论 | 证据 |
|---|---|---|---|
| T0-1 | 新增 `ZipGuard.safeJoin`，XAPK/工具解包统一走校验 | ✅ **真实** | `lib/utils/zip_guard.dart:34-61` 拒绝 `..`/绝对路径/盘符/UNC/`~`；`zip_helper.dart:78`、`xapk_installer`、`tool_downloader` 均调用 |
| T0-2 | 官方源优先 + 解包前校验 checksum | ✅ **真实** | `tool_downloader.dart:102-113` 官方 `repositoryIndexUrl` 居首、镜像兜底；`_parseChecksums`(473)、`_verifyArchiveChecksum`(565)、`_digestFile`(547) 优先 SHA-256 回退 SHA-1 |
| T0-3 | `arsc_parser` / `binary_xml` 无界分配加界校验 | ✅ **真实** | `arsc_parser.dart:394,428` `if (entryCount > reader.remain ~/ 4) return;`；`string_pool.dart:40-45`；`binary_xml.dart:705-710` `numStrings > dataSize ~/ 4 \|\| > 1<<20` 则返回空 |
| T0-4 | 删除两份 `lib/` 副本，图标链改指 package | ✅ **真实** | `ls lib/apkparser/binary_xml.dart` → No such file；`ls lib/utils/byte_data_reader.dart` → No such file |
| T0-5 | ZIP bomb 三重预算 | ✅ **真实**（**但有重复实现**，见 5.3） | `zip_guard.dart:16-28,66-97`；`zip_helper.dart:20`；`apk_reader.dart:19-42` |
| T1-1 | 两处 pubspec 固定同一 SHA，lockfile 同步 | ⚠️ **部分** | pubspec 两处均为 `cb3a07c8…`；**但 lockfile 仍为 `ref: HEAD`** → 见 5.1 |
| T1-2 | 新增 `utils_test` / `split_type_test`，替换模板测试 | ✅ **真实**（内容正确） | `test/utils_test.dart` 覆盖 formatFileSize 边界与 ZipGuard 穿越/盘符/UNC；`test/split_type_test.dart` 覆盖回归项 |
| T1-3 | CI 加 quality 闸门 + PR 触发 | ✅ **真实** | `.github/workflows/build.yml:15-43` quality job（format→analyze→test→包 analyze），三个 build job `needs: quality`，`pull_request` 已加，`--enforce-lockfile` 已加 |
| T1-4 | `info_page` 补 `dispose()` 反注册 MethodChannel | ✅ **真实** | `info_page.dart:857-860` |
| T1-5 | 引入 `_loadGeneration` 代次令牌 | ✅ **真实** | `info_page.dart:39,86,113,137,167,184` |
| T1-6 | `InstallDialog` 补 `dispose()` + `mounted` 守卫 | ⚠️ **部分** | `dispose()` 真实存在且正确（`install_dialog.dart:310-315` 置 `_isCancelled` 并 kill 进程/取消安装器）；**但 `mounted` 守卫只加在 `_installApk` 的 `finally` 一处（:268）**，其余 await 后的 `setState` 全部无守卫 → 见 5.11 |
| T1-7 | `ConfigItem.flush()` + `flushAll()` + 生命周期落盘 | ✅ **真实** | `config.dart:58-62,148-156`；`main.dart:58-64` `AppLifecycleListener` |
| T1-8 | entitlements 补 `network.client`、移除 `network.server` | ✅ **真实** | 两份 entitlements 均含 `network.client`，无 `network.server` |
| T1-9 | `compare.dart` 失败时 `exit(1)` | ✅ **真实** | `bin/compare.dart` 已改 |
| 逻辑 bug | `formatFileSize` / `SplitType.fromId` / `trimSQ` | ✅ **真实** | `format.dart:20-25` 进位修正；`split_type.dart:11-38` 正则重写；`apk_info.dart:729-735` `trimSQ` 用 `RegExp(r"[^']")` |

**核验小结**：前次整改整体是**诚实的**，无「声称已改但实际未改」的情况。两处为**部分完成**：T1-1 的「lockfile 同步」（见 5.1）、T1-6 的「mounted 守卫」（见 5.11）。

---

## 5. 风险清单

### 5.1 【新增·高】`pubspec.lock` 与 `pubspec.yaml` 的 `archive` ref 不一致

实测两个 lockfile 的 `archive` 块：

```yaml
  archive:
    dependency: "direct main"
    description:
      path: "."
      ref: HEAD                                          # ← pubspec 里是 cb3a07c8…
      resolved-ref: cb3a07c80d6a475ef8d36e5642bc2691612d074e
      url: "https://github.com/huanfeng/archive.git"
    source: git
    version: "4.0.9"
```

`pubspec.yaml` 声明 `ref: cb3a07c80d6a475ef8d36e5642bc2691612d074e`，而 lockfile 记录 `ref: HEAD`。二者不一致。

**影响**：CI 中新增的 `flutter pub get --enforce-lockfile`（`build.yml:27,81,141,203`）在 pubspec 声明与 lockfile 记录不符时**会失败**，即 T1-3 新增的质量门禁自身可能红在第一行。**更根本的是**：`resolved-ref` 只是「上次解析到的提交」，若 pubspec 仍被 pub 视为 `HEAD`，任何 `pub upgrade` 都会静默拉到当日 HEAD —— 而这正是 T1-1 想消除的风险。

**必须验证**：`flutter pub get --enforce-lockfile` 是否真的失败。**本机无 SDK，无法验证 → 标记为「待验证」。**

**修复方向**：执行一次普通的 `flutter pub get` 重新生成两个 lockfile，确认 `ref:` 字段变为 SHA。

> **✅ 已实证（2026-10-13，SDK 就绪后）**：执行 `flutter pub get` 后，`pubspec.lock` 的
> `archive.ref` 已由 `HEAD` 刷新为 `cb3a07c80d6a475ef8d36e5642bc2691612d074e`，
> 与 pubspec 声明一致。随后 `flutter pub get --enforce-lockfile` **返回 exit 0**。
> 结论：该缺陷**确实存在过**，且**已通过重新解析依赖修复**。

### 5.2 【中】lint 规则仍全部注释掉

`analysis_options.yaml:23-26` 的 `linter.rules` 全是注释，`analyzer.plugins: [custom_lint]` 虽配置但无规则启用 → `riverpod_lint` 空转。T2-9 未修。

### 5.3 【中】ZIP bomb 预算存在两份重复实现

`lib/utils/zip_guard.dart:66-97` 与 `packages/apk_parser/lib/src/apk_reader.dart:19-42` 各自实现了一份**逻辑等价但常量重复**的 bomb 检查（`_maxTotalUncompressed` 等）。约束 3「不复制现有解析器」的精神同样适用于安全防护：两份会漂移。且 `ApkReader` 在 `packages/` 内无法反向依赖 `lib/utils/zip_guard.dart` —— 需把预算逻辑下沉到 `packages/apk_parser`，由应用层复用。

### 5.4 【中】`ApkReader` 与 `ZipHelper` 的 bomb 判定**返回值语义不一致**

- `ZipHelper.open` 命中 bomb → 抛异常被 `catch` 吞掉 → 返回 `false`。
- `ApkReader.open` 命中 bomb → 返回 `false`。
- 调用方（`getApkInfo`）无法区分「不是 ZIP」「ZIP 损坏」「ZIP 炸弹」三种原因，只能统一报「解析失败」。与 V2.0 第 4.2 节「明确区分 5 种状态」直接冲突。

### 5.5 【中】签名状态未建模

`getSignatureInfo` 在工具缺失时 `throw`，UI 归入「验证失败」。V2.0 第 4.3 节要求区分「通过 / 失败 / 工具不可用 / 未知」四态，当前 0 态建模。

### 5.6 【中】解析仍在 UI isolate 上同步执行

`_getApkInfoBuiltin`（`apk_info.dart:501`）在 `Future.delayed(Duration.zero)` 后同步跑 ZIP 解压 + 完整 `resources.arsc` 遍历。项目已有 `Isolate.run` 用法（`utils/file_hash.dart`），模式现成。V2.0 第 7 节要求「真实分析进度 + 取消按钮」，同步阻塞会让进度与取消都不可实现。

### 5.7 【中】无取消机制

全链路无 `CancellationToken`。V2.0 第 5.1、7 节要求「支持取消操作」+「解析取消后不留孤儿进程或临时文件」。当前 aapt2 路径只有 120s 超时看门狗，builtin 路径无超时无取消。

### 5.8 【已更正·非问题】`freezed` 实际在使用

**初判有误，特此更正**：初次静态审计时因仓库内不存在 `*.freezed.dart`（被 `.gitignore` 排除）而误判「freezed 声明未使用」。
运行 `dart run build_runner build` 后实际产出：

```
lib/providers/setting_provider.freezed.dart
lib/providers/ui_config_provider.freezed.dart
```

即 `freezed` 用于 `setting_provider` 与 `ui_config_provider` 的状态类。**依赖声明是必要的，不应移除。**

### 5.9 【低】`FileState` 无法置空字段且无值语义

`info_page_provider.dart:76-96`：`copyWith` 用 `??`，无法把 `md5Hash` 等置回 `null`；无 `==`/`hashCode` → 无变化也触发 `ref.watch` 重建。T2-8 未修。

### 5.10 【低】`assets/image/icon_512.png` 未在 pubspec 声明

`pubspec.yaml:57-58` 只声明 `assets/image/icon.png`，但 README 引用了 `icon_512.png`。不影响运行（README 图片），但属资产清单不一致。

### 5.11 【中】`InstallDialog` 的 `mounted` 守卫只补了一处

`install_dialog.dart` 的 `dispose()` 已正确实现（:310-315），但 **`mounted` 守卫仅存在于 `_installApk` 的 `finally`（:268）**。以下 await 之后的 `setState` 全部无守卫：

| 位置 | 场景 |
|---|---|
| `_loadDevices` :132, :138 | `Process.run(adb devices)` 期间用户关闭对话框 → `setState` on disposed |
| `_loadSplitApks` :150 | `getSplitApks` 期间关闭 |
| `_showStopConfirmDialog` :300 | 确认弹窗期间关闭 |
| `_installApk` 循环 :189, :237, :244, :255, :261 | `dispose()` 置 `_isCancelled` 后，循环内 `setState` 仍会执行 |

前次报告称「21 处 `setState`、0 处 `mounted` 守卫」已修复，实测**仅修复 1 处**。T1-6 应重开为**部分完成**。

### 5.12 【高·已实证】CI 的 `quality` 门禁此前从未成功执行过，两个步骤都会红

SDK 就绪后实测，T1-3 新增的 `quality` job 的**前两个步骤都会失败**：

**① `flutter pub get` 解析失败**（`build.yml:27`）

```
Because apk_info_tool depends on flutter_localizations from sdk
which depends on intl ^0.20.3, intl ^0.20.3 is required.
So, because apk_info_tool depends on intl 0.20.2, version solving failed.
```

项目把 `intl` 死锁在 `0.20.2`，而 Flutter 3.47.7（当前 stable）的 `flutter_localizations` 要求 `^0.20.3`。
经实测各版本 `flutter_localizations/pubspec.yaml`：

| Flutter | `intl` 约束 |
|---|---|
| 3.35.0 / 3.38.0 / 3.41.0 / 3.44.0 | `0.20.2` |
| 3.47.7（当前 stable） | `^0.20.3` |

即该 pin 在 3.44 → 3.47 之间被 SDK 演进打破。**CI 用 `channel: stable`，因此必然失败。**

**② `dart format --set-exit-if-changed .` 必然失败**（`build.yml:31`）

```
Formatted 49 files (37 changed) in 0.14 seconds.
```

Dart 3.7+ 引入新格式化器，本仓库代码仍是旧格式。**37/49 个文件会被重排。**

**结论**：`quality` 门禁自加入起就**没有被真正跑通过**（这与前次报告第八节「待验证（阻塞）：本机无 Flutter/Dart SDK」自述一致 —— 门禁是照计划写好但从未执行）。因此三个 `build-*` job 的 `needs: quality` 也会被连带阻断。

**处置**：经确认采用「对齐当前 stable」路线 —— `intl: 0.20.2 → ^0.20.3`，并落盘一次 `dart format`。作为**独立的「环境对齐」提交**，与 V2.0 改动严格分离。

### 5.13 【最高·已实证·已修复】仓库交付时不编译 —— 4 个编译错误

这是本次审计**最重要**的发现，且**前次审计不可能发现**（无 SDK，只做了静态阅读）。`flutter analyze` 报 4 个 `error`：

| # | 位置 | 错误 | 根因 |
|---|---|---|---|
| 1 | `lib/pages/setting_page.dart:938` | `non_exhaustive_switch_statement` | **T0-2 的连带遗漏**：`tool_downloader.dart` 新增了 `ToolDownloadError.checksumMismatch`，但 `setting_page.dart` 的 `switch (e.code)` 未同步补 case |
| 2 | `lib/pages/setting_page.dart:1118` | `undefined_method` | 调用了不存在的 `openDirectoryInExplorer`（`lib/utils/platform.dart` 里只有 `openFileInExplorer`） |
| 3 | `packages/apk_parser/bin/compare.dart:223` | `undefined_identifier` `failCount` | **T1-9 的误粘贴**：`exit(1)` 块被复制到 `_parseAapt2Output` 的 `return result;` **之后**，成为引用未定义变量的死代码 |
| 4 | `packages/apk_parser/bin/compare.dart:223` | `undefined_identifier` `skipCount` | 同上 |

**要点**：错误 1、3、4 全部是**前次「已完成」整改的连带破损**。T0-2 与 T1-9 在报告中被标记为已完成，但两者都把仓库改成了无法编译的状态 —— 因为当时没有任何 SDK 能编译一次。`main()` 第 150-152 行本身已有**正确**的 `exit(1)`，`compare.dart` 里那份纯属重复粘贴。

**修复**（commit `f2af93b`）：
- 补 `case ToolDownloadError.checksumMismatch:`，并在 6 个语言文件新增 i18n key `settings.download_error_checksum`（校验和不匹配是安全相关的拒绝路径，必须让用户看到真实原因，不能退化为「未知错误」）。
- 在 `lib/utils/platform.dart` 新增 `openDirectoryInExplorer`：语义是**打开目录本身**，与 `openFileInExplorer`（定位到条目、macOS 用 `open -R`）区分。路径以参数数组传入，不经 shell 拼接（符合约束 9）。
- 删除 `compare.dart` 中的重复死代码块。

### 5.14 【高·已实证·已修复】`test/widget_test.dart` 必然失败

前次用于替换模板测试的冒烟测试直接 `pumpWidget(const MyApp())`，但 `MyApp` 是 `ConsumerWidget`，`build` 中 `ref.watch(themeManagerProvider)`，且调用 `TranslationProvider.of(context)`。缺少 `ProviderScope` 与 `TranslationProvider` 两个祖先 → 恒抛：

```
Bad state: No ProviderScope found
```

即 T1-2「替换无法通过的模板测试」实际是**换成了另一个必然失败的测试**。修复：按 `main()` 的装配方式包一层（commit `f2af93b`），测试随即通过。

### 5.15 【中·已实证·已修复】CI 的 analyze 门禁曾是红的：0 error，但 9 warning + 91 info

修复编译错误后，`flutter analyze` 为 **0 error / 9 warning / 91 info**。CI 用的是
`flutter analyze --fatal-infos --fatal-warnings`，因此**仍然 exit 1**。`packages/apk_parser` 同理（82 issue，0 error）。

9 个 warning **全部是真实缺陷**（非噪声）：

| 位置 | 问题 |
|---|---|
| `analysis_options.yaml:37` | `custom_lint` 旧式插件机制已废弃 |
| `lib/apkparser/xapk_info.dart:2` | 未使用的 `import 'dart:io'` |
| `lib/apkparser/xapk_info.dart:116` | `invalid_null_aware_operator`（短路后不可能为 null） |
| `lib/main.dart:79` | `_appLifecycleListener` 只写不读 |
| `lib/pages/install_page.dart:4` | 未使用的 import |
| `lib/pages/setting_page.dart:757` | 未使用字段 `_isCustomDirSelected` |
| `lib/utils/zip_helper.dart:11` | 未使用字段 `_filePath`（T0-1 重构残留） |
| `lib/utils/zip_helper.dart:36` | 多余 cast |
| `lib/utils/zip_helper.dart:55` | 未使用的 `_safeJoin` 包装（T0-1 重构残留） |

91 个 info 的构成：`avoid_print` 60（全部在 `bin/` 下的 CLI 脚本）、`constant_identifier_names` 14（`resource_value.dart` 里对齐 Android `Res_value` 的规范常量名）、`deprecated_member_use` 6（`withOpacity`）、`prefer_conditional_assignment` 4，其余零散。

**处置**：经确认采用「修真实缺陷 + 定向豁免误报」路线，**已全部完成**（commit `3194b26`）。

**修掉的真实缺陷（12 处）**：

| 位置 | 问题 | 修法 |
|---|---|---|
| `lib/main.dart` | `_appLifecycleListener` 只写不读 | 删除该顶层变量。**同时纠正了错误注释**：`AppLifecycleListener` 构造函数内即 `WidgetsBinding.instance.addObserver(this)`，而 `WidgetsBinding.instance` 是进程级单例，早已强引用持有，不需要额外变量防 GC |
| `lib/pages/setting_page.dart` | `_isCustomDirSelected` 只写不读（6 处赋值、0 处读取） | 删除字段与全部 6 处赋值 |
| `lib/utils/zip_helper.dart` | `_filePath` 未使用字段 | 删除字段及其读写 |
| `lib/utils/zip_helper.dart` | `_safeJoin` 未使用包装（T0-1 重构残留） | 删除 |
| `lib/utils/zip_helper.dart` | 多余 cast | `file?.content as Uint8List?` → `file?.content`（archive fork 的 `content` 本就是非空 `Uint8List`） |
| `lib/apkparser/xapk_info.dart` | 未使用 `dart:io` | 删除 import |
| `lib/apkparser/xapk_info.dart` | `invalid_null_aware_operator` | `.toString()?.trim()` → `.toString().trim()` |
| `lib/pages/install_page.dart` | 未使用 import | 删除 |
| `lib/utils/logger.dart` | 顶层函数缺返回类型 | `initLogger()` → `Future<void> initLogger()` |
| `lib/config.dart`、`lib/theme/theme_manager.dart` | `Color.value` 已废弃 | 改用 `toARGB32()`（等值 int，**不影响已持久化的主题色**） |
| `lib/pages/setting_page.dart` | `withOpacity` 已废弃 | 改用 `withValues(alpha: 0.2)` |
| `packages/apk_parser/.../manifest_parser.dart`、`apk_parser.dart`、`bin/compare.dart` | 4× `prefer_conditional_assignment`、`unnecessary_library_name`、3× 单插值字符串 | 分别改用 `??=`、删除 `library` 名、去掉多余插值 |

**定向豁免（规则误报，非降标准，均带注释说明理由）**：

| 范围 | 规则 | 理由 |
|---|---|---|
| `packages/apk_parser/bin/{compare,parse}.dart` | `avoid_print` | 开发者命令行工具，stdout 就是它的接口 |
| `packages/apk_parser/lib/src/arsc/resource_value.dart` | `constant_identifier_names` | 常量名刻意对齐 Android `Res_value` 规范命名，以便与 AOSP 逐项对照 |

**顺带查实的一处死配置**：`analysis_options.yaml` 里的 `analyzer.plugins: [custom_lint]` ——
`custom_lint` **根本不在依赖图里**（`riverpod_lint` 3.1.0 已迁移到 `analysis_server_plugin`）。
该配置既不生效、又持续产生 `analysis_options_deprecated_plugins` 告警。已改用新体系的顶层
`plugins: riverpod_lint: ^3.1.0`；新体系下插件 lint 规则**默认关闭**，故不引入新诊断。

---

## 6. V2.0 需求 vs 现状 差距矩阵

### 6.1 Android 加固 APK 分析（第二/四步）

| 需求（原文小节） | 现状 | 差距 |
|---|---|---|
| 应用名/包名/版本名/版本号 | ✅ `ApkMeta` + `_applyMetaToApkInfo` | 无 |
| 图标 + 图标解析状态 | ✅ 已有完整链路 | 需补「解析状态」字段 |
| min/target/**max**SdkVersion | min/target ✅；**max ❌** | `maxSdkVersion` 属性名已在 `binary_xml.dart:82` 映射表，但 `manifest_parser.dart` 未消费 |
| 权限 | ✅ `meta.permissions` | 无 |
| **Activity/Service/Receiver/Provider** | ❌ **仅 launchable activity** | `manifest_parser.dart:107-124` 只收集含 MAIN+LAUNCHER 的 activity；service/receiver/provider 完全未解析 |
| **组件 exported 属性** | ❌ | 属性名 `exported` 已在映射表（`binary_xml.dart:53`），未被消费 |
| APK 大小 / SHA-256 / ZIP 目录 | 大小 ✅、MD5/SHA-1 ✅、**SHA-256 ❌**、ZIP 目录部分（`listFiles`） | 需补 SHA-256 与结构化目录树 |
| DEX 数量 / SO / ABI / 资源目录 | ABI ✅（`_scanNativeCodes`）；**DEX 数 ❌**；SO 明细 ❌ | 需新增 |
| 签名方案/证书/指纹/验证结果 | 仅 `apksigner --print-certs` 原始 stdout，**无结构化、无状态、无方案区分** | 需重做签名层 |
| 分层可回退策略 + 字段来源 | ❌ 无「字段级来源/状态」模型 | 需新建 `PackageAnalysisResult` |
| 加固线索（不臆断厂商） | ❌ | 需新增启发式 + 可解释输出 |

**可复用率估算**：AXML/ARSC/ZIP/图标/ABI 约 60% 可直接复用；组件解析、签名建模、状态模型、加固线索为新增。

### 6.2 iOS IPA 分析（第三/五步）

| 需求 | 现状 |
|---|---|
| IPA 容器解析（多 App / PlugIns / Watch） | **0** |
| XML plist + 二进制 plist 解析 | **0**（依赖 `xml` 包可解析 XML plist；bplist00 需自实现） |
| CFBundle* 字段 | **0** |
| IPA 图标 | **0** |
| Mach-O 解析（架构/Fat/Load Commands/dylib） | **0** |
| `_CodeSignature` / `embedded.mobileprovision` / Entitlements | **0** |
| macOS `codesign` 集成 | **0** |

**结论：IPA 为完全从零实现**，且约束 6 要求「基础元数据尽量跨平台纯 Dart」，即 plist + Mach-O 解析器都要自己写（`archive` 可用于 ZIP 层）。

---

## 7. 修改计划（文件级，按实施顺序）

> 每一阶段独立提交。因当前无 `.git`，**第 0 阶段必须先恢复版本控制**。

### 阶段 0：前置条件（阻塞，需用户决策）
- 安装 Flutter SDK（stable），执行 `flutter pub get` + `build_runner` + `analyze` + `test`，产出**真实基线**。
- `git init`（或恢复 `.git`）并提交当前快照作为基线 commit。

### 阶段 1：修复高优先级问题
1. **`pubspec.lock` ref 一致性**（5.1）：重生成两个 lockfile，验证 `--enforce-lockfile` 通过。
2. **ZIP 预算去重**（5.3）：把预算常量与 `isBomb` 下沉到 `packages/apk_parser`，`lib/utils/zip_guard.dart` 改为薄封装。
3. **解析失败原因可区分**（5.4）：为 `ApkReader.open` / `ZipHelper.open` 引入结果枚举（`notZip` / `corrupt` / `bomb` / `ok`），贯穿到 UI 诊断。
4. **`InstallDialog` 补齐 `mounted` 守卫**（5.11）：`_loadDevices` / `_loadSplitApks` / `_showStopConfirmDialog` / `_installApk` 循环内共 8 处。
5. **`analysis_options.yaml` 启用 lint**（5.2）+ `riverpod_lint`。

### 阶段 2：统一数据模型（第四步）
- 新增 `packages/apk_parser/lib/src/analysis/`（或应用层 `lib/models/`）：
  - `PackageAnalysisResult`（platform / fileName / fileSize / sha256 / appName / packageId / version / buildNumber / signatureStatus / diagnostics）
  - `FieldValue<T>`（值 + 解析状态 + 来源 + 诊断）
  - `AndroidPackageInfo`（权限 / 组件 / SDK / DEX / SO / 签名）
  - `IosPackageInfo`（plist 字段 / 图标 / Mach-O / Entitlements）
- **不把 Android 权限与 iOS Entitlements 合并为同一类型**（约束 6）。

### 阶段 3：Android 组件与签名增强
- `manifest_parser.dart`：新增 service / receiver / provider 解析，消费 `exported` 属性；新增 `maxSdkVersion`。
- 新增 `packages/apk_parser/lib/src/manifest_components.dart`。
- 签名层重写：`lib/utils/signature_analyzer.dart`，四态建模 + 退出码/stdout/stderr 保留。

### 阶段 4：IPA 解析引擎（第五步，从零）
- `packages/ipa_parser/`（新 package，与 Android 解耦）：
  - `src/ipa_reader.dart`（安全 ZIP + Payload 定位 + 多 App 枚举）
  - `src/plist/{xml_plist.dart, binary_plist.dart}`（bplist00 自实现）
  - `src/macho_parser.dart`（Fat/Thin、架构、Load Commands、dylib，含边界检查）
  - `src/icon_resolver.dart`
  - `src/signature_materials.dart`（`_CodeSignature` / `embedded.mobileprovision` 静态分析；macOS 上可选 `codesign`）
- 复用 `packages/apk_parser` 的 `ByteDataReader` 与 ZIP 预算逻辑（避免第三份副本）。

### 阶段 5：UI 增量
- `info_page.dart`：后缀白名单加 `.ipa`；平台标识；新增区块（组件 / 签名 / 文件结构 / 诊断 / Entitlements）。
- 复用现有 `TitleValueLayout` 卡片结构，**不重写首页/导航/主题**。

### 阶段 6：测试与门禁
- 单测：格式识别、plist（XML/binary）、Mach-O、字段合并、损坏/随机输入。
- 安全测试：ZIP 穿越、炸弹预算、恶意长度、取消后无孤儿、切换文件不串数据。
- CI：`quality` job 扩展（含新 package 的 analyze/test）。

---

## 8. 基线验证结果（真实执行）

环境已按用户决策搭建完毕：**Flutter 3.47.7 stable / Dart 3.13.5 / DevTools 2.60.0**
（Framework revision `abaf9c5237`，2026-10-08），安装于 `~/development/flutter`。

> **注意**：`flutter test` 在本机需要绕过环境代理，否则 `flutter_tester` 的本地
> WebSocket 会被 `HTTP_PROXY=http://127.0.0.1:51252` 劫持，报
> `Invalid WebSocket upgrade request`。执行前须设
> `NO_PROXY=127.0.0.1,localhost,::1`。

### 8.1 首次基线（修复前）— **仓库无法编译**

| 检查项 | 结果 | 证据 |
|---|---|---|
| `flutter pub get` | ❌ **失败** | `intl 0.20.2` 与 `flutter_localizations` 的 `^0.20.3` 冲突，版本求解失败 |
| `dart run build_runner build` | ✅ exit 0 | 写出 10 个产物（slang 7 + riverpod 4 + freezed 2） |
| `dart format --set-exit-if-changed .` | ❌ **失败** | `Formatted 49 files (37 changed)` |
| `flutter analyze` | ❌ **4 error** / 10 warning / 91 info | 见 5.13 |
| `flutter test` | ❌ **编译失败** | `setting_page.dart` 两处 error 导致无法编译 |
| `packages/apk_parser` `dart analyze` | ❌ 82 issue（0 error） | 60 `avoid_print` + 14 `constant_identifier_names` + 4 + 3 + 1 |
| `flutter build {windows,macos,linux}` | **未执行** | 本机仅 Command Line Tools，无完整 Xcode；且上面已失败，构建无意义 |
| 真实 IPA / 加固 APK 样本解析 | **未执行** | 无样本 |

### 8.2 修复后基线 — **可编译、可测试、门禁全绿**

| 检查项 | 结果 |
|---|---|
| `flutter pub get --enforce-lockfile` | ✅ **exit 0** |
| `dart run build_runner build --delete-conflicting-outputs` | ✅ exit 0 |
| `dart format --set-exit-if-changed .` | ✅ **`Formatted 62 files (0 changed)`** |
| `flutter analyze --fatal-infos --fatal-warnings` | ✅ **exit 0 · `No issues found!`** |
| `flutter test` | ✅ **`+23: All tests passed!`** |
| `packages/apk_parser` `dart analyze --fatal-infos --fatal-warnings` | ✅ **exit 0 · `No issues found!`** |
| 源码级审计 | ✅ 见第 2–6 节，含文件路径与行号证据 |
| 依赖锁定一致性核查 | ✅ 发现 5.1，已修复并验证（**两个 lockfile 的 `archive.ref` 均已固定为 SHA**） |
| 历史整改核验 | ✅ 见第 4 节，13/15 条为真、2 条部分为真、1 条初判有误（5.8） |
| `flutter build {windows,macos,linux}` | ❌ **未执行**（本机仅 Command Line Tools，无完整 Xcode；Linux/Windows 构建需对应平台） |
| 真实 IPA / 加固 APK 样本解析 | ❌ **未执行**（无样本，属交付要求 7 的遗留项） |

### 8.3 本次修复的提交

| commit | 内容 |
|---|---|
| `97bef24` | `chore:` 基线快照（审计时的原始状态） |
| `54ac313` | `style:` 全仓库 `dart format`（纯格式，无行为变更） |
| `f2af93b` | `fix:` 恢复可编译可测试基线（4 个编译错误 + 测试修复 + 环境对齐） |
| `c55eadf` | `docs:` 本审计报告 |
| `70d975b` | `docs:` 记录真实基线与 3 条新发现 |
| `3194b26` | `chore:` 让 CI 质量门禁转绿（修 12 处真实缺陷 + 2 类定向豁免 + 迁移分析器插件配置） |

**按约束 10 与交付要求 5**：8.1/8.2 中标记为 ❌ 或「未执行」的项一律不得计为通过。

---

## 9. 阻塞项与需决策事项（更新于基线验证之后）

### 已解除

1. ~~**【阻塞】无 Flutter/Dart SDK**~~ → 已安装 Flutter 3.47.7 stable 于 `~/development/flutter`，基线已真实跑出（第 8 节）。
2. ~~**【阻塞】非 Git 仓库**~~ → 已 `git init`，基线快照 `97bef24`，并按「格式 / 功能 / 文档」拆成 3 个可审查提交。

### 已解除（续）

3. ~~**【需决策】CI 的 `analyze` 门禁严格度**~~ → 经确认采用「修真实缺陷 + 定向豁免误报」路线，已实施完成（commit `3194b26`）。`flutter analyze --fatal-infos --fatal-warnings` 与包内 `dart analyze --fatal-infos --fatal-warnings` 现均为 **exit 0 · No issues found!**。详见 5.15。

### 待决策

4. **【需决策】`archive` fork 仍是个人仓库**（`github.com/huanfeng/archive.git`，前次报告已列为遗留）：已固定到 SHA `cb3a07c8…`，风险可控，但长期建议改为 vendored 本地依赖或上游发布版本。

5. **【需决策】无真实测试样本**。交付要求 7（真实 IPA 与不同加固 APK 的解析情况）需要样本文件。仓库内无任何 `.apk` / `.xapk` / `.ipa` fixture，`bin/compare.dart` 的差分语料仍为空 —— 这也是 T1-2 补强的遗留项。

### 其他遗留（非阻塞）

6. 5.3 ZIP 预算双份实现、5.4 解析失败原因不可区分、5.5 签名状态未建模、5.6 解析阻塞 UI isolate、5.7 无取消机制、5.9 `FileState` 值语义缺失、5.11 `InstallDialog` 守卫不全 —— 均待第 1 阶段处理。
7. `.workbuddy-ai/memory/` 已被纳入版本控制（随基线快照一起提交）。若不需要，可在 `.gitignore` 中排除。
