# AppInfoTool V2.0 交付报告

> 生成时间：2026-10-13  
> 基线快照：`97bef24`（V2.0 开工前的仓库状态）  
> 本次交付：64 个提交，相对基线新增 87 个文件、修改 52 个文件

本报告只写**实测到的**结果。凡未执行的项目一律标注「未执行」，不用推测或静态  
分析的结果冒充已验证结论。

---

## 1. 环境与门禁现状

| 项目                                               | 实测结果                                                         |
| ------------------------------------------------ | ------------------------------------------------------------ |
| Flutter                                          | 3.47.7 stable（`~/development/flutter`）                       |
| Dart                                             | 3.13.5                                                       |
| 平台                                               | macOS，仅 Command Line Tools（**无完整 Xcode**）                    |
| `flutter pub get --enforce-lockfile`             | 通过                                                           |
| `dart run build_runner build`                    | 通过（slang / freezed / riverpod_generator）                     |
| 格式检查                                             | **0 处待改**（`dart format --output=none --set-exit-if-changed`） |
| `flutter analyze --fatal-infos --fatal-warnings` | **No issues found!**                                         |
| 逐包 `dart analyze`（4 个子包）                         | **全部 No issues found!**                                      |
| `flutter test`                                   | **479 通过 / 10 明确跳过 / 0 失败**                                  |
| 测试文件数                                            | 32                                                           |
| `flutter build bundle`（编译整个程序，无需平台工具链）          | **通过** —— 产出 `kernel_blob.bin`（77 MB）与 `AssetManifest.bin`      |
| 跨平台 `flutter build macos` / `windows` / `linux`    | **未执行**（本机无完整 Xcode，实测报错见 1.1）                              |

10 条跳过项都写明了原因，不是「悄悄没跑」：

1. `ios_codesign_step_test`：`codesign 不可用时不解包` —— 只能在非 macOS 上构造。
2. `real_samples_test` 的 APK 组与 IPA 组：未设置 `APPINFOTOOL_SAMPLES` 时跳过；  
   本次交付**已设置并执行**（见第 7 节）。
3. `real_samples_ui_test` 的 7 条界面用例：同上，**已设置并执行**。

### 1.1 构建验证到哪一步为止

```
$ flutter build macos --debug
Xcode not installed; this is necessary for iOS and macOS development.
```

**这是实测输出，不是推测。** 本机 `xcode-select -p` 指向
`/Library/Developer/CommandLineTools`，`xcodebuild` 因此不可用。

能做到的替代验证是 `flutter build bundle`：它从 `main.dart` 出发编译**整个程序**
并解析资产清单，不需要 Xcode / Android SDK。它补上了一个真实缺口 ——
`flutter test` 只编译测试引用到的代码，一个从未被测试实例化的页面组件在测试里
完全不会被编译，而 `build bundle` 会。

它**不等于**跨平台构建验证：产出可执行文件仍需要对应平台的工具链。这一步已加入
CI，见 `.github/workflows/build.yml` 的 `Compile the whole app` 步骤。

---

## 2. 修改文件清单与用途

### 2.1 新增的本地 package（4 个）

| 包                         | 用途                                                                                                                                            |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `packages/archive_safety` | 不可信 ZIP 的通用安全原语：`ZipBudget`（解压预算）、`ArchiveOpenResult`（打开结果的五态）、`looksLikeZip`、`looksStructurallyBroken`。APK 与 IPA 解析器都依赖它，**不必互相依赖、也不必各写一份**。 |
| `packages/analysis_model` | 平台中立的「值 + 状态 + 来源 + 诊断」模型：`FieldValue<T>`、`FieldStatus`（7 态）、`FieldSource`、`AnalysisDiagnostic`、`SignatureStatus`。**零依赖**。                    |
| `packages/apk_parser`     | 纯 Dart Android 解析：AXML、`resources.arsc`、组件、加固线索、容器结构。                                                                                         |
| `packages/ipa_parser`     | 纯 Dart iOS 解析：plist（XML + `bplist00`）、IPA 容器、Info.plist 字段、图标、Mach-O、CMS 载荷、签名材料。                                                             |

### 2.2 应用层新增文件

| 文件                                                 | 用途                                                        |
| -------------------------------------------------- | --------------------------------------------------------- |
| `lib/apkparser/parse_task.dart`                    | APK 解析的 worker isolate，真阶段进度 + 真取消。                       |
| `lib/apkparser/aapt2_task.dart`                    | `aapt2` 子进程任务，**可取消**、超时**真的终止进程**。                       |
| `lib/apkparser/analysis_builder.dart`              | 逐字段合并各来源，保留来源标注；iOS 侧的组装。                                 |
| `lib/ipaparser/ipa_analysis.dart`                  | IPA 静态解析流水线（容器 → Info.plist → 图标 → Mach-O → 签名材料 → 授权比对）。 |
| `lib/ipaparser/ipa_parse_task.dart`                | IPA 解析的 worker isolate。                                   |
| `lib/ipaparser/ios_codesign_step.dart`             | 解包 + `codesign` 验证（跑在主 isolate，保证临时目录一定被清理）。              |
| `lib/utils/cancellable_task.dart`                  | 统一的「可取消任务」接口，让「显示取消按钮」与「取消真的有效」是同一件事。                     |
| `lib/utils/signature_analyzer.dart`                | Android 签名验证（`apksigner`）。                                |
| `lib/utils/ios_codesign_analyzer.dart`             | iOS 签名验证（`codesign`）。                                     |
| `lib/utils/ipa_bundle_extractor.dart`              | 有界解包：先算后写、逐条路径校验、可取消、保证清理。                                |
| `lib/utils/ios_icon_decoder.dart`                  | iOS 图标解码，解码前做像素预算。                                        |
| `lib/utils/detail_renderer.dart`                   | 详情页的纯文本渲染（可单测，不依赖 widget 树）。                              |
| `lib/utils/analysis_report.dart`                   | 导出解析报告（Markdown，纯函数）。                                     |
| `lib/models/analysis/package_analysis_result.dart` | 统一分析结果模型。                                                 |
| `lib/models/analysis/hardening.dart`               | 加固线索与置信度。                                                 |
| `lib/widgets/ios_icon_preview.dart`                | iOS 图标预览。                                                 |

### 2.3 测试与样本

- 新增测试文件 20 个、新增样本文件 7 个；`test/` 下的测试文件共 **30** 个，  
  测试用例总数从 40 增至 **469**。
- 新增样本：
  - `test/fixtures/macho/` —— clang 编出的真实 dylib（thin arm64 / fat x86_64+arm64），期望值取自 `otool`。
  - `test/fixtures/ipa/embedded.mobileprovision` —— macOS `security cms` 生成的**真实 CMS**，期望值取自 `security cms -D`。
  - `test/fixtures/apk/hardened-manifest.axml` —— 从真实加固 APK 提取的 36240 字节 AXML，期望值取自**独立写的 Python 解码器**。
  - `assets/image/icon.png` —— 仓库内真实 PNG。
- `test/real_samples_test.dart` —— 用 `APPINFOTOOL_SAMPLES` 指向样本目录即可跑真实端到端解析。

---

## 3. 新增 / 增强的 APK 能力

### 3.1 基本信息（规范 4.1）

| 能力                                                                | 状态                                                             |
| ----------------------------------------------------------------- | -------------------------------------------------------------- |
| 应用名、包名、版本号、版本码                                                    | 已有，本次补上真实加固样本下丢失的缺陷（见 3.5）                                     |
| `minSdkVersion` / `targetSdkVersion` / **`maxSdkVersion`**        | `maxSdkVersion` 为本次新增                                          |
| `android:debuggable`（三态：声明 true/false/未声明）                        | 新增                                                             |
| 权限列表                                                              | 已有                                                             |
| **组件（activity / activity-alias / service / receiver / provider）** | 新增，含三态 `exported`、`permission`、`authorities`、`hasIntentFilter` |
| **SHA-256**                                                       | 新增（一次读取同时算 MD5 / SHA-1 / SHA-256）                              |
| **ZIP 目录结构、DEX 数量、SO、ABI、资源目录、解压后总字节数**                           | 新增                                                             |
| 签名方案、证书信息、指纹、验证结果                                                 | 新增                                                             |

### 3.2 分层回退与来源标注（规范 4.2）

- 每个重要字段都带**值 + 状态 + 来源 + 诊断**，7 种状态：  
  `extracted` / `absent` / `wrongType` / `unsupported` / `failed` / `hardenedUnknown` / `notRequested`。
- 明确区分「**这个来源不报该字段**」（`unsupported`）与「**文件里没有该字段**」（`absent`）。  
  例：`aapt2 dump badging` 不输出 `maxSdkVersion` / `debuggable`，组件只给  
  `launchable-activity` —— 这三项在 aapt2 分支下是 `unsupported` 而不是 `absent`。

### 3.3 加固线索（规范 4.2）

8 类**可解释的结构特征**，**枚举中不含任何厂商名**：

| 线索                              | 层     | 置信度    | 实测触发（本样本）              |
| ------------------------------- | ----- | ------ | ---------------------- |
| `missingPrimaryDex`             | 容器    | strong | 否                      |
| `multipleDexFiles`              | 容器    | weak   | 否                      |
| `dexHeaderNotStandard`          | 容器    | strong | 否                      |
| `unusualNativeLibraryName`      | 容器    | weak   | 否                      |
| `executableInAssets`            | 容器    | strong | 否                      |
| **`decoyArchiveEntries`**（本次新增） | 容器    | strong | **是 —— 216 条**          |
| `resourceTableAnomaly`          | 容器    | weak   | 否                      |
| **`manifestLayoutAnomaly`**（本次新增） | manifest | strong | **是 —— 4 类布局事实**       |

线索来自**两层**：容器层只看条目名与 DEX 头，manifest 层要先把 `AndroidManifest.xml`
解出来。两层的判据都是「正常构建流程不会产出这个结构」，与具体是哪家加固器无关。

不据单一特征判定厂商；每条线索都带「因为看到了什么」的证据文本。

### 3.3.1 manifest 层的布局事实（本次新增）

AXML 是二进制的，元素头与属性区之间有若干**标准规定为固定值**的字段。加固器可以
把它们改大，并在多出来的空间里塞诱饵 —— 按标准布局读的解析器会读到诱饵，
而按固定偏移硬编码的解析器会读到垃圾。四类可复现的事实：

| 事实 | 标准值 | 本样本实测 |
|---|---|---|
| `attributeStart`（属性区相对元素头的偏移） | 20 | **49 个元素非标准，最大 281（`<application>`）** |
| `attributeSize`（每个属性的步长） | 20 | **127 个元素非标准，最大 26** |
| `START/END_NAMESPACE` 的 chunk 尺寸 | 24 | **1 个非标准，最大 1220** |
| 元素区允许的 chunk 类型 | `0x0100`–`0x0104`、`0x0180` | **出现 `0x0200`** |

**误报防护**：`test/fixtures/apk/standard-manifest.axml` 是一份手工构造的最小
标准 AXML，检测对它一条都不报（有专门的断言）。


### 3.4 进度与取消（规范 4.3 / 第七步）

- 解析跑在 worker isolate，不冻结 UI。
- **只报阶段、不报百分比**：各阶段耗时极不均匀，百分比会是编造的。
- 取消是 `Isolate.immediate` **真终止**，不是丢掉结果。
- `aapt2` / XAPK 路径**本次变得可取消**（此前只能不显示取消按钮），超时与取消  
  都会**确认子进程真的退出**（退出码记信号值，POSIX 上 SIGKILL 为 `-9`）。

### 3.5 用真实加固 APK 发现并修掉的缺陷

用真实样本做端到端验证时发现：那份加固 APK 的**组件名能读出来，但  
`package`、`versionName`、`versionCode`、`minSdk`、`targetSdk`、全部  
`uses-permission`、`label` 一律为空** —— 一个很难解释的组合。

根因：`_parseStartElement` 忽略了 AXML 的 `attributeStart` 字段，直接假定属性  
紧跟在 attrExt 头之后（标准布局里它恒为 20，所以一直没暴露）。加固器在头与真正的  
属性之间塞了**诱饵字节**并把 `attributeStart` 指到诱饵之后：

| 元素                  | 实测 `attributeStart` | 标准值 |
| ------------------- | ------------------- | --- |
| `<manifest>`        | **181**             | 20  |
| `<uses-sdk>`        | 87                  | 20  |
| `<uses-permission>` | 67 / 96 / 44 …      | 20  |

按「紧跟 header」读就会读到诱饵。组件名之所以还在，是因为那些元素的  
`attributeStart` 仍是 20。

修复后该样本的全部字段与**独立写的 Python 解码器**逐项一致。  
反向验证：把修复去掉，4 条断言立刻失败。

---

## 4. 新增的 iOS（IPA）能力与平台限制

### 4.1 能力

| 能力              | 说明                                                                                                                                                                                                                                                                 |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| IPA 容器结构        | 枚举全部 bundle（主应用 / 扩展 / Watch / 嵌套 / 框架），**按路径位置分类而非名字猜测**；多个 `Payload/*.app` 全部保留并告警                                                                                                                                                                               |
| `Info.plist` 字段 | `CFBundleDisplayName` / `CFBundleName` / `CFBundleIdentifier` / `CFBundleShortVersionString` / `CFBundleVersion` / `CFBundleExecutable` / `MinimumOSVersion` / `UIDeviceFamily` / `LSApplicationQueriesSchemes` / `UIRequiredDeviceCapabilities` / `CFBundleIcons` |
| plist 编码        | XML 与二进制 `bplist00`（从零实现，含全部长度/偏移边界检查、递归环检测、深度上限）                                                                                                                                                                                                                  |
| 图标              | 只按 `Info.plist` 点名的文件定位，**不扫描目录**；`Assets.car` 形式明确报「无法直接预览」；解码前做像素预算（4096×4096）                                                                                                                                                                                   |
| Mach-O          | thin / fat、每切片独立头部、架构、段、动态库、RPATH、UUID、`LC_BUILD_VERSION`；**所有长度与偏移先验边界**                                                                                                                                                                                          |
| 签名材料（静态）        | `_CodeSignature/` 条目、从 `embedded.mobileprovision` 的 CMS 外壳里取出 plist（BER/DER 定位，支持不定长容器与分段 OCTET STRING）、`Name` / `AppIDName` / `TeamIdentifier` / `ApplicationIdentifierPrefix` / `UUID` / 有效期 / Entitlements                                                      |
| 授权比对            | 应用声明的 `CFBundleIdentifier` 与描述文件 `application-identifier` 的比对（按**后缀**比较，通配符单独处理）                                                                                                                                                                                   |
| 签名验证            | macOS 上调用 `codesign --verify`；解包有界、可取消、保证临时目录清理                                                                                                                                                                                                                    |
| 统一详情页           | 平台分支；字段状态与来源、诊断、未执行项都如实展示                                                                                                                                                                                                                                          |
| 导出报告            | Markdown，含字段状态/来源、工具原始输出、「未执行」清单                                                                                                                                                                                                                                   |

### 4.2 平台限制（必须让用户看到的）

| 限制                    | 表现                                                                                 |
| --------------------- | ---------------------------------------------------------------------------------- |
| 非 macOS 没有 `codesign` | 签名结论为「无法确认」，**绝不显示为「签名无效」**；详情页明确显示「未执行」                                           |
| 不做密码学验证               | 本项目**不自行实现签名算法**。CMS 载荷只做结构定位，不验证签名值、摘要与证书                                         |
| `Assets.car` 图标       | 无法直接预览（需要专门的资源目录解析器），明确报出而不是找替代图                                                   |
| HEIC 图标               | 系统能解、Flutter 不能，明确报「无法解码」                                                          |
| 符号链接                  | 解包时**不创建符号链接**（链接目标可以是 `../../..`），当普通文件写并计数；这会改变字节，可能让 `codesign` 的密封校验失败，结果里会附说明 |
| 嵌套二进制清单               | 上限 24 条；**被截断时补一条诊断说明「只解析了前 N 个，共 M 个」**（实测样本 27 个框架，已触发）                          |
| Mach-O 单文件上限          | 64 MiB，超过不读、不分配                                                                    |
| `Info.plist` / 描述文件上限 | 8 MiB / 16 MiB                                                                     |

---

## 5. 安全测试结果

| 测试项              | 结果                                                                                                                                                    |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| ZIP 穿越无法写到目标目录之外 | 通过（`..` 段 / 绝对路径 / 反斜杠变体 / 前缀内越界，四种变体各有用例，并断言磁盘上没多出文件）                                                                                                |
| ZIP 炸弹超预算被拒绝     | 通过（总量 / 条目数 / 压缩比）                                                                                                                                    |
| 恶意长度字段不触发无界分配    | 通过（CMS 的 BER 长度、Mach-O 的 `cmdsize`/`ncmds`、bplist00 的偏移与长度）                                                                                           |
| 校验和不符的工具下载不被执行   | 通过（`download_error_checksum` 分支）                                                                                                                      |
| 不可信路径无法注入命令参数    | 通过（参数一律以数组传入；用 `a; echo injected`、`` `id` ``、`$HOME` 这类参数钉死）                                                                                          |
| 取消不留下孤儿进程        | **部分执行**：`aapt2` 的取消/超时都断言了「进程以信号退出」（`wasTerminatedBySignal`）；`codesign` 超时终止也有断言。**「枚举残留进程」这一条未执行** —— 沙箱不允许 `ps`（`Operation not permitted`），测试里如实跳过 |
| 取消不留下临时文件        | 通过（`IpaBundleExtractor` 与 `IpaCodeSignStep` 的四条退出路径都断言了「不留临时目录」，并做过**反向验证**：去掉清理后测试立刻失败并指名泄漏的目录）                                                      |
| 切文件不串数据          | 通过（`FileState` 值语义 + `_loadGeneration` 代际；`ipa_analysis_test` 有「连续解析两个不同文件」用例）                                                                        |
| 畸形输入不崩溃          | 通过（随机字节、截断、深嵌套、环引用各有用例）                                                                                                                               |

---

## 6. 测试用例、命令与真实结果

### 6.1 单元与回归测试

```sh
export PATH="$HOME/development/flutter/bin:$PATH"
export NO_PROXY=127.0.0.1,localhost,::1   # 否则环境代理会劫持 flutter_tester 的本地 WebSocket

dart run build_runner build --delete-conflicting-outputs
dart format --output=none --set-exit-if-changed $(git ls-files -co --exclude-standard '*.dart')
flutter analyze --fatal-infos --fatal-warnings
flutter test
for pkg in packages/*/; do (cd "$pkg" && dart analyze --fatal-infos --fatal-warnings); done
```

实测结果：格式 0 处待改；analyze 无问题（根包 + 4 子包）；**469 通过 / 3 跳过 / 0 失败**。

### 6.2 真实样本端到端

```sh
APPINFOTOOL_SAMPLES=/path/to/samples flutter test test/real_samples_test.dart
```

---

## 7. 真实样本的解析结果

两个样本都由用户提供。样本不进版本库（体积大、属于用户数据），已在  
`.gitignore` 中忽略 `*.apk` / `*.ipa` 等。

### 7.1 加固 APK

| 项目      | 值                                                                  |
| ------- | ------------------------------------------------------------------ |
| 文件大小    | 60,608,714 字节（57.8 MiB）                                            |
| SHA-256 | `32272bdaf79c286219879379410d774e04421edb17327579eba66cdbb6cb8975` |
| MD5     | `8fc42777d7048dd1475887241f7eb93c`                                 |
| ZIP 条目数 | 2242（声明解压总量 120.7 MiB，压缩比 2.1×）                                    |

解析结果（修复 `attributeStart` 缺陷之后）：

| 字段                          | 值                                                            | 状态                             | 来源            |
| --------------------------- | ------------------------------------------------------------ | ------------------------------ | ------------- |
| 应用名                         | `杏⟠⎗吧`                                                       | extracted                      | builtinParser |
| 包名                          | `com.QOCrchtmmAzhekiE.HVkokqyMaKAafvaY`                      | extracted                      | builtinParser |
| 版本                          | `8.5.5` (1)                                                  | extracted                      | builtinParser |
| minSdk / targetSdk / maxSdk | `24` / `34` / 未声明                                            | extracted / extracted / absent | builtinParser |
| debuggable                  | 未声明                                                          | absent                         | builtinParser |
| 权限数                         | 40                                                           | extracted                      | builtinParser |
| 组件数                         | 22                                                           | extracted                      | builtinParser |
| DEX 数                       | 1（`classes.dex`，魔数正常）                                        | —                              | zipDirectory  |
| 原生库                         | 1（`lib/arm64-v8a/libqoovcfvd.so`）                            | —                              | zipDirectory  |
| ABI                         | `arm64-v8a`                                                  | —                              | zipDirectory  |
| 加固线索                        | **5 条**：1 条容器层（`decoyArchiveEntries`，216 条诱饵条目）+ 4 条 manifest 层（`manifestLayoutAnomaly`） | —                              | zipDirectory / builtinParser  |

这份包的加固特征（都可复现）：

1. **路径形状的诱饵条目**（216 条，占 10%）：  
   `AndroidManifest.xml/..xml`、`resources.arsc////.xml`、`classes.dex/////.xml`、  
   `AndroidManifest.xml/ .xml`。同一个字符串既是文件、又被当目录前缀。
2. **AXML 的 `attributeStart` 被放大**：49 个元素非标准，最大 **281**（`<application>`），
   标准值是 20 —— 头与真正的属性之间塞了诱饵字节。`<manifest>` 是 181。
3. **AXML 的 `attributeSize` 也被放大**：127 个元素非标准，最大 26，标准值是 20。
4. **命名空间 chunk 尺寸非标准**：1 个，最大 1220，标准值是 24；而且它出现在
   任何 `START_NAMESPACE` 之前。
5. **出现标准范围之外的 chunk 类型**：`0x0200`。

> 第 2–5 项现在会作为 `manifestLayoutAnomaly` 线索呈现（见 3.3.1）。

### 7.2 签名过的 IPA

| 项目      | 值                                                                  |
| ------- | ------------------------------------------------------------------ |
| 文件大小    | 42,465,437 字节（40.5 MiB）                                            |
| SHA-256 | `736fa5d3b0998665babe8e031c8db0e63f07a6537b15a9bc0999d67a8b675903` |
| MD5     | `08adcfcbf70f0ddefb13dbcae6e8790a`                                 |
| ZIP 条目数 | 326                                                                |

解析结果：


| 字段                   | 值                                                                               |
| -------------------- | ------------------------------------------------------------------------------- |
| 主应用                  | `Payload/UjTBpiBdS.app`                                                         |
| bundle 总数            | 28（1 个主应用 + 27 个框架）                                                             |
| 是否多个主应用              | 否                                                                               |
| Bundle Identifier    | `com.overall.sun`                                                               |
| 显示名                  | `SUN`                                                                           |
| 版本                   | `1.8.3` (183)                                                                   |
| 最低系统版本               | `15.5`                                                                          |
| 设备类型                 | iPhone + iPad（`UIDeviceFamily = [1, 2]`）                                        |
| 可执行文件                | `Payload/UjTBpiBdS.app/UjTBpiBdS`                                               |
| 架构                   | `arm64 (64-bit)`                                                                |
| 链接的动态库               | 72                                                                              |
| 嵌套二进制                | 24（**共 27，被上限截断，已给出诊断**）                                                        |
| 图标候选                 | 1 个可预览；3 条未解析（`Assets.car` ×2、`AppIcon76x76` 找不到对应条目）                           |
| 签名材料                 | `_CodeSignature/` 存在、`embedded.mobileprovision` 存在                              |
| 描述文件                 | `bxInHouse`（in-house 分发）                                                        |
| 描述文件 Team            | `7CJLRPGAZ6`                                                                    |
| 描述文件有效期              | 2026-04-29 → 2027-04-29                                                         |
| **授权比对**             | **`mismatch`** —— 描述文件授权 `7CJLRPGAZ6.com.bxbank.mobile`，而应用声明 `com.overall.sun` |
| `codesign` 结论        | **验证不通过**（退出码 1）：`invalid signature (code or signature have been modified)`     |
| `codesign` 标识 / Team | `com.overall.sun` / `7CJLRPGAZ6`                                                |
| 解析诊断                 | 31 条                                                                            |

#### 7.2.1 「签名无效」这个结论做过的独立核对

「我们的解包方式破坏了密封」与「文件真的被改过」必须分开 —— 前者是我们的  
缺陷，后者是用户的结论。核对方式：**用系统 `unzip` 独立解包同一个 IPA，  
再跑系统 `codesign`**：

```
Payload/UjTBpiBdS.app: invalid signature (code or signature have been modified)
In architecture: arm64
```

结论一致。该 `.app` 里**没有任何符号链接**（`find -type l` 计数为 0），  
因此不是「符号链接被当普通文件写出」造成的。**这个「验证不通过」是真实的。**

补充观察：签名里 `Authority=(unavailable)`（没有可用的证书链），而描述文件是  
为 `com.bxbank.mobile` 签发的 in-house 描述文件 —— 与「第三方重签名工具把  
另一个应用重新签名」的形态一致。本项目**只陈述观察到的事实与工具的结论，  
不推断这是哪种行为**。

---

## 8. 未解决问题与不支持格式

### 8.1 未执行

| 项目                                           | 原因                                                       |
| -------------------------------------------- | -------------------------------------------------------- |
| 跨平台 `flutter build`（macOS / Windows / Linux） | **未执行** —— 本机只有 Command Line Tools，无完整 Xcode             |
| 「超时后无残留子进程」的进程枚举断言                           | **未执行** —— 沙箱不允许 `ps`（`Operation not permitted`），测试里如实跳过 |
| `codesign 不可用时不解包` 用例                        | **未执行** —— 只能在非 macOS 上构造，本机 skip                        |
| 真实样本的 UI 端到端（状态 → 渲染）                        | **已执行** —— 8 条用例通过（见 6.2）                                  |
| 真实样本的**交互**（拖放、点击取消、导出报告）                   | **未执行** —— 需要图形环境做真实手势；widget 测试覆盖不到原生拖放              |

### 8.2 不支持 / 做不到

| 项目                             | 说明                                         |
| ------------------------------ | ------------------------------------------ |
| 加固 APK 的原始 manifest / DEX / 源码 | **不承诺恢复**。规范明确禁止这种承诺；本工具只报告「读到了什么」与「可能被加固」 |
| `Assets.car` 里的图标              | 需要专门的资源目录解析器，当前明确报「无法预览」                   |
| 从单个特征判定加固厂商                    | **刻意不做**。线索枚举里不含任何厂商名                      |
| 自行验证 CMS / 代码签名                | **刻意不做**。规范禁止自行实现签名算法并宣称权威结论               |
| HEIC 图标解码                      | Flutter 不支持                                |
| ZIP 符号链接的保真解包                  | 出于安全**刻意不创建**符号链接                          |
| `Assets.car` 里的图标（详见 8.4）          | **刻意不做**。载荷是 LZFSE 压缩的，需要先实现 LZFSE 解码器          |

### 8.3 已知局限（写在代码注释里，不粉饰）

- 归档层预算只统计**声明尺寸**；ZIP 头部少报尺寸时无法阻止分配，只能在读完后  
  复核并拒绝解析。
- `Future.timeout` 不会终止子进程（已改为 `Process.start` + 显式 kill）；  
  kill 只作用于直接子进程，孙进程可能短暂存活。
- 归档里的符号链接被当普通文件写出，依赖符号链接的 bundle 用 `codesign`  
  验证可能失败（结果里会给出计数与说明）。
- manifest 层的布局线索依赖 `AndroidManifest.xml` 能被解出来；若 manifest 整体
  读不出来，容器层的线索仍然有效，但 manifest 层的那几条不会出现。
- 测试里用到的 `security cms` 自签样本，其**信任链**校验会失败（刻意如此，  
  本项目不做信任链校验）。

---


### 8.4 为什么不做 `Assets.car` 图标解析

真实样本的 `Assets.car`（2,970,920 字节）实测情况：

| 检查项 | 实测 |
| --- | --- |
| 文件头 | `BOMStore`（Apple 的 BOM 归档格式） |
| PNG / JPEG 魔数 | **0 / 0** —— 图标不是以独立图片文件存放的 |
| `RAWR` / `PACK` / `BYTE` 载荷标记 | **0 / 0 / 0** |
| **LZFSE 压缩魔数**（`bvx2` / `bvxn` / `bvx$`） | **124 / 16 / 100** |

也就是说，要取出图标需要：解析 BOMStore → BOMTree → CUI rendition 键（多层
二进制格式），再**实现一个 LZFSE 解码器**（Apple 自有算法，Dart 无内置支持）。

规范 5.3 的要求是「按 `Info.plist` 配置解析图标、**明确说明无法直接预览的资源**、
不得把启动图或截图当作图标」—— 这三条当前都已满足（未解析项会连同原因显示）。
而一个半成品提取器一旦取错了 rendition，就会把**启动图或别的图**显示成图标，
恰好违反规范里那条硬约束。**因此刻意不做**，而不是做一半。
## 9. 发布前检查清单

- [x] `flutter pub get --enforce-lockfile` 通过
- [x] `dart run build_runner build` 通过
- [x] 格式检查 0 处待改
- [x] `flutter analyze --fatal-infos --fatal-warnings` 无问题
- [x] 4 个子包 `dart analyze` 无问题
- [x] `flutter test` 全绿（479 通过 / 10 明确跳过）
- [x] `flutter build bundle` 通过（编译整个程序 + 资产清单）
- [x] 每个「跳过」都写明原因，没有把「没跑」写成「通过」
- [x] 安全测试：ZIP 穿越、ZIP 炸弹、恶意长度、工具校验和、参数注入、  
  取消清理、切文件不串数据
- [x] 真实加固 APK 与真实 IPA 的端到端解析已执行，结果记入本报告
- [x] `codesign` 的「验证不通过」结论做过独立核对（系统 `unzip` + `codesign`）
- [ ] **跨平台 `flutter build`** —— 未执行，需要在装有完整 Xcode / Windows SDK  
  / Linux 桌面依赖的机器上补做
- [x] 真实样本的界面端到端（状态 → 渲染）—— 已执行，8 条通过
- [ ] 真实样本的**交互**（拖放、取消、导出报告）—— 未执行，需要图形环境
- [ ] 「取消后无残留进程」的进程枚举 —— 未执行（沙箱限制）

---

## 10. 下一步建议（按价值排序）

1. **补做跨平台构建验证** —— 这是唯一会阻塞发布的未执行项（`flutter build bundle`
   已作为替代验证通过，但产出可执行文件仍需平台工具链）。
2. ~~把 AXML 层的加固特征变成线索~~ —— **已完成**（`manifestLayoutAnomaly`）。
3. ~~真实样本的界面端到端~~ —— **已完成**（8 条用例）。剩下的**交互**部分
   （拖放、点击取消、导出报告）需要图形环境。
4. **`Assets.car` 图标解析** —— 需要先实现 LZFSE 解码器，且取错 rendition 会
   违反「不得把启动图当图标」。要做就要做对，不能做一半（见 8.4）。
5. **给 Android 侧补 `AnalysisDiagnostic`** —— 目前只有 iOS 侧产出诊断，
   因此 Android 的「解析诊断」卡片始终为空。这是事实而非缺陷，但对排查不利。
